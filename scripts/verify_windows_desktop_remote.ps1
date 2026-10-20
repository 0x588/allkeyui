param(
    [Parameter(Mandatory = $true)][string]$BaseUri,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSha256
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$BaseUri = $BaseUri.TrimEnd('/')
$work = Join-Path $env:LOCALAPPDATA ('AllKeyUI\DesktopValidation\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$report = [ordered]@{status='started'; testedAtUtc=[DateTime]::UtcNow.ToString('o'); os=$null; cpu=$null; bundleSha256=$ExpectedSha256; core=$null; ui=$null; error=$null}
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = @(Get-CimInstance Win32_Processor)
    $report.os = $os.Caption + ' ' + $os.Version
    $report.cpu = @($cpu | Select-Object -ExpandProperty Name -Unique) -join '; '
    if (@($cpu | Where-Object Architecture -ne 9).Count) { throw 'This bundle requires native x64 Windows.' }
    $archive = Join-Path $work 'app.zip'
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUri/bundle.zip" -OutFile $archive
    if ((Get-FileHash -Algorithm SHA256 $archive).Hash -ne $ExpectedSha256) { throw 'Bundle hash mismatch.' }
    Expand-Archive -LiteralPath $archive -DestinationPath $work
    $bundle = Join-Path $work 'win-x64'
    $program = Join-Path $bundle 'AllKeyUI.exe'
    $coreReport = Join-Path $work 'core.json'
    # GUI executables report through JSON files; do not redirect console handles.
    $process = Start-Process -FilePath $program -PassThru -ArgumentList @('--verify-core','--report',('"' + $coreReport + '"')) -WorkingDirectory $bundle
    $null = $process.Handle
    if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Core verification timed out.' }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or -not (Test-Path $coreReport)) { throw 'Core verification failed. See local core log.' }
    $report.core = Get-Content -LiteralPath $coreReport -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($report.core.status -ne 'passed' -or $report.core.architecture -ne 'X64') { throw 'Core assertions failed.' }
    Write-Host "CORE PASS: $($report.core.checks.Count) checks"
    $uiReport = Join-Path $work 'ui.json'
    $data = Join-Path $work 'ui-data'
    $ui = Start-Process -FilePath $program -PassThru -ArgumentList @('--ui-smoke','--data-dir',('"'+$data+'"'),'--report',('"'+$uiReport+'"')) -WorkingDirectory $bundle
    $null = $ui.Handle
    $deadline = (Get-Date).AddSeconds(120)
    while (-not (Test-Path $uiReport)) {
        if ($ui.HasExited) { throw 'Desktop app exited before reporting. See local UI log.' }
        if ((Get-Date) -gt $deadline) { $ui.Kill(); throw 'UI verification timed out.' }
        Start-Sleep -Milliseconds 200
    }
    $report.ui = Get-Content -LiteralPath $uiReport -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($report.ui.status -ne 'passed' -or $report.ui.architecture -ne 'X64') { throw ('UI assertions failed: ' + $report.ui.error) }
    $report.status = 'passed'
    Write-Host "UI PASS: $($report.ui.checks.Count) checks; app left open for visual inspection"
} catch {
    $report.status = 'failed'; $report.error = $_.Exception.Message
} finally {
    $json = $report | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText((Join-Path $work 'desktop-validation.json'), $json, (New-Object Text.UTF8Encoding($false)))
    Invoke-RestMethod -Method Post -Uri "$BaseUri/report" -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
    Write-Host "Report: $work\desktop-validation.json"
}
if ($report.status -ne 'passed') { throw $report.error }
Write-Host 'ALLKEY DESKTOP VALIDATION PASSED'
