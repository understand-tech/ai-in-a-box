package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/sha256"
	"errors"
	"io"
)

const (
	joining   = "ut-pair v1 join"
	accepting = "ut-pair v1 accept"
	nonceSize = 32
)

// One key per direction, each also bound as associated data: a message sent
// one way cannot be played back the other way, even if a check is forgotten.
func keyFor(direction string, code Code) ([]byte, error) {
	return hkdf.Key(sha256.New, code[:], nil, direction, 32)
}

func seal(direction string, code Code, message []byte, random io.Reader) ([]byte, error) {
	aead, err := aeadFor(direction, code)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := io.ReadFull(random, nonce); err != nil {
		return nil, err
	}
	return aead.Seal(nonce, nonce, message, []byte(direction)), nil
}

var errNotSealedWithThisCode = errors.New("not sealed with this code")

func open(direction string, code Code, sealed []byte) ([]byte, error) {
	aead, err := aeadFor(direction, code)
	if err != nil {
		return nil, err
	}
	if len(sealed) < aead.NonceSize() {
		return nil, errNotSealedWithThisCode
	}
	nonce, ciphertext := sealed[:aead.NonceSize()], sealed[aead.NonceSize():]
	message, err := aead.Open(nil, nonce, ciphertext, []byte(direction))
	if err != nil {
		return nil, errNotSealedWithThisCode
	}
	return message, nil
}

func aeadFor(direction string, code Code) (cipher.AEAD, error) {
	key, err := keyFor(direction, code)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// A message is the asker's random value followed by a root, in DER.
func message(nonce [nonceSize]byte, root []byte) []byte {
	return append(nonce[:], root...)
}

func splitMessage(plain []byte) ([nonceSize]byte, []byte, error) {
	var nonce [nonceSize]byte
	if len(plain) <= nonceSize {
		return nonce, nil, errors.New("a message without a root")
	}
	copy(nonce[:], plain[:nonceSize])
	return nonce, plain[nonceSize:], nil
}
