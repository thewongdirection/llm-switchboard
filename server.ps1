#requires -Version 7.0
<#
  LLM Switchboard - local dashboard for llama.cpp + Claude Code.
  Binds to 127.0.0.1 only. Run via start.cmd (or: pwsh -File server.ps1).
#>
[CmdletBinding()]
param([switch]$NoBrowser)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = $PSScriptRoot
. (Join-Path $Root 'lib.ps1')
. (Join-Path $Root 'gguf.ps1')

$UiDir = Join-Path $Root 'ui'
# Runtime data lives outside the (Synology-synced) project folder.
$Data = Join-Path $env:LOCALAPPDATA 'llm-switchboard'
New-Item -ItemType Directory -Force $Data | Out-Null
$SettingsFile = Join-Path $Data 'settings.json'
$ServerFile = Join-Path $Data 'server.json'
$DiscCacheFile = Join-Path $Data 'discover-cache.json'
$DiscStatusFile = Join-Path $Data 'discover-status.json'
$LogOut = Join-Path $Data 'llama-server.out.log'
$LogErr = Join-Path $Data 'llama-server.err.log'

# ---- Settings ---------------------------------------------------------------

$script:S = @{
    port             = 8787
    llamaServerPath  = ((Get-Command llama-server -ErrorAction SilentlyContinue)?.Source ?? '')
    claudePath       = ''
    modelDirs        = @((Join-Path $HOME '.cache\huggingface\hub'), (Join-Path $HOME 'models'))
    downloadDir      = (Join-Path $HOME 'models')
    projectsDir      = $(if (Test-Path 'D:\SynologyDrive\Archon\Projects') { 'D:\SynologyDrive\Archon\Projects' } else { $HOME })
    llamaPort        = 8080
    hardwareOverride = $null
    seen             = @()
    seenBaselined    = $false
}
$loaded = Read-Json $SettingsFile $null
if ($loaded) { foreach ($k in $loaded.Keys) { if ($script:S.ContainsKey($k)) { $script:S[$k] = $loaded[$k] } } }
function Save-Settings { Write-Json $SettingsFile $script:S }
Save-Settings

# ---- Hardware ---------------------------------------------------------------

# Detection shells out to nvidia-smi and WMI (~0.5s), and the server is single-threaded, so cache it briefly.
$script:HwCache = $null; $script:HwCacheAt = [datetime]::MinValue
function Get-DetectedHardware {
    if ($script:HwCache -and ((Get-Date) - $script:HwCacheAt).TotalSeconds -lt 5) { return $script:HwCache }
    $script:HwCache = Get-DetectedHardwareRaw
    $script:HwCacheAt = Get-Date
    return $script:HwCache
}

function Get-DetectedHardwareRaw {
    $gpus = @()
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smi) {
        try {
            $out = & $smi.Source '--query-gpu=name,memory.total,memory.free,driver_version' '--format=csv,noheader,nounits' 2>$null
            foreach ($l in $out) {
                $p = $l -split ',\s*'
                if ($p.Count -ge 4) {
                    $gpus += @{ vendor = 'NVIDIA'; name = $p[0]; vramGB = [math]::Round([double]$p[1] / 1024, 1); freeGB = [math]::Round([double]$p[2] / 1024, 1); driver = $p[3]; vramKnown = $true }
                }
            }
        } catch { }
    }
    try {
        foreach ($v in (Get-CimInstance Win32_VideoController)) {
            if ($v.Name -match 'NVIDIA' -and $gpus.Count -gt 0) { continue }
            if ($v.Name -match 'Microsoft Basic|Remote Display|Virtual') { continue }
            $vendor = if ($v.Name -match 'AMD|Radeon') { 'AMD' } elseif ($v.Name -match 'Intel') { 'Intel' } elseif ($v.Name -match 'NVIDIA') { 'NVIDIA' } else { 'Other' }
            # Win32_VideoController.AdapterRAM is a 32-bit field, so it is not trusted as a VRAM figure.
            $gpus += @{ vendor = $vendor; name = $v.Name; vramGB = $null; freeGB = $null; vramKnown = $false; integrated = [bool]($v.Name -match 'Radeon\(TM\) Graphics$|Intel.*(UHD|Iris|Graphics)') }
        }
    } catch { }

    $ramGB = $null; $freeRamGB = $null
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $freeRamGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    } catch { }
    $cpu = $null
    try { $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 } catch { }

    return @{
        gpus      = $gpus
        ramGB     = $ramGB
        freeRamGB = $freeRamGB
        cpuName   = ($cpu ? $cpu.Name.Trim() : $null)
        cores     = ($cpu ? [int]$cpu.NumberOfCores : $null)
        threads   = ($cpu ? [int]$cpu.NumberOfLogicalProcessors : $null)
    }
}

function Get-HardwareView {
    $d = Get-DetectedHardware
    $known = @($d.gpus | Where-Object { $_.vramKnown })
    $detectedVram = if ($known.Count) { [math]::Round(($known | Measure-Object vramGB -Sum).Sum, 1) } else { $null }
    $needsInput = (-not $known.Count) -or ($null -eq $d.ramGB)
    $ov = $script:S.hardwareOverride
    if ($ov) {
        $eff = @{
            gpuName = [string]$ov.gpuName
            vramGB  = [double]$ov.vramGB
            ramGB   = [double]$ov.ramGB
            source  = 'manual'
        }
        $needsInput = $false
    } else {
        $eff = @{
            gpuName = ($known.Count ? (($known | ForEach-Object { $_.name }) -join ' + ') : 'No GPU detected')
            vramGB  = [double]($detectedVram ?? 0)
            ramGB   = [double]($d.ramGB ?? 0)
            source  = 'detected'
        }
    }
    $eff.cpuName = $d.cpuName; $eff.cores = $d.cores; $eff.threads = $d.threads
    $eff.freeVramGB = if ($known.Count) { [math]::Round(($known | Measure-Object freeGB -Sum).Sum, 1) } else { $null }
    $eff.freeRamGB = $d.freeRamGB
    # VRAM a model can really use = total minus what other programs (desktop, browser...) hold. That is measured
    # whenever no llama-server is running, so our own models don't count against themselves.
    if ($ov) {
        $eff.gpuAvailGB = [math]::Max(0.0, $eff.vramGB - 1.0 - 0.3)
    } elseif ($known.Count) {
        if (-not (Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)) {
            $script:OtherVramGB = [math]::Max(0.0, $detectedVram - [double]$eff.freeVramGB)
        }
        $eff.gpuAvailGB = [math]::Round([math]::Max(0.0, $detectedVram - [double]($script:OtherVramGB ?? 1.0) - 0.3), 1)
    } else { $eff.gpuAvailGB = 0.0 }
    return @{ detected = $d; effective = $eff; needsInput = $needsInput; override = $ov }
}

# ---- Installed models -------------------------------------------------------

function Get-RepoFromPath([string]$Path) {
    if ($Path -match 'models--([^\\]+)--([^\\]+)\\snapshots') { return "$($Matches[1])/$($Matches[2])" }
    if ($Path -match '\\([^\\]+)--([^\\]+)\\[^\\]+\.gguf$') { return "$($Matches[1])/$($Matches[2])" }
    return $null
}

