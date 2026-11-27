# Upstream: development notes

The player-facing description is in [README.md](README.md). This page covers
building, running, testing and tuning the game.

Upstream is built with **Godot 4** (GDScript, no
assets: all art and sound are generated in code).

The board has a light PlayStation 1 flavour: it renders at 480 lines (the PS1's
hi-res mode) with 15-bit colour and a subtle ordered dither, then scales up
smoothly.
The menu and the side panel use an industrial pump-station look (steel plates,
rivets, hazard stripes, a pressure gauge on the nameplate) and stay sharp so
they read well on phones. Buttons are chunky, rounded game buttons that stand
on a darker base and sink onto it when pressed (`_btn_box` in `ui.gd`); height
and score are counter plates with an icon (up arrow, star) and the number in a
dark display window. There is no top bar: height and score sit in the side
panel under the hand (in the bottom bar, between the hand and the power
buttons, in portrait), so the board gets the full height of the screen.

## Deployment

Every push to `main` runs [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml):
it downloads Godot 4.7.2 and its web export templates, runs both test suites,
exports the "Web" preset and publishes it to GitHub Pages at
https://zzzteph.github.io/upstream/. A failing test stops the deploy, so the
live game stays on the last good build. You can also start it by hand from the
Actions tab (Run workflow).

One-time setup: in the repository's **Settings > Pages**, set **Source** to
**GitHub Actions**.

## Run it

- **Editor:** open this folder in Godot 4.7 (tested with 4.7.2) and press F5.
- **Browser:** Project > Export > Web (the preset is included, single-threaded,
  so any static host works). Then serve the folder over HTTP, for example:

  ```bash
  cd build/web && python3 -m http.server 8000
  ```

  and open http://localhost:8000. A Godot web build can't be opened straight
  from disk with `file://`.
- **Phones and tablets:** the same web build works with touch. The layout
  switches to portrait (controls in a bar under the board) or a compact sideways layout,
  and text and buttons scale to the screen.

## Frame rate

The game has no frame cap: it runs at the display's refresh rate (120 Hz or
more on high-refresh screens; browsers follow the display too). The aim is
that play feels instant even on a cheap phone, so every frame is kept small:

- Nothing is redone that hasn't changed: static art is rasterised once into
  sprite atlases; board rows are cached and only redrawn when they change,
  and scrolling moves one parent node instead of every row; the layout is
  only worked out when the window resizes; the side panel only reformats a
  number when it changes; the board renders at low resolution.
- The tile the water is in stamps its dry pipe from the atlas and draws only
  the water as vectors.
- Bubbles in full pipes are worked out once per row change, then only moved.
  Particles live in packed arrays, not a Dictionary each. Snow and spill
  spray spawn per second, not per frame, so 120 Hz doesn't double them.
- The frost of a Flow-freeze is drawn once, then moved and faded.
- The backdrop uses a table of random numbers and skips whatever is behind
  the board or panel. The full-screen flash layer only exists while flashing.
- About 90-110 draw calls a frame.
- **Quality steps down by itself** (`quality` in `main.gd`): after 3 s of
  slow frames (under ~45 a second) while playing, the decorative motion goes
  (background bubbles and decorations, bubbles in pipes, particle glow);
  if it's still slow, the board renders at 3/4 resolution. Low-memory phones
  (2 GB or less) start at the lighter level. `?quality=0|1|2` forces it.
- The web page renders at most 2 device pixels per CSS pixel (1.5 on
  low-memory phones), so 3x phone screens don't push 2.25x the pixels.

`?prof` logs, every 2 s, how many microseconds each part of a frame takes
(game logic, each drawing layer, the panel) - in the browser too, where it
matters. About 0.25 ms of script a frame in play on a desktop CPU (about
3x that in the browser).

The solver plans on a snapshot of the visible rows in packed arrays (states
are ints, the heap is inlined): about 1 ms for a fresh plan on a desktop CPU,
and an unchanged board reuses the last plan (40 us).

## Web page

