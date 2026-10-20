package main

import (
	"bytes"
	"crypto/aes"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"unicode/utf8"

	"allkeyui/nativecore/Core/base"
	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcutil"
	"github.com/btcsuite/btcd/btcutil/base58"
	"github.com/btcsuite/btcd/btcutil/bech32"
	"github.com/btcsuite/btcd/chaincfg"
	ethcrypto "github.com/ethereum/go-ethereum/crypto"
	"golang.org/x/crypto/ripemd160"
	"golang.org/x/crypto/scrypt"
	"golang.org/x/text/unicode/norm"
)

type calculatorRequest struct {
	Operation  string `json:"operation"`
	Input      string `json:"input"`
	Passphrase string `json:"passphrase"`
	Compressed bool   `json:"compressed"`
}
type calculatorResult struct {
	Output string `json:"output"`
}

func calculateJSON(raw []byte) (calculatorResult, error) {
	var request calculatorRequest
	if len(raw) > 8*1024*1024 {
		return calculatorResult{}, errors.New("输入过长，最多 1 MiB")
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return calculatorResult{}, errors.New("无效的计算请求")
	}
	if len(request.Input) > 1024*1024 || len(request.Passphrase) > 4096 {
		return calculatorResult{}, errors.New("输入最多 1 MiB，口令最多 4096 字节")
	}
	result, err := calculate(request)
	return calculatorResult{Output: result}, err
}

func calcHex(input string, odd bool) ([]byte, error) {
	text := strings.TrimSpace(input)
	if strings.HasPrefix(text, "0x") || strings.HasPrefix(text, "0X") {
		text = text[2:]
	}
	if odd && len(text)%2 != 0 {
		text = "0" + text
	}
	decoded, err := hex.DecodeString(text)
	if err != nil {
		return nil, errors.New("请输入有效的十六进制字节（两个字符表示一个字节）")
	}
	return decoded, nil
}
func calcSHA(data []byte) []byte     { sum := sha256.Sum256(data); return sum[:] }
func calcHash160(data []byte) []byte { h := ripemd160.New(); h.Write(calcSHA(data)); return h.Sum(nil) }
func calcCheckEncode(payload []byte) string {
	sum := calcSHA(calcSHA(payload))
	return base58.Encode(append(append([]byte{}, payload...), sum[:4]...))
}
func calcBase58(input string, check bool) ([]byte, error) {
	if input == "" || strings.Trim(input, "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz") != "" {
		return nil, errors.New("无效的 Base58 字符")
	}
	data := base58.Decode(input)
	if !check {
		return data, nil
	}
	if len(data) < 4 {
		return nil, errors.New("Base58Check 数据过短")
	}
	payload, checksum := data[:len(data)-4], data[len(data)-4:]
	expected := calcSHA(calcSHA(payload))
	if subtle.ConstantTimeCompare(checksum, expected[:4]) != 1 {
		return nil, errors.New("Base58Check 校验和不匹配")
	}
	return payload, nil
}
func calcScalar(data []byte) (*btcec.PrivateKey, error) {
	number := new(big.Int).SetBytes(data)
	if len(data) > 32 || number.Sign() <= 0 || number.Cmp(btcec.S256().N) >= 0 {
		return nil, errors.New("私钥必须满足 1 ≤ d < secp256k1 曲线阶 n，最长 32 字节")
	}
	key, _ := btcec.PrivKeyFromBytes(data)
	return key, nil
}
func calcPrivate(input string) (*btcec.PrivateKey, bool, error) {
	if strings.HasPrefix(input, "5") || strings.HasPrefix(input, "K") || strings.HasPrefix(input, "L") {
		payload, err := calcBase58(input, true)
		if err == nil && (len(payload) == 33 || len(payload) == 34) && payload[0] == 0x80 {
			compressed := len(payload) == 34
			if compressed && payload[33] != 1 {
				return nil, false, errors.New("无效的 WIF 压缩标记")
			}
			key, err := calcScalar(payload[1:33])
			return key, compressed, err
		}
		// Hex strings starting with 5 remain valid private-key input.
		if _, hexErr := calcHex(input, true); hexErr != nil {
			return nil, false, errors.New("无效的 Bitcoin 主网 WIF 或校验和")
		}
	}
	data, err := calcHex(input, true)
	if err != nil {
		return nil, false, err
	}
	key, err := calcScalar(data)
	return key, true, err
}
func calcPublic(input string) (*btcec.PublicKey, error) {
	data, err := calcHex(input, false)
	if err != nil {
		return nil, err
	}
	if !(len(data) == 33 && (data[0] == 2 || data[0] == 3) || len(data) == 65 && data[0] == 4) {
		return nil, errors.New("公钥需为 33 字节压缩格式或 65 字节未压缩格式")
	}
	key, err := btcec.ParsePubKey(data)
	if err != nil {
		return nil, errors.New("公钥不是有效的 secp256k1 曲线点")
	}
	return key, nil
}
func calcWIF(key *btcec.PrivateKey, compressed bool) string {
	w, _ := btcutil.NewWIF(key, &chaincfg.MainNetParams, compressed)
	return w.String()
}
func calcLegacy(key *btcec.PrivateKey, compressed bool) string {
	item, _ := base.CreateBtcLegacy(key, compressed)
	return item.Addr
}

