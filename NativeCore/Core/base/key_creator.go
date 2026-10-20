package base

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcec/v2/schnorr"
	"github.com/btcsuite/btcd/btcutil"
	"github.com/btcsuite/btcd/btcutil/base58"
	"github.com/btcsuite/btcd/chaincfg"
	"github.com/btcsuite/btcd/txscript"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/fbsobreira/gotron-sdk/pkg/address"
	"math/big"
)

var LTCParams = chaincfg.MainNetParams
var DOGEParams = chaincfg.MainNetParams

func FromHex(s string) *big.Int {
	if s == "" {
		return big.NewInt(0)
	}
	r, ok := new(big.Int).SetString(s, 16)
	if !ok {
		panic("invalid hex in source file: " + s)
	}
	return r
}

func CreateBtcLegacy(priKey *btcec.PrivateKey, compress bool) (*AddrItem, error) {
	btcWif, err := btcutil.NewWIF(priKey, &chaincfg.MainNetParams, compress)
	if err != nil {
		return nil, err
	}
	pubKey := btcWif.SerializePubKey()
	addrPubKey, err := btcutil.NewAddressPubKey(pubKey, &chaincfg.MainNetParams)
	if err != nil {
		return nil, err
	}
	addr := addrPubKey.EncodeAddress()
	AddrTag := "Legacy(c)"
	if !compress {
		AddrTag = "Legacy(u)"
	}
	return &AddrItem{
		Coin:    "BTC",
		Addr:    addr,
		HexKey:  hex.EncodeToString(priKey.Serialize()),
		AddrTag: AddrTag,
		KeyTag:  btcWif.String(),
	}, nil
}

func CreateBtcSegWit(priKey *btcec.PrivateKey, compress bool) (*AddrItem, error) {
	btcWif, err := btcutil.NewWIF(priKey, &chaincfg.MainNetParams, compress)
	if err != nil {
		return nil, err
	}
	pubKey := btcWif.SerializePubKey()
	witnessProg := btcutil.Hash160(pubKey)
	addrWitnessPubKey, err := btcutil.NewAddressWitnessPubKeyHash(witnessProg, &chaincfg.MainNetParams)
	if err != nil {
		return nil, err
	}
	addrWitness := addrWitnessPubKey.EncodeAddress()
	AddrTag := "SegWit(c)"
	if !compress {
		AddrTag = "SegWit(u)"
	}
	return &AddrItem{
		Coin:    "BTC",
		Addr:    addrWitness,
		HexKey:  hex.EncodeToString(priKey.Serialize()),
		AddrTag: AddrTag,
		KeyTag:  btcWif.String(),
	}, nil
}

func CreateBtcNestedSegWit(priKey *btcec.PrivateKey, compress bool) (*AddrItem, error) {
	btcWif, err := btcutil.NewWIF(priKey, &chaincfg.MainNetParams, compress)
	if err != nil {
		return nil, err
	}
	pubKey := btcWif.SerializePubKey()
	witnessProg := btcutil.Hash160(pubKey)
	addrWitnessPubKey, err := btcutil.NewAddressWitnessPubKeyHash(witnessProg, &chaincfg.MainNetParams)
	if err != nil {
		return nil, err
	}
	serializedScript, err := txscript.PayToAddrScript(addrWitnessPubKey)
	if err != nil {
		return nil, err
	}
	addrP2SH, err := btcutil.NewAddressScriptHash(serializedScript, &chaincfg.MainNetParams)
	if err != nil {
		return nil, err
	}
	segWitNested := addrP2SH.EncodeAddress()
	AddrTag := "NestedSegWit(c)"
	if !compress {
		AddrTag = "NestedSegWit(u)"
	}
	return &AddrItem{
		Coin:    "BTC",
		Addr:    segWitNested,
		HexKey:  hex.EncodeToString(priKey.Serialize()),
		AddrTag: AddrTag,
		KeyTag:  btcWif.String(),
	}, nil
}

func CreateBtcTaproot(priKey *btcec.PrivateKey) (*AddrItem, error) {
	tapKey := txscript.ComputeTaprootKeyNoScript(priKey.PubKey())
	t := schnorr.SerializePubKey(tapKey)
	taproot, err := btcutil.NewAddressTaproot(t, &chaincfg.MainNetParams)
	if err != nil {
		return nil, err
	}
	tapAddress := taproot.EncodeAddress()
	return &AddrItem{
		Coin:    "BTC",
		Addr:    tapAddress,
		HexKey:  hex.EncodeToString(priKey.Serialize()),
		AddrTag: "Taproot",
	}, nil
}

func CreateBtcAddrWithKey(key []byte) ([]*AddrItem, error) {
	res := make([]*AddrItem, 0)
	prvKey, _ := btcec.PrivKeyFromBytes(key)
	legacy, err := CreateBtcLegacy(prvKey, true)
	if err == nil {
		res = append(res, legacy)
	}
	segWit, err := CreateBtcSegWit(prvKey, true)
	if err == nil {
		res = append(res, segWit)
	}
	nestedSegWit, err := CreateBtcNestedSegWit(prvKey, true)
	if err == nil {
		res = append(res, nestedSegWit)
	}
	legacy, err = CreateBtcLegacy(prvKey, false)
	if err == nil {
		res = append(res, legacy)
	}
	//segWit, err = CreateBtcSegWit(prvKey, false)
	//if err == nil {
	//	res = append(res, segWit)
	//}
	//nestedSegWit, err = CreateBtcNestedSegWit(prvKey, false)
	//if err == nil {
	//	res = append(res, nestedSegWit)
	//}
	taproot, err := CreateBtcTaproot(prvKey)
	if err == nil {
		res = append(res, taproot)
	}
	return res, nil
}

