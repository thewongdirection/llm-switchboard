#requires -Version 7.0
<#
  Autotune: find the fastest llama-server settings for ONE model on THIS machine.

  It launches real, throw-away llama-server instances (on a private port) with different settings and measures
  generation speed and prompt-reading speed on each, then keeps the fastest combination that is also SAFE
  (leaves VRAM headroom, so the desktop or a browser can't push it out of memory later):

    1. baseline    exactly what the dashboard launches today (llama-server's own --fit decides the offload)
    2. offload     how much of the model stays on the GPU: for mixture-of-experts models the number of layers whose
                   experts live in system RAM (--n-cpu-moe), otherwise the number of layers on the GPU (-ngl).
                   Binary search for the most GPU use that still leaves headroom.
    3. batch       physical batch size (-ub), which mostly speeds up reading long prompts
    4. threads     CPU threads (-t), only when the CPU does part of the work

  The dashboard runs this for you (Launch card -> Autotune). To run it by hand:
    pwsh -File tune.ps1 -ModelPath <file.gguf> -Ctx 65536 -LlamaServer <llama-server.exe> [-IsMoe -Layers 30] [-KvQuant]

  Results are saved to %LOCALAPPDATA%\llm-switchboard\tuning.json, keyed by model file, context, KV type and hardware,
  and the dashboard then starts that model with the tuned flags automatically.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ModelPath,
    [Parameter(Mandatory)][int]$Ctx,
    [Parameter(Mandatory)][string]$LlamaServer,
    [string]$ModelName = '',      # the name the dashboard knows the model by (keys the saved result)
    [switch]$KvQuant,
    [switch]$IsMoe,
    [int]$Layers = 0,
    [int]$Port = 8189,
    [string]$TemplateFile = '',
    [string]$HwSig = '',
    [string]$StatusFile = '',
    [string]$DbFile = '',
    [int]$MarginMiB = 1000,       # VRAM that must stay free in the winning configuration (the desktop's own use drifts by ~1 GB)
    [switch]$Quick                # fewer trials (skips the threads sweep and the neighbour check)
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib.ps1')
$MarginMiB = Get-MarginMiB $MarginMiB
$data = Join-Path $env:LOCALAPPDATA 'llm-switchboard'
[void](New-Item -ItemType Directory -Force $data)
if (-not $StatusFile) { $StatusFile = Join-Path $data 'tune-status.json' }
if (-not $DbFile) { $DbFile = Join-Path $data 'tuning.json' }
$trialOut = Join-Path $data 'tune-trial.out.log'; $trialErr = Join-Path $data 'tune-trial.err.log'

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cores = [int]$cpu.NumberOfCores; $logical = [int]$cpu.NumberOfLogicalProcessors
$modelName = if ($ModelName) { $ModelName } else { [IO.Path]::GetFileNameWithoutExtension($ModelPath) }
$trials = [System.Collections.Generic.List[object]]::new()
$cache = @{}                      # argument signature -> trial result (never measure the same thing twice)
$script:step = 0; $script:steps = 0
$script:server = $null

function Quote-Arg([string]$a) { if ($a -match '\s') { return '"' + $a + '"' } return $a }

function Set-Status([string]$State, [string]$Phase, [string]$Message, $Extra = @{}) {
    $best = $trials | Where-Object { $_.ok -and $_.safe } | Sort-Object { $_.score } -Descending | Select-Object -First 1
    $s = @{
        state = $State; phase = $Phase; message = $Message; pid = $PID; model = $modelName; ctx = $Ctx; kvQuant = [bool]$KvQuant
        step = $script:step; steps = $script:steps; updatedAt = (Get-Date).ToString('o')
        trials = @($trials | ForEach-Object { @{ label = $_.label; ok = $_.ok; safe = $_.safe; gen = $_.gen; prompt = $_.prompt; freeMiB = $_.freeMiB; error = $_.error } })
        best = $(if ($best) { @{ label = $best.label; gen = $best.gen; prompt = $best.prompt } } else { $null })
    }
    foreach ($k in $Extra.Keys) { $s[$k] = $Extra[$k] }
    Write-Json $StatusFile $s
}

function Stop-Trial {
    if ($script:server -and -not $script:server.HasExited) {
        try { Stop-Process -Id $script:server.Id -Force -ErrorAction SilentlyContinue; [void]$script:server.WaitForExit(15000) } catch { }
    }
    $script:server = $null
}

# ---- one measurement -----------------------------------------------------------

function Get-FreeMiB {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) { return $null }
    try { $p = (& $smi.Source '--query-gpu=memory.used,memory.total' '--format=csv,noheader,nounits' 2>$null | Select-Object -First 1) -split ',\s*'; return [int]$p[1] - [int]$p[0] } catch { return $null }
}

# Synthetic prompt of roughly 5k tokens, so prompt-reading speed is measured on something Claude-Code-sized.
$bigPrompt = & {
    $sb = [Text.StringBuilder]::new(); $rng = [Random]::new(7)
    1..300 | ForEach-Object { [void]$sb.AppendLine(("Entry {0}: sensor={1} reading={2} status=nominal note=checked" -f $_, $rng.Next(100, 999), $rng.Next(10000, 99999))) }
    $sb.ToString()
}

function Invoke-Completion([hashtable]$Body) {
    Invoke-RestMethod "http://127.0.0.1:$Port/completion" -Method Post -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 4) -TimeoutSec 300
}

