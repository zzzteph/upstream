## ============================================================================
##  UI - HUD, buttons, banners and the title / pause / game-over screens.
## ============================================================================
class_name GameUI
extends CanvasLayer


## A power card (Flow-freeze or Reveal), drawn as a piece of the pump
## station: a loop of pipe (steel for Freeze, brass for Reveal) with bolted
## flange collars and a coloured channel, around a dark plate. The icon sits
## behind a bolted porthole. Wide cards put the name and charges beside the
## porthole; tall ones put the charges under it.
class IconButton:
	extends Button
	const FREEZE_COL := Color("8fe8ff")
	const REVEAL_COL := Color("ffc928")
	const STEEL_PIPE := Color("8fa3ab")
	const BRASS_PIPE := Color("c9973a")
	var kind := ""
	var lit := false
	var count := 0
	var label := ""
	var _sb := StyleBoxFlat.new()

	func _draw() -> void:
		var accent := FREEZE_COL if kind == "freeze" else REVEAL_COL
		var metal := STEEL_PIPE if kind == "freeze" else BRASS_PIPE
		match get_draw_mode():
			DRAW_HOVER:
				metal = metal.lightened(0.15)
			DRAW_PRESSED, DRAW_HOVER_PRESSED:
				metal = metal.darkened(0.2)
		var w := clampf(minf(size.x, size.y) * 0.09, 6.0, 12.0)
		_pipe_frame(Rect2(Vector2.ZERO, size), w, metal, accent)
		var inner := Rect2(Vector2(w * 1.5, w * 1.5), size - Vector2(w * 3.0, w * 3.0))
		var wide := size.x >= size.y * 1.6
		var r: float
		var ic: Vector2
		var f := PipeArt.font()
		var n := "x%d" % count
		if wide:
			r = minf(inner.size.y * 0.46, inner.size.x * 0.2)
			ic = Vector2(inner.position.x + r + 2.0, inner.get_center().y)
		else:
			var fs_c := clampf(inner.size.x * 0.26, 14.0, 26.0)
			r = minf(inner.size.x * 0.46, (inner.size.y - fs_c * 1.2) * 0.46)
			ic = Vector2(inner.get_center().x, inner.position.y + (inner.size.y - fs_c * 1.1) * 0.5)
		_porthole(ic, r, metal, kind == "freeze")
		if kind == "freeze":
			draw_freeze_icon(self, ic, r * 0.7, lit)
		else:
			draw_reveal_icon(self, ic, r * 0.7)
		if wide:
			var x := ic.x + r + 10.0
			var tw := maxf(10.0, inner.end.x - x - 2.0)
			var name_fs := int(clampf(minf(inner.size.y * 0.22, tw / 4.4), 12.0, 20.0))
			var n_fs := int(clampf(inner.size.y * 0.4, 18.0, 36.0))
			var top := inner.get_center().y - (name_fs + n_fs) * 0.5
			draw_string(f, Vector2(x, top + name_fs * 0.95), label, HORIZONTAL_ALIGNMENT_LEFT, tw, name_fs, accent)
			draw_string_outline(f, Vector2(x, top + name_fs + n_fs * 0.92), n, HORIZONTAL_ALIGNMENT_LEFT, tw, n_fs, maxi(2, n_fs / 6), Color(0, 0, 0, 0.8))
			draw_string(f, Vector2(x, top + name_fs + n_fs * 0.92), n, HORIZONTAL_ALIGNMENT_LEFT, tw, n_fs, Color.WHITE)
		else:
			var fs := int(clampf(inner.size.x * 0.26, 14.0, 26.0))
			var y := inner.end.y - fs * 0.15
			draw_string_outline(f, Vector2(inner.position.x, y), n, HORIZONTAL_ALIGNMENT_CENTER, inner.size.x, fs, maxi(2, fs / 6), Color(0, 0, 0, 0.8))
			draw_string(f, Vector2(inner.position.x, y), n, HORIZONTAL_ALIGNMENT_CENTER, inner.size.x, fs, Color.WHITE)

	## Stroke the rounded rectangle `path` with a band `bw` wide, centred on it.
	func _stroke(path: Rect2, bw: float, radius: float, col: Color) -> void:
		_sb.draw_center = false
		_sb.set_border_width_all(maxi(1, roundi(bw)))
		_sb.set_corner_radius_all(maxi(0, roundi(radius + bw * 0.5)))
		_sb.border_color = col
		_sb.anti_aliasing = true
		draw_style_box(_sb, path.grow(bw * 0.5))

	## The card: a dark plate inside a loop of pipe with four flange collars.
	func _pipe_frame(r: Rect2, w: float, metal: Color, accent: Color) -> void:
		var path := r.grow(-w * 0.62)
		var rad := w * 1.4
		# Plate (and a soft drop shadow under the whole card).
		_sb.draw_center = true
		_sb.set_border_width_all(0)
		_sb.anti_aliasing = true
		_sb.set_corner_radius_all(roundi(rad + w * 0.5))
		_sb.bg_color = Color(0, 0, 0, 0.45)
		draw_style_box(_sb, Rect2(r.position + Vector2(0, w * 0.35), r.size).grow(-w * 0.1))
		_sb.bg_color = Color("0e151a")
		draw_style_box(_sb, path)
		_sb.bg_color = Color(1, 1, 1, 0.03)
		draw_style_box(_sb, Rect2(path.position, Vector2(path.size.x, path.size.y * 0.45)))
		# The pipe: dark edges, the metal body, a coloured channel, a highlight.
		_stroke(path, w, rad, metal.darkened(0.6))
		_stroke(path, w * 0.74, rad, metal)
		_stroke(path.grow(w * 0.2), w * 0.16, rad + w * 0.2, metal.lightened(0.45))
		_stroke(path.grow(-w * 0.14), w * 0.2, rad - w * 0.14, PipeArt.fade(accent, 0.85 if lit or kind != "freeze" else 0.7))
		if lit:
			_stroke(path, w * 1.6, rad, Color(0.7, 0.95, 1.0, 0.25))
		# Flange collars, bolted on, halfway along each side.
		var c := path.get_center()
		for spec in [[Vector2(c.x, path.position.y), true], [Vector2(c.x, path.end.y), true],
				[Vector2(path.position.x, c.y), false], [Vector2(path.end.x, c.y), false]]:
			var p: Vector2 = spec[0]
			var across: Vector2 = Vector2(0, 1) if spec[1] else Vector2(1, 0)
			var along: Vector2 = Vector2(1, 0) if spec[1] else Vector2(0, 1)
			var half: Vector2 = along * w * 0.42 + across * w * 0.86
			var cr := Rect2(p - Vector2(absf(half.x), absf(half.y)), Vector2(absf(half.x), absf(half.y)) * 2.0)
			draw_rect(cr.grow(1.0), metal.darkened(0.6))
			draw_rect(cr, metal.darkened(0.05))
			draw_rect(Rect2(cr.position, Vector2(cr.size.x, maxf(1.0, cr.size.y * 0.18))) if spec[1] else Rect2(cr.position, Vector2(maxf(1.0, cr.size.x * 0.18), cr.size.y)), metal.lightened(0.4))
			for sgn in [-1.0, 1.0]:
				var bp: Vector2 = p + across * w * 0.58 * sgn
				draw_circle(bp, maxf(1.2, w * 0.17), metal.darkened(0.6))
				draw_circle(bp - Vector2(0.4, 0.4), maxf(0.8, w * 0.09), metal.lightened(0.5))

	## A bolted porthole: a metal flange ring with bolts and a dark glass.
	func _porthole(c: Vector2, r: float, metal: Color, icy: bool) -> void:
		draw_circle(c + Vector2(r * 0.05, r * 0.08), r * 1.02, Color(0, 0, 0, 0.45))
		draw_circle(c, r, metal.darkened(0.6))
		draw_circle(c, r * 0.93, metal)
		draw_arc(c, r * 0.86, PI * 1.05, PI * 1.7, 24, metal.lightened(0.45), maxf(1.5, r * 0.06), true)
		for k in 8:
			var bp := c + Vector2.from_angle(k * TAU / 8.0 + PI / 8.0) * r * 0.83
			draw_circle(bp, maxf(1.5, r * 0.07), metal.darkened(0.6))
			draw_circle(bp - Vector2(0.5, 0.5), maxf(1.0, r * 0.035), metal.lightened(0.5))
		draw_circle(c, r * 0.72, metal.darkened(0.65))
		draw_circle(c, r * 0.68, Color("0a2436") if icy else Color("2b1f06"))
		draw_circle(c - Vector2(r, r) * 0.2, r * 0.32, Color(1, 1, 1, 0.05))

	## Flow-freeze: a six-armed snowflake behind frosted glass.
	static func draw_freeze_icon(ci: CanvasItem, c: Vector2, r: float, glow := false) -> void:
		if glow:
			ci.draw_circle(c, r * 1.05, Color(0.6, 0.92, 1.0, 0.3))
		ci.draw_circle(c, r * 0.94, Color("12405f"))
		for layer in 2:
			var off := Vector2(r * 0.04, r * 0.06) if layer == 0 else Vector2.ZERO
			var col := Color("041622") if layer == 0 else (Color.WHITE if glow else Color("e9fbff"))
			var w := maxf(2.0, r * 0.11)
			var o := c + off
			for k in 6:
				var d := Vector2.from_angle(k * PI / 3.0 - PI / 2.0)
				var pp := Vector2(-d.y, d.x)
				ci.draw_line(o, o + d * r * 0.72, col, w, true)
				for spec in [[0.32, 0.22], [0.54, 0.16]]:
					var m: Vector2 = o + d * r * spec[0]
					var L: float = r * spec[1]
					ci.draw_line(m, m + (d + pp).normalized() * L, col, w * 0.8, true)
					ci.draw_line(m, m + (d - pp).normalized() * L, col, w * 0.8, true)
				ci.draw_circle(o + d * r * 0.74, w * 0.75, col)
			ci.draw_circle(o, r * 0.14, col)
		ci.draw_circle(c, r * 0.06, Color("12405f"))

	## Reveal: an open eye with a few scan rays, behind amber glass.
	static func draw_reveal_icon(ci: CanvasItem, c: Vector2, r: float) -> void:
		ci.draw_circle(c, r * 0.94, Color("4d3a0c"))
		var ec := c + Vector2(0, r * 0.12)
		var ew := r * 0.78
		var eh := r * 0.46
		var pts := PackedVector2Array()
		for i in 25:
			var t := i / 24.0
			pts.append(ec + Vector2(lerpf(-ew, ew, t), -eh * sin(t * PI)))
		for i in range(1, 24):
			var t := 1.0 - i / 24.0
			pts.append(ec + Vector2(lerpf(-ew, ew, t), eh * sin(t * PI)))
		var shadow := PackedVector2Array()
		for p in pts:
			shadow.append(p + Vector2(r * 0.04, r * 0.06))
		ci.draw_colored_polygon(shadow, Color(0, 0, 0, 0.5))
		ci.draw_colored_polygon(pts, Color("fff7e4"))
		ci.draw_circle(ec, eh * 0.86, Color("155e96"))
		ci.draw_circle(ec, eh * 0.7, Color("3ab4ff"))
		ci.draw_circle(ec, eh * 0.36, Color("081420"))
		ci.draw_circle(ec + Vector2(-eh * 0.3, -eh * 0.3), eh * 0.16, Color.WHITE)
		var closed := pts.duplicate()
		closed.append(pts[0])
		ci.draw_polyline(closed, Color("1c1404"), maxf(2.0, r * 0.08), true)
		for a in [-0.6, 0.0, 0.6]:
			var d := Vector2.from_angle(-PI / 2.0 + a)
			ci.draw_line(ec + d * r * 0.62, ec + d * r * 0.84, Color("ffe7a0"), maxf(2.0, r * 0.09), true)


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
			draw_colored_polygon(PackedVector2Array([c + Vector2(0, -k), c + Vector2(k, k * 0.2), c + Vector2(k * 0.35, k * 0.2),
					c + Vector2(k * 0.35, k), c + Vector2(-k * 0.35, k), c + Vector2(-k * 0.35, k * 0.2), c + Vector2(-k, k * 0.2)]), trim)
		else:
			var pts := PackedVector2Array()
			for i in 10:
				pts.append(c + Vector2.from_angle(-PI / 2.0 + i * PI / 5.0) * (k if i % 2 == 0 else k * 0.45))
			draw_colored_polygon(pts, trim)


