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

type Answers struct {
	Domain    string
	License   string
	Reporting string
	Model     string
}

// A folder that carries the license file needs no key, and a box installed from
// a folder has no network to send reports on.
func parseAnswers(form url.Values, folder Folder) (Answers, error) {
	answers := Answers{
		Domain:    strings.ToLower(strings.TrimSpace(form.Get("domain"))),
		License:   strings.TrimSpace(form.Get("license")),
		Reporting: form.Get("reporting"),
		Model:     form.Get("model"),
	}
	if folder.License != "" {
		answers.License = ""
	}
	if folder.Images != "" {
		answers.Reporting = "no"
	}
	switch {
	case !hostname.MatchString(answers.Domain) || len(answers.Domain) > 253:
		return Answers{}, errors.New("the address is not a host name, such as box.example.com")
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

func installArguments(answers Answers, licenseFile string) []string {
	arguments := []string{"--domain", answers.Domain}
	if licenseFile != "" {
		arguments = append(arguments, "--license-file", licenseFile)
	}
	arguments = append(arguments, "--reporting", answers.Reporting)
	if answers.Model != "" {
		arguments = append(arguments, "--model", answers.Model)
	}
	return arguments
}
