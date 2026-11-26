## ============================================================================
##  UPSTREAM - game controller: state machine, rules, scoring and layout.
## ============================================================================
## Owns the Grid, Generator, Flow and Camera, and wires the Renderer, Input,
## UI and Sfx nodes together. See tuning.gd for every difficulty knob.
extends Node2D

enum State { TITLE, COUNTDOWN, RUNNING, SPILL, GAMEOVER }

const REASONS := {
	"rock": "The water smashed into a rock.",
	"empty": "The water poured out onto an empty tile.",
	"leak": "The water leaked out of an open pipe end.",
	"wall": "The water hit the wall.",
	"oneway": "The water hit a one-way pipe from the wrong side.",
	"clogged": "The water ran into a pipe that was already full.",
	"locked": "",  # Plain enough on screen; no message.
}

var state := State.TITLE
var paused := false
var mode: String = Tuning.DEFAULT_MODE  ## "unlock" (BioShock-style) or "classic" (piece queue).
var grid := Grid.new()
var gen := LevelGenerator.new()
var flow := Flow.new()
var cam := GameCamera.new()
var queue: Array[int] = []        ## Classic mode: upcoming pipe items (see Pieces.item).
var rng := RandomNumberGenerator.new()

var renderer: BoardRenderer
var atlas: SpriteAtlas
var world_view: TextureRect          ## PS1 mode: shows the world viewport, scaled to the screen.
var world_vp: SubViewport            ## PS1 mode: the world renders in here, at PS1_SHORT_SIDE lines.
var is_touch := false
var input_handler: InputHandler
var ui: GameUI
var sfx: Sfx

# Run state
var difficulty: String = Tuning.DEFAULT_DIFFICULTY  ## "easy", "medium" or "hard": scales the water speed.
var score := 0
var best := 0               ## Best score on the current difficulty.
var height := 0            ## Highest row the goo has reached.
var countdown := 0.0
var fast_forward := false
var lock_timer := 0.0
var queue_shift := 0.0     ## 1 -> 0 slide animation after a placement.
var time := 0.0
var zone_index := 0
var spill := {}
var spill_timer := 0.0
var new_best := false
var last_reason := ""
var _beeped := 0
# Unlock mode
var held_from := Vector2i(-1, -1)  ## Tile whose pipe is picked up.
var held_piece := -1               ## Pipe item in hand (see Pieces.item), -1 = empty hand.
# Milestone powers (earned every POWER_AWARD_ROWS rows)
var freezes := 0                   ## Flow-freeze charges.
var reveals := 0                   ## Reveal charges.
var freeze_timer := 0.0            ## Time left on a running freeze.
var freeze_started := -100.0       ## Game time the current freeze began.
var _next_award_row := Tuning.POWER_AWARD_ROWS
var flips := 0
var drops := 0                     ## Pipes put down this run (unlock mode).
# Hold to speed up: a press that lasts HOLD_DELAY (finger, mouse button or F).
var hold_down := false
var hold_since := 0.0
var hold_key := false
var ai_hold := false               ## The AI player is "holding" the screen.
# AI player and first-run walkthrough
var ai: AIPlayer
var tutorial: Tutorial
var tutorial_pending := false      ## Show the walkthrough at the next run (first game ever).
var ai_used := false               ## The AI played part of this run: no best score.

# Layout, in virtual pixels (720 on the short side).
var view_size := Vector2(720, 720)
var portrait := false
var hud_h := 0.0           ## Height of a top bar (none: the stats live in the side panel).
var T := 64.0
var px_scale := 1.0        ## Physical pixels per virtual pixel (window stretch).
var board_rect := Rect2()
var queue_rect := Rect2()
var stats_rect := Rect2()    ## Height and score, inside the panel.
var freeze_rect := Rect2()   ## Milestone power buttons (shown while playing).
var ai_rect := Rect2()       ## The AI SOLVE toggle, below the power buttons.
var reveal_rect := Rect2()
var _slots: Array = []

# Pointer / keyboard cursor
var hover := Vector2i(-1, -1)
var hover_active := false
var kb_cursor := Vector2i(Tuning.SOURCE_COL, 1)
var kb_active := false

# Debug flags: add ?fps / ?autoplay to the web URL (or --fps / --autoplay after "--" on the command line).
var debug_fps := false
var debug_autoplay := false
var debug_powers := false   ## ?powers: start each run with 3 Flow-freezes and 3 Reveals.
var _fps_timer := 0.0


