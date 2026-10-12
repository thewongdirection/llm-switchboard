#requires -Version 7.0
<#
  End-to-end check that the model selected in LLM Switchboard really works through Claude Code.

  Run it with the dashboard running (start.cmd). It:
    0. (with -Model) launches that model through the dashboard and waits until it is Ready,
    1. confirms the server is running the model/context the dashboard says it is,
    2. checks the model is alive and responding *directly* - health, a plain prompt, the Anthropic
       endpoint Claude Code uses, and a code-writing prompt whose output must parse and work (D1-D4),
    3. launches Claude Code from the dashboard (a real, visible terminal) with a first task - read the
       README with a tool, write a function - and verifies from Claude Code's own debug log that
       *that window* sent the task to the selected local model, finished the turn and ran the tool (V1-V2),
       Watch it happen live. (Working generated code is verified by D4 and T4/T10, which run it.)
    4. drives Claude Code headless with the *same environment the launcher sets*, through a set of
       interactions: plain replies, reasoning, code generation (then runs the generated code),
       Read / Write / Edit / Bash tool use, multi-turn memory and long-context recall (T1-T10).

  Usage:  pwsh -File tests\verify-claude.ps1 [-Model gemma] [-StopAfter] [-KeepTerminal] [-Quick] [-NoLaunch]
                                              [-Only D3,V1,T4] [-TimeoutSec 600]
    -Model         start the installed model whose name contains this text (otherwise a model must already be Ready)
    -StopAfter     stop the model afterwards, if this script started it
    -KeepTerminal  leave the visible Claude Code terminal open at the end (default: close it)
  Nothing is written to your projects; all test files live in a temp folder that is deleted afterwards.
#>
[CmdletBinding()]
param([switch]$Quick, [switch]$NoLaunch, [switch]$KeepTerminal, [string]$Model, [switch]$StopAfter, [string[]]$Only, [int]$TimeoutSec = 600, [string]$Dashboard = 'http://127.0.0.1:8787')

$ErrorActionPreference = 'Stop'
$h = @{ 'X-Switchboard' = '1'; 'Content-Type' = 'application/json' }
$data = Join-Path $env:LOCALAPPDATA 'llm-switchboard'
$results = [System.Collections.Generic.List[object]]::new()

. (Join-Path $PSScriptRoot 'terminal.ps1')
$tabTitle = 'SB-TEST-' + (Get-Random -Minimum 10000 -Maximum 99999)   # unique, so we only ever close our own tab
$startedByTest = $false; $launchedTerminal = $null; $work = $null

# Runs on every way out (normal end, early exit, error, Ctrl+C): leaves nothing behind.
# Closing a terminal's process does NOT close its tab, so close the tab through Windows Terminal first.
function Remove-TestState {
    if (-not $KeepTerminal) {
        [void](Close-TerminalTab $tabTitle)
        if ($launchedTerminal) { & taskkill /T /F /PID $launchedTerminal.ProcessId 2>&1 | Out-Null }
        # Wait until Windows Terminal has really removed the tab, so nothing is still on screen when we return.
        for ($i = 0; $i -lt 20 -and @(Get-TerminalTabs | Where-Object { $_.Title -like "$tabTitle*" }).Count; $i++) {
            Start-Sleep -Milliseconds 500
            if ($i -eq 6) { [void](Close-TerminalTab $tabTitle) }   # one retry if the first click was missed
        }
    }
    if ($work) { try { [IO.Directory]::Delete($work, $true) } catch { } }
    if ($StopAfter -and $startedByTest) {
        try { $null = Invoke-RestMethod "$Dashboard/api/server/stop" -Method Post -Headers $h -Body '{}'; Write-Host 'Stopped the model this test started.' -ForegroundColor DarkGray } catch { }
        $script:startedByTest = $false
    }
}

function Add-Result($Name, [bool]$Pass, $Detail = '', $Secs = $null) {
    $results.Add([pscustomobject]@{ Test = $Name; Pass = $Pass; Seconds = $Secs; Detail = $Detail })
    $mark = if ($Pass) { 'PASS' } else { 'FAIL' }
    $t = if ($null -ne $Secs) { ' ({0:N0}s)' -f $Secs } else { '' }
    Write-Host ('{0}  {1}{2}  {3}' -f $mark, $Name, $t, $Detail) -ForegroundColor $(if ($Pass) { 'Green' } else { 'Red' })
}

