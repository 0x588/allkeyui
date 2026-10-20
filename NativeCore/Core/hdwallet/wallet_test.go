package hdwallet

import (
	"fmt"
	"testing"
)

func TestSol_GetAddress(t *testing.T) {
	/*

			patient board palm abandon right sort find blood grace sweet vote load action bag trash calm burden glow phrase shoot frog vacant elegant tourist
		derivation-path="m/44'/501'/0'/0'"
			pub: AYFf2pT5o1FqzwQmPM6pfW7sPdK4oVxwD7cHrt3X4jY8
			prv: 2WKuYzXcJk53A1ymJ2mH182TuqBfSnMShyoA4ma1b9cUxXi5fo1bm3Va4eTxRuafmpYwH2kNM1ioHdG8fYy1zSH2
			```
			derivation-path="m/44'/501'/1'/0'"
		pub: 4kVGwzQweEDciB7PxiYc2tg3EeGCBZNgighjcTtP4mao
		prv: 52JyCw73NWYKfkEUfZpUQKTvqVGyFD7tcMZCk49559jpRnCUJxcutmYCJcXkdqb5jpH7AFRBgCXn8U29R1BuhoBM

	*/
	mnemonic := "patient board palm abandon right sort find blood grace sweet vote load action bag trash calm burden glow phrase shoot frog vacant elegant tourist"
	master, err := NewKey(
		Mnemonic(mnemonic),
	)
	if err != nil {
		t.Error(err)
		return
	}
	wallet, err := master.GetWallet(CoinType(SOL), Account(ZeroQuote), Change(ZeroQuote), AddressIndex(ZeroQuote+0))
	if err != nil {
		t.Error(err)
		return
	}
	address, _ := wallet.GetAddress()
	private, _ := wallet.GetPrivateKey()
	fmt.Println(address, private)
}

func TestKey_GetWallets(t *testing.T) {
	mnemonic := "patient board palm abandon right sort find blood grace sweet vote load action bag trash calm burden glow phrase shoot frog vacant elegant tourist"
	master, err := NewKey(
		Mnemonic(mnemonic),
	)
	if err != nil {
		t.Error(err)
		return
	}
	wallets, err := master.GetWallets(4, Purpose(ZeroQuote+44), CoinType(BTC))
	for _, wallet := range wallets {
		address, _ := wallet.GetAddress()
		private, _ := wallet.GetPrivateKey()
		fmt.Println(address, private)
	}
}
