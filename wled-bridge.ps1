# wled-bridge.ps1 - stdio MCP server ("wled") that drives the room lights through WLED's JSON API.
# Windows PowerShell 5.1, no installs. Scenes/flashes live in lights.json (next to this file).
# Only the light STATE is changed; WLED's LED preferences, Wi-Fi and current limiter are never touched.
$ErrorActionPreference = 'Stop'
$script:Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogFile = Join-Path $script:Root 'wled-bridge.log'
$script:CfgFile = Join-Path $script:Root 'lights.json'
$script:Version = '1.0.0'
[System.Net.ServicePointManager]::Expect100Continue = $false
[System.Net.WebRequest]::DefaultWebProxy = $null          # LAN device: never go through a proxy

# ---------------------------------------------------------------- logging (rotating, ~512 KB x 3)
function Write-Log([string]$Level, [string]$Msg) {
    try {
        $f = $script:LogFile
        if ((Test-Path $f) -and ((Get-Item $f).Length -gt 524288)) {
            if (Test-Path "$f.3") { Remove-Item "$f.3" -Force }
            if (Test-Path "$f.2") { Move-Item "$f.2" "$f.3" -Force }
            if (Test-Path "$f.1") { Move-Item "$f.1" "$f.2" -Force }
            Move-Item $f "$f.1" -Force
        }
        $line = '{0} {1} {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Msg
        [System.IO.File]::AppendAllText($f, $line + "`r`n")
    } catch { }
}

# ---------------------------------------------------------------- stdin pump (reader thread + monotonic clock)
if (-not ([System.Management.Automation.PSTypeName]'WledPump').Type) {
Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
public class WledMsg { public string Line; public long ArrivedMs; }
public static class WledPump {
    static BlockingCollection<WledMsg> q = new BlockingCollection<WledMsg>();
    static Stopwatch sw = Stopwatch.StartNew();
    public static volatile bool Eof;
    public static long NowMs { get { return sw.ElapsedMilliseconds; } }
    public static int Count { get { return q.Count; } }
    public static void Start() {
        Thread t = new Thread(delegate() {
            StreamReader r = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
            string l;
            while ((l = r.ReadLine()) != null) {
                if (l.Trim().Length > 0) { WledMsg m = new WledMsg(); m.Line = l; m.ArrivedMs = sw.ElapsedMilliseconds; q.Add(m); }
            }
            Eof = true;
        });
        t.IsBackground = true;
        t.Start();
    }
    public static WledMsg Take(int ms) { WledMsg m; if (q.TryTake(out m, ms)) return m; return null; }
}
"@
}

# ---------------------------------------------------------------- small helpers
function Fail([string]$Reason, $Extra) { $script:FailExtra = $Extra; throw ('ERR:' + $Reason) }

function ConvertTo-Hash($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }
        return $h
    }
    if ($o -is [System.Array]) {
        $a = New-Object System.Collections.ArrayList
        foreach ($x in $o) { [void]$a.Add((ConvertTo-Hash $x)) }
        return , $a.ToArray()
    }
    return $o
}

function Norm([string]$s) { return ((($s.ToLower()) -replace '[''\u2019]', '') -replace '[^a-z0-9]+', ' ').Trim() }

function Get-Val($h, [string]$k, $def) {
    if (($h -is [System.Collections.IDictionary]) -and $h.Contains($k) -and ($null -ne $h[$k])) { return $h[$k] }
    return $def
}

function Merge-Spec($a, $b) {
    $m = [ordered]@{}
    if ($a -is [System.Collections.IDictionary]) { foreach ($k in $a.Keys) { $m[$k] = $a[$k] } }
    if ($b -is [System.Collections.IDictionary]) { foreach ($k in $b.Keys) { $m[$k] = $b[$k] } }
    return $m
}

function Clamp([double]$v, [double]$lo, [double]$hi) { return [Math]::Max($lo, [Math]::Min($hi, $v)) }

function Send-Json($obj) {
    $s = ConvertTo-Json -InputObject $obj -Depth 12 -Compress
    $script:Out.WriteLine($s)
}

# ---------------------------------------------------------------- colours
$script:ColorNames = @{
    'red' = '#FF0000'; 'orange' = '#FF6A00'; 'amber' = '#FF8A1E'; 'yellow' = '#FFD800'; 'gold' = '#FFC832'
    'green' = '#00FF00'; 'lime' = '#80FF00'; 'teal' = '#00A08C'; 'cyan' = '#00FFFF'; 'blue' = '#0000FF'
    'ice' = '#A0E8FF'; 'ice blue' = '#A0E8FF'; 'icy blue' = '#A0E8FF'; 'purple' = '#7A18C8'; 'violet' = '#9040FF'
    'magenta' = '#FF00D0'; 'pink' = '#FF5FA0'; 'white' = '#FFFFFF'; 'warm white' = '#FFB466'; 'black' = '#000000'
    'crimson' = '#C0102A'; 'sickly green' = '#7CFF2E'
}

