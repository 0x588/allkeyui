package electrum

import (
	"errors"
	"fmt"

	"github.com/btcsuite/btcd/btcutil"
	"github.com/btcsuite/btcd/btcutil/hdkeychain"
	"github.com/btcsuite/btcd/chaincfg"
)

func GenerateAddress(mnemonic string, prefix string) ([]string, error) {
	seedOpts := &SeedOptions{
		Passphrase: "",
		Prefix:     prefix,
	}

	seed, err := MnemonicToSeed(mnemonic, seedOpts)
	if err != nil {
		return nil, err
	}

	masterKey, err := hdkeychain.NewMaster(seed, &chaincfg.MainNetParams)
	if err != nil {
		return nil, err
	}

	derivePath := []uint32{
		0 + hdkeychain.HardenedKeyStart, // coin type (BTC)
		0,                               // change
		0,                               // address index
	}
	if prefix == Prefixes["standard"] {
		derivePath = []uint32{
			0,
			0,
		}
	}

	key := masterKey
	for _, childNum := range derivePath {
		key, err = key.Derive(childNum)
		if err != nil {
			return nil, fmt.Errorf("派生密钥失败: %v", err)
		}
	}

	// 3. 获取 ECPrivKey
	privKey, err := key.ECPrivKey()
	if err != nil {
		return nil, fmt.Errorf("获取私钥失败: %v", err)
	}
	if prefix == Prefixes["segwit"] {
		witnessAddr, err := btcutil.NewAddressWitnessPubKeyHash(
			btcutil.Hash160(privKey.PubKey().SerializeCompressed()),
			&chaincfg.MainNetParams,
		)
		if err != nil {
			return nil, fmt.Errorf("生成地址失败: %v", err)
		}
		return []string{witnessAddr.EncodeAddress()}, nil
	} else if prefix == Prefixes["standard"] {
		p2pkhAddr, err := btcutil.NewAddressPubKeyHash(
			btcutil.Hash160(privKey.PubKey().SerializeCompressed()),
			&chaincfg.MainNetParams,
		)
		if err != nil {
			return nil, fmt.Errorf("生成地址失败: %v", err)
		}
		return []string{p2pkhAddr.EncodeAddress()}, nil
	}
	return nil, errors.New("不支持的前缀")
}
