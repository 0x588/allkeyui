package base

import (
	"encoding/json"
	"fmt"
	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcutil"
	"github.com/btcsuite/btcd/chaincfg"
	"math/big"
	"testing"
)

func TestCreateBtc2AddrWithKey(t *testing.T) {
	b := FromHex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140")
	prvKey, _ := btcec.PrivKeyFromBytes(b.Bytes())
	pkHash := btcutil.Hash160(prvKey.PubKey().SerializeUncompressed())
	cfg := &chaincfg.MainNetParams
	cfg.PubKeyHashAddrID = 0x1e // 30
	cfg.ScriptHashAddrID = 0x16 // 22
	cfg.PrivateKeyID = 0x9e     // 158
	r, err := btcutil.NewAddressPubKeyHash(pkHash, cfg)
	fmt.Println(r.EncodeAddress(), err)
}

func TestCreateBtcAddrWithKey(t *testing.T) {
	b := FromHex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140")
	r, err := CreateBtcAddrWithKey(b.Bytes())
	s, err := json.MarshalIndent(r, "  ", " ")
	fmt.Println(string(s), err)
}

func TestCreateEthAddrWithKey(t *testing.T) {
	b := FromHex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140")
	r, err := CreateEthAddrWithKey(b.Bytes(), "ETH")
	s, err := json.MarshalIndent(r, "  ", " ")
	fmt.Println(string(s), err)
}

func TestCreateTRXAddrWithKey(t *testing.T) {
	b := FromHex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140")
	r, err := CreateTrxAddrWithKey(b.Bytes())
	s, err := json.MarshalIndent(r, "  ", " ")
	fmt.Println(string(s), err)
}

func TestCreateLtcAddrWithKey(t *testing.T) {
	b := FromHex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140")
	r, err := CreateLtcAddrWithKey(b.Bytes())
	s, err := json.MarshalIndent(r, "  ", " ")
	fmt.Println(string(s), err)
}

func TestCreateDogeAddrWithKey(t *testing.T) {
	b := FromHex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140")
	r, err := CreateDogeAddrWithKey(b.Bytes())
	s, err := json.MarshalIndent(r, "  ", " ")
	fmt.Println(string(s), err)
}

func TestSolAddrWithKey(t *testing.T) {
	b := FromHex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")
	r, err := CreateSolAddrWithKey(b.Bytes())
	s, err := json.MarshalIndent(r, "  ", " ")
	fmt.Println(string(s), err)
}

func TestCreateKeys(t *testing.T) {
	b := big.NewInt(1)
	r, err := CreateKeys(b, []string{"BTC", "ETH", "TRX", "LTC", "DOGE", "SOL"})
	s, err := json.MarshalIndent(r, "  ", " ")
	fmt.Println(string(s), err)
}