**Loading screen.** `web/shell.html` is the page template the web export
uses (`html/custom_html_shell`; Godot's own shell with its loading screen
replaced). While the game downloads it shows the UPSTREAM nameplate from the
main menu, drawn as an SVG to the same measurements as `station_logo.gd`, on
the menu's colours: the blue rule under the name is the progress bar and the
gauge needle rises with it (a short sweep when the size isn't known yet). When
the game starts, the nameplate fades out over the menu's own.


`export_presets.cfg` adds a small script to the page head (`html/head_include`;
the same script is in the claude.ai artifact page). It caps the pixel ratio
(above), and makes sound work on phones: browsers only let audio start from
a tap, so it keeps the engine's AudioContext and resumes it on every touch
end, pointer up, mouse down, key and click (iPhones count touchend, not
touchstart), plays a one-sample silent buffer inside the tap (some iOS
versions need a sound to start there), resumes again when the page comes
back from the background, and on iPhone sets the audio session to playback
so the game is heard with the silent switch on.

## Menu and modes

The main menu shows the best score above the nameplate, a big NEW GAME button
and a small SOLVER button (a game the AI plays, see below). There are no
difficulty levels: the water starts at one speed and rises evenly to 8x by row
800 (`SPEED_MAX`, `SPEED_MAX_ROW`: about +0.9% of the starting speed per row),
flat after that. The best score is stored under
`upstream_score_medium` (the key the old Medium level used, so that record
carries over). PLAY AGAIN, RESTART, R and Enter on the game-over screen repeat
the same kind of game.

The game plays in unlock mode; set `DEFAULT_MODE` in `scripts/tuning.gd` to
`"classic"` for the piece-queue game.

- **Unlock** (like BioShock's hacking): every tile starts as a closed steel
  hatch (light, raised, tread plate). Click or tap one to flip it open and see
  what's under it: a pipe, an empty slot (a dark recessed socket with corner
  marks) or a rock. Click a pipe to pick it up, then click an open spot or
  another pipe to swap them (click it again to put it back). Water that
  reaches a closed block spills, so open blocks ahead of it.
- **Classic**: the board is open and you place pieces from a queue of five.

**Powers:** every run starts with one **Flow-freeze** and one **Reveal**
(`START_POWERS`), and every 100 rows adds another of each.
Flow-freeze stops the water for 8 seconds while every pipe frosts over. Reveal
opens every block on screen in one wave; rows above
the screen stay closed. They are pipe-framed cards in the panel (steel for
Freeze, brass for Reveal) that stay for the whole run and dim when empty (Q and
E on a keyboard).

**Narrow pipes** (thinner steel tubes with a ring in the middle) connect like
normal pipes but the water takes 2.5x as long to get through them, so swap them
onto the water's path to buy time.

## Controls

| Action | Mouse / touch | Keyboard |
| --- | --- | --- |
| Open a block (unlock mode) | Click / tap it | Arrows or WASD to move the cursor, Space / Enter to click |
| Pick up a pipe, then swap it (unlock mode) | Click / tap the pipe, then the spot | Same |
| Place the next piece (classic mode) | Click / tap an empty tile | Same |
| Replace a dry pipe (classic, 1 s lock) | Click / tap it | Same |
| Speed up (x4 water and countdown, 2x points per tube, both +10% per tube held through, up to x8 / 4x) | Hold anywhere on the board or panel (0.5 s) | Hold F |
| Watch the solver play a game | SOLVER on the menu | |
| Flow-freeze / Reveal | FREEZE / REVEAL buttons in the panel | Q / E |
| Pause | The pause button at the top of the panel (also pauses by itself when you switch apps) | P / Esc |
| Mute | | M |
| Restart | Play again | R |

## First-run walkthrough

The very first game is played on a prepared board (`tutorial_start` in
`scripts/generator.gd`): row 1 goes straight up from the pump, the hatch above
the pump hides an empty slot and the hatch next to it hides the straight pipe
that slot needs. The walkthrough (`scripts/tutorial.gd`) uses it, so every
instruction is true: open the hatch above the pump (empty), open the one next
to it (a straight pipe), pick it up, put it above the pump. Those steps follow
the board itself, so they stay right whatever the player taps in between
(holding a pipe that won't fit, it says to put it back first). Then it
explains how the water flows, hold to speed up, the two powers (with the real
numbers from `tuning.gd`) (OK to continue; there is no skip). A
coach panel sits at the top of the board, everything but the target is dimmed
(a spotlight), and a pulsing frame with a bouncing arrow points at it. The
pump's countdown waits while it runs. When it's finished the flag
`tutorial_done` is saved and it never shows again. It words things the way
the player plays (`touch_ui()` in `main.gd`): tap and finger after a touch,
click and the mouse after a click, and the F key only once they've pressed a
key; before any input it goes by the browser's main pointer (a finger on
phones and tablets, a mouse on a laptop even with a touch screen).

## Feedback

- **Speed in the background.** Bubbles and current streaks rise through the
  backdrop at the water's pace (`BoardRenderer.flow_motion`, eased, a softened
  power of the real speed): faster as it climbs, rushing and stretching into
  streaks while you hold, still during a freeze. The zones' own decorations
  (bubbles, embers, gears, grid streaks) move at the same pace, and a glass
  channel in each side wall of the board shows it too (on a phone the board
  covers most of the backdrop).
