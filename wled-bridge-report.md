# WLED bridge: report for the binder Claude

**Status: written but NOT yet run.** The bridge was drafted in a cloud session with no access to Colin's PC, to PowerShell, or to the controller at 10.0.0.240. Nothing below has been executed. Example responses are the designed shapes, not captured output. Section 5 lists the tests Colin still has to run; fill in the timings there before building the Lights panel on top of this.

## 1. What was built, and where

Target folder: `C:\Users\colin\Documents\DM-Tools\wled-bridge\` (copy this whole folder there).

| File | Purpose |
|---|---|
| `wled-bridge.ps1` | The stdio MCP server, server name `wled`. Windows PowerShell 5.1, no installs. A small inline C# class reads stdin on a background thread; HTTP is plain `Invoke-RestMethod`. |
| `lights.json` | IP address, scenes, flashes, wall gain. Reloaded automatically when the file changes. |
| `test-client.ps1` | Command-line client (see section 5). |
| `wled-bridge.log` | Created on first run. Rotates at about 512 KB, keeps 3 old files. |
| `wled-bridge-report.md` | This file. |

Behaviour that matters to the binder:
- **Segments:** on the first call that reaches the controller, the bridge makes sure two segments exist: id 0 "Window wall" LEDs 0-149 and id 1 "Poster wall" LEDs 150-299. It removes any extra segments. It changes nothing else: no LED preferences, Wi-Fi or current limiter.
- **Names, not IDs:** effects and palettes are looked up by name from `/json/eff` and `/json/pal`. In `lights.json` an effect can be a list of names; the first one WLED knows is used, otherwise it falls back to Solid and logs a warning.
- **Base and flashes:** `set_scene` and `set_light` set the base for the walls they touch. A flash plays on top of it and ends by restoring the base on the flash's walls. A new flash or sweep replaces one in progress. A scene or `power` call cancels it.
- **Controller unreachable:** answers `{"ok":false,"reason":"Lights controller not reachable at 10.0.0.240"}`. After one failure the bridge answers instantly for 2 s, then tries again.
- **Rate limiting:** one call per 200 ms (about 5/s). A call that would wait more than 1.5 s behind others is answered `dropped: ...`. The same flash name and side within 0.3 s of the last accepted one is dropped. Animation steps the bridge sends by itself are not counted.
- **Replies:** every tool returns JSON text plus `structuredContent`. Failures set `isError: true`. No stack traces; crashes are logged and answered as "Internal error in the lights bridge".
- **Brightness:** `set_brightness` is the master brightness (WLED `bri`). Scene `level` and `set_light.brightness` are per-wall brightness (0-100) multiplied by `wall_gain` in `lights.json`. Both gains are 1.0, so the dark window wall and white poster wall are not yet balanced.

## 2. Registration (needs Colin's OK first; nothing has been changed)

Add one entry to `mcpServers` in `%APPDATA%\Claude\claude_desktop_config.json`, next to the existing `soundtale` entry. Do not touch `soundtale`:

```json
"wled": {
  "command": "powershell.exe",
  "args": [
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", "C:\\Users\\colin\\Documents\\DM-Tools\\wled-bridge\\wled-bridge.ps1"
  ]
}
```

Match whatever form the `soundtale` entry uses (command, args, extra keys). I did not edit the file automatically because a PowerShell JSON round trip can reformat it. Restart Claude Desktop afterwards. The binder declares it as `host:wled`.

## 3. Tools

`side` is `"both"` (default), `"window"` or `"poster"` everywhere. Every response starts with `ok`.

| Tool | Input schema | Example response |
|---|---|---|
| `status` | `{}` | `{"ok":true,"reachable":true,"ip":"10.0.0.240","on":true,"brightness":50,"scene":"tavern","scenes":{"window":"tavern","poster":"tavern"},"walls":{"window":{"effect":"Candle","color":"#FF8A1E","speed":70,"intensity":130,"level":27},"poster":{...}},"flash":null}` |
| `list_targets` | `{}` | `{"ok":true,"scenes":[{"name":"tavern","aliases":[],"description":"..."}],"flashes":[{"name":"fire","aliases":[],"description":"Orange flicker","default_ms":1500}],"sides":["both","window","poster"],"effects":["Solid","Blink",...]}` (if unreachable: `effects` empty plus `effects_note`) |
| `set_scene` | `{name: string (req), side?: enum}` | `{"ok":true,"scene":"tavern","side":"window+poster"}`. Scene `off`: `{"ok":true,"scene":"off","power":"off","note":"..."}` |
| `set_light` | `{color: string (req; #RRGGBB, #RRGGBBWW or a name), effect?: string, speed?: 0-255, intensity?: 0-255, brightness?: 0-100, side?}` | `{"ok":true,"side":"window+poster","color":"#FF0000","effect":"Solid"}` |
| `flash` | `{name: string (req), side?, duration_ms?: 200-10000, gentle?: bool}` | `{"ok":true,"flash":"fire","side":"window+poster","duration_ms":1500,"gentle":false,"replaced":null}` |
| `sweep` | `{color: string (req), from: "window"\|"poster" (req), duration_ms?: 300-10000, gentle?: bool}` | `{"ok":true,"from":"window","to":"poster","duration_ms":1200,"gentle":false,"replaced":null}` |
| `power` | `{on: bool (req)}` | `{"ok":true,"on":false}` |
| `set_brightness` | `{level: 0-100 (req)}` | `{"ok":true,"level":60}` |

Error shapes:
- Unknown name: `{"ok":false,"reason":"Unknown flash 'zap'.","known":["fire","lightning",...]}`. The same pattern applies to scenes, sides, effects and colours.
- Dropped: `{"ok":false,"reason":"dropped: repeat of flash 'fire' within 0.3 s"}` or `"dropped: waited more than 1.5 s behind other calls ..."`.
- Lights off: flash and sweep answer `{"ok":false,"reason":"Lights are off: call power(on) first"}`.

## 4. Names (aliases also accepted; matching ignores case, punctuation and apostrophes)

**Scenes:** `tavern`, `cave`, `forest`, `giants forge` (aliases `giant's forge`, `forge`), `night`, `daylight`, `combat`, `combat epic`, `combat tense`, `creepy`, `calm`, `off`.

**Flashes:** `fire`, `lightning`, `thunder`, `cold`, `necrotic` (alias `unholy`), `radiant`, `psychic`, `acid` (alias `poison`), `healing`, `explosion`, `natural 20` (aliases `nat20`, `nat 20`, `crit`), `natural 1` (aliases `nat1`, `nat 1`, `fumble`).

Default lengths are in `lights.json` (`default_ms`): lightning 1000, fire 1500, healing 2000, thunder 1800, and so on.

**Gentle mode:** `flash` and `sweep` with `gentle:true` replace the whole effect with a fade to the flash's `color` at 55% brightness and back (about 300 ms in, at least 600 ms out). The binder's switch only has to pass the flag.

**Sweep direction:** the path follows the room: window wall 0 to 149 away from the DM corner, around the far corner, then poster wall 299 down to 150 back toward the corner. `from:"poster"` runs it the other way.

## 5. Tests: none run yet

Run from the folder in PowerShell. Tell whoever is in the room first; these change the lights. Record the `[ms]` figure the client prints.

| # | Test | Command | Expected | Result / ms |
|---|---|---|---|---|
| 1 | Starts, tools listed | `.\test-client.ps1 -List` | 8 tools | not run |
| 2 | Status (also creates the two segments) | `.\test-client.ps1 -Tool status` | `ok:true`, `reachable:true` | not run |
| 3 | List targets | `.\test-client.ps1 -Tool list_targets` | scenes, flashes, effect list | not run |
| 4 | Every scene | `.\test-client.ps1 -Tool set_scene -Arguments '{"name":"tavern"}'` (repeat per scene, then `side` window / poster) | look right | not run |
| 5 | Every flash returns to base | after a scene: `-Tool flash -Arguments '{"name":"fire"}'` (repeat per flash, then `status`) | base scene back after each | not run |
| 6 | Gentle | add `"gentle":true` to a lightning flash | quick fade, no strobing | not run |
| 7 | Sweep, both directions | `-Tool sweep -Arguments '{"color":"#00A0FF","from":"window"}'` then `from:"poster"` | band runs along the walls, base returns | not run |
| 8 | set_light, power, brightness | `set_light` with `{"color":"amber","effect":"Fire Flicker"}`; `power` off then on; `set_brightness` 30 | on restores the base | not run |
| 9 | Unknown name | `-Tool flash -Arguments '{"name":"zap"}'` | `ok:false` plus `known` list | not run |
| 10 | Burst of 10 | `-Tool flash -Arguments '{"name":"lightning"}' -Burst 10` | repeats dropped, late calls dropped after 1.5 s, no crash, base back at the end | not run |
| 11 | Flash during a flash | `-Calls '[{"tool":"flash","args":{"name":"fire"}},{"tool":"flash","args":{"name":"cold"}}]' -GapMs 400` | second says `replaced:"fire"`, base returns once | not run |
| 12 | Controller unplugged | unplug it, then `-Tool status`, then `-Tool flash ...` | `ok:false`, "Lights controller not reachable at 10.0.0.240" (first about 1 s, then immediate) | not run |
| 13 | Recovery | plug back in, wait a few seconds, `-Tool status` | `ok:true` again | not run |

Leave things as found: note the original WLED state first (open `http://10.0.0.240/json/state` in a browser) and set it back at the end.

## 6. Known limitations and things to check first

- **Untested code.** Expect small PowerShell or WLED-API bugs on first run. The most likely trouble spots are listed below. `wled-bridge.log` shows the cause of any failure.
- **Sweep is the riskiest part.** It freezes each segment (`frz`) and paints pixels with the `i` field, about 12 frames per second, then unfreezes and restores the base. If the band does not appear or the walls stay frozen, `power` or `set_scene` will recover them.
- **Effect and palette names** in `lights.json` (Candle, Aurora, Fire 2012, Twinkle, the Forest and Fire palettes, and so on) come from memory of WLED's list. Missing names fall back to Solid with a log warning. Use `list_targets` to see the real names, then tune `lights.json`.
- **White channel:** `#RRGGBB` lets WLED's Auto-calculate W = Accurate work out white. `daylight` uses an explicit `#000000FF`. Check that daylight and calm look right on the SK6812s.
- **Colours and levels are first guesses.** Colin will tune them. `wall_gain` is where to compensate for the dark window wall against the white poster wall.
- **Master brightness 0** is passed to WLED as `bri: 0`. The current limiter (2,000 mA per output) is the only power protection, so full-white flashes at 100% depend on it.
- **Stale knowledge:** the bridge tracks on/off itself and re-reads WLED only when it reconnects, so a change made in the WLED app can be out of date until the next `status`.
- **Rate limiting** is per bridge process, applied to every tool call including `status`.
- **One animation at a time.** A flash or sweep replaces the current one; they never overlap.
- **Timeouts** are whole seconds (PowerShell 5.1 limit), so "about 1 s" means exactly 1 s.