func CreateEthAddrWithKey(key []byte, coin string) (*AddrItem, error) {
	priKeyHex := hex.EncodeToString(key)
	priKey, err := crypto.HexToECDSA(priKeyHex)
	if err != nil {
		return nil, err
	}
	addr := crypto.PubkeyToAddress(priKey.PublicKey).Hex()
	return &AddrItem{
		Coin:   coin,
		Addr:   addr,
		HexKey: priKeyHex,
	}, nil
}

func CreateTrxAddrWithKey(key []byte) (*AddrItem, error) {
	priKeyHex := hex.EncodeToString(key)
	priKey, err := crypto.HexToECDSA(priKeyHex)
	if err != nil {
		return nil, err
	}
	addr := address.PubkeyToAddress(priKey.PublicKey)
	return &AddrItem{
		Coin:   "TRX",
		Addr:   addr.String(),
		HexKey: priKeyHex,
	}, nil
}

func CreateLtcAddrWithKey(key []byte) ([]*AddrItem, error) {
	res := make([]*AddrItem, 0)
	prvKey, _ := btcec.PrivKeyFromBytes(key)
	pkHash := btcutil.Hash160(prvKey.PubKey().SerializeUncompressed())
	cfg := &LTCParams
	cfg.Bech32HRPSegwit = "ltc"
	cfg.PubKeyHashAddrID = 0x30 // 48
	cfg.ScriptHashAddrID = 0x32 // 50
	cfg.PrivateKeyID = 0xb0     // 176
	r, err := btcutil.NewAddressPubKeyHash(pkHash, cfg)
	if err != nil {
		return nil, err
	}
	res = append(res, &AddrItem{
		Coin:    "LTC",
		Addr:    r.EncodeAddress(),
		HexKey:  hex.EncodeToString(key),
		AddrTag: "U",
	})

	pkHash = btcutil.Hash160(prvKey.PubKey().SerializeCompressed())
	r, err = btcutil.NewAddressPubKeyHash(pkHash, cfg)
	if err != nil {
		return res, err
	}
	res = append(res, &AddrItem{
		Coin:    "LTC",
		Addr:    r.EncodeAddress(),
		HexKey:  hex.EncodeToString(key),
		AddrTag: "C",
	})
	return res, nil
}

func CreateDogeAddrWithKey(key []byte) ([]*AddrItem, error) {
	res := make([]*AddrItem, 0)
	prvKey, _ := btcec.PrivKeyFromBytes(key)
	pkHash := btcutil.Hash160(prvKey.PubKey().SerializeUncompressed())
	cfg := &DOGEParams
	cfg.PubKeyHashAddrID = 0x1e // 30
	cfg.ScriptHashAddrID = 0x16 // 22
	cfg.PrivateKeyID = 0x9e     // 176
	r, err := btcutil.NewAddressPubKeyHash(pkHash, cfg)
	if err != nil {
		return nil, err
	}
	res = append(res, &AddrItem{
		Coin:    "DOGE",
		Addr:    r.EncodeAddress(),
		HexKey:  hex.EncodeToString(key),
		AddrTag: "U",
	})

	pkHash = btcutil.Hash160(prvKey.PubKey().SerializeCompressed())
	r, err = btcutil.NewAddressPubKeyHash(pkHash, cfg)
	if err != nil {
		return res, err
	}
	res = append(res, &AddrItem{
		Coin:    "DOGE",
		Addr:    r.EncodeAddress(),
		HexKey:  hex.EncodeToString(key),
		AddrTag: "C",
	})
	return res, nil
}

func CreateSolAddrWithKey(key []byte) (*AddrItem, error) {
	pubKey, priKey, err := ed25519.GenerateKey(bytes.NewReader(key))
	if err != nil {
		return nil, err
	}
	priKeyHex := base58.Encode(priKey)

	addr := base58.Encode(pubKey)
	return &AddrItem{
		Coin:   "SOL",
		HexKey: hex.EncodeToString(key),
		KeyTag: priKeyHex,
		Addr:   addr,
	}, nil
}

func CreateKeys(index *big.Int, selectedCoins []string) ([]*AddrItem, error) {
	bytes1 := make([]byte, 32)
	indexBytes := index.Bytes()
	if len(indexBytes) == 32 {
		bytes1 = indexBytes
	} else {
		copy(bytes1[32-len(indexBytes):], indexBytes)
	}
	res := make([]*AddrItem, 0)

	if contains(selectedCoins, "BTC") {
		r, err := CreateBtcAddrWithKey(bytes1)
		if err == nil {
			res = append(res, r...)
		}
	}
	if contains(selectedCoins, "ETH") {
		r, err := CreateEthAddrWithKey(bytes1, "ETH")
		if err == nil {
			res = append(res, r)
		}
	}
	if contains(selectedCoins, "BSC") {
		r, err := CreateEthAddrWithKey(bytes1, "BSC")
		if err == nil {
			res = append(res, r)
		}
	}
	if contains(selectedCoins, "TRX") {
		r, err := CreateTrxAddrWithKey(bytes1)
		if err == nil {
			res = append(res, r)
		}
	}
	if contains(selectedCoins, "LTC") {
		r, err := CreateLtcAddrWithKey(bytes1)
		if err == nil {
			res = append(res, r...)
		}
	}
	if contains(selectedCoins, "DOGE") {
		r, err := CreateDogeAddrWithKey(bytes1)
		if err == nil {
			res = append(res, r...)
		}
	}
	if contains(selectedCoins, "SOL") {
		r, err := CreateSolAddrWithKey(bytes1)
		//fmt.Println(r, err)
		if err == nil {
			res = append(res, r)
		}
	}
	return res, nil
}
