[CmdletBinding()]
param(
    [string]$Repo = 'phakphoum38-stack/DRIVE_VIRTUAL_CLOUD_CONTROL_PLANE',
    [switch]$Apply,
    [switch]$AllowOverwrite
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Stop-Bootstrap([string]$Message) { throw $Message }

function Invoke-NativeChecked {
    param([string]$Command, [string[]]$Arguments, [string]$FailureMessage = 'Native command failed.')
    $output = & $Command @Arguments 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $output) { Write-Host $line }
    if ($code -ne 0) { Stop-Bootstrap "$FailureMessage Exit code: $code" }
}

function Get-NativeOutput {
    param([string]$Command, [string[]]$Arguments, [string]$FailureMessage = 'Native command failed.')
    $output = & $Command @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        foreach ($line in $output) { Write-Host $line }
        Stop-Bootstrap "$FailureMessage Exit code: $code"
    }
    return (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Assert-RepoName([string]$Value) {
    $parts = $Value.Split('/')
    if ($parts.Count -ne 2) { Stop-Bootstrap 'Repo must use OWNER/REPOSITORY format.' }
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or $part -in @('.', '..')) {
            Stop-Bootstrap 'Repo contains an invalid owner or repository name.'
        }
    }
}

function Assert-NoReparsePointInPath {
    param([string]$Path, [string]$BoundaryRoot)
    $root = [IO.Path]::GetFullPath($BoundaryRoot).TrimEnd([char[]]@('\', '/'))
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if ($full -ine $root -and -not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Bootstrap "Path escapes its permitted root: $Path"
    }
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-Bootstrap "Permitted root is a reparse point: $root"
    }
    $relative = $full.Substring($root.Length).TrimStart([char[]]@('\', '/'))
    $current = $root
    foreach ($segment in ($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { break }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Bootstrap "Reparse point is not permitted: $current"
        }
    }
}

function Assert-RelativeTargetPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or [IO.Path]::IsPathRooted($Value) -or
        $Value -match '(^|[\\/])\.\.([\\/]|$)' -or $Value -match '^[A-Za-z]:') {
        Stop-Bootstrap "Unsafe target-relative path: $Value"
    }
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Get-IgnoreAppendPlan {
    param([string]$Path, [string[]]$Rules)
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $bytes = [byte[]]@()
    $hash = $null
    $text = ''
    $bom = $false
    if ($exists) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [Convert]::ToBase64String($sha.ComputeHash($bytes)) }
        finally { $sha.Dispose() }
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
            $bom = $true
            $payload = New-Object byte[] ($bytes.Length - 3)
            [Array]::Copy($bytes, 3, $payload, 0, $payload.Length)
        }
        else { $payload = $bytes }
        try {
            $decoder = New-Object System.Text.UTF8Encoding($false, $true)
            $text = $decoder.GetString($payload)
        }
        catch { Stop-Bootstrap '.gitignore is not valid UTF-8; refusing to rewrite it.' }
    }
    $lines = @($text -split "\r\n|\n|\r")
    $missing = @(
        foreach ($rule in $Rules) {
            if ($lines -cnotcontains $rule) { $rule }
        }
    )
    $newline = [Environment]::NewLine
    if ($text.Contains([string][char]10) -and -not $text.Contains(([string][char]13) + ([string][char]10))) {
        $newline = [string][char]10
    }
    elseif ($text.Contains([string][char]13) -and -not $text.Contains(([string][char]13) + ([string][char]10))) {
        $newline = [string][char]13
    }
    [pscustomobject]@{ Exists = $exists; Hash = $hash; Text = $text; Bom = $bom; Newline = $newline; Missing = $missing }
}