## "▶▶ FAST x4" shown at the top of the board while the water is sped up.
class SpeedBadge:
	extends Control

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.05, 0.07, 0.09, 0.85)
		sb.border_color = Color("ffc928")
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(int(size.y * 0.5))
		sb.anti_aliasing = true
		draw_style_box(sb, r)
		var h := size.y * 0.42
		var x := size.y * 0.45
		for i in 2:
			var ox := x + i * h * 0.75
			draw_colored_polygon(PackedVector2Array([Vector2(ox, size.y * 0.5 - h * 0.5), Vector2(ox + h * 0.7, size.y * 0.5),
					Vector2(ox, size.y * 0.5 + h * 0.5)]), Color("ffc928"))
		var f := PipeArt.font()
		var fs := int(size.y * 0.46)
		var tx := x + h * 2.3
		var txt := "FAST x%d" % int(Tuning.HOLD_SPEED_MULT)
		draw_string(f, Vector2(tx, size.y * 0.5 + fs * 0.36), txt, HORIZONTAL_ALIGNMENT_LEFT, size.x - tx - 8.0, fs, Color.WHITE)
		var tw := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(f, Vector2(tx + tw + 12.0, size.y * 0.5 + fs * 0.36), "%dx POINTS" % Tuning.HOLD_SCORE_MULT, HORIZONTAL_ALIGNMENT_LEFT, size.x - tx - tw - 18.0, fs, Color("ffc928"))