function Resolve-Color($v, [bool]$Strict) {
    $s = ([string]$v).Trim()
    $n = Norm $s
    if ($script:ColorNames.ContainsKey($n)) { $s = $script:ColorNames[$n] }
    if ($s -match '^#?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})?$') {
        $c = @([Convert]::ToInt32($Matches[1], 16), [Convert]::ToInt32($Matches[2], 16), [Convert]::ToInt32($Matches[3], 16))
        if ($Matches[4]) { $c += [Convert]::ToInt32($Matches[4], 16) }
        return , ([int[]]$c)
    }
    if ($Strict) { Fail "Unknown colour '$v'. Use #RRGGBB, #RRGGBBWW or a name." @{ known = @($script:ColorNames.Keys | Sort-Object) } }
    Write-Log 'WARN' "bad colour '$v' in lights.json, using black"
    return , ([int[]]@(0, 0, 0))
}

function Color-Hex($c) {
    if ($null -eq $c) { return $null }
    $a = @($c)
    $h = '#{0:X2}{1:X2}{2:X2}' -f [int]$a[0], [int]$a[1], [int]$a[2]
    if ($a.Count -gt 3 -and [int]$a[3] -gt 0) { $h += ('{0:X2}' -f [int]$a[3]) }
    return $h
}

# ---------------------------------------------------------------- config (lights.json, reloaded when it changes)
$script:Cfg = $null; $script:CfgStamp = $null; $script:CfgError = $null
$script:SceneIdx = @{}; $script:FlashIdx = @{}

function Build-Index($section) {
    $idx = @{}
    foreach ($k in $section.Keys) {
        $idx[(Norm $k)] = $k
        $al = Get-Val $section[$k] 'aliases' @()
        foreach ($a in @($al)) { $idx[(Norm ([string]$a))] = $k }
    }
    return $idx
}

function Load-Config {
    try {
        $stamp = (Get-Item $script:CfgFile).LastWriteTimeUtc.Ticks
        if ($script:Cfg -and $stamp -eq $script:CfgStamp) { return }
        $raw = [System.IO.File]::ReadAllText($script:CfgFile)
        $c = ConvertTo-Hash (ConvertFrom-Json $raw)
        foreach ($need in 'wled', 'scenes', 'flashes') { if (-not $c.Contains($need)) { throw "missing '$need'" } }
        $script:SceneIdx = Build-Index $c['scenes']
        $script:FlashIdx = Build-Index $c['flashes']
        $script:Cfg = $c; $script:CfgStamp = $stamp; $script:CfgError = $null
        Write-Log 'INFO' 'lights.json loaded'
    } catch {
        $script:CfgError = "lights.json problem: $($_.Exception.Message)"
        $script:CfgStamp = $null
        Write-Log 'ERROR' $script:CfgError
    }
}

function Cfg-Ip { return [string]$script:Cfg['wled']['ip'] }

# ---------------------------------------------------------------- WLED access
$script:DownUntil = 0; $script:SegOk = $false
$script:FxMap = $null; $script:FxNames = @(); $script:PalMap = $null
$script:Base = @{ window = $null; poster = $null }
$script:SceneBy = @{ window = $null; poster = $null }
$script:PowerOn = $true; $script:MasterBri = 128
$script:Job = $null
$script:SegId = @{ window = 0; poster = 1 }

function Wled-Req([string]$Method, [string]$Path, $Body) {
    $ip = Cfg-Ip
    if ([WledPump]::NowMs -lt $script:DownUntil) { Fail "Lights controller not reachable at $ip" }
    $secs = [int][Math]::Max(1, [Math]::Ceiling([double](Get-Val $script:Cfg['wled'] 'timeout_ms' 1000) / 1000))
    try {
        $uri = "http://$ip$Path"
        if ($Method -eq 'GET') { return (Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $secs) }
        $json = ConvertTo-Json -InputObject $Body -Depth 12 -Compress
        return (Invoke-RestMethod -Uri $uri -Method Post -Body $json -ContentType 'application/json' -TimeoutSec $secs)
    } catch {
        Write-Log 'WARN' "WLED $Method $Path failed: $($_.Exception.Message)"
        $script:DownUntil = [WledPump]::NowMs + 2000
        $script:SegOk = $false
        Fail "Lights controller not reachable at $ip"
    }
}

function Send-State($Body) {
    $Body['v'] = $false
    [void](Wled-Req 'POST' '/json/state' $Body)
}

function Make-Map($names) {
    $m = @{}
    for ($i = 0; $i -lt $names.Count; $i++) {
        $k = Norm (([string]$names[$i]).Split('@')[0])
        if ($k -and -not $m.ContainsKey($k)) { $m[$k] = $i }
    }
    return $m
}

