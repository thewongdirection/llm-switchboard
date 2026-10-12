# Closes any terminal tab left open by the verification tests (tabs titled "SB-TEST-..."), e.g. after a test run
# was hard-killed and could not clean up after itself. Touches nothing else: only exact-prefix matches on tab titles.
#
#   pwsh -File tests\close-test-terminals.ps1
. (Join-Path $PSScriptRoot 'terminal.ps1')

$closed = 0
foreach ($t in @(Get-TerminalTabs | Where-Object { $_.Title -like 'SB-TEST-*' })) {
    $n = Close-TerminalTab $t.Title
    $closed += $n
    Write-Host ("closed {0} tab titled '{1}'" -f $n, $t.Title)
}
if (-not $closed) { Write-Host 'No test terminals are open.' }