- **Freeze countdown.** While a freeze runs, the FREEZE button reads FROZEN
  with the seconds left, and ice fills it and drains away as time runs out.
- **FAST badge.** While you hold, a badge at the top of the board shows the
  current speed and points multipliers, with a bar that fills as the hold
  ramps up to its maximum.
- Freeze, Reveal and Pause are plain text buttons in the same rounded style as
  the menu buttons; the HEIGHT arrow and SCORE star are drawn with smoothed
  edges.
- **Actions per second.** The game-over screen shows the run's average: taps
  that did something (open a hatch, pick up or put down a pipe, Freeze,
  Reveal) per second played, pauses not counted (`actions`, `play_time` in
  `main.gd`). Solver games count the solver's taps.

## Assets and licences

Everything the game shows or plays is made by its own code, so there are no
third-party images, sounds or fonts to license:

- Pipes, tiles, rocks, buttons, icons, backgrounds and the logo are drawn with
  Godot's drawing calls (`pipe_art.gd`, `sprite_atlas.gd`,
  `board_renderer.gd`, `ui.gd`, `title_backdrop.gd`, `station_logo.gd`).
  `icon.svg` was written by hand for this project. The screenshots in `media/`
  are of this game.
- Sounds are synthesised when the game starts (`sfx.gd`).
- Text uses Godot's built-in default font, Open Sans SemiBold, under the SIL
  Open Font License 1.1, which allows commercial use and embedding.
- The engine is Godot, under the MIT licence. A commercial release (Google
  Play, Steam) must show Godot's licence text, and the notices of the
  third-party libraries built into the engine, somewhere the player can find
  them, such as a credits screen. See "Complying with licenses" in the Godot
  docs.

## SOLVER

The small SOLVER button on the menu starts a game played by
`scripts/ai_player.gd`, a bot that solves the puzzle the way a person would. A visible finger moves to
every tap at a human pace (`AI_MOVE_SPEED`, `AI_THINK_MIN` / `AI_THINK_MAX`:
about three taps a second, like a quick player, a little faster when it's in
a hurry), and every tap
goes through `try_place()`, exactly like the player's. It only uses what is on
screen: it never reads a closed hatch or the generator's guaranteed path.

**Planning.** Each time it decides, it plans the best route for the water from
where the water is right now through everything open on screen: a Dijkstra
search over (cell, side the water comes in from). Pipes that already fit cost
almost nothing (reservoirs and narrow pipes even less, since they buy time),
so it happily sends the water the long way round through pipes already in
place - free time and extra points. A swap costs more, pieces that are running short cost more still (it checks the
route's needs against the loose pipes on screen and searches again with
penalties), and going down costs extra. It then picks where the route should
stop: off the top of the screen if it can, else at a closed hatch (rated lower
when the hatch looks like a dead end, boxed in by walls and rocks), else as
high as possible. For every cell on the route it estimates when the water will
arrive.

**Rebuilding.** Because it always plans from the water, a route that went
wrong (a rock behind a hatch, a missing piece, a pipe that got moved) simply
gets re-planned: pipes that still fit are kept, the rest are swapped out. In
an emergency it borrows a matching pipe from further along its own route and
rebuilds that spot afterwards.

**Strategy**, in order of priority:

1. finish a half-done swap (a pipe in hand goes to the first cell it fits);
2. Flow-freeze when the water would reach unfinished pipe before it could fix
   it even hurrying (freezes are rare, so only then);
