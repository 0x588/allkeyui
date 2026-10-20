package base

import (
	"fmt"
	"golang.org/x/text/unicode/norm"
	"math/big"
	"math/rand"
	"strings"

	"allkeyui/nativecore/Core/electrum"
	"allkeyui/nativecore/Core/hdwallet"

	"github.com/btcsuite/btcd/btcutil"
	"github.com/btcsuite/btcd/btcutil/hdkeychain"
	"github.com/btcsuite/btcd/chaincfg"
	"github.com/tyler-smith/go-bip39"
	"github.com/wumansgy/goEncrypt/aes"
)

// 助记词位数对应
// bit: 128，160，192，224，256
// byte: 16   20   24   28   32
//
//	12   15   18  21   24

func CheckBitSize(bitSize int) bool {
	if bitSize == 128 || bitSize == 160 || bitSize == 192 || bitSize == 224 || bitSize == 256 {
		return true
	}
	return false
}

func MaxIndex(bitSize int) *big.Int {
	a := big.NewInt(0).Lsh(big.NewInt(1), uint(bitSize))
	return a.Sub(a, big.NewInt(1))
}

func contains(arr []string, str string) bool {
	for _, a := range arr {
		if a == str {
			return true
		}
	}
	return false
}

func GetElectrumMneAtIndex(index *big.Int, addressCount uint32, addressType string) (*MneRes, error) {
	words, prefix, idx, err := electrum.GenerateMnemonicWithStart(index, addressType)
	if err != nil {
		return nil, err
	}

	seedOpts := &electrum.SeedOptions{
		Passphrase: "",
		Prefix:     prefix,
	}

	seed, err := electrum.MnemonicToSeed(words, seedOpts)
	if err != nil {
		return nil, err
	}

	masterKey, err := hdkeychain.NewMaster(seed, &chaincfg.MainNetParams)
	if err != nil {
		return nil, err
	}

	var res MneRes
	res.Zjc = words
	res.Index = idx.String()

	key := masterKey
	if prefix == electrum.Prefixes["standard"] {
		key, err = key.Derive(0)
	} else {
		key, err = key.Derive(0 + hdkeychain.HardenedKeyStart)
		key, err = key.Derive(0)
	}
	if err != nil {
		return nil, err
	}
	res.List = make([]*AddrItem, 0)
	for i := uint32(0); i < addressCount; i++ {
		childKey, err := key.Derive(i)
		if err != nil {
			return nil, err
		}
		privKey, err := childKey.ECPrivKey()
		if err != nil {
			return nil, err
		}
		wif, _ := btcutil.NewWIF(privKey, &chaincfg.MainNetParams, true)
		if prefix == electrum.Prefixes["segwit"] {
			witnessAddr, _ := btcutil.NewAddressWitnessPubKeyHash(
				btcutil.Hash160(privKey.PubKey().SerializeCompressed()),
				&chaincfg.MainNetParams,
			)
			res.List = append(res.List, &AddrItem{
				Coin:      BTC,
				HexKey:    wif.String(),
				KeyFormat: "wif",
				Addr:      witnessAddr.EncodeAddress(),
				AddrTag:   "SegWit",
				Path:      fmt.Sprintf("m/0'/0/%d", i),
			})
		} else {
			p2pkhAddr, _ := btcutil.NewAddressPubKeyHash(
				btcutil.Hash160(privKey.PubKey().SerializeCompressed()),
				&chaincfg.MainNetParams,
			)
			res.List = append(res.List, &AddrItem{
				Coin:      BTC,
				HexKey:    wif.String(),
				KeyFormat: "wif",
				Addr:      p2pkhAddr.EncodeAddress(),
				AddrTag:   "Legacy",
				Path:      fmt.Sprintf("m/0/%d", i),
			})
		}
	}
	return &res, nil
}

// MnemonicDerivation selects a standard path and a window within one mnemonic.
type MnemonicDerivation struct {
	CustomPath   string
	Account      uint32
	Passphrase   string
	AddressStart uint32
	BTCType      string
	PathPreset   string
}

func GetMneAtIndex(bitSize int, index *big.Int, addressCount uint32, selectedCoins []string) (*MneRes, error) {
	return GetMneAtIndexWithOptions(bitSize, index, addressCount, selectedCoins, MnemonicDerivation{})
}