function Get-InstalledModels($Hw) {
    $seenPaths = @{}
    $files = foreach ($dir in @($script:S.modelDirs)) {
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            Get-ChildItem -LiteralPath $dir -Recurse -Depth 7 -Filter *.gguf -File -ErrorAction SilentlyContinue
        }
    }
    $mmprojByDir = @{}
    $models = @{}
    foreach ($f in $files) {
        if ($seenPaths.ContainsKey($f.FullName)) { continue }
        $seenPaths[$f.FullName] = $true
        if ($f.Name -match '(?i)mmproj') { $mmprojByDir[$f.DirectoryName] = $f; continue }
        if ($f.Name -match '(?i)imatrix') { continue }
        $stem = $f.Name -replace '(?i)-\d{5}-of-\d{5}\.gguf$', '' -replace '(?i)\.gguf$', ''
        $key = "$($f.DirectoryName)|$stem"
        if (-not $models.ContainsKey($key)) {
            $models[$key] = @{ stem = $stem; dir = $f.DirectoryName; main = $null; size = [int64]0; modified = $f.LastWriteTime; files = 0 }
        }
        $m = $models[$key]
        $m.size += $f.Length
        $m.files++
        if ($f.Name -notmatch '(?i)-\d{5}-of-\d{5}\.gguf$' -or $f.Name -match '(?i)-0*1-of-\d+\.gguf$') { $m.main = $f.FullName }
    }
    # A projector is only attached when it is unambiguous: one model in that folder. In a flat folder with
    # several models it could belong to any of them, and a mismatched projector makes llama-server fail.
    $perDir = @{}
    foreach ($m in $models.Values) { if ($m.main) { $perDir[$m.dir] = 1 + [int]$perDir[$m.dir] } }
    $tuneDb = Read-Json $TuneDbFile @{}; $tuneSig = Get-HwSig
    $list = foreach ($m in $models.Values) {
        if (-not $m.main) { continue }
        $q = Get-QuantInfo $m.stem
        $paramsB = Get-ParamsB $m.stem
        $sizeGB = [math]::Round($m.size / 1GB, 2)
        $plan = Get-CtxPlan $m.main ($m.size / 1GB) $Hw (Test-IsMoe $m.stem)   # reads real expert/layer counts from the file
        $isMoe = $plan.isMoe
        $fit = Get-Fit $sizeGB $isMoe $Hw
        $mm = if ($perDir[$m.dir] -eq 1) { $mmprojByDir[$m.dir] } else { $null }
        @{
            path     = $m.main
            name     = $m.stem
            repo     = (Get-RepoFromPath $m.main)
            quant    = $q.label
            sizeGB   = $sizeGB
            sizeBytes = [int64]$m.size
            isMoe    = $isMoe
            paramsB  = $paramsB
            fit      = $fit
            ctxPlan  = $plan
            templatePatch = [bool](Get-PatchedTemplate $m.main)
            tunings  = @(Get-ModelTunings $m.stem $tuneDb $tuneSig)
            mmproj   = ($mm ? $mm.FullName : $null)
            modified = $m.modified.ToString('o')
            score    = (Get-ModelScore ($paramsB ?? [math]::Max($sizeGB * 1.6, 1)) $isMoe $fit)
        }
    }
    $list = @($list | Sort-Object { $_.score } -Descending)
    $best = $list | Where-Object { $_.fit.tier -in 'gpu', 'moe' } | Select-Object -First 1
    foreach ($m in $list) { $m.recommended = ($best -and $m.path -eq $best.path) }
    return $list
}

# ---- llama-server lifecycle -------------------------------------------------

$script:LlamaVersion = $null; $script:LlamaVersionTried = $false
function Get-LlamaVersion {
    if ($script:LlamaVersionTried) { return $script:LlamaVersion }
    $script:LlamaVersionTried = $true   # don't re-run the exe on every poll if it fails
    $exe = $script:S.llamaServerPath
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        try { $script:LlamaVersion = ((& $exe --version 2>&1 | Out-String) -split "`n" | Where-Object { $_ -match 'version' } | Select-Object -First 1).Trim() } catch { }
    }
    return $script:LlamaVersion
}

function Get-LogTail([string]$Path, [int]$Lines = 80) {
    if (-not (Test-Path $Path)) { return @() }
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $len = [math]::Min($fs.Length, 65536)
            [void]$fs.Seek(-$len, 'End')
            $txt = [IO.StreamReader]::new($fs).ReadToEnd()
        } finally { $fs.Dispose() }
        return @(($txt -split "`r?`n") | Where-Object { $_ } | Select-Object -Last $Lines)
    } catch { return @() }
}

function Get-ServerStatus {
    $st = Read-Json $ServerFile $null
    if (-not $st) { return @{ running = $false; state = 'stopped' } }
    $p = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
    $alive = $p -and $p.ProcessName -like 'llama-server*' -and $p.StartTime.ToFileTimeUtc() -eq [int64]$st.startTicks
    if (-not $alive) {
        $tail = @(Get-LogTail $LogErr 12)
        return @{ running = $false; state = 'exited'; model = $st.model; tuned = [bool]$st.tuned; error = ($tail -join "`n") }
    }
    $state = 'loading'
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$($st.port)/health" -TimeoutSec 2 -SkipHttpErrorCheck
        if ($r.StatusCode -eq 200) { $state = 'ready'; $script:ReadyPid = [int]$st.pid }
    } catch {
        # A busy server can miss a health check; once a model has been Ready, don't flap back to Loading.
        if ($script:ReadyPid -eq [int]$st.pid) { $state = 'ready' }
    }
    return @{
        running = $true; state = $state; pid = $st.pid; port = $st.port; model = $st.model; modelPath = $st.modelPath
        alias = $st.alias; ctx = $st.ctx; kvQuant = [bool]$st.kvQuant; templatePatched = [bool]$st.templatePatched; tuned = [bool]$st.tuned; startedAt = $st.startedAt; baseUrl = "http://127.0.0.1:$($st.port)"
    }
}

function Stop-LlamaServer {
    $st = Read-Json $ServerFile $null
    if ($st) {
        $p = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -like 'llama-server*') { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $p.WaitForExit(8000) | Out-Null }
        Remove-Item $ServerFile -ErrorAction SilentlyContinue
    }
}

