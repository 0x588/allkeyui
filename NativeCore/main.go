package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"math/big"
	"runtime/debug"
	"strings"
	"unsafe"

	"allkeyui/nativecore/Core/base"
	"allkeyui/nativecore/Core/electrum"

	"github.com/btcsuite/btcd/btcutil/base58"
	"github.com/tyler-smith/go-bip39"
	"github.com/tyler-smith/go-bip39/wordlists"
)

const maxBatchSize = 20

type createKeysRequest struct {
	PuzzleNumber int      `json:"puzzleNumber,omitempty"`
	BTCType      string   `json:"btcType,omitempty"`
	Index        string   `json:"index"`
	Coins        []string `json:"coins"`
	Count        int      `json:"count"`
	Op           string   `json:"op"`
}

type mnemonicRequest struct {
	CustomPath    string   `json:"customPath,omitempty"`
	TargetAddress string   `json:"targetAddress,omitempty"`
	TargetCoin    string   `json:"targetCoin,omitempty"`
	Account       int64    `json:"account,omitempty"`
	Passphrase    string   `json:"passphrase,omitempty"`
	AddressStart  int64    `json:"addressStart,omitempty"`
	BTCType       string   `json:"btcType,omitempty"`
	PathPreset    string   `json:"pathPreset,omitempty"`
	Pattern       string   `json:"pattern,omitempty"`
	Cursor        string   `json:"cursor,omitempty"`
	BitSize       int      `json:"bitSize"`
	Count         int      `json:"count"`
	Coins         []string `json:"coins"`
	Index         string   `json:"index"`
	Op            string   `json:"op"`
}

type electrumRequest struct {
	Count       int    `json:"count"`
	AddressType string `json:"addressType"`
	Index       string `json:"index"`
	Op          string `json:"op"`
}

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type envelope struct {
	OK    bool        `json:"ok"`
	Data  interface{} `json:"data,omitempty"`
	Error *apiError   `json:"error,omitempty"`
}

type keyResult struct {
	InputFormat   string           `json:"inputFormat"`
	WIFCompressed *bool            `json:"wifCompressed,omitempty"`
	Index         string           `json:"index"`
	Items         []*base.AddrItem `json:"items"`
}

type mnemonicResult struct {
	MatchedItem  *base.AddrItem   `json:"matchedItem,omitempty"`
	SearchCursor string           `json:"searchCursor,omitempty"`
	Mnemonic     string           `json:"mnemonic"`
	Index        string           `json:"index"`
	Max          string           `json:"max"`
	Items        []*base.AddrItem `json:"items"`
}

var supportedCoins = map[string]struct{}{
	base.BTC: {}, base.ETH: {}, base.BSC: {}, base.LTC: {},
	base.DOGE: {}, base.TRX: {}, base.SOL: {},
}

var secp256k1Max = mustBigInt("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140", 16)
var electrumMax = mustBigInt("87112285931760246646623899502532662131973", 10)

func mustBigInt(value string, base int) *big.Int {
	n, ok := new(big.Int).SetString(value, base)
	if !ok {
		panic("invalid constant")
	}
	return n
}