func _ready() -> void:
	rng.randomize()
	sfx = Sfx.new()
	add_child(sfx)
	atlas = SpriteAtlas.new()
	add_child(atlas)
	renderer = BoardRenderer.new()
	renderer.game = self
	renderer.atlas = atlas
	if Tuning.PS1_MODE:
		_build_world_viewport()
		renderer.overlay_parent = self
		world_vp.add_child(renderer)
	else:
		add_child(renderer)
	input_handler = InputHandler.new()
	input_handler.game = self
	add_child(input_handler)
	ui = GameUI.new()
	ui.game = self
	add_child(ui)
	best = SaveData.load_best(difficulty)
	ai = AIPlayer.new()
	ai.game = self
	add_child(ai)
	tutorial = Tutorial.new()
	tutorial.game = self
	ui.root.add_child(tutorial)
	tutorial_pending = not SaveData.load_flag("tutorial_done")
	_read_debug_flags()
	if debug_autoplay:
		tutorial_pending = false
	_compute_layout()
	new_board(rng.randi())
	state = State.TITLE
	ui.show_title(best)


## PS1 mode: the board renders into a low-resolution viewport that is scaled up
## with nearest-neighbour sampling and run through the 15-bit dither shader.
## The HUD and menus stay on the full-resolution screen so text stays readable.
func _build_world_viewport() -> void:
	world_vp = SubViewport.new()
	world_vp.disable_3d = true
	world_vp.gui_disable_input = true
	world_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	world_vp.size_2d_override_stretch = true
	add_child(world_vp)
	world_view = TextureRect.new()
	world_view.texture = world_vp.get_texture()
	world_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	world_view.stretch_mode = TextureRect.STRETCH_SCALE
	world_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	world_view.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR if Tuning.SMOOTH_EDGES else CanvasItem.TEXTURE_FILTER_NEAREST
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scripts/ps1_screen.gdshader")
	mat.set_shader_parameter("levels", Tuning.PS1_COLOR_LEVELS)
	mat.set_shader_parameter("dither", Tuning.PS1_DITHER)
	world_view.material = mat
	add_child(world_view)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and (state == State.COUNTDOWN or state == State.RUNNING) and not paused:
		toggle_pause()


# --- run lifecycle ------------------------------------------------------------------

func new_board(seed_value: int) -> void:
	grid.clear()
	gen.reset(seed_value)
	gen.unlock_mode = mode == "unlock"
	gen.tutorial_start = tutorial_pending and mode == "unlock"
	_clear_hand()
	freezes = Tuning.START_POWERS
	reveals = Tuning.START_POWERS
	freeze_timer = 0.0
	freeze_started = -100.0
	_next_award_row = Tuning.POWER_AWARD_ROWS
	flips = 0
	drops = 0
	hold_down = false
	hold_key = false
	ai_hold = false
	flow.reset()
	if renderer:
		renderer.clear_fx()
		renderer.invalidate_rows()
	score = 0
	height = 0
	fast_forward = false
	lock_timer = 0.0
	queue_shift = 0.0
	zone_index = 0
	spill = {}
	spill_timer = 0.0
	new_best = false
	last_reason = ""
	countdown = Tuning.COUNTDOWN_TIME
	_beeped = 0
	queue.clear()
	for i in Tuning.QUEUE_SIZE:
		queue.append(_random_piece())
	cam.visible_rows = board_rect.size.y / T if T > 0.0 else Tuning.MIN_VISIBLE_ROWS
	cam.snap(0.5, 0)
	_ensure_rows()
	kb_cursor = Vector2i(Tuning.SOURCE_COL, 1)
	kb_active = false


## Start a run. `diff` picks the difficulty ("easy", "medium", "hard"); empty keeps the last one.
func start_run(diff := "") -> void:
	if diff != "" and Tuning.DIFFICULTY_SPEED.has(diff):
		difficulty = diff
	best = SaveData.load_best(difficulty)
	new_board(rng.randi())
	if debug_powers:
		freezes = 3
		reveals = 3
	paused = false
	state = State.COUNTDOWN
	if ai != null and ai.enabled:
		ai.set_enabled(false)
	ai_used = false
	ui.show_play()
	sfx.play("click")
	if tutorial_pending and mode == "unlock":
		tutorial.start()


func go_to_title() -> void:
	paused = false
	if ai != null and ai.enabled:
		ai.set_enabled(false)
	if tutorial != null:
		tutorial.stop()
	new_board(rng.randi())
	state = State.TITLE
	ui.show_title(best)


func _start_flow() -> void:
	countdown = 0.0
	flow.begin(grid, Tuning.SOURCE_COL, 0, Pieces.S, _goo_color())
	state = State.RUNNING
	sfx.play("go")
	ui.show_toast("PUMP ON!", Color("8fd8ff"))


