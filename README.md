# Adaptive FPS

A World of Warcraft 3.3.5a addon (WotLK, interface 30300). When your frame rate stays below a target, it steps shadows and then distant detail down, and steps them back up once the frame rate recovers. Every change is reversible, and your own settings always win.

> **Warning: it may cause short loading screens in the middle of play.** Lowering or restoring the view distance or environment detail makes the client reload the world around you, which can bring up a brief loading screen. The first steps only change shadows, so you'll see these only when a scene stays slow enough to reach the later steps, and again when it steps back up. In combat it restores nothing until the fight ends, and steps down only below a lower combat target, so they don't land mid-fight. `/afps off` turns it off and puts your settings back.

## What it changes
There are six steps below your normal settings, taken one at a time:

| Step | Shadows (`extShadowQuality`) | View distance (`farclip`) | Ground clutter distance | Environment detail |
|---|---|---|---|---|
| 1 | 4 | unchanged | at most 140 | at most 1.5 |
| 2, 3 | 3 | unchanged | at most 140 | at most 1.5 |
| 4 | 3 | 85% | at most 140 | at most 1.5 |
| 5 | 3 | 70% | at most 130 | at most 1.5 |
| 6 | 3 | 55% (never below 500) | at most 120 | at most 1.25 |

- It never raises a setting. If yours is already lower than a step's value, yours stays.
- Shadows stop at 3, so buildings keep their shadows, unless your own setting is lower.
- Character detail, spell effects and everything else are left alone. Nothing needs a graphics restart.

## When it acts
- **Default target: 45 FPS.** It steps down after about 10 seconds more than 2 FPS below the target (smoothed), with at least 15 seconds between steps.
- **Stepping back up:** one step at a time, no sooner than 60 seconds after the last step down. It needs the frame rate to sit 7 FPS above the target for 25 seconds, or 2 above for 90 seconds.
- **Where:** by default only in cities and group instances (raids, dungeons, battlegrounds, arenas), where scenes are busiest. `/afps scope all` uses it everywhere.
- **In combat:** it steps down only below the combat target, 15 FPS by default (`/afps combat`), and restores nothing until combat ends.
- **Paused:** while AFK or in a cinematic, for 20 seconds after a loading screen, and while Video Options is open (your normal settings are shown and kept there). It also pauses when the frame rate sits still at a frame cap, for example WoW in the background at its 30 FPS background cap.

## Your settings win
- A setting you change by hand, or another addon changes, becomes the new normal. Adaptive FPS only ever restores values it set itself.
- `/afps off`, logging out and opening Video Options restore your normal settings. After a crash, the next login restores them too.

## Commands
- `/afps` or `/afps status`: on or off, target, current step, frame rate, and each setting against your normal.
- `/afps on` / `/afps off`: turn it on or off. Off restores your settings.
- `/afps target 20-120`: the frame rate to aim for.
- `/afps combat 5-60`: in combat, step down only below this.
- `/afps scope busy` / `/afps scope all`: cities and instances only, or everywhere.
- `/afps baseline`: save your current settings as the normal ones.
- `/afps profile`, then `/afps report`: measure which addons use the most CPU over 30 seconds. Profiling needs a `/reload` to start and another to switch off.

## Install
Copy the `AdaptiveFPS` folder into `Interface\AddOns`. Settings are saved in `ChromieAdaptiveFPSDB`. Settings kept by the copy that used to be embedded in Carbonite Runes are taken over on first login. If both copies are installed, only one runs.

## Tests
`python tests/test_adaptive_fps.py` runs the addon under Lua 5.1 (`pip install lupa`) against a mocked client: 33 checks, covering the stepping and restoring, combat, the background frame cap, manual changes, Video Options, reload and crash recovery, rejected settings, and the CPU profiler.

Written with AI coding assistants (Claude Code and Codex).

## License
MIT (see `LICENSE`).
