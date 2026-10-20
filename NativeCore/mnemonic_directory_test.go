package main

import (
	"encoding/json"
	"math/big"
	"strings"
	"testing"
)

func directory(t *testing.T, index, op string, size, bits int) (mnemonicPageResult, error) {
	t.Helper()
	raw, _ := json.Marshal(mnemonicPageRequest{mnemonicRequest: mnemonicRequest{BitSize: bits, Index: index, Op: op, Coins: []string{"ETH"}}, PageSize: size})
	return createMnemonicPage(raw)
}

func TestMnemonicDirectoryPageNavigationAndCanonicalSeed(t *testing.T) {
	first, err := directory(t, "0", "first", 10, 128)
	if err != nil {
		t.Fatal(err)
	}
	if first.Start != "0" || first.End != "9" || first.HasPrevious || !first.HasNext || len(first.Items) != 10 {
		t.Fatal("Incorrect first page")
	}
	if first.Items[0].Mnemonic != strings.Repeat("abandon ", 11)+"about" || first.Items[0].Items[0].Addr != "0x9858EfFD232B4033E47d90003D41EC34EcaEda94" {
		t.Fatal("Canonical directory entry changed")
	}
	next, err := directory(t, first.Start, "next", 10, 128)
	if err != nil {
		t.Fatal(err)
	}
	if next.Start != "10" || next.End != "19" {
		t.Fatal("Pages overlap or skip")
	}
	previous, err := directory(t, next.Start, "previous", 10, 128)
	if err != nil || previous.Start != "0" {
		t.Fatal("Previous page failed")
	}
	for i, item := range next.Items {
		if item.Index != big.NewInt(int64(10+i)).String() || len(item.Items) != 1 {
			t.Fatal("Unexpected per-entry range")
		}
	}
}

func TestMnemonicDirectoryLastPageJumpAndAllWordCounts(t *testing.T) {
	for _, bits := range []int{128, 160, 192, 224, 256} {
		last, err := directory(t, "0", "last", 20, bits)
		if err != nil {
			t.Fatal(err)
		}
		if last.End != last.Max || last.HasNext || !last.HasPrevious || len(last.Items) < 1 || len(last.Items) > 20 {
			t.Fatal("Incorrect last page")
		}
		exact, err := directory(t, last.Max, "jump", 10, bits)
		if err != nil || len(exact.Items) != 1 || exact.HasNext || exact.End != last.Max {
			t.Fatal("Jump at entropy maximum failed")
		}
		if len(strings.Fields(exact.Items[0].Mnemonic)) != bits/32*3 {
			t.Fatal("Incorrect mnemonic length")
		}
		if _, err := directory(t, last.Start, "next", 20, bits); err == nil {
			t.Fatal("Past-end navigation accepted")
		}
		random, err := directory(t, "0", "random", 10, bits)
		if err != nil || len(random.Items) == 0 {
			t.Fatal("Random page failed")
		}
		ordinal, _ := new(big.Int).SetString(random.Start, 10)
		if new(big.Int).Mod(ordinal, big.NewInt(10)).Sign() != 0 {
			t.Fatal("Random page not aligned")
		}
	}
	for _, tc := range []struct {
		input      string
		size, bits int
	}{{"-1", 10, 128}, {"0x1", 10, 128}, {"0", 21, 128}, {"0", 0, 128}, {"0", 10, 120}} {
		if _, err := directory(t, tc.input, "jump", tc.size, tc.bits); err == nil {
			t.Fatal("Invalid directory request accepted")
		}
	}
}