func _random_piece() -> int:
	var total := 0
	for w in Tuning.PIECE_WEIGHTS:
		total += w
	var p := 0
	for attempt in 2:
		var x := rng.randi_range(0, total - 1)
		for i in Tuning.PIECE_WEIGHTS.size():
			x -= Tuning.PIECE_WEIGHTS[i]
			if x < 0:
				p = i
				break
		# Avoid three of the same piece in a row.
		var n := queue.size()
		if not (n >= 2 and Pieces.item_piece(queue[n - 1]) == p and Pieces.item_piece(queue[n - 2]) == p):
			break
	return Pieces.item(p, rng.randf() < Tuning.NARROW_CHANCE)


# --- frame update --------------------------------------------------------------------

func _process(dt: float) -> void:
	dt = minf(dt, 0.05)
	time += dt
	_compute_layout()
	if not paused:
		match state:
			State.COUNTDOWN, State.RUNNING:
				_update_play(dt)
			State.SPILL:
				_update_spill(dt)
		renderer.update_fx(dt)
		queue_shift = maxf(0.0, queue_shift - dt * 7.0)
		var head := flow.head_world() if (flow.active or state == State.SPILL or state == State.GAMEOVER) \
				else Vector2(Tuning.SOURCE_COL + 0.5, 0.5)
		cam.update(dt, head.y, grid.floor_row)
	_ensure_rows()
	if debug_autoplay:
		_autoplay_step()
	if debug_fps:
		_fps_timer += dt
		if _fps_timer >= 2.0:
			_fps_timer = 0.0
			print("FPS %d | process %.2f ms | draw calls %d | primitives %d | height %d | score %d | state %s | rows in memory %d" % [
					Engine.get_frames_per_second(), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
					Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
					Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
					height, score, State.keys()[state], grid.row_count()])
	renderer.redraw()
	ui.refresh()


func _update_play(dt: float) -> void:
	lock_timer = maxf(0.0, lock_timer - dt)
	_check_hand()
	if state == State.COUNTDOWN:
		if tutorial.active:
			return  # The pump waits while the walkthrough is on.
		countdown -= dt * (Tuning.HOLD_SPEED_MULT if speed_held() else 1.0)
		var n := int(ceil(countdown))
		if n <= 3 and n >= 1 and n != _beeped:
			_beeped = n
			sfx.play("beep")
		if countdown <= 0.0:
			_start_flow()
		return
	if freeze_timer > 0.0:
		freeze_timer -= dt
		if randf() < 0.6:
			renderer.snow(1)
		if freeze_timer <= 0.0:
			freeze_timer = 0.0
			sfx.play("thaw")
			renderer.thaw_drips()
	var amount := dt * effective_speed() / Tuning.BASE_SEGMENT_TIME
	for e in flow.advance(grid, amount, _goo_color()):
		grid.touch(e["row"])
		_handle_event(e)
		if state != State.RUNNING:
			break


func _update_spill(dt: float) -> void:
	spill_timer -= dt
	if randf() < 0.5:
		renderer.burst(spill["p"], spill["col"], 2, 2.2, 0.06, 0.8, 9.0)
	if spill_timer <= 0.0:
		state = State.GAMEOVER
		ui.show_game_over(REASONS.get(last_reason, "The water spilled."), score, height, best, new_best, difficulty)


func _ensure_rows() -> void:
	var floor_r := maxi(0, height - Tuning.KEEP_ROWS_BELOW)
	if floor_r > grid.floor_row:
		grid.discard_below(floor_r)
		gen.forget_below(floor_r)
	var top := int(ceil(cam.y + cam.visible_rows)) + Tuning.GENERATE_AHEAD
	top = maxi(top, height + Tuning.GENERATE_AHEAD)
	gen.generate_until(grid, top)


# --- rules & scoring ---------------------------------------------------------------------

func height_speed() -> float:
	return minf(Tuning.MAX_SPEED, 1.0 + height * Tuning.SPEEDUP_PER_ROW)


func effective_speed() -> float:
	var s := height_speed() * float(Tuning.DIFFICULTY_SPEED.get(difficulty, 1.0))
	if speed_held():
		s *= Tuning.HOLD_SPEED_MULT
	if fast_forward:
		s *= Tuning.FAST_FORWARD_MULT
	if freeze_timer > 0.0:
		return 0.0
	return s


## The score is simple: +SCORE_TUBE for every tube the water fills (a cross
## filled both ways is two tubes) and +SCORE_ROW for every new row it reaches.
## No multipliers or bonuses.
func add_points(n: int) -> void:
	score += n


func _goo_color() -> Color:
	return Zones.theme_for_row(flow.row if flow.active else 0)["goo"]


func _handle_event(e: Dictionary) -> void:
	match e["type"]:
		"enter":
			var r: int = e["row"]
			if r > height:
				_set_height(r)
				var zi := Zones.index_for_row(height)
				if zi > zone_index:
					zone_index = zi
					ui.show_banner(Zones.title(zi))
					sfx.play("zone")
			var t: Tile = e["tile"]
			var wp := Vector2(e["col"] + 0.5, e["row"] + 0.5)
			if t.narrow:
				renderer.float_text(wp, "SLOW", Color("e8c020"), 0.28, 0.8)
		"filled":
			var t: Tile = e["tile"]
			if t.kind == Tile.SOURCE:
				return
			add_points(Tuning.SCORE_TUBE)
			sfx.play("tick", 0.92 + randf() * 0.16 + minf(0.5, height * 0.004), -5.0)
		"blocked":
			_game_over(e)


