package main

import (
	"errors"
	"net/url"
	"regexp"
	"strings"
)

const maxLicenseLength = 8192

var hostname = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$`)

type Answers struct {
	Domain    string
	License   string
	Reporting string
}

func parseAnswers(form url.Values) (Answers, error) {
	answers := Answers{
		Domain:    strings.ToLower(strings.TrimSpace(form.Get("domain"))),
		License:   strings.TrimSpace(form.Get("license")),
		Reporting: form.Get("reporting"),
	}
	switch {
	case !hostname.MatchString(answers.Domain) || len(answers.Domain) > 253:
		return Answers{}, errors.New("the address is not a host name, such as box.example.com")
	case answers.License == "":
		return Answers{}, errors.New("the license key is missing")
	case len(answers.License) > maxLicenseLength || strings.ContainsAny(answers.License, "\r\n"):
		return Answers{}, errors.New("the license key is one line, as UnderstandTech sent it")
	case answers.Reporting != "yes" && answers.Reporting != "no":
		return Answers{}, errors.New("say whether usage reports are sent")
	}
	return answers, nil
}

func installArguments(answers Answers, licenseFile string) []string {
	return []string{"--domain", answers.Domain, "--license-file", licenseFile, "--reporting", answers.Reporting}
}
