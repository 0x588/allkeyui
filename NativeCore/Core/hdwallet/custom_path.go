package hdwallet

// GetWalletAtPath derives exactly the supplied child sequence, without the
// standard-path aliases (for example BSC -> ETH) or implicit default components.
func (k *Key) GetWalletAtPath(coinType uint32, path []uint32) (Wallet, error) {
	constructor, ok := coins[coinType]
	if !ok {
		return nil, ErrCoinTypeUnknow
	}
	extended, solKey := k.Extended, k.SolKey
	for _, child := range path {
		var err error
		if coinType == SOL {
			solKey, err = solKey.Derive(child)
		} else {
			extended, err = extended.Derive(child)
		}
		if err != nil {
			return nil, err
		}
	}
	key := &Key{Opt: newOptions(CoinType(coinType)), Extended: extended, SolKey: solKey}
	if err := key.init(); err != nil {
		return nil, err
	}
	return constructor(key), nil
}