func createKeys(raw []byte) (result keyResult, err error) {
	var request createKeysRequest
	if err := json.Unmarshal(raw, &request); err != nil {
		return result, errors.New("请求格式无效")
	}

	index, inputFormat, compressed, parseErr := parsePrivateKey(request.Index)
	if parseErr != nil {
		return result, parseErr
	}
	btcTags := map[string]string{"legacy": "Legacy(c)", "legacyUncompressed": "Legacy(u)", "segwit": "SegWit(c)", "nested": "NestedSegWit(c)", "taproot": "Taproot"}
	if request.BTCType != "" && request.BTCType != "all" {
		if _, ok := btcTags[request.BTCType]; !ok {
			return result, errors.New("不支持的 BTC 地址类型")
		}
	}
	if request.Count < 1 || request.Count > maxBatchSize {
		return result, errors.New("每次生成数量必须在 1 到 20 之间")
	}
	minimum, maximum, rangeErr := privateKeyBounds(request.PuzzleNumber)
	if rangeErr != nil {
		return result, rangeErr
	}
	if request.PuzzleNumber > 0 && (request.Op == "current" || request.Op == "") &&
		(index.Cmp(minimum) < 0 || index.Cmp(maximum) > 0) {
		return result, errors.New("索引超出当前 Puzzle 范围")
	}
	available := new(big.Int).Sub(maximum, minimum)
	available.Add(available, big.NewInt(1))
	if available.Cmp(big.NewInt(int64(request.Count))) < 0 {
		request.Count = int(available.Int64())
	}
	pageSize := big.NewInt(int64(request.Count))
	maximumStart := new(big.Int).Sub(maximum, pageSize)
	maximumStart.Add(maximumStart, big.NewInt(1))

	switch request.Op {
	case "first":
		index.Set(minimum)
	case "previous":
		index.Sub(index, pageSize)
	case "next":
		index.Add(index, pageSize)
	case "last":
		index.Set(maximumStart)
	case "random":
		span := new(big.Int).Sub(maximumStart, minimum)
		span.Add(span, big.NewInt(1))
		randomIndex, randomErr := rand.Int(rand.Reader, span)
		if randomErr != nil {
			return result, errors.New("无法生成安全随机索引")
		}
		index.Add(randomIndex, minimum)
	case "current", "":
	default:
		return result, errors.New("不支持的导航操作")
	}
	if index.Cmp(minimum) < 0 {
		index.Set(minimum)
	}
	if index.Cmp(maximumStart) > 0 {
		index.Set(maximumStart)
	}
	if len(request.Coins) == 0 {
		return result, errors.New("请至少选择一种币")
	}

	coins := make([]string, 0, len(request.Coins))
	seen := make(map[string]struct{}, len(request.Coins))
	for _, coin := range request.Coins {
		coin = strings.ToUpper(strings.TrimSpace(coin))
		if _, valid := supportedCoins[coin]; !valid {
			return result, errors.New("包含不支持的币种：" + coin)
		}
		if _, duplicate := seen[coin]; duplicate {
			continue
		}
		seen[coin] = struct{}{}
		coins = append(coins, coin)
	}

	items := make([]*base.AddrItem, 0)
	for offset := 0; offset < request.Count; offset++ {
		current := new(big.Int).Add(index, big.NewInt(int64(offset)))
		if current.Cmp(maximum) > 0 {
			break
		}
		created, createErr := base.CreateKeys(current, coins)
		if createErr != nil {
			return result, createErr
		}
		for _, item := range created {
			if item.Coin == base.BTC && request.BTCType != "" && request.BTCType != "all" && item.AddrTag != btcTags[request.BTCType] {
				continue
			}
			items = append(items, item)
		}
	}

	return keyResult{Index: index.Text(16), Items: items, InputFormat: inputFormat, WIFCompressed: compressed}, nil
}

// Check the original scalar before conversion: private-key constructors may reduce modulo N.
func parsePrivateKey(input string) (*big.Int, string, *bool, error) {
	input = strings.TrimSpace(input)
	if len(input) == 0 || len(input) > 66 {
		return nil, "", nil, errors.New("请输入 HEX 私钥或 Bitcoin 主网 WIF")
	}
	hex := input
	if strings.HasPrefix(hex, "0x") || strings.HasPrefix(hex, "0X") {
		hex = hex[2:]
	}
	isHex := len(hex) > 0 && len(hex) <= 64
	for _, c := range hex {
		if !strings.ContainsRune("0123456789abcdefABCDEF", c) {
			isHex = false
			break
		}
	}
	var index *big.Int
	format := "HEX"
	var compressed *bool
	if isHex {
		index, _ = new(big.Int).SetString(hex, 16)
	} else {
		payload, version, err := base58.CheckDecode(input)
		if err != nil {
			return nil, "", nil, errors.New("私钥格式无效：请输入十六进制 HEX 或校验和正确的 WIF")
		}
		if version != 0x80 {
			return nil, "", nil, errors.New("仅支持 Bitcoin 主网 WIF")
		}
		if len(payload) != 32 && (len(payload) != 33 || payload[32] != 1) {
			return nil, "", nil, errors.New("WIF 长度或压缩标记无效")
		}
		c := len(payload) == 33
		compressed = &c
		index = new(big.Int).SetBytes(payload[:32])
		format = "WIF"
	}
	if index.Sign() <= 0 || index.Cmp(secp256k1Max) > 0 {
		return nil, "", nil, errors.New("私钥超出 secp256k1 有效范围")
	}
	return index, format, compressed, nil
}

