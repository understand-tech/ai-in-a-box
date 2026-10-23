package main

type Folder struct {
	Images  string
	License string
}

func (f Folder) arguments() []string {
	arguments := []string{}
	if f.Images != "" {
		arguments = append(arguments, "--images-from", f.Images)
	}
	if f.License != "" {
		arguments = append(arguments, "--machine-file", f.License)
	}
	return arguments
}
