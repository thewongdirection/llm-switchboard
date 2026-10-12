# Windows Terminal tab helpers for the tests.
#
# Killing a terminal's process does NOT close its tab: Windows Terminal keeps the dead tab open ("[process exited]").
# These helpers close a tab through the terminal's own UI (the tab's "Close Tab" button, via UI Automation), and only
# a tab whose title matches EXACTLY - so a test can never close a tab it did not open.
#
#   . .\tests\terminal.ps1
#   Get-TerminalTabs                       # every tab in every Windows Terminal window
#   Close-TerminalTab 'SB-TEST-12345'      # returns how many tabs were closed

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

function Get-TerminalTabs {
    foreach ($w in @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })) {
        try {
            $root = [Windows.Automation.AutomationElement]::FromHandle($w.MainWindowHandle)
            $isTab = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::TabItem)
            foreach ($t in $root.FindAll([Windows.Automation.TreeScope]::Descendants, $isTab)) {
                [pscustomobject]@{ WindowPid = $w.Id; Title = $t.Current.Name; Element = $t }
            }
        } catch { }
    }
}

function Close-TerminalTab([string]$Title) {
    if (-not $Title) { return 0 }
    $closed = 0
    $isClose = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, 'Close Tab')
    foreach ($tab in @(Get-TerminalTabs | Where-Object { $_.Title -eq $Title })) {
        try {
            $btn = $tab.Element.FindFirst([Windows.Automation.TreeScope]::Descendants, $isClose)
            if ($btn) { $btn.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); $closed++ }
        } catch { }
    }
    return $closed
}