var game  ## The Game node (main.gd).
var root: Control
var hud: Control
var stat_values := {}     ## "HEIGHT" / "SCORE" -> value Label.
var stat_captions := {}   ## "HEIGHT" / "SCORE" -> caption Label.
var stat_plates := {}     ## "HEIGHT" / "SCORE" -> StatPlate behind them.
var _stats_key := ""
var btn_freeze: IconButton
var btn_reveal: IconButton
var speed_badge: SpeedBadge
var banner: Label
var toast: Label
var title_screen: Control
var new_game_button: Button
var watch_ai_button: Button    ## Small: starts a game the AI plays.
var best_label: Label         ## The best score on the menu, above the nameplate.
var _title_box: VBoxContainer
var _best_caption: Label
var logo: StationLogo
var pause_screen: Control
var pause_mute: Button
var over_screen: Control
var over_reason: Label
var over_score: Label
var over_height: Label
var over_best: Label
var over_new: Label
var _last_view := Vector2.ZERO
var _last_portrait := false
var _banner_tween: Tween
var _toast_tween: Tween
var _ff_lit := false
var _scaled := []          ## [Label, base font size, base outline] scaled to the screen width.
var _key_buttons := []     ## [Button, mouse/keyboard text, touch text]
var _flash: ColorRect
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


