param(
    [Parameter(Mandatory = $true)][string]$BaseUri,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSha256,
    [ValidateRange(1, 100)][int]$StartupRuns = 10
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$BaseUri = $BaseUri.TrimEnd('/')
$work = Join-Path $env:LOCALAPPDATA ('AllKeyUI\Validation\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$report = [ordered]@{
    testedAtUtc = [DateTime]::UtcNow.ToString('o')
    status = 'started'
    osCaption = $null
    osVersion = $null
    cpuName = $null
    cpuArchitectureCodes = @()
    bundleSha256 = $ExpectedSha256.ToLowerInvariant()
    iterationsPerRun = 10000
    runs = @()
    error = $null
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = @(Get-CimInstance Win32_Processor)
    $report.osCaption = $os.Caption
    $report.osVersion = $os.Version
    $report.cpuName = @($cpu | Select-Object -ExpandProperty Name -Unique) -join '; '
    $report.cpuArchitectureCodes = @($cpu | Select-Object -ExpandProperty Architecture -Unique)
    Write-Host "OS: $($report.osCaption) $($report.osVersion)"
    Write-Host "CPU: $($report.cpuName)"
    if ($report.cpuArchitectureCodes.Count -ne 1 -or $report.cpuArchitectureCodes[0] -ne 9) {
        throw 'This package must be validated on native Intel/AMD x64 Windows (architecture code 9).'
    }

    $archive = Join-Path $work 'bundle.zip'
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUri/bundle.zip" -OutFile $archive
    if ((Get-FileHash -Algorithm SHA256 $archive).Hash -ne $ExpectedSha256) {
        throw 'Downloaded bundle SHA256 does not match.'
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $work
    $bundle = Join-Path $work 'win-x64'
    $program = Join-Path $bundle 'AllKey.WindowsPoC.exe'
    $library = Join-Path $bundle 'allkeycore.dll'

    # A full run, followed by independent process startups. Bound every child lifetime.
    for ($i = 0; $i -le $StartupRuns; $i++) {
        $stdoutPath = Join-Path $work "run-$i.log"
        $stderrPath = Join-Path $work "run-$i.stderr.log"
        $process = Start-Process -FilePath $program -ArgumentList @(('"' + $library + '"'), '10000') `
            -WorkingDirectory $bundle -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        try {
            $null = $process.Handle
            if (-not $process.WaitForExit(60000)) {
                $process.Kill()
                $process.WaitForExit()
                throw "Run $i exceeded the 60 second limit."
            }
            $process.WaitForExit()
            $output = [string](Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8)
            $stderr = [string](Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8)
            $exitCode = $process.ExitCode
        } finally {
            $process.Dispose()
        }
        $result = [ordered]@{run = $i; exitCode = $exitCode; summary = $null; stdout = $output; stderr = $stderr}
        $report.runs += $result
        if ($exitCode -ne 0) { throw "Run $i failed with exit code $exitCode." }
        $match = [regex]::Match($output, '(?s)\{.*\}\s*$')
        if (-not $match.Success) { throw "Run $i returned no JSON summary." }
        $summary = $match.Value | ConvertFrom-Json
        $result.summary = $summary
        if ($summary.status -ne 'passed' -or $summary.architecture -ne 'X64' -or
            $summary.vectorsPassed -ne 16 -or $summary.repeatedCalls -ne 10000 -or
            $summary.responsesReceived -ne 10016 -or $summary.responsesFreed -ne 10016) {
            throw "Run $i did not satisfy all x64 validation assertions."
        }
        Write-Host "PASS run $i : 16 vectors, 10000 repeated calls, 10016 responses freed"
    }
    $report.status = 'passed'
} catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
} finally {
    $json = $report | ConvertTo-Json -Depth 10
    $reportPath = Join-Path $work 'remote-validation.json'
    [IO.File]::WriteAllText($reportPath, $json, (New-Object Text.UTF8Encoding($false)))
    Invoke-RestMethod -Method Post -Uri "$BaseUri/report" -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
    Write-Host "Report saved: $reportPath"
}
if ($report.status -ne 'passed') { throw $report.error }
Write-Host 'REMOTE X64 VALIDATION PASSED'