function Ensure-Catalog {
    if ($script:FxMap -and $script:PalMap) { return }
    $fx = @(Wled-Req 'GET' '/json/eff' $null)
    $pal = @(Wled-Req 'GET' '/json/pal' $null)
    $script:FxNames = @($fx | ForEach-Object { ([string]$_).Split('@')[0] })
    $script:FxMap = Make-Map $fx
    $script:PalMap = Make-Map $pal
    Write-Log 'INFO' "catalog: $($fx.Count) effects, $($pal.Count) palettes"
}

function Resolve-Effect($v, [bool]$Strict) {
    foreach ($cand in @($v)) {
        $k = Norm ([string]$cand)
        if ($script:FxMap.ContainsKey($k)) { return [int]$script:FxMap[$k] }
    }
    if ($Strict) { Fail "Unknown effect '$v'." @{ known = $script:FxNames } }
    Write-Log 'WARN' ("effect not found, using Solid: " + (@($v) -join ' / '))
    return 0
}

function Resolve-Palette($v) {
    $k = Norm ([string]$v)
    if ($script:PalMap.ContainsKey($k)) { return [int]$script:PalMap[$k] }
    Write-Log 'WARN' "palette '$v' not found, using Default"
    return 0
}

function Copy-Cols($cols) {
    $out = New-Object System.Collections.ArrayList
    foreach ($c in @($cols)) {
        $a = New-Object System.Collections.ArrayList
        foreach ($n in @($c)) { [void]$a.Add([int]$n) }
        [void]$out.Add($a.ToArray())
    }
    return , $out.ToArray()
}

function Seg-FromState($s) {
    $bri = 255; if ($null -ne $s.bri) { $bri = [int]$s.bri }
    return @{ col = (Copy-Cols $s.col); fx = [int]$s.fx; sx = [int]$s.sx; ix = [int]$s.ix; pal = [int]$s.pal; bri = $bri }
}

function Copy-Seg($s) {
    return @{ col = (Copy-Cols $s.col); fx = $s.fx; sx = $s.sx; ix = $s.ix; pal = $s.pal; bri = $s.bri }
}

function Seg-Out([int]$Id, $s) {
    return @{ id = $Id; on = $true; frz = $false; bri = $s.bri; col = $s.col; fx = $s.fx; sx = $s.sx; ix = $s.ix; pal = $s.pal }
}

function Active-Segs($st) { return @(@($st.seg) | Where-Object { $null -ne $_ -and [int]$_.stop -gt 0 }) }

function Ensure-Ready {
    Load-Config
    if ($script:CfgError -and -not $script:Cfg) { Fail $script:CfgError }
    if ($script:SegOk) { return }
    $st = Wled-Req 'GET' '/json/state' $null
    Ensure-Catalog
    $segs = Active-Segs $st
    $good = ($segs.Count -eq 2) -and ([int]$segs[0].start -eq 0) -and ([int]$segs[0].stop -eq 150) -and ([int]$segs[1].start -eq 150) -and ([int]$segs[1].stop -eq 300)
    if (-not $good) {
        Write-Log 'INFO' "creating the two wall segments (found $($segs.Count) active)"
        $list = @(@{ id = 0; start = 0; stop = 150; n = 'Window wall' }, @{ id = 1; start = 150; stop = 300; n = 'Poster wall' })
        $all = @($st.seg)
        for ($i = 2; $i -lt $all.Count; $i++) { if ([int]$all[$i].stop -gt 0) { $list += @{ id = $i; stop = 0 } } }
        Send-State @{ seg = $list }
        $st = Wled-Req 'GET' '/json/state' $null
        $segs = Active-Segs $st
    }
    if ($segs.Count -ge 2) {
        if ($null -eq $script:Base.window) { $script:Base.window = Seg-FromState $segs[0] }
        if ($null -eq $script:Base.poster) { $script:Base.poster = Seg-FromState $segs[1] }
    }
    $script:PowerOn = [bool]$st.on
    $script:MasterBri = [int]$st.bri
    $script:SegOk = $true
}

# ---------------------------------------------------------------- building segments from specs
function Level-To-Bri($level, [string]$Side) {
    $gain = [double](Get-Val (Get-Val $script:Cfg 'wall_gain' @{}) $Side 1.0)
    $b = [Math]::Round((Clamp ([double]$level) 0 100) * 2.55 * $gain)
    if ([double]$level -gt 0 -and $b -lt 1) { $b = 1 }
    return [int](Clamp $b 0 255)
}

function Build-Seg($Spec, [string]$Side, [bool]$Strict) {
    $m = Merge-Spec (Get-Val $script:Cfg 'defaults' @{}) $Spec
    $c1 = Resolve-Color (Get-Val $m 'color' '#000000') $Strict
    $c2 = Resolve-Color (Get-Val $m 'color2' '#000000') $Strict
    $c3 = Resolve-Color (Get-Val $m 'color3' '#000000') $Strict
    return @{
        col = @($c1, $c2, $c3)
        fx  = (Resolve-Effect (Get-Val $m 'effect' 'Solid') $Strict)
        sx  = [int](Clamp ([double](Get-Val $m 'speed' 128)) 0 255)
        ix  = [int](Clamp ([double](Get-Val $m 'intensity' 128)) 0 255)
        pal = (Resolve-Palette (Get-Val $m 'palette' 'Default'))
        bri = (Level-To-Bri (Get-Val $m 'level' 100) $Side)
    }
}