# Every llama-server process on the machine, including ones this dashboard did not start.
function Get-LlamaProcesses([int]$OwnPid = 0) {
    $procs = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
    if (-not $procs.Count) { return @() }
    $cmd = @{}
    try { foreach ($c in (Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'")) { $cmd[[int]$c.ProcessId] = $c.CommandLine } } catch { }
    return @($procs | ForEach-Object {
            $line = [string]$cmd[$_.Id]
            $port = if ($line -match '--port\s+(\d+)') { [int]$Matches[1] } else { 8080 }
            @{ pid = $_.Id; port = $port; startedAt = $_.StartTime.ToString('o'); ours = ($_.Id -eq $OwnPid) }
        })
}

function Stop-AllLlamaServers {
    $killed = 0; $failed = @()
    foreach ($p in @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; [void]$p.WaitForExit(8000); $killed++ }
        catch { $failed += "PID $($p.Id): $($_.Exception.Message)" }
    }
    Remove-Item $ServerFile -ErrorAction SilentlyContinue
    return @{ killed = $killed; failed = $failed; remaining = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue).Count }
}

function Quote-Arg([string]$a) { if ($a -match '\s') { return '"' + $a + '"' } return $a }

# Context: 'auto' (default) = the largest window this machine can hold for this model, capped at its trained length.
# KV cache: 'auto' = compress to 8-bit only when full precision would not stay on the GPU.
function Resolve-LaunchPlan($Model, $Req) {
    $plan = $Model.ctxPlan
    if ($null -eq $Req.ctx -or "$($Req.ctx)" -eq 'auto') { $opt = $plan.recommended }
    else {
        $want = [int]$Req.ctx
        if ($want -lt 2048 -or $want -gt 1048576) { throw 'Context size out of range.' }
        $opt = $plan.options | Where-Object { $_.ctx -eq $want } | Select-Object -First 1
        if (-not $opt) { $opt = @{ ctx = $want; kvQuant = $false } }
    }
    $kvq = if ($null -eq $Req.kvQuant -or "$($Req.kvQuant)" -eq 'auto') { [bool]$opt.kvQuant } else { [bool]$Req.kvQuant }
    return @{ ctx = [int]$opt.ctx; kvq = $kvq }
}

# ---- Autotune (see tune.ps1) ------------------------------------------------

$TuneStatusFile = Join-Path $Data 'tune-status.json'
$TuneDbFile = Join-Path $Data 'tuning.json'

# Tuning only applies to the machine and llama.cpp build it was measured on.
function Get-HwSig {
    $e = (Get-HardwareView).effective
    return ('{0}|{1}|{2}|{3}' -f $e.gpuName, [math]::Round($e.vramGB), [math]::Round($e.ramGB), (Get-LlamaVersion))
}

function Get-TuningRecord([string]$ModelName, [int]$Ctx, [bool]$Kvq) {
    $db = Read-Json $TuneDbFile @{}
    $key = '{0}|{1}|{2}|{3}' -f $ModelName, $Ctx, [int]$Kvq, (Get-HwSig)
    if ($db.ContainsKey($key)) { return $db[$key] }
    return $null
}

# Slim summaries of this model's tunings for the current hardware (the list endpoint must stay small).
function Get-ModelTunings([string]$ModelName, $Db, [string]$Sig) {
    $suffix = '|' + $Sig
    @($Db.Keys | Where-Object { $_.StartsWith($ModelName + '|') -and $_.EndsWith($suffix) } | ForEach-Object {
            $r = $Db[$_]
            @{ ctx = $r.ctx; kvQuant = $r.kvQuant; savedAt = $r.savedAt; baseline = $r.baseline; tuned = $r.tuned; gainGenPct = $r.gainGenPct
                gainPromptPct = $r.gainPromptPct; marginMiB = $r.marginMiB; applied = $r.applied; note = $r.note; cliArgs = @($r.cliArgs) }
        })
}

function Get-TuneStatus {
    $st = Read-Json $TuneStatusFile @{ state = 'idle' }
    if ($st.state -eq 'running') {
        $p = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
        if (-not $p -or $p.ProcessName -notlike 'pwsh*') { $st.state = 'error'; $st.message = 'The autotune stopped unexpectedly.' }
    }
    return $st
}

function Start-AutoTune($Req) {
    if ((Get-TuneStatus).state -eq 'running') { throw 'An autotune is already running.' }
    if ((Get-ServerStatus).running -or @(Get-LlamaProcesses).Count) { throw 'Stop every running model server first - the autotune needs the GPU to itself.' }
    $exe = $script:S.llamaServerPath
    if (-not $exe -or -not (Test-Path $exe)) { throw 'llama-server.exe not found. Set its path in Settings.' }
    $model = Get-InstalledModels (Get-HardwareView).effective | Where-Object { $_.path -eq $Req.modelPath } | Select-Object -First 1
    if (-not $model) { throw 'That model is not in a configured model folder.' }
    $lp = Resolve-LaunchPlan $model $Req
    $tpl = Get-TemplatePatchFile $model.path (Join-Path $Data 'templates')
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Arg (Join-Path $Root 'tune.ps1')),
        '-ModelPath', (Quote-Arg $model.path), '-ModelName', (Quote-Arg $model.name), '-Ctx', "$($lp.ctx)", '-LlamaServer', (Quote-Arg $exe),
        '-Port', "$([int]$script:S.llamaPort + 100)", '-HwSig', (Quote-Arg (Get-HwSig)), '-Layers', "$([int]$model.ctxPlan.layers)")
    if ($lp.kvq) { $a += '-KvQuant' }
    if ($model.ctxPlan.isMoe) { $a += '-IsMoe' }
    if ($tpl) { $a += @('-TemplateFile', (Quote-Arg $tpl)) }
    if ($Req.quick) { $a += '-Quick' }
    $margin = Get-MarginMiB $Req.marginMiB
    $a += @('-MarginMiB', "$margin")
    $p = Start-Process (Get-Process -Id $PID).Path -ArgumentList $a -WindowStyle Hidden -PassThru
    Write-Json $TuneStatusFile @{ state = 'running'; phase = 'starting'; message = 'Starting...'; pid = $p.Id; model = $model.name; ctx = $lp.ctx
        kvQuant = $lp.kvq; marginMiB = $margin; step = 0; steps = 12; trials = @(); startedAt = (Get-Date).ToString('o') }
    return @{ started = $true; ctx = $lp.ctx; kvQuant = $lp.kvq }
}

function Stop-AutoTune {
    $st = Get-TuneStatus
    if ($st.state -eq 'running' -and $st.pid) {
        $p = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -like 'pwsh*') { & taskkill /T /F /PID $p.Id 2>&1 | Out-Null }   # the whole tree, including the trial llama-server
        Write-Json $TuneStatusFile @{ state = 'cancelled'; phase = 'cancelled'; message = 'Cancelled.'; model = $st.model; ctx = $st.ctx; trials = @($st.trials) }
    }
}

function Reset-Tuning([string]$ModelName) {
    $db = Read-Json $TuneDbFile @{}
    foreach ($k in @($db.Keys | Where-Object { $_.StartsWith($ModelName + '|') })) { $db.Remove($k) }
    Write-Json $TuneDbFile $db
}

function Start-LlamaServer($Req) {
    if ((Get-ServerStatus).running) { throw 'A model server is already running. Stop it first.' }
    if ((Get-TuneStatus).state -eq 'running') { throw 'An autotune is running. Wait for it to finish, or cancel it.' }
    $exe = $script:S.llamaServerPath
    if (-not $exe -or -not (Test-Path $exe)) { throw 'llama-server.exe not found. Set its path in Settings.' }
    $hw = (Get-HardwareView).effective
    $model = Get-InstalledModels $hw | Where-Object { $_.path -eq $Req.modelPath } | Select-Object -First 1
    if (-not $model) { throw 'That model is not in a configured model folder.' }
    $lp = Resolve-LaunchPlan $model $Req
    $ctx = $lp.ctx; $kvq = $lp.kvq
    $port = [int]$script:S.llamaPort
    $alias = $model.name
    $inUse = $false
    $tcp = [Net.Sockets.TcpClient]::new()
    try { $inUse = $tcp.ConnectAsync('127.0.0.1', $port).Wait(300) }
    catch { $inUse = $false }   # connection refused (faulted task) means the port is free
    finally { $tcp.Dispose() }
    if ($inUse) {
        throw "Port $port is already in use - another llama-server (not started from this dashboard) may be running. Stop it, or change the model server port in Settings."
    }

    $a = @('-m', $model.path, '--alias', $alias, '--host', '127.0.0.1', '--port', "$port", '-c', "$ctx", '-np', '1', '--jinja', '-fa', 'on')
    if ($kvq) { $a += @('-ctk', 'q8_0', '-ctv', 'q8_0') }
    # Models whose chat template rejects Claude Code's mid-conversation system message get a patched template.
    $tplFile = Get-TemplatePatchFile $model.path (Join-Path $Data 'templates')
    if ($tplFile) { $a += @('--chat-template-file', $tplFile) }
    # Settings found by the autotune for this exact model, context, KV type and machine (opt out with useTuned = false).
    $tuned = $false
    if ($Req.useTuned -ne $false) {
        $rec = Get-TuningRecord $model.name $ctx $kvq
        if ($rec -and $rec.applied -and @($rec.cliArgs).Count) { $a += @($rec.cliArgs | ForEach-Object { [string]$_ }); $tuned = $true }
    }
    if ($Req.vision -and $model.mmproj) { $a += @('--mmproj', $model.mmproj) }
    if ($Req.extraArgs) { $a += @(([string]$Req.extraArgs).Trim() -split '\s+' | Where-Object { $_ }) }

    Remove-Item $LogOut, $LogErr -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $exe -ArgumentList ($a | ForEach-Object { Quote-Arg $_ }) -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr -WorkingDirectory (Split-Path $exe)
    Write-Json $ServerFile @{
        pid = $proc.Id; startTicks = $proc.StartTime.ToFileTimeUtc(); port = $port; model = $model.name; modelPath = $model.path
        alias = $alias; ctx = $ctx; kvQuant = $kvq; templatePatched = [bool]$tplFile; tuned = $tuned; startedAt = (Get-Date).ToString('o'); args = $a
    }
    return Get-ServerStatus
}

# ---- Claude Code launch -----------------------------------------------------

