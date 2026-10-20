package base

type AddrItem struct {
	KeyFormat string `json:"key_format,omitempty"`
	Coin      string `json:"coin"`
	Path      string `json:"path"`
	HexKey    string `json:"hex_key"`
	KeyTag    string `json:"key_tag"`
	Addr      string `json:"addr"`
	AddrTag   string `json:"addr_tag"`
	Balance   string `json:"balance"`
	Tx        string `json:"tx"`
	Received  string `json:"received"`
}

type MneRes struct {
	Zjc     string      `json:"zjc"`
	Index   string      `json:"index"`
	Max     string      `json:"max"`
	Percent string      `json:"percent"`
	Token   string      `json:"token"`
	List    []*AddrItem `json:"list"`
}