function Get-Sides($v) {
    $n = Norm ([string](Get-Val @{ s = $v } 's' 'both'))
    switch ($n) {
        { $_ -in 'both', 'all', '' } { return , @('window', 'poster') }
        'window' { return , @('window') }
        'poster' { return , @('poster') }
    }
    Fail "Unknown side '$v'." @{ known = @('both', 'window', 'poster') }
}

function Find-Name($Idx, $Section, [string]$Given, [string]$Kind) {
    $k = Norm $Given
    if ($Idx.ContainsKey($k)) { return [string]$Idx[$k] }
    Fail "Unknown $Kind '$Given'." @{ known = @($Section.Keys) }
}

function Restore-Body($Sides, [int]$Ms) {
    $segs = @()
    foreach ($s in $Sides) { $segs += , (Seg-Out $script:SegId[$s] $script:Base[$s]) }
    return @{ tt = [int][Math]::Round($Ms / 100.0); seg = $segs }
}

# ---------------------------------------------------------------- timed animations (flash / sweep), one at a time
function Step-Anim {
    $j = $script:Job
    if (-not $j) { return }
    $el = [WledPump]::NowMs - $j.Start
    try {
        while ($j.Index -lt $j.Steps.Count -and $j.Steps[$j.Index].At -le $el) {
            $st = $j.Steps[$j.Index]; $j.Index++
            Send-State $st.Body
        }
    } catch {
        Write-Log 'WARN' "animation '$($j.Name)' aborted: $($_.Exception.Message)"
        $script:Job = $null; return
    }
    if ($j.Index -ge $j.Steps.Count) { $script:Job = $null }
}

function Begin-Anim([string]$Name, [string]$Kind, $Sides, $Steps, [bool]$Gentle) {
    $old = $script:Job
    $replaced = $null
    if ($old) {
        $replaced = $old.Name
        $leftover = @($old.Sides | Where-Object { $Sides -notcontains $_ })
        $script:Job = $null
        if ($leftover.Count -gt 0) { try { Send-State (Restore-Body $leftover 100) } catch { } }
    }
    $j = @{ Name = $Name; Kind = $Kind; Sides = $Sides; Steps = $Steps; Index = 0; Start = [WledPump]::NowMs; Gentle = $Gentle
            End = [WledPump]::NowMs + $Steps[$Steps.Count - 1].At }
    $script:Job = $j
    try {
        $j.Index = 1
        Send-State $Steps[0].Body          # first step goes out now, so failures are reported to the caller
    } catch { $script:Job = $null; throw }
    return $replaced
}

function Gentle-Steps($Sides, $ColorSpec, [int]$Dur, [int]$RestoreMs) {
    $segs = @()
    foreach ($s in $Sides) {
        $seg = Build-Seg @{ color = $ColorSpec; effect = 'Solid'; level = 55 } $s $false
        $segs += , (Seg-Out $script:SegId[$s] $seg)
    }
    $steps = New-Object System.Collections.ArrayList
    [void]$steps.Add(@{ At = 0; Body = @{ tt = 3; seg = $segs } })
    [void]$steps.Add(@{ At = $Dur; Body = (Restore-Body $Sides ([Math]::Max(600, $RestoreMs))) })
    return , $steps
}

function Flash-Steps($Def, $Sides, [int]$Dur, [int]$RestoreMs) {
    $steps = New-Object System.Collections.ArrayList
    foreach ($step in @($Def['steps'])) {
        $at = [int][Math]::Round([double]$step['at'] * $Dur)
        $segs = @(); $tt = 0
        foreach ($s in $Sides) {
            $v = $null
            if ($step.Contains($s)) { $v = $step[$s] } elseif ($step.Contains('both')) { $v = $step['both'] }
            if ($null -eq $v) { continue }
            if ($v -is [string]) {
                if ($v -eq 'base') { $segs += , (Seg-Out $script:SegId[$s] $script:Base[$s]) }
                continue
            }
            $tt = [Math]::Max($tt, [int]((Get-Val $v 'tt_ms' 100) / 100))
            if ($v.Contains('base_scale')) {
                $seg = Copy-Seg $script:Base[$s]
                $seg.bri = [int][Math]::Max(1, [Math]::Round([double]$seg.bri * [double]$v['base_scale']))
            } else {
                $seg = Build-Seg $v $s $false
            }
            $segs += , (Seg-Out $script:SegId[$s] $seg)
        }
        if ($segs.Count -gt 0) { [void]$steps.Add(@{ At = $at; Body = @{ tt = $tt; seg = $segs } }) }
    }
    [void]$steps.Add(@{ At = $Dur; Body = (Restore-Body $Sides $RestoreMs) })
    return , $steps
}

