param(
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [string]$CCompiler = ''
)
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$repoRoot = Split-Path $PSScriptRoot -Parent
$output = Join-Path $repoRoot '.build/windows-poc'
$rid = "win-$Architecture"
$nativeOutput = Join-Path $output "native/$rid"
New-Item -ItemType Directory -Force -Path $nativeOutput | Out-Null
if (-not $CCompiler) {
    $CCompiler = if ($Architecture -eq 'arm64') { 'aarch64-w64-mingw32-clang' } else { 'gcc' }
}

function Assert-NativeExit([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "$Step failed: exit $LASTEXITCODE" }
}

# Limit cross-compilation settings to this script, including when dot-sourced.
$savedEnvironment = @{}
foreach ($name in @('GOOS', 'GOARCH', 'CGO_ENABLED', 'CC')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
Push-Location (Join-Path $repoRoot 'NativeCore')
try {
    $env:GOOS = 'windows'
    $env:GOARCH = if ($Architecture -eq 'arm64') { 'arm64' } else { 'amd64' }
    $env:CGO_ENABLED = '1'
    $env:CC = $CCompiler
    & go test -count=1 ./...
    Assert-NativeExit 'Go tests'
    & go build -trimpath -buildmode=c-shared -o (Join-Path $nativeOutput 'allkeycore.dll') .
    Assert-NativeExit 'Go DLL build'
} finally {
    Pop-Location
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
}

& dotnet publish (Join-Path $repoRoot 'WindowsPoC/AllKey.WindowsPoC.csproj') `
    -c Release -r $rid --self-contained true -o (Join-Path $output $rid) --nologo
Assert-NativeExit 'C# publish'
Copy-Item (Join-Path $nativeOutput 'allkeycore.dll') (Join-Path $output "$rid/allkeycore.dll") -Force
Copy-Item (Join-Path $repoRoot 'WindowsPoC/Run-Validation.ps1') (Join-Path $output "$rid/Run-Validation.ps1") -Force
Copy-Item (Join-Path $repoRoot 'WindowsPoC/README.md') (Join-Path $output "$rid/README.md") -Force
Copy-Item (Join-Path $repoRoot 'WindowsPoC/VALIDATION.md') (Join-Path $output "$rid/VALIDATION.md") -Force
if (Test-Path (Join-Path $repoRoot 'WindowsPoC/evidence')) {
    Copy-Item (Join-Path $repoRoot 'WindowsPoC/evidence') (Join-Path $output $rid) -Recurse -Force
}
& (Join-Path $output "$rid/Run-Validation.ps1")
Assert-NativeExit 'Windows bridge verification'