function Invoke-Trial([string]$Label, [string[]]$Extra) {
    $sig = ($Extra -join ' ')
    if ($cache.ContainsKey($sig)) { return $cache[$sig] }
    $script:step++
    Set-Status 'running' $script:phase "Trial $($script:step) of ~$($script:steps): $Label" @{ current = $Label }

    $a = @('-m', $ModelPath, '--host', '127.0.0.1', '--port', "$Port", '-c', "$Ctx", '-np', '1', '--jinja', '-fa', 'on')
    if ($KvQuant) { $a += @('-ctk', 'q8_0', '-ctv', 'q8_0') }
    if ($TemplateFile) { $a += @('--chat-template-file', $TemplateFile) }
    $a += $Extra
    foreach ($f in $trialOut, $trialErr) { if (Test-Path $f) { [IO.File]::Delete($f) } }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = @{ label = $Label; args = @($Extra); ok = $false; safe = $false; gen = 0.0; prompt = 0.0; freeMiB = $null; secs = 0; error = ''; score = 0.0 }
    try {
        $script:server = Start-Process -FilePath $LlamaServer -ArgumentList ($a | ForEach-Object { Quote-Arg $_ }) -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $trialOut -RedirectStandardError $trialErr -WorkingDirectory (Split-Path $LlamaServer)
        $up = $false
        while ($sw.Elapsed.TotalSeconds -lt 300) {
            Start-Sleep -Milliseconds 1500
            if ($script:server.HasExited) { break }
            try { if ((Invoke-WebRequest "http://127.0.0.1:$Port/health" -TimeoutSec 2 -SkipHttpErrorCheck).StatusCode -eq 200) { $up = $true; break } } catch { }
        }
        if (-not $up) {
            $tail = @(Get-Content $trialErr -ErrorAction SilentlyContinue | Where-Object { $_ -match 'out of memory|failed|error|cudaMalloc|alloc' } | Select-Object -Last 2)
            throw $(if ($tail) { ($tail -join ' ') -replace '\s+', ' ' } elseif ($script:server.HasExited) { 'server exited while loading' } else { 'did not become ready in 5 minutes' })
        }
        [void](Invoke-Completion @{ prompt = 'Hello'; n_predict = 8; temperature = 0; cache_prompt = $false })     # warm-up (CUDA graphs, caches)
        $gen = 0.0; $prm = 0.0
        foreach ($i in 1, 2) {
            $g = Invoke-Completion @{ prompt = 'Write a long, detailed story about a lighthouse keeper.'; n_predict = 96; temperature = 0; cache_prompt = $false; ignore_eos = $true }
            $gen = [math]::Max($gen, [double]$g.timings.predicted_per_second)
        }
        foreach ($i in 1, 2) {
            $p = Invoke-Completion @{ prompt = $bigPrompt; n_predict = 1; temperature = 0; cache_prompt = $false }
            $prm = [math]::Max($prm, [double]$p.timings.prompt_per_second)
        }
        $r.freeMiB = Get-FreeMiB           # measured with the model loaded and after the big prompt, i.e. at peak use
        $r.gen = [math]::Round($gen, 1); $r.prompt = [math]::Round($prm, 0); $r.ok = ($gen -gt 0 -and $prm -gt 0)
        $r.safe = $r.ok -and ($null -eq $r.freeMiB -or $r.freeMiB -ge $MarginMiB)
        $r.score = [math]::Sqrt($gen * $prm)       # generation and prompt reading count equally
    } catch { $r.error = $_.Exception.Message }
    finally { Stop-Trial; Start-Sleep -Seconds 2 }     # let VRAM be released before the next trial
    $r.secs = [int]$sw.Elapsed.TotalSeconds
    $trials.Add($r); $cache[$sig] = $r
    Set-Status 'running' $script:phase "Finished: $Label"
    return $r
}

