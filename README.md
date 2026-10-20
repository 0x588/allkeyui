# AllKey

[English](README.md) | [简体中文](README.zh-CN.md)

AllKey is a **multi-coin private-key and mnemonic library** for **macOS and Windows**. Browse private keys and BIP39 / Electrum mnemonics, derive addresses in batches, and navigate by index, page or random selection. It supports **BTC, ETH, BSC, LTC, DOGE, TRX and SOL**, with BTC address-type selection, custom derivation paths and mnemonic search tools.

**Local processing keeps your secrets on your computer.** Key generation, address derivation and mnemonic searches run locally. Private keys, mnemonics, passphrases and derivation paths are not sent to balance providers.

**Query balances alongside your library results.** Configure providers to check public-address balances, filter funded addresses or transaction activity, and refresh results as needed. Balance requests send only public addresses, with primary/backup services, incremental updates and successful-result caching. See [Privacy and settings](#privacy-and-settings) for storage and configuration details.

## Download

Download **v0.1.4** from [GitHub Releases](https://github.com/0x588/allkeyui/releases/latest).

| Platform | Download | Requirements |
| --- | --- | --- |
| macOS Universal | [AllKey-macOS-universal.zip](https://github.com/0x588/allkeyui/releases/latest/download/AllKey-macOS-universal.zip) | macOS 13+, Apple Silicon or Intel |
| Windows x64 | [AllKeyUI-win-x64.zip](https://github.com/0x588/allkeyui/releases/latest/download/AllKeyUI-win-x64.zip) | 64-bit Windows, Intel or AMD |
| Windows ARM64 | [AllKeyUI-win-arm64.zip](https://github.com/0x588/allkeyui/releases/latest/download/AllKeyUI-win-arm64.zip) | Native ARM64 Windows |
| Checksums | [SHA256SUMS.txt](https://github.com/0x588/allkeyui/releases/latest/download/SHA256SUMS.txt) | SHA-256 hashes for release assets |

**macOS:** unzip and move `AllKeyUI.app` to Applications. This release is not Developer ID signed or notarized; macOS may require approval in System Settings → Privacy & Security after an initial launch attempt.

**Windows:** extract the entire archive and run `AllKeyUI.exe` inside its platform directory. Keep all DLLs and JSON files together. The .NET runtime is included; no Go or .NET installation is needed. The portable executables are unsigned. Select the package matching your native system architecture.

The README is bilingual; the current application interface is primarily Chinese.

## Features

- **Private-key library:** BTC, ETH, BSC, LTC, DOGE, TRX and SOL; HEX/WIF validation, batch derivation, first/last/previous/next/random navigation, and BTC address-type selection.
- **BIP39:** 12–24 words, passphrases, account and address indexes, standard or custom derivation paths, word completion, local public-address matching, and cancellable missing-word searches using `?` placeholders.
- **Mnemonic directory:** multiple groups per page, independent navigation, first-address previews, balance filters, and single-group details.
- **Electrum:** Standard and SegWit mnemonics, address derivation, index navigation, and phrase lookup.
- **BTC Puzzle:** an offline catalog of 160 public challenges with search, status filters, exact key ranges and range navigation. Opening the page automatically queries public target balances through your configured BTC service. Solved status remains a dated snapshot, independent of live balances.
- **Crypto calculator:** 46 operations across key/address/WIF conversion, hashes, encodings, and non-EC-multiply BIP38, with line-by-line batch processing.
- **Balances:** configurable primary/backup providers, incremental results, bounded concurrency, 60-second successful-result cache, manual forced refresh, and funded/activity/failure filters. Failures are not treated as zero balances.
- **Custom EVM networks:** HTTPS RPC, chain-ID verification, native-coin units, explorer links and network-specific caches.

![BTC Puzzle on Windows](Windows/evidence/results-0.1.3-puzzle.png)

## Privacy and settings

Private keys, mnemonics, passphrases and derivation paths stay on your computer. Balance requests send public addresses to the providers you configure. Generated-address auto-refresh is off by default; the public BTC Puzzle catalog refreshes on page entry. Balance queries require a configured service and may require a provider API key.

Provider URLs and API keys are stored **in plaintext** in the local `balance-settings.json`, with permissions restricted to the current user. Open its folder from Settings to find the exact path. On Windows it is under `%LOCALAPPDATA%\AllKeyUI`. Sensitive clipboard contents are cleared after 60 seconds only if the clipboard still contains the copied value.

No personal configuration or build output is published in the source repository. Use public test vectors when evaluating the application.

## Build from source

Clone the repository:

```bash
git clone https://github.com/0x588/allkeyui.git
cd allkeyui
```

### macOS

Requirements: macOS 13+, Xcode (the project was validated with Xcode 27), and Go 1.24+.

Open `AllKeyUI.xcodeproj`, select the `AllKeyUI` scheme and Run. The build compiles the bundled Go core for Apple Silicon and Intel. If Go is outside the usual installation paths, set the target build setting `GO_BINARY` to its full path.

```bash
xcodebuild -project AllKeyUI.xcodeproj -scheme AllKeyUI \
  -configuration Release -derivedDataPath .build/ReleaseDerived \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
```

The app is produced at `.build/ReleaseDerived/Build/Products/Release/AllKeyUI.app`.

### Windows

Requirements: .NET 10 SDK, Go 1.24+, and a C compiler matching the target Windows architecture. Visual Studio can open the C# project; publishing also builds the native Go DLL.

On Windows with MinGW-w64 / LLVM-MinGW:

```powershell
& .\scripts\build_windows_app.ps1
& .\scripts\build_windows_app.ps1 -Architecture arm64 -CCompiler 'C:\llvm-mingw\bin\aarch64-w64-mingw32-clang.exe'
```

Cross-build on macOS or Linux:

```bash
bash scripts/build_windows_app.sh
WINDOWS_ARCH=arm64 WINDOWS_CC=/path/to/aarch64-w64-mingw32-clang \
  bash scripts/build_windows_app.sh
```

Outputs: `.build/windows-app/win-x64` and `.build/windows-app/win-arm64`. See [Windows build and verification instructions](Windows/README.md).

## Tests and release status

```bash
(cd NativeCore && go test ./...)
xcodebuild -project AllKeyUI.xcodeproj -scheme AllKeyUI \
  -configuration Debug -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

The v0.1.4 Windows ARM64 package passed 34 core/service checks and 111 UI checks on Windows 11. The same desktop UI passed 111 checks on the macOS development host. The x64 Windows package was cross-built; its last native Windows 10 regression was v0.1.3 (34 core/service and 106 UI checks). The macOS page-entry balance change passed three targeted tests. Provider tests use fixtures, not personal wallets or live provider accounts.

This is an early portable release. Signing/notarization, installers, automatic updates, full interface localization, and broader manual testing remain pending. Provider availability and account quotas depend on your configuration.

## Source layout

- `AllKeyUI/`, `AllKeyUITests/`: macOS application and Swift tests.
- `NativeCore/`: shared Go implementation and tests.
- `Windows/`: Windows UI, services and verification tools.
- `WindowsPoC/`: initial native-bridge verification project.
- `scripts/`: build and validation scripts.
- `THIRD_PARTY_NOTICES/`: third-party license texts distributed with releases.

`docs/`, `.build/`, local IDE state and personal settings are excluded from the public repository. Downloadable binaries are attached to GitHub Releases.
