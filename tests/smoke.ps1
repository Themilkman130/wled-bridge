# Runs the bridge through test-client against the mock controller and checks the answers.
param([string]$Dir)
$ErrorActionPreference = 'Stop'
$fail = 0
function Check($name, $cmd, $must) {
    $out = (& $cmd *>&1 | Out-String)
    if ($out -match $must) { Write-Host "PASS $name" } else { Write-Host "FAIL $name`n$out"; $script:fail++ }
}
$tc = Join-Path $Dir 'test-client.ps1'
Check 'tools listed'      { & $tc -List }                                              'set_brightness'
Check 'status'            { & $tc -Tool status }                                       '"reachable":true'
Check 'list_targets'      { & $tc -Tool list_targets }                                 '"giants forge"'
Check 'set_scene'         { & $tc -Tool set_scene -Arguments '{"name":"tavern"}' }     '"scene":"tavern"'
Check 'alias scene'       { & $tc -Tool set_scene -Arguments '{"name":"giant''s forge"}' } '"scene":"giants forge"'
Check 'unknown scene'     { & $tc -Tool set_scene -Arguments '{"name":"zzz"}' }        '"ok":false.*"known"'
Check 'flash'             { & $tc -Tool flash -Arguments '{"name":"fire"}' }           '"flash":"fire"'
Check 'unknown flash'     { & $tc -Tool flash -Arguments '{"name":"zap"}' }            '"known"'
Check 'sweep'             { & $tc -Tool sweep -Arguments '{"color":"blue","from":"window"}' } '"from":"window"'
Check 'power off'         { & $tc -Tool power -Arguments '{"on":false}' }              '"on":false'
Check 'flash while off'   { & $tc -Tool flash -Arguments '{"name":"fire"}' }           'Lights are off'
Check 'power on'          { & $tc -Tool power -Arguments '{"on":true}' }               '"on":true'
Check 'brightness'        { & $tc -Tool set_brightness -Arguments '{"level":40}' }     '"level":40'
Check 'burst of 10'       { & $tc -Tool flash -Arguments '{"name":"lightning"}' -Burst 10 } 'dropped'
if ($fail) { exit 1 }