function Write-IgnoreAppend {
    param([string]$Path, [pscustomobject]$Plan)
    if ($Plan.Missing.Count -eq 0) { return }
    if ($Plan.Exists) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [Convert]::ToBase64String($sha.ComputeHash($bytes)) }
        finally { $sha.Dispose() }
        if ($hash -cne $Plan.Hash) { Stop-Bootstrap '.gitignore changed after planning; refusing to overwrite it.' }
    }
    elseif (Test-Path -LiteralPath $Path) {
        Stop-Bootstrap '.gitignore appeared after planning; refusing to overwrite it.'
    }
    $newText = $Plan.Text
    if ($newText.Length -gt 0 -and -not $newText.EndsWith([string][char]10) -and -not $newText.EndsWith([string][char]13)) {
        $newText += $Plan.Newline
    }
    $newText += ($Plan.Missing -join $Plan.Newline) + $Plan.Newline
    $payload = (New-Object System.Text.UTF8Encoding($false)).GetBytes($newText)
    if ($Plan.Bom) {
        $withBom = New-Object byte[] ($payload.Length + 3)
        $withBom[0] = 239; $withBom[1] = 187; $withBom[2] = 191
        [Array]::Copy($payload, 0, $withBom, 3, $payload.Length)
        $payload = $withBom
    }
    [IO.File]::WriteAllBytes($Path, $payload)
}

if ($AllowOverwrite -and -not $Apply) { Stop-Bootstrap '-AllowOverwrite requires -Apply.' }
Assert-RepoName $Repo
foreach ($name in @('gh', 'git')) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { Stop-Bootstrap "Required command not found: $name" }
}

$scriptPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($scriptPath)) { Stop-Bootstrap 'Run this file as a script; pasted commands are not supported.' }
$sourceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $scriptPath))
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\', '/'))
$workspace = Join-Path $tempRoot ('drive-virtual-cloud-control-plane-' + [guid]::NewGuid().ToString('N'))
$repoDir = Join-Path $workspace 'repo'
$preserveWorkspace = $true

$copies = [ordered]@{
    'virtual-cloud-runners.yml' = '.github/workflows/virtual-cloud-runners.yml'
    'virtual-cloud-drive-sync.yml' = '.github/workflows/virtual-cloud-drive-sync.yml'
    'build-control-center.yml' = '.github/workflows/build-control-center.yml'
    'bridge_worker.py' = 'tools/virtual-cloud/bridge_worker.py'
    'requirements.txt' = 'tools/virtual-cloud/requirements.txt'
    'bootstrap-control-plane.ps1' = 'tools/virtual-cloud/bootstrap-control-plane.ps1'
    'authorize-gdrive-user.ps1' = 'tools/virtual-cloud/authorize-gdrive-user.ps1'
    'build-control-center.ps1' = 'tools/virtual-cloud/build-control-center.ps1'
    'run-control-center.bat' = 'tools/virtual-cloud/run-control-center.bat'
    'control_center.py' = 'app/control_center.py'
    'README.md' = 'README.md'
    'CONTROL_CENTER_README.md' = 'CONTROL_CENTER_README.md'
    'AUDIT_REPORT.md' = 'AUDIT_REPORT.md'
}
$ignoreRules = @('*.json', '*credentials*.json', '*service-account*.json', '.env', '.env.*', '__pycache__/', '*.pyc', 'dist/', 'build/', '*.spec')

$missingSources = @()
foreach ($name in $copies.Keys) {
    $source = if ($name -eq 'bootstrap-control-plane.ps1') { $scriptPath } else { Join-Path $sourceRoot $name }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { $missingSources += $name }
    else { Assert-NoReparsePointInPath -Path $source -BoundaryRoot $sourceRoot }
}
if ($missingSources.Count -gt 0) {
    Stop-Bootstrap ('Required source files are missing: ' + ($missingSources -join ', '))
}