try {
# ---- 0. preconditions --------------------------------------------------------
try { $srv = Invoke-RestMethod "$Dashboard/api/server" -Headers $h -TimeoutSec 5 }
catch { Write-Host "Dashboard not reachable at $Dashboard. Start it with start.cmd first." -ForegroundColor Red; exit 2 }

# ---- 0. launch the model through the dashboard (when -Model is given) ------------
$startedByTest = $false
if ($Model) {
    $found = (Invoke-RestMethod "$Dashboard/api/models" -Headers $h).models | Where-Object { $_.name -like "*$Model*" } | Select-Object -First 1
    if (-not $found) { Write-Host "No installed model matches '$Model'." -ForegroundColor Red; exit 2 }
    if ($srv.running) { Write-Host "The dashboard already runs '$($srv.model)'. Stop it first (or omit -Model)." -ForegroundColor Red; exit 2 }
    Write-Host "Launching '$($found.name)' through the dashboard (auto context)..." -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $null = Invoke-RestMethod "$Dashboard/api/server/start" -Method Post -Headers $h -TimeoutSec 60 -Body (@{ modelPath = $found.path; ctx = 'auto'; kvQuant = 'auto' } | ConvertTo-Json) }
    catch { Add-Result 'dashboard starts the model' $false ($_.ErrorDetails.Message -replace '\s+', ' '); exit 1 }
    do { Start-Sleep -Seconds 2; $srv = Invoke-RestMethod "$Dashboard/api/server" -Headers $h } while ($srv.state -eq 'loading' -and $sw.Elapsed.TotalSeconds -lt 300)
    Add-Result 'dashboard launches the model and it becomes Ready' ($srv.state -eq 'ready') ("state={0} after {1:N0}s ctx={2} kv8bit={3} templatePatched={4}" -f $srv.state, $sw.Elapsed.TotalSeconds, $srv.ctx, $srv.kvQuant, $srv.templatePatched)
    if ($srv.state -ne 'ready') { (Invoke-RestMethod "$Dashboard/api/logs?lines=15" -Headers $h).lines | ForEach-Object { Write-Host "  $_" }; exit 1 }
    $startedByTest = $true
}
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