// Puzzle n includes both endpoints: [2^(n-1), 2^n-1].
func privateKeyBounds(puzzleNumber int) (*big.Int, *big.Int, error) {
	if puzzleNumber < 0 || puzzleNumber > 160 {
		return nil, nil, errors.New("Puzzle 编号必须在 1 到 160 之间")
	}
	if puzzleNumber == 0 {
		return big.NewInt(1), new(big.Int).Set(secp256k1Max), nil
	}
	minimum := new(big.Int).Lsh(big.NewInt(1), uint(puzzleNumber-1))
	maximum := new(big.Int).Lsh(big.NewInt(1), uint(puzzleNumber))
	maximum.Sub(maximum, big.NewInt(1))
	return minimum, maximum, nil
}

func normalizedCoins(input []string) ([]string, error) {
	if len(input) == 0 {
		return nil, errors.New("请至少选择一种币")
	}
	coins := make([]string, 0, len(input))
	seen := make(map[string]struct{}, len(input))
	for _, coin := range input {
		coin = strings.ToUpper(strings.TrimSpace(coin))
		if _, valid := supportedCoins[coin]; !valid {
			return nil, errors.New("包含不支持的币种：" + coin)
		}
		if _, duplicate := seen[coin]; duplicate {
			continue
		}
		seen[coin] = struct{}{}
		coins = append(coins, coin)
	}
	return coins, nil
}

func navigateIndex(value, op string, maximum *big.Int) (*big.Int, error) {
	index, ok := new(big.Int).SetString(strings.TrimSpace(value), 10)
	if !ok {
		return nil, errors.New("索引必须是十进制数字")
	}
	switch op {
	case "first":
		index.SetInt64(0)
	case "previous":
		index.Sub(index, big.NewInt(1))
	case "next":
		index.Add(index, big.NewInt(1))
	case "last":
		index.Set(maximum)
	case "random":
		upper := new(big.Int).Add(maximum, big.NewInt(1))
		var err error
		index, err = rand.Int(rand.Reader, upper)
		if err != nil {
			return nil, errors.New("无法生成安全随机索引")
		}
	case "current", "":
	default:
		return nil, errors.New("不支持的导航操作")
	}
	if index.Sign() < 0 {
		index.SetInt64(0)
	}
	if index.Cmp(maximum) > 0 {
		index.Set(maximum)
	}
	return index, nil
}

func mnemonicIndex(words []string, bitSize int) (*big.Int, error) {
	checksumBitLength := bitSize / 32
	sentenceLength := (bitSize + checksumBitLength) / 11
	if len(words) > sentenceLength {
		return nil, errors.New("输入的助记词数量超过所选长度")
	}
	mnemonic := strings.Join(words, " ")
	if len(words) == sentenceLength {
		entropy, err := bip39.MnemonicToByteArray(mnemonic, true)
		if err != nil {
			return nil, errors.New("完整助记词的校验和无效")
		}
		return new(big.Int).SetBytes(entropy), nil
	}

	rightPadBits := 11 - checksumBitLength
	missingBeforeChecksum := sentenceLength - len(words) - 1
	if missingBeforeChecksum > 0 {
		rightPadBits += 11 * missingBeforeChecksum
	}
	index := new(big.Int)
	for _, word := range words {
		wordIndex, _ := bip39.GetWordIndex(word)
		index.Mul(index, big.NewInt(2048))
		index.Add(index, big.NewInt(int64(wordIndex)))
	}
	return index.Lsh(index, uint(rightPadBits)), nil
}