try {
    Assert-NoReparsePointInPath -Path $tempRoot -BoundaryRoot $tempRoot
    Assert-NoReparsePointInPath -Path $workspace -BoundaryRoot $tempRoot
    New-Item -ItemType Directory -Path $workspace -ErrorAction Stop | Out-Null
    Assert-NoReparsePointInPath -Path $workspace -BoundaryRoot $tempRoot

    if ($Apply) { Write-Warning 'APPLY: local feature-branch preparation only; no remote writes.' }
    else { Write-Host 'PLAN ONLY: no target files will be modified or published.' }

    Invoke-NativeChecked 'gh' @('auth', 'status') 'GitHub CLI authentication check failed.'
    $json = Get-NativeOutput 'gh' @('repo', 'view', $Repo, '--json', 'nameWithOwner,defaultBranchRef') 'Repository lookup failed; no repository will be created.'
    try { $info = $json | ConvertFrom-Json }
    catch { Stop-Bootstrap 'GitHub returned invalid repository metadata.' }
    if ([string]::IsNullOrWhiteSpace([string]$info.nameWithOwner) -or $info.nameWithOwner -ine $Repo) {
        Stop-Bootstrap 'Repository identity mismatch.'
    }
    $defaultBranch = [string]$info.defaultBranchRef.name
    if ([string]::IsNullOrWhiteSpace($defaultBranch) -or $defaultBranch -match '[\r\n]' -or $defaultBranch -match '(^|/)\.\.(/|$)') {
        Stop-Bootstrap 'Default branch metadata is invalid.'
    }

    Invoke-NativeChecked 'gh' @('repo', 'clone', $Repo, $repoDir) 'Failed to clone the verified repository.'
    Assert-NoReparsePointInPath -Path $repoDir -BoundaryRoot $workspace
    $cloneRoot = Get-NativeOutput 'git' @('-C', $repoDir, 'rev-parse', '--show-toplevel') 'Could not verify clone root.'
    if ([IO.Path]::GetFullPath($cloneRoot).TrimEnd([char[]]@('\', '/')) -ine [IO.Path]::GetFullPath($repoDir).TrimEnd([char[]]@('\', '/'))) {
        Stop-Bootstrap 'Clone root does not match isolated workspace.'
    }
    $origin = Get-NativeOutput 'git' @('-C', $repoDir, 'remote', 'get-url', 'origin') 'Could not verify clone origin.'
    $suffix = '/' + $Repo
    $cleanOrigin = $origin.TrimEnd('/')
    if (-not ($cleanOrigin -imatch ([regex]::Escape($suffix) + '(\.git)?$'))) {
        Stop-Bootstrap 'Clone origin does not match requested repository.'
    }
    $branch = Get-NativeOutput 'git' @('-C', $repoDir, 'branch', '--show-current') 'Could not verify checked-out branch.'
    if ($branch -cne $defaultBranch) { Stop-Bootstrap 'Clone is not on verified default branch.' }
    $baseSha = Get-NativeOutput 'git' @('-C', $repoDir, 'rev-parse', 'HEAD') 'Could not verify cloned base commit.'
    if ($baseSha -notmatch '^[0-9a-fA-F]{40,64}$') { Stop-Bootstrap 'Invalid cloned base commit.' }
    $remote = Get-NativeOutput 'git' @('-C', $repoDir, 'ls-remote', 'origin', "refs/heads/$defaultBranch") 'Could not verify remote default branch.'
    if (($remote -split '\s+')[0] -cne $baseSha) { Stop-Bootstrap 'Remote default branch changed during clone; re-run plan.' }

    $plan = @()
    foreach ($entry in $copies.GetEnumerator()) {
        Assert-RelativeTargetPath $entry.Value
        $source = if ($entry.Key -eq 'bootstrap-control-plane.ps1') { $scriptPath } else { Join-Path $sourceRoot $entry.Key }
        $target = Join-Path $repoDir ($entry.Value -replace '/', [IO.Path]::DirectorySeparatorChar)
        Assert-NoReparsePointInPath -Path $target -BoundaryRoot $repoDir
        $sourceHash = Get-FileSha256 $source
        if (Test-Path -LiteralPath $target) {
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { Stop-Bootstrap "Target is not a regular file: $($entry.Value)" }
            $action = if ((Get-FileSha256 $target) -ceq $sourceHash) { 'UNCHANGED' } else { 'UPDATE' }
        }
        else { $action = 'ADD' }
        $plan += [pscustomobject]@{ Source = $entry.Key; Target = $entry.Value; SourceHash = $sourceHash; Action = $action }
    }

    $ignorePath = Join-Path $repoDir '.gitignore'
    Assert-NoReparsePointInPath -Path $ignorePath -BoundaryRoot $repoDir
    if ((Test-Path -LiteralPath $ignorePath) -and -not (Test-Path -LiteralPath $ignorePath -PathType Leaf)) {
        Stop-Bootstrap '.gitignore is not a regular file.'
    }
    $ignorePlan = Get-IgnoreAppendPlan $ignorePath $ignoreRules

    Write-Host ([Environment]::NewLine + '=== FILE PLAN ===')
    foreach ($item in $plan) { Write-Host ("{0,-9} {1}" -f $item.Action, $item.Target) }
    foreach ($rule in $ignorePlan.Missing) { Write-Host ("APPEND    .gitignore (+{0})" -f $rule) }
    if ($ignorePlan.Missing.Count -eq 0) { Write-Host 'UNCHANGED .gitignore' }

    $updates = @($plan | Where-Object { $_.Action -eq 'UPDATE' })
    if ($Apply -and $updates.Count -gt 0 -and -not $AllowOverwrite) {
        Stop-Bootstrap 'Existing target files differ. Review every UPDATE, then use -Apply -AllowOverwrite.'
    }
    if (-not $Apply) {
        Write-Host ([Environment]::NewLine + 'Plan complete. No target files were changed.')
        $preserveWorkspace = $false
        return
    }

    $remote = Get-NativeOutput 'git' @('-C', $repoDir, 'ls-remote', 'origin', "refs/heads/$defaultBranch") 'Could not revalidate remote default branch.'
    if (($remote -split '\s+')[0] -cne $baseSha) { Stop-Bootstrap 'Default branch changed after planning; no files applied.' }

    $featureBranch = 'automation/bootstrap-sync-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    Invoke-NativeChecked 'git' @('-C', $repoDir, 'checkout', '-b', $featureBranch) 'Could not create isolated feature branch.'

    foreach ($entry in $plan) {
        if ($entry.Action -eq 'UNCHANGED') { continue }
        $source = if ($entry.Source -eq 'bootstrap-control-plane.ps1') { $scriptPath } else { Join-Path $sourceRoot $entry.Source }
        $target = Join-Path $repoDir ($entry.Target -replace '/', [IO.Path]::DirectorySeparatorChar)
        Assert-NoReparsePointInPath -Path $source -BoundaryRoot $sourceRoot
        Assert-NoReparsePointInPath -Path $target -BoundaryRoot $repoDir
        if ((Get-FileSha256 $source) -cne $entry.SourceHash) { Stop-Bootstrap "Source changed after planning: $($entry.Source)" }
        if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Stop-Bootstrap "Target is not a regular file: $($entry.Target)"
        }
        $parent = Split-Path -Parent $target
        Assert-NoReparsePointInPath -Path $parent -BoundaryRoot $repoDir
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        Assert-NoReparsePointInPath -Path $parent -BoundaryRoot $repoDir
        Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
        if ((Get-FileSha256 $target) -cne $entry.SourceHash) { Stop-Bootstrap "Post-copy hash verification failed: $($entry.Target)" }
    }

    if ($ignorePlan.Missing.Count -gt 0) {
        Assert-NoReparsePointInPath -Path $ignorePath -BoundaryRoot $repoDir
        Write-IgnoreAppend $ignorePath $ignorePlan
    }

    Invoke-NativeChecked 'git' @('-C', $repoDir, 'diff', '--check') 'Working-tree diff validation failed.'
    $status = Get-NativeOutput 'git' @('-C', $repoDir, 'status', '--short') 'Could not inspect prepared worktree.'
    Write-Host ([Environment]::NewLine + '=== PREPARED WORKTREE ===')
    if ([string]::IsNullOrWhiteSpace($status)) { Write-Host 'No changes were necessary.' } else { Write-Host $status }
    Write-Host "Local feature branch prepared: $featureBranch"
    Write-Host "Base commit: $baseSha"
    Write-Host "Workspace retained for review: $workspace"
    Write-Host 'No files were staged. No commit, push, PR, repository creation, or secret changes were performed.'
    $preserveWorkspace = $true
}
finally {
    if (-not $preserveWorkspace -and (Test-Path -LiteralPath $workspace -PathType Container)) {
        try {
            Assert-NoReparsePointInPath -Path $workspace -BoundaryRoot $tempRoot
            Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction Stop
        }
        catch { Write-Warning "Workspace cleanup skipped: $($_.Exception.Message)" }
    }
    elseif (Test-Path -LiteralPath $workspace -PathType Container) {
        Write-Warning "Diagnostic workspace retained: $workspace"
    }
}
