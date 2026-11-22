$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Files = @(Get-ChildItem -LiteralPath $Root -Filter "*.ps1" -File -Recurse)

if ($Files.Count -eq 0) {
    throw "No PowerShell scripts were found under $Root"
}

$Failed = @()
foreach ($File in $Files) {
    $Tokens = $null
    $ParseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $File.FullName,
        [ref]$Tokens,
        [ref]$ParseErrors
    )

    if ($ParseErrors.Count -gt 0) {
        $Details = $ParseErrors | ForEach-Object {
            "{0}:{1}: {2}" -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message
        }
        $Failed += [PSCustomObject]@{
            Path = $File.FullName
            Errors = ($Details -join [Environment]::NewLine)
        }
        continue
    }

    $Relative = $File.FullName.Substring($Root.Length).TrimStart([char[]]@([char]92, [char]47))
    Write-Host "PASS $Relative"
}

if ($Failed.Count -gt 0) {
    foreach ($Item in $Failed) {
        Write-Error ("Parse failed: {0}; {1}" -f $Item.Path, $Item.Errors)
    }
    throw "$($Failed.Count) PowerShell script(s) failed parsing."
}

Write-Host "Parsed $($Files.Count) PowerShell scripts successfully with PowerShell $($PSVersionTable.PSVersion)."
