#requires -Version 7.0
# Unit check for the autotune VRAM-margin clamp (no GPU or dashboard needed):  pwsh -File tests/test-margin.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'lib.ps1')
$cases = @(@($null, 1000), @('', 1000), @('abc', 1000), @(0, 256), @(-5, 256), @(512, 512), @('1500', 1500), @(2000, 2000), @(999999, 4096), @(3000000000, 4096), @(1500.5, 1500), @(' 750 ', 750), @('1e3', 1000), @([double]::NaN, 1000))
$fail = 0
foreach ($c in $cases) {
    $got = Get-MarginMiB $c[0]
    $ok = $got -eq $c[1]
    if (-not $ok) { $fail++ }
    Write-Host ('{0}  Get-MarginMiB({1}) = {2} (expected {3})' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), "$($c[0])", $got, $c[1]) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}
exit $(if ($fail) { 1 } else { 0 })
