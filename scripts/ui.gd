## ============================================================================
##  UI - HUD, buttons, banners and the title / pause / game-over screens.
## ============================================================================
class_name GameUI
extends CanvasLayer


## Fill a polygon with smooth edges (a plain polygon has hard, stair-step
## edges; a thin anti-aliased outline in the same colour softens them).
static func smooth_poly(ci: CanvasItem, pts: PackedVector2Array, col: Color) -> void:
	ci.draw_colored_polygon(pts, col)
	var closed := pts.duplicate()
	closed.append(pts[0])
	ci.draw_polyline(closed, col, 1.2, true)


## A HUD button in the same chunky style as the menu buttons: a rounded face
## on a darker base that it sinks onto when pressed. Freeze and Reveal are
## just text - the name and the charges left. While a freeze runs, ice fills
## the Freeze button and drains away as the seconds run out (with the seconds
## left on it), so you can see when the water starts again. Pause shows two
## bars (and PAUSE when there's room).
class HudButton:
	extends Button
	const COLORS := {
		"freeze": [Color("123247"), Color("8fe8ff")],
		"reveal": [Color("3a2b0b"), Color("ffc928")],
		"pause": [Color("2a3640"), Color("3ab4ff")],
	}
	const ICE := Color(0.56, 0.91, 1.0)
	var kind := ""
	var count := 0
	var label := ""
	var progress := 0.0     ## Freeze: share of the freeze still to run (0 = not frozen).
	var seconds := 0.0      ## Freeze: seconds left.
	var _sb := StyleBoxFlat.new()

	func _draw() -> void:
		var bg: Color = COLORS[kind][0]
		var trim: Color = COLORS[kind][1]
		var dm := get_draw_mode()
		var down := dm == DRAW_PRESSED or dm == DRAW_HOVER_PRESSED
		if dm == DRAW_HOVER:
			bg = bg.lightened(0.12)
			trim = trim.lightened(0.2)
		elif down:
			bg = bg.darkened(0.25)
		var base := clampf(size.y * 0.08, 3.0, 6.0)
		var sink := base * 0.7 if down else 0.0
		var rad := int(clampf(minf(size.x, size.y) * 0.22, 8.0, 18.0))
		_sb.anti_aliasing = true
		_sb.draw_center = true
		_sb.set_corner_radius_all(rad)
		_sb.set_border_width_all(0)
		_sb.bg_color = trim.darkened(0.62)
		draw_style_box(_sb, Rect2(0, base, size.x, size.y - base))
		var face := Rect2(0, sink, size.x, size.y - base)
		_sb.bg_color = bg
		_sb.border_color = trim
		_sb.set_border_width_all(3)
		draw_style_box(_sb, face)
		var inner := face.grow(-3.0)
		_sb.set_border_width_all(0)
		if progress > 0.0:
			# Frozen: the ice drains towards the left as the freeze runs out.
			var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.008)
			_sb.set_corner_radius_all(maxi(2, rad - 3))
			_sb.bg_color = PipeArt.fade(ICE, 0.5 + 0.15 * pulse)
			draw_style_box(_sb, Rect2(inner.position, Vector2(maxf(4.0, inner.size.x * progress), inner.size.y)))
			_sb.bg_color = Color(1, 1, 1, 0.18)
			draw_style_box(_sb, Rect2(inner.position, Vector2(maxf(4.0, inner.size.x * progress), inner.size.y * 0.4)))
		# A soft sheen on the top half.
		_sb.set_corner_radius_all(maxi(2, rad - 3))
		_sb.bg_color = Color(1, 1, 1, 0.05)
		draw_style_box(_sb, Rect2(inner.position, Vector2(inner.size.x, inner.size.y * 0.45)))
		var f := PipeArt.font()
		var c := face.get_center()
		if kind == "pause":
			var h := clampf(face.size.y * 0.44, 12.0, 22.0)
			var bw := h * 0.32
			var gap := h * 0.32
			var fs := int(clampf(face.size.y * 0.42, 13.0, 20.0))
			var show_text := face.size.x >= 110.0
			var tw := f.get_string_size("PAUSE", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x if show_text else 0.0
			var x := c.x - (bw * 2.0 + gap + (10.0 + tw if show_text else 0.0)) * 0.5
			_sb.set_corner_radius_all(maxi(1, int(bw * 0.45)))
			_sb.bg_color = Color.WHITE
			for k in 2:
				draw_style_box(_sb, Rect2(x + k * (bw + gap), c.y - h * 0.5, bw, h))
			if show_text:
				_text(f, Vector2(x + bw * 2.0 + gap + 10.0, c.y + fs * 0.36), "PAUSE", fs, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, tw + 4.0)
			return
		var title := label
		var value := "x%d" % count
		var name_col := trim.lightened(0.25)
		if progress > 0.0:
			title = "FROZEN"
			value = "%.1fs" % seconds
			name_col = Color.WHITE
		if face.size.y >= 70.0:
			# Two lines: the name, and the charges (or seconds left) big below it.
			var name_fs := int(clampf(minf(face.size.x * 0.16, face.size.y * 0.2), 13.0, 22.0))
			var val_fs := int(clampf(minf(face.size.x * 0.28, face.size.y * 0.36), 18.0, 40.0))
			var top := c.y - (name_fs + val_fs * 1.05) * 0.5
			_text(f, Vector2(face.position.x, top + name_fs * 0.9), title, name_fs, name_col, HORIZONTAL_ALIGNMENT_CENTER, face.size.x)
			_text(f, Vector2(face.position.x, top + name_fs * 1.05 + val_fs * 0.92), value, val_fs, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, face.size.x)
		else:
			# One line: the name on the left, the charges on the right.
			var fs := int(clampf(minf(face.size.y * 0.36, face.size.x * 0.12), 13.0, 22.0))
			var y := c.y + fs * 0.36
			_text(f, Vector2(inner.position.x + 10.0, y), title, fs, name_col, HORIZONTAL_ALIGNMENT_LEFT, inner.size.x - 20.0)
			_text(f, Vector2(inner.position.x + 10.0, y), value, int(fs * 1.15), Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT, inner.size.x - 20.0)

	func _text(f: Font, pos: Vector2, s: String, fs: int, col: Color, align: int, w: float) -> void:
		draw_string_outline(f, pos, s, align, w, fs, maxi(2, fs / 6), Color(0, 0, 0, 0.8))
		draw_string(f, pos, s, align, w, fs, col)


## A game counter for HEIGHT or SCORE: a rounded steel plate with a coloured
## trim and an icon, and the number in a dark recessed display window. The
## caption and number are Labels placed on top (see _place_stats).
class StatPlate:
	extends Control
	var trim := Color.WHITE
	var icon := "up"            ## "up" (height) or "star" (score).
	var window := Rect2()       ## The number's display window, in local coordinates.
	var icon_at := Vector2.ZERO
	var icon_r := 7.0

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var sb := StyleBoxFlat.new()
		sb.anti_aliasing = true
		sb.bg_color = Color("2a3640")
		sb.border_color = trim.darkened(0.15)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(int(minf(14.0, size.y * 0.3)))
		sb.shadow_color = Color(0, 0, 0, 0.45)
		sb.shadow_size = 4
		sb.shadow_offset = Vector2(0, 3)
		draw_style_box(sb, r)
		draw_line(Vector2(12, 3.5), Vector2(size.x - 12, 3.5), Color(1, 1, 1, 0.14), 2.0)
		# The recessed window: dark, with a shadow along its top edge.
		var w := StyleBoxFlat.new()
		w.anti_aliasing = true
		w.bg_color = Color("0a1015")
		w.border_color = Color(0, 0, 0, 0.7)
		w.border_width_top = 3
		w.set_corner_radius_all(int(minf(9.0, window.size.y * 0.3)))
		draw_style_box(w, window)
		draw_line(Vector2(window.position.x + 8, window.end.y - 1.5), Vector2(window.end.x - 8, window.end.y - 1.5), PipeArt.fade(trim, 0.35), 2.0)
		# Icon.
		var c := icon_at
		var k := icon_r
		if icon == "up":
			GameUI.smooth_poly(self, PackedVector2Array([c + Vector2(0, -k), c + Vector2(k, k * 0.2), c + Vector2(k * 0.35, k * 0.2),
					c + Vector2(k * 0.35, k), c + Vector2(-k * 0.35, k), c + Vector2(-k * 0.35, k * 0.2), c + Vector2(-k, k * 0.2)]), trim)
		else:
			var pts := PackedVector2Array()
			for i in 10:
				pts.append(c + Vector2.from_angle(-PI / 2.0 + i * PI / 5.0) * (k if i % 2 == 0 else k * 0.45))
			GameUI.smooth_poly(self, pts, trim)


## "▶▶ FAST x4.4  x2.2 POINTS" at the top of the board while the water is sped
## up, with a bar along the bottom that fills as the hold ramps up to its max.
class SpeedBadge:
	extends Control
	var game

	static func mult(m: float) -> String:
		return "%d" % roundi(m) if absf(m - roundf(m)) < 0.05 else "%.1f" % m

	func _texts() -> Array:
		return ["FAST x" + mult(game.hold_speed_mult()), "x%s POINTS" % mult(game.hold_score_mult())]

	## The width that fits the text at height h.
	func width_for(h: float) -> float:
		var f := PipeArt.font()
		var fs := int(h * 0.46)
		var t := _texts()
		return h * 0.45 + h * 0.42 * 2.3 + f.get_string_size(t[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 12.0 \
				+ f.get_string_size(t[1], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + h * 0.5

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var gold := Color("ffc928")
		var ramp: float = game.hold_ramp()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.05, 0.07, 0.09, 0.85)
		sb.border_color = gold.lerp(Color.WHITE, 0.5 * ramp)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(int(size.y * 0.5))
		sb.anti_aliasing = true
		draw_style_box(sb, r)
		var h := size.y * 0.42
		var x := size.y * 0.45
		for i in 2:
			var ox := x + i * h * 0.75
			GameUI.smooth_poly(self, PackedVector2Array([Vector2(ox, size.y * 0.5 - h * 0.5), Vector2(ox + h * 0.7, size.y * 0.5),
					Vector2(ox, size.y * 0.5 + h * 0.5)]), gold)
		var f := PipeArt.font()
		var fs := int(size.y * 0.46)
		var tx := x + h * 2.3
		var t := _texts()
		draw_string(f, Vector2(tx, size.y * 0.5 + fs * 0.36), t[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
		var tw := f.get_string_size(t[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(f, Vector2(tx + tw + 12.0, size.y * 0.5 + fs * 0.36), t[1], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, gold)
		# The ramp: fills up over the tubes you keep holding through.
		var track := Rect2(size.y * 0.5, size.y - 6.0, size.x - size.y, 2.5)
		draw_rect(track, Color(1, 1, 1, 0.12))
		if ramp > 0.0:
			draw_rect(Rect2(track.position, Vector2(track.size.x * ramp, track.size.y)), gold.lerp(Color.WHITE, 0.4 * ramp))


var game  ## The Game node (main.gd).
var root: Control
var hud: Control
var stat_values := {}     ## "HEIGHT" / "SCORE" -> value Label.
var stat_captions := {}   ## "HEIGHT" / "SCORE" -> caption Label.
var stat_plates := {}     ## "HEIGHT" / "SCORE" -> StatPlate behind them.
var _stats_key := ""
var btn_freeze: HudButton
var btn_reveal: HudButton
var btn_pause: HudButton
var speed_badge: SpeedBadge
var banner: Label
var toast: Label
var title_screen: Control
var new_game_button: Button
var solver_button: Button      ## Small: starts a game the solver (the AI player) plays.
var best_label: Label         ## The best score on the menu, above the nameplate.
var _title_box: VBoxContainer
var _best_caption: Label
var logo: StationLogo
var pause_screen: Control
var over_screen: Control
var over_reason: Label
var over_score: Label
var over_height: Label
var over_best: Label
var over_speed: Label        ## Actions per second (average taps that did something).
var over_new: Label
var _last_view := Vector2.ZERO
var _last_portrait := false
var _banner_tween: Tween
var _toast_tween: Tween
var _ff_lit := false
var _scaled := []          ## [Label, base font size, base outline] scaled to the screen width.
var _flash: ColorRect
var _badge_key := ""
var _flash_tween: Tween


func _ready() -> void:
	layer = 10
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _make_theme()
	add_child(root)
	_build_hud()
	_build_center_labels()
	_build_title()
	_build_pause()
	_build_over()
	_flash = ColorRect.new()
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.color = Color(1, 0, 0, 0)
	_flash.visible = false  # A full-screen layer: only drawn while it flashes.
	root.add_child(_flash)


# --- theme ------------------------------------------------------------------------------

const STEEL := Color("2a3640")
const STEEL_DARK := Color("161e24")
const STEEL_EDGE := Color("5a6b75")
const WATER := Color("3ab4ff")
const HAZARD := Color("ffc928")


## A steel plate with a rivet in each corner.
class RivetPanel:
	extends PanelContainer

	func _draw() -> void:
		for c in [Vector2(16, 16), Vector2(size.x - 16, 16), Vector2(16, size.y - 16), size - Vector2(16, 16)]:
			draw_circle(c, 4.5, Color("11181d"))
			draw_circle(c - Vector2(1, 1), 2.5, Color("8fa3ab"))


func _box(bg: Color, border: Color, radius := 14, bw := 3, shadow := 6) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = shadow
	sb.shadow_offset = Vector2(0, 3)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	sb.anti_aliasing = true
	return sb


## A chunky game button: rounded, standing on a solid darker base that it
## sinks onto when pressed.
func _btn_box(bg: Color, trim: Color, pressed := false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = trim
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(18)
	sb.anti_aliasing = true
	sb.shadow_color = trim.darkened(0.6)
	sb.shadow_size = 1
	sb.shadow_offset = Vector2(0, 2 if pressed else 6)
	if pressed:
		sb.expand_margin_top = -4.0
		sb.expand_margin_bottom = 4.0
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 12 if pressed else 8
	sb.content_margin_bottom = 4 if pressed else 8
	return sb


## Normal / hover / pressed game-button styles on `b`.
func _style_button(b: Button, bg: Color, trim: Color) -> void:
	b.add_theme_stylebox_override("normal", _btn_box(bg, trim))
	b.add_theme_stylebox_override("hover", _btn_box(bg.lightened(0.12), trim.lightened(0.3)))
	b.add_theme_stylebox_override("pressed", _btn_box(bg.darkened(0.25), trim, true))
	b.add_theme_stylebox_override("hover_pressed", _btn_box(bg.darkened(0.25), trim, true))


func _make_theme() -> Theme:
	var th := Theme.new()
	th.default_font = PipeArt.font()
	th.default_font_size = 22
	th.set_color("font_outline_color", "Label", Color(0, 0, 0, 0.9))
	th.set_constant("outline_size", "Label", 8)
	th.set_color("font_color", "Label", Color.WHITE)
	# Pump-station look: steel plates with water-blue trim.
	th.set_stylebox("normal", "Button", _btn_box(STEEL, WATER))
	th.set_stylebox("hover", "Button", _btn_box(STEEL.lightened(0.1), WATER.lightened(0.35)))
	th.set_stylebox("pressed", "Button", _btn_box(STEEL_DARK, WATER, true))
	th.set_stylebox("hover_pressed", "Button", _btn_box(STEEL_DARK, WATER, true))
	th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	th.set_stylebox("disabled", "Button", _btn_box(Color("333333"), Color("555555")))
	th.set_color("font_color", "Button", Color.WHITE)
	th.set_color("font_hover_color", "Button", Color.WHITE)
	th.set_color("font_pressed_color", "Button", WATER.lightened(0.5))
	th.set_color("font_outline_color", "Button", Color(0, 0, 0, 0.8))
	th.set_constant("outline_size", "Button", 6)
	th.set_font_size("font_size", "Button", 26)
	var plate := _box(Color(STEEL.r, STEEL.g, STEEL.b, 0.97), STEEL_EDGE, 18, 4, 12)
	plate.content_margin_left = 26
	plate.content_margin_right = 26
	plate.content_margin_top = 20
	plate.content_margin_bottom = 20
	th.set_stylebox("panel", "PanelContainer", plate)
	var bar := _box(Color(0.07, 0.09, 0.11, 0.95), HAZARD, 0, 0, 8)
	bar.border_width_bottom = 3
	th.set_stylebox("panel", "Panel", bar)
	return th


func _label(text: String, size: int, col := Color.WHITE, outline := 8) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_constant_override("outline_size", outline)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A label whose font size follows the screen width (big screens keep `size`).
func _slabel(text: String, size: int, col := Color.WHITE, outline := 8) -> Label:
	var l := _label(text, size, col, outline)
	_scaled.append([l, size, outline])
	return l


func _button(text: String, cb: Callable, min_w := 260) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(min_w, 60)
	b.pressed.connect(func():
		game.sfx.play("click")
		cb.call())
	return b


func _hud_button(kind: String, cb: Callable) -> HudButton:
	var b := HudButton.new()
	b.kind = kind
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(24, 24)  # The layout sizes it.
	b.pressed.connect(cb)
	return b


func _overlay() -> Control:
	var o := Control.new()
	o.set_anchors_preset(Control.PRESET_FULL_RECT)
	o.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.04, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	o.add_child(dim)
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	o.add_child(cc)
	o.visible = false
	root.add_child(o)
	return o


func _center_of(o: Control) -> CenterContainer:
	return o.get_child(1) as CenterContainer


# --- HUD ----------------------------------------------------------------------------------

func _build_hud() -> void:
	# Height and score live in the side panel (or the bottom bar in portrait);
	# refresh() places them inside game.stats_rect every frame.
	hud = Control.new()
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(hud)
	for key in ["HEIGHT", "SCORE"]:
		var trim: Color = WATER if key == "HEIGHT" else HAZARD
		var plate := StatPlate.new()
		plate.trim = trim
		plate.icon = "up" if key == "HEIGHT" else "star"
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud.add_child(plate)
		var cap := _label(key, 14, trim.lightened(0.2), 3)
		var val := _label("0", 30, Color("d6f3ff") if key == "HEIGHT" else Color("fff1c4"), 6)
		hud.add_child(cap)
		hud.add_child(val)
		stat_captions[key] = cap
		stat_values[key] = val
		stat_plates[key] = plate
	# Powers: one of each to start, another pair every 100 rows.
	btn_freeze = _hud_button("freeze", func(): game.use_freeze())
	btn_reveal = _hud_button("reveal", func(): game.use_reveal())
	btn_pause = _hud_button("pause", func(): game.toggle_pause())
	btn_freeze.label = "FREEZE"
	btn_reveal.label = "REVEAL"
	for b in [btn_freeze, btn_reveal, btn_pause]:
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
			b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
		b.visible = false
		root.add_child(b)
	speed_badge = SpeedBadge.new()
	speed_badge.game = game
	speed_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	speed_badge.visible = false
	root.add_child(speed_badge)


func _build_center_labels() -> void:
	banner = _slabel("", 54, Color("ffd23a"), 16)
	banner.set_anchors_preset(Control.PRESET_FULL_RECT)
	banner.modulate.a = 0.0
	root.add_child(banner)
	toast = _slabel("", 26, Color.WHITE, 8)
	toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast.modulate.a = 0.0
	root.add_child(toast)


func _build_title() -> void:
	title_screen = _overlay()
	# The main screen gets its own background instead of the dimmed board.
	var dim := title_screen.get_child(0)
	title_screen.remove_child(dim)
	dim.queue_free()
	var backdrop := TitleBackdrop.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	title_screen.add_child(backdrop)
	title_screen.move_child(backdrop, 0)
	# A simple menu: the best score, the name, and NEW GAME.
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 28)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center_of(title_screen).add_child(vb)
	_title_box = vb
	var best_box := VBoxContainer.new()
	best_box.add_theme_constant_override("separation", -4)
	best_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	best_box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vb.add_child(best_box)
	_best_caption = _label("BEST SCORE", 15, Color("ffc928"), 4)
	best_box.add_child(_best_caption)
	best_label = _label("0", 34, Color.WHITE, 6)
	best_box.add_child(best_label)
	logo = StationLogo.new()
	logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vb.add_child(logo)
	new_game_button = _button("NEW GAME", func(): game.start_run(), 300)
	new_game_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_button(new_game_button, STEEL, HAZARD)
	vb.add_child(new_game_button)
	solver_button = _button("SOLVER", func(): game.start_run(true), 200)
	solver_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_button(solver_button, Color("1d3a1f"), Color("5fbf55"))
	vb.add_child(solver_button)


func _build_pause() -> void:
	pause_screen = _overlay()
	var panel := RivetPanel.new()
	_center_of(pause_screen).add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	vb.add_child(_slabel("PAUSED", 64, WATER.lightened(0.3), 14))
	vb.add_child(_button("RESUME", func(): game.toggle_pause()))
	vb.add_child(_button("RESTART", func(): game.play_again()))
	vb.add_child(_button("MAIN MENU", func(): game.go_to_title()))


func _build_over() -> void:
	over_screen = _overlay()
	var panel := RivetPanel.new()
	_center_of(over_screen).add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)
	vb.add_child(_slabel("LEAK DETECTED", 64, Color("ff6a3a"), 14))
	over_reason = _slabel("", 22, Color(1, 1, 1, 0.85), 6)
	over_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(over_reason)
	over_score = _slabel("", 54, Color.WHITE, 12)
	vb.add_child(over_score)
	over_height = _label("", 26, WATER.lightened(0.3), 6)
	vb.add_child(over_height)
	over_best = _label("", 26, Color("ffd23a"), 6)
	vb.add_child(over_best)
	over_speed = _label("", 22, Color("9dff8a"), 6)
	vb.add_child(over_speed)
	over_new = _label("NEW BEST!", 36, Color("ffd23a"), 10)
	vb.add_child(over_new)
	var sp := Control.new()
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE  # Spacers must not swallow taps.
	sp.custom_minimum_size = Vector2(0, 8)
	vb.add_child(sp)
	vb.add_child(_button("PLAY AGAIN", func(): game.play_again()))
	vb.add_child(_button("MAIN MENU", func(): game.go_to_title()))


# --- screens --------------------------------------------------------------------------------

func show_title(_best: int = 0) -> void:
	_set_text(best_label, "%d" % SaveData.load_best())
	title_screen.visible = true
	pause_screen.visible = false
	over_screen.visible = false
	hud.visible = false


func show_play() -> void:
	title_screen.visible = false
	pause_screen.visible = false
	over_screen.visible = false
	hud.visible = true


func show_pause(p: bool) -> void:
	pause_screen.visible = p


func show_game_over(reason: String, score: int, height: int, best: int, is_new: bool, aps := 0.0) -> void:
	over_reason.text = reason
	over_reason.visible = reason != ""
	over_score.text = "%d" % score
	over_height.text = "HEIGHT  %d rows" % height
	over_best.text = "BEST  %d" % best
	over_speed.text = "%.1f ACTIONS PER SECOND" % aps
	over_new.visible = is_new
	over_screen.visible = true
	over_screen.modulate.a = 0.0
	create_tween().tween_property(over_screen, "modulate:a", 1.0, 0.35)


func show_banner(text: String) -> void:
	banner.text = text
	if _banner_tween:
		_banner_tween.kill()
	banner.modulate.a = 0.0
	banner.scale = Vector2.ONE
	_banner_tween = create_tween()
	_banner_tween.tween_property(banner, "modulate:a", 1.0, 0.25)
	_banner_tween.tween_interval(1.8)
	_banner_tween.tween_property(banner, "modulate:a", 0.0, 0.5)


func flash(col: Color) -> void:
	if _flash_tween:
		_flash_tween.kill()
	_flash.color = col
	_flash.visible = true
	_flash_tween = create_tween()
	_flash_tween.tween_property(_flash, "color:a", 0.0, 0.5)
	_flash_tween.tween_callback(func(): _flash.visible = false)


func show_toast(text: String, col := Color.WHITE) -> void:
	toast.text = text
	toast.add_theme_color_override("font_color", col)
	if _toast_tween:
		_toast_tween.kill()
	toast.modulate.a = 1.0
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.2)
	_toast_tween.tween_property(toast, "modulate:a", 0.0, 0.4)


# --- per-frame refresh ------------------------------------------------------------------------

func _set_text(l: Label, s: String) -> void:
	if l.text != s:
		l.text = s


func refresh() -> void:
	var vs: Vector2 = game.view_size
	if vs != _last_view or game.portrait != _last_portrait:
		_last_view = vs
		_last_portrait = game.portrait
		_apply_layout()

	_set_text(stat_values["HEIGHT"], "%d" % game.height)
	_set_text(stat_values["SCORE"], "%d" % game.score)
	_place_stats()

	_refresh_powers()

	if over_new.visible:
		over_new.modulate = Color.from_hsv(0.13, 0.6 + 0.4 * sin(game.time * 6.0), 1.0)


## Height and score inside game.stats_rect: one counter plate each (caption
## and icon on top, the number in a window below), stacked, or side by side
## when the area is wide (portrait bar).
func _place_stats() -> void:
	var r: Rect2 = game.stats_rect
	var key := "%s|%s" % [r, game.portrait]
	if key == _stats_key:
		return
	_stats_key = key
	var keys := ["HEIGHT", "SCORE"]
	for i in 2:
		var cap: Label = stat_captions[keys[i]]
		var val: Label = stat_values[keys[i]]
		var plate: StatPlate = stat_plates[keys[i]]
		var cell: Rect2
		if game.portrait and r.size.x >= 170.0:
			cell = Rect2(r.position.x + i * r.size.x * 0.5, r.position.y, r.size.x * 0.5, r.size.y)
		else:
			cell = Rect2(r.position.x, r.position.y + i * r.size.y * 0.5, r.size.x, r.size.y * 0.5)
		var pr := cell.grow(-3.0)
		plate.position = pr.position
		plate.size = pr.size
		if pr.size.y < 58.0:
			# Short plate (phone bar): just the icon (up arrow = height, star =
			# score) beside a big number window.
			cap.visible = false
			plate.icon_r = minf(9.0, pr.size.y * 0.22)
			plate.icon_at = Vector2(8.0 + plate.icon_r, pr.size.y * 0.5)
			var wx := plate.icon_at.x + plate.icon_r + 6.0
			var cw := Rect2(Vector2(wx, 4.0), Vector2(maxf(10.0, pr.size.x - wx - 5.0), pr.size.y - 8.0))
			plate.window = cw
			plate.queue_redraw()
			var cfs := int(clampf(minf(cw.size.y * 0.7, cw.size.x * 0.26), 12.0, 30.0))
			val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			val.position = pr.position + cw.position
			val.size = cw.size
			val.add_theme_font_size_override("font_size", cfs)
			val.add_theme_constant_override("outline_size", maxi(3, cfs / 6))
			continue
		cap.visible = true
		var cap_fs := int(clampf(pr.size.y * 0.2, 10.0, 15.0))
		var cap_h := cap_fs * 1.45 + 4.0
		var win := Rect2(Vector2(7, cap_h), Vector2(pr.size.x - 14.0, pr.size.y - cap_h - 6.0))
		plate.window = win
		plate.icon_r = cap_fs * 0.5
		var cap_w := PipeArt.font().get_string_size(keys[i], HORIZONTAL_ALIGNMENT_LEFT, -1, cap_fs).x
		var cap_x := (pr.size.x - cap_w) * 0.5 + plate.icon_r + 3.0
		plate.icon_at = Vector2(cap_x - plate.icon_r * 1.6 - 3.0, 2.0 + cap_h * 0.5)
		plate.queue_redraw()
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		cap.position = pr.position + Vector2(cap_x, 2.0)
		cap.size = Vector2(pr.size.x - cap_x, cap_h - 2.0)
		var val_fs := int(clampf(minf(win.size.y * 0.74, win.size.x * 0.24), 12.0, 36.0))
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		val.position = pr.position + win.position
		val.size = win.size
		cap.add_theme_font_size_override("font_size", cap_fs)
		val.add_theme_font_size_override("font_size", val_fs)
		val.add_theme_constant_override("outline_size", maxi(3, val_fs / 6))


func _refresh_powers() -> void:
	var shown: bool = game.powers_shown()
	for e in [[btn_freeze, game.freeze_rect, game.freezes], [btn_reveal, game.reveal_rect, game.reveals], [btn_pause, game.pause_rect, 1]]:
		var b: HudButton = e[0]
		if b.visible != shown:
			b.visible = shown
		if not shown:
			continue
		var r: Rect2 = e[1]
		if b.position != r.position or b.size != r.size:
			b.position = r.position
			b.size = r.size
		if b.count != e[2]:
			b.count = e[2]
			b.queue_redraw()
		var dim := 1.0 if e[2] > 0 or (b == btn_freeze and game.freeze_timer > 0.0) else 0.4
		if b.modulate.a != dim:
			b.modulate.a = dim
	# A running freeze: ice on the Freeze button, draining as it runs out.
	var left: float = game.freeze_timer
	var prog := clampf(left / Tuning.FREEZE_TIME, 0.0, 1.0) if left > 0.0 else 0.0
	if btn_freeze.progress != prog:
		btn_freeze.progress = prog
		btn_freeze.seconds = left
		btn_freeze.queue_redraw()
	# FAST badge while the water is sped up.
	var fast: bool = game.speed_held()
	if speed_badge.visible != fast:
		speed_badge.visible = fast
	if fast:
		var b: Rect2 = game.board_rect
		var sz := Vector2(minf(b.size.x - 16.0, roundf(speed_badge.width_for(34.0))), 34)
		var bk := "%s|%.2f" % [speed_badge._texts(), game.hold_ramp()]
		if bk != _badge_key:
			_badge_key = bk
			speed_badge.queue_redraw()
		var y := b.position.y + 10.0
		if game.tutorial.active and game.tutorial.visible:
			y = game.tutorial._panel.get_global_rect().end.y + 8.0
		speed_badge.position = Vector2(roundf(b.get_center().x - sz.x * 0.5), y)
		speed_badge.size = sz


func _apply_layout() -> void:
	var vs: Vector2 = game.view_size
	# Text scales down on narrow screens so headings never run off the edge.
	var k := clampf(minf(vs.x / 680.0, vs.y / 760.0), 0.6, 1.0)
	for e in _scaled:
		var l: Label = e[0]
		l.add_theme_font_size_override("font_size", maxi(12, int(e[1] * k)))
		l.add_theme_constant_override("outline_size", maxi(2, int(e[2] * k)))
	# Menu: best score, nameplate, NEW GAME and the small SOLVER must fit.
	var short := vs.y < 600.0
	var bh := 56.0 if short else 74.0
	var bw := minf(320.0, vs.x - 64.0)
	var sep := 16.0 if short else 26.0
	_title_box.add_theme_constant_override("separation", int(sep))
	_best_caption.add_theme_font_size_override("font_size", 13 if short else 17)
	best_label.add_theme_font_size_override("font_size", 26 if short else 36)
	var best_h := 48.0 if short else 64.0
	var ai_h := 40.0 if short else 46.0
	var used := bh + ai_h + 3.0 * sep + best_h + 60.0
	logo.fit_width(vs.x - 24.0, maxf(60.0, minf(vs.y * (0.3 if short else 0.36), vs.y - used)))
	solver_button.custom_minimum_size = Vector2(minf(220.0, bw * 0.7), ai_h)
	solver_button.add_theme_font_size_override("font_size", 18 if short else 20)
	over_reason.custom_minimum_size = Vector2(minf(420.0, vs.x - 96.0), 0)
	_stats_key = ""
	new_game_button.custom_minimum_size = Vector2(bw, bh)
	new_game_button.add_theme_font_size_override("font_size", 28 if short else 34)
	banner.position = Vector2(0, -vs.y * 0.22)
	banner.size = vs
	toast.position = Vector2(20, -vs.y * 0.5 + game.hud_h + 40)
	toast.size = Vector2(vs.x - 40, vs.y)