func createMnemonic(raw []byte) (mnemonicResult, error) {
	var request mnemonicRequest
	if err := json.Unmarshal(raw, &request); err != nil {
		return mnemonicResult{}, errors.New("请求格式无效")
	}
	if !base.CheckBitSize(request.BitSize) {
		return mnemonicResult{}, errors.New("助记词强度必须是 128、160、192、224 或 256")
	}
	if request.Account < 0 || request.Account >= 1<<31 {
		return mnemonicResult{}, errors.New("账户编号必须在 0 到 2147483647 之间")
	}
	request.Index = normalizedMnemonic(request.Index)
	request.Pattern = normalizedMnemonic(request.Pattern)
	if request.Count < 1 || request.Count > 20 {
		return mnemonicResult{}, errors.New("每页地址数量必须在 1 到 20 之间")
	}
	if request.AddressStart < 0 || request.AddressStart+int64(request.Count) > 1<<31 || request.AddressStart > 1<<31 {
		return mnemonicResult{}, errors.New("地址索引范围无效")
	}
	coins, err := normalizedCoins(request.Coins)
	if err != nil {
		return mnemonicResult{}, err
	}

	var target string
	if request.TargetAddress != "" {
		if !containsCoin(coins, request.TargetCoin) {
			return mnemonicResult{}, errors.New("请在派生币种中选择目标地址的币种")
		}
		target, err = canonicalMatchAddress(request.TargetCoin, request.TargetAddress)
		if err != nil {
			return mnemonicResult{}, err
		}
	}
	var index *big.Int
	if request.Pattern != "" || (request.Op == "search" && strings.Contains(request.Index, "?")) {
		if request.Pattern == "" {
			request.Pattern = request.Index
		}
		var cursor string
		index, cursor, err = findMnemonicPattern(request)
		if err == nil && cursor != "" {
			return mnemonicResult{SearchCursor: cursor, Items: []*base.AddrItem{}}, nil
		}
	} else if request.Op == "search" {
		words := strings.Fields(request.Index)
		if len(words) == 0 {
			return mnemonicResult{}, errors.New("请输入助记词")
		}
		for _, word := range words {
			if _, exists := bip39.GetWordIndex(word); !exists {
				return mnemonicResult{}, errors.New("助记词包含词表之外的单词：" + word)
			}
		}
		index, err = mnemonicIndex(words, request.BitSize)
	} else if request.Op == "jump" {
		index, err = strictEntropyIndex(request.Index, request.BitSize)
	} else {
		index, err = navigateIndex(request.Index, request.Op, base.MaxIndex(request.BitSize))
	}
	if err != nil {
		return mnemonicResult{}, err
	}
	generated, err := base.GetMneAtIndexWithOptions(request.BitSize, index, uint32(request.Count), coins,
		base.MnemonicDerivation{CustomPath: strings.TrimSpace(request.CustomPath), AddressStart: uint32(request.AddressStart), BTCType: request.BTCType, PathPreset: request.PathPreset, Account: uint32(request.Account), Passphrase: request.Passphrase})
	if err != nil {
		return mnemonicResult{}, err
	}
	var matched *base.AddrItem
	if target != "" {
		for _, item := range generated.List {
			if item.Coin != request.TargetCoin {
				continue
			}
			address, parseErr := canonicalMatchAddress(item.Coin, item.Addr)
			if parseErr == nil && address == target {
				matched = item
				break
			}
		}
	}
	return mnemonicResult{
		MatchedItem: matched,
		Mnemonic:    generated.Zjc,
		Index:       index.String(),
		Max:         base.MaxIndex(request.BitSize).String(),
		Items:       generated.List,
	}, nil
}

