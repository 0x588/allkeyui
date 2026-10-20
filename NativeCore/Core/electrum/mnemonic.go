package electrum

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha512"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/tyler-smith/go-bip39/wordlists"
	"golang.org/x/crypto/pbkdf2"
)

var (
	// Prefixes defines the version bytes for different address types
	Prefixes = map[string]string{
		"segwit":     "100",
		"standard":   "01",
		"2fa":        "101",
		"2fa-segwit": "102",
	}

	ErrInvalidMnemonic = errors.New("invalid seed version for mnemonic")
)

// Options defines the parameters for mnemonic generation
type Options struct {
	Prefix   string
	Strength int
	Wordlist []string
}

// DefaultOptions provides default values for mnemonic generation
var DefaultOptions = Options{
	Prefix:   Prefixes["segwit"],
	Strength: 132,
}

// GenerateMnemonic generates a new mnemonic phrase
func GenerateMnemonic(opts *Options) (string, error) {
	if opts == nil {
		opts = &DefaultOptions
	}

	if err := validatePrefix(opts.Prefix); err != nil {
		return "", err
	}

	prefixBits := len(opts.Prefix) * 4
	if prefixBits > opts.Strength/2 {
		return "", errors.New("strength must be at least 2x of prefix bit count")
	}

	wordBitLen := BitLen(len(opts.Wordlist))
	wordCount := (opts.Strength + wordBitLen - 1) / wordBitLen
	byteCount := (wordCount*wordBitLen + 7) / 8
	var result string
	for {
		bytes := make([]byte, byteCount)
		if _, err := rand.Read(bytes); err != nil {
			return "", err
		}

		MaskBytes(bytes, opts.Strength)
		result = Encode(bytes, opts.Wordlist)

		if prefixMatches(result, opts.Prefix) {
			break
		}
	}

	fmt.Printf("prefixBits: %d, wordBitLen: %d, wordCount: %d, byteCount: %d\n", prefixBits, wordBitLen, wordCount, byteCount)
	return result, nil
}

func MaxIndex(bitSize int) *big.Int {
	a := big.NewInt(0).Lsh(big.NewInt(1), uint(bitSize))
	return a.Sub(a, big.NewInt(1))
}

func GenerateMnemonicWithStart(start *big.Int, addressType string) (string, string, *big.Int, error) {
	var result string
	maxIndex := MaxIndex(136)
	opts := &DefaultOptions
	opts.Wordlist = wordlists.English
	for start.Cmp(maxIndex) < 0 {
		bytes := make([]byte, 17)
		indexBytes := start.Bytes()
		if len(indexBytes) == 17 {
			bytes = indexBytes
		} else {
			copy(bytes[17-len(indexBytes):], indexBytes)
		}
		MaskBytes(bytes, opts.Strength)
		result = Encode(bytes, opts.Wordlist)
		prefix := ValidateMnemonic(result, addressType)

		if prefix != "" {
			return result, prefix, start, nil
		}
		start = big.NewInt(0).Add(start, big.NewInt(1))
	}
	return "", "", nil, errors.New("no valid mnemonic found in the given range")
}

// SeedOptions defines parameters for seed generation
type SeedOptions struct {
	Passphrase string
	Prefix     string
	SkipCheck  bool
}

// DefaultSeedOptions provides default values for seed generation
var DefaultSeedOptions = SeedOptions{
	Passphrase: "",
	Prefix:     Prefixes["segwit"],
	SkipCheck:  false,
}

// MnemonicToSeed converts a mnemonic to a seed using the given options
func MnemonicToSeed(mnemonic string, opts *SeedOptions) ([]byte, error) {
	if opts == nil {
		opts = &DefaultSeedOptions
	}

	if err := validatePrefix(opts.Prefix); err != nil {
		return nil, err
	}

	if !opts.SkipCheck {
		if err := checkPrefix(mnemonic, opts.Prefix); err != nil {
			return nil, err
		}
	}

	normalizedMnemonic := NormalizeText(mnemonic)
	normalizedPassphrase := NormalizeText(opts.Passphrase)
	salt := "electrum" + normalizedPassphrase

	return pbkdf2.Key([]byte(normalizedMnemonic), []byte(salt), 2048, 64, sha512.New), nil
}

// ValidateMnemonic checks if a mnemonic is valid for the given prefix
func ValidateMnemonic(mnemonic string, addressType string) string {
	prefixes := []string{
		Prefixes["segwit"],
		Prefixes["standard"],
	}
	if addressType == "segwit" {
		prefixes = []string{Prefixes["segwit"]}
	} else if addressType == "standard" {
		prefixes = []string{Prefixes["standard"]}
	}

	for _, prefix := range prefixes {
		if prefixMatches(mnemonic, prefix) {
			return prefix
		}
	}
	return ""
}

func validatePrefix(prefix string) error {
	for _, c := range prefix {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return errors.New("prefix must be hexadecimal")
		}
	}
	return nil
}

func checkPrefix(mnemonic string, prefix string) error {
	if prefixMatches(mnemonic, prefix) {
		return nil
	}
	return ErrInvalidMnemonic
}

func prefixMatches(mnemonic string, prefix string) bool {
	hmac := hmac.New(sha512.New, []byte("Seed version"))
	hmac.Write([]byte(NormalizeText(mnemonic)))
	hx := hex.EncodeToString(hmac.Sum(nil))
	return strings.HasPrefix(hx, strings.ToLower(prefix))
}
