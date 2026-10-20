package main

import (
	"encoding/json"
	"math/big"
	"os"
	"strings"
	"testing"

	"github.com/btcsuite/btcd/btcutil/base58"
)

func puzzleKeys(t *testing.T, number, count int, index, operation string) keyResult {
	t.Helper()
	raw, _ := json.Marshal(createKeysRequest{PuzzleNumber: number, Count: count, Index: index, Op: operation, Coins: []string{"ETH"}})
	result, err := createKeys(raw)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestPuzzleBoundsAndNavigation(t *testing.T) {
	// Puzzle 3 covers [4, 7]. A batch of three can start only at 4 or 5.
	cases := []struct{ index, op, want string }{
		{"4", "first", "4"}, {"4", "last", "5"}, {"4", "previous", "4"},
		{"4", "next", "5"}, {"5", "next", "5"}, {"5", "previous", "4"},
		{"7", "current", "5"},
	}
	for _, c := range cases {
		result := puzzleKeys(t, 3, 3, c.index, c.op)
		if result.Index != c.want {
			t.Fatalf("%s %s: got %s want %s", c.index, c.op, result.Index, c.want)
		}
		if len(result.Items) != 3 {
			t.Fatal("wrong batch length")
		}
		for _, item := range result.Items {
			key, ok := new(big.Int).SetString(item.HexKey, 16)
			if !ok || key.Cmp(big.NewInt(4)) < 0 || key.Cmp(big.NewInt(7)) > 0 {
				t.Fatal("escaped puzzle range")
			}
		}
	}
	for i := 0; i < 16; i++ {
		result := puzzleKeys(t, 3, 3, "4", "random")
		if result.Index != "4" && result.Index != "5" {
			t.Fatal("random escaped range")
		}
	}
	result := puzzleKeys(t, 1, 20, "1", "last")
	if result.Index != "1" || len(result.Items) != 1 {
		t.Fatal("single-key puzzle overflow")
	}
	high := puzzleKeys(t, 160, 1, "1", "last")
	if high.Index != strings.Repeat("f", 40) {
		t.Fatal("160-bit upper bound lost precision")
	}
	high = puzzleKeys(t, 160, 1, "1", "first")
	if high.Index != "8"+strings.Repeat("0", 39) {
		t.Fatal("160-bit lower bound lost precision")
	}
}

func TestPuzzleRejectsInvalidNumbersAndOutsideIndex(t *testing.T) {
	for _, number := range []int{-1, 161} {
		raw, _ := json.Marshal(createKeysRequest{PuzzleNumber: number, Count: 1, Index: "1", Coins: []string{"BTC"}})
		if _, err := createKeys(raw); err == nil {
			t.Fatal("accepted invalid puzzle")
		}
	}
	for _, index := range []string{"3", "8"} {
		raw, _ := json.Marshal(createKeysRequest{PuzzleNumber: 3, Count: 1, Index: index, Op: "current", Coins: []string{"BTC"}})
		if _, err := createKeys(raw); err == nil {
			t.Fatal("accepted index outside puzzle")
		}
	}
}

func TestPuzzleCatalogAddressesAndKnownKeys(t *testing.T) {
	raw, err := os.ReadFile("../AllKeyUI/Resources/btc-puzzles.json")
	if err != nil {
		t.Fatal(err)
	}
	var catalog struct {
		Puzzles []struct {
			ID      int    `json:"id"`
			Address string `json:"address"`
		} `json:"puzzles"`
	}
	if err = json.Unmarshal(raw, &catalog); err != nil {
		t.Fatal(err)
	}
	if len(catalog.Puzzles) != 160 {
		t.Fatal("incomplete catalog")
	}
	seen := map[string]bool{}
	for i, puzzle := range catalog.Puzzles {
		payload, version, decodeErr := base58.CheckDecode(puzzle.Address)
		if puzzle.ID != i+1 || decodeErr != nil || version != 0 || len(payload) != 20 || seen[puzzle.Address] {
			t.Fatalf("invalid catalog entry #%d", puzzle.ID)
		}
		seen[puzzle.Address] = true
	}
	for i, key := range []string{"1", "3", "7", "8", "15"} {
		raw, _ := json.Marshal(createKeysRequest{PuzzleNumber: i + 1, Count: 1, Index: key, Coins: []string{"BTC"}})
		result, err := createKeys(raw)
		if err != nil {
			t.Fatal(err)
		}
		matched := false
		for _, item := range result.Items {
			matched = matched || item.Addr == catalog.Puzzles[i].Address
		}
		if !matched {
			t.Fatalf("known key does not match puzzle %d", i+1)
		}
	}
}