function Sweep-Steps([string]$From, $Rgb, [int]$Dur) {
    $head = 8; $tail = 16; $last = 299 + $head + $tail
    $first = $From; $second = 'poster'; if ($From -eq 'poster') { $second = 'window' }
    $dim = @([int]($Rgb[0] * 0.35), [int]($Rgb[1] * 0.35), [int]($Rgb[2] * 0.35))
    $steps = New-Object System.Collections.ArrayList
    $setup = @()
    foreach ($s in 'window', 'poster') { $setup += , @{ id = $script:SegId[$s]; on = $true; frz = $true; fx = 0; bri = 255; col = @(, @(0, 0, 0)) } }
    [void]$steps.Add(@{ At = 0; Body = @{ tt = 0; seg = $setup } })
    $frames = [int][Math]::Max(4, [Math]::Floor($Dur / 80))
    for ($f = 0; $f -lt $frames; $f++) {
        $p = [int][Math]::Round($f * $last / ($frames - 1))
        $segs = @()
        foreach ($side in $first, $second) {
            $i = New-Object System.Collections.ArrayList
            [void]$i.Add(0); [void]$i.Add(150); [void]$i.Add(@(0, 0, 0))
            foreach ($band in @(@{ lo = $p - $head - $tail + 1; hi = $p - $head; c = $dim }, @{ lo = $p - $head + 1; hi = $p; c = $Rgb[0..2] })) {
                if ($side -eq $first) { $a = [Math]::Max($band.lo, 0); $b = [Math]::Min($band.hi, 149) }
                else { $a = [Math]::Max(299 - $band.hi, 0); $b = [Math]::Min(299 - $band.lo, 149) }
                if ($a -le $b) { [void]$i.Add($a); [void]$i.Add($b + 1); [void]$i.Add([int[]]$band.c) }
            }
            $segs += , @{ id = $script:SegId[$side]; i = $i.ToArray() }
        }
        [void]$steps.Add(@{ At = 60 + $f * 80; Body = @{ tt = 0; seg = $segs } })
    }
    [void]$steps.Add(@{ At = 60 + $frames * 80 + 40; Body = (Restore-Body @('window', 'poster') 400) })
    return , $steps
}

# ---------------------------------------------------------------- tools
function Tool-ListTargets($a) {
    Load-Config
    if ($script:CfgError -and -not $script:Cfg) { Fail $script:CfgError }
    $scenes = @(); foreach ($k in $script:Cfg['scenes'].Keys) { $scenes += , ([ordered]@{ name = $k; aliases = @(Get-Val $script:Cfg['scenes'][$k] 'aliases' @()); description = (Get-Val $script:Cfg['scenes'][$k] 'description' '') }) }
    $flashes = @(); foreach ($k in $script:Cfg['flashes'].Keys) { $d = $script:Cfg['flashes'][$k]; $flashes += , ([ordered]@{ name = $k; aliases = @(Get-Val $d 'aliases' @()); description = (Get-Val $d 'description' ''); default_ms = (Get-Val $d 'default_ms' 1000) }) }
    $fx = @(); $note = $null
    try { Ensure-Catalog; $fx = $script:FxNames } catch { $note = "effects list unavailable: Lights controller not reachable at $(Cfg-Ip)" }
    $r = [ordered]@{ scenes = $scenes; flashes = $flashes; sides = @('both', 'window', 'poster'); effects = $fx }
    if ($note) { $r['effects_note'] = $note }
    return $r
}

function Tool-Status($a) {
    Ensure-Ready
    $st = Wled-Req 'GET' '/json/state' $null
    $script:PowerOn = [bool]$st.on
    $script:MasterBri = [int]$st.bri
    $segs = Active-Segs $st
    $walls = [ordered]@{}
    $names = 'window', 'poster'
    for ($n = 0; $n -lt 2 -and $n -lt $segs.Count; $n++) {
        $s = $segs[$n]; $fxName = $null; $c0 = @($s.col)[0]
        if ($script:FxNames.Count -gt [int]$s.fx) { $fxName = $script:FxNames[[int]$s.fx] }
        $walls[$names[$n]] = [ordered]@{ effect = $fxName; color = (Color-Hex $c0); speed = [int]$s.sx; intensity = [int]$s.ix; level = [int][Math]::Round([double]$s.bri / 2.55) }
    }
    $sw = $script:SceneBy.window; $sp = $script:SceneBy.poster
    $scene = $null; if ($sw -eq $sp) { $scene = $sw } else { $scene = 'mixed' }
    $flash = $null
    if ($script:Job) { $flash = [ordered]@{ name = $script:Job.Name; kind = $script:Job.Kind; sides = $script:Job.Sides; gentle = $script:Job.Gentle; remaining_ms = [int][Math]::Max(0, $script:Job.End - [WledPump]::NowMs) } }
    return [ordered]@{ reachable = $true; ip = (Cfg-Ip); on = [bool]$st.on; brightness = [int][Math]::Round([double]$st.bri / 2.55); scene = $scene; scenes = [ordered]@{ window = $sw; poster = $sp }; walls = $walls; flash = $flash }
}