# ---- 1b. alive and responding - talking to the server directly --------------------
# Before Claude Code is involved: is the model up, does it answer, and can it write working code?
function Invoke-Chat([string]$Prompt, [int]$MaxTokens = 600) {
    $body = @{ model = $srv.alias; messages = @(@{ role = 'user'; content = $Prompt }); max_tokens = $MaxTokens; temperature = 0
        chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 6   # skip long reasoning for these quick probes
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod "$($srv.baseUrl)/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
    return @{ text = [string]$r.choices[0].message.content; secs = $sw.Elapsed.TotalSeconds; tps = [double]$r.timings.predicted_per_second; tokens = [int]$r.usage.completion_tokens; finish = [string]$r.choices[0].finish_reason }
}
function Test-Direct([string]$Id, [string]$Name, [scriptblock]$Body) {
    if ($Only -and ($Id -notin $Only)) { return }
    try { & $Body } catch { Add-Result "$Id  $Name" $false "exception: $($_.Exception.Message)" }
}
if ((-not $Only) -or @($Only | Where-Object { $_ -like 'D*' }).Count) {
    Write-Host "`nChecking the model is alive and responding (directly, before Claude Code is involved)..." -ForegroundColor Cyan

    Test-Direct 'D1' 'health' {
        $r = Invoke-WebRequest "$($srv.baseUrl)/health" -SkipHttpErrorCheck -TimeoutSec 10
        Add-Result 'D1  server health endpoint reports ok' ($r.StatusCode -eq 200) "HTTP $($r.StatusCode) $($r.Content)"
    }
    Test-Direct 'D2' 'direct prompt' {
        $c = Invoke-Chat 'Reply with exactly the single word: ALIVE' 300
        Add-Result 'D2  model answers a direct prompt' ($c.text -match 'ALIVE') ("reply=[{0}] {1} tokens, {2:N1} tok/s" -f ($c.text.Trim() -replace '\s+', ' '), $c.tokens, $c.tps) $c.secs
    }
    Test-Direct 'D3' 'anthropic endpoint' {
        # The endpoint Claude Code actually talks to.
        $body = @{ model = $srv.alias; max_tokens = 1500; messages = @(@{ role = 'user'; content = 'Reply with exactly: ANTHROPIC-OK' }) } | ConvertTo-Json -Depth 5
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $a = Invoke-RestMethod "$($srv.baseUrl)/v1/messages" -Method Post -ContentType 'application/json' -Headers @{ 'x-api-key' = 'x'; 'anthropic-version' = '2023-06-01' } -Body $body -TimeoutSec $TimeoutSec
        $t = (@($a.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join '')
        Add-Result 'D3  Anthropic /v1/messages endpoint (used by Claude Code) responds' ($t -match 'ANTHROPIC-OK') "reply=[$($t.Trim() -replace '\s+',' ')] stop=$($a.stop_reason)" $sw.Elapsed.TotalSeconds
    }
    Test-Direct 'D4' 'writes code' {
        $c = Invoke-Chat 'Write a PowerShell function named Get-Fib that takes an integer parameter $n and returns the nth Fibonacci number, so that Get-Fib 10 returns 55. Reply with ONLY the code in one ```powershell code block.' 1500
        $code = if ($c.text -match '(?s)```(?:powershell|pwsh|ps1)?\s*\r?\n(.*?)```') { $Matches[1] } else { $c.text }
        $errs = $null; $tok = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($code, [ref]$tok, [ref]$errs)
        $fn = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-Fib' }, $true))
        $valid = ($errs.Count -eq 0 -and $fn.Count -ge 1)
        Add-Result 'D4a model writes syntactically valid code when asked' $valid ("defines Get-Fib={0} syntaxErrors={1} {2} chars, {3:N1} tok/s" -f ($fn.Count -ge 1), $errs.Count, $code.Length, $c.tps) $c.secs
        if ($valid) {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ("sb-d4-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
            Set-Content $tmp ($code + "`nGet-Fib 10") -Encoding utf8
            $o = "$tmp.out"
            $p = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $tmp -PassThru -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError "$tmp.err"
            if (-not $p.WaitForExit(30000)) { $p.Kill($true) }
            $out = if (Test-Path $o) { (Get-Content $o -Raw).Trim() } else { '' }
            Add-Result 'D4b  the code it wrote runs and returns the right answer (Get-Fib 10 = 55)' ($out -match '(^|\s)55$') "output=[$($out -replace '\s+',' ')]"
            foreach ($f in $tmp, $o, "$tmp.err") { if (Test-Path $f) { [IO.File]::Delete($f) } }
        }
    }
}

# ---- 2. launch Claude Code from the dashboard, already working on a task --------
# The terminal opens with a first message, so you can watch it think, call a tool and write code.
$launchedTerminal = $null
if (-not $NoLaunch) {
    # Only look at terminals created by *this* launch, so leftovers from earlier sessions can't be mistaken for it.
    $before = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'launch-claude\.ps1' } | ForEach-Object { $_.ProcessId })
    $projects = Invoke-RestMethod "$Dashboard/api/projects" -Headers $h
    $proj = $projects.projects | Where-Object { $_.name -eq 'llm-switchboard' } | Select-Object -First 1   # has a README to read
    $projectDir = if ($proj) { $proj.path } else { $projects.root }
    $watch = (-not $Only) -or @($Only | Where-Object { $_ -like 'V*' }).Count
    $token = 'SB-VISIBLE-' + (Get-Random -Minimum 10000 -Maximum 99999)
    # Test-only: keep the account's connectors (~100k tokens of tool definitions) out of the session so checks run fast.
    $launchBody = @{ mode = 'local'; projectDir = $projectDir; disableConnectors = $true; debugLog = $true; tabTitle = "$tabTitle - $($srv.alias)" }
    if ($watch) {
        $launchBody.initialPrompt = 'This is an automated check of a local model. Do these in order: (1) Use the Read tool to read README.md and tell me, in one sentence, what this project is. (2) Write a PowerShell function named Get-Square that takes a number and returns its square, in a ```powershell code block. Do not create or edit any files and do not run any commands. (3) Finish your reply with exactly this line: ' + $token
    }
    $launchTime = Get-Date
    $r = Invoke-RestMethod "$Dashboard/api/claude/launch" -Method Post -Headers $h -Body ($launchBody | ConvertTo-Json)
    Start-Sleep -Seconds 6
    $term = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'launch-claude\.ps1' -and $_.ProcessId -notin $before })
    $launchedTerminal = $term | Select-Object -First 1
    Add-Result 'dashboard launched a Claude Code terminal' ($r.launched -and $term.Count -eq 1) "new terminals=$($term.Count)"
    if ($launchedTerminal) {
        $kid = Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $launchedTerminal.ProcessId -and $_.Name -eq 'claude.exe' } | Select-Object -First 1
        Add-Result 'terminal is running claude.exe' ([bool]$kid) "pid=$($kid.ProcessId)"
        $tabs = @(Get-TerminalTabs | Where-Object { $_.Title -eq "$tabTitle - $($srv.alias)" })
        Add-Result 'terminal tab is open and labelled with the model' ($tabs.Count -eq 1) "tab='$tabTitle - $($srv.alias)' matching tabs=$($tabs.Count)"
    }

    if ($launchedTerminal -and $watch) {
        Write-Host "`nWatch the new terminal window: Claude Code is working on its first task there right now..." -ForegroundColor Cyan
        # Claude Code's own debug log (enabled for this launch) is the reliable record of what the *visible* session did:
        # which model each request went to, which tools ran, and when the turn finished.
        $dbgLog = $r.debugLog
        $limit = [math]::Min($TimeoutSec, 300)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $reqSeen = $false; $modelOk = $false; $toolOk = $false; $turnEnd = $false; $usage = ''; $raw = ''
        while (-not $turnEnd -and $sw.Elapsed.TotalSeconds -lt $limit) {
            Start-Sleep -Seconds 3
            if (-not $dbgLog -or -not (Test-Path -LiteralPath $dbgLog)) { continue }
            try {
                $fs = [IO.File]::Open($dbgLog, 'Open', 'Read', 'ReadWrite')
                try { $raw = [IO.StreamReader]::new($fs).ReadToEnd() } finally { $fs.Dispose() }
            } catch { continue }
            $reqSeen = $raw -match '\[API REQUEST\] /v1/messages source=repl_main_thread'
            $modelOk = $raw -match [regex]::Escape("dispatching to firstParty model=$($srv.alias)")
            $toolOk = ($raw -match 'tool_dispatch_start tool=Read') -and ($raw -match 'tool_dispatch_end tool=Read[^\r\n]*outcome=ok')
            if ($raw -match 'turn \d+ end \(([^)]*)stop=end_turn') { $turnEnd = $true; $usage = ($Matches[1] -replace '\s+', ' ').Trim() }
        }
        $tail = if (-not $turnEnd) { ' | last log lines: ' + ((($raw -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 3) -join ' / ') -replace '\s+', ' ') } else { '' }
        Add-Result 'V1  visible terminal: sent its task to the selected local model and finished the turn' ($reqSeen -and $modelOk -and $turnEnd) "model=$modelOk request=$reqSeen finished=$turnEnd $usage$tail" $sw.Elapsed.TotalSeconds
        Add-Result 'V2  visible terminal: ran the Read tool live and used its result' $toolOk "debug log=$(Split-Path $dbgLog -Leaf)"
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
Add-Result 'launcher keeps account connectors out of the local session' ($envSet['ENABLE_CLAUDEAI_MCP_SERVERS'] -eq 'false') "ENABLE_CLAUDEAI_MCP_SERVERS=$($envSet['ENABLE_CLAUDEAI_MCP_SERVERS'])"
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
    $diag = if ($r.json) { "turns=$($r.json.num_turns) permissionDenials=$(@($r.json.permission_denials).Count)" } else { '' }
    Add-Result 'T6  uses the Edit tool correctly' ($r.ok -and $c -eq 'Hello Switchboard') "file=[$c] reply=[$($r.text.Trim() -replace '\s+',' ')] $diag $($r.error)" $r.secs
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

} finally {
    Remove-TestState
}

# ---- 4. summary --------------------------------------------------------------
$fail = @($results | Where-Object { -not $_.Pass })
Write-Host ("`n{0} passed, {1} failed" -f ($results.Count - $fail.Count), $fail.Count) -ForegroundColor $(if ($fail.Count) { 'Red' } else { 'Green' })
exit $fail.Count