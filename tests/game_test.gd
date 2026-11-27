## Integration test: drives the real main scene through input events.
## Run from the project folder (fixed fps makes it deterministic and fast):
##   godot --headless --fixed-fps 60 --script res://tests/game_test.gd
extends SceneTree

const P := preload("res://scripts/pieces.gd")

var game
var failures := 0
var checks := 0
var proc_times: Array = []


func _initialize() -> void:
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	_run.call_deferred()


func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		push_error("FAIL: " + msg)
		print("FAIL: ", msg)


func frames(n: int) -> void:
	for i in n:
		await process_frame
		proc_times.append(Performance.get_monitor(Performance.TIME_PROCESS))


func click(pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = pos
	ev.global_position = pos
	root.push_input(ev, true)
	var up := ev.duplicate()
	up.pressed = false
	root.push_input(up, true)


func press_at(pos: Vector2, down := true) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = down
	ev.position = pos
	ev.global_position = pos
	root.push_input(ev, true)


func key_state(k: int, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.pressed = down
	root.push_input(ev, true)


func key(k: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.pressed = true
	root.push_input(ev, true)
	var up := ev.duplicate()
	up.pressed = false
	root.push_input(up, true)


func tile_center(c: int, r: int) -> Vector2:
	return game.renderer.tile_rect(c, r).get_center() - game.cam.offset


## Keep the spine laid just ahead of the goo (the "perfect player").
func lay_spine_ahead(rows_ahead := 6) -> void:
	var r0: int = game.flow.row
	for r in range(maxi(1, r0 - 1), r0 + rows_ahead):
		if not game.gen.spine_needs.has(r):
			continue
		var need: Dictionary = game.gen.spine_needs[r]
		for c in need:
			var t: Tile = game.grid.get_tile(c, r)
			if t != null and t.is_free():
				game.debug_set_piece(c, r, P.piece_for(need[c][0], need[c][1]))


func _run() -> void:
	await frames(3)
	game.tutorial_pending = false  # The walkthrough has its own test below.
	var S = game.State
	# The classic (piece queue) mode is tested first; unlock mode further down.
	game.mode = "classic"
	game.go_to_title()
	await frames(1)
	check(game.state == S.TITLE, "starts on the title screen")
	check(game.ui.title_screen.visible, "title overlay visible")

	# --- the menu: best score, NEW GAME and a small SOLVER; clicking elsewhere does nothing ---
	var screen := Rect2(Vector2.ZERO, game.view_size)
	var ng: Button = game.ui.new_game_button
	var wa: Button = game.ui.solver_button
	check(ng.is_visible_in_tree() and screen.encloses(ng.get_global_rect()) and ng.text == "NEW GAME", "the menu shows NEW GAME on screen")
	check(wa.is_visible_in_tree() and screen.encloses(wa.get_global_rect()) and wa.get_global_rect().position.y >= ng.get_global_rect().end.y
			and wa.size.x < ng.size.x and wa.text == "SOLVER", "a smaller SOLVER button sits under it")
	check(not "difficulty_buttons" in game.ui and not "difficulty" in game, "no difficulty levels")
	check(not (load("res://scripts/station_logo.gd") as Script).get_script_constant_map().has("SUBTITLE"), "the nameplate has no subtitle")
	var logo_top: float = game.ui.logo.get_global_rect().position.y
	check(game.ui.best_label.is_visible_in_tree() and game.ui.best_label.get_global_rect().end.y <= logo_top
			and game.ui.best_label.text == "%d" % SaveData.load_best(), "the best score is shown above UPSTREAM")
	click(Vector2(game.view_size.x * 0.06, game.view_size.y * 0.5))
	await frames(1)
	check(game.state == S.TITLE, "clicking beside the buttons does not start a game")
	click(game.ui.new_game_button.get_global_rect().get_center())
	await frames(2)
	check(game.state == S.COUNTDOWN and not game.ai.enabled, "NEW GAME starts the countdown, with you playing")
	check(not game.ui.title_screen.visible, "title hidden")
	check(game.countdown > 9.0, "10 second countdown")

	# --- place a piece by clicking a tile ---
	var next: int = game.queue[0]
	var second: int = game.queue[1]
	click(tile_center(3, 1))
	await frames(1)
	var t31: Tile = game.grid.get_tile(3, 1)
	check(t31.get_item() == next, "click places the next queued piece")
	check(game.queue[0] == second and game.queue.size() == Tuning.QUEUE_SIZE, "queue advances and refills")

	# --- replacing costs a short lock (and no points) ---
	game.score = 500
	click(tile_center(3, 1))
	await frames(1)
	check(game.score == 500, "replacing costs no points")
	check(game.lock_timer > 0.9, "replace locks the queue")
	var before: int = game.grid.get_tile(4, 1).piece
	click(tile_center(4, 1))
	await frames(1)
	check(game.grid.get_tile(4, 1).piece == before, "placing is blocked while locked")
	await frames(65)
	check(game.lock_timer == 0.0, "lock wears off after 1s")
	click(tile_center(4, 1))
	await frames(1)
	check(game.grid.get_tile(4, 1).piece >= 0, "placing works again after the lock")

	# --- off-screen tiles can't be used ---
	var top_row := int(game.cam.y + game.cam.visible_rows) + 2
	check(game.try_place(2, top_row) == "no", "tiles above the screen are not placeable")

	# --- pause, mute ---
	key(KEY_P)
	await frames(1)
	check(game.paused and game.ui.pause_screen.visible, "P pauses")
	var cd: float = game.countdown
	await frames(30)
	check(game.countdown == cd, "countdown frozen while paused")
	key(KEY_ESCAPE)
	await frames(1)
	check(not game.paused, "Esc resumes")
	var pb: Button = game.ui.btn_pause
	check(pb.is_visible_in_tree() and Rect2(Vector2.ZERO, game.view_size).encloses(pb.get_global_rect())
			and not pb.get_global_rect().intersects(game.board_rect) and pb.get_global_rect().end.y <= (game.queue_slot_rects()[0] as Rect2).position.y + 0.5,
			"a pause button sits in the panel, above the hand")
	click(pb.get_global_rect().get_center())
	await frames(1)
	check(game.paused and game.ui.pause_screen.visible, "the pause button pauses the game")
	var labels := []
	for b in game.ui.pause_screen.find_children("*", "Button", true, false):
		labels.append((b as Button).text)
	check(labels == ["RESUME", "RESTART", "MAIN MENU"], "the pause menu is just RESUME, RESTART, MAIN MENU (got %s)" % [labels])
	var cd_p: float = game.countdown
	await frames(30)
	check(game.countdown == cd_p, "nothing moves while paused")
	game.toggle_pause()
	await frames(1)
	check(not game.paused, "RESUME carries on")
	key(KEY_M)
	await frames(1)
	check(game.sfx.muted, "M mutes")
	key(KEY_M)
	await frames(1)
	check(not game.sfx.muted, "M unmutes")

	# --- keyboard placement ---
	key(KEY_LEFT)
	key(KEY_SPACE)
	await frames(1)
	check(game.kb_active, "arrow keys show the keyboard cursor")

	# --- countdown runs out, goo starts ---
	game.go_to_title()
	await frames(1)
	key(KEY_ENTER)
	await frames(1)
	check(game.state == S.COUNTDOWN, "Enter starts from the title")
	await frames(int(Tuning.COUNTDOWN_TIME * 60) + 5)
	check(game.state == S.RUNNING and game.flow.active, "goo starts after the countdown")

	# --- the cross loop in the safe rows: +1 per tube (both cross passes), nothing per row ---
	game.start_run()
	await frames(1)
	for spec in [[3, 1, P.V], [3, 2, P.CROSS], [3, 3, P.SE], [4, 3, P.SW], [4, 2, P.NW], [2, 2, P.NE], [2, 3, P.V], [2, 4, P.V]]:
		game.debug_set_piece(spec[0], spec[1], spec[2])
	var above: Tile = game.grid.get_tile(2, 5)  # Make sure the loop ends on an empty tile.
	above.kind = Tile.EMPTY
	above.clear_pipe()
	game.activate_fast_forward()
	await frames(1)
	check(game.state == S.RUNNING and game.fast_forward, "fast-forward (debug) during countdown starts the flow")
	var waited := 0
	while game.state == S.RUNNING and waited < 2000:
		await frames(1)
		waited += 1
	var cross: Tile = game.grid.get_tile(3, 2)
	check(cross.fill[0] == 1.0 and cross.fill[1] == 1.0, "cross filled both ways in game")
	check(game.height == 4, "the loop climbs to row 4 (got %d)" % game.height)
	var want: int = 9 * Tuning.SCORE_TUBE
	check(Tuning.SCORE_TUBE == 1 and not (load("res://scripts/tuning.gd") as Script).get_script_constant_map().has("SCORE_ROW"), "scoring is +1 per tube, nothing per row")
	check(game.score == want, "loop score: 9 tubes x1 = %d; rows and fast-forward add nothing (got %d)" % [want, game.score])
	check(game.last_reason == "empty", "spills on the empty tile (got %s)" % game.last_reason)
	await frames(100)
	check(game.state == S.GAMEOVER and game.ui.over_screen.visible, "game over screen shows")
	var again_ok := false
	for b in game.ui.over_screen.find_children("*", "Button", true, false):
		again_ok = again_ok or (b as Button).text == "PLAY AGAIN"
	check(again_ok, "the game-over button reads PLAY AGAIN (no key hint)")
	check(not game.fast_forward, "fast-forward ends at game over")
	key(KEY_R)
	await frames(1)
	check(game.state == S.COUNTDOWN, "R plays again")

	# --- a long perfect run: zones, speed-up, memory ---
	game.start_run()
	await frames(1)
	game.activate_fast_forward()
	var peak_rows := 0
	var zones_seen := {}
	var guard := 0
	var target := 165
	while game.state == S.RUNNING and game.height < target and guard < 60000:
		lay_spine_ahead()
		await frames(1)
		guard += 1
		peak_rows = maxi(peak_rows, game.grid.row_count())
		zones_seen[game.zone_index] = true
	check(game.height >= target, "perfect play climbs to row %d (reached %d, %s)" % [target, game.height, game.last_reason])
	check(zones_seen.size() >= 4, "passed through 4 zones (%d)" % zones_seen.size())
	var top_z := -100000
	for v in game.renderer.row_views.values():
		top_z = maxi(top_z, v.z_index)
	check(top_z > 0 and top_z < game.renderer.live_base.z_index,
			"high up, the board rows still draw under the water's tile and the effects (row z %d < %d)" % [top_z, game.renderer.live_base.z_index])
	check(Zones.title(1) == "ZONE 2" and Zones.title(300) == "ZONE 255", "zone banners are just numbers, up to ZONE 255")
	# flow.segments also counts the pump itself, which scores nothing.
	check(game.score == (game.flow.segments - 1) * Tuning.SCORE_TUBE, "score is exactly the tubes filled, nothing per row (height %d, score %d, tubes %d)" % [game.height, game.score, game.flow.segments - 1])
	check(game.height_speed() > 2.0, "flow speeds up with height (%.2fx)" % game.height_speed())
	var h_was: int = game.height
	for spec in [[0, 1.0], [400, 4.5], [800, 8.0], [1200, 8.0]]:
		game.height = spec[0]
		check(is_equal_approx(game.height_speed(), spec[1]), "speed rises evenly to 8x at row 800: row %d -> %.2fx (got %.2fx)" % [spec[0], spec[1], game.height_speed()])
	game.height = h_was
	check(peak_rows <= Tuning.KEEP_ROWS_BELOW + 40, "rows in memory stay bounded (peak %d)" % peak_rows)
	check(game.grid.floor_row > 100, "old rows discarded (floor at %d)" % game.grid.floor_row)
	print("long run: height %d, score %d" % [game.height, game.score])

	# Stop laying pipe: the run must end on its own.
	guard = 0
	while game.state == S.RUNNING and guard < 3000:
		await frames(1)
		guard += 1
	check(game.state == S.SPILL or game.state == S.GAMEOVER, "run ends once pipes run out")
	await frames(120)
	check(game.state == S.GAMEOVER, "game over after the spill")
	check(game.best >= game.score, "best score kept")
	check(SaveData.load_best() == game.best, "best score saved")

	# --- unlock mode (BioShock-style) ---
	game.mode = "unlock"
	game.rng.seed = 2024  # A fixed board, so rows 1-3 surely hold both pipes and empty slots.
	game.start_run()
	await frames(1)
	check(game.state == S.COUNTDOWN, "unlock mode starts")
	var hidden_ok := true
	for r in range(1, 5):
		for c in Tuning.COLS:
			if not game.grid.get_tile(c, r).hidden:
				hidden_ok = false
	check(hidden_ok, "unlock mode: tiles start locked")
	click(tile_center(3, 1))
	await frames(1)
	check(not game.grid.get_tile(3, 1).hidden and game.flips == 1, "clicking a locked tile unlocks it")
	for r in range(1, 4):
		for c in Tuning.COLS:
			if game.grid.get_tile(c, r).hidden:
				click(tile_center(c, r))
	await frames(1)
	var src := Vector2i(-1, -1)
	var dst := Vector2i(-1, -1)
	for r in range(1, 4):
		for c in Tuning.COLS:
			var t: Tile = game.grid.get_tile(c, r)
			if src.x < 0 and t.is_loose():
				src = Vector2i(c, r)
			elif dst.x < 0 and t.is_slot():
				dst = Vector2i(c, r)
	check(src.x >= 0 and dst.x >= 0, "unlocked rows hold pipes and open spots")
	if src.x >= 0 and dst.x >= 0:
		var piece: int = game.grid.get_tile(src.x, src.y).get_item()
		click(tile_center(src.x, src.y))
		await frames(1)
		check(game.held_piece == piece and game.held_from == src, "clicking a pipe picks it up")
		click(tile_center(src.x, src.y))
		await frames(1)
		check(game.held_piece == -1, "clicking it again puts it back")
		click(tile_center(src.x, src.y))
		click(tile_center(dst.x, dst.y))
		await frames(1)
		check(game.grid.get_tile(dst.x, dst.y).get_item() == piece and game.grid.get_tile(src.x, src.y).piece == -1 and game.held_piece == -1,
				"clicking an open spot moves the pipe there")
	# A narrow pipe stays narrow when it is moved.
	var nsrc: Tile = game.grid.get_tile(1, 1)
	var ndst: Tile = game.grid.get_tile(5, 1)
	for t in [nsrc, ndst]:
		t.hidden = false
		t.kind = Tile.EMPTY
		t.fixed = false
		t.special = Tile.SP_NONE
	nsrc.set_item(P.item(P.V, true))
	ndst.set_item(-1)
	game.grid.touch(1)
	click(tile_center(1, 1))
	click(tile_center(5, 1))
	await frames(1)
	check(ndst.piece == P.V and ndst.narrow and not nsrc.narrow and nsrc.piece == -1, "a narrow pipe stays narrow when moved")
	check(not "alarm" in Tile.new() and not "surge_timer" in game, "no alarm traps (and no surges)")
	# Goo meets a locked tile.
	game.start_run()
	await frames(1)
	game.grid.get_tile(3, 1).hidden = true
	game.activate_fast_forward()
	guard = 0
	while game.state == S.RUNNING and guard < 2000:
		await frames(1)
		guard += 1
	check(game.last_reason == "locked", "goo reaching a locked tile spills (got %s)" % game.last_reason)
	await frames(120)
	check(game.state == S.GAMEOVER and not game.ui.over_reason.visible, "no message on the game-over screen for a closed block")
	# A long unlock-mode run, played by the autoplay bot through the same clicks.
	game.start_run()
	game.debug_autoplay = true
	guard = 0
	while game.height < 120 and guard < 40000:
		await frames(1)
		guard += 1
		if game.state == S.GAMEOVER:
			break
	game.debug_autoplay = false
	check(game.height >= 120, "unlock mode: autoplay climbs to row 120 (reached %d, %s)" % [game.height, game.last_reason])
	print("unlock run: height %d, score %d, flips %d" % [game.height, game.score, game.flips])

	# --- one speed for everyone; one best score ---
	game.start_run()
	await frames(1)
	game._start_flow()
	check(is_equal_approx(game.effective_speed(), game.height_speed()), "the water runs at the base speed (no difficulty multiplier)")
	check(game.freezes == Tuning.START_POWERS and game.reveals == Tuning.START_POWERS, "the run starts with one Flow-freeze and one Reveal")
	check(game.ui.btn_freeze.visible and game.ui.btn_reveal.visible, "power buttons are there from the start")
	check(SaveData.KEY == "upstream_score_medium", "the best score keeps the old Medium record")
	game.ui.show_game_over("", 10, 1, 20, false)
	check(game.ui.over_best.text == "BEST  20", "game over shows the best score")
	game.ui.over_screen.visible = false

	# --- height and score sit in the side panel; no top bar ---
	await frames(2)
	check(game.board_rect.position.y == 0.0, "no top bar: the board starts at the top of the screen")
	check(game.queue_rect.encloses(game.stats_rect), "the stats area is inside the panel")
	for k in ["HEIGHT", "SCORE"]:
		var lr: Rect2 = (game.ui.stat_values[k] as Label).get_global_rect()
		check(game.queue_rect.encloses(lr) and not lr.intersects(game.board_rect), "%s value sits in the panel" % k)
	game.score = 4321
	await frames(1)
	check((game.ui.stat_values["SCORE"] as Label).text == "4321", "the panel shows the score")

	# --- milestone powers: one of each to start, then another pair every 100 rows ---
	game.mode = "unlock"
	game.start_run()
	await frames(2)
	game._set_height(100)
	check(game.freezes == 2 and game.reveals == 2, "row 100 gives one more Flow-freeze and Reveal")
	game._set_height(250)
	check(game.freezes == 3 and game.reveals == 3, "row 200 gives another pair")
	# Use them on a fresh board (jumping the height to 250 above dropped the pump's rows).
	game.start_run()
	game.freezes = 2
	game.reveals = 2
	await frames(2)
	check(game.ui.btn_freeze.visible and game.ui.btn_reveal.visible, "power buttons are shown while you have charges")
	check(screen.encloses(game.ui.btn_freeze.get_global_rect()) and screen.encloses(game.ui.btn_reveal.get_global_rect()), "power buttons are fully on screen")
	check(game.freeze_rect.size.y >= 56.0 and game.freeze_rect.size.x >= 120.0 and not game.freeze_rect.intersects(game.reveal_rect),
			"power buttons are big (%s) and don't overlap" % game.freeze_rect.size)
	click(game.ui.btn_reveal.get_global_rect().get_center())
	await frames(1)
	var lo_r: int = maxi(game.grid.floor_row, floori(game.cam.y))
	var hi_r: int = floori(game.cam.y + game.cam.visible_rows)
	var still_hidden := 0
	for r in range(lo_r, hi_r + 1):
		for c in Tuning.COLS:
			if game.grid.get_tile(c, r).hidden:
				still_hidden += 1
	var above_hidden := 0
	for r in range(hi_r + 1, game.grid.top_row + 1):
		for c in Tuning.COLS:
			if game.grid.get_tile(c, r).hidden:
				above_hidden += 1
	check(still_hidden == 0 and game.reveals == 1, "Reveal opens every block on screen (%d still closed)" % still_hidden)
	check(game.grid.top_row > hi_r and above_hidden == (game.grid.top_row - hi_r) * Tuning.COLS,
			"Reveal leaves the rows above the screen closed (%d of %d)" % [above_hidden, (game.grid.top_row - hi_r) * Tuning.COLS])
	game._start_flow()
	await frames(20)
	click(game.ui.btn_freeze.get_global_rect().get_center())
	await frames(1)
	check(game.freeze_timer > 0.0 and game.freezes == 1, "the freeze button starts a Flow-freeze")
	await frames(30)
	check(game.ui.btn_freeze.progress > 0.8 and game.ui.btn_freeze.progress < 1.0 and is_equal_approx(game.ui.btn_freeze.progress, game.freeze_timer / Tuning.FREEZE_TIME),
			"the Freeze button fills with ice that drains as the freeze runs out (%.2f)" % game.ui.btn_freeze.progress)
	check(game.ui.btn_freeze.text == "" and game.ui.btn_reveal.text == "" and not "draw_freeze_icon" in game.ui.btn_freeze,
			"Freeze and Reveal are plain text buttons")
	var frozen_at := [game.flow.row, game.flow.col, game.flow.progress]
	await frames(60)
	check([game.flow.row, game.flow.col, game.flow.progress] == frozen_at and game.effective_speed() == 0.0, "the water stands still while frozen")
	key(KEY_Q)
	await frames(1)
	check(game.freezes == 1, "a second freeze can't stack on a running one")
	game.freeze_timer = 0.05
	await frames(10)
	check(game.freeze_timer == 0.0 and [game.flow.row, game.flow.col, game.flow.progress] != frozen_at,
			"the water flows again after the freeze (timer %.2f, flow %s -> %s, state %s, paused %s)" % [game.freeze_timer, frozen_at, [game.flow.row, game.flow.col, game.flow.progress], game.state, game.paused])
	key(KEY_Q)
	await frames(1)
	check(game.freezes == 0 and game.freeze_timer > 0.0, "Q uses the next freeze charge")

	# --- smooth on any phone: quality steps down when frames are slow ---
	game.start_run()
	await frames(1)
	game._start_flow()
	game.set_quality(0)
	for i in 60:
		game._govern(1.0 / 60.0)
	check(game.quality == 0, "60 frames a second keeps full quality")
	for i in 100:
		game._govern(1.0 / 30.0)
	check(game.quality == 1, "3 s of slow frames (30 a second) drop the decorations (quality %d)" % game.quality)
	for i in 100:
		game._govern(1.0 / 30.0)
	check(game.quality == 2, "still slow: the board renders at a lower resolution too (quality %d)" % game.quality)
	game.set_quality(0)
	game.toggle_pause()
	for i in 200:
		game._govern(1.0 / 20.0)
	game.toggle_pause()
	for i in 20:
		game._govern(0.5)
	check(game.quality == 0, "pauses and one-off hitches (switching tabs) don't count")
	var lt := Tile.new()
	for pc in P.COUNT:
		lt.piece = pc
		check(SpriteAtlas.dry_sprite_for(lt) >= 0, "the live tile stamps the dry pipe from the atlas (piece %d)" % pc)
	game.set_quality(0)

	# --- the walkthrough talks the way you play ---
	game.pointer_kind = "touch"
	game.used_keys = false
	check(game.touch_ui(), "after a tap it talks about fingers")
	game.pointer_kind = "mouse"
	check(not game.touch_ui(), "after a click it talks about the mouse")
	game.note_input("touch")
	check(game.touch_ui(), "a tap switches it back")
	game.pointer_kind = ""
	game.used_keys = false

	# --- hold to speed up ---
	game.mode = "unlock"
	game.start_run()
	await frames(1)
	game._start_flow()
	var spot := Vector2(game.board_rect.position.x + 10.0, game.board_rect.end.y - 10.0)
	press_at(spot)
	await frames(2)
	check(not game.speed_held(), "a quick press doesn't speed anything up")
	await frames(22)
	check(not game.speed_held(), "nor does a slow click (0.4 s)")
	await frames(int(Tuning.HOLD_DELAY * 60.0) + 4)
	check(game.speed_held() and is_equal_approx(game.effective_speed(), game.height_speed() * Tuning.HOLD_SPEED_MULT),
			"holding the screen speeds the water up x%d" % int(Tuning.HOLD_SPEED_MULT))
	check(game.ui.speed_badge.visible, "a FAST badge shows while holding")
	press_at(spot, false)
	await frames(1)
	check(not game.speed_held() and is_equal_approx(game.effective_speed(), game.height_speed()), "letting go slows it back down")
	var tube := Tile.new()
	tube.piece = P.V
	var sc0: int = game.score
	game._handle_event({"type": "filled", "tile": tube, "col": 0, "row": 1, "channel": 0})
	check(game.score - sc0 == Tuning.SCORE_TUBE, "a tube scores +1 normally")
	# A fresh run: holding at x4 above has nearly brought the water to a hatch.
	game.start_run()
	await frames(1)
	game._start_flow()
	press_at(spot)
	await frames(int(Tuning.HOLD_DELAY * 60.0) + 4)
	sc0 = game.score
	game._handle_event({"type": "filled", "tile": tube, "col": 0, "row": 1, "channel": 0})
	check(game.score - sc0 == Tuning.SCORE_TUBE * 2, "the first tube scores 2x while you hold to speed up")
	check(is_equal_approx(game.effective_speed(), game.height_speed() * 4.4) and is_equal_approx(game.hold_score_mult(), 2.2),
			"every tube you hold through adds 10%%: x4.4 speed, 2.2x points (got x%.2f, %.2fx)" % [game.effective_speed() / game.height_speed(), game.hold_score_mult()])
	sc0 = game.score
	for i in 30:
		game._handle_event({"type": "filled", "tile": tube, "col": 0, "row": 1, "channel": 0})
	await frames(1)
	check(is_equal_approx(game.effective_speed(), game.height_speed() * 8.0) and is_equal_approx(game.hold_score_mult(), 4.0),
			"it tops out at x8 speed and 4x points (x%.2f, %.2fx)" % [game.effective_speed() / game.height_speed(), game.hold_score_mult()])
	# Tubes 2-10 pay 2.2 ... 3.8 (27 in all, plus 0.0 carried), then 21 more at 4.
	check(game.score - sc0 == 27 + 21 * 4, "points per tube rise 2.2, 2.4 ... up to 4 (got %d)" % (game.score - sc0))
	check(game.ui.speed_badge.visible and game.ui.speed_badge._texts() == ["FAST x8", "x4 POINTS"], "the FAST badge shows the current multipliers")
	press_at(spot, false)
	await frames(1)
	check(game.hold_tubes == 0 and is_equal_approx(game.hold_speed_mult(), Tuning.HOLD_SPEED_MULT), "letting go resets the ramp: the next hold starts at x4 again")
	key_state(KEY_F, true)
	await frames(int(Tuning.HOLD_DELAY * 60.0) + 4)
	check(game.speed_held(), "holding F does the same on a keyboard")
	key_state(KEY_F, false)
	await frames(1)
	check(not game.speed_held(), "releasing F slows it back down")
	game.start_run()
	await frames(1)
	var cd0: float = game.countdown
	press_at(spot)
	await frames(60)
	press_at(spot, false)
	check(cd0 - game.countdown > 2.0, "holding during the countdown runs it faster (%.1fs in 1s)" % (cd0 - game.countdown))

	# --- first-run walkthrough, on a prepared board ---
	var tut = game.tutorial
	game.tutorial_pending = true
	game.start_run()
	await frames(2)
	check(tut.active and tut.visible, "the walkthrough starts on the first game")
	check(not tut._ok.visible, "no buttons on the doing-steps: you do the thing")
	var slot_t: Tile = game.grid.get_tile(3, 1)
	var pipe_t: Tile = game.grid.get_tile(2, 1)
	check(slot_t.hidden and slot_t.piece < 0 and pipe_t.hidden and pipe_t.piece == P.V and not pipe_t.narrow
			and game.gen.spine_needs[1].has(3) and game.gen.spine_needs[1][3] == [P.S, P.N],
			"the first board is prepared: an empty slot above the pump, a straight pipe next to it, the way up goes straight")
	var cd1: float = game.countdown
	await frames(60)
	check(game.countdown == cd1, "the pump waits while the walkthrough is on")
	check(tut.sub == "open" and tut.target_rect() == game.renderer.tile_rect(3, 1), "walkthrough 1: it points at the hatch above the pump")
	click(tut.target_rect().get_center())
	await frames(1)
	check(not slot_t.hidden and tut.sub == "next" and tut.target_rect() == game.renderer.tile_rect(2, 1), "walkthrough 2: that hatch was empty, and it points at the one next to it")
	click(tut.target_rect().get_center())
	await frames(1)
	check(not pipe_t.hidden and tut.sub == "pick" and tut.target_rect() == game.renderer.tile_rect(2, 1), "walkthrough 3: it was a straight pipe, and it says to pick it up")
	# Picking up a pipe that won't fit: it says to put it back first.
	var wrong: Tile = game.grid.get_tile(4, 1)
	wrong.hidden = false
	wrong.kind = Tile.EMPTY
	wrong.set_item(P.H)
	game.grid.touch(1)
	click(tile_center(4, 1))
	await frames(1)
	check(tut.sub == "putback" and tut.target_rect() == game.renderer.tile_rect(4, 1), "holding a pipe that won't fit: it says to put it back")
	click(tut.target_rect().get_center())
	await frames(1)
	check(game.held_piece < 0 and tut.sub == "pick", "after putting it back it points at the straight pipe again")
	click(tut.target_rect().get_center())
	await frames(1)
	check(game.held_piece >= 0 and tut.sub == "drop" and tut.target_rect() == game.renderer.tile_rect(3, 1), "walkthrough 4: holding it, it points at the spot above the pump")
	click(tut.target_rect().get_center())
	await frames(1)
	check(slot_t.piece == P.V and tut.step == tut.Step.FLOW, "walkthrough 5: the pipe is above the pump")
	click(tut._ok.get_global_rect().get_center())
	await frames(1)
	check(tut.step == tut.Step.SPEED, "walkthrough 6: how to speed up")
	var keys_were: bool = game.used_keys
	game.pointer_kind = "mouse"
	game.used_keys = false
	await frames(1)
	check(tut._text.text.begins_with("Hold the mouse button down to") and not tut._text.text.contains("F key"),
			"on a computer it says the mouse, and no key you haven't used (%s)" % tut._text.text.substr(0, 40))
	game.used_keys = true
	await frames(1)
	check(tut._text.text.contains("(or the F key)"), "once you've used the keyboard it mentions F")
	game.pointer_kind = "touch"
	await frames(1)
	check(tut._text.text.begins_with("Hold your finger on the screen") and not tut._text.text.contains("F key"), "on a phone: your finger, never a key")
	game.pointer_kind = ""
	game.used_keys = keys_were
	press_at(spot)
	await frames(60)
	press_at(spot, false)
	await frames(1)
	check(tut.step == tut.Step.POWERS, "walkthrough 7: holding the screen moves on")
	check(tut._text.text.contains("%d seconds" % int(Tuning.FREEZE_TIME)) and tut._text.text.contains("%d rows" % Tuning.POWER_AWARD_ROWS), "the powers text gives the real numbers")
	check(tut._ok.text == "LET'S GO", "the powers are the last step")
	click(tut._ok.get_global_rect().get_center())
	await frames(1)
	check(not tut.active and not game.tutorial_pending and SaveData.load_flag("tutorial_done"), "walkthrough done, and saved so it won't show again")
	var cd2: float = game.countdown
	await frames(30)
	check(game.countdown < cd2, "the countdown runs again after the walkthrough")
	game._start_flow()
	guard = 0
	while game.state == S.RUNNING and game.flow.row < 2 and guard < 600:
		await frames(1)
		guard += 1
	check(slot_t.fill[0] >= 1.0, "the water really flows up through the pipe placed in the walkthrough")
	game.start_run()
	await frames(1)
	check(not tut.active and not game.gen.tutorial_start, "the next game is a normal, unprepared one")
	check(not "_skip" in tut, "the walkthrough has no SKIP button")

	# --- SOLVER: a bot that plans routes and plays through taps, at a human pace ---
	seed(4242)
	game.rng.seed = 4242
	game.tutorial_pending = true  # A SOLVER game never shows the walkthrough.
	game.go_to_title()
	await frames(1)
	var best_before := SaveData.load_best()
	click(game.ui.solver_button.get_global_rect().get_center())
	await frames(2)
	check(game.state == S.COUNTDOWN and game.ai.enabled and not game.tutorial.active and not game.gen.tutorial_start,
			"SOLVER starts a game the AI plays (no walkthrough, normal board)")
	game.tutorial_pending = false
	click(tile_center(0, 2))
	await frames(1)
	check(game.grid.get_tile(0, 2).hidden, "your taps on the board are ignored while the AI plays")
	guard = 0
	var idle := 0
	var longest_idle := 0
	var last_taps := 0
	while game.state != S.GAMEOVER and game.height < 25 and guard < 60 * 200:
		await frames(1)
		guard += 1
		if game.ai.actions == last_taps and not game.ai_hold:
			idle += 1
			longest_idle = maxi(longest_idle, idle)
		else:
			idle = 0
		last_taps = game.ai.actions
	var secs := guard / 60.0
	check(game.height >= 25, "the AI climbs on its own (row %d after %.0fs, %s)" % [game.height, secs, game.last_reason])
	check(longest_idle < 60 * 3, "it never stalls (longest pause %.1fs)" % (longest_idle / 60.0))
	check(game.ai.actions >= 10 and game.flips > 0 and game.drops > 0, "it plays by tapping: %d taps, %d hatches opened, %d pipes moved" % [game.ai.actions, game.flips, game.drops])
	check(game.ai.actions / maxf(1.0, secs) < 4.0, "at a human pace (%.1f taps a second)" % (game.ai.actions / maxf(1.0, secs)))
	check(int(game.ai.tally.get("hold", 0)) > 0, "it holds the screen to speed up when its route is ready")
	# Rebuild: break a pipe on its route ahead of the water and watch it repair it.
	var broken := Vector2i(-1, -1)
	for tries in 600:
		var lp: Dictionary = game.ai.last_plan
		for cell in lp.get("cells", []):
			var bt: Tile = game.grid.get_tile(cell["v"].x, cell["v"].y)
			if cell["need"] < 0 and cell["arrive"] > 5.0 and cell["arrive"] < 9.0 and bt.is_loose() and game.held_piece < 0:
				broken = cell["v"]
				break
		if broken.x >= 0 or game.state == S.GAMEOVER:
			break
		await frames(1)
	if broken.x >= 0:
		var bt: Tile = game.grid.get_tile(broken.x, broken.y)
		var was: int = bt.piece
		bt.set_item(P.NE if was != P.NE else P.SW)  # A pipe that doesn't fit there.
		game.grid.touch(broken.y)
		var row_then: int = game.height
		guard = 0
		while game.state != S.GAMEOVER and game.height < maxi(row_then, broken.y) + 3 and guard < 60 * 60:
			await frames(1)
			guard += 1
		check(game.state != S.GAMEOVER or game.flow.row > broken.y, "after its route is broken at %s it rebuilds and the water gets past (%s)" % [broken, game.last_reason])
	else:
		check(false, "found a pipe on the AI's route to break")
	if game.state != S.GAMEOVER:
		game.score = best_before + 1000
		game._game_over({"reason": "rock", "col": 3, "row": game.flow.row, "exit": Pieces.N})
		await frames(120)
	check(SaveData.load_best() == best_before, "a run the AI played doesn't set a best score")
	check(game.ui.over_screen.visible and game.actions > 0 and game.ui.over_speed.text == "%.1f ACTIONS PER SECOND" % game.actions_per_second()
			and game.actions_per_second() > 0.5 and game.actions_per_second() < 4.0,
			"the game-over screen shows the average actions per second (%s)" % game.ui.over_speed.text)
	game.play_again()
	await frames(1)
	check(game.ai.enabled, "PLAY AGAIN after a SOLVER game watches again")
	game.go_to_title()
	await frames(1)
	check(not game.ai.enabled, "back on the menu the AI stops")
	game.start_run()
	await frames(1)
	check(not game.ai.enabled, "NEW GAME is yours to play")

	# --- frame cost ---
	var total := 0.0
	var worst := 0.0
	for t in proc_times:
		total += t
		worst = maxf(worst, t)
	print("process time per frame: avg %.2f ms, worst %.2f ms over %d frames" % [total / proc_times.size() * 1000.0, worst * 1000.0, proc_times.size()])
	print("\n%d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
