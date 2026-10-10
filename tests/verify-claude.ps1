#requires -Version 7.0
<#
  End-to-end check that the model selected in LLM Switchboard really works through Claude Code.

  Run it with the dashboard running (start.cmd) and a model started and Ready. It:
    1. confirms the server is running the model/context the dashboard says it is,
    2. launches Claude Code from the dashboard (a real terminal) and checks that terminal,
    3. drives Claude Code headless with the *same environment the launcher sets*, through a set of
       interactions: plain replies, reasoning, code generation (then runs the generated code),
       Read / Write / Edit / Bash tool use, multi-turn memory and long-context recall.

  Usage:  pwsh -File tests\verify-claude.ps1 [-Quick] [-NoLaunch] [-Only T4,T10] [-TimeoutSec 600]
  Nothing is written to your projects; all test files live in a temp folder that is deleted afterwards.
  It never stops or starts models - use the dashboard for that.
#>
[CmdletBinding()]
param([switch]$Quick, [switch]$NoLaunch, [string[]]$Only, [int]$TimeoutSec = 600, [string]$Dashboard = 'http://127.0.0.1:8787')

$ErrorActionPreference = 'Stop'
$h = @{ 'X-Switchboard' = '1'; 'Content-Type' = 'application/json' }
$data = Join-Path $env:LOCALAPPDATA 'llm-switchboard'
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result($Name, [bool]$Pass, $Detail = '', $Secs = $null) {
    $results.Add([pscustomobject]@{ Test = $Name; Pass = $Pass; Seconds = $Secs; Detail = $Detail })
    $mark = if ($Pass) { 'PASS' } else { 'FAIL' }
    $t = if ($null -ne $Secs) { ' ({0:N0}s)' -f $Secs } else { '' }
    Write-Host ('{0}  {1}{2}  {3}' -f $mark, $Name, $t, $Detail) -ForegroundColor $(if ($Pass) { 'Green' } else { 'Red' })
}

# ---- 0. preconditions --------------------------------------------------------
try { $srv = Invoke-RestMethod "$Dashboard/api/server" -Headers $h -TimeoutSec 5 }
catch { Write-Host "Dashboard not reachable at $Dashboard. Start it with start.cmd first." -ForegroundColor Red; exit 2 }
if ($srv.state -ne 'ready') {
    Write-Host "No dashboard-started model is Ready (state: $($srv.state)). Start one in the dashboard first." -ForegroundColor Red
    if (@($srv.processes | Where-Object { -not $_.ours }).Count) { Write-Host 'Note: a llama-server NOT started by the dashboard is running; the dashboard will not manage it.' -ForegroundColor Yellow }
    exit 2
}
$claudeExe = (Invoke-RestMethod "$Dashboard/api/state" -Headers $h).claude.path
if (-not $claudeExe) { Write-Host 'Claude Code CLI not found.' -ForegroundColor Red; exit 2 }
Write-Host "`nModel under test: $($srv.alias)   ctx=$($srv.ctx)   server=$($srv.baseUrl)   claude=$claudeExe`n"

# ---- 1. server-side identity -------------------------------------------------
$props = Invoke-RestMethod "$($srv.baseUrl)/props" -TimeoutSec 10
$loaded = Split-Path ([string]$props.model_path) -Leaf
$expected = Split-Path ([string]$srv.modelPath) -Leaf
Add-Result 'server runs the selected model file' ($loaded -eq $expected) "loaded=$loaded expected=$expected"
$nctx = [int]$props.default_generation_settings.n_ctx
Add-Result 'server context matches the dashboard setting' ($nctx -eq [int]$srv.ctx) "n_ctx=$nctx dashboard=$($srv.ctx)"
$models = Invoke-RestMethod "$($srv.baseUrl)/v1/models" -TimeoutSec 10
Add-Result 'server advertises the expected model name' (@($models.data.id) -contains $srv.alias) "ids=$(@($models.data.id) -join ',')"

# ---- 2. launch Claude Code from the dashboard --------------------------------
$launchedTerminal = $null
if (-not $NoLaunch) {
    # Only look at terminals created by *this* launch, so leftovers from earlier sessions can't be mistaken for it.
    $before = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'launch-claude\.ps1' } | ForEach-Object { $_.ProcessId })
    $projectDir = (Invoke-RestMethod "$Dashboard/api/projects" -Headers $h).root
    $r = Invoke-RestMethod "$Dashboard/api/claude/launch" -Method Post -Headers $h -Body (@{ mode = 'local'; projectDir = $projectDir } | ConvertTo-Json)
    Start-Sleep -Seconds 6
    $term = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'launch-claude\.ps1' -and $_.ProcessId -notin $before })
    $launchedTerminal = $term | Select-Object -First 1
    Add-Result 'dashboard launched a Claude Code terminal' ($r.launched -and $term.Count -eq 1) "new terminals=$($term.Count)"
    if ($launchedTerminal) {
        $kid = Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $launchedTerminal.ProcessId -and $_.Name -eq 'claude.exe' } | Select-Object -First 1
        Add-Result 'terminal is running claude.exe' ([bool]$kid) "pid=$($kid.ProcessId)"
        $titles = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue | ForEach-Object { $_.MainWindowTitle })
        Add-Result 'terminal window is labelled with the model' (@($titles | Where-Object { $_ -like "*$($srv.alias)*" }).Count -ge 1) "titles=$($titles -join ' | ')"
    }
}

