package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestMnemonicInspectionSeparatesWordsChecksumAndMissing(t *testing.T) {
	valid := strings.Repeat("abandon ", 11) + "about"
	cases := []struct {
		text                          string
		bits, count, invalid, missing int
		checksum                      string
	}{
		{strings.ToUpper(valid), 128, 12, 0, 0, "valid"},
		{strings.Repeat("abandon ", 11) + "abandon", 128, 12, 0, 0, "invalid"},
		{strings.Repeat("abandon ", 11) + "?", 128, 12, 0, 1, "missing"},
		{"abndon about", 128, 2, 1, 0, "pending"},
		{valid, 256, 12, 0, 0, "pending"},
		{"", 128, 0, 0, 0, "pending"},
	}
	for _, tc := range cases {
		raw, _ := json.Marshal(map[string]interface{}{"text": tc.text, "bitSize": tc.bits})
		got, err := inspectMnemonic(raw)
		if err != nil {
			t.Fatal(err)
		}
		if got.WordCount != tc.count || len(got.InvalidWords) != tc.invalid || got.MissingCount != tc.missing || got.Checksum != tc.checksum {
			t.Fatalf("Unexpected inspection state: %+v", got)
		}
	}
	raw, _ := json.Marshal(map[string]interface{}{"text": "abndon about", "bitSize": 128, "completionPosition": 0})
	got, err := inspectMnemonic(raw)
	if err != nil {
		t.Fatal(err)
	}
	if got.InvalidWords[0].Position != 0 || got.CompletionPosition != 0 || len(got.Suggestions) == 0 || got.Suggestions[0] != "abandon" {
		t.Fatal("Typo location/suggestions incorrect")
	}
	raw, _ = json.Marshal(map[string]interface{}{"text": "aban ", "bitSize": 128})
	got, _ = inspectMnemonic(raw)
	if len(got.Suggestions) != 0 {
		t.Fatal("Trailing whitespace should end completion")
	}
}

func TestMnemonicAccountAndPassphraseDoNotChangeEntropyIndex(t *testing.T) {
	first, err := createMnemonic([]byte(`{"bitSize":128,"count":1,"coins":["BTC","ETH","SOL"],"index":"0","op":"current","btcType":"segwit"}`))
	if err != nil {
		t.Fatal(err)
	}
	next, err := createMnemonic([]byte(`{"bitSize":128,"count":1,"coins":["BTC","ETH","SOL"],"index":"0","op":"current","btcType":"segwit","account":2,"passphrase":"TREZOR"}`))
	if err != nil {
		t.Fatal(err)
	}
	if next.Mnemonic != first.Mnemonic || next.Index != first.Index {
		t.Fatal("Derivation parameters changed mnemonic")
	}
	expected := []string{"m/84'/0'/2'/0/0", "m/44'/60'/2'/0/0", "m/44'/501'/2'/0'"}
	for index, item := range next.Items {
		if item.Path != expected[index] || item.Addr == first.Items[index].Addr {
			t.Fatalf("Incorrect account path %s", item.Path)
		}
	}
	for _, fields := range []string{`"account":-1`, `"account":2147483648`, `"account":2147483647,"addressStart":1`} {
		_, err = createMnemonic([]byte(`{"bitSize":128,"count":1,"coins":["SOL"],"index":"0","op":"current",` + fields + `}`))
		if err == nil {
			t.Fatal("Expected account bounds error")
		}
	}
}

func TestMnemonicCandidatePrefixesTyposAndBounds(t *testing.T) {
	for _, query := range []string{"aban", "abnd", "abndon", "abnadon"} {
		candidates := suggestMnemonicWord(query)
		found := false
		for _, word := range candidates {
			if word == "abandon" {
				found = true
			}
		}
		if !found {
			t.Fatalf("Missing fuzzy candidate for %q: %v", query, candidates)
		}
	}
	candidates := suggestMnemonicWord("ab")
	if len(candidates) != 8 || candidates[0] != "abandon" {
		t.Fatal("Prefix order or candidate limit changed")
	}
	for _, word := range candidates {
		if !strings.HasPrefix(word, "ab") {
			t.Fatal("Fuzzy results displaced prefix matches")
		}
	}
	for _, query := range []string{"", "?", "ab?", "😀", "中", "x", strings.Repeat("a", 33)} {
		if len(suggestMnemonicWord(query)) != 0 {
			t.Fatal("Non-word input received candidates")
		}
	}
	raw, _ := json.Marshal(map[string]interface{}{"text": "abnd about ?", "bitSize": 128, "completionPosition": 0})
	inspected, err := inspectMnemonic(raw)
	if err != nil || inspected.CompletionPosition != 0 || inspected.Suggestions[0] != "abandon" {
		t.Fatal("Mid-sentence target failed")
	}
	raw, _ = json.Marshal(map[string]interface{}{"text": "abnd about ?", "bitSize": 128, "completionPosition": -1})
	inspected, err = inspectMnemonic(raw)
	if err != nil || len(inspected.Suggestions) != 0 {
		t.Fatal("Dismissed target still received suggestions")
	}
}
