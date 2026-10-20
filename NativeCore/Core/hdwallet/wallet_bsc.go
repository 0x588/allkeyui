package hdwallet

import (
	"github.com/ethereum/go-ethereum/crypto"
)

func init() {
	coins[BSC] = newBsc
}

type bsc struct {
	name   string
	symbol string
	key    *Key

	// eth token
	contract string
}

func newBsc(key *Key) Wallet {
	return &bsc{
		name:   "Binance Smart Chain",
		symbol: "BSC",
		key:    key,
	}
}

func (c *bsc) GetType() uint32 {
	return c.key.Opt.CoinType
}

func (c *bsc) GetName() string {
	return c.name
}

func (c *bsc) GetSymbol() string {
	return c.symbol
}

func (c *bsc) GetKey() *Key {
	return c.key
}

func (c *bsc) GetAddress() (string, error) {
	return crypto.PubkeyToAddress(*c.key.PublicECDSA).Hex(), nil
}

func (c *bsc) GetPrivateKey() (string, error) {
	return c.key.PrivateHex(), nil
}
