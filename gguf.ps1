# GGUF header reader + KV-cache sizing. Dot-sourced by server.ps1 only (Add-Type compiles C#, which is slow).
# Reads just the metadata block at the start of a .gguf file (~30 ms) - never the tensors.

if (-not ('GgufMeta' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class GgufMeta {
    static string ReadStr(BinaryReader r) {
        ulong n = r.ReadUInt64();
        if (n > 16777216UL) throw new InvalidDataException("string too long");
        return Encoding.UTF8.GetString(r.ReadBytes((int)n));
    }
    static int FixedSize(uint t) {
        switch (t) {
            case 0: case 1: case 7: return 1;
            case 2: case 3: return 2;
            case 4: case 5: case 6: return 4;
            case 10: case 11: case 12: return 8;
        }
        return -1;
    }
    static object ReadVal(BinaryReader r, uint t) {
        switch (t) {
            case 0: return (long)r.ReadByte();
            case 1: return (long)r.ReadSByte();
            case 2: return (long)r.ReadUInt16();
            case 3: return (long)r.ReadInt16();
            case 4: return (long)r.ReadUInt32();
            case 5: return (long)r.ReadInt32();
            case 6: return (double)r.ReadSingle();
            case 7: return r.ReadByte() != 0;
            case 8: return ReadStr(r);
            case 10: return (long)r.ReadUInt64();
            case 11: return r.ReadInt64();
            case 12: return r.ReadDouble();
        }
        throw new InvalidDataException("unsupported value type " + t);
    }
    // Scalars are returned as-is; short numeric/bool arrays (per-layer values) as List<object>;
    // long arrays (tokenizer vocab etc.) are skipped without being materialised.
    public static Dictionary<string, object> Read(string path) {
        var d = new Dictionary<string, object>();
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (var r = new BinaryReader(fs)) {
            if (new string(r.ReadChars(4)) != "GGUF") throw new InvalidDataException("not a GGUF file");
            r.ReadUInt32();               // version
            r.ReadUInt64();               // tensor count
            ulong kv = r.ReadUInt64();
            if (kv > 100000UL) throw new InvalidDataException("implausible metadata count");
            for (ulong i = 0; i < kv; i++) {
                string key = ReadStr(r);
                uint t = r.ReadUInt32();
                if (t == 9) {
                    uint et = r.ReadUInt32();
                    ulong n = r.ReadUInt64();
                    int sz = FixedSize(et);
                    if (sz > 0) {
                        if (n <= 256) { var l = new List<object>(); for (ulong j = 0; j < n; j++) l.Add(ReadVal(r, et)); d[key] = l; }
                        else fs.Seek((long)n * sz, SeekOrigin.Current);
                    } else if (et == 8) {
                        for (ulong j = 0; j < n; j++) { ulong len = r.ReadUInt64(); fs.Seek((long)len, SeekOrigin.Current); }
                    } else throw new InvalidDataException("unsupported array type " + et);
                } else d[key] = ReadVal(r, t);
            }
        }
        return d;
    }
}
'@
}

$script:MetaCache = @{}

function Get-ModelMeta([string]$Path) {
    $stamp = (Get-Item -LiteralPath $Path).LastWriteTimeUtc.Ticks
    $key = "$Path|$stamp"
    if ($script:MetaCache.ContainsKey($key)) { return $script:MetaCache[$key] }
    $meta = $null
    try { $meta = [GgufMeta]::Read($Path) } catch { }
    $script:MetaCache[$key] = $meta
    return $meta
}

# ---- Chat-template compatibility -------------------------------------------
# Claude Code sends a `system` message *after* the first user message (its injected "# Environment" block).
# ChatML-style templates such as Qwen's raise "System message must be at the beginning" and every request fails.
# Patch: render that message as an ordinary block instead of raising. Returns $null when no patch is needed.
function Get-PatchedTemplate([string]$ModelPath) {
    $meta = Get-ModelMeta $ModelPath
    if (-not $meta -or -not ($meta['tokenizer.chat_template'] -is [string])) { return $null }
    $tpl = [string]$meta['tokenizer.chat_template']
    $pattern = '(?s)raise_exception\(\s*([''"])System message must be at the beginning\.\1\s*\)'
    if ($tpl -notmatch $pattern) { return $null }
    # `content` is the already-rendered message text in this template family (set just above the check).
    $render = "'<|im_start|>' + message.role + '\n' + content + '<|im_end|>' + '\n'"
    return [regex]::Replace($tpl, $pattern, { param($m) $render })
}

# Writes the patched template (once, keyed by content hash) and returns its path, or $null if not needed.
function Get-TemplatePatchFile([string]$ModelPath, [string]$Dir) {
    $patched = Get-PatchedTemplate $ModelPath
    if (-not $patched) { return $null }
    [void](New-Item -ItemType Directory -Force $Dir)
    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($patched))[0..5] | ForEach-Object { $_.ToString('x2') })
    $file = Join-Path $Dir "chat-template-$hash.jinja"
    if (-not (Test-Path -LiteralPath $file)) { [IO.File]::WriteAllText($file, $patched, [Text.UTF8Encoding]::new($false)) }
    return $file
}

