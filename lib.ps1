# Shared helpers: dot-sourced by server.ps1 and by the Hugging Face discovery job.

function Read-Json([string]$Path, $Default) {
    if (Test-Path $Path) {
        try { return (Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable) } catch { }
    }
    return $Default
}

function Write-Json([string]$Path, $Object) {
    $tmp = "$Path.tmp"
    ConvertTo-Json -InputObject $Object -Depth 12 | Set-Content $tmp -Encoding utf8
    Move-Item $tmp $Path -Force
}

# ---- Name parsing -----------------------------------------------------------

function Get-QuantInfo([string]$FileName) {
    # Only strip a real .gguf extension: names like "Qwen3.8-27B-UD-IQ4_XS" contain dots of their own.
    $n = $FileName -replace '(?i)\.gguf$', '' -replace '-\d{5}-of-\d{5}$', ''
    $found = [regex]::Matches($n, '(?i)(?<![A-Za-z0-9])((?:UD-)?(?:IQ|Q)\d+(?:_[A-Z0-9]+)*|BF16|F16|F32|(?:MX|NV)FP4(?:_[A-Z0-9]+)*)(?![A-Za-z0-9])')
    if ($found.Count -eq 0) { return @{ label = 'unknown'; bits = 0; stem = $n } }
    $label = $found[$found.Count - 1].Groups[1].Value.ToUpper()
    $bits = 0
    if ($label -match '^(?:UD-)?(?:IQ|Q)(\d+)') { $bits = [int]$Matches[1] }
    elseif ($label -match 'F32') { $bits = 32 }
    elseif ($label -match 'F16') { $bits = 16 }
    elseif ($label -match 'FP4') { $bits = 4 }
    return @{ label = $label; bits = $bits; stem = $n }
}

function Test-IsMoe([string]$Name) {
    return [bool]($Name -match '(?i)(\d+x\d+B|(?<![A-Za-z0-9])A\d+(\.\d+)?B|moe)')
}

function Get-ParamsB([string]$Name) {
    if ($Name -match '(?i)(?<![A-Za-z0-9.])(\d+(?:\.\d+)?)B(?![A-Za-z0-9])') { return [double]$Matches[1] }
    return $null
}

function Get-ActiveB([string]$Name) {
    if ($Name -match '(?i)(?<![A-Za-z0-9])A(\d+(?:\.\d+)?)B(?![A-Za-z0-9])') { return [double]$Matches[1] }
    return $null
}

# Group a Hugging Face file listing into downloadable quant variants (handles sharded GGUFs + mmproj).
function Get-QuantGroups($Entries) {
    $groups = @{}
    $mm = @()
    foreach ($e in $Entries) {
        if ($e.type -ne 'file' -or $e.path -notmatch '(?i)\.gguf$') { continue }
        $leaf = Split-Path $e.path -Leaf
        if ($leaf -match '(?i)mmproj') { $mm += @{ path = $e.path; size = [int64]$e.size }; continue }
        if ($leaf -match '(?i)imatrix|^mtp-') { continue }
        $dir = Split-Path $e.path -Parent
        $q = Get-QuantInfo $leaf
        $label = if ($q.label -eq 'unknown') { $q.stem } else { $q.label }
        $key = "$dir|$label"
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = @{ quant = $label; bits = $q.bits; size = [int64]0; files = @() }
        }
        $groups[$key].size += [int64]$e.size
        $groups[$key].files += $e.path
    }
    $list = foreach ($g in $groups.Values) { $g.files = @($g.files | Sort-Object); $g }
    $pick = $mm | Where-Object { $_.path -match '(?i)f16' } | Select-Object -First 1
    if (-not $pick) { $pick = $mm | Select-Object -First 1 }
    return @{ groups = @($list | Sort-Object { $_.size }); mmproj = $pick }
}

# ---- Hardware fit -----------------------------------------------------------
# Heuristic budgets: reserve VRAM for KV cache / compute buffers, and keep RAM headroom for the OS.

function Get-Fit([double]$SizeGB, [bool]$IsMoe, $Hw) {
    $vram = [double]$Hw.vramGB
    $ram = [double]$Hw.ramGB
    $gpuBudget = [math]::Max(0.0, $vram * 0.95 - 1.2)
    $ramBudget = [math]::Max(0.0, $ram - 8) * 0.8
    if ($vram -gt 0 -and $SizeGB -le $gpuBudget) {
        return @{ tier = 'gpu'; label = 'Fits on GPU'; weight = 6.0 }
    }
    if ($SizeGB -le ($gpuBudget + $ramBudget)) {
        if ($IsMoe -and $vram -gt 0) { return @{ tier = 'moe'; label = 'GPU + RAM (MoE, fast)'; weight = 5.5 } }
        if ($vram -gt 0) { return @{ tier = 'partial'; label = 'Partial offload (slower)'; weight = 2.0 } }
        return @{ tier = 'cpu'; label = 'CPU only (slow)'; weight = 0.5 }
    }
    return @{ tier = 'toobig'; label = 'Too large'; weight = -100.0 }
}

function Get-ModelScore([double]$ParamsB, [bool]$IsMoe, $Fit) {
    $eff = if ($IsMoe) { $ParamsB * 0.7 } else { $ParamsB }
    return $Fit.weight + 1.5 * [math]::Log([math]::Max($eff, 1.0))
}