## New best height: +SCORE_ROW per new row, and the milestone powers every 100 rows.
func _set_height(r: int) -> void:
	if r > height:
		add_points((r - height) * Tuning.SCORE_ROW)
	height = r
	while height >= _next_award_row:
		freezes += 1
		reveals += 1
		ui.show_toast("ROW %d!  +1 FLOW-FREEZE  +1 REVEAL" % _next_award_row, Color("8fe8ff"))
		sfx.play("powerup", 0.8)
		renderer.float_text(flow.head_world(), "+FREEZE  +REVEAL", Color("bff0ff"), 0.36, 1.6)
		_next_award_row += Tuning.POWER_AWARD_ROWS


## Flow-freeze: every pipe frosts over and the water stops for FREEZE_TIME.
func use_freeze() -> bool:
	if freezes <= 0 or state != State.RUNNING or paused or freeze_timer > 0.0:
		sfx.play("deny")
		return false
	freezes -= 1
	freeze_timer = Tuning.FREEZE_TIME
	freeze_started = time
	sfx.play("freeze")
	cam.add_shake(0.2)
	renderer.snow(40)
	ui.show_toast("FLOW FROZEN", Color("bff0ff"))
	ui.flash(Color(0.85, 0.97, 1.0, 0.45))
	buzz(60)
	return true


## Reveal: unlock every tile on the current map, in a wave from the bottom.
func use_reveal() -> bool:
	if reveals <= 0 or (state != State.COUNTDOWN and state != State.RUNNING) or paused:
		sfx.play("deny")
		return false
	# Only what's on screen: from the row at the bottom edge to the (partly
	# visible) row at the top edge. Rows further up stay closed.
	var base := floori(cam.y)
	var lo := maxi(grid.floor_row, base)
	var hi := mini(grid.top_row, floori(cam.y + cam.visible_rows))
	var count := 0
	for r in range(lo, hi + 1):
		var any := false
		for c in Tuning.COLS:
			var t := grid.get_tile(c, r)
			if t == null or not t.hidden:
				continue
			t.hidden = false
			t.flip_at = time + maxf(0.0, r - base) * 0.045 + c * 0.012
			any = true
			count += 1
		if any:
			grid.touch(r)
			renderer.animate_row(r, time + maxf(0.0, r - base) * 0.045 + 0.1 + Tuning.FLIP_TIME + 0.05)
	if count == 0:
		ui.show_toast("Nothing on screen to reveal", Color("8fa3ab"))
		sfx.play("deny")
		return false
	reveals -= 1
	sfx.play("reveal")
	ui.show_toast("REVEALED", Color("ffd86a"))
	return true


func _game_over(e: Dictionary) -> void:
	state = State.SPILL
	spill_timer = 1.5
	last_reason = e["reason"]
	var v: Vector2i = Pieces.DIR_VEC[e["exit"]]
	var p := Vector2(e["col"] + 0.5, e["row"] + 0.5) + Vector2(v.x, v.y) * 0.5
	var col := _goo_color()
	spill = {"p": p, "t": time, "col": col, "seed": randf() * TAU}
	cam.add_shake(0.85)
	sfx.play("gameover")
	buzz(250)
	renderer.burst(p, col, 44, 5.0, 0.09, 1.2, 8.0)
	fast_forward = false
	freeze_timer = 0.0
	_clear_hand()
	if score > best and not ai_used:
		best = score
		new_best = true
		SaveData.save_best(best, difficulty)


# --- placement ------------------------------------------------------------------------------

func screen_to_tile(pos: Vector2) -> Vector2i:
	return Vector2i(floori((pos.x - board_rect.position.x) / T), floori(cam.y + (board_rect.end.y - pos.y) / T))


func is_tile_visible(c: int, r: int) -> bool:
	if c < 0 or c >= Tuning.COLS or r < grid.floor_row or r > grid.top_row:
		return false
	var cy := board_rect.end.y - (r + 0.5 - cam.y) * T
	return cy >= board_rect.position.y and cy <= board_rect.end.y


## What clicking tile (c, r) would do. Classic: place, replace, locked or no.
## Unlock: flip, pick, drop, deselect or no.
func placement_mode(c: int, r: int) -> String:
	var t := grid.get_tile(c, r)
	if t == null or not is_tile_visible(c, r):
		return "no"
	if mode == "unlock":
		return _unlock_action(t, c, r)
	if t.kind != Tile.EMPTY or t.has_goo() or t.fixed:
		return "no"
	if lock_timer > 0.0:
		return "locked"
	return "replace" if t.piece >= 0 else "place"


