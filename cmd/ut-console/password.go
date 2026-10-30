package main

import (
	"bufio"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

const (
	hashScheme      = "pbkdf2-sha256"
	hashIterations  = 600_000
	maxIterations   = 10_000_000
	saltBytes       = 16
	keyBytes        = 32
	maxPasswordSize = 1024
)

var encoding = base64.RawStdEncoding

func derive(password string, salt []byte, iterations int) ([]byte, error) {
	return pbkdf2.Key(sha256.New, password, salt, iterations, keyBytes)
}

func hashPassword(password string) (string, error) {
	salt := make([]byte, saltBytes)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key, err := derive(password, salt, hashIterations)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%s$%d$%s$%s", hashScheme, hashIterations, encoding.EncodeToString(salt), encoding.EncodeToString(key)), nil
}

func passwordMatches(stored, password string) bool {
	fields := strings.Split(strings.TrimSpace(stored), "$")
	if len(fields) != 4 || fields[0] != hashScheme {
		return false
	}
	iterations, err := strconv.Atoi(fields[1])
	if err != nil || iterations < 1 || iterations > maxIterations {
		return false
	}
	salt, err := encoding.DecodeString(fields[2])
	if err != nil {
		return false
	}
	want, err := encoding.DecodeString(fields[3])
	if err != nil || len(want) != keyBytes {
		return false
	}
	got, err := derive(password, salt, iterations)
	return err == nil && subtle.ConstantTimeCompare(got, want) == 1
}

// The password is read from the standard input, never taken as an argument:
// an argument is in the process table for anyone on the machine to read.
func hashPasswordCommand(stdin io.Reader, stdout, stderr io.Writer) int {
	reader := bufio.NewReader(io.LimitReader(stdin, maxPasswordSize+2))
	line, err := reader.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		fmt.Fprintln(stderr, "ut-console hash-password: the standard input cannot be read:", err)
		return 1
	}
	password := strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
	if password == "" || len(password) > maxPasswordSize {
		fmt.Fprintln(stderr, "ut-console hash-password: give the password on the standard input, one line, at most 1024 bytes")
		return 2
	}
	encoded, err := hashPassword(password)
	if err != nil {
		fmt.Fprintln(stderr, "ut-console hash-password:", err)
		return 1
	}
	fmt.Fprintln(stdout, encoded)
	return 0
}
