package main

import (
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"unicode"

	"github.com/tyler-smith/go-bip39"
	"github.com/tyler-smith/go-bip39/wordlists"
	"golang.org/x/text/unicode/norm"
)

type mnemonicWordIssue struct {
	Position int    `json:"position"`
	Word     string `json:"word"`
}

type mnemonicInspection struct {
	WordCount          int                 `json:"wordCount"`
	DetectedBitSize    int                 `json:"detectedBitSize"`
	MissingCount       int                 `json:"missingCount"`
	InvalidWords       []mnemonicWordIssue `json:"invalidWords"`
	Checksum           string              `json:"checksum"`
	CompletionPosition int                 `json:"completionPosition"`
	Suggestions        []string            `json:"suggestions"`
}

func normalizedMnemonic(text string) string {
	return strings.Join(strings.Fields(strings.ToLower(norm.NFKD.String(text))), " ")
}

func inspectMnemonic(raw []byte) (mnemonicInspection, error) {
	var request struct {
		Text               string `json:"text"`
		BitSize            int    `json:"bitSize"`
		CompletionPosition *int   `json:"completionPosition"`
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return mnemonicInspection{}, errors.New("请求格式无效")
	}
	if len(request.Text) > 16384 {
		return mnemonicInspection{}, errors.New("输入内容过长")
	}
	words := strings.Fields(normalizedMnemonic(request.Text))
	result := mnemonicInspection{WordCount: len(words), InvalidWords: []mnemonicWordIssue{}, Suggestions: []string{}, Checksum: "pending", CompletionPosition: -1}
	switch len(words) {
	case 12, 15, 18, 21, 24:
		result.DetectedBitSize = len(words) / 3 * 32
	}
	for index, word := range words {
		if word == "?" {
			result.MissingCount++
			continue
		}
		if _, ok := bip39.GetWordIndex(word); !ok {
			result.InvalidWords = append(result.InvalidWords, mnemonicWordIssue{index, word})
		}
	}
	if result.MissingCount > 0 {
		result.Checksum = "missing"
	} else if len(result.InvalidWords) == 0 && len(words) == request.BitSize/32*3 && result.DetectedBitSize > 0 {
		if bip39.IsMnemonicValid(strings.Join(words, " ")) {
			result.Checksum = "valid"
		} else {
			result.Checksum = "invalid"
		}
	}
	position := len(words) - 1
	if request.CompletionPosition != nil {
		position = *request.CompletionPosition
	} else if len(request.Text) == 0 || unicode.IsSpace([]rune(request.Text)[len([]rune(request.Text))-1]) {
		position = -1
	}
	if position >= 0 && position < len(words) && words[position] != "?" {
		result.CompletionPosition = position
		result.Suggestions = suggestMnemonicWord(words[position])
	}
	return result, nil
}

func suggestMnemonicWord(prefix string) []string {
	matches := []string{}
	if prefix == "" || len(prefix) > 32 {
		return matches
	}
	for _, letter := range prefix {
		if letter < 'a' || letter > 'z' {
			return matches
		}
	}
	for _, word := range wordlists.English {
		if strings.HasPrefix(word, prefix) {
			matches = append(matches, word)
			if len(matches) == 8 {
				return matches
			}
		}
	}
	if len(matches) > 0 || len(prefix) < 3 {
		return matches
	}
	type candidate struct {
		word     string
		distance int
	}
	candidates := []candidate{}
	for _, word := range wordlists.English {
		distance := wordDistance(prefix, word)
		// A mistyped partial word can still complete: "abnd" -> "abandon".
		// Prefix matches above always take priority; fuzzy prefixes allow one edit.
		for length := max(1, len(prefix)-1); length <= min(len(word), len(prefix)+1); length++ {
			if partial := wordDistance(prefix, word[:length]); partial <= 1 {
				distance = min(distance, partial)
			}
		}
		if distance <= 2 {
			candidates = append(candidates, candidate{word, distance})
		}
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].distance != candidates[j].distance {
			return candidates[i].distance < candidates[j].distance
		}
		return candidates[i].word < candidates[j].word
	})
	for i, value := range candidates {
		if i >= 8 {
			break
		}
		matches = append(matches, value.word)
	}
	return matches
}

func wordDistance(a, b string) int {
	left, right := []rune(a), []rune(b)
	previous := make([]int, len(right)+1)
	for j := range previous {
		previous[j] = j
	}
	for i, x := range left {
		current := make([]int, len(right)+1)
		current[0] = i + 1
		for j, y := range right {
			cost := 0
			if x != y {
				cost = 1
			}
			current[j+1] = min(current[j]+1, previous[j+1]+1, previous[j]+cost)
		}
		previous = current
	}
	return previous[len(right)]
}