func try_place(c: int, r: int) -> String:
	if (state != State.COUNTDOWN and state != State.RUNNING) or paused:
		return "inactive"
	if mode == "unlock":
		return _unlock_click(c, r)
	var action := placement_mode(c, r)
	var t := grid.get_tile(c, r)
	var wp := Vector2(c + 0.5, r + 0.5)
	if action == "place" or action == "replace":
		grid.touch(r)
		renderer.animate_row(r, time + 0.45)
	match action:
		"place", "replace":
			t.set_item(queue.pop_front())
			queue.append(_random_piece())
			queue_shift = 1.0
			t.placed_at = time
			if action == "replace":
				lock_timer = Tuning.REPLACE_LOCK_TIME
				sfx.play("replace")
				renderer.burst(wp, Color(0.8, 0.8, 0.8), 10, 2.5, 0.06, 0.5, 3.0, false)
			else:
				sfx.play("place", 0.95 + randf() * 0.1)
				renderer.burst(wp, Color(1, 1, 1, 0.7), 6, 1.5, 0.05, 0.35, 0.0, false)
		"locked":
			sfx.play("deny")
			ui.show_toast("LOCKED!", Color("ff6a5a"))
		_:
			sfx.play("deny")
	return action


# --- unlock mode (BioShock-style) -------------------------------------------------------------

func _unlock_action(t: Tile, c: int, r: int) -> String:
	if t.hidden:
		return "flip"
	if held_piece >= 0:
		if Vector2i(c, r) == held_from:
			return "deselect"
		if t.is_slot() or t.is_loose():
			return "drop"
		return "no"
	if t.is_loose():
		return "pick"
	return "no"


## Unlock a tile, pick a pipe up, or drop the pipe in hand (swapping with
## whatever is there).
func _unlock_click(c: int, r: int) -> String:
	var t := grid.get_tile(c, r)
	if t == null or not is_tile_visible(c, r):
		sfx.play("deny")
		return "no"
	var action := _unlock_action(t, c, r)
	var wp := Vector2(c + 0.5, r + 0.5)
	match action:
		"flip":
			t.hidden = false
			t.flip_at = time
			flips += 1
			grid.touch(r)
			renderer.animate_row(r, time + Tuning.FLIP_TIME + 0.05)
			sfx.play("flip", 0.9 + randf() * 0.2)
			renderer.burst(wp, Color(0.8, 0.85, 0.9), 8, 2.0, 0.05, 0.4, 2.0, false)
		"pick":
			held_from = Vector2i(c, r)
			held_piece = t.get_item()
			sfx.play("pick")
		"deselect":
			_clear_hand()
			sfx.play("click")
		"drop":
			drops += 1
			var src: Tile = grid.get_tile(held_from.x, held_from.y) if held_from.x >= 0 else null
			var old := t.get_item()
			t.set_item(held_piece)
			t.placed_at = time
			grid.touch(r)
			renderer.animate_row(r, time + 0.45)
			if src != null:
				src.set_item(old)
				if old >= 0:
					src.placed_at = time
				grid.touch(held_from.y)
				renderer.animate_row(held_from.y, time + 0.45)
			_clear_hand()
			sfx.play("place", 0.95 + randf() * 0.1)
			renderer.burst(wp, Color(1, 1, 1, 0.7), 6, 1.5, 0.05, 0.35, 0.0, false)
		_:
			sfx.play("deny")
	return action


func _clear_hand() -> void:
	held_from = Vector2i(-1, -1)
	held_piece = -1


## Drop the hand if the picked-up pipe scrolled away, got goo, or changed.
func _check_hand() -> void:
	if held_piece < 0 or held_from.x < 0:
		return
	var t := grid.get_tile(held_from.x, held_from.y)
	if t == null or not t.is_loose() or t.get_item() != held_piece or not is_tile_visible(held_from.x, held_from.y):
		_clear_hand()


# --- input entry points ---------------------------------------------------------------------

func on_pointer_move(pos: Vector2, touch := false) -> void:
	hover = screen_to_tile(pos)
	hover_active = not touch and board_rect.has_point(pos) and is_tile_visible(hover.x, hover.y)
	if not touch:
		kb_active = false


## Hold to speed up: any press that lasts HOLD_DELAY speeds the water while held.
func on_hold(pressed: bool) -> void:
	if pressed and not hold_down:
		hold_since = time
	hold_down = pressed


func on_hold_key(pressed: bool) -> void:
	if pressed and not hold_key:
		hold_since = time
	hold_key = pressed