func calculate(request calculatorRequest) (string, error) {
	op := request.Operation
	input := strings.TrimSpace(request.Input)
	if strings.HasPrefix(op, "priv-to-") || op == "wif-to-priv" || op == "wif-validate" {
		if strings.HasPrefix(op, "wif-") {
			if !strings.HasPrefix(input, "5") && !strings.HasPrefix(input, "K") && !strings.HasPrefix(input, "L") {
				return "", errors.New("请输入 Bitcoin 主网 WIF（5 / K / L 开头）")
			}
			payload, err := calcBase58(input, true)
			if err != nil {
				return "", err
			}
			if !(len(payload) == 33 || len(payload) == 34) || payload[0] != 0x80 || len(payload) == 34 && payload[33] != 1 {
				return "", errors.New("无效的 Bitcoin 主网 WIF 长度、版本或压缩标记")
			}
		}
		key, compressed, err := calcPrivate(input)
		if err != nil {
			return "", err
		}
		pub := key.PubKey()
		switch op {
		case "priv-to-pub-c":
			return hex.EncodeToString(pub.SerializeCompressed()), nil
		case "priv-to-pub-u":
			return hex.EncodeToString(pub.SerializeUncompressed()), nil
		case "priv-to-addr-c":
			return calcLegacy(key, true), nil
		case "priv-to-addr-u":
			return calcLegacy(key, false), nil
		case "priv-to-addr-evm":
			return ethcrypto.PubkeyToAddress(*pub.ToECDSA()).Hex(), nil
		case "priv-to-wif-c":
			return calcWIF(key, true), nil
		case "priv-to-wif-u":
			return calcWIF(key, false), nil
		case "wif-to-priv":
			return hex.EncodeToString(key.Serialize()), nil
		case "wif-validate":
			return fmt.Sprintf("有效的 Bitcoin 主网 WIF\n压缩公钥：%t\n地址：%s", compressed, calcLegacy(key, compressed)), nil
		case "priv-to-all":
			seg, err := base.CreateBtcSegWit(key, true)
			if err != nil {
				return "", err
			}
			nested, err := base.CreateBtcNestedSegWit(key, true)
			if err != nil {
				return "", err
			}
			tap, err := base.CreateBtcTaproot(key)
			if err != nil {
				return "", err
			}
			return fmt.Sprintf("HEX 私钥\n%x\n\nWIF · 压缩\n%s\n\nWIF · 未压缩\n%s\n\n公钥 · 压缩\n%x\n\n公钥 · 未压缩\n%x\n\nBTC Legacy(c)\n%s\n\nBTC Legacy(u)\n%s\n\nBTC SegWit\n%s\n\nBTC Nested SegWit\n%s\n\nBTC Taproot\n%s\n\nEVM 地址\n%s", key.Serialize(), calcWIF(key, true), calcWIF(key, false), pub.SerializeCompressed(), pub.SerializeUncompressed(), calcLegacy(key, true), calcLegacy(key, false), seg.Addr, nested.Addr, tap.Addr, ethcrypto.PubkeyToAddress(*pub.ToECDSA()).Hex()), nil
		}
	}
	if strings.HasPrefix(op, "pub-") {
		pub, err := calcPublic(input)
		if err != nil {
			return "", err
		}
		data, _ := calcHex(input, false)
		switch op {
		case "pub-compress":
			return hex.EncodeToString(pub.SerializeCompressed()), nil
		case "pub-decompress":
			return hex.EncodeToString(pub.SerializeUncompressed()), nil
		case "pub-to-addr":
			a, _ := btcutil.NewAddressPubKey(data, &chaincfg.MainNetParams)
			return a.EncodeAddress(), nil
		case "pub-to-addr-evm":
			return ethcrypto.PubkeyToAddress(*pub.ToECDSA()).Hex(), nil
		case "pub-to-hash160":
			return hex.EncodeToString(calcHash160(data)), nil
		case "pub-validate":
			return fmt.Sprintf("有效的 secp256k1 公钥\n序列化长度：%d 字节", len(data)), nil
		}
	}
	switch op {
	case "dec-to-hex", "hex-to-dec", "bin-to-hex", "hex-to-bin":
		radix := 10
		if op == "hex-to-dec" || op == "hex-to-bin" {
			radix = 16
			input = strings.TrimPrefix(strings.TrimPrefix(input, "0x"), "0X")
		}
		if op == "bin-to-hex" {
			radix = 2
		}
		if input == "" || strings.HasPrefix(input, "-") || strings.HasPrefix(input, "+") {
			return "", errors.New("请输入非负整数，不包含符号")
		}
		for _, r := range input {
			if !(r >= '0' && r <= '9' || radix == 16 && (r >= 'a' && r <= 'f' || r >= 'A' && r <= 'F')) || radix == 2 && r != '0' && r != '1' {
				return "", errors.New("输入包含不属于当前进制的字符")
			}
		}
		n, ok := new(big.Int).SetString(input, radix)
		if !ok {
			return "", errors.New("无效的进制输入")
		}
		outRadix := 16
		if op == "hex-to-dec" {
			outRadix = 10
		}
		if op == "hex-to-bin" {
			outRadix = 2
			value := n.Text(2)
			width := len(input) * 4
			return strings.Repeat("0", width-len(value)) + value, nil
		}
		return n.Text(outRadix), nil
	case "ascii-to-hex":
		return hex.EncodeToString([]byte(request.Input)), nil
	case "hex-to-ascii":
		data, err := calcHex(input, false)
		if err != nil {
			return "", err
		}
		if !utf8.Valid(data) {
			return "", errors.New("字节不是有效 UTF-8 文本")
		}
		return string(data), nil
	case "sha256-text":
		return hex.EncodeToString(calcSHA([]byte(request.Input))), nil
	case "sha256", "ripemd160", "hash160", "keccak256", "double-sha256", "base58-enc", "base58check-enc", "reverse-bytes", "pad-hex":
		data, err := calcHex(input, op == "pad-hex")
		if err != nil {
			return "", err
		}
		switch op {
		case "sha256":
			return hex.EncodeToString(calcSHA(data)), nil
		case "ripemd160":
			h := ripemd160.New()
			h.Write(data)
			return hex.EncodeToString(h.Sum(nil)), nil
		case "hash160":
			return hex.EncodeToString(calcHash160(data)), nil
		case "keccak256":
			return hex.EncodeToString(ethcrypto.Keccak256(data)), nil
		case "double-sha256":
			return hex.EncodeToString(calcSHA(calcSHA(data))), nil
		case "base58-enc":
			return base58.Encode(data), nil
		case "base58check-enc":
			return calcCheckEncode(data), nil
		case "reverse-bytes":
			for i, j := 0, len(data)-1; i < j; i, j = i+1, j-1 {
				data[i], data[j] = data[j], data[i]
			}
			return hex.EncodeToString(data), nil
		case "pad-hex":
			if len(data) > 32 {
				return "", errors.New("输入超过 32 字节，无法补齐到 64 位 HEX")
			}
			return fmt.Sprintf("%064x", new(big.Int).SetBytes(data)), nil
		}
	case "base58-dec", "base58check-dec":
		data, err := calcBase58(input, op == "base58check-dec")
		return hex.EncodeToString(data), err
	case "hash160-to-addr", "hash160-to-segwit", "bech32-enc", "bech32m-enc":
		data, err := calcHex(input, false)
		if err != nil {
			return "", err
		}
		required := 20
		if op == "bech32m-enc" {
			required = 32
		}
		if len(data) != required {
			return "", fmt.Errorf("输入必须是 %d 字节（%d 位 HEX）", required, required*2)
		}
		if op == "hash160-to-addr" {
			a, _ := btcutil.NewAddressPubKeyHash(data, &chaincfg.MainNetParams)
			return a.EncodeAddress(), nil
		}
		if op == "bech32m-enc" {
			a, _ := btcutil.NewAddressTaproot(data, &chaincfg.MainNetParams)
			return a.EncodeAddress(), nil
		}
		a, _ := btcutil.NewAddressWitnessPubKeyHash(data, &chaincfg.MainNetParams)
		return a.EncodeAddress(), nil
	case "addr-to-hash160", "addr-validate", "bech32-dec", "bech32m-dec":
		if strings.HasPrefix(strings.ToLower(input), "0x") {
			if op != "addr-validate" {
				return "", errors.New("此操作仅接受 BTC 主网地址")
			}
			address, err := calcEIP55(input, true)
			if err != nil {
				return "", err
			}
			return "有效的 EVM 地址\n" + address, nil
		}
		a, err := btcutil.DecodeAddress(input, &chaincfg.MainNetParams)
		if err != nil || !a.IsForNet(&chaincfg.MainNetParams) {
			return "", errors.New("无效的 Bitcoin 主网地址、长度或校验和")
		}
		label := ""
		version := -1
		switch a.(type) {
		case *btcutil.AddressPubKeyHash:
			label = "P2PKH · 公钥哈希"
		case *btcutil.AddressScriptHash:
			label = "P2SH · 脚本哈希"
		case *btcutil.AddressWitnessPubKeyHash:
			label = "P2WPKH · witness program"
			version = 0
		case *btcutil.AddressWitnessScriptHash:
			label = "P2WSH · witness program"
			version = 0
		case *btcutil.AddressTaproot:
			label = "P2TR · 输出公钥"
			version = 1
		default:
			return "", errors.New("不支持的地址类型")
		}
		if strings.HasPrefix(op, "bech32") {
			hrp, words, variant, e := bech32.DecodeGeneric(input)
			if e != nil || hrp != "bc" || len(words) == 0 {
				return "", errors.New("无效的 BTC 主网 Bech32 地址")
			}
			if op == "bech32-dec" && (version != 0 || variant != bech32.Version0) || op == "bech32m-dec" && (version != 1 || variant != bech32.VersionM) {
				return "", errors.New("地址版本与所选 Bech32 / Bech32m 操作不匹配")
			}
		}
		if op == "addr-validate" {
			return fmt.Sprintf("有效的 BTC 主网地址\n类型：%s\n载荷：%d 字节", label, len(a.ScriptAddress())), nil
		}
		return fmt.Sprintf("类型：%s\n载荷：%d 字节\nHEX：%x", label, len(a.ScriptAddress()), a.ScriptAddress()), nil
	case "checksum-evm":
		return calcEIP55(input, false)
	case "random-key":
		number, err := rand.Int(rand.Reader, new(big.Int).Sub(btcec.S256().N, big.NewInt(1)))
		if err != nil {
			return "", errors.New("系统随机数生成失败")
		}
		number.Add(number, big.NewInt(1))
		return fmt.Sprintf("%064x", number), nil
	case "bip38-encrypt", "bip38-decrypt":
		return calcBIP38(request)
	}
	return "", errors.New("不支持的计算操作")
}