## A button whose caption drops its keyboard hint on touch screens.
func _kbutton(key_text: String, touch_text: String, cb: Callable) -> Button:
	var b := _button(key_text, cb)
	_key_buttons.append([b, key_text, touch_text])
	return b


func _button(text: String, cb: Callable, min_w := 260) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(min_w, 60)
	b.pressed.connect(func():
		game.sfx.play("click")
		cb.call())
	return b


func _icon_button(kind: String, cb: Callable) -> IconButton:
	var b := IconButton.new()
	b.kind = kind
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(52, 52)
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
	btn_freeze = _icon_button("freeze", func(): game.use_freeze())
	btn_reveal = _icon_button("reveal", func(): game.use_reveal())
	btn_freeze.label = "FREEZE"
	btn_reveal.label = "REVEAL"
	for b in [btn_freeze, btn_reveal]:
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
			b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
		b.visible = false
		root.add_child(b)
	speed_badge = SpeedBadge.new()
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
	watch_ai_button = _button("WATCH AI", func(): game.start_run(true), 200)
	watch_ai_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_button(watch_ai_button, Color("1d3a1f"), Color("5fbf55"))
	vb.add_child(watch_ai_button)


func _build_pause() -> void:
	pause_screen = _overlay()
	var panel := RivetPanel.new()
	_center_of(pause_screen).add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	vb.add_child(_slabel("PAUSED", 64, WATER.lightened(0.3), 14))
	vb.add_child(_kbutton("RESUME  (P)", "RESUME", func(): game.toggle_pause()))
	vb.add_child(_kbutton("RESTART  (R)", "RESTART", func(): game.play_again()))
	pause_mute = _button("SOUND: ON  (M)", func(): game.toggle_mute())
	vb.add_child(pause_mute)
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