function Tool-SetScene($a) {
    if (-not $a.Contains('name')) { Fail "Missing input 'name'." }
    Load-Config
    if ($script:CfgError -and -not $script:Cfg) { Fail $script:CfgError }
    $key = Find-Name $script:SceneIdx $script:Cfg['scenes'] ([string]$a['name']) 'scene'
    $sc = $script:Cfg['scenes'][$key]
    Ensure-Ready
    if ((Get-Val $sc 'power' $true) -eq $false) {
        $script:Job = $null
        Send-State @{ on = $false; tt = 3 }
        $script:PowerOn = $false
        return [ordered]@{ scene = $key; power = 'off'; note = 'base scene kept; power on restores it' }
    }
    $sides = Get-Sides (Get-Val $a 'side' 'both')
    $segs = @()
    foreach ($s in $sides) {
        $spec = Merge-Spec (Get-Val $sc 'all' @{}) (Get-Val $sc $s @{})
        $script:Base[$s] = Build-Seg $spec $s $false
        $script:SceneBy[$s] = $key
        $segs += , (Seg-Out $script:SegId[$s] $script:Base[$s])
    }
    $script:Job = $null
    Send-State @{ on = $true; tt = [int]((Get-Val $script:Cfg 'scene_transition_ms' 600) / 100); seg = $segs }
    $script:PowerOn = $true
    return [ordered]@{ scene = $key; side = ($sides -join '+') }
}

function Tool-SetLight($a) {
    if (-not $a.Contains('color')) { Fail "Missing input 'color'." }
    Ensure-Ready
    $sides = Get-Sides (Get-Val $a 'side' 'both')
    $spec = @{ color = $a['color']; effect = (Get-Val $a 'effect' 'Solid') }
    if ($a.Contains('speed')) { $spec['speed'] = $a['speed'] }
    if ($a.Contains('intensity')) { $spec['intensity'] = $a['intensity'] }
    if ($a.Contains('brightness')) { $spec['level'] = $a['brightness'] }
    [void](Resolve-Effect $spec['effect'] $true)       # strict check up front
    $segs = @()
    foreach ($s in $sides) {
        $script:Base[$s] = Build-Seg $spec $s $true
        $script:SceneBy[$s] = 'custom'
        $segs += , (Seg-Out $script:SegId[$s] $script:Base[$s])
    }
    $script:Job = $null
    Send-State @{ on = $true; tt = 3; seg = $segs }
    $script:PowerOn = $true
    return [ordered]@{ side = ($sides -join '+'); color = (Color-Hex $script:Base[$sides[0]].col[0]); effect = (Get-Val $spec 'effect' 'Solid') }
}

$script:LastFlash = @{ Key = ''; At = -10000 }

function Tool-Flash($a) {
    if (-not $a.Contains('name')) { Fail "Missing input 'name'." }
    Load-Config
    if ($script:CfgError -and -not $script:Cfg) { Fail $script:CfgError }
    $key = Find-Name $script:FlashIdx $script:Cfg['flashes'] ([string]$a['name']) 'flash'
    $def = $script:Cfg['flashes'][$key]
    $sides = Get-Sides (Get-Val $a 'side' 'both')
    $tag = $key + '|' + ($sides -join '+')
    $now = [WledPump]::NowMs
    if ($script:LastFlash.Key -eq $tag -and ($now - $script:LastFlash.At) -lt 300) { Fail "dropped: repeat of flash '$key' within 0.3 s" }
    Ensure-Ready
    if (-not $script:PowerOn) { Fail 'Lights are off: call power(on) first' }
    $gentle = [bool](Get-Val $a 'gentle' $false)
    $dur = [int](Clamp ([double](Get-Val $a 'duration_ms' (Get-Val $def 'default_ms' 1000))) 200 10000)
    $rest = [int](Get-Val $def 'restore_ms' 400)
    if ($gentle) { $steps = Gentle-Steps $sides (Get-Val $def 'color' '#FFFFFF') $dur $rest }
    else { $steps = Flash-Steps $def $sides $dur $rest }
    $replaced = Begin-Anim $key 'flash' $sides $steps $gentle
    $script:LastFlash = @{ Key = $tag; At = $now }
    return [ordered]@{ flash = $key; side = ($sides -join '+'); duration_ms = $dur; gentle = $gentle; replaced = $replaced }
}