3. Reveal when the water is moving and there are too many closed hatches to
   open in time;
4. look before you leap: open the hatch where the route stops before building
   towards it (it may hide a rock). Earliest deadline first: that hatch must
   be seen while there's still time to re-route (open it, then rebuild up to
   two pipes); the first fix must be done before the water gets there;
   whichever deadline is sooner goes first;
5. fix the most urgent cell. Choosing the pipe to fetch: two-for-one swaps
   first (a pipe from another route cell that wants exactly the pipe being
   replaced - one swap fixes both), narrow pipes next (they slow the water),
   then pipes from rows the water has already passed, then the nearest; if no
   pipe fits anywhere on screen, Reveal or open the hatches nearest that cell;
6. open more hatches when the route is stuck or short of pieces;
7. fix the rest of the route, nearest the water first;
8. in spare time, upgrade pipes on the route to narrow ones of the same shape
   (each makes the water take 2.5x as long there), when that gains more time
   than the swap costs;
9. open hatches ahead so the next plan has more to work with;
10. with nothing to fix and nothing to open, and the water well behind the
    route, hold the screen to hurry it along (and score double). It lets go
    as soon as there's work, or when the route ahead drops under 8 seconds
    (more at high speed).

The player's taps on the board are ignored while it plays; MAIN MENU (pause or
game over) ends it. A solver game doesn't set a best score.

**Style.** It snakes the pipe wall to wall instead of rushing straight up: the
search also tracks the column where the route entered each row, and turning up
costs `AI_CURVY` for every column it could still have run along the row; when
choosing where the route should stop, every column travelled along the current
row also counts, enough that reaching the far wall beats turning up early. So
it opens the hatches along the row and fills the shaft: about 2.5 tubes per row
early on instead of 1.6 - more points, and more fun to watch. The pull fades
out as the water nears `AI_CURVY_UNTIL_SPEED` and switches off when it's in
danger, so it doesn't snake itself to death at top speed.

