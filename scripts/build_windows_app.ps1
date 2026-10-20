param(
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [string]$CCompiler = ''
)
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$repo = Split-Path $PSScriptRoot -Parent
$rid = "win-$Architecture"
$output = Join-Path $repo '.build/windows-app'
$native = Join-Path $output "native/$rid"
New-Item -ItemType Directory -Force $native | Out-Null
if (-not $CCompiler) { $CCompiler = if ($Architecture -eq 'arm64') { 'aarch64-w64-mingw32-clang' } else { 'gcc' } }
$saved = @{}
foreach ($name in @('GOOS','GOARCH','CGO_ENABLED','CC')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
Push-Location (Join-Path $repo 'NativeCore')
try {
    $env:GOOS = 'windows'
    $env:GOARCH = if ($Architecture -eq 'arm64') { 'arm64' } else { 'amd64' }
    $env:CGO_ENABLED = '1'; $env:CC = $CCompiler
    & go build -trimpath -buildmode=c-shared '-ldflags=-s -w' -o (Join-Path $native 'allkeycore.dll') .
    if ($LASTEXITCODE -ne 0) { throw 'Go core build failed' }
} finally {
    Pop-Location
    foreach ($entry in $saved.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
}
& dotnet publish (Join-Path $repo 'Windows/AllKey.Desktop/AllKey.Desktop.csproj') `
    -c Release -r $rid --self-contained true -o (Join-Path $output $rid) --nologo
if ($LASTEXITCODE -ne 0) { throw 'Desktop application build failed' }
Copy-Item (Join-Path $native 'allkeycore.dll') (Join-Path $output "$rid/allkeycore.dll") -Force
Copy-Item (Join-Path $repo 'Windows/README.md') (Join-Path $output "$rid/README.md") -Force
Write-Host "Published: $output\$rid\AllKeyUI.exe"