func show_game_over(reason: String, score: int, height: int, best: int, is_new: bool) -> void:
	over_reason.text = reason
	over_reason.visible = reason != ""
	over_score.text = "%d" % score
	over_height.text = "HEIGHT  %d rows" % height
	over_best.text = "BEST  %d" % best
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
	_flash_tween = create_tween()
	_flash_tween.tween_property(_flash, "color:a", 0.0, 0.5)


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
	var mt := "SOUND: OFF" if game.sfx.muted else "SOUND: ON"
	if not game.is_touch:
		mt += "  (M)"
	if pause_mute.text != mt:
		pause_mute.text = mt

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
	for e in [[btn_freeze, game.freeze_rect, game.freezes], [btn_reveal, game.reveal_rect, game.reveals]]:
		var b: IconButton = e[0]
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
		var dim := 1.0 if e[2] > 0 else 0.4
		if b.modulate.a != dim:
			b.modulate.a = dim
	var lit: bool = game.freeze_timer > 0.0
	if btn_freeze.lit != lit:
		btn_freeze.lit = lit
		btn_freeze.queue_redraw()
	# FAST badge while the water is sped up.
	var fast: bool = game.speed_held()
	if speed_badge.visible != fast:
		speed_badge.visible = fast
	if fast:
		var b: Rect2 = game.board_rect
		var sz := Vector2(260, 34)
		var y := b.position.y + 10.0
		if game.tutorial.active and game.tutorial.visible:
			y = game.tutorial._panel.get_global_rect().end.y + 8.0
		speed_badge.position = Vector2(roundf(b.get_center().x - sz.x * 0.5), y)
		speed_badge.size = sz


func _apply_layout() -> void:
	var vs: Vector2 = game.view_size
	var touch: bool = game.is_touch
	# Text scales down on narrow screens so headings never run off the edge.
	var k := clampf(minf(vs.x / 680.0, vs.y / 760.0), 0.6, 1.0)
	for e in _scaled:
		var l: Label = e[0]
		l.add_theme_font_size_override("font_size", maxi(12, int(e[1] * k)))
		l.add_theme_constant_override("outline_size", maxi(2, int(e[2] * k)))
	for e in _key_buttons:
		(e[0] as Button).text = e[2] if touch else e[1]
	# Menu: best score, nameplate, NEW GAME and the small WATCH AI must fit.
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
	watch_ai_button.custom_minimum_size = Vector2(minf(220.0, bw * 0.7), ai_h)
	watch_ai_button.add_theme_font_size_override("font_size", 18 if short else 20)
	over_reason.custom_minimum_size = Vector2(minf(420.0, vs.x - 96.0), 0)
	_stats_key = ""
	new_game_button.custom_minimum_size = Vector2(bw, bh)
	new_game_button.add_theme_font_size_override("font_size", 28 if short else 34)
	banner.position = Vector2(0, -vs.y * 0.22)
	banner.size = vs
	toast.position = Vector2(20, -vs.y * 0.5 + game.hud_h + 40)
	toast.size = Vector2(vs.x - 40, vs.y)
