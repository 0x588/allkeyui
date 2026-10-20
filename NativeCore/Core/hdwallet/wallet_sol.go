package hdwallet

func init() {
	coins[SOL] = newSOL
}

type Sol struct {
	name   string
	symbol string
	key    *Key
}

func newSOL(key *Key) Wallet {
	return &Sol{
		name:   "Solana",
		symbol: "sol",
		key:    key,
	}
}

func (c *Sol) GetType() uint32 {
	return c.key.Opt.CoinType
}

func (c *Sol) GetName() string {
	return c.name
}

func (c *Sol) GetSymbol() string {
	return c.symbol
}

func (c *Sol) GetKey() *Key {
	return c.key
}

func (c *Sol) GetAddress() (string, error) {
	return c.key.AddressSol()
}

func (c *Sol) GetPrivateKey() (string, error) {
	return c.key.PrivateKeySol()
}