# ---- KV-cache sizing --------------------------------------------------------

function Get-MetaNum($Meta, [string]$Key) {
    if ($Meta.ContainsKey($Key)) { $v = $Meta[$Key]; if ($v -is [System.Collections.IList]) { return $null }; return [double]$v }
    return $null
}

# Per-layer attention geometry -> how KV memory scales with context for this architecture.
#   perTokenBytes  : f16 bytes per token across full-attention layers (grows with context)
#   swaBytesPerCell/swaWindow : sliding-window layers (capped at the window, not the context)
#   fixedBytes     : recurrent/SSM state of hybrid models (constant)
function Get-KvModel($Meta) {
    if (-not $Meta -or -not $Meta.ContainsKey('general.architecture')) { return $null }
    $a = [string]$Meta['general.architecture']
    $L = Get-MetaNum $Meta "$a.block_count"
    if (-not $L) { return $null }
    $nextn = [int](Get-MetaNum $Meta "$a.nextn_predict_layers")
    $L = [int]$L - $nextn                                  # multi-token-prediction layers carry no KV cache
    $emb = Get-MetaNum $Meta "$a.embedding_length"
    $headsV = $Meta["$a.attention.head_count"]; $kvhV = $Meta["$a.attention.head_count_kv"]
    $kLen = Get-MetaNum $Meta "$a.attention.key_length"; $vLen = Get-MetaNum $Meta "$a.attention.value_length"
    $kLenS = Get-MetaNum $Meta "$a.attention.key_length_swa"; $vLenS = Get-MetaNum $Meta "$a.attention.value_length_swa"
    $window = Get-MetaNum $Meta "$a.attention.sliding_window"
    $pattern = $Meta["$a.attention.sliding_window_pattern"]
    $interval = Get-MetaNum $Meta "$a.full_attention_interval"
    $per = 0.0; $swaCell = 0.0; $rec = 0
    $recLayers = 0
    for ($i = 0; $i -lt $L; $i++) {
        $h = if ($headsV -is [System.Collections.IList]) { [double]$headsV[$i] } else { [double]$headsV }
        $kvh = if ($kvhV -is [System.Collections.IList]) { [double]$kvhV[$i] } elseif ($null -ne $kvhV) { [double]$kvhV } else { $h }
        $kl = if ($kLen) { $kLen } elseif ($emb -and $h) { $emb / $h } else { 128 }
        $vl = if ($vLen) { $vLen } else { $kl }
        if ($interval -and (($i + 1) % [int]$interval) -ne 0) { $recLayers++; continue }   # linear-attention layer: no growing KV
        if ($kvh -le 0) { continue }
        $isSwa = $window -and ($pattern -is [System.Collections.IList]) -and [bool]$pattern[$i]
        if ($isSwa) {
            $ks = if ($kLenS) { $kLenS } else { $kl }; $vs = if ($vLenS) { $vLenS } else { $vl }
            $swaCell += ($ks + $vs) * $kvh * 2
        } else { $per += ($kl + $vl) * $kvh * 2 }
    }
    $fixed = 0.0
    $inner = Get-MetaNum $Meta "$a.ssm.inner_size"; $state = Get-MetaNum $Meta "$a.ssm.state_size"
    if ($recLayers -and $inner -and $state) {
        $grp = [double](Get-MetaNum $Meta "$a.ssm.group_count"); $conv = [double](Get-MetaNum $Meta "$a.ssm.conv_kernel")
        $fixed = $recLayers * (($inner * $state * 4) + (($conv - 1) * ($inner + 2 * $grp * $state) * 4))
    }
    $experts = Get-MetaNum $Meta "$a.expert_count"
    return @{
        arch = $a; layers = $L; perTokenBytes = $per; swaBytesPerCell = $swaCell; swaWindow = [double]($window ?? 0)
        fixedBytes = $fixed; maxCtx = [int](Get-MetaNum $Meta "$a.context_length"); isMoe = [bool]($experts -and $experts -gt 1)
    }
}

