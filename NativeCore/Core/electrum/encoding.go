package electrum

import (
	"fmt"
	"math"
	"math/big"
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

// BitLen returns the number of bits needed to represent n
func BitLen(n int) int {
	return int(math.Ceil(math.Log2(float64(n))))
}

// Encode converts byte data to mnemonic words using the given wordlist
func Encode(data []byte, wordlist []string) string {
	dataBitLen := len(data) * 8
	wordBitLen := BitLen(len(wordlist))
	wordCount := dataBitLen / wordBitLen

	// Mask extra bits
	MaskBytes(data, wordCount*wordBitLen)

	// Convert bytes to binary string
	binStr := bufferToBin(data)
	binStr = binStr[len(binStr)-wordCount*wordBitLen:]

	result := make([]string, wordCount)
	for i := 0; i < wordCount; i++ {
		wordBin := binStr[i*wordBitLen : (i+1)*wordBitLen]
		idx := binToInt(wordBin)
		result[i] = wordlist[idx]
	}

	return strings.Join(result, " ")
}

func GetIndexFromMnemonic(mnemonic string, wordlist []string) (*big.Int, error) {
	words := strings.Split(mnemonic, " ")
	diff := 12 - len(words)
	for diff > 0 {
		words = append(words, wordlist[0])
		diff--
	}
	bytes, err := Decode(strings.Join(words, " "), wordlist)
	if err != nil {
		return nil, err
	}
	return big.NewInt(0).SetBytes(bytes), nil
}

// Decode converts mnemonic words back to bytes using the given wordlist
func Decode(mnemonic string, wordlist []string) ([]byte, error) {
	words := strings.Split(mnemonic, " ")
	wordBitLen := BitLen(len(wordlist))

	var binStr string
	for _, word := range words {
		index := -1
		for i, w := range wordlist {
			if w == word {
				index = i
				break
			}
		}
		if index == -1 {
			return nil, fmt.Errorf("unknown word: %s", word)
		}
		binStr += lpad(fmt.Sprintf("%b", index), "0", wordBitLen)
	}

	byteLen := (len(binStr) + 7) / 8
	result := make([]byte, byteLen)
	paddedStr := lpad(binStr, "0", byteLen*8)

	for i := 0; i < byteLen; i++ {
		result[i] = byte(binToInt(paddedStr[i*8 : (i+1)*8]))
	}

	return result, nil
}

// MaskBytes masks extra bits in the byte array
func MaskBytes(bytes []byte, bits int) {
	skipByteCount := bits / 8
	lastByteMask := byte((1 << uint(bits%8)) - 1)

	for i := len(bytes) - 1 - skipByteCount; i >= 0; i-- {
		bytes[i] &= lastByteMask
		if lastByteMask != 0 {
			lastByteMask = 0
		}
	}
}

// NormalizeText normalizes the input text according to Electrum rules
func NormalizeText(str string) string {
	// 1. NFKD normalize
	str = norm.NFKD.String(str)

	// 2. lowercase
	str = strings.ToLower(str)

	// 3. remove accents
	str = removeCombiningCharacters(str)

	// 4. normalize whitespace
	str = strings.Join(strings.Fields(str), " ")

	// 5. remove whitespace between CJK characters
	return removeCJKSpaces(str)
}

func removeCombiningCharacters(str string) string {
	result := strings.Builder{}
	for _, r := range str {
		if !unicode.Is(unicode.Mn, r) {
			result.WriteRune(r)
		}
	}
	return result.String()
}

func removeCJKSpaces(str string) string {
	runes := []rune(str)
	var result []rune

	for i := 0; i < len(runes); i++ {
		if unicode.IsSpace(runes[i]) &&
			i > 0 && isCJK(runes[i-1]) &&
			i+1 < len(runes) && isCJK(runes[i+1]) {
			continue
		}
		result = append(result, runes[i])
	}

	return string(result)
}

func isCJK(r rune) bool {
	ranges := [][2]rune{
		{0x4E00, 0x9FFF},   // CJK Unified Ideographs
		{0x3400, 0x4DBF},   // CJK Unified Ideographs Extension A
		{0x20000, 0x2A6DF}, // CJK Unified Ideographs Extension B
		{0x2A700, 0x2B73F}, // CJK Unified Ideographs Extension C
		{0x2B740, 0x2B81F}, // CJK Unified Ideographs Extension D
		{0x2B820, 0x2CEAF}, // CJK Unified Ideographs Extension E
		{0xF900, 0xFAFF},   // CJK Compatibility Ideographs
	}

	for _, rang := range ranges {
		if r >= rang[0] && r <= rang[1] {
			return true
		}
	}
	return false
}

func bufferToBin(data []byte) string {
	var result strings.Builder
	for _, b := range data {
		result.WriteString(lpad(fmt.Sprintf("%b", b), "0", 8))
	}
	return result.String()
}

func lpad(str, pad string, length int) string {
	for len(str) < length {
		str = pad + str
	}
	return str
}

func binToInt(s string) int {
	var result int
	for _, c := range s {
		result = result*2 + int(c-'0')
	}
	return result
}