function Find-Claude {
    if ($script:S.claudePath -and (Test-Path $script:S.claudePath)) { return $script:S.claudePath }
    $c = Get-Command claude -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in (Join-Path $HOME '.local\bin\claude.exe'), (Join-Path $env:APPDATA 'npm\claude.cmd'), (Join-Path $env:LOCALAPPDATA 'Programs\claude\claude.exe')) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-ProjectsView {
    $root = $script:S.projectsDir
    if (-not $root -or -not (Test-Path $root)) { return @() }
    @(Get-ChildItem $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^[.$]' -and $_.Name -ne 'node_modules' } |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { @{ name = $_.Name; path = $_.FullName; modified = $_.LastWriteTime.ToString('o') } })
}

function Test-InsideProjects([string]$Dir) {
    $full = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($script:S.projectsDir).TrimEnd('\')
    return ($full -ieq $root) -or $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
}

# Environment variables the local-model launch sets. The cloud launch clears every one of them so a
# session can never inherit a local endpoint from a parent shell.
$LocalEnvVars = @('ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL',
    'CLAUDE_CODE_ATTRIBUTION_HEADER', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC', 'CLAUDE_CODE_MAX_CONTEXT_TOKENS',
    'ENABLE_CLAUDEAI_MCP_SERVERS')

function Start-ClaudeCode($Req) {
    $mode = if ($Req.mode -eq 'cloud') { 'cloud' } else { 'local' }
    $claude = Find-Claude
    if (-not $claude) { throw 'Claude Code CLI not found. Install it or set its path in Settings.' }
    $dir = [string]$Req.projectDir
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container) -or -not (Test-InsideProjects $dir)) { throw 'Choose a folder inside your projects folder.' }
    $dir = [IO.Path]::GetFullPath($dir)
    $claudeQ = $claude.Replace("'", "''")
    $stopAfterLaunch = $false
    # Optional first message: the terminal opens already working on it, so the session is visibly alive.
    $initial = ([string]$Req.initialPrompt -replace '\s+', ' ').Trim()
    if ($initial.Length -gt 4000) { throw 'initialPrompt is too long (max 4000 characters).' }
    if ($initial.StartsWith('-')) { throw 'initialPrompt must not start with "-".' }
    $promptArg = if ($initial) { " '" + $initial.Replace("'", "''") + "'" } else { '' }
    # Opt-in (the tests use it): have Claude Code write a debug log we can read to verify what the visible session did.
    # The path is generated here, never taken from the request.
    $debugArg = ''; $debugPath = $null
    if ($Req.debugLog) {
        $dd = Join-Path $Data 'debug'; [void](New-Item -ItemType Directory -Force $dd)
        Get-ChildItem $dd -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | ForEach-Object { [IO.File]::Delete($_.FullName) }
        $debugPath = Join-Path $dd ('claude-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $debugArg = " --debug-file '" + $debugPath.Replace("'", "''") + "'"
    }

    if ($mode -eq 'cloud') {
        $script = Join-Path $Data 'launch-claude-cloud.ps1'
        $lines = @($LocalEnvVars | ForEach-Object { "Remove-Item Env:$_ -ErrorAction SilentlyContinue" })
        $lines += @(
            "`$Host.UI.RawUI.WindowTitle = 'Claude Code - cloud'",
            "Write-Host 'Claude Code -> Anthropic cloud (local-model settings cleared)' -ForegroundColor Cyan",
            "& '$claudeQ'$debugArg$promptArg"
        )
        $stopAfterLaunch = [bool]($Req.stopLocal -and (Get-ServerStatus).running)
    } else {
        $srv = Get-ServerStatus
        if (-not $srv.running) { throw 'Start a model first.' }
        if ($srv.state -ne 'ready') { throw 'The model is still loading. Wait until it is Ready.' }
        $alias = ([string]$srv.alias).Replace("'", "''")
        $script = Join-Path $Data 'launch-claude.ps1'
        $lines = @(
            "`$env:ANTHROPIC_BASE_URL = '$($srv.baseUrl)'",
            "`$env:ANTHROPIC_AUTH_TOKEN = 'local-llama-cpp'",
            "Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue",
            "`$env:ANTHROPIC_MODEL = '$alias'",
            "`$env:ANTHROPIC_DEFAULT_OPUS_MODEL = '$alias'",
            "`$env:ANTHROPIC_DEFAULT_SONNET_MODEL = '$alias'",
            "`$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = '$alias'",
            "`$env:CLAUDE_CODE_SUBAGENT_MODEL = '$alias'",
            "`$env:CLAUDE_CODE_ATTRIBUTION_HEADER = '0'",
            "`$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'",
            # Claude Code doesn't know local model names and would assume a 200k window and compact far too late.
            "`$env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = '$([int]$srv.ctx)'"
        )
        # Opt-in (the tests use it): leave the Claude login's account connectors (Gmail, Calendar, travel, brokerage...)
        # out of the session. They add ~100k tokens of tool definitions to every request, which a local model must
        # read before answering. Normal launches keep them.
        if ($Req.disableConnectors) { $lines += "`$env:ENABLE_CLAUDEAI_MCP_SERVERS = 'false'" }
        $lines += @(
            "`$Host.UI.RawUI.WindowTitle = 'Claude Code - local: $alias'",
            "Write-Host 'Claude Code -> $($srv.baseUrl)  model: $alias' -ForegroundColor Cyan",
            "& '$claudeQ'$debugArg$promptArg"
        )
    }
    Set-Content $script ($lines -join "`r`n") -Encoding utf8
    $pwsh = (Get-Process -Id $PID).Path
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    $psArgs = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Arg $script))
    # Optional tab title (the tests use it): pinned so Claude Code can't rename the tab, which lets a caller find
    # and close exactly this tab later. Restricted to plain characters; it ends up on a command line.
    $tabTitle = ([string]$Req.tabTitle).Trim()
    if ($tabTitle -and $tabTitle -notmatch '^[A-Za-z0-9 _.:\-]{1,80}$') { throw 'tabTitle may only contain letters, digits, spaces and _ . : -' }
    if ($wt) {
        $wtArgs = @('-d', (Quote-Arg $dir))
        if ($tabTitle) { $wtArgs += @('--title', (Quote-Arg $tabTitle), '--suppressApplicationTitle') }
        Start-Process $wt.Source -ArgumentList ($wtArgs + @($pwsh) + $psArgs)
    } else {
        Start-Process $pwsh -ArgumentList $psArgs -WorkingDirectory $dir
    }
    # Only stop the local model once the cloud session has actually been launched.
    if ($stopAfterLaunch) { Stop-LlamaServer }
    return @{ launched = $true; mode = $mode; dir = $dir; claude = $claude; stoppedLocal = $stopAfterLaunch; debugLog = $debugPath }
}

# ---- Hugging Face discovery -------------------------------------------------

$script:DiscJob = $null
$script:DiscCache = $null; $script:DiscCacheStamp = [datetime]::MinValue

