package main

import (
	"encoding/json"
	"github.com/btcsuite/btcd/btcutil/base58"
	"math/big"
	"strings"
	"testing"
)

func TestCreateKeysAtOne(t *testing.T) {
	result, err := createKeys([]byte(`{"index":"1","coins":["ETH"],"count":1,"op":"current"}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 1 {
		t.Fatalf("expected one result, got %d", len(result.Items))
	}
	if got, want := result.Items[0].Addr, "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"; got != want {
		t.Fatalf("address mismatch: got %s want %s", got, want)
	}
}

func TestRejectsInvalidIndex(t *testing.T) {
	response := safeResponse(func() (interface{}, error) {
		return createKeys([]byte(`{"index":"xyz","coins":["BTC"],"count":1}`))
	})
	var decoded envelope
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.OK || decoded.Error == nil {
		t.Fatalf("expected structured error, got %s", response)
	}
}

func TestPrivateKeyPageNavigation(t *testing.T) {
	result, err := createKeys([]byte(`{"index":"1","coins":["ETH"],"count":4,"op":"next"}`))
	if err != nil {
		t.Fatal(err)
	}
	if result.Index != "5" {
		t.Fatalf("expected next page at 5, got %s", result.Index)
	}

	result, err = createKeys([]byte(`{"index":"1","coins":["ETH"],"count":4,"op":"previous"}`))
	if err != nil {
		t.Fatal(err)
	}
	if result.Index != "1" {
		t.Fatalf("expected previous page to clamp at 1, got %s", result.Index)
	}
}

func TestCreateMnemonicAtZero(t *testing.T) {
	result, err := createMnemonic([]byte(`{"bitSize":128,"count":1,"coins":["ETH"],"index":"0","op":"current"}`))
	if err != nil {
		t.Fatal(err)
	}
	if result.Mnemonic != "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about" {
		t.Fatalf("unexpected mnemonic: %s", result.Mnemonic)
	}
	if len(result.Items) != 1 {
		t.Fatalf("expected one address, got %d", len(result.Items))
	}
}

func TestMnemonicSearchRejectsUnknownWord(t *testing.T) {
	_, err := createMnemonic([]byte(`{"bitSize":128,"count":1,"coins":["BTC"],"index":"notaword","op":"search"}`))
	if err == nil {
		t.Fatal("expected unknown word to be rejected")
	}
}

func TestCreateElectrumAtZero(t *testing.T) {
	result, err := createElectrum([]byte(`{"count":1,"addressType":"standard","index":"0","op":"current"}`))
	if err != nil {
		t.Fatal(err)
	}
	if result.Mnemonic == "" || len(result.Items) != 1 {
		t.Fatalf("expected mnemonic and one address: %#v", result)
	}
}

// Official BIP84/BIP86 vectors: https://github.com/bitcoin/bips
func TestMnemonicStandardBTCPathsAndAddressWindows(t *testing.T) {
	cases := []struct {
		kind, preset  string
		start         int
		path, address string
	}{
		{"segwit", "receive", 0, "m/84'/0'/0'/0/0", "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"},
		{"segwit", "receive", 1, "m/84'/0'/0'/0/1", "bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g"},
		{"segwit", "change", 0, "m/84'/0'/0'/1/0", "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el"},
		{"taproot", "receive", 0, "m/86'/0'/0'/0/0", "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"},
		{"taproot", "change", 0, "m/86'/0'/0'/1/0", "bc1p3qkhfews2uk44qtvauqyr2ttdsw7svhkl9nkm9s9c3x4ax5h60wqwruhk7"},
	}
	for _, tc := range cases {
		raw, _ := json.Marshal(map[string]interface{}{"bitSize": 128, "count": 1, "coins": []string{"BTC"}, "index": "0", "op": "current", "addressStart": tc.start, "btcType": tc.kind, "pathPreset": tc.preset})
		result, err := createMnemonic(raw)
		if err != nil {
			t.Fatal(err)
		}
		if len(result.Items) != 1 || result.Items[0].Path != tc.path || result.Items[0].Addr != tc.address {
			t.Fatalf("%s %s start %d: unexpected derivation: %+v", tc.kind, tc.preset, tc.start, result.Items)
		}
	}
}

func TestMnemonicPaginationPreservesSeedAndOtherChains(t *testing.T) {
	first, err := createMnemonic([]byte(`{"bitSize":128,"count":3,"coins":["ETH","BSC","SOL","LTC"],"index":"0","op":"current"}`))
	if err != nil {
		t.Fatal(err)
	}
	second, err := createMnemonic([]byte(`{"bitSize":128,"count":2,"coins":["ETH","BSC","SOL","LTC"],"index":"0","op":"current","addressStart":1}`))
	if err != nil {
		t.Fatal(err)
	}
	if first.Mnemonic != second.Mnemonic || first.Index != second.Index {
		t.Fatal("Address window changed mnemonic")
	}
	// Fixed public zero-entropy sample, using the existing standard receive paths.
	for _, item := range first.Items {
		if item.Path == "m/44'/60'/0'/0/0" && item.Addr != "0x9858EfFD232B4033E47d90003D41EC34EcaEda94" {
			t.Fatalf("Ethereum standard receive address changed: %s", item.Addr)
		}
		if item.Coin == "SOL" && item.Path == "m/44'/501'/0'/0'" && item.Addr != "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk" {
			t.Fatalf("Solana standard receive address changed: %s", item.Addr)
		}
	}
	for _, got := range second.Items {
		found := false
		for _, original := range first.Items {
			if original.Coin == got.Coin && original.Path == got.Path && original.Addr == got.Addr {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("Address window mismatch for %s %s", got.Coin, got.Path)
		}
	}
	if second.Items[len(second.Items)-2].Path != "m/44'/501'/1'/0'" {
		t.Fatal("SOL must retain hardened account path")
	}
	changed, err := createMnemonic([]byte(`{"bitSize":128,"count":1,"coins":["BTC","ETH","SOL","LTC","DOGE","TRX"],"index":"0","op":"current","btcType":"legacy","pathPreset":"change"}`))
	if err != nil {
		t.Fatal(err)
	}
	for _, got := range changed.Items {
		if got.Coin == "BTC" || got.Coin == "LTC" || got.Coin == "DOGE" {
			if !strings.Contains(got.Path, "/0'/1/0") {
				t.Fatalf("Expected change branch: %s", got.Path)
			}
		} else if got.Coin != "SOL" && !strings.Contains(got.Path, "/0'/0/0") {
			t.Fatalf("Unexpected change branch: %s", got.Path)
		}
	}
}

func TestMnemonicRejectsInvalidDerivationBoundsAndPresets(t *testing.T) {
	for _, fields := range []string{
		`"addressStart":-1`, `"addressStart":2147483647`, `"addressStart":9223372036854775807`,
		`"btcType":"invalid"`, `"pathPreset":"invalid"`,
	} {
		_, err := createMnemonic([]byte(`{"bitSize":128,"count":2,"coins":["BTC"],"index":"0","op":"current",` + fields + `}`))
		if err == nil {
			t.Fatalf("Expected invalid request: %s", fields)
		}
	}
	result, err := createMnemonic([]byte(`{"bitSize":128,"count":1,"coins":["ETH"],"index":"0","op":"current","addressStart":2147483647}`))
	if err != nil || len(result.Items) != 1 {
		t.Fatalf("Last non-hardened index rejected: %v", err)
	}
}

func TestPrivateKeyInputFormatsAndValidation(t *testing.T) {
	scalar := make([]byte, 32)
	scalar[31] = 1
	for _, compressed := range []bool{false, true} {
		payload := append([]byte{}, scalar...)
		if compressed {
			payload = append(payload, 1)
		}
		wif := base58.CheckEncode(payload, 0x80)
		raw, _ := json.Marshal(createKeysRequest{Index: wif, Coins: []string{"BTC"}, Count: 1})
		result, err := createKeys(raw)
		if err != nil {
			t.Fatal(err)
		}
		if result.Index != "1" || result.InputFormat != "WIF" || result.WIFCompressed == nil || *result.WIFCompressed != compressed {
			t.Fatal("WIF normalization mismatch")
		}
		want := "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH"
		if !compressed {
			want = "1EHNa6Q4Jz2uvNExL497mE43ikXhwF6kZm"
		}
		found := false
		for _, item := range result.Items {
			if item.Addr == want {
				found = true
			}
		}
		if !found {
			t.Fatal("Known WIF address missing")
		}
	}
	for _, input := range []string{"1", " 0X01 ", strings.Repeat("0", 63) + "1"} {
		value, format, _, err := parsePrivateKey(input)
		if err != nil || value.Cmp(big.NewInt(1)) != 0 || format != "HEX" {
			t.Fatalf("HEX input rejected: %v", err)
		}
	}
	invalid := []string{"", "0", "-1", "+1", "xyz", "0x", strings.Repeat("f", 64), strings.Repeat("0", 65) + "1",
		base58.CheckEncode(scalar, 0xef), base58.CheckEncode(scalar[:31], 0x80),
		base58.CheckEncode(append(append([]byte{}, scalar...), 2), 0x80),
		base58.CheckEncode(make([]byte, 32), 0x80), base58.CheckEncode(new(big.Int).Add(secp256k1Max, big.NewInt(1)).Bytes(), 0x80)}
	wif := base58.CheckEncode(scalar, 0x80)
	last := "1"
	if strings.HasSuffix(wif, "1") {
		last = "2"
	}
	invalid = append(invalid, wif[:len(wif)-1]+last)
	for _, input := range invalid {
		if _, _, _, err := parsePrivateKey(input); err == nil {
			t.Errorf("Invalid private key accepted")
		}
	}
}

func TestPrivateKeyBTCTypeFiltersKeepOtherCoinsAndPageSize(t *testing.T) {
	kinds := map[string]string{"legacy": "Legacy(c)", "legacyUncompressed": "Legacy(u)", "segwit": "SegWit(c)", "nested": "NestedSegWit(c)", "taproot": "Taproot"}
	for kind, tag := range kinds {
		raw, _ := json.Marshal(createKeysRequest{Index: "1", Count: 2, Coins: []string{"BTC", "ETH"}, BTCType: kind, Op: "next"})
		result, err := createKeys(raw)
		if err != nil {
			t.Fatal(err)
		}
		if result.Index != "3" || len(result.Items) != 4 {
			t.Fatalf("Unexpected page for %s", kind)
		}
		for _, item := range result.Items {
			if item.Coin == "BTC" && item.AddrTag != tag {
				t.Fatalf("Incorrect filter %s", kind)
			}
		}
	}
	if _, err := createKeys([]byte(`{"index":"1","count":1,"coins":["BTC"],"btcType":"bad"}`)); err == nil {
		t.Fatal("Invalid BTC filter accepted")
	}
}

func TestMnemonicPrivateKeyFormatMetadata(t *testing.T) {
	result, err := createMnemonic([]byte(`{"index":"0","count":1,"bitSize":128,"coins":["BTC","LTC","DOGE","SOL","ETH"]}`))
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range result.Items {
		want := "hex"
		if item.Coin == "BTC" || item.Coin == "LTC" || item.Coin == "DOGE" {
			want = "wif"
		}
		if item.Coin == "SOL" {
			want = "base58"
		}
		if item.KeyFormat != want {
			t.Fatalf("Wrong format for %s", item.Coin)
		}
	}
	electrum, err := createElectrum([]byte(`{"index":"0","count":1,"addressType":"all"}`))
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range electrum.Items {
		if item.KeyFormat != "wif" {
			t.Fatal("Electrum WIF mislabeled")
		}
	}
}