# ---- 3. headless Claude Code with the launcher's own environment ------------
# Read the environment straight from the launcher the dashboard generated, so we test what the terminal really got.
$launcher = Get-Content (Join-Path $data 'launch-claude.ps1')
$envSet = @{}; $envClear = @()
foreach ($line in $launcher) {
    if ($line -match "^\`$env:(\w+) = '(.*)'$") { $envSet[$Matches[1]] = $Matches[2] }
    elseif ($line -match '^Remove-Item Env:(\w+)') { $envClear += $Matches[1] }
}
Add-Result 'launcher points Claude Code at the local server' ($envSet['ANTHROPIC_BASE_URL'] -eq $srv.baseUrl) "base=$($envSet['ANTHROPIC_BASE_URL'])"
Add-Result 'launcher maps every model tier to the loaded model' (@('ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL' | Where-Object { $envSet[$_] -ne $srv.alias }).Count -eq 0)
Add-Result 'launcher tells Claude Code the real context window' ([int]$envSet['CLAUDE_CODE_MAX_CONTEXT_TOKENS'] -eq [int]$srv.ctx) "CLAUDE_CODE_MAX_CONTEXT_TOKENS=$($envSet['CLAUDE_CODE_MAX_CONTEXT_TOKENS'])"

$work = Join-Path ([IO.Path]::GetTempPath()) ("sb-verify-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Force $work)
$script:session = $null

function Invoke-Claude([string]$Prompt, [string]$Tools = '', [int]$MaxTurns = 6, [switch]$Continue) {
    $psi = [Diagnostics.ProcessStartInfo]::new($claudeExe)
    $psi.WorkingDirectory = $work; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    foreach ($k in $envClear) { [void]$psi.Environment.Remove($k) }
    foreach ($k in $envSet.Keys) { $psi.Environment[$k] = $envSet[$k] }
    foreach ($a in @('-p', $Prompt, '--output-format', 'json', '--max-turns', "$MaxTurns", '--permission-mode', 'acceptEdits')) { [void]$psi.ArgumentList.Add($a) }
    if ($Tools) { [void]$psi.ArgumentList.Add('--allowedTools'); [void]$psi.ArgumentList.Add($Tools) }
    if ($Continue) { [void]$psi.ArgumentList.Add('--continue') }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill($true); return @{ ok = $false; secs = $sw.Elapsed.TotalSeconds; error = "timed out after ${TimeoutSec}s"; text = ''; raw = '' } }
    $out = $outTask.Result; $err = $errTask.Result
    $json = ($out -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
    try { $o = $json | ConvertFrom-Json } catch { return @{ ok = $false; secs = $sw.Elapsed.TotalSeconds; error = "unparseable output: $(($out + $err).Trim() -replace '\s+',' ')"; text = ''; raw = $out } }
    return @{ ok = (-not $o.is_error); secs = $sw.Elapsed.TotalSeconds; error = $(if ($o.is_error) { [string]$o.result } else { '' }); text = [string]$o.result; json = $o; raw = $out }
}

# Run a generated PowerShell program the way a user would: from its own folder.
function Invoke-GeneratedScript([string]$File) {
    Push-Location $work
    try { return (& pwsh -NoProfile -File $File 2>&1 | Out-String).Trim() } finally { Pop-Location }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    if ($Only -and ($Name.Split(' ')[0] -notin $Only)) { return }
    try { & $Body } catch { Add-Result $Name $false "exception: $($_.Exception.Message)" }
}

Write-Host "`nDriving Claude Code headless (each step is a real round trip to the local model)..." -ForegroundColor Cyan

Test-Case 'T1  responds to a simple prompt' {
    $r = Invoke-Claude 'Reply with exactly the single word: PONG'
    Add-Result 'T1  responds to a simple prompt' ($r.ok -and $r.text -match 'PONG') "reply=[$($r.text.Trim() -replace '\s+',' ')] $($r.error)" $r.secs
    if ($r.ok -and $r.json) {
        $used = @($r.json.modelUsage.PSObject.Properties.Name)
        Add-Result 'T2  requests were served by the selected model' ($used -contains $srv.alias) "modelUsage=$($used -join ',')"
        $u = $r.json.usage; if ($u) { Write-Host "      tokens: in=$($u.input_tokens) out=$($u.output_tokens) cache_read=$($u.cache_read_input_tokens)" -ForegroundColor DarkGray }
    }
}

Test-Case 'T3  basic reasoning' {
    $r = Invoke-Claude 'What is 17 multiplied by 23? Answer with only the number.'
    Add-Result 'T3  basic reasoning (17 x 23 = 391)' ($r.ok -and $r.text -match '\b391\b') "reply=[$($r.text.Trim() -replace '\s+',' ')] $($r.error)" $r.secs
}

Test-Case 'T4  code generation' {
    $r = Invoke-Claude 'Create a file named fib.ps1 in the current directory: a PowerShell script that prints the first 10 Fibonacci numbers (starting 0 1 1 2 ...) on ONE line separated by single spaces. Write only the file.' 'Write,Read' 8
    $f = Join-Path $work 'fib.ps1'
    $exists = Test-Path $f
    $out = if ($exists) { (Invoke-GeneratedScript $f) -replace '\s+', ' ' } else { '' }
    Add-Result 'T4  generates code that runs correctly (Fibonacci)' ($r.ok -and $exists -and $out -eq '0 1 1 2 3 5 8 13 21 34') "file=$exists output=[$out] $($r.error)" $r.secs
}

Test-Case 'T5  Read tool' {
    Set-Content (Join-Path $work 'notes.md') "# Zebra Project`n`nThe launch code is ORCHID-7731.`n" -Encoding utf8
    $r = Invoke-Claude 'Use the Read tool to read notes.md and reply with ONLY the launch code it contains.' 'Read'
    Add-Result 'T5  uses the Read tool correctly' ($r.ok -and $r.text -match 'ORCHID-7731') "reply=[$($r.text.Trim() -replace '\s+',' ')] $($r.error)" $r.secs
}

Test-Case 'T6  Edit tool' {
    Set-Content (Join-Path $work 'greet.txt') 'Hello World' -Encoding utf8 -NoNewline
    $r = Invoke-Claude 'Edit greet.txt so that the word World becomes Switchboard. Make no other changes.' 'Read,Edit' 8
    $c = (Get-Content (Join-Path $work 'greet.txt') -Raw).Trim()
    Add-Result 'T6  uses the Edit tool correctly' ($r.ok -and $c -eq 'Hello Switchboard') "file=[$c] $($r.error)" $r.secs
}

Test-Case 'T7  Bash tool' {
    $r = Invoke-Claude 'Run the shell command: echo SB-BASH-7Q2 and tell me exactly what it printed.' 'Bash(echo:*)'
    Add-Result 'T7  uses the Bash tool correctly' ($r.ok -and $r.text -match 'SB-BASH-7Q2') "reply=[$($r.text.Trim() -replace '\s+',' ')] $($r.error)" $r.secs
}

if (-not $Quick) {
    Test-Case 'T8  multi-turn memory' {
        $a = Invoke-Claude 'Remember this number for later: 7421. Just reply OK.'
        $b = Invoke-Claude 'What number did I ask you to remember? Answer with only the number.' '' 6 -Continue
        Add-Result 'T8  remembers earlier turns (--continue)' ($a.ok -and $b.ok -and $b.text -match '\b7421\b') "reply=[$($b.text.Trim() -replace '\s+',' ')] $($b.error)" ($a.secs + $b.secs)
    }

    Test-Case 'T9  long-context recall' {
        $sb = [Text.StringBuilder]::new()
        $rng = [Random]::new(42)
        1..450 | ForEach-Object { [void]$sb.AppendLine(("Record {0}: sensor={1} reading={2} status=nominal" -f $_, $rng.Next(100, 999), $rng.Next(10000, 99999))) }
        $text = $sb.ToString().Replace('Record 337: sensor=', 'Record 337 (ACCESS CODE: GLACIER-5190): sensor=')
        Set-Content (Join-Path $work 'records.txt') $text -Encoding utf8
        $r = Invoke-Claude 'Use the Read tool to read records.txt (it may be long). One record mentions an ACCESS CODE. Reply with ONLY that code.' 'Read' 8
        Add-Result 'T9  finds a fact buried in a large file' ($r.ok -and $r.text -match 'GLACIER-5190') "reply=[$($r.text.Trim() -replace '\s+',' ')] $($r.error)" $r.secs
    }

    Test-Case 'T10 multi-step coding task' {
        $r = Invoke-Claude 'In the current directory create two files. 1) mathlib.ps1 defining a function Get-Square($n) that returns $n*$n. 2) main.ps1 that dot-sources mathlib.ps1 and prints Get-Square 12. Do not run anything.' 'Write,Read,Edit' 10
        $m = Join-Path $work 'main.ps1'
        $out = if ((Test-Path $m) -and (Test-Path (Join-Path $work 'mathlib.ps1'))) { Invoke-GeneratedScript $m } else { '' }
        Add-Result 'T10 builds a two-file program that runs (12^2 = 144)' ($r.ok -and $out -eq '144') "output=[$out] $($r.error)" $r.secs
    }
}

# ---- 4. cleanup + summary ----------------------------------------------------
if ($launchedTerminal) { & taskkill /T /F /PID $launchedTerminal.ProcessId 2>&1 | Out-Null }
try { [IO.Directory]::Delete($work, $true) } catch { }

$fail = @($results | Where-Object { -not $_.Pass })
Write-Host ("`n{0} passed, {1} failed" -f ($results.Count - $fail.Count), $fail.Count) -ForegroundColor $(if ($fail.Count) { 'Red' } else { 'Green' })
exit $fail.Count