func GetMneAtIndexWithOptions(bitSize int, index *big.Int, addressCount uint32, selectedCoins []string, options MnemonicDerivation) (*MneRes, error) {
	if index == nil || index.Sign() < 0 || index.BitLen() > bitSize {
		return nil, fmt.Errorf("助记词索引超出范围")
	}
	if addressCount < 1 || addressCount > 20 || uint64(options.AddressStart)+uint64(addressCount) > uint64(hdwallet.ZeroQuote) {
		return nil, fmt.Errorf("地址索引范围无效")
	}
	if options.Account >= hdwallet.ZeroQuote {
		return nil, fmt.Errorf("账户编号超出范围")
	}
	if options.CustomPath == "" && contains(selectedCoins, SOL) && uint64(options.Account)+uint64(options.AddressStart)+uint64(addressCount) > uint64(hdwallet.ZeroQuote) {
		return nil, fmt.Errorf("SOL 账户索引范围无效")
	}
	switch options.BTCType {
	case "", "all", "legacy", "segwit", "nested", "taproot":
	default:
		return nil, fmt.Errorf("不支持的 BTC 地址类型")
	}
	if options.PathPreset != "" && options.PathPreset != "receive" && options.PathPreset != "change" {
		return nil, fmt.Errorf("不支持的标准路径预设")
	}
	if options.CustomPath != "" {
		if len(selectedCoins) != 1 {
			return nil, fmt.Errorf("自定义路径模式请仅选择一个币种")
		}
		children, _, err := ResolveCustomPath(options.CustomPath, options.AddressStart)
		if err != nil {
			return nil, err
		}
		if selectedCoins[0] == SOL {
			for _, child := range children {
				if child < hdwallet.ZeroQuote {
					return nil, fmt.Errorf("SOL 自定义路径的每层都必须硬化（带 '）")
				}
			}
		}
	}
	entropy := make([]byte, bitSize/8)
	index.FillBytes(entropy)
	mnemonic, err := bip39.NewMnemonic(entropy)
	if err != nil {
		return nil, err
	}
	master, err := hdwallet.NewKey(hdwallet.Mnemonic(mnemonic), hdwallet.Password(norm.NFKD.String(options.Passphrase)))
	if err != nil {
		return nil, err
	}
	result := &MneRes{Zjc: mnemonic, List: make([]*AddrItem, 0)}
	types := []struct {
		id, tag string
		purpose uint32
	}{
		{"legacy", "Legacy", 44}, {"segwit", "SegWit", 84},
		{"nested", "Nested SegWit", 49}, {"taproot", "Taproot", 86},
	}
	for _, coin := range []string{BTC, ETH, BSC, LTC, DOGE, TRX, SOL} {
		if !contains(selectedCoins, coin) {
			continue
		}
		coinType := map[string]uint32{BTC: hdwallet.BTC, ETH: hdwallet.ETH, BSC: hdwallet.BSC,
			LTC: hdwallet.LTC, DOGE: hdwallet.DOGE, TRX: hdwallet.TRX, SOL: hdwallet.SOL}[coin]
		change := uint32(0)
		if options.PathPreset == "change" && (coin == BTC || coin == LTC || coin == DOGE) {
			change = 1
		}
		for _, kind := range types {
			if coin != BTC && kind.id != "legacy" {
				continue
			}
			if coin == BTC && options.BTCType != "" && options.BTCType != "all" && options.BTCType != kind.id {
				continue
			}
			for offset := uint32(0); offset < addressCount; offset++ {
				addressIndex := options.AddressStart + offset
				childIndex := addressIndex
				account := options.Account + hdwallet.ZeroQuote
				if coin == SOL {
					childIndex += options.Account + hdwallet.ZeroQuote
					account = hdwallet.ZeroQuote
				}
				path := fmt.Sprintf("m/%d'/%d'/%d'/%d/%d", kind.purpose, coinType-hdwallet.ZeroQuote, options.Account, change, addressIndex)
				if coin == SOL {
					path = fmt.Sprintf("m/44'/501'/%d'/0'", options.Account+addressIndex)
				}
				var wallet hdwallet.Wallet
				if options.CustomPath != "" {
					var children []uint32
					children, path, err = ResolveCustomPath(options.CustomPath, addressIndex)
					if err == nil {
						wallet, err = master.GetWalletAtPath(coinType, children)
					}
				} else {
					wallet, err = master.GetWallet(hdwallet.Purpose(hdwallet.ZeroQuote+kind.purpose),
						hdwallet.CoinType(coinType), hdwallet.AddressIndex(childIndex), hdwallet.Change(change), hdwallet.Account(account))
				}
				if err != nil {
					return nil, err
				}
				var address string
				if coin == BTC {
					switch kind.id {
					case "segwit":
						address, err = wallet.GetKey().AddressP2WPKH()
					case "nested":
						address, err = wallet.GetKey().AddressP2WPKHInP2SH()
					case "taproot":
						address, err = wallet.GetKey().AddressBtcTaproot()
					default:
						address, err = wallet.GetAddress()
					}
				} else {
					address, err = wallet.GetAddress()
				}
				if err != nil {
					return nil, err
				}
				private, err := wallet.GetPrivateKey()
				if err != nil {
					return nil, err
				}
				tag := ""
				if coin == BTC {
					tag = kind.tag
				}
				format := "hex"
				if coin == BTC || coin == LTC || coin == DOGE {
					format = "wif"
				}
				if coin == SOL {
					format = "base58"
				}
				result.List = append(result.List, &AddrItem{Coin: coin, HexKey: private, KeyFormat: format, Addr: address, AddrTag: tag, Path: path})
			}
		}
	}
	return result, nil
}

