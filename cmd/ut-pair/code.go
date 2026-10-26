package main

import (
	"errors"
	"io"
	"math/big"
	"strings"
)

// Crockford's base32 and its check symbols: no I, L, O or U to misread, and
// the typed form forgives the letters people confuse with digits.
const (
	codeSymbols  = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
	checkSymbols = codeSymbols + "*~$=U"
	codeLength   = 24
)

type Code [15]byte

func newCode(random io.Reader) (Code, error) {
	var code Code
	_, err := io.ReadFull(random, code[:])
	return code, err
}

func (c Code) String() string {
	number := new(big.Int).SetBytes(c[:])
	symbols := make([]byte, codeLength)
	five := big.NewInt(31)
	for i := codeLength - 1; i >= 0; i-- {
		symbols[i] = codeSymbols[new(big.Int).And(number, five).Int64()]
		number.Rsh(number, 5)
	}
	var grouped strings.Builder
	for i := 0; i < codeLength; i += 4 {
		grouped.Write(symbols[i : i+4])
		grouped.WriteByte('-')
	}
	grouped.WriteByte(c.check())
	return grouped.String()
}

func (c Code) check() byte {
	remainder := new(big.Int).Mod(new(big.Int).SetBytes(c[:]), big.NewInt(int64(len(checkSymbols))))
	return checkSymbols[remainder.Int64()]
}

var errNotACode = errors.New("this is not a pairing code: 24 letters and digits in groups of four, then one more")

func parseCode(typed string) (Code, error) {
	var code Code
	normalized := strings.NewReplacer("-", "", " ", "", "O", "0", "I", "1", "L", "1").Replace(strings.ToUpper(strings.TrimSpace(typed)))
	if len(normalized) != codeLength+1 {
		return code, errNotACode
	}
	number := new(big.Int)
	for _, symbol := range []byte(normalized[:codeLength]) {
		value := strings.IndexByte(codeSymbols, symbol)
		if value < 0 {
			return code, errNotACode
		}
		number.Lsh(number, 5).Or(number, big.NewInt(int64(value)))
	}
	number.FillBytes(code[:])
	if code.check() != normalized[codeLength] {
		return code, errors.New("this code has a typo: its last symbol does not match the rest")
	}
	return code, nil
}