func speed_held() -> bool:
	if (state != State.COUNTDOWN and state != State.RUNNING) or paused:
		return false
	return ai_hold or ((hold_down or hold_key) and time - hold_since >= Tuning.HOLD_DELAY)


## The AI SOLVE button: hand the board to the AI player, or take it back.
func toggle_ai() -> void:
	if (state != State.COUNTDOWN and state != State.RUNNING) or mode != "unlock":
		return
	ai.set_enabled(not ai.enabled)
	_clear_hand()
	if ai.enabled:
		ai_used = true
		if tutorial.active:
			tutorial.finish()
		ui.show_toast("AI IS PLAYING", Color("9dff8a"))
	else:
		ui.show_toast("YOUR TURN", Color.WHITE)
	sfx.play("click")


func on_pointer_press(pos: Vector2, touch := false) -> void:
	if state != State.COUNTDOWN and state != State.RUNNING or paused:
		return
	if ai.enabled:
		return  # The AI has the board; its button hands it back.
	if not board_rect.has_point(pos):
		return
	var cell := screen_to_tile(pos)
	hover = cell
	hover_active = not touch and is_tile_visible(cell.x, cell.y)
	try_place(cell.x, cell.y)


func move_cursor(dx: int, dy: int) -> void:
	if (state != State.COUNTDOWN and state != State.RUNNING) or paused:
		return
	if not kb_active:
		kb_active = true
		if hover_active:
			kb_cursor = hover
		elif flow.active:
			kb_cursor = Vector2i(flow.col, flow.row + 1)
		else:
			kb_cursor = Vector2i(Tuning.SOURCE_COL, 1)
	else:
		kb_cursor += Vector2i(dx, dy)
	hover_active = false
	var lo := maxi(grid.floor_row, ceili(cam.y + 0.01))
	var hi := floori(cam.y + cam.visible_rows - 0.51)
	kb_cursor.x = clampi(kb_cursor.x, 0, Tuning.COLS - 1)
	kb_cursor.y = clampi(kb_cursor.y, lo, maxi(lo, hi))


func on_confirm() -> void:
	match state:
		State.TITLE, State.GAMEOVER:
			start_run()
		State.COUNTDOWN, State.RUNNING:
			if paused:
				toggle_pause()
			elif ai.enabled:
				return
			elif kb_active:
				try_place(kb_cursor.x, kb_cursor.y)
			else:
				move_cursor(0, 0)


func restart_key() -> void:
	if state == State.TITLE or state == State.GAMEOVER or paused:
		start_run()


func toggle_pause() -> void:
	if state != State.COUNTDOWN and state != State.RUNNING:
		return
	paused = not paused
	ui.show_pause(paused)
	sfx.play("click")


func toggle_mute() -> void:
	sfx.set_muted(not sfx.muted)
	sfx.play("click")


func activate_fast_forward() -> void:
	if (state != State.COUNTDOWN and state != State.RUNNING) or paused or fast_forward:
		return
	fast_forward = true
	if state == State.COUNTDOWN:
		_start_flow()
	sfx.play("ff")
	ui.show_toast("FAST-FORWARD!", Color("ffd23a"))


# --- layout -----------------------------------------------------------------------------------

## The power buttons stay on screen for the whole run (dimmed when empty).
func powers_shown() -> bool:
	return state == State.COUNTDOWN or state == State.RUNNING


## 0..1 strength of the freeze effect: frosts in fast, thaws over the last second.
func freeze_amount() -> float:
	if freeze_timer <= 0.0:
		return 0.0
	return clampf((time - freeze_started) / 0.35, 0.0, 1.0) * clampf(freeze_timer / 1.0, 0.0, 1.0)


func buzz(ms: int) -> void:
	if is_touch:
		Input.vibrate_handheld(ms)


func queue_slot_rects() -> Array:
	return _slots


## Snap to whole physical pixels.
func _px(v: float) -> float:
	return roundf(v * px_scale) / px_scale


