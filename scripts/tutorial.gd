## ============================================================================
##  TUTORIAL - the short walkthrough on the very first game.
## ============================================================================
## The first game is played on a prepared board (LevelGenerator.tutorial_start):
## the hatch above the pump hides an empty slot and the hatch next to it hides
## the straight pipe that slot needs. So every instruction here is true:
##
##   1. open the hatch above the pump     (it's empty)
##   2. open the hatch next to it         (a straight pipe)
##   3. pick the pipe up
##   4. put it in the slot above the pump (now the water has a way up)
##   5. how the water flows               (OK)
##   6. hold to speed up (more points)    (hold, or OK)
##   7. Freeze and Reveal                 (LET'S GO)
##
## Steps 1-4 follow the board itself, so they stay right whatever the player
## taps in between (a wrong pipe picked up is put back first). A coach panel at
## the top of the board says what to do; everything else is dimmed (a
## spotlight on the target) and a pulsing frame and a bouncing arrow point at
## it. The pump's countdown waits while it runs. Once finished it never shows
## again (SaveData flag "tutorial_done").
class_name Tutorial
extends Control

enum Step { FIRST_PIPE, FLOW, SPEED, POWERS }

const HAZARD := Color("ffc928")
const SHADE := Color(0.0, 0.01, 0.02, 0.66)   ## The dimmed background around the spotlight.
const SLOT := LevelGenerator.TUTORIAL_SLOT
const PIPE := LevelGenerator.TUTORIAL_PIPE

var game  ## The Game node (main.gd).
var active := false
var step := Step.FIRST_PIPE
var sub := ""                    ## Within FIRST_PIPE: "open", "next", "pick", "putback", "drop".

var _panel: PanelContainer
var _text: Label
var _ok: Button
var _held_for := 0.0
var _t := 0.0
var _target := Rect2()


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_panel = PanelContainer.new()
	var sb: StyleBoxFlat = game.ui._box(Color(0.09, 0.12, 0.15, 0.96), HAZARD, 18, 3, 8)
	sb.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	_panel.add_child(vb)
	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_text.add_theme_font_size_override("font_size", 21)
	_text.add_theme_color_override("font_color", Color.WHITE)
	_text.add_theme_constant_override("outline_size", 4)
	vb.add_child(_text)
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_theme_constant_override("separation", 12)
	vb.add_child(hb)
	_ok = game.ui._button("OK", func(): _next(), 110)
	_ok.custom_minimum_size = Vector2(110, 44)
	_ok.add_theme_font_size_override("font_size", 20)
	hb.add_child(_ok)


func start() -> void:
	active = true
	visible = true
	_go(Step.FIRST_PIPE)


## Leave without marking it done (e.g. back to the menu mid-way).
func stop() -> void:
	active = false
	visible = false


## Done: never show it again.
func finish() -> void:
	active = false
	visible = false
	game.tutorial_pending = false
	SaveData.save_flag("tutorial_done")


func _next() -> void:
	match step:
		Step.FLOW:
			_go(Step.SPEED)
		Step.SPEED:
			_go(Step.POWERS)
		Step.POWERS:
			finish()
			game.ui.show_toast("GOOD LUCK!", HAZARD)


func _go(s: int) -> void:
	step = s
	_held_for = 0.0
	_ok.visible = s != Step.FIRST_PIPE
	_ok.text = "LET'S GO" if s == Step.POWERS else "OK"


## The slot above the pump takes the water straight up?
func _slot_done() -> bool:
	var t: Tile = game.grid.get_tile(SLOT.x, SLOT.y)
	return t != null and not t.hidden and t.piece >= 0 and Pieces.exit_dir(t.piece, Pieces.S) == Pieces.N


func _fits_up(item: int) -> bool:
	var p := Pieces.item_piece(item)
	return p == Pieces.V or p == Pieces.CROSS


## Work out where the player is in steps 1-4 from the board itself, and what
## to point at.
func _first_pipe() -> void:
	var slot: Tile = game.grid.get_tile(SLOT.x, SLOT.y)
	var tap := "Tap" if game.touch_ui() else "Click"
	var cell := Vector2i(-1, -1)
	var txt := ""
	if slot == null:
		return
	if slot.hidden:
		sub = "open"
		cell = SLOT
		txt = "The water will come up out of the pump. %s the steel hatch just above it." % tap
	elif game.held_piece >= 0 and not _fits_up(game.held_piece):
		sub = "putback"
		cell = game.held_from
		txt = "That pipe won't take the water up. %s it again to put it back." % tap
	elif game.held_piece >= 0:
		sub = "drop"
		cell = SLOT
		txt = "Now %s the spot above the pump to put the pipe there." % tap.to_lower()
	else:
		var pipe := _nearest(func(t: Tile): return t.is_loose() and _fits_up(t.get_item()) and t != slot)
		if pipe.x >= 0:
			sub = "pick"
			cell = pipe
			txt = "A straight pipe: just what that spot needs. %s it to pick it up." % tap
		else:
			sub = "next"
			var nxt: Tile = game.grid.get_tile(PIPE.x, PIPE.y)
			cell = PIPE if nxt != null and nxt.hidden else _nearest(func(t: Tile): return t.hidden)
			txt = "It's empty, and the water needs a pipe there. Open the hatch next to it."
	_set_text(txt)
	_target = game.renderer.tile_rect(cell.x, cell.y) if cell.x >= 0 else Rect2()


func _set_text(txt: String) -> void:
	if _text.text != txt:
		_text.text = txt