function Get-KvBytes($Kv, [int]$Ctx, [bool]$Q8) {
    $cells = if ($Kv.swaWindow -gt 0) { [math]::Min($Ctx, $Kv.swaWindow + 768) } else { 0 }
    $f16 = $Kv.perTokenBytes * $Ctx + $Kv.swaBytesPerCell * $cells
    $kv = if ($Q8) { $f16 * 0.53125 } else { $f16 }       # q8_0 = 34 bytes per 32 values vs 64 for f16
    return $kv + $Kv.fixedBytes
}

# Which context sizes this machine can hold for a model, and how fast it will be.
# "Feasible" = the model weights + KV cache fit in VRAM plus usable system RAM (llama-server's --fit spreads them).
# Speed: fully on GPU, or MoE experts in RAM, is fast; a dense model spilling into RAM slows down roughly in
# proportion to the fraction that no longer fits (measured: ~3x slower at 40% spilled).
function Get-CtxPlan([string]$Path, [double]$WeightsGB, $Hw, [bool]$IsMoeName) {
    $meta = Get-ModelMeta $Path
    $kv = Get-KvModel $meta
    $isMoe = if ($kv) { $kv.isMoe } else { $IsMoeName }
    $trained = if ($kv -and $kv.maxCtx -gt 0) { $kv.maxCtx } else { 32768 }
    $vram = [double]$Hw.vramGB
    $gpuAvail = if ($null -ne $Hw.gpuAvailGB) { [double]$Hw.gpuAvailGB } else { [math]::Max(0.0, $vram - 1.3) }
    $ramBudget = [math]::Max(0.0, [double]$Hw.ramGB - 8) * 0.8
    $overhead = 1.0                                         # compute buffers
    $sizes = @(16384, 32768, 65536, 131072, 262144) | Where-Object { $_ -le $trained }
    if ($trained -lt 262144 -and $trained -notin $sizes -and $trained -ge 16384) { $sizes = @($sizes) + $trained }
    if (-not $sizes) { $sizes = @($trained) }

    $evaluate = {
        param([double]$KvGB, [bool]$Q8)
        $need = $WeightsGB + $KvGB + $overhead
        if ($vram -gt 0 -and $need -le $gpuAvail) { return @{ tier = 'gpu'; speed = 'fast'; offload = 0 } }
        if ($vram -gt 0 -and $isMoe -and ($WeightsGB * 0.3 + $KvGB + $overhead) -le $gpuAvail -and $need -le ($gpuAvail + $ramBudget)) {
            return @{ tier = 'moe'; speed = 'fast'; offload = 0 }
        }
        if ($need -le ($gpuAvail + $ramBudget)) {
            $spill = [math]::Round(($need - $gpuAvail) / $need * 100)
            $speed = if ($vram -le 0) { 'slow' } elseif ($spill -le 12) { 'fast' } elseif ($spill -le 30) { 'moderate' } else { 'slow' }
            return @{ tier = $(if ($vram -gt 0) { 'partial' } else { 'cpu' }); speed = $speed; offload = $spill }
        }
        return @{ tier = 'toobig'; speed = 'none'; offload = 100 }
    }

    $options = @()
    foreach ($c in $sizes) {
        $f16GB = if ($kv) { (Get-KvBytes $kv $c $false) / 1GB } else { $WeightsGB * 0.02 * ($c / 4096) / 8 }
        $q8GB = if ($kv) { (Get-KvBytes $kv $c $true) / 1GB } else { $f16GB * 0.53125 }
        $e16 = & $evaluate $f16GB $false
        # Compress the cache (q8, near-lossless) whenever full precision would not stay on the GPU.
        $useQ8 = ($e16.tier -notin 'gpu', 'moe')
        $e = if ($useQ8) { & $evaluate $q8GB $true } else { $e16 }
        $options += @{
            ctx = [int]$c; kvQuant = $useQ8; kvGB = [math]::Round($(if ($useQ8) { $q8GB } else { $f16GB }), 2)
            kvF16GB = [math]::Round($f16GB, 2); kvQ8GB = [math]::Round($q8GB, 2); tier = $e.tier; speed = $e.speed; offloadPct = $e.offload; feasible = ($e.tier -ne 'toobig')
        }
    }
    $feasible = @($options | Where-Object { $_.feasible })
    $rec = if ($feasible.Count) { $feasible | Sort-Object { $_.ctx } -Descending | Select-Object -First 1 } else { $options | Sort-Object { $_.ctx } | Select-Object -First 1 }
    return @{ options = $options; recommended = $rec; trainedCtx = $trained; estimated = [bool]$kv; isMoe = $isMoe; perTokenKB = $(if ($kv) { [math]::Round($kv.perTokenBytes / 1024, 1) } else { $null }) }
}