function Tool-Sweep($a) {
    foreach ($k in 'color', 'from') { if (-not $a.Contains($k)) { Fail "Missing input '$k'." } }
    $from = Norm ([string]$a['from'])
    if ($from -ne 'window' -and $from -ne 'poster') { Fail "Unknown 'from' value '$($a['from'])'." @{ known = @('window', 'poster') } }
    $rgb = Resolve-Color $a['color'] $true
    Ensure-Ready
    if (-not $script:PowerOn) { Fail 'Lights are off: call power(on) first' }
    $gentle = [bool](Get-Val $a 'gentle' $false)
    $dur = [int](Clamp ([double](Get-Val $a 'duration_ms' 1200)) 300 10000)
    $both = @('window', 'poster')
    if ($gentle) { $steps = Gentle-Steps $both $a['color'] $dur 600 } else { $steps = Sweep-Steps $from $rgb $dur }
    $replaced = Begin-Anim ('sweep from ' + $from) 'sweep' $both $steps $gentle
    return [ordered]@{ from = $from; to = $(if ($from -eq 'window') { 'poster' } else { 'window' }); duration_ms = $dur; gentle = $gentle; replaced = $replaced }
}

function Tool-Power($a) {
    if (-not $a.Contains('on')) { Fail "Missing input 'on' (true/false)." }
    Ensure-Ready
    $on = [bool]$a['on']
    $script:Job = $null
    Send-State @{ on = $on; tt = 3 }
    $script:PowerOn = $on
    return [ordered]@{ on = $on }
}

function Tool-SetBrightness($a) {
    if (-not $a.Contains('level')) { Fail "Missing input 'level' (0-100)." }
    Ensure-Ready
    $lvl = [int](Clamp ([double]$a['level']) 0 100)
    $bri = [int][Math]::Round($lvl * 2.55)
    Send-State @{ bri = $bri; tt = 2 }
    $script:MasterBri = $bri
    return [ordered]@{ level = $lvl }
}

# ---------------------------------------------------------------- MCP plumbing
$sideProp = @{ type = 'string'; enum = @('both', 'window', 'poster'); description = 'Which wall(s). Default both.' }
$script:ToolDefs = @(
    @{ name = 'status'; description = 'Controller reachability, on/off, brightness, current scene, each wall''s effect and colour, flash in progress.'
       inputSchema = @{ type = 'object'; properties = @{} } },
    @{ name = 'list_targets'; description = 'Scene names, flash names, sides, and WLED''s effect list.'
       inputSchema = @{ type = 'object'; properties = @{} } },
    @{ name = 'set_scene'; description = 'Apply a named scene from lights.json. It becomes the base that flashes return to.'
       inputSchema = @{ type = 'object'; properties = @{ name = @{ type = 'string' }; side = $sideProp }; required = @('name') } },
    @{ name = 'set_light'; description = 'One-off colour/effect (hex or colour name). Also becomes the base.'
       inputSchema = @{ type = 'object'; properties = @{ color = @{ type = 'string'; description = '#RRGGBB, #RRGGBBWW or a colour name' }; effect = @{ type = 'string'; description = 'WLED effect name, default Solid' }
           speed = @{ type = 'integer'; minimum = 0; maximum = 255 }; intensity = @{ type = 'integer'; minimum = 0; maximum = 255 }
           brightness = @{ type = 'integer'; minimum = 0; maximum = 100; description = 'Wall brightness 0-100 (before master brightness)' }; side = $sideProp }; required = @('color') } },
    @{ name = 'flash'; description = 'Play a named flash on top of the base scene, then return to the base. A new flash replaces one in progress.'
       inputSchema = @{ type = 'object'; properties = @{ name = @{ type = 'string' }; side = $sideProp; duration_ms = @{ type = 'integer'; minimum = 200; maximum = 10000 }
           gentle = @{ type = 'boolean'; description = 'Replace strobing/lightning with a quick fade' } }; required = @('name') } },
    @{ name = 'sweep'; description = 'Light travels from one wall to the other along the LED order.'
       inputSchema = @{ type = 'object'; properties = @{ color = @{ type = 'string' }; from = @{ type = 'string'; enum = @('window', 'poster') }; duration_ms = @{ type = 'integer'; minimum = 300; maximum = 10000 }
           gentle = @{ type = 'boolean' } }; required = @('color', 'from') } },
    @{ name = 'power'; description = 'All lights on or off. Off keeps the base, so on restores it.'
       inputSchema = @{ type = 'object'; properties = @{ on = @{ type = 'boolean' } }; required = @('on') } },
    @{ name = 'set_brightness'; description = 'Master brightness 0-100.'
       inputSchema = @{ type = 'object'; properties = @{ level = @{ type = 'integer'; minimum = 0; maximum = 100 } }; required = @('level') } }
)

function Reply($Id, $Result) { Send-Json ([ordered]@{ jsonrpc = '2.0'; id = $Id; result = $Result }) }
function Reply-Error($Id, [int]$Code, [string]$Msg) { Send-Json ([ordered]@{ jsonrpc = '2.0'; id = $Id; error = [ordered]@{ code = $Code; message = $Msg } }) }

function Tool-Result($Id, $res) {
    $text = ConvertTo-Json -InputObject $res -Depth 12 -Compress
    Reply $Id ([ordered]@{ content = @(@{ type = 'text'; text = $text }); structuredContent = $res; isError = (-not $res['ok']) })
}

