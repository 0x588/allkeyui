package base

import (
	"allkeyui/nativecore/Core/hdwallet"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"testing"

	"allkeyui/nativecore/Core/electrum"

	"github.com/davecgh/go-spew/spew"
	"github.com/tyler-smith/go-bip39"
	"github.com/tyler-smith/go-bip39/wordlists"
)

func TestBip39(t *testing.T) {
	//mnemonicPre := "patient board palm abandon right sort find blood grace sweet vote"
	b := big.NewInt(0).Lsh(big.NewInt(1), 128)
	b = b.Sub(b, big.NewInt(1))
	fmt.Println(b.String())
	fmt.Println(b.Bytes())
	b = big.NewInt(0)
	b.SetBits([]big.Word{
		0x01000001, 0x00000000, 0x00000000, 0xFF000001,
	})
	//b.Sub(b, big.NewInt(10000))
	fmt.Println(b)
	a := b.Bytes()
	fmt.Println(a)
	b.SetBit(b, 0, 1)
	b.SetBit(b, 120, 0)
	a = b.Bytes()
	fmt.Println(a)

	a = make([]byte, 16)
	a[15] = 255
	fmt.Println(a)
	fmt.Println(len(a))
	m, err := bip39.NewMnemonic(a)
	fmt.Println(m, err)

}

func TestGetMneAtIndex(t *testing.T) {
	bitSize := 128
	index := big.NewInt(1)
	pathCnt := 1
	mne, err := GetMneAtIndex(bitSize, index, uint32(pathCnt), []string{"ETH", "SOL"})
	fmt.Println(mne.Zjc)
	js, err := json.Marshal(mne)
	fmt.Println(string(js), err)
}

func TestGetElectrumMneAtIndex(t *testing.T) {
	index, _ := rand.Int(rand.Reader, MaxIndex(136))
	mne, err := GetElectrumMneAtIndex(index, 5, "segwit")
	spew.Dump(mne, err)
}

func TestGetElectrumIndex(t *testing.T) {
	mne := "pride output humor kiwi seat weird hood fatigue thing trend"
	index, err := electrum.Decode(mne, wordlists.English)
	fmt.Println(index, err)
}

func TestGetIndex(t *testing.T) {
	bitSize := 128
	mne := "upset come scissors lumber movie boring blush master absurd height aware crew"
	index, err := GetIndexLeft(mne, bitSize)
	fmt.Println(index, err)
	mne = "upset come scissors lumber movie boring blush master absurd height aware"
	index, err = GetIndexLeft(mne, bitSize)
	fmt.Println(index, err)
	mne = "upset come scissors lumber movie boring blush master absurd height"
	index, err = GetIndexLeft(mne, bitSize)
	fmt.Println(index, err)
	mne = "upset come"
	index, err = GetIndexLeft(mne, bitSize)
	fmt.Println(index, err)
	ret, err := GetMneAtIndex(bitSize, index, uint32(1), []string{"ETH", "SOL"})
	fmt.Println(ret, err)
}

func TestToken(t *testing.T) {
	//b := big.NewInt(0).Lsh(big.NewInt(1), 256)
	//b = b.Sub(b, big.NewInt(2303))
	b := big.NewInt(123023121232)
	//index := b.Bytes()
	//a := make([]byte, 34)
	//a[0] = 1
	//a[1] = 3
	//copy(a[2:], index)
	//fmt.Println(a)
	//res, err := aes.AesCtrEncryptBase64(a, []byte("@copyrightsaodi1"), nil)
	//fmt.Println(res, err)
	//
	//r, err := aes.AesCtrDecryptByBase64(res, []byte("@copyrightsaodi1"), nil)
	//fmt.Println(r, err)
	fmt.Println(b.Bytes())
	res := CreateToken(b, 0)
	fmt.Println(res)
	fmt.Println(b.Bytes())
	res = CreateToken(b, 0)
	fmt.Println(res)

	r, l, err := GetIndexWithToken(res)
	fmt.Println(r.Bytes(), l, err)
}

func TestMnemonicPassphraseUsesOfficialSeedAndNFKD(t *testing.T) {
	// BIP39 / trezor/python-mnemonic English zero-entropy vector with passphrase TREZOR.
	seed, err := hex.DecodeString("c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04")
	if err != nil {
		t.Fatal(err)
	}
	master, err := hdwallet.NewKey(hdwallet.Seed(seed))
	if err != nil {
		t.Fatal(err)
	}
	wallet, err := master.GetWallet(hdwallet.CoinType(hdwallet.ETH), hdwallet.Path("m/44'/60'/0'/0/0"))
	if err != nil {
		t.Fatal(err)
	}
	expected, err := wallet.GetAddress()
	if err != nil {
		t.Fatal(err)
	}
	derive := func(password string) *MneRes {
		result, err := GetMneAtIndexWithOptions(128, big.NewInt(0), 1, []string{ETH}, MnemonicDerivation{Passphrase: password})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	if derive("TREZOR").List[0].Addr != expected {
		t.Fatal("BIP39 official seed mismatch")
	}
	if derive("é").List[0].Addr != derive("e\u0301").List[0].Addr {
		t.Fatal("Passphrase must use NFKD")
	}
	if derive("TREZOR").List[0].Addr == derive("trezor").List[0].Addr || derive("x").List[0].Addr == derive(" x").List[0].Addr {
		t.Fatal("Passphrase case/whitespace must be preserved")
	}
}
