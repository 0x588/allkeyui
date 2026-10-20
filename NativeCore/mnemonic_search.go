package main

import (
	"crypto/rand"
	"errors"
	"math/big"
	"strings"

	"github.com/tyler-smith/go-bip39"
	"github.com/tyler-smith/go-bip39/wordlists"
)

// Each call scans a bounded batch so the caller can report progress and cancel.
const mnemonicSearchBatch = 4096

func findMnemonicPattern(request mnemonicRequest) (*big.Int, string, error) {
	return findMnemonicPatternBatch(request, mnemonicSearchBatch)
}

func findMnemonicPatternBatch(request mnemonicRequest, batchSize int) (*big.Int, string, error) {
	words := strings.Fields(request.Pattern)
	if len(words) != request.BitSize/32*3 {
		return nil, "", errors.New("使用 ? 时，请填满所选词数，每个缺失单词用一个 ? 代替")
	}
	var missing []int
	for i, word := range words {
		if word == "?" {
			missing = append(missing, i)
		} else if _, ok := bip39.GetWordIndex(word); !ok {
			return nil, "", errors.New("助记词包含词表之外的单词：" + word)
		}
	}
	if len(missing) == 0 {
		return nil, "", errors.New("缺词模板必须包含 ?")
	}
	limit := new(big.Int).Lsh(big.NewInt(1), uint(11*len(missing)))
	wrapped := strings.HasPrefix(request.Cursor, "wrap:")
	ordinal := new(big.Int)
	direction := int64(1)
	if request.Op == "previous" || request.Op == "last" {
		direction = -1
	}
	if request.Cursor != "" {
		if _, ok := ordinal.SetString(strings.TrimPrefix(request.Cursor, "wrap:"), 10); !ok {
			return nil, "", errors.New("缺词查询游标无效")
		}
	} else {
		switch request.Op {
		case "search", "first":
		case "last":
			ordinal.Sub(limit, big.NewInt(1))
		case "random":
			var err error
			ordinal, err = rand.Int(rand.Reader, limit)
			if err != nil {
				return nil, "", err
			}
		case "next", "previous", "current", "":
			index, ok := new(big.Int).SetString(request.Index, 10)
			if !ok || index.Sign() < 0 || index.BitLen() > request.BitSize {
				return nil, "", errors.New("缺词查询索引无效")
			}
			entropy := make([]byte, request.BitSize/8)
			index.FillBytes(entropy)
			phrase, err := bip39.NewMnemonic(entropy)
			if err != nil {
				return nil, "", err
			}
			current := strings.Fields(phrase)
			for i, word := range words {
				if word != "?" && word != current[i] {
					return nil, "", errors.New("当前结果不属于缺词模板，请重新查找")
				}
			}
			for _, position := range missing {
				value, _ := bip39.GetWordIndex(current[position])
				ordinal.Lsh(ordinal, 11)
				ordinal.Or(ordinal, big.NewInt(int64(value)))
			}
			if request.Op == "next" || request.Op == "previous" {
				ordinal.Add(ordinal, big.NewInt(direction))
			}
		default:
			return nil, "", errors.New("不支持的缺词查询操作")
		}
	}
	step := big.NewInt(direction)
	for scanned := 0; scanned < batchSize; scanned++ {
		if request.Op == "random" && !wrapped && ordinal.Cmp(limit) >= 0 {
			ordinal.SetInt64(0)
			wrapped = true
		}
		if ordinal.Sign() < 0 || ordinal.Cmp(limit) >= 0 {
			if request.Op == "previous" {
				return nil, "", errors.New("已经是第一个匹配结果")
			}
			if request.Op == "next" {
				return nil, "", errors.New("已经是最后一个匹配结果")
			}
			return nil, "", errors.New("该范围内没有符合校验和的匹配结果")
		}
		digits := new(big.Int).Set(ordinal)
		for i := len(missing) - 1; i >= 0; i-- {
			words[missing[i]] = wordlists.English[digits.Uint64()&2047]
			digits.Rsh(digits, 11)
		}
		entropy, err := bip39.EntropyFromMnemonic(strings.Join(words, " "))
		if err == nil {
			return new(big.Int).SetBytes(entropy), "", nil
		}
		ordinal.Add(ordinal, step)
	}
	cursor := ordinal.String()
	if wrapped {
		cursor = "wrap:" + cursor
	}
	return nil, cursor, nil
}
