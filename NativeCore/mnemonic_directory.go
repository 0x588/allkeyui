package main

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"math/big"

	"allkeyui/nativecore/Core/base"
)

type mnemonicPageRequest struct {
	mnemonicRequest
	PageSize int `json:"pageSize"`
}

type mnemonicPageResult struct {
	Start       string           `json:"start"`
	End         string           `json:"end"`
	Max         string           `json:"max"`
	HasPrevious bool             `json:"hasPrevious"`
	HasNext     bool             `json:"hasNext"`
	Items       []mnemonicResult `json:"items"`
}

func createMnemonicPage(raw []byte) (mnemonicPageResult, error) {
	var request mnemonicPageRequest
	var result mnemonicPageResult
	if err := json.Unmarshal(raw, &request); err != nil {
		return result, errors.New("请求格式无效")
	}
	if !base.CheckBitSize(request.BitSize) || request.PageSize < 1 || request.PageSize > 20 {
		return result, errors.New("目录词数或每页组数无效，每页最多 20 组")
	}
	index, err := strictEntropyIndex(request.Index, request.BitSize)
	if err != nil {
		return result, err
	}
	maximum := base.MaxIndex(request.BitSize)
	pageSize := big.NewInt(int64(request.PageSize))
	switch request.Op {
	case "first":
		index.SetInt64(0)
	case "previous":
		index.Sub(index, pageSize)
		if index.Sign() < 0 {
			index.SetInt64(0)
		}
	case "next":
		index.Add(index, pageSize)
		if index.Cmp(maximum) > 0 {
			return result, errors.New("已经是目录最后一页")
		}
	case "last":
		index.Mul(new(big.Int).Quo(maximum, pageSize), pageSize)
	case "random":
		pages := new(big.Int).Add(new(big.Int).Quo(maximum, pageSize), big.NewInt(1))
		random, err := rand.Int(rand.Reader, pages)
		if err != nil {
			return result, err
		}
		index.Mul(random, pageSize)
	case "current", "jump", "":
	default:
		return result, errors.New("不支持的目录导航操作")
	}
	result = mnemonicPageResult{Start: index.String(), Max: maximum.String(), HasPrevious: index.Sign() > 0, Items: []mnemonicResult{}}
	for offset := 0; offset < request.PageSize; offset++ {
		current := new(big.Int).Add(index, big.NewInt(int64(offset)))
		if current.Cmp(maximum) > 0 {
			break
		}
		// Directory and per-mnemonic address windows are independent. The directory
		// always displays the first address per selected type at account zero.
		child := mnemonicRequest{BitSize: request.BitSize, Count: 1, Coins: request.Coins, Index: current.String(), Op: "jump", BTCType: request.BTCType}
		payload, _ := json.Marshal(child)
		generated, err := createMnemonic(payload)
		if err != nil {
			return mnemonicPageResult{}, err
		}
		result.Items = append(result.Items, generated)
		result.End = current.String()
	}
	result.HasNext = result.End != result.Max
	return result, nil
}