$DiscJobScript = {
    param($Lib, $CacheFile, $StatusFile, $MaxParamsB)
    . $Lib
    $ErrorActionPreference = 'Stop'
    function Set-Status($state, $msg, $done = 0, $total = 0) {
        Write-Json $StatusFile @{ state = $state; message = $msg; done = $done; total = $total; at = (Get-Date).ToString('o') }
    }
    try {
        Set-Status 'running' 'Querying Hugging Face...'
        $exp = 'expand[]=downloads&expand[]=likes&expand[]=createdAt&expand[]=lastModified&expand[]=gguf&expand[]=pipeline_tag'
        $queries = @(
            "filter=gguf&pipeline_tag=text-generation&sort=trendingScore&limit=80",
            "filter=gguf&pipeline_tag=image-text-to-text&sort=trendingScore&limit=30",
            "filter=gguf&pipeline_tag=text-generation&sort=createdAt&limit=60",
            "filter=gguf&search=coder&sort=trendingScore&limit=30"
        )
        foreach ($a in 'unsloth', 'bartowski', 'ggml-org', 'lmstudio-community', 'Qwen', 'google', 'mistralai') {
            $queries += "filter=gguf&author=$a&sort=createdAt&limit=25"
        }
        $byId = @{}
        $qh = @{}; if ($env:HF_TOKEN) { $qh['Authorization'] = "Bearer $($env:HF_TOKEN)" }
        foreach ($pass in 1, 2) {
            foreach ($q in $queries) {
                try {
                    $r = Invoke-RestMethod "https://huggingface.co/api/models?$q&$exp" -Headers $qh -TimeoutSec 30
                    foreach ($m in $r) { if (-not $byId.ContainsKey($m.id)) { $byId[$m.id] = $m } }
                } catch { }
            }
            if ($byId.Count -gt 0) { break }
            Set-Status 'running' 'Hugging Face is rate limiting this IP - waiting a minute...'
            Start-Sleep 70
        }
        if ($byId.Count -eq 0) { throw 'Could not reach Hugging Face (offline?).' }
        $trusted = @('unsloth', 'bartowski', 'ggml-org', 'lmstudio-community', 'Qwen', 'google', 'mistralai', 'meta-llama', 'microsoft', 'deepseek-ai', 'zai-org', 'openai', 'nvidia', 'JetBrains')
        $cands = @($byId.Values | Where-Object {
                $_.gguf -and $_.gguf.total -and ($_.gguf.total / 1e9) -le $MaxParamsB -and
                ($_.pipeline_tag -in 'text-generation', 'image-text-to-text', 'any-to-any', $null)
            } | Sort-Object { ($(if (($_.id -split '/')[0] -in $trusted) { 100 } else { 0 })) + [math]::Log(1 + [double]$_.downloads) } -Descending | Select-Object -First 140)

        # Reuse file lists from the previous run when a repo hasn't changed (keeps API traffic low).
        $prev = @{}
        $old = Read-Json $CacheFile $null
        if ($old) { foreach ($o in $old.items) { $prev[$o.id] = $o } }
        $todo = @($cands | Where-Object { -not ($prev.ContainsKey($_.id) -and $prev[$_.id].lastModified -eq $_.lastModified) })
        Set-Status 'running' "Reading file lists for $($todo.Count) models..." 0 $todo.Count

        $libPath = $Lib
        $token = $env:HF_TOKEN
        $fetched = $todo | ForEach-Object -ThrottleLimit 3 -Parallel {
            . $using:libPath
            $m = $_
            $hdr = @{}
            if ($using:token) { $hdr['Authorization'] = "Bearer $($using:token)" }
            foreach ($wait in 0, 20, 70) {
                if ($wait) { Start-Sleep $wait }
                try {
                    $tree = Invoke-RestMethod "https://huggingface.co/api/models/$($m.id)/tree/main?recursive=true" -Headers $hdr -TimeoutSec 30
                    $g = Get-QuantGroups $tree
                    if ($g.groups.Count -eq 0) { return }
                    return @{
                        id = $m.id; downloads = [int64]$m.downloads; likes = [int]$m.likes; createdAt = $m.createdAt; lastModified = $m.lastModified
                        params = [int64]$m.gguf.total; arch = $m.gguf.architecture; ctxLen = $m.gguf.context_length; pipeline = $m.pipeline_tag
                        groups = $g.groups; mmproj = $g.mmproj
                    }
                } catch {
                    if ($_.Exception.Response.StatusCode -ne 429 -and "$($_.ErrorDetails.Message)" -notmatch 'rate limit') { return }
                }
            }
            return @{ id = $m.id; failed = $true }
        }
        $failed = @($fetched | Where-Object { $_.failed }).Count
        $fresh = @{}; foreach ($f in $fetched) { if (-not $f.failed) { $fresh[$f.id] = $f } }
        $items = foreach ($c in $cands) {
            if ($fresh.ContainsKey($c.id)) { $fresh[$c.id] }
            elseif ($prev.ContainsKey($c.id)) {
                $p = $prev[$c.id]; $p.downloads = [int64]$c.downloads; $p.likes = [int]$c.likes; $p
            }
        }
        Write-Json $CacheFile @{ fetchedAt = (Get-Date).ToString('o'); items = @($items) }
        $note = if ($failed) { " ($failed skipped - Hugging Face rate limit; refresh again in a few minutes, or set HF_TOKEN)" } else { '' }
        Set-Status 'done' "Found $(@($items).Count) models.$note" @($items).Count @($items).Count
    } catch {
        Set-Status 'error' $_.Exception.Message
    }
}

function Start-DiscoverRefresh {
    if ($script:DiscJob -and $script:DiscJob.State -eq 'Running') { return }
    if ($script:DiscJob) { Remove-Job $script:DiscJob -Force -ErrorAction SilentlyContinue }
    Write-Json $DiscStatusFile @{ state = 'running'; message = 'Starting...'; done = 0; total = 0; at = (Get-Date).ToString('o') }
    $script:DiscJob = Start-ThreadJob -ScriptBlock $DiscJobScript -ArgumentList (Join-Path $Root 'lib.ps1'), $DiscCacheFile, $DiscStatusFile, 150
}

$TrustedOrgs = @('unsloth', 'bartowski', 'ggml-org', 'lmstudio-community', 'Qwen', 'google', 'meta-llama', 'mistralai', 'microsoft', 'deepseek-ai',
    'zai-org', 'openai', 'nvidia', 'JetBrains', 'ibm-granite', 'HuggingFaceTB', 'allenai', 'CohereLabs', 'moonshotai', 'MiniMaxAI')

