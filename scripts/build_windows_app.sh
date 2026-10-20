#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$REPO_ROOT/.build/windows-app"
DOTNET_EXECUTABLE="${DOTNET_BINARY:-}"
if [[ -z "$DOTNET_EXECUTABLE" ]]; then
  if command -v dotnet >/dev/null 2>&1; then DOTNET_EXECUTABLE="$(command -v dotnet)";
  else DOTNET_EXECUTABLE="$REPO_ROOT/.build/toolchains/dotnet/dotnet"; fi
fi
[[ -x "$DOTNET_EXECUTABLE" ]] || { echo 'Install .NET 10 SDK, or set DOTNET_BINARY.' >&2; exit 1; }
WINDOWS_ARCH="${WINDOWS_ARCH:-amd64}"
case "$WINDOWS_ARCH" in
  amd64) RID=win-x64; WINDOWS_CC="${WINDOWS_CC:-x86_64-w64-mingw32-gcc}" ;;
  arm64) RID=win-arm64; WINDOWS_CC="${WINDOWS_CC:-aarch64-w64-mingw32-clang}" ;;
  *) echo 'WINDOWS_ARCH must be amd64 or arm64.' >&2; exit 1 ;;
esac
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_GENERATE_ASPNET_CERTIFICATE=false
mkdir -p "$OUTPUT/native/$RID"
echo "Building Go core for $RID"
(cd "$REPO_ROOT/NativeCore" && GOOS=windows GOARCH="$WINDOWS_ARCH" CGO_ENABLED=1 CC="$WINDOWS_CC" \
  go build -trimpath -buildmode=c-shared -ldflags='-s -w' -o "$OUTPUT/native/$RID/allkeycore.dll" .)
"$DOTNET_EXECUTABLE" publish "$REPO_ROOT/Windows/AllKey.Desktop/AllKey.Desktop.csproj" \
  -c Release -r "$RID" --self-contained true -o "$OUTPUT/$RID" --nologo
cp "$OUTPUT/native/$RID/allkeycore.dll" "$OUTPUT/$RID/allkeycore.dll"
cp "$REPO_ROOT/Windows/README.md" "$OUTPUT/$RID/README.md"
echo "Published: $OUTPUT/$RID/AllKeyUI.exe"
