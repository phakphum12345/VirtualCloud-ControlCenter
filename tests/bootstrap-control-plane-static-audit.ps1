$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-control-plane.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Bootstrap script not found: $scriptPath"
}

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    $details = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
    throw "PowerShell parser errors: $details"
}

$source = [IO.File]::ReadAllText($scriptPath)
$checks = [ordered]@{
    'Plan-only is the default' = ($source -match '\[switch\]\$Apply')
    'Repository identity is verified' = ($source -match 'nameWithOwner' -and $source -match 'Repository identity mismatch')
    'Remote branch is checked before and after planning' = ([regex]::Matches($source, 'ls-remote').Count -ge 2)
    'Reparse points are rejected' = ($source -match 'Assert-NoReparsePointInPath' -and $source -match 'FileAttributes\]::ReparsePoint')
    'Target paths are constrained' = ($source -match 'Assert-RelativeTargetPath')
    'Source hashes are revalidated' = ($source -match 'Source changed after planning')
    'Copied files are hash-verified' = ($source -match 'Post-copy hash verification failed')
    '.gitignore is read as bytes' = ($source -match 'ReadAllBytes')
    '.gitignore is written as bytes' = ($source -match 'WriteAllBytes')
    'Service-account JSON is ignored' = ($source -match '\*service-account\*\.json')
    'No repository creation command exists' = ($source -notmatch 'gh\s+repo\s+create')
    'No secret provisioning command exists' = ($source -notmatch 'gh\s+secret\s+set')
    'No automatic commit exists' = ($source -notmatch 'git\s+commit')
    'No push command exists' = ($source -notmatch 'git\s+push')
    'No broad git add exists' = ($source -notmatch 'git\s+add')
    'Apply retains its diagnostic workspace' = ($source -match 'Workspace retained for review')
}

$failed = @()
foreach ($name in $checks.Keys) {
    if ($checks[$name]) {
        Write-Host ("PASS  {0}" -f $name) -ForegroundColor Green
    }
    else {
        Write-Host ("FAIL  {0}" -f $name) -ForegroundColor Red
        $failed += $name
    }
}
if ($failed.Count -gt 0) {
    throw ("Static audit failed: " + ($failed -join ', '))
}
Write-Host 'Bootstrap static audit passed.' -ForegroundColor Green
