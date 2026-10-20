package main

import (
	"encoding/json"
	"math/big"
	"strings"
	"testing"
)

func mnemonicFromFields(t *testing.T, fields map[string]interface{}) (mnemonicResult, error) {
	t.Helper()
	for k, v := range map[string]interface{}{"bitSize": 128, "count": 1, "coins": []string{"BTC"}, "index": "0", "op": "current"} {
		if _, ok := fields[k]; !ok {
			fields[k] = v
		}
	}
	raw, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	return createMnemonic(raw)
}

func TestEntropyJumpIsStrictAndCoversEachWordCount(t *testing.T) {
	for _, bits := range []int{128, 160, 192, 224, 256} {
		maximum := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), uint(bits)), big.NewInt(1)).String()
		got, err := mnemonicFromFields(t, map[string]interface{}{"op": "jump", "bitSize": bits, "index": maximum})
		if err != nil || got.Index != maximum {
			t.Fatalf("Last entropy %d rejected: %v", bits, err)
		}
		for _, input := range []string{"-1", "+1", "0x1", "1.1", "1e3", new(big.Int).Lsh(big.NewInt(1), uint(bits)).String()} {
			if _, err := mnemonicFromFields(t, map[string]interface{}{"op": "jump", "bitSize": bits, "index": input}); err == nil {
				t.Fatal("Out-of-range or malformed entropy accepted")
			}
		}
	}
}

func TestCustomPathsMatchStandardVectorsAndAddressWindows(t *testing.T) {
	cases := []struct{ coin, kind, path string }{
		{"BTC", "segwit", "m/84'/0'/0'/0/{index}"}, {"BTC", "taproot", "m/86'/0'/0'/0/{index}"},
		{"BTC", "nested", "m/49'/0'/0'/0/{index}"}, {"LTC", "all", "m/44'/2'/0'/0/{index}"},
		{"DOGE", "all", "m/44'/3'/0'/0/{index}"}, {"ETH", "all", "m/44'/60'/0'/0/{index}"},
		{"BSC", "all", "m/44'/60'/0'/0/{index}"}, {"TRX", "all", "m/44'/195'/0'/0/{index}"},
		{"SOL", "all", "m/44'/501'/{index}'/0'"},
	}
	for _, tc := range cases {
		standard, err := mnemonicFromFields(t, map[string]interface{}{"coins": []string{tc.coin}, "btcType": tc.kind, "addressStart": 2, "count": 2})
		if err != nil {
			t.Fatal(err)
		}
		custom, err := mnemonicFromFields(t, map[string]interface{}{"coins": []string{tc.coin}, "btcType": tc.kind, "addressStart": 2, "count": 2, "customPath": tc.path, "account": 123, "pathPreset": "change"})
		if err != nil {
			t.Fatal(err)
		}
		if len(custom.Items) != 2 {
			t.Fatal("Incorrect custom address window")
		}
		for i, item := range custom.Items {
			if item.Path != standard.Items[i].Path || item.Addr != standard.Items[i].Addr || item.HexKey != standard.Items[i].HexKey {
				t.Fatalf("Custom %s diverges from standard vector", tc.coin)
			}
		}
	}
	// Exact path overrides the standard BSC -> ETH coin-path alias.
	eth, err := mnemonicFromFields(t, map[string]interface{}{"coins": []string{"ETH"}, "customPath": "m/44'/714'/0'/0/{index}"})
	if err != nil {
		t.Fatal(err)
	}
	bsc, err := mnemonicFromFields(t, map[string]interface{}{"coins": []string{"BSC"}, "customPath": "m/44'/714'/0'/0/{index}"})
	if err != nil {
		t.Fatal(err)
	}
	if eth.Items[0].Addr != bsc.Items[0].Addr {
		t.Fatal("Custom path was rewritten")
	}
}

func TestInvalidCustomPathsNeverFallBack(t *testing.T) {
	for _, path := range []string{"m/44'/0'/0'/0/0", "m//{index}", "m/+1/{index}", "m/2147483648/{index}", "m/{index}/{index}", "m/{index}h", "m/-1/{index}", "M/{index}", "m/1.1/{index}", "m/" + strings.Repeat("0/", 10) + "{index}", strings.Repeat("x", 256)} {
		if _, err := mnemonicFromFields(t, map[string]interface{}{"customPath": path}); err == nil {
			t.Fatalf("Invalid path accepted: %s", path)
		}
	}
	if _, err := mnemonicFromFields(t, map[string]interface{}{"customPath": "m/44'/501'/{index}/0'", "coins": []string{"SOL"}}); err == nil {
		t.Fatal("Non-hardened SOL path accepted")
	}
	if _, err := mnemonicFromFields(t, map[string]interface{}{"customPath": "m/{index}", "coins": []string{"BTC", "ETH"}}); err == nil {
		t.Fatal("Multi-coin custom path accepted")
	}
	for _, coin := range []string{"BTC", "SOL"} {
		path := "m/44'/0'/0'/0/{index}"
		if coin == "SOL" {
			path = "m/44'/501'/{index}'/0'"
		}
		if _, err := mnemonicFromFields(t, map[string]interface{}{"coins": []string{coin}, "customPath": path, "addressStart": 2147483647}); err != nil {
			t.Fatal(err)
		}
	}
}

func TestKnownAddressMatchingRespectsCoinTypeAndWindow(t *testing.T) {
	for _, coin := range []string{"BTC", "ETH", "BSC", "LTC", "DOGE", "TRX", "SOL"} {
		source, err := mnemonicFromFields(t, map[string]interface{}{"coins": []string{coin}, "btcType": "segwit", "addressStart": 3})
		if err != nil {
			t.Fatal(err)
		}
		target := source.Items[0].Addr
		if coin == "ETH" || coin == "BSC" || coin == "BTC" {
			target = strings.ToUpper(target)
			if strings.HasPrefix(target, "0X") {
				target = "0x" + target[2:]
			}
		}
		matched, err := mnemonicFromFields(t, map[string]interface{}{"coins": []string{coin}, "btcType": "segwit", "addressStart": 2, "count": 2, "targetAddress": target, "targetCoin": coin})
		if err != nil || matched.MatchedItem == nil || matched.MatchedItem.Path != source.Items[0].Path {
			t.Fatalf("%s match failed: %v", coin, err)
		}
		outside, err := mnemonicFromFields(t, map[string]interface{}{"coins": []string{coin}, "btcType": "segwit", "addressStart": 0, "targetAddress": target, "targetCoin": coin})
		if err != nil || outside.MatchedItem != nil {
			t.Fatalf("Matched outside address window: %s", coin)
		}
	}
	wrongType, err := mnemonicFromFields(t, map[string]interface{}{"btcType": "legacy", "targetCoin": "BTC", "targetAddress": "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"})
	if err != nil || wrongType.MatchedItem != nil {
		t.Fatal("BTC type filter ignored")
	}
	for _, target := range []struct{ coin, address string }{{"BTC", "mipcBbFg9gMiCh81Kj8tqqdgoZub1ZJRfn"}, {"ETH", "0x123"}, {"SOL", "abc"}, {"TRX", "invalid"}, {"BTC", "invalid"}} {
		if _, err := mnemonicFromFields(t, map[string]interface{}{"targetAddress": target.address, "targetCoin": target.coin, "coins": []string{target.coin}}); err == nil {
			t.Fatal("Invalid target address accepted")
		}
	}
}