func GetIndexLeft(mnemonic string, bitSize int) (*big.Int, error) {
	mnemonicSlice := strings.Split(strings.Trim(mnemonic, " "), " ")
	checksumBitLength := bitSize / 32
	sentenceLength := (bitSize + checksumBitLength) / 11
	if sentenceLength == len(mnemonicSlice) {
		bytes, err := bip39.MnemonicToByteArray(mnemonic, true)
		if err != nil {
			return nil, err
		}
		return big.NewInt(0).SetBytes(bytes), nil
	}
	rightPadBits := 11 - checksumBitLength
	o := sentenceLength - len(mnemonicSlice) - 1
	if o > 0 {
		rightPadBits += (11 * o)
	}
	fmt.Println(rightPadBits)
	fmt.Println(mnemonicSlice)
	ret := big.NewInt(0)
	modulo := big.NewInt(2048)
	for i := 0; i < len(mnemonicSlice); i++ {
		index, b := bip39.GetWordIndex(mnemonicSlice[i])
		if !b {
			index = 0
		}
		ret = ret.Mul(ret, modulo)
		ret = ret.Add(ret, big.NewInt(int64(index)))
	}
	ret = ret.Lsh(ret, uint(rightPadBits))
	return ret, nil
}

func CreateToken(index *big.Int, byteLen int) string {
	indexBytes := index.Bytes()
	indexLen := len(indexBytes)
	a := make([]byte, 64)
	j := 0
	for i := 0; i < 64; i++ {
		if i%2 == 0 {
			if j < indexLen {
				a[i] = indexBytes[j]
			} else {
				a[i] = byte(rand.Intn(254))
			}
			j++
		} else {
			a[i] = byte(rand.Intn(254))
		}
	}
	a[47] = byte(byteLen)
	a[7] = byte(indexLen)
	res, err := aes.AesCtrEncryptBase64(a, []byte("@copyrightsaodi1"), nil)
	if err != nil {
		return ""
	}
	return res
}

func GetIndexWithToken(token string) (*big.Int, int, error) {
	a, err := aes.AesCtrDecryptByBase64(token, []byte("@copyrightsaodi1"), nil)
	if err != nil {
		return nil, 0, err
	}
	byteLen := int(a[47])
	indexLen := int(a[7])
	index := big.NewInt(0)
	indexBytes := make([]byte, indexLen)
	for i := 0; i < indexLen; i++ {
		indexBytes[i] = a[i*2]
	}
	index.SetBytes(indexBytes)
	return index, byteLen, nil
}