function Get-DiscoverView {
    $hwv = Get-HardwareView
    $hw = $hwv.effective
    if (Test-Path $DiscCacheFile) {
        $stamp = (Get-Item $DiscCacheFile).LastWriteTimeUtc
        if ($stamp -ne $script:DiscCacheStamp) { $script:DiscCache = Read-Json $DiscCacheFile $null; $script:DiscCacheStamp = $stamp }
    }
    $status = Read-Json $DiscStatusFile @{ state = 'idle'; message = ''; done = 0; total = 0 }
    if ($status.state -eq 'running' -and -not ($script:DiscJob -and $script:DiscJob.State -eq 'Running')) {
        $status = @{ state = 'error'; message = 'Refresh was interrupted.'; done = 0; total = 0 }
    }
    if (-not $script:DiscCache) { return @{ items = @(); fetchedAt = $null; status = $status; needsInput = $hwv.needsInput } }

    $installedNames = @{}
    foreach ($m in (Get-InstalledModels $hw)) { $installedNames[(Split-Path $m.path -Leaf).ToLower()] = $true }
    $seen = @{}; foreach ($s in @($script:S.seen)) { $seen[$s] = $true }
    if (-not $script:S.seenBaselined) {
        foreach ($i in $script:DiscCache.items) { $seen[$i.id] = $true }
        $script:S.seen = @($seen.Keys); $script:S.seenBaselined = $true; Save-Settings
    }
    $now = Get-Date
    $out = foreach ($i in $script:DiscCache.items) {
        $name = ($i.id -split '/', 2)[1]
        $org = ($i.id -split '/', 2)[0]
        $isMoe = Test-IsMoe $name
        $paramsB = [math]::Round($i.params / 1e9, 1)
        $age = $null
        try {
            $created = if ($i.createdAt -is [datetime]) { $i.createdAt } else { [datetime]::Parse([string]$i.createdAt, [Globalization.CultureInfo]::InvariantCulture) }
            $age = [int]($now - $created).TotalDays
        } catch { }
        $variant = [bool]($name -match '(?i)uncensor|abliterat|obliterat|decensor|derestrict|heretic|jailbreak|nsfw|roleplay|erp\b|humaniz|lobotom')
        $trusted = ($org -in $TrustedOrgs)

        $quants = foreach ($g in $i.groups) {
            $gb = [math]::Round($g.size / 1GB, 2)
            @{ quant = $g.quant; bits = $g.bits; sizeGB = $gb; files = @($g.files); fit = (Get-Fit $gb $isMoe $hw) }
        }
        # Drop files too small to be a complete model of this size (draft heads, adapters, partial uploads).
        $quants = @($quants | Where-Object { $_.sizeGB -ge $paramsB * 0.18 })
        if (-not $quants.Count) { continue }
        # Choose the quant to suggest for this machine.
        $cand = @($quants | Where-Object { $_.bits -lt 16 -and $_.bits -ge 2 })
        if (-not $cand.Count) { $cand = $quants }
        $gpuBudget = [math]::Max(0.0, $hw.vramGB * 0.95 - 1.2)
        # Quality-first: prefer Q4 or better. Use the biggest (<=Q6) quant that comfortably fits on the GPU;
        # failing that, the smallest Q4+ quant that fits with CPU/RAM offload; only then fall back to Q3/Q2.
        $good = @($cand | Where-Object { $_.bits -ge 4 })
        $best = $good | Where-Object { $_.fit.tier -eq 'gpu' -and $_.sizeGB -le $gpuBudget * 0.92 -and $_.bits -le 6 } | Sort-Object { $_.sizeGB } -Descending | Select-Object -First 1
        if (-not $best) { $best = $good | Where-Object { $_.fit.tier -eq 'gpu' } | Sort-Object { $_.sizeGB } | Select-Object -First 1 }
        if (-not $best) { $best = $good | Where-Object { $_.fit.tier -in 'moe', 'partial', 'cpu' } | Sort-Object { $_.sizeGB } | Select-Object -First 1 }
        if (-not $best) { $best = $cand | Where-Object { $_.fit.tier -ne 'toobig' } | Sort-Object { $_.bits }, { $_.sizeGB } -Descending | Select-Object -First 1 }
        if (-not $best) { $best = $cand | Sort-Object { $_.sizeGB } | Select-Object -First 1 }

        $score = (Get-ModelScore $paramsB $isMoe $best.fit)
        if ($best.bits -le 2) { $score -= 3.0 } elseif ($best.bits -eq 3) { $score -= 1.2 }
        $score += 0.25 * [math]::Log(1 + $i.downloads / 1000.0)
        $score += $(if ($trusted) { 1.5 } else { -1.0 })
        if ($variant) { $score -= 3 }
        if ($null -ne $age) { if ($age -le 21) { $score += 0.8 } elseif ($age -le 90) { $score += 0.4 } }
        if ($name -match '(?i)coder|code') { $score += 1.0 }

        $bestFile = ($best.files | Select-Object -First 1)
        @{
            id = $i.id; org = $org; name = $name; paramsB = $paramsB; activeB = (Get-ActiveB $name); isMoe = $isMoe
            downloads = $i.downloads; likes = $i.likes; createdAt = $i.createdAt; ageDays = $age; isNew = ($null -ne $age -and $age -le 21)
            unseen = (-not $seen.ContainsKey($i.id)); trusted = $trusted; variant = $variant
            installed = [bool]$installedNames[(Split-Path $bestFile -Leaf).ToLower()]
            best = $best; quants = @($quants | Sort-Object { $_.sizeGB }); mmproj = $i.mmproj; ctxLen = $i.ctxLen
            tier = $best.fit.tier; score = [math]::Round($score, 2); url = "https://huggingface.co/$($i.id)"
        }
    }
    return @{
        items      = @($out | Sort-Object { $_.score } -Descending)
        fetchedAt  = $script:DiscCache.fetchedAt
        status     = $status
        needsInput = $hwv.needsInput
    }
}

# ---- Downloads --------------------------------------------------------------

$script:Downloads = @{}

# Size of a remote file via HEAD (HF reports the real size of redirected LFS files in x-linked-size).
function Get-RemoteSize([string]$Url) {
    try {
        $hdr = @(& curl.exe -sIL --max-time 15 $Url 2>$null)
        $linked = $hdr | Where-Object { $_ -match '(?i)^x-linked-size:\s*\d+' } | Select-Object -Last 1
        if ($linked -match '(\d+)\s*$') { return [int64]$Matches[1] }
        $len = $hdr | Where-Object { $_ -match '(?i)^content-length:\s*\d+' } | Select-Object -Last 1
        if ($len -match '(\d+)\s*$') { return [int64]$Matches[1] }
    } catch { }
    return [int64]0
}