func _process(dt: float) -> void:
	if not active:
		return
	if game.state != game.State.COUNTDOWN and game.state != game.State.RUNNING:
		stop()
		return
	_t += dt
	visible = not game.paused
	var b: Rect2 = game.board_rect
	match step:
		Step.FIRST_PIPE:
			if _slot_done():
				_go(Step.FLOW)
			else:
				_first_pipe()
		Step.FLOW:
			_set_text("That's it! The water flows up through connected pipes. Keep building a way up: if the water reaches a closed hatch, a rock or an open pipe end, the run is over.")
			_target = game.renderer.tile_rect(SLOT.x, SLOT.y).merge(game.renderer.tile_rect(SLOT.x, 0))
		Step.SPEED:
			# Say it the way this player plays: a finger on a phone, the mouse on
			# a computer, and the F key only once they've used the keyboard.
			var hold := "Hold your finger on the screen"
			if not game.touch_ui():
				hold = "Hold the mouse button down (or the F key)" if game.used_keys else "Hold the mouse button down"
			_set_text("%s to speed the water up x%d and score %dx per tube. Keep holding: every tube adds 10%% more, up to x%d speed and %dx points. Let go to slow it down again." % [
					hold, int(Tuning.HOLD_SPEED_MULT), int(Tuning.HOLD_SCORE_MULT), int(Tuning.HOLD_SPEED_MAX), int(Tuning.HOLD_SCORE_MAX)])
			_target = b  # Hold anywhere on the board.
			if game.speed_held():
				_held_for += dt
				if _held_for > 0.4:  # Plus HOLD_DELAY before it counts: about a second in all.
					_go(Step.POWERS)
		Step.POWERS:
			_set_text("FREEZE stops the water for %d seconds. REVEAL opens every hatch on screen. You start with one of each and get another every %d rows." % [int(Tuning.FREEZE_TIME), Tuning.POWER_AWARD_ROWS])
			_target = game.freeze_rect.merge(game.reveal_rect)
	_place_panel()
	queue_redraw()


func _place_panel() -> void:
	var b: Rect2 = game.board_rect
	var w := minf(b.size.x - 24.0, 460.0)
	_text.custom_minimum_size = Vector2(w - 28.0, 0)
	_panel.reset_size()
	var sz := _panel.get_combined_minimum_size()
	_panel.size = Vector2(w, sz.y)
	_panel.position = Vector2(roundf(b.get_center().x - w * 0.5), b.position.y + 14.0)


## The on-screen tile matching `pred` nearest to the pump.
func _nearest(pred: Callable) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_d := INF
	var lo: int = maxi(game.grid.floor_row, floori(game.cam.y))
	var hi: int = floori(game.cam.y + game.cam.visible_rows)
	for r in range(lo, hi + 1):
		for c in Tuning.COLS:
			var t: Tile = game.grid.get_tile(c, r)
			if t == null or not game.is_tile_visible(c, r) or not pred.call(t):
				continue
			var d := absf(c - Tuning.SOURCE_COL) + absf(r - 1) * 1.2
			if d < best_d:
				best_d = d
				best = Vector2i(c, r)
	return best


## What the arrow points at, as a screen rect (empty = nothing).
func target_rect() -> Rect2:
	return _target


func _draw() -> void:
	if not active:
		return
	var r := _target
	var vs: Vector2 = game.view_size
	if r.size.x <= 0.0:
		draw_rect(Rect2(Vector2.ZERO, vs), SHADE)
		return
	# Spotlight: dim everything but the target (the coach panel draws on top).
	var hole := r.grow(6.0).intersection(Rect2(Vector2.ZERO, vs))
	draw_rect(Rect2(0, 0, vs.x, hole.position.y), SHADE)
	draw_rect(Rect2(0, hole.end.y, vs.x, vs.y - hole.end.y), SHADE)
	draw_rect(Rect2(0, hole.position.y, hole.position.x, hole.size.y), SHADE)
	draw_rect(Rect2(hole.end.x, hole.position.y, vs.x - hole.end.x, hole.size.y), SHADE)
	var pulse := 0.5 + 0.5 * sin(_t * 6.0)
	var g := r.grow(4.0 + 4.0 * pulse)
	draw_rect(g, Color(0, 0, 0, 0.6), false, 7.0)
	draw_rect(g, PipeArt.fade(HAZARD, 0.65 + 0.35 * pulse), false, 4.0)
	if step == Step.SPEED:
		# A finger pressing in the middle of the board, with rings spreading out.
		var c := r.get_center()
		for i in 2:
			var k := fposmod(_t * 0.9 + i * 0.5, 1.0)
			draw_arc(c, 18.0 + 40.0 * k, 0.0, TAU, 40, PipeArt.fade(Color.WHITE, 1.0 - k), 3.0, true)
		draw_circle(c, 16.0, Color(1, 1, 1, 0.85))
		return
	# A bouncing arrow above the target, pointing down at it.
	var tip := Vector2(r.get_center().x, g.position.y - 6.0 - 8.0 * pulse)
	var s := 18.0
	var arrow := PackedVector2Array([tip, tip + Vector2(-s, -s), tip + Vector2(-s * 0.4, -s), tip + Vector2(-s * 0.4, -s * 2.2),
			tip + Vector2(s * 0.4, -s * 2.2), tip + Vector2(s * 0.4, -s), tip + Vector2(s, -s)])
	var shadow := PackedVector2Array()
	for p in arrow:
		shadow.append(p + Vector2(2, 3))
	draw_colored_polygon(shadow, Color(0, 0, 0, 0.5))
	draw_colored_polygon(arrow, HAZARD)
	var outline := arrow.duplicate()
	outline.append(arrow[0])
	draw_polyline(outline, Color("1a1a1a"), 2.0, true)
