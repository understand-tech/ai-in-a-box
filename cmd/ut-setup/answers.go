package main

import (
	"errors"
	"net/url"
	"regexp"
	"strings"
)

const maxLicenseLength = 8192

var modelName = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{0,63}$`)

var hostname = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$`)

var ipv4 = regexp.MustCompile(`^([0-9]{1,3}\.){3}[0-9]{1,3}$`)

var addressRanges = regexp.MustCompile(`^[0-9a-fA-F:./,]{1,256}$`)

type Answers struct {
	Role           string
	Domain         string
	ComputeAddress string
	TLS            string
	CertificateDir string
	ProxyRanges    string
	License        string
	Reporting      string
	Model          string
}

// A folder that carries the license file needs no key, and a box installed from
// a folder has no network to send reports on.
func parseAnswers(form url.Values, folder Folder) (Answers, error) {
	answers := Answers{
		Role:           form.Get("role"),
		Domain:         strings.ToLower(strings.TrimSpace(form.Get("domain"))),
		ComputeAddress: strings.ToLower(strings.TrimSpace(form.Get("compute_address"))),
		TLS:            form.Get("tls"),
		CertificateDir: strings.TrimSpace(form.Get("certificate_dir")),
		ProxyRanges:    strings.ReplaceAll(form.Get("proxy_ranges"), " ", ""),
		License:        strings.TrimSpace(form.Get("license")),
		Reporting:      form.Get("reporting"),
		Model:          form.Get("model"),
	}
	if folder.License != "" {
		answers.License = ""
	}
	if folder.Images != "" {
		answers.Reporting = "no"
	}
	if answers.Role == "compute" {
		if err := computeProblem(answers); err != nil {
			return Answers{}, err
		}
	} else if err := platformProblem(&answers); err != nil {
		return Answers{}, err
	}
	switch {
	case answers.License == "" && folder.License == "":
		return Answers{}, errors.New("the license key is missing")
	case len(answers.License) > maxLicenseLength || strings.ContainsAny(answers.License, "\r\n"):
		return Answers{}, errors.New("the license key is one line, as UnderstandTech sent it")
	case answers.Reporting != "yes" && answers.Reporting != "no":
		return Answers{}, errors.New("say whether usage reports are sent")
	case answers.Model != "" && !modelName.MatchString(answers.Model):
		return Answers{}, errors.New("the model is not one this box lists")
	}
	return answers, nil
}

func computeProblem(answers Answers) error {
	switch {
	case strings.HasSuffix(answers.ComputeAddress, ".local"):
		return errors.New("the platform's containers cannot resolve a .local name: give this box's IP address or a DNS name")
	case !ipv4.MatchString(answers.ComputeAddress) && (!hostname.MatchString(answers.ComputeAddress) || len(answers.ComputeAddress) > 253):
		return errors.New("the address is not an IP address or a host name, such as 10.0.0.12 or gpu-1.example.com")
	}
	return nil
}

func platformProblem(answers *Answers) error {
	answers.Role = "complete"
	switch {
	case !hostname.MatchString(answers.Domain) || len(answers.Domain) > 253:
		return errors.New("the address is not a host name, such as box.example.com")
	case answers.TLS == "certificate" && (!strings.HasPrefix(answers.CertificateDir, "/") || strings.ContainsAny(answers.CertificateDir, "\r\n") || len(answers.CertificateDir) > 4096):
		return errors.New("the certificate folder is a full path on this box, such as /etc/understandtech/certs")
	case answers.TLS == "proxy" && !addressRanges.MatchString(answers.ProxyRanges):
		return errors.New("the load balancer's range is a CIDR, such as 10.42.0.0/16, or several separated by commas")
	case answers.TLS != "" && answers.TLS != "internal" && answers.TLS != "certificate" && answers.TLS != "proxy":
		return errors.New("say how TLS ends")
	}
	return nil
}

func installArguments(answers Answers, licenseFile string) []string {
	arguments := []string{"--domain", answers.Domain}
	if answers.Role == "compute" {
		arguments = []string{"--compute", answers.ComputeAddress}
	}
	switch answers.TLS {
	case "certificate":
		arguments = append(arguments, "--certificate-dir", answers.CertificateDir)
	case "proxy":
		arguments = append(arguments, "--behind-proxy", answers.ProxyRanges)
	}
	if licenseFile != "" {
		arguments = append(arguments, "--license-file", licenseFile)
	}
	arguments = append(arguments, "--reporting", answers.Reporting)
	if answers.Model != "" {
		arguments = append(arguments, "--model", answers.Model)
	}
	return arguments
}