function Start-ModelDownload($Req) {
    $repo = [string]$Req.repo
    if ($repo -notmatch '^[\w.-]+/[\w.-]+$') { throw 'Invalid repository id.' }
    if (-not $script:DiscCache) { throw 'Refresh the model list first.' }
    $item = $script:DiscCache.items | Where-Object { $_.id -eq $repo } | Select-Object -First 1
    if (-not $item) { throw 'Unknown repository.' }
    $known = @{}
    foreach ($g in $item.groups) { foreach ($f in $g.files) { $known[$f] = $true } }
    $sizes = @{}
    foreach ($g in $item.groups) { if ($g.files.Count -eq 1) { $sizes[$g.files[0]] = [int64]$g.size } }

    $want = @($Req.files)
    if ($Req.mmproj -and $item.mmproj) { $want += $item.mmproj.path; $sizes[$item.mmproj.path] = [int64]$item.mmproj.size; $known[$item.mmproj.path] = $true }
    if (-not $want.Count) { throw 'No files selected.' }
    foreach ($f in $want) { if (-not $known.ContainsKey($f)) { throw "Unknown file: $f" } }

    $destDir = Join-Path $script:S.downloadDir ($repo -replace '/', '--')
    New-Item -ItemType Directory -Force $destDir | Out-Null
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $dl = @{ id = $id; repo = $repo; files = @(); status = 'downloading'; error = $null; startedAt = (Get-Date).ToString('o') }
    $n = 0
    foreach ($f in $want) {
        $leaf = Split-Path $f -Leaf
        $final = Join-Path $destDir $leaf
        $part = "$final.part"
        $err = Join-Path $Data "dl-$id-$n.err"
        $url = 'https://huggingface.co/' + $repo + '/resolve/main/' + (($f -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
        $size = [int64]($sizes[$f] ?? 0)
        if ($size -le 0) { $size = Get-RemoteSize $url }   # sharded files: only the group total is cached
        if ((Test-Path -LiteralPath $final) -and $size -gt 0 -and (Get-Item -LiteralPath $final).Length -eq $size) {
            $dl.files += @{ name = $leaf; part = $part; final = $final; size = $size; proc = $null; errFile = $err; state = 'done' }   # already have it
            $n++; continue
        }
        $proc = Start-Process curl.exe -ArgumentList @('-L', '--fail', '-sS', '-C', '-', '--retry', '3', '-o', (Quote-Arg $part), $url) -WindowStyle Hidden -PassThru -RedirectStandardError $err
        $dl.files += @{ name = $leaf; part = $part; final = $final; size = $size; proc = $proc; errFile = $err; state = 'downloading' }
        $n++
    }
    $script:Downloads[$id] = $dl
    return @{ id = $id }
}

function Get-DownloadsView {
    $out = foreach ($dl in $script:Downloads.Values) {
        $done = [int64]0; $total = [int64]0; $allDone = $true; $failed = $null
        foreach ($f in $dl.files) {
            if ($f.state -eq 'downloading' -and $f.proc.HasExited) {
                if ($f.proc.ExitCode -eq 0 -and (Test-Path $f.part)) {
                    Move-Item $f.part $f.final -Force; $f.state = 'done'
                } else {
                    $f.state = 'failed'
                    $msg = if (Test-Path $f.errFile) { (Get-Content $f.errFile -Raw).Trim() } else { '' }
                    $f.error = if ($msg -match '40[13]') { 'Access denied - this model is gated and needs a Hugging Face login.' } elseif ($msg) { $msg } else { "curl exit code $($f.proc.ExitCode)" }
                }
            }
            $cur = 0
            if ($f.state -eq 'done') { $cur = (Get-Item $f.final).Length }
            elseif (Test-Path $f.part) { $cur = (Get-Item $f.part).Length }
            $done += $cur; $total += [math]::Max($f.size, $cur)
            if ($f.state -eq 'downloading') { $allDone = $false }
            if ($f.state -eq 'failed') { $failed = $f.error }
        }
        if ($dl.status -eq 'downloading') {
            if ($failed) {
                $dl.status = 'failed'; $dl.error = $failed
                # One file failed, so the set is unusable: stop its siblings instead of leaving them running unseen.
                foreach ($f in $dl.files) {
                    if ($f.state -eq 'downloading' -and $f.proc -and -not $f.proc.HasExited) { Stop-Process -Id $f.proc.Id -Force -ErrorAction SilentlyContinue }
                    if ($f.state -eq 'downloading') { $f.state = 'cancelled' }
                }
            }
            elseif ($allDone) { $dl.status = 'done' }
        }
        @{ id = $dl.id; repo = $dl.repo; status = $dl.status; error = $dl.error; doneBytes = $done; totalBytes = $total; files = @($dl.files | ForEach-Object { $_.name }) }
    }
    return @($out)
}

function Stop-ModelDownload([string]$Id) {
    $dl = $script:Downloads[$Id]
    if (-not $dl) { throw 'Unknown download.' }
    foreach ($f in $dl.files) {
        if ($f.state -eq 'downloading' -and -not $f.proc.HasExited) { Stop-Process -Id $f.proc.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item $f.part -ErrorAction SilentlyContinue
        if ($f.state -eq 'downloading') { $f.state = 'cancelled' }
    }
    $dl.status = 'cancelled'
}

# ---- Storage overview -------------------------------------------------------

function Get-DirSize([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    return [int64](Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
}

# -NoSizes skips the (slow) recursive folder sizing; used when only the list of paths is needed.
function Get-StorageView([switch]$NoSizes) {
    if ($NoSizes) { function Get-DirSize { [int64]0 } }
    $hw = (Get-HardwareView).effective
    $models = @(Get-InstalledModels $hw)
    $items = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($group, $label, $path, $kind, $size, $detail)
        $path = [string]$path
        $items.Add(@{ group = $group; label = $label; path = $path; kind = $kind; exists = [bool]($path -and (Test-Path $path)); sizeBytes = $size; detail = $detail })
    }

    $dirs = @($script:S.modelDirs | Where-Object { $_ })
    $dl = [string]$script:S.downloadDir
    foreach ($d in $dirs) {
        $under = @($models | Where-Object { $_.path.StartsWith($d.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
        $bytes = [int64]($under | Measure-Object sizeBytes -Sum).Sum
        $role = if ($d -ieq $dl) { 'Scanned for models - also where new downloads are saved' } else { 'Scanned for models' }
        & $add 'Models' 'Model folder' $d 'dir' $bytes "$($under.Count) model$(if ($under.Count -ne 1) { 's' }) - $role"
    }
    if ($dl -and $dl -notin $dirs) {
        & $add 'Models' 'Download folder' $dl 'dir' (Get-DirSize $dl) 'Where new downloads are saved'
    }
    $part = @(); if ($dl -and (Test-Path $dl)) { $part = @(Get-ChildItem $dl -Recurse -File -Filter *.part -ErrorAction SilentlyContinue) }
    if ($part.Count) { & $add 'Models' 'Unfinished downloads' $dl 'dir' ([int64]($part | Measure-Object Length -Sum).Sum) "$($part.Count) .part file(s) - resume by downloading again" }
    foreach ($m in $models) {
        $label = if ($m.repo) { $m.repo } else { $m.name }
        & $add 'Model files' $label $m.path 'file' $m.sizeBytes "$($m.quant)$(if ($m.mmproj) { ' - vision projector: ' + (Split-Path $m.mmproj -Leaf) })"
    }

    $llama = [string]$script:S.llamaServerPath
    & $add 'Programs' 'llama-server' $llama 'file' $(if ($llama -and (Test-Path $llama)) { (Get-Item $llama).Length } else { $null }) (Get-LlamaVersion)
    $claude = Find-Claude
    & $add 'Programs' 'Claude Code CLI' $claude 'file' $(if ($claude -and (Test-Path $claude)) { (Get-Item $claude).Length } else { $null }) $(if ($claude) { 'Used by the launch buttons' } else { 'Not installed' })
    & $add 'Programs' 'Claude Code settings & history' (Join-Path $HOME '.claude') 'dir' $null 'Your Claude Code config, sessions and memory'

    & $add 'Dashboard' 'Dashboard data folder' $Data 'dir' (Get-DirSize $Data) 'Settings, logs and the model catalogue cache (outside the synced project folder)'
    $files = @(
        @($SettingsFile, 'Settings'), @($DiscCacheFile, 'Hugging Face catalogue cache'), @($ServerFile, 'Running-model record'),
        @($LogErr, 'llama-server log (stderr)'), @($LogOut, 'llama-server log (stdout)'),
        @((Join-Path $Data 'launch-claude.ps1'), 'Local-model Claude launcher'), @((Join-Path $Data 'launch-claude-cloud.ps1'), 'Cloud Claude launcher')
    )
    foreach ($f in $files) { if (Test-Path $f[0]) { & $add 'Dashboard' $f[1] $f[0] 'file' (Get-Item $f[0]).Length '' } }
    & $add 'Dashboard' 'Dashboard application' $Root 'dir' (Get-DirSize $Root) 'The code you run with start.cmd'
    & $add 'Dashboard' 'Projects folder' $script:S.projectsDir 'dir' $null 'Where Claude Code is launched from'

    $disks = @()
    $roots = @($dirs + $dl | Where-Object { $_ -and $_.Length -ge 2 -and $_[1] -eq ':' } | ForEach-Object { $_.Substring(0, 2).ToUpper() } | Select-Object -Unique)
    foreach ($r in $roots) {
        try { $di = [IO.DriveInfo]::new($r); $disks += @{ drive = $r; freeBytes = [int64]$di.AvailableFreeSpace; totalBytes = [int64]$di.TotalSize } } catch { }
    }
    return @{ items = @($items); disks = $disks }
}

function Open-InExplorer([string]$Path) {
    $known = @((Get-StorageView -NoSizes).items | ForEach-Object { $_.path })
    if ($Path -notin $known) { throw 'That location is not one of the dashboard''s storage paths.' }
    if (-not (Test-Path -LiteralPath $Path)) { throw 'That location does not exist yet.' }
    if (Test-Path -LiteralPath $Path -PathType Container) { Start-Process explorer.exe -ArgumentList (Quote-Arg $Path) }
    else { Start-Process explorer.exe -ArgumentList "/select,$(Quote-Arg $Path)" }
}

# ---- HTTP plumbing ----------------------------------------------------------

$Mime = @{ '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.svg' = 'image/svg+xml'; '.json' = 'application/json'; '.ico' = 'image/x-icon' }

function Send-Bytes($Ctx, [int]$Status, [byte[]]$Bytes, [string]$Type) {
    $r = $Ctx.Response
    $r.StatusCode = $Status
    $r.ContentType = $Type
    $r.Headers['Cache-Control'] = 'no-store'
    $r.Headers['X-Content-Type-Options'] = 'nosniff'
    $r.ContentLength64 = $Bytes.Length
    $r.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $r.Close()
}

function Send-Json($Ctx, $Obj, [int]$Status = 200) {
    $json = ConvertTo-Json -InputObject $Obj -Depth 12 -Compress
    Send-Bytes $Ctx $Status ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8'
}

function Read-Body($Ctx) {
    $sr = [IO.StreamReader]::new($Ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd()
    if (-not $txt) { return @{} }
    return ($txt | ConvertFrom-Json -AsHashtable)
}

function Get-PublicState {
    $hwv = Get-HardwareView
    $pub = @{}; foreach ($k in $script:S.Keys) { if ($k -ne 'seen') { $pub[$k] = $script:S[$k] } }   # 'seen' is a long internal ID list
    return @{
        hardware = $hwv
        settings = $pub
        llama    = @{ path = $script:S.llamaServerPath; found = [bool]($script:S.llamaServerPath -and (Test-Path -LiteralPath $script:S.llamaServerPath)); version = (Get-LlamaVersion) }
        claude   = @{ path = (Find-Claude) }
    }
}

function Invoke-Api($Ctx, [string]$Method, [string]$Path) {
    $q = $Ctx.Request.QueryString
    switch ("$Method $Path") {
        'GET /api/state' { return Get-PublicState }
        'GET /api/models' { $hw = (Get-HardwareView).effective; return @{ models = @(Get-InstalledModels $hw) } }
        'GET /api/server' {
            $st = Get-ServerStatus
            $st.processes = @(Get-LlamaProcesses ([int]($st.pid ?? 0)))
            return $st
        }
        'POST /api/server/force-stop' { return Stop-AllLlamaServers }
        'GET /api/tune' { return Get-TuneStatus }
        'POST /api/tune/start' { return Start-AutoTune (Read-Body $Ctx) }
        'POST /api/tune/cancel' { Stop-AutoTune; return Get-TuneStatus }
        'POST /api/tune/reset' { $b = Read-Body $Ctx; Reset-Tuning ([string]$b.model); return @{ ok = $true } }
        'GET /api/logs' { $n = [int]($q['lines'] ?? 80); return @{ lines = @((Get-LogTail $LogErr $n) + (Get-LogTail $LogOut 10) | Select-Object -Last $n) } }
        'GET /api/projects' { return @{ root = $script:S.projectsDir; projects = @(Get-ProjectsView) } }
        'GET /api/discover' { return Get-DiscoverView }
        'GET /api/storage' { return Get-StorageView }
        'POST /api/storage/open' { $b = Read-Body $Ctx; Open-InExplorer ([string]$b.path); return @{ ok = $true } }
        'GET /api/downloads' { return @{ downloads = @(Get-DownloadsView) } }
        'POST /api/server/start' { return Start-LlamaServer (Read-Body $Ctx) }
        'POST /api/server/stop' { Stop-LlamaServer; return Get-ServerStatus }
        'POST /api/claude/launch' { return Start-ClaudeCode (Read-Body $Ctx) }
        'POST /api/discover/refresh' { Start-DiscoverRefresh; return @{ started = $true } }
        'POST /api/discover/seen' {
            $v = Get-DiscoverView
            $script:S.seen = @($v.items | ForEach-Object { $_.id }); Save-Settings
            return @{ ok = $true }
        }
        'POST /api/download' { return Start-ModelDownload (Read-Body $Ctx) }
        'POST /api/download/cancel' { $b = Read-Body $Ctx; Stop-ModelDownload ([string]$b.id); return @{ ok = $true } }
        'POST /api/hardware' {
            $b = Read-Body $Ctx
            # Index by key: `$b.clear` would resolve to Hashtable.Clear() (a truthy method) when the key is absent.
            if ($b.ContainsKey('clear') -and $b['clear']) { $script:S.hardwareOverride = $null }
            else {
                $vram = [double]$b.vramGB; $ram = [double]$b.ramGB
                if ($vram -lt 0 -or $vram -gt 1024) { throw 'VRAM must be between 0 and 1024 GB.' }
                if ($ram -lt 1 -or $ram -gt 8192) { throw 'RAM must be between 1 and 8192 GB.' }
                $name = ([string]$b.gpuName).Trim()
                if (-not $name) { $name = if ($vram -gt 0) { 'Custom GPU' } else { 'No dedicated GPU (CPU only)' } }
                $script:S.hardwareOverride = @{ gpuName = $name; vramGB = $vram; ramGB = $ram }
            }
            Save-Settings
            return Get-PublicState
        }
        'POST /api/settings' {
            $b = Read-Body $Ctx
            # Validate everything before changing anything, so a bad field can't leave settings half-applied.
            $new = @{}
            foreach ($k in 'llamaServerPath', 'claudePath', 'downloadDir', 'projectsDir') {
                if (-not $b.ContainsKey($k)) { continue }
                $v = ([string]$b[$k]).Trim()
                if ($k -ne 'claudePath' -and -not $v) { throw "$k can't be empty." }
                if ($v -and -not [IO.Path]::IsPathRooted($v)) { throw "$k must be a full path (like C:\...)." }
                $new[$k] = $v
            }
            if ($b.ContainsKey('modelDirs')) {
                $dirs = @($b.modelDirs | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
                foreach ($d in $dirs) { if (-not [IO.Path]::IsPathRooted($d)) { throw "Model folder '$d' must be a full path (like C:\...)." } }
                $new['modelDirs'] = $dirs
            }
            foreach ($k in $new.Keys) { $script:S[$k] = $new[$k] }
            if ($b.ContainsKey('llamaPort')) {
                $p = [int]$b.llamaPort
                if ($p -lt 1024 -or $p -gt 65535) { throw 'Port must be 1024-65535.' }
                $script:S.llamaPort = $p
            }
            $script:LlamaVersion = $null; $script:LlamaVersionTried = $false
            Save-Settings
            return Get-PublicState
        }
        default { return $null }
    }
}

function Handle-Request($Ctx) {
    $req = $Ctx.Request
    $path = $req.Url.AbsolutePath
    $origin = "http://127.0.0.1:$($script:S.port)"
    $hostOk = $req.Headers['Host'] -in "127.0.0.1:$($script:S.port)", "localhost:$($script:S.port)"
    if (-not $hostOk) { return Send-Json $Ctx @{ error = 'Bad host header.' } 403 }

    if ($path.StartsWith('/api/')) {
        if ($req.HttpMethod -eq 'POST') {
            $o = $req.Headers['Origin']
            if ($req.Headers['X-Switchboard'] -ne '1' -or ($o -and $o -notin $origin, "http://localhost:$($script:S.port)")) {
                return Send-Json $Ctx @{ error = 'Cross-origin request blocked.' } 403
            }
        }
        try {
            $result = Invoke-Api $Ctx $req.HttpMethod $path
            if ($null -eq $result) { return Send-Json $Ctx @{ error = 'Not found.' } 404 }
            return Send-Json $Ctx $result
        } catch {
            return Send-Json $Ctx @{ error = $_.Exception.Message } 400
        }
    }

    if ($req.HttpMethod -ne 'GET') { return Send-Json $Ctx @{ error = 'Method not allowed.' } 405 }
    $rel = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') -replace '/', '\' }
    $full = [IO.Path]::GetFullPath((Join-Path $UiDir $rel))
    if (-not $full.StartsWith($UiDir + '\', [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $full -PathType Leaf)) {
        return Send-Json $Ctx @{ error = 'Not found.' } 404
    }
    $type = $Mime[[IO.Path]::GetExtension($full).ToLower()] ?? 'application/octet-stream'
    Send-Bytes $Ctx 200 ([IO.File]::ReadAllBytes($full)) $type
}

# ---- Main -------------------------------------------------------------------

$port = [int]$script:S.port
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
try { $listener.Start() } catch {
    Write-Host "Could not listen on 127.0.0.1:$port - is the dashboard already running? ($($_.Exception.Message))" -ForegroundColor Red
    exit 1
}

# Refresh the model catalogue in the background if it is missing or older than 12 hours.
$cacheAge = if (Test-Path $DiscCacheFile) { ((Get-Date) - (Get-Item $DiscCacheFile).LastWriteTime).TotalHours } else { 999 }
if ($cacheAge -gt 12) { Start-DiscoverRefresh }

Write-Host ''
Write-Host "  LLM Switchboard running at http://127.0.0.1:$port/" -ForegroundColor Cyan
Write-Host '  Close this window (or Ctrl+C) to stop the dashboard. A running model keeps running.' -ForegroundColor DarkGray
Write-Host ''
if (-not $NoBrowser) { Start-Process "http://127.0.0.1:$port/" }

try {
    while ($listener.IsListening) {
        $task = $listener.GetContextAsync()
        while (-not $task.AsyncWaitHandle.WaitOne(500)) { }
        $ctx = $task.GetAwaiter().GetResult()
        try { Handle-Request $ctx } catch {
            try { Send-Json $ctx @{ error = $_.Exception.Message } 500 } catch { }
        }
    }
} finally {
    $listener.Stop()
}