func _compute_layout() -> void:
	var win := get_window()
	if win != null and win.size.x > 0:
		# Pick the virtual resolution from the screen's real (logical) size, so
		# phones get a smaller base and therefore bigger text and buttons.
		var ds := DisplayServer.screen_get_scale()
		var logical := minf(win.size.x, win.size.y) / (ds if ds > 0.0 else 1.0)
		var base := clampi(int(logical), Tuning.UI_BASE_MIN, Tuning.UI_BASE_MAX)
		if win.content_scale_size != Vector2i(base, base):
			win.content_scale_size = Vector2i(base, base)
	view_size = get_viewport_rect().size
	if world_vp != null:
		# Render the board at PS1_SHORT_SIDE lines (never above the screen's own pixels).
		var phys := Vector2(win.size) if win != null and win.size.x > 0 else view_size
		if phys.x < view_size.x * 0.5:
			phys = view_size  # Headless / not-yet-sized window: use the virtual size.
		var k := minf(1.0, Tuning.PS1_SHORT_SIDE / minf(phys.x, phys.y))
		var target := Vector2i(maxi(16, roundi(phys.x * k)), maxi(16, roundi(phys.y * k)))
		if world_vp.size != target:
			world_vp.size = target
		if world_vp.size_2d_override != Vector2i(view_size):
			world_vp.size_2d_override = Vector2i(view_size)
		if world_view.size != view_size:
			world_view.position = Vector2.ZERO
			world_view.size = view_size
		px_scale = float(world_vp.size.x) / view_size.x
	else:
		px_scale = float(win.size.x) / view_size.x if win != null and win.size.x > 0 and view_size.x > 0.0 else 1.0
	is_touch = DisplayServer.is_touchscreen_available()
	var min_rows := Tuning.MIN_VISIBLE_ROWS if view_size.y >= 600.0 else Tuning.MIN_VISIBLE_ROWS_COMPACT
	portrait = view_size.x < view_size.y * 0.9
	hud_h = 0.0  # No top bar: height and score sit in the side panel.
	_slots = []
	var n := Tuning.QUEUE_SIZE
	var unlock := mode == "unlock"
	if portrait:
		# Board on top, a control bar along the bottom:
		# [hand / queue] [height + score] [freeze] [reveal]
		var bottom_h := clampf(view_size.y * 0.2, 164.0, 214.0)
		var avail_w := view_size.x - 40.0
		var avail_h := view_size.y - bottom_h
		T = _tile_size(minf(avail_w / Tuning.COLS, avail_h / min_rows))
		var bw := T * Tuning.COLS
		board_rect = Rect2(_px((view_size.x - bw) * 0.5), 0.0, bw, _px(view_size.y - bottom_h))
		queue_rect = Rect2(8.0, board_rect.end.y + 6.0, view_size.x - 16.0, bottom_h - 14.0)
		var s0 := minf(queue_rect.size.y - 34.0, 88.0)
		# Power buttons: big thumb targets at the right end of the bar.
		var bar_h := queue_rect.size.y - 24.0
		var pw := minf(bar_h * 0.78, 120.0)
		reveal_rect = Rect2(queue_rect.end.x - 12.0 - pw, queue_rect.position.y + 12.0, pw, bar_h)
		freeze_rect = Rect2(reveal_rect.position.x - 14.0 - pw, reveal_rect.position.y, pw, bar_h)
		var x := queue_rect.position.x + 14.0
		var y := queue_rect.position.y + 24.0 + maxf(0.0, (queue_rect.size.y - 34.0 - s0) * 0.5)
		_slots.append(Rect2(x, y, s0, s0))
		x += s0 + 12.0
		if not unlock:
			# Classic: the next pieces in a 2 x 2 block beside the first one.
			var s1 := (s0 - 6.0) * 0.5
			for i in n - 1:
				_slots.append(Rect2(x + (i % 2) * (s1 + 6.0), y + (i / 2) * (s1 + 6.0), s1, s1))
			x += s0 + 12.0
		var mid_w := maxf(0.0, freeze_rect.position.x - 10.0 - x)
		var ai_h := 32.0
		stats_rect = Rect2(x, queue_rect.position.y + 8.0, mid_w, queue_rect.size.y - 20.0 - ai_h)
		ai_rect = Rect2(x, stats_rect.end.y + 6.0, mid_w, ai_h)
	else:
		# Board on the left, a panel on the right:
		# HAND (or the queue), height + score, then the power buttons.
		var panel_w := clampf(view_size.x * 0.2, 150.0, 260.0)
		var avail_w := view_size.x - panel_w - 80.0
		T = _tile_size(minf(avail_w / Tuning.COLS, view_size.y / min_rows))
		var bw := T * Tuning.COLS
		var total := bw + 30.0 + panel_w
		var x0 := _px((view_size.x - total) * 0.5)
		board_rect = Rect2(x0, 0.0, bw, _px(view_size.y))
		queue_rect = Rect2(board_rect.end.x + 30.0, 12.0, panel_w, view_size.y - 24.0)
		var tall := view_size.y >= 600.0
		var cx := queue_rect.get_center().x
		var y := queue_rect.position.y + 40.0
		# Power buttons: two big full-width buttons at the bottom of the panel.
		var ph := 112.0 if tall else 60.0
		var ai_h := 46.0 if tall else 38.0
		var bottom := queue_rect.end.y - 12.0
		ai_rect = Rect2(queue_rect.position.x + 12.0, bottom - ai_h, panel_w - 24.0, ai_h)
		bottom = ai_rect.position.y - 12.0
		reveal_rect = Rect2(queue_rect.position.x + 12.0, bottom - ph, panel_w - 24.0, ph)
		freeze_rect = Rect2(reveal_rect.position.x, reveal_rect.position.y - 16.0 - ph, panel_w - 24.0, ph)
		var stats_h := 136.0 if tall else 100.0
		var slots_bottom := freeze_rect.position.y - 10.0 - stats_h - 16.0
		if unlock:
			var s0 := minf(minf(panel_w - 40.0, 150.0), slots_bottom - y)
			_slots.append(Rect2(cx - s0 * 0.5, y, s0, s0))
			y += s0 + 16.0
		elif tall:
			# The next piece on top, the rest stacked below it.
			var avail := slots_bottom - y - (n - 1) * 10.0 - 14.0
			var s0 := minf(panel_w - 40.0, avail / (1.0 + (n - 1) * 0.58))
			var s1 := s0 * 0.58
			_slots.append(Rect2(cx - s0 * 0.5, y, s0, s0))
			y += s0 + 14.0
			for i in n - 1:
				_slots.append(Rect2(cx - s1 * 0.5, y, s1, s1))
				y += s1 + 10.0
			y += 6.0
		else:
			# Short screen (phone held sideways): the next piece, then one row of the rest.
			var gap := 6.0
			var s1 := (panel_w - 24.0 - gap * (n - 2)) / (n - 1)
			var s0 := minf(panel_w - 40.0, slots_bottom - y - s1 - 10.0)
			_slots.append(Rect2(cx - s0 * 0.5, y, s0, s0))
			y += s0 + 10.0
			var x := queue_rect.position.x + 12.0
			for i in n - 1:
				_slots.append(Rect2(x, y, s1, s1))
				x += s1 + gap
			y += s1 + 16.0
		stats_rect = Rect2(queue_rect.position.x + 10.0, y, panel_w - 20.0, stats_h)
	cam.visible_rows = board_rect.size.y / T
	if atlas != null:
		atlas.ensure(roundi(T * px_scale), roundi((_slots[0] as Rect2).size.x * 0.86 * px_scale))