func createElectrum(raw []byte) (mnemonicResult, error) {
	var request electrumRequest
	if err := json.Unmarshal(raw, &request); err != nil {
		return mnemonicResult{}, errors.New("请求格式无效")
	}
	if request.Count < 1 || request.Count > 5 {
		return mnemonicResult{}, errors.New("接收地址数量必须在 1 到 5 之间")
	}
	if request.AddressType != "all" && request.AddressType != "standard" && request.AddressType != "segwit" {
		return mnemonicResult{}, errors.New("不支持的 Electrum 地址类型")
	}

	var index *big.Int
	var err error
	if request.Op == "search" {
		mnemonic := strings.Join(strings.Fields(request.Index), " ")
		if mnemonic == "" {
			return mnemonicResult{}, errors.New("请输入 Electrum 助记词")
		}
		index, err = electrum.GetIndexFromMnemonic(mnemonic, wordlists.English)
	} else {
		index, err = navigateIndex(request.Index, request.Op, electrumMax)
	}
	if err != nil {
		return mnemonicResult{}, errors.New("Electrum 助记词或索引格式无效")
	}
	generated, err := base.GetElectrumMneAtIndex(index, uint32(request.Count), request.AddressType)
	if err != nil {
		return mnemonicResult{}, err
	}
	return mnemonicResult{
		Mnemonic: generated.Zjc,
		Index:    generated.Index,
		Max:      electrumMax.String(),
		Items:    generated.List,
	}, nil
}

func encodeResponse(data interface{}, err error) []byte {
	if err != nil {
		payload, _ := json.Marshal(envelope{
			OK: false, Error: &apiError{Code: "invalid_request", Message: err.Error()},
		})
		return payload
	}
	payload, _ := json.Marshal(envelope{OK: true, Data: data})
	return payload
}

func safeResponse(operation func() (interface{}, error)) (payload []byte) {
	defer func() {
		if recovered := recover(); recovered != nil {
			_ = debug.Stack()
			payload, _ = json.Marshal(envelope{
				OK:    false,
				Error: &apiError{Code: "internal_error", Message: "核心计算发生异常"},
			})
		}
	}()
	data, err := operation()
	return encodeResponse(data, err)
}

//export AllKeyCreateKeys
func AllKeyCreateKeys(requestJSON *C.char) *C.char {
	if requestJSON == nil {
		return C.CString(`{"ok":false,"error":{"code":"invalid_request","message":"请求不能为空"}}`)
	}
	raw := []byte(C.GoString(requestJSON))
	return C.CString(string(safeResponse(func() (interface{}, error) { return createKeys(raw) })))
}

//export AllKeyCreateMnemonic
func AllKeyCreateMnemonic(requestJSON *C.char) *C.char {
	if requestJSON == nil {
		return C.CString(`{"ok":false,"error":{"code":"invalid_request","message":"请求不能为空"}}`)
	}
	raw := []byte(C.GoString(requestJSON))
	return C.CString(string(safeResponse(func() (interface{}, error) { return createMnemonic(raw) })))
}

//export AllKeyCreateMnemonicPage
func AllKeyCreateMnemonicPage(requestJSON *C.char) *C.char {
	if requestJSON == nil {
		return C.CString(`{"ok":false,"error":{"code":"invalid_request","message":"请求不能为空"}}`)
	}
	raw := []byte(C.GoString(requestJSON))
	return C.CString(string(safeResponse(func() (interface{}, error) { return createMnemonicPage(raw) })))
}

//export AllKeyInspectMnemonic
func AllKeyInspectMnemonic(requestJSON *C.char) *C.char {
	if requestJSON == nil {
		return C.CString(`{"ok":false,"error":{"code":"invalid_request","message":"请求不能为空"}}`)
	}
	raw := []byte(C.GoString(requestJSON))
	return C.CString(string(safeResponse(func() (interface{}, error) { return inspectMnemonic(raw) })))
}

//export AllKeyCreateElectrum
func AllKeyCreateElectrum(requestJSON *C.char) *C.char {
	if requestJSON == nil {
		return C.CString(`{"ok":false,"error":{"code":"invalid_request","message":"请求不能为空"}}`)
	}
	raw := []byte(C.GoString(requestJSON))
	return C.CString(string(safeResponse(func() (interface{}, error) { return createElectrum(raw) })))
}

//export AllKeyCalculate
func AllKeyCalculate(requestJSON *C.char) *C.char {
	if requestJSON == nil {
		return C.CString(`{"ok":false,"error":{"code":"invalid_request","message":"请求不能为空"}}`)
	}
	raw := []byte(C.GoString(requestJSON))
	return C.CString(string(safeResponse(func() (interface{}, error) { return calculateJSON(raw) })))
}

//export AllKeyFree
func AllKeyFree(pointer *C.char) {
	C.free(unsafe.Pointer(pointer))
}

func main() {}
