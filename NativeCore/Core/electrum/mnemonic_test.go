package electrum

import (
	"fmt"
	"math/big"
	"testing"

	"github.com/tyler-smith/go-bip39/wordlists"
)

func TestMnemonic(t *testing.T) {
	i := big.NewInt(0).Sub(MaxIndex(130), big.NewInt(1000))
	words, prefix, idx, err := GenerateMnemonicWithStart(i, "")
	fmt.Println(words, prefix, err, idx.String())
	ad, err := GenerateAddress(words, prefix)
	fmt.Println(ad, err)
}

func TestAddress(t *testing.T) {
	ad, err := GenerateAddress("various analyst scale spirit indicate canoe assist decorate shrug grace judge outdoor", Prefixes["segwit"])
	fmt.Println(ad, err)
}

func TestDecode(t *testing.T) {
	//words := "various analyst scale spirit indicate canoe assist decorate shrug grace judge outdoor"
	words := "various analyst scale spirit indicate canoe assist decorate shrug"
	idx, err := GetIndexFromMnemonic(words, wordlists.English)
	fmt.Println(err)
	fmt.Println(idx.String())
	r, r1, r3, e := GenerateMnemonicWithStart(idx, "")
	fmt.Println(r, r1, r3, e)
}
