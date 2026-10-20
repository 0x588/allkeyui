#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$REPO_ROOT/.build/windows-poc"
PROJECT="$REPO_ROOT/WindowsPoC/AllKey.WindowsPoC.csproj"
DOTNET_EXECUTABLE="${DOTNET_BINARY:-}"
if [[ -z "$DOTNET_EXECUTABLE" ]]; then
  if command -v dotnet >/dev/null 2>&1; then
    DOTNET_EXECUTABLE="$(command -v dotnet)"
  else
    DOTNET_EXECUTABLE="$REPO_ROOT/.build/toolchains/dotnet/dotnet"
  fi
fi
[[ -x "$DOTNET_EXECUTABLE" ]] || { echo "Install .NET 10 SDK, or set DOTNET_BINARY." >&2; exit 1; }
WINDOWS_ARCH="${WINDOWS_ARCH:-amd64}"
case "$WINDOWS_ARCH" in
  amd64) WINDOWS_RID=win-x64; WINDOWS_CC="${WINDOWS_CC:-x86_64-w64-mingw32-gcc}" ;;
  arm64) WINDOWS_RID=win-arm64; WINDOWS_CC="${WINDOWS_CC:-aarch64-w64-mingw32-clang}" ;;
  *) echo "WINDOWS_ARCH must be amd64 or arm64." >&2; exit 1 ;;
esac
command -v "$WINDOWS_CC" >/dev/null || { echo "Missing Windows C compiler: $WINDOWS_CC" >&2; exit 1; }
NATIVE_OUTPUT="$OUTPUT/native/$WINDOWS_RID"

export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export DOTNET_GENERATE_ASPNET_CERTIFICATE=false
mkdir -p "$NATIVE_OUTPUT"

echo "Testing existing Go implementation"
(cd "$REPO_ROOT/NativeCore" && go test -count=1 ./...)

echo "Building $WINDOWS_RID Go DLL"
(cd "$REPO_ROOT/NativeCore" &&
  GOOS=windows GOARCH="$WINDOWS_ARCH" CGO_ENABLED=1 CC="$WINDOWS_CC" \
  go build -trimpath -buildmode=c-shared -o "$NATIVE_OUTPUT/allkeycore.dll" .)

case "$(uname -s)" in
  Darwin) HOST_OS=darwin; HOST_LIBRARY="$OUTPUT/liballkeycore.dylib" ;;
  Linux) HOST_OS=linux; HOST_LIBRARY="$OUTPUT/liballkeycore.so" ;;
  *) echo "Use verify_windows_poc.ps1 on Windows." >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) HOST_ARCH=arm64 ;;
  x86_64) HOST_ARCH=amd64 ;;
  *) echo "Unsupported host architecture." >&2; exit 1 ;;
esac

echo "Building host library and checking the same C# bridge locally"
(cd "$REPO_ROOT/NativeCore" &&
  GOOS="$HOST_OS" GOARCH="$HOST_ARCH" CGO_ENABLED=1 \
  go build -trimpath -buildmode=c-shared -o "$HOST_LIBRARY" .)
"$DOTNET_EXECUTABLE" build "$PROJECT" -c Release --nologo
"$DOTNET_EXECUTABLE" "$OUTPUT/managed/bin/Release/net10.0/AllKey.WindowsPoC.dll" \
  "$HOST_LIBRARY" 10000 | tee "$OUTPUT/host-verification.log"

echo "Publishing a self-contained $WINDOWS_RID validation bundle"
"$DOTNET_EXECUTABLE" publish "$PROJECT" -c Release -r "$WINDOWS_RID" --self-contained true \
  -o "$OUTPUT/$WINDOWS_RID" --nologo
cp "$NATIVE_OUTPUT/allkeycore.dll" "$OUTPUT/$WINDOWS_RID/allkeycore.dll"
cp "$REPO_ROOT/WindowsPoC/Run-Validation.ps1" "$OUTPUT/$WINDOWS_RID/Run-Validation.ps1"
cp "$REPO_ROOT/WindowsPoC/README.md" "$OUTPUT/$WINDOWS_RID/README.md"
cp "$REPO_ROOT/WindowsPoC/VALIDATION.md" "$OUTPUT/$WINDOWS_RID/VALIDATION.md"
if [[ -d "$REPO_ROOT/WindowsPoC/evidence" ]]; then
  cp -R "$REPO_ROOT/WindowsPoC/evidence" "$OUTPUT/$WINDOWS_RID/"
fi
echo "Ready: $OUTPUT/$WINDOWS_RID"
echo "Windows runtime validation is still required: run Run-Validation.ps1 inside that directory."