**Rocks.** Only the stretch of a row it could really reach counts towards the
snake (rocks, walls, full pipes and fixed pipes that don't run sideways end
it), so a row blocked by rocks never stops it from climbing out. A route that
would end on an open cell with no possible way on (rocks, walls or full pipes
all round) counts as a dead end, not a wait, so it never steers the water into
a pocket. Deeper pockets too: before settling on where a route ends, a flood
fill checks that the water could still climb at least two more rows from
there through cells not known to be blocked (closed hatches count as open)
and not on the route itself (the water can't go back through its own pipes);
if not, that end counts as a dead end and it steers elsewhere while it still
can. Closed hatches that look boxed in are rated lower, and the hatch at the
end of the route is opened by its deadline (see 4), early enough to re-route
if it hides a rock.

`tests/ai_bench.gd` plays seeded games and reports how far it gets (up to row
400), with tubes per row; `-- 1 400 <n>` replays game n and prints the
solver's last decisions and the board when it loses. Latest results (8 games):
rows 251-400+ (median about 360; two still going at row 400), about 2 tubes
per row overall (2.5 while snaking early on). It loses when the water at
3.2-4.5x outpaces what human-speed tapping can build or find: stuck for want
of the one pipe the only way up needs, with no Freeze or Reveal left.

## Rules

- Water starts after a 10-second countdown, shown on the pump's pressure gauge,
  and speeds up evenly with height, to 8x its starting speed at row 800. The
  panel shows your height and score, the pause button and the two powers.
- In unlock mode every row hides at least the pipes its guaranteed path needs,
  so unlocking a row and swapping pipes within it is always enough.
- The run ends when water reaches an open pipe end, a wall, a rock, an empty tile,
  a pipe that is already full, or a one-way pipe from the wrong side.
- Pieces: straight horizontal and vertical, four corners and a cross. A cross can
  be filled twice, once each way.
- Scoring: +1 per tube the water fills (a cross filled both ways is two tubes).
  Holding to speed up makes the water x4 as fast and every tube worth 2x; each
  tube filled while you keep holding adds 10% of that to both, up to x8 speed
  and 4x points (after 10 tubes). Letting go resets it. Fractions of a point
  carry over. Rows give no points of their own. Nothing else: no bonuses, no penalties, and the debug
  fast-forward doesn't change the points.
- Obstacles grow with height: rocks, one-way pipes (brass, with arrows) and
  reservoirs (fixed pipes that swell into a wide chamber and take 4x as long to
  fill, which buys you time).
- There are no bonus pickups on the board. The only things that help are the
  slow tubes (narrow pipes and reservoirs) and the Flow-freeze / Reveal powers.
- Every 50 rows the zone changes ("ZONE 2" ... up to "ZONE 255"); the looks
  cycle through five palettes (sewer, factory, neon, magma, space).
- The level is always solvable: each row carries a guaranteed path that only
  ever holds free tiles or fixed pipes pointing the right way, and no row can
  be sealed by rocks.

## Tuning

Every knob is in [`scripts/tuning.gd`](scripts/tuning.gd):

| Constant | Default | What it does |
| --- | --- | --- |
| `COUNTDOWN_TIME` | 10 s | Delay before the water starts |
| `BASE_SEGMENT_TIME` | 2.6 s | Time to fill one tile at 1.0x |
| `SPEED_MAX` / `SPEED_MAX_ROW` | 8x / 800 | Top speed of the water, reached evenly by this row |
| `FAST_FORWARD_MULT` | 5x | Debug fast-forward (autoplay and tests) |
| `RESERVOIR_FILL_FACTOR` | 4 | How much slower reservoirs fill |
| `REPLACE_LOCK_TIME` | 1 s | Queue lock after replacing a pipe (classic) |
| `PIECE_WEIGHTS` | 16,16,14,14,14,14,5 | Piece odds (crosses rarest) |
| `DEFAULT_MODE` | "unlock" | Game mode ("unlock" or "classic") |
| `UNLOCK_PIECE_FILL` | 0.72 | Chance a closed block hides a pipe (else an open spot) |
| `UNLOCK_SPINE_PIECE_CHANCE` | 0.5 | Chance a path tile already hides the pipe it needs |
| `FLIP_TIME` | 0.3 s | Unlock flip animation |
| `START_POWERS` | 1 | Flow-freezes and Reveals at the start of every run |
| `HOLD_SPEED_MULT` / `HOLD_SPEED_MAX` | 4x / 8x | Speed when you start holding the screen, and its ceiling |
| `HOLD_SCORE_MULT` / `HOLD_SCORE_MAX` | 2x / 4x | Points per tube when you start holding, and their ceiling |
| `HOLD_RAMP` / `HOLD_DELAY` | 0.1 / 0.5 s | What each tube held through adds (10% of the starting x); how long a press must last |
| `AI_CURVY` / `AI_CURVY_UNTIL_SPEED` | 25 / 3.0x | How hard the solver snakes wall to wall, and the speed where it stops |
| `AI_MOVE_SPEED` / `AI_THINK_MIN` / `AI_THINK_MAX` | 1400 px/s / 0.06 s / 0.18 s | Solver finger speed and pause between taps |
| `POWER_AWARD_ROWS` / `FREEZE_TIME` | 100 / 8 s | Rows per extra Flow-freeze + Reveal pair; freeze length |
| `SCORE_TUBE` | 1 | Points per tube filled (times the hold multiplier while holding) |
| `SAFE_ROWS` | 5 | Obstacle-free rows at the start |
| `ROCK_BASE` / `ROCK_PER_ROW` / `ROCK_MAX` | 0.10 / 0.0025 / 0.40 | Rock density and growth |
| `MAX_ROCKS_PER_ROW` | 4 | Hard cap per row |
| `ONEWAY_START_ROW` / `ONEWAY_CHANCE` / `ONEWAY_ON_PATH_CHANCE` | 35 / 0.035 / 0.09 | One-way pipes |
| `RESERVOIR_START_ROW` / `RESERVOIR_CHANCE` / `RESERVOIR_ON_PATH_CHANCE` | 55 / 0.012 / 0.06 | Reservoirs |
| `NARROW_FILL_FACTOR` / `NARROW_CHANCE` / `NARROW_START_ROW` | 2.5 / 0.16 / 3 | Narrow pipes: slowdown, how often, from which row |
| `SPINE_SHIFT_WEIGHTS` | 40,38,16,6 | How far the guaranteed path drifts sideways per row |
| `ZONE_ROWS` | 50 | Rows per zone |
| `CAMERA_LEAD_FRACTION` / `CAMERA_STIFFNESS` | 0.33 / 3.0 | Camera follow |
| `KEEP_ROWS_BELOW` / `GENERATE_AHEAD` | 20 / 8 | Rows kept below / generated above |
| `PS1_MODE` | true | PS1 look on or off (off = smooth, anti-aliased, full resolution) |
| `PS1_SHORT_SIDE` | 480 | Board pixels across the screen's short side (240 = chunky PS1) |
| `SMOOTH_EDGES` | true | Anti-aliased art and smooth scaling (false = hard pixel edges) |
| `PS1_COLOR_LEVELS` / `PS1_DITHER` | 31 / 1.0 | Colour steps per channel (31 = 15-bit) and dither strength |
| `UI_BASE_MAX` / `UI_BASE_MIN` | 720 / 480 | Virtual resolution on big screens / phones (smaller = bigger UI) |
| `MIN_VISIBLE_ROWS` / `MIN_VISIBLE_ROWS_COMPACT` | 7.5 / 5.5 | Rows that always fit on screen / on short screens (fewer = bigger tiles) |

Each zone also scales the obstacle mix (`rock_mult`, `oneway_mult`, ...) in
[`scripts/zones.gd`](scripts/zones.gd).

## Code map

| Script | Role |
| --- | --- |
| `main.gd` | Game controller: states, rules, scoring, layout, hold to speed up |
| `ai_player.gd` | The SOLVER bot: reads the visible board, plans, taps with a moving finger |
| `tutorial.gd` | The first-run walkthrough |
| `tuning.gd` | Tunable constants |
| `pieces.gd` | Piece types, openings, water path geometry |
| `grid.gd`, `tile.gd` | Sparse endless board; rows below the floor are discarded |
| `flow.gd` | Moves the water and reports fills, entries and spills |
| `game_camera.gd` | Smooth follow (water in the lower third) and screen shake |
| `generator.gd` | Procedural rows with a guaranteed path upward |
| `zones.gd` | Zone palettes and obstacle mixes |
| `pipe_art.gd` | Vector drawing of pipes, water, rocks and icons |
| `sprite_atlas.gd` | Rasterises the vector art once per zone into textures |
| `board_renderer.gd` | Backdrop (with the speed-paced current), cached board rows, live water tile, particles, queue |
| `ps1_screen.gdshader` | 15-bit colour and ordered dither for the low-res board |
| `input_handler.gd` | Mouse, touch and keyboard |
| `ui.gd` | Height and score in the panel, pause / power buttons, FAST badge, banners, title / pause / game-over screens |
| `title_backdrop.gd` | The menu's background: pump-station wall and flowing pipes |
| `station_logo.gd` | The UPSTREAM nameplate: steel plate, gauge, stencil letters |
| `sfx.gd` | Synthesised sound effects |
| `save_data.gd` | Best score and one-time flags (localStorage on the web, a config file elsewhere) |

## Tests

```bash
godot --headless --script res://tests/run_tests.gd
```

```bash
godot --headless --fixed-fps 60 --script res://tests/game_test.gd
```

`run_tests.gd` checks every piece from every entry side, the cross both ways,
every way the water can be stopped, and generates 250 seeds x 420 rows to prove
each one solvable. `game_test.gd` drives the real scene with input events:
the menu (best score, NEW GAME, SOLVER), the speed curve, the starting powers,
height and score in the panel, placing, replacing, unlocking and swapping,
narrow pipes, pause (P, Esc and the pause button), the countdown, the
+1-per-tube scoring on a cross loop, hold to speed up (finger and F, the ramp
to x8 speed and 4x points, reset on letting go), the freeze button's
countdown fill, the prepared walkthrough board and every
step of the walkthrough (including putting back a wrong pipe; no SKIP), the
solver climbing 25 rows by itself at under 4 taps a second without stalling,
rebuilding its route after a pipe on it is broken, holding to speed up, and
not setting a best score, and a 165-row run through four zones.

For testing in a browser, add `?fps` to the URL to log frame rate and draw
calls to the console, `?prof` to log where each frame's time goes,
`?quality=0|1|2` to force a quality level, `?autoplay` to let a bot play, and `?powers` to start
with three Flow-freezes and three Reveals.
