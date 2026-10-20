package main

import (
	"encoding/hex"
	"encoding/json"
	"math/big"
	"strings"
	"testing"

	"github.com/btcsuite/btcd/btcec/v2"
)

func calcTest(t *testing.T, op, input string) string {
	t.Helper()
	value, err := calculate(calculatorRequest{Operation: op, Input: input, Compressed: true})
	if err != nil {
		t.Fatalf("%s: %v", op, err)
	}
	return value
}
func TestCalculatorKnownConversions(t *testing.T) {
	cases := []struct{ op, input, want string }{
		{"dec-to-hex", "255", "ff"}, {"hex-to-dec", "0Xf", "15"}, {"bin-to-hex", "1111", "f"}, {"hex-to-bin", "01", "00000001"},
		{"ascii-to-hex", " 中\n", "20e4b8ad0a"}, {"hex-to-ascii", "20e4b8ad0a", " 中\n"},
		{"sha256", "616263", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
		{"sha256-text", "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
		{"keccak256", "", "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"},
		{"ripemd160", "", "9c1185a5c5e9fc54612808977ee8f548b2258d31"},
		{"reverse-bytes", "010203", "030201"}, {"pad-hex", "1", strings.Repeat("0", 63) + "1"},
		{"priv-to-addr-c", "1", "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH"},
		{"priv-to-addr-u", "01", "1EHNa6Q4Jz2uvNExL497mE43ikXhwF6kZm"},
		{"priv-to-addr-evm", "1", "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"},
		{"priv-to-wif-c", "1", "KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn"},
		{"priv-to-wif-u", "1", "5HpHagT65TZzG1PH3CSu63k8DbpvD8s5ip4nEB3kEsreAnchuDf"},
		{"checksum-evm", "52908400098527886e0f7030069857d2e4169ee7", "0x52908400098527886E0F7030069857D2E4169EE7"},
	}
	for _, c := range cases {
		t.Run(c.op+c.input, func(t *testing.T) {
			if got := calcTest(t, c.op, c.input); got != c.want {
				t.Errorf("got %q want %q", got, c.want)
			}
		})
	}
	// Text input keeps whitespace; no trimming or line splitting inside the core.
	if calcTest(t, "sha256-text", " abc\n") == calcTest(t, "sha256-text", "abc") {
		t.Fatal("text whitespace was lost")
	}
}
func TestCalculatorKeysAndEncodingRoundTrips(t *testing.T) {
	compressed := calcTest(t, "priv-to-pub-c", "1")
	uncompressed := calcTest(t, "priv-to-pub-u", "1")
	if calcTest(t, "pub-compress", uncompressed) != compressed || calcTest(t, "pub-decompress", compressed) != uncompressed {
		t.Fatal("public key round trip")
	}
	if calcTest(t, "pub-to-addr", compressed) != calcTest(t, "priv-to-addr-c", "1") {
		t.Fatal("public address")
	}
	if calcTest(t, "pub-to-addr-evm", compressed) != calcTest(t, "priv-to-addr-evm", "1") {
		t.Fatal("EVM public address")
	}
	for _, kind := range []string{"c", "u"} {
		wif := calcTest(t, "priv-to-wif-"+kind, "1")
		if calcTest(t, "wif-to-priv", wif) != strings.Repeat("0", 63)+"1" {
			t.Fatal("WIF round trip")
		}
		calcTest(t, "wif-validate", wif)
	}
	for _, prefix := range []string{"base58", "base58check"} {
		if calcTest(t, prefix+"-dec", calcTest(t, prefix+"-enc", "000001ff")) != "000001ff" {
			t.Fatal("base58 zero preservation")
		}
	}
	hash := calcTest(t, "pub-to-hash160", compressed)
	if calcTest(t, "hash160-to-addr", hash) != calcTest(t, "priv-to-addr-c", "1") {
		t.Fatal("hash address")
	}
	for _, op := range []string{"bech32", "bech32m"} {
		data := hash
		if op == "bech32m" {
			data = strings.Repeat("00", 32)
		}
		address := calcTest(t, op+"-enc", data)
		decoded := calcTest(t, op+"-dec", address)
		if !strings.Contains(decoded, data) {
			t.Fatal("bech32 round trip")
		}
		calcTest(t, "addr-validate", address)
		if !strings.Contains(calcTest(t, "addr-to-hash160", address), data) {
			t.Fatal("witness payload")
		}
	}
	all := calcTest(t, "priv-to-all", "1")
	for _, part := range []string{strings.Repeat("0", 63) + "1", "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH", "bc1q", "bc1p", "3JvL6Ymt8MVWiCNHC7oWU6nLeHNJKLZGLN"} {
		if !strings.Contains(all, part) {
			t.Fatal("missing all-format address")
		}
	}
	calcTest(t, "pub-validate", compressed)
}
func TestCalculatorRejectsMalformedAndBoundaryInputs(t *testing.T) {
	invalid := []struct{ op, input string }{
		{"hash160-to-addr", strings.Repeat("g", 40)}, {"hash160-to-segwit", strings.Repeat("g", 40)},
		{"bech32-enc", strings.Repeat("g", 40)}, {"bech32m-enc", strings.Repeat("g", 64)},
		{"bech32m-enc", strings.Repeat("00", 20)}, {"sha256", "abc"}, {"hex-to-ascii", "ff"},
		{"priv-to-pub-c", "0"}, {"priv-to-pub-c", btcec.S256().N.Text(16)},
		{"pub-compress", "04" + strings.Repeat("00", 64)}, {"pad-hex", strings.Repeat("aa", 33)},
		{"base58-dec", "0OIl"}, {"base58check-dec", "1111"}, {"wif-to-priv", "1"},
		{"addr-validate", "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMJ"},
		{"addr-validate", "0x7E5F4552091A69125d5DfCb7b8C2659029395Bde"},
		{"dec-to-hex", "-1"}, {"bin-to-hex", "12"}, {"hex-to-dec", "0xgg"},
	}
	for _, c := range invalid {
		if _, err := calculate(calculatorRequest{Operation: c.op, Input: c.input}); err == nil {
			t.Errorf("%s accepted %q", c.op, c.input)
		}
	}
	nMinusOne := new(big.Int).Sub(btcec.S256().N, big.NewInt(1)).Text(16)
	calcTest(t, "priv-to-wif-c", nMinusOne)
	for i := 0; i < 8; i++ {
		key := calcTest(t, "random-key", "")
		if len(key) != 64 {
			t.Fatal("random length")
		}
		n, _ := new(big.Int).SetString(key, 16)
		if n.Sign() <= 0 || n.Cmp(btcec.S256().N) >= 0 {
			t.Fatal("random range")
		}
	}
	bc1 := calcTest(t, "bech32-enc", strings.Repeat("00", 20))
	if _, err := calculate(calculatorRequest{Operation: "bech32m-dec", Input: bc1}); err == nil {
		t.Fatal("accepted wrong encoding variant")
	}
}
func TestCalculatorBIP38PublishedVectors(t *testing.T) {
	vectors := []struct{ pass, cipher, wif string }{
		{"TestingOneTwoThree", "6PRVWUbkzzsbcVac2qwfssoUJAN1Xhrg6bNk8J7Nzm5H7kxEbn2Nh2ZoGg", "5KN7MzqK5wt2TP1fQCYyHBtDrXdJuXbUzm4A9rKAteGu3Qi5CVR"},
		{"TestingOneTwoThree", "6PYNKZ1EAgYgmQfmNVamxyXVWHzK5s6DGhwP4J5o44cvXdoY7sRzhtpUeo", "L44B5gGEpqEDRS9vVPz7QT35jcBG2r3CZwSwQ4fCewXAhAhqGVpP"},
		{"\u03d2\u0301\u0000\U00010400\U0001f4a9", "6PRW5o9FLp4gJDDVqJQKJFTpMvdsSGJxMYHtHaQBF3ooa8mwD69bapcDQn", "5Jajm8eQ22H3pGWLEVCXyvND8dQZhiQhoLJNKjYXk9roUFTMSZ4"},
	}
	for _, v := range vectors {
		encrypted, err := calculate(calculatorRequest{Operation: "bip38-encrypt", Input: v.wif, Passphrase: v.pass, Compressed: true})
		if err != nil || encrypted != v.cipher {
			t.Fatalf("BIP38 encryption vector: %v / %s", err, encrypted)
		}
		decrypted, err := calculate(calculatorRequest{Operation: "bip38-decrypt", Input: v.cipher, Passphrase: v.pass})
		if err != nil || !strings.Contains(decrypted, v.wif) {
			t.Fatalf("BIP38 decryption vector: %v", err)
		}
	}
	if _, err := calculate(calculatorRequest{Operation: "bip38-decrypt", Input: vectors[0].cipher, Passphrase: "wrong"}); err == nil {
		t.Fatal("accepted wrong passphrase")
	}
	payload := append([]byte{1, 0x43, 0}, make([]byte, 36)...)
	if _, err := calculate(calculatorRequest{Operation: "bip38-decrypt", Input: calcCheckEncode(payload), Passphrase: "test"}); err == nil {
		t.Fatal("accepted EC multiply")
	}
	payload[1] = 0x42
	payload[2] = 0xe1
	if _, err := calculate(calculatorRequest{Operation: "bip38-decrypt", Input: calcCheckEncode(payload), Passphrase: "test"}); err == nil {
		t.Fatal("accepted reserved bits")
	}
}
func TestCalculatorJSONBoundsAndNULPassphrase(t *testing.T) {
	raw, _ := json.Marshal(calculatorRequest{Operation: "sha256-text", Input: "a\x00b"})
	v, err := calculateJSON(raw)
	if err != nil || v.Output != hex.EncodeToString(calcSHA([]byte{'a', 0, 'b'})) {
		t.Fatal("JSON NUL was lost")
	}
	// JSON escaping must not shrink the advertised 1 MiB input allowance.
	raw, _ = json.Marshal(calculatorRequest{Operation: "sha256-text", Input: strings.Repeat("\x00", 1024*1024)})
	if _, err := calculateJSON(raw); err != nil {
		t.Fatalf("valid escaped input rejected: %v", err)
	}
	raw, _ = json.Marshal(calculatorRequest{Operation: "sha256-text", Input: strings.Repeat("x", 1024*1024+1)})
	if _, err := calculateJSON(raw); err == nil {
		t.Fatal("accepted oversized input")
	}
}
