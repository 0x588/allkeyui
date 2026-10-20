package base

import (
	"fmt"
	"strconv"
	"strings"

	"allkeyui/nativecore/Core/hdwallet"
)

// ResolveCustomPath requires an explicit index placeholder so pagination never
// silently derives the same key repeatedly. Apostrophe marks hardened children.
func ResolveCustomPath(template string, index uint32) ([]uint32, string, error) {
	template = strings.TrimSpace(template)
	if len(template) > 255 || !strings.HasPrefix(template, "m/") || strings.Count(template, "{index}") != 1 {
		return nil, "", fmt.Errorf("自定义路径必须以 m/ 开头，并包含且仅包含一个 {index}")
	}
	parts := strings.Split(strings.TrimPrefix(template, "m/"), "/")
	if len(parts) < 1 || len(parts) > 10 {
		return nil, "", fmt.Errorf("自定义路径须包含 1–10 层")
	}
	children := make([]uint32, 0, len(parts))
	resolved := make([]string, 0, len(parts))
	for _, part := range parts {
		hardened := strings.HasSuffix(part, "'")
		token := strings.TrimSuffix(part, "'")
		number := uint64(index)
		if token != "{index}" {
			if token == "" {
				return nil, "", fmt.Errorf("自定义路径存在空层")
			}
			for _, c := range token {
				if c < '0' || c > '9' {
					return nil, "", fmt.Errorf("路径每层仅支持十进制数字或 {index}，末尾可带 '")
				}
			}
			var err error
			number, err = strconv.ParseUint(token, 10, 31)
			if err != nil {
				return nil, "", fmt.Errorf("路径各层编号须在 0–2147483647 之间")
			}
		}
		if number >= uint64(hdwallet.ZeroQuote) {
			return nil, "", fmt.Errorf("路径索引超出范围")
		}
		child := uint32(number)
		text := strconv.FormatUint(number, 10)
		if hardened {
			child += hdwallet.ZeroQuote
			text += "'"
		}
		children = append(children, child)
		resolved = append(resolved, text)
	}
	return children, "m/" + strings.Join(resolved, "/"), nil
}
