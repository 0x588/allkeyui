package main

import (
	"encoding/json"
	"math/big"
	"strings"
	"testing"

	"github.com/tyler-smith/go-bip39"
	"github.com/tyler-smith/go-bip39/wordlists"
)

func TestPatternSearchMiddleWordAllLengths(t *testing.T) {
	for _, bits := range []int{128, 160, 192, 224, 256} {
		phrase, _ := bip39.NewMnemonic(make([]byte, bits/8))
		words := strings.Fields(phrase)
		words[4] = "?"
		request := mnemonicRequest{BitSize: bits, Pattern: strings.Join(words, " "), Op: "search"}
		var expected []*big.Int
		for _, word := range wordlists.English {
			words[4] = word
			if entropy, err := bip39.EntropyFromMnemonic(strings.Join(words, " ")); err == nil {
				expected = append(expected, new(big.Int).SetBytes(entropy))
			}
		}
		for _, op := range []string{"search", "last"} {
			request.Op = op
			want := expected[0]
			if op == "last" {
				want = expected[len(expected)-1]
			}
			got, cursor, err := findMnemonicPattern(request)
			if err != nil || cursor != "" || got.Cmp(want) != 0 {
				t.Fatalf("bits=%d op=%s: %v", bits, op, err)
			}
		}
		request.Op = "search"
		for i, want := range expected {
			got, _, err := findMnemonicPattern(request)
			if err != nil || got.Cmp(want) != 0 {
				t.Fatalf("forward bits=%d i=%d: %v", bits, i, err)
			}
			request.Index, request.Op = got.String(), "next"
		}
		if _, _, err := findMnemonicPattern(request); err == nil {
			t.Fatal("expected upper boundary")
		}
		request.Op = "previous"
		for i := len(expected) - 2; i >= 0; i-- {
			got, _, err := findMnemonicPattern(request)
			if err != nil || got.Cmp(expected[i]) != 0 {
				t.Fatalf("reverse bits=%d i=%d: %v", bits, i, err)
			}
			request.Index = got.String()
		}
		if _, _, err := findMnemonicPattern(request); err == nil {
			t.Fatal("expected lower boundary")
		}
	}
}

func TestPatternMultipleMissingCarryAndResume(t *testing.T) {
	words := strings.Fields("? abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon ?")
	request := mnemonicRequest{BitSize: 128, Pattern: strings.Join(words, " "), Op: "search"}
	// Build an independent, exhaustive oracle across a carry of the rightmost word.
	var expected []*big.Int
	for a := 0; a < 2; a++ {
		for b := 0; b < 2048; b++ {
			words[0], words[11] = wordlists.English[a], wordlists.English[b]
			if entropy, err := bip39.EntropyFromMnemonic(strings.Join(words, " ")); err == nil {
				expected = append(expected, new(big.Int).SetBytes(entropy))
			}
		}
	}
	for i, want := range expected {
		var got *big.Int
		for {
			var cursor string
			var err error
			got, cursor, err = findMnemonicPatternBatch(request, 1)
			if err != nil {
				t.Fatal(err)
			}
			request.Cursor = cursor
			if cursor == "" {
				break
			}
		}
		if got.Cmp(want) != 0 {
			t.Fatalf("wrong candidate at %d", i)
		}
		request.Index, request.Op = got.String(), "next"
	}
	// The first result after a left-word increment must go back across the carry.
	request.Index = expected[len(expected)/2].String()
	request.Op = "previous"
	got, _, err := findMnemonicPattern(request)
	if err != nil || got.Cmp(expected[len(expected)/2-1]) != 0 {
		t.Fatal("reverse carry failed", err)
	}
}

func TestPatternValidationAndAPI(t *testing.T) {
	for _, pattern := range []string{"abandon ?", "? " + strings.Repeat("abandon ", 10) + "typo", strings.Repeat("abandon ", 12)} {
		_, _, err := findMnemonicPattern(mnemonicRequest{BitSize: 128, Pattern: pattern, Op: "search"})
		if err == nil {
			t.Fatalf("expected invalid pattern: %s", pattern)
		}
	}
	request := mnemonicRequest{BitSize: 128, Count: 1, Coins: []string{"ETH"}, Index: strings.Repeat("abandon ", 5) + "? " + strings.Repeat("abandon ", 5) + "about", Op: "search"}
	raw, _ := json.Marshal(request)
	result, err := createMnemonic(raw)
	if err != nil || result.Index != "0" || len(result.Items) != 1 {
		t.Fatal("wildcard API failed", err)
	}
	request.Index = "abandon"
	raw, _ = json.Marshal(request)
	result, err = createMnemonic(raw)
	if err != nil || result.Index != "0" {
		t.Fatal("prefix search regression", err)
	}
}

func TestPatternRandomWrapAndThreeMissing(t *testing.T) {
	pattern := "? ? abandon abandon abandon abandon abandon abandon abandon abandon abandon ?"
	request := mnemonicRequest{BitSize: 128, Pattern: pattern, Op: "random", Cursor: new(big.Int).Lsh(big.NewInt(1), 33).String()}
	got, cursor, err := findMnemonicPattern(request)
	if err != nil || cursor != "" || got.Sign() != 0 {
		t.Fatal("random wrap failed", err)
	}
	request.Op, request.Cursor = "next", ""
	request.Index = got.String()
	got, cursor, err = findMnemonicPattern(request)
	if err != nil || cursor != "" || got.Cmp(big.NewInt(1)) != 0 {
		t.Fatal("three wildcard navigation failed", err)
	}
}
