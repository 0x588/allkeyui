package main

import (
	"errors"
	"math/big"
	"strings"

	"github.com/btcsuite/btcd/btcutil"
	"github.com/btcsuite/btcd/btcutil/base58"
	"github.com/btcsuite/btcd/chaincfg"
	"github.com/ethereum/go-ethereum/common"
)

func containsCoin(coins []string, coin string) bool {
	for _, value := range coins {
		if value == coin {
			return true
		}
	}
	return false
}

func strictEntropyIndex(value string, bitSize int) (*big.Int, error) {
	value = strings.TrimSpace(value)
	if len(value) == 0 || len(value) > 78 {
		return nil, errors.New("请输入有效的十进制熵索引")
	}
	for _, c := range value {
		if c < '0' || c > '9' {
			return nil, errors.New("熵索引只支持非负十进制整数")
		}
	}
	index, ok := new(big.Int).SetString(value, 10)
	if !ok || index.BitLen() > bitSize {
		return nil, errors.New("熵索引超出当前助记词长度的范围")
	}
	return index, nil
}

// Match addresses locally using network-aware decoding. EVM addresses are
// case-insensitive; Base58 addresses retain case, and Bech32 canonicalizes case.
func canonicalMatchAddress(coin, input string) (string, error) {
	input = strings.TrimSpace(input)
	invalid := errors.New("目标公开地址格式或网络无效，请核对币种与主网地址")
	if len(input) == 0 || len(input) > 128 {
		return "", invalid
	}
	switch coin {
	case "ETH", "BSC":
		if !common.IsHexAddress(input) {
			return "", invalid
		}
		return strings.ToLower(common.HexToAddress(input).Hex()), nil
	case "TRX":
		payload, version, err := base58.CheckDecode(input)
		if err != nil || version != 0x41 || len(payload) != 20 {
			return "", invalid
		}
		return input, nil
	case "SOL":
		decoded := base58.Decode(input)
		if len(decoded) != 32 || base58.Encode(decoded) != input {
			return "", invalid
		}
		return input, nil
	case "BTC", "LTC", "DOGE":
		params := chaincfg.MainNetParams
		if coin == "LTC" {
			params.PubKeyHashAddrID = 0x30
			params.ScriptHashAddrID = 0x32
			params.Bech32HRPSegwit = "ltc"
		}
		if coin == "DOGE" {
			params.PubKeyHashAddrID = 0x1e
			params.ScriptHashAddrID = 0x16
			params.Bech32HRPSegwit = "doge"
		}
		address, err := btcutil.DecodeAddress(input, &params)
		if err != nil || !address.IsForNet(&params) {
			return "", invalid
		}
		return address.EncodeAddress(), nil
	}
	return "", invalid
}
