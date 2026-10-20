param([ValidateRange(1, 100000)][int]$Iterations = 10000)
$ErrorActionPreference = 'Stop'
$program = Join-Path $PSScriptRoot 'AllKey.WindowsPoC.exe'
$library = Join-Path $PSScriptRoot 'allkeycore.dll'
$log = Join-Path $PSScriptRoot 'windows-verification.log'
& $program $library $Iterations 2>&1 | Tee-Object -FilePath $log
$result = $LASTEXITCODE
if ($result -ne 0) { throw "Validation failed (exit $result). See $log" }
Write-Host "Windows runtime validation passed. Log: $log"
