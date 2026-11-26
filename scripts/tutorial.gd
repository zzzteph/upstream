## ============================================================================
##  TUTORIAL - the short walkthrough on the very first game.
## ============================================================================
## A coach panel at the top of the board says what to do next, and a pulsing
## frame with a bouncing arrow points at it: open a hatch, pick a pipe up, put
## it down, hold to speed up, the two powers, and the AI SOLVE button. Each
## step waits for the player to actually do it (or tap OK); SKIP ends it. The
## pump's countdown waits while it runs. Once finished (or skipped) it never
## shows again (SaveData flag "tutorial_done").
class_name Tutorial
extends Control

enum Step { OPEN, PICK, DROP, SPEED, POWERS, AI }

const HAZARD := Color("ffc928")

var game  ## The Game node (main.gd).
var active := false
var step := Step.OPEN

var _panel: PanelContainer
var _text: Label
var _ok: Button
var _skip: Button
var _flips0 := 0
var _drops0 := 0
var _held_for := 0.0
var _t := 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_panel = PanelContainer.new()
	var sb: StyleBoxFlat = game.ui._box(Color(0.09, 0.12, 0.15, 0.96), HAZARD, 12, 3, 6)
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
	_skip = game.ui._button("SKIP", func(): finish(), 110)
	_ok = game.ui._button("OK", func(): _next(), 110)
	for b in [_skip, _ok]:
		b.custom_minimum_size = Vector2(110, 44)
		b.add_theme_font_size_override("font_size", 20)
		hb.add_child(b)


func start() -> void:
	active = true
	visible = true
	_go(Step.OPEN)


## Leave without marking it done (e.g. back to the menu mid-way).
func stop() -> void:
	active = false
	visible = false


## Done or skipped: never show it again.
func finish() -> void:
	active = false
	visible = false
	game.tutorial_pending = false
	SaveData.save_flag("tutorial_done")


func _next() -> void:
	match step:
		Step.SPEED:
			_go(Step.POWERS)
		Step.POWERS:
			_go(Step.AI)
		Step.AI:
			finish()
			game.ui.show_toast("GOOD LUCK!", HAZARD)


func _go(s: int) -> void:
	step = s
	_flips0 = game.flips
	_drops0 = game.drops
	_held_for = 0.0
	_ok.visible = s == Step.SPEED or s == Step.POWERS or s == Step.AI
	_ok.text = "LET'S GO" if s == Step.AI else "OK"
	_skip.visible = s != Step.AI
	_update_text()


func _update_text() -> void:
	var tap := "Tap" if game.is_touch else "Click"
	var hold := "Hold your finger on the screen" if game.is_touch else "Hold the mouse button (or F)"
	var txt := ""
	match step:
		Step.OPEN:
			txt = "%s a steel hatch to open it." % tap
		Step.PICK:
			if _nearest(func(t: Tile): return t.is_loose()).x < 0:
				txt = "No pipe yet. Open more hatches to find one."
			else:
				txt = "%s a pipe to pick it up." % tap
		Step.DROP:
			txt = "Now %s an empty slot to put it there. Lay pipe up from the pump!" % tap.to_lower()
		Step.SPEED:
			txt = "%s to speed the water up. Let go to slow down." % hold
		Step.POWERS:
			txt = "FREEZE stops the water for a few seconds. REVEAL opens every hatch on screen."
		Step.AI:
			txt = "Stuck? AI SOLVE plays for you. %s it again to take over." % tap
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
	match step:
		Step.OPEN:
			if game.flips > _flips0:
				_go(Step.PICK)
		Step.PICK:
			if game.held_piece >= 0:
				_go(Step.DROP)
			else:
				_update_text()
		Step.DROP:
			if game.drops > _drops0:
				_go(Step.SPEED)
			elif game.held_piece < 0:
				_go(Step.PICK)
		Step.SPEED:
			if game.speed_held():
				_held_for += dt
				if _held_for > 0.6:
					_go(Step.POWERS)
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
	var cell := Vector2i(-1, -1)
	match step:
		Step.OPEN:
			cell = _nearest(func(t: Tile): return t.hidden)
		Step.PICK:
			cell = _nearest(func(t: Tile): return t.is_loose())
			if cell.x < 0:
				cell = _nearest(func(t: Tile): return t.hidden)
		Step.DROP:
			var above: Tile = game.grid.get_tile(Tuning.SOURCE_COL, 1)
			if above != null and above.is_slot():
				cell = Vector2i(Tuning.SOURCE_COL, 1)
			else:
				cell = _nearest(func(t: Tile): return t.is_slot())
		Step.SPEED:
			var b: Rect2 = game.board_rect
			return Rect2(b.get_center() - Vector2(40, 40), Vector2(80, 80))
		Step.POWERS:
			return game.freeze_rect.merge(game.reveal_rect)
		Step.AI:
			return game.ai_rect
	if cell.x < 0:
		return Rect2()
	return game.renderer.tile_rect(cell.x, cell.y)


func _draw() -> void:
	if not active:
		return
	var r := target_rect()
	if r.size.x <= 0.0:
		return
	var pulse := 0.5 + 0.5 * sin(_t * 6.0)
	var g := r.grow(4.0 + 4.0 * pulse)
	draw_rect(g, Color(0, 0, 0, 0.6), false, 7.0)
	draw_rect(g, PipeArt.fade(HAZARD, 0.65 + 0.35 * pulse), false, 4.0)
	if step == Step.SPEED:
		# A finger pressing, with rings spreading out.
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