function Format-Trial($t) { if ($t.ok) { "{0}: {1} tok/s writing, {2} tok/s reading, {3} MiB VRAM free" -f $t.label, $t.gen, $t.prompt, $t.freeMiB } else { "{0}: failed ({1})" -f $t.label, $t.error } }

# ---- the sweep -------------------------------------------------------------------

try {
    $maxLayers = if ($Layers -gt 0) { $Layers } else { 48 }
    $script:steps = if ($Quick) { 9 } else { 12 }
    Set-Status 'running' 'baseline' 'Starting...'

    # 1. Baseline = what the dashboard launches today.
    $script:phase = 'baseline'
    $base = Invoke-Trial 'baseline (llama-server auto-fit)' @()
    if (-not $base.ok) { throw "The baseline launch failed, so there is nothing to compare against: $($base.error)" }

    # 2. Offload: most GPU use that is still safe.
    $script:phase = 'offload'
    $offArgs = @()
    if ($IsMoe) {
        # n = layers whose experts stay in RAM. 0 = everything on the GPU. Smaller is faster; find the smallest safe n.
        $mk = { param($n) @('-ngl', '99', '--n-cpu-moe', "$n", '-fit', 'off') }
        $lo = 0; $hi = $maxLayers; $bestN = $null
        while ($lo -lt $hi) {
            $mid = [int][math]::Floor(($lo + $hi) / 2)
            $t = Invoke-Trial "experts of $mid layers in RAM" (& $mk $mid)
            if ($t.safe) { $hi = $mid; $bestN = $mid } else { $lo = $mid + 1 }
        }
        if ($null -eq $bestN -or $bestN -ne $hi) {
            $t = Invoke-Trial "experts of $hi layers in RAM" (& $mk $hi)
            if ($t.safe) { $bestN = $hi } else { $bestN = $null }
        }
        if ($null -ne $bestN) { $offArgs = & $mk $bestN }
    } else {
        # n = layers on the GPU. Larger is faster; find the largest safe n (99 = everything).
        $mk = { param($n) @('-ngl', "$n", '-fit', 'off') }
        $t = Invoke-Trial 'all layers on the GPU' (& $mk 99)
        if ($t.safe) { $offArgs = & $mk 99 }
        else {
            $lo = 0; $hi = $maxLayers + 1; $bestN = $null       # lo is assumed safe; find the largest safe n below hi
            while ($lo -lt $hi - 1) {
                $mid = [int][math]::Floor(($lo + $hi) / 2)
                $t = Invoke-Trial "$mid layers on the GPU" (& $mk $mid)
                if ($t.safe) { $lo = $mid; $bestN = $mid } else { $hi = $mid }
            }
            if ($null -ne $bestN) { $offArgs = & $mk $bestN }
        }
    }
    $pool = @($trials | Where-Object { $_.safe -and $_.label -ne $base.label })
    $current = if ($offArgs.Count) { $trials | Where-Object { $_.safe -and (($_.args -join ' ') -eq ($offArgs -join ' ')) } | Select-Object -First 1 } else { $null }
    if (-not $current -or ($base.safe -and $base.score -gt $current.score)) { $current = $base; $offArgs = @() }

    # 3. Physical batch size: mostly changes prompt-reading speed (and VRAM use).
    $script:phase = 'batch'
    foreach ($ub in 1024, 2048) {
        $t = Invoke-Trial "batch size $ub" ($offArgs + @('-ub', "$ub", '-b', '2048'))
        if ($t.safe -and $t.score -gt $current.score * 1.01) { $current = $t }
    }

    # 4. Threads: only matters when the CPU shares the work.
    $cpuWorks = $IsMoe -or (($current.args -join ' ') -match '-ngl (\d+)' -and [int]$Matches[1] -lt 99) -or ($current -eq $base)
    if ($cpuWorks -and -not $Quick) {
        $script:phase = 'threads'
        $keep = @($current.args | Where-Object { $_ })
        foreach ($th in ($cores, $logical | Select-Object -Unique)) {
            if ($keep -contains '-t') { break }
            $t = Invoke-Trial "$th CPU threads" ($keep + @('-t', "$th"))
            if ($t.safe -and $t.score -gt $current.score * 1.02) { $current = $t }
        }
    }

    # 5. Decide. Only keep a tuned configuration if it is clearly better than doing nothing.
    $script:phase = 'done'
    $win = $current
    $gainGen = if ($base.gen -gt 0) { [math]::Round(($win.gen / $base.gen - 1) * 100) } else { 0 }
    $gainPrompt = if ($base.prompt -gt 0) { [math]::Round(($win.prompt / $base.prompt - 1) * 100) } else { 0 }
    $useful = ($win -ne $base) -and ($win.score -gt $base.score * 1.03)
    $record = @{
        savedAt = (Get-Date).ToString('o'); model = $modelName; ctx = $Ctx; kvQuant = [bool]$KvQuant; hw = $HwSig; marginMiB = $MarginMiB
        baseline = @{ gen = $base.gen; prompt = $base.prompt; freeMiB = $base.freeMiB }
        tuned = @{ gen = $win.gen; prompt = $win.prompt; freeMiB = $win.freeMiB }
        gainGenPct = $gainGen; gainPromptPct = $gainPrompt
        cliArgs = @($(if ($useful) { $win.args } else { @() }))
        applied = $useful
        note = $(if ($useful) { "Tuned settings are faster: $($win.label)." } else { 'No setting beat the default by a meaningful margin, so the default (auto-fit) is kept.' })
        trials = @($trials | ForEach-Object { @{ label = $_.label; ok = $_.ok; safe = $_.safe; gen = $_.gen; prompt = $_.prompt; freeMiB = $_.freeMiB; error = $_.error; args = $_.args } })
    }
    if ($DbFile -and $HwSig -ne $null) {
        $db = Read-Json $DbFile @{}
        $key = "$modelName|$Ctx|$([int][bool]$KvQuant)|$HwSig"
        $db[$key] = $record
        Write-Json $DbFile $db
    }
    Set-Status 'done' 'done' $record.note @{ result = $record }
    exit 0
} catch {
    Set-Status 'error' 'error' $_.Exception.Message
    exit 1
} finally {
    Stop-Trial
}
