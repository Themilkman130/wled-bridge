# test-client.ps1 - talk to wled-bridge.ps1 over stdio from the command line (Windows PowerShell 5.1).
#
#   .\test-client.ps1 -List
#   .\test-client.ps1 -Tool status
#   .\test-client.ps1 -Tool set_scene -Arguments '{"name":"tavern"}'
#   .\test-client.ps1 -Tool flash -Arguments '{"name":"lightning"}'
#   .\test-client.ps1 -Tool flash -Arguments '{"name":"fire"}' -Burst 10        # 10 calls sent at once
#   .\test-client.ps1 -Tool flash -Arguments '{"name":"fire"}' -Repeat 3 -GapMs 500   # sequential, with a pause
#   .\test-client.ps1 -Calls '[{"tool":"flash","args":{"name":"fire"}},{"tool":"status","args":{}}]' -GapMs 400
#
# Each call prints the round-trip time in ms and the JSON the bridge answered with.
param(
    [string]$Tool,
    [string]$Arguments = '{}',
    [string]$Calls,
    [switch]$List,
    [int]$Burst = 0,
    [int]$Repeat = 1,
    [int]$GapMs = 0,
    [int]$WaitMs = 8000,
    [switch]$Raw
)
$ErrorActionPreference = 'Stop'
$bridge = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'wled-bridge.ps1'

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$bridge`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$proc = [System.Diagnostics.Process]::Start($psi)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$script:nextId = 1
$script:pending = $null

function Send($method, $params) {
    $id = $script:nextId++
    $msg = [ordered]@{ jsonrpc = '2.0'; id = $id; method = $method; params = $params }
    $proc.StandardInput.WriteLine((ConvertTo-Json -InputObject $msg -Depth 12 -Compress))
    $proc.StandardInput.Flush()
    return $id
}

function Read-Reply([int]$TimeoutMs) {
    if (-not $script:pending) { $script:pending = $proc.StandardOutput.ReadLineAsync() }
    if (-not $script:pending.Wait($TimeoutMs)) { return $null }
    $line = $script:pending.Result
    $script:pending = $null
    return $line
}

function Show($label, $line, $sentAt) {
    $ms = $sw.ElapsedMilliseconds - $sentAt
    if ($null -eq $line) { Write-Host "$label  (no answer within the wait time)" -ForegroundColor Red; return }
    if ($Raw) { Write-Host "$label  [$ms ms]  $line"; return }
    $o = ConvertFrom-Json $line
    if ($o.error) { Write-Host "$label  [$ms ms]  PROTOCOL ERROR $($o.error.message)" -ForegroundColor Red; return }
    if ($o.result.content) {
        $r = ConvertFrom-Json $o.result.content[0].text
        $colour = 'Green'; if (-not $r.ok) { $colour = 'Yellow' }
        Write-Host "$label  [$ms ms]  $($o.result.content[0].text)" -ForegroundColor $colour
    } else {
        Write-Host "$label  [$ms ms]  $line"
    }
}

try {
    $t = $sw.ElapsedMilliseconds
    [void](Send 'initialize' @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'test-client'; version = '1' } })
    $init = Read-Reply 15000
    if ($null -eq $init) { throw 'The bridge did not answer initialize. Check wled-bridge.log in this folder.' }
    $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
    Write-Host "initialized in $($sw.ElapsedMilliseconds - $t) ms"

    if ($List) {
        [void](Send 'tools/list' @{})
        $l = ConvertFrom-Json (Read-Reply 5000)
        foreach ($x in $l.result.tools) { Write-Host ("{0,-15} {1}" -f $x.name, $x.description) }
        return
    }

    # Build the list of calls to make
    $plan = @()
    if ($Calls) {
        foreach ($c in (ConvertFrom-Json $Calls)) { $plan += , @{ tool = $c.tool; args = (ConvertFrom-Json (ConvertTo-Json -InputObject $c.args -Depth 8 -Compress)) } }
    } elseif ($Tool) {
        $n = [Math]::Max([Math]::Max($Burst, $Repeat), 1)
        for ($i = 0; $i -lt $n; $i++) { $plan += , @{ tool = $Tool; args = (ConvertFrom-Json $Arguments) } }
    } else {
        Write-Host 'Nothing to do. Use -List, -Tool <name> [-Arguments <json>], or -Calls <json array>.'; return
    }

    if ($Burst -gt 0) {
        # send everything at once, then collect the answers
        $sent = @{}
        foreach ($p in $plan) { $id = Send 'tools/call' @{ name = $p.tool; arguments = $p.args }; $sent[$id] = $sw.ElapsedMilliseconds }
        for ($k = 0; $k -lt $plan.Count; $k++) {
            $line = Read-Reply $WaitMs
            $id = 0; if ($line) { $id = [int](ConvertFrom-Json $line).id }
            Show ("#{0}" -f ($k + 1)) $line $sent[$id]
        }
    } else {
        $k = 0
        foreach ($p in $plan) {
            $k++
            $at = $sw.ElapsedMilliseconds
            [void](Send 'tools/call' @{ name = $p.tool; arguments = $p.args })
            Show ("#{0} {1}" -f $k, $p.tool) (Read-Reply $WaitMs) $at
            if ($GapMs -gt 0 -and $k -lt $plan.Count) { Start-Sleep -Milliseconds $GapMs }
        }
    }
} finally {
    try { $proc.StandardInput.Close() } catch { }
    if (-not $proc.WaitForExit(3000)) { $proc.Kill() }
}
