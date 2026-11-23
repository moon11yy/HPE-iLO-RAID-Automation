#Requires -Version 7.0
$path = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\scripts\ilo7-bulk-two-raid1-public.ps1')).Path
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
if (@($parseErrors).Count -gt 0) {
  $parseErrors | Format-List | Out-String | Write-Error
  throw 'PowerShell syntax validation failed.'
}
Write-Host "PowerShell syntax OK: $path"