## A tile size that is a whole number of physical pixels, so atlas sprites stay crisp.
func _tile_size(t: float) -> float:
	return maxf(8.0, floorf(t * px_scale)) / px_scale


# --- test hooks -------------------------------------------------------------------------------

func _read_debug_flags() -> void:
	var qs := ""
	if OS.has_feature("web"):
		var q = JavaScriptBridge.eval("window.location.search", true)
		qs = str(q) if q != null else ""
	for arg in OS.get_cmdline_user_args():
		qs += " " + arg
	debug_fps = qs.contains("fps")
	debug_autoplay = qs.contains("autoplay")
	debug_powers = qs.contains("powers")


## Autoplay: a perfect player that lays the guaranteed path just ahead of the goo.
func _autoplay_step() -> void:
	match state:
		State.TITLE, State.GAMEOVER:
			start_run()
			activate_fast_forward()
		State.COUNTDOWN, State.RUNNING:
			if mode == "unlock":
				_autoplay_unlock()
				return
			var r0 := flow.row if flow.active else 0
			for r in range(maxi(1, r0 - 1), r0 + 6):
				var need: Dictionary = gen.spine_needs.get(r, {})
				for c in need:
					var t := grid.get_tile(c, r)
					if t != null and t.is_free():
						debug_set_piece(c, r, Pieces.piece_for(need[c][0], need[c][1]))


func debug_set_piece(c: int, r: int, piece: int) -> void:
	var t := grid.get_tile(c, r)
	if t != null and t.kind == Tile.EMPTY and not t.has_goo():
		t.set_item(piece)
		t.placed_at = time
		grid.touch(r)
		renderer.animate_row(r, time + 0.45)


## Autoplay in unlock mode: unlock the rows ahead, then swap the needed pipes
## onto the guaranteed path, through the same clicks a player makes.
func _autoplay_unlock() -> void:
	_clear_hand()
	var r0 := flow.row if flow.active else 0
	for r in range(maxi(1, r0 - 1), r0 + 5):
		if not is_tile_visible(0, r):
			continue
		for c in Tuning.COLS:
			var t := grid.get_tile(c, r)
			if t != null and t.hidden:
				_unlock_click(c, r)
		var need: Dictionary = gen.spine_needs.get(r, {})
		for c in need:
			var t := grid.get_tile(c, r)
			var want := Pieces.piece_for(need[c][0], need[c][1])
			if t == null or t.fixed or t.has_goo() or t.piece == want:
				continue
			for c2 in Tuning.COLS:
				var s2 := grid.get_tile(c2, r)
				if c2 == c or s2 == null or not s2.is_loose() or s2.piece != want:
					continue
				if need.has(c2) and Pieces.piece_for(need[c2][0], need[c2][1]) == want:
					continue
				_unlock_click(c2, r)
				_unlock_click(c, r)
				break