func calcEIP55(input string, validate bool) (string, error) {
	data, err := calcHex(input, false)
	if err != nil || len(data) != 20 {
		return "", errors.New("EVM 地址必须是 20 字节（40 位 HEX）")
	}
	value := hex.EncodeToString(data)
	hash := ethcrypto.Keccak256([]byte(value))
	result := []byte(value)
	for i, c := range result {
		nibble := hash[i/2] >> 4
		if i%2 == 1 {
			nibble = hash[i/2] & 15
		}
		if c >= 'a' && c <= 'f' && nibble >= 8 {
			result[i] = c - 32
		}
	}
	text := strings.TrimPrefix(strings.TrimPrefix(input, "0x"), "0X")
	if validate && text != strings.ToLower(text) && text != strings.ToUpper(text) && text != string(result) {
		return "", errors.New("EIP-55 大小写校验不匹配")
	}
	return "0x" + string(result), nil
}

// Non-EC-multiply BIP38, using the existing x/crypto scrypt implementation.
func calcBIP38(request calculatorRequest) (string, error) {
	if request.Passphrase == "" {
		return "", errors.New("请输入 BIP38 口令（空格与大小写会保留）")
	}
	input := strings.TrimSpace(request.Input)
	encrypt := request.Operation == "bip38-encrypt"
	var raw, salt []byte
	compressed := request.Compressed
	var key *btcec.PrivateKey
	if encrypt {
		var wifCompressed bool
		var err error
		key, wifCompressed, err = calcPrivate(input)
		if err != nil {
			return "", err
		}
		if strings.HasPrefix(input, "5") || strings.HasPrefix(input, "K") || strings.HasPrefix(input, "L") {
			if _, err := calcBase58(input, true); err == nil {
				compressed = wifCompressed
			}
		}
		salt = calcSHA(calcSHA([]byte(calcLegacy(key, compressed))))[:4]
		raw = key.Serialize()
	} else {
		payload, err := calcBase58(input, true)
		if err != nil {
			return "", err
		}
		if len(payload) != 39 {
			return "", errors.New("无效的 BIP38 数据长度")
		}
		if payload[0] != 1 || payload[1] != 0x42 {
			return "", errors.New("仅支持 BIP38 非 EC-multiply 格式（0x0142）")
		}
		if payload[2] != 0xc0 && payload[2] != 0xe0 {
			return "", errors.New("无效的 BIP38 标志位")
		}
		compressed = payload[2] == 0xe0
		salt = payload[3:7]
		raw = payload[7:39]
	}
	derived, err := scrypt.Key([]byte(norm.NFC.String(request.Passphrase)), salt, 16384, 8, 8, 64)
	if err != nil {
		return "", errors.New("BIP38 密钥派生失败")
	}
	defer clear(derived)
	block, err := aes.NewCipher(derived[32:])
	if err != nil {
		return "", err
	}
	result := make([]byte, 32)
	defer clear(result)
	if encrypt {
		for i := range result {
			result[i] = raw[i] ^ derived[i]
		}
		block.Encrypt(result[:16], result[:16])
		block.Encrypt(result[16:], result[16:])
		flag := byte(0xc0)
		if compressed {
			flag = 0xe0
		}
		payload := append([]byte{1, 0x42, flag}, salt...)
		payload = append(payload, result...)
		return calcCheckEncode(payload), nil
	}
	block.Decrypt(result[:16], raw[:16])
	block.Decrypt(result[16:], raw[16:])
	for i := range result {
		result[i] ^= derived[i]
	}
	key, err = calcScalar(result)
	if err != nil {
		return "", errors.New("口令不正确或密文无效")
	}
	address := calcLegacy(key, compressed)
	expected := calcSHA(calcSHA([]byte(address)))
	if !bytes.Equal(salt, expected[:4]) {
		return "", errors.New("口令不正确（地址哈希不匹配）")
	}
	return fmt.Sprintf("WIF\n%s\n\nHEX 私钥\n%x\n\nBTC Legacy 地址\n%s\n\n公钥压缩：%t", calcWIF(key, compressed), key.Serialize(), address, compressed), nil
}