$script:LastSlot = -1000

function Run-Tool([string]$Name, $a) {
    $script:FailExtra = $null
    try {
        switch ($Name) {
            'status'         { $d = Tool-Status $a }
            'list_targets'   { $d = Tool-ListTargets $a }
            'set_scene'      { $d = Tool-SetScene $a }
            'set_light'      { $d = Tool-SetLight $a }
            'flash'          { $d = Tool-Flash $a }
            'sweep'          { $d = Tool-Sweep $a }
            'power'          { $d = Tool-Power $a }
            'set_brightness' { $d = Tool-SetBrightness $a }
            default          { Fail "Unknown tool '$Name'." }
        }
        $r = [ordered]@{ ok = $true }
        foreach ($k in $d.Keys) { $r[$k] = $d[$k] }
        return $r
    } catch {
        $msg = $_.Exception.Message
        $r = [ordered]@{ ok = $false }
        if ($msg.StartsWith('ERR:')) {
            $r['reason'] = $msg.Substring(4)
            if ($script:FailExtra) { foreach ($k in $script:FailExtra.Keys) { $r[$k] = $script:FailExtra[$k] } }
            if ($Name -eq 'status' -and $msg -like '*not reachable*') { $r['reachable'] = $false }
        } else {
            Write-Log 'ERROR' ("tool $Name crashed: " + $_.Exception.Message + ' | ' + $_.ScriptStackTrace)
            $r['reason'] = 'Internal error in the lights bridge (details in wled-bridge.log)'
        }
        return $r
    }
}

function Handle-Call($req, $m) {
    $id = $req['id']
    $p = Get-Val $req 'params' @{}
    $name = [string](Get-Val $p 'name' '')
    $a = Get-Val $p 'arguments' $null
    if ($null -eq $a -or -not ($a -is [System.Collections.IDictionary])) { $a = [ordered]@{} }

    # rate limit: about 5 calls/s; anything that would wait more than 1.5 s is dropped
    $slot = [Math]::Max([WledPump]::NowMs, $script:LastSlot + 200)
    if (($slot - $m.ArrivedMs) -gt 1500) {
        Write-Log 'INFO' "DROP $name (queue wait)"
        Tool-Result $id ([ordered]@{ ok = $false; reason = 'dropped: waited more than 1.5 s behind other calls (limit is about 5 calls per second)' })
        return
    }
    $script:LastSlot = $slot
    while ([WledPump]::NowMs -lt $slot) { Step-Anim; Start-Sleep -Milliseconds 10 }

    $t0 = [WledPump]::NowMs
    $res = Run-Tool $name $a
    $ms = [WledPump]::NowMs - $t0
    Write-Log 'INFO' ("CALL $name " + (ConvertTo-Json -InputObject $a -Depth 4 -Compress) + " -> ok=$($res['ok']) $(if(-not $res['ok']){$res['reason']}) (${ms} ms)")
    Tool-Result $id $res
}

function Handle-Message($m) {
    try { $req = ConvertTo-Hash (ConvertFrom-Json $m.Line) }
    catch { Reply-Error $null (-32700) 'Parse error'; return }
    if (-not ($req -is [System.Collections.IDictionary])) { Reply-Error $null (-32600) 'Invalid request'; return }
    $method = [string](Get-Val $req 'method' '')
    $hasId = $req.Contains('id') -and ($null -ne $req['id'])
    $id = $req['id']
    switch ($method) {
        'initialize' {
            $ver = [string](Get-Val (Get-Val $req 'params' @{}) 'protocolVersion' '2024-11-05')
            Reply $id ([ordered]@{ protocolVersion = $ver; capabilities = @{ tools = @{} }; serverInfo = [ordered]@{ name = 'wled'; version = $script:Version } })
        }
        'ping'       { if ($hasId) { Reply $id @{} } }
        'tools/list' { Reply $id ([ordered]@{ tools = $script:ToolDefs }) }
        'tools/call' { Handle-Call $req $m }
        default      { if ($hasId) { Reply-Error $id (-32601) "Method not found: $method" } }
    }
}

function Main {
    $script:Out = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object System.Text.UTF8Encoding($false)))
    $script:Out.NewLine = "`n"
    $script:Out.AutoFlush = $true
    Write-Log 'INFO' "wled-bridge $($script:Version) starting (pid $PID)"
    Load-Config
    [WledPump]::Start()
    while ($true) {
        $m = [WledPump]::Take(15)
        if ($m) {
            try { Handle-Message $m } catch { Write-Log 'ERROR' ("message handler crashed: " + $_.Exception.Message + ' | ' + $_.ScriptStackTrace) }
        } elseif ([WledPump]::Eof -and [WledPump]::Count -eq 0) { break }
        Step-Anim
    }
    Write-Log 'INFO' 'stdin closed, exiting'
}

Main | Out-Null
