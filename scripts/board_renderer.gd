## ============================================================================
##  RENDERER - backdrop, board, goo, particles and the queue panel.
## ============================================================================
## Draw-call budget matters (WebGL, phones), so:
##  * every board row is its own cached canvas item made of textured quads from
##    the SpriteAtlas, redrawn only when that row changes;
##  * only the tile the goo is flowing through (and the source pump) is drawn
##    with live vector calls;
##  * particles, glows and backdrop decorations are textured quads too.
## Layers, back to front: backdrop (this node) > rows > live tiles > glow (add)
##   > hover ghost sprites > fx > queue panel (bg, icons, overlay).
class_name BoardRenderer
extends Node2D


## A child layer whose drawing is delegated back to the renderer.
class Layer:
	extends Node2D
	var draw_cb: Callable
	var row := -999999
	var stamp := -1

	func _draw() -> void:
		draw_cb.call(self)


var game  ## The Game node (main.gd).
var atlas: SpriteAtlas
## Where layers that must stay sharp go (text, queue panel). In PS1 mode the
## board renders at low resolution, so these live on the full-res screen.
var overlay_parent: Node
var rows_root: Node2D
var live: Layer
var glow: Layer
var fx_sprites: Layer
var frost: Layer
var fx: Layer
var backdrop: Layer
var live_base: Layer   ## The live tile's dry pipe, as an atlas sprite (under `live`).
var queue_bg: Layer
var queue_icons: Layer
var queue_fg: Layer
var text_layer: Layer
var row_views := {}       ## row -> Layer
var _pool: Array = []
var _animate_until := {}  ## row -> game time until which it redraws every frame
var _layout_key := ""
var _queue_sig := ""
## Particles, as parallel packed arrays (far cheaper per frame than a
## Dictionary each): position and velocity in world units, life left and at
## the start, size, gravity, colour, and whether it glows.
var _pp := PackedVector2Array()
var _pv := PackedVector2Array()
var _pl := PackedFloat32Array()
var _pm := PackedFloat32Array()
var _ps := PackedFloat32Array()
var _pg := PackedFloat32Array()
var _pc := PackedColorArray()
var _pw := PackedByteArray()
const MAX_PARTS := 300
## Bubbles drifting along full pipes, worked out once per row version:
## row -> [version, PackedFloat32Array of BUB_STRIDE floats per bubble].
var _bub_cache := {}
const BUB_STRIDE := 11
## Random numbers for the backdrop and the side glasses (a table, so nothing
## calls sin() just to get a random number every frame).
var _rt := PackedFloat32Array()
## The frost is drawn once and then only moved and faded (see _sync_frost).
var _frost_key := ""
var _frost_cam := 0.0
var _frost_off := Vector2.ZERO
## The background shows how fast the water runs: bubbles and current streaks
## rise at a pace that follows the water's speed (faster with height, rushing
## while held, still while frozen). flow_motion eases towards that pace;
## flow_clock is how far the current has moved.
var flow_motion := 1.0
var flow_clock := 0.0
var texts: Array = []   ## {p, text, col, life, max, size}
var _sb := StyleBoxFlat.new()


func _ready() -> void:
	_sb.anti_aliasing = true
	_rt.resize(1024)
	for i in 1024:
		_rt[i] = h01(i * 1.618 + 0.37)
	var add_mat := CanvasItemMaterial.new()
	add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	backdrop = _layer(_draw_backdrop, -100)
	rows_root = Node2D.new()
	rows_root.material = atlas.premult_material
	add_child(rows_root)
	live_base = _layer(_draw_live_base, 139)
	live_base.material = atlas.premult_material
	live = _layer(_draw_live, 140)
	glow = _layer(_draw_glow, 150)
	glow.material = add_mat
	fx_sprites = _layer(_draw_fx_sprites, 160)
	fx_sprites.material = atlas.premult_material
	frost = _layer(_draw_frost, 165)
	fx = _layer(_draw_fx, 170)
	var top: Node = overlay_parent if overlay_parent != null else self
	text_layer = _layer(_draw_text, 175, top)
	queue_bg = _layer(_draw_queue_bg, 180, top)
	queue_icons = _layer(_draw_queue_icons, 181, top)
	queue_icons.material = atlas.premult_material
	queue_icons.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	queue_fg = _layer(_draw_queue_fg, 182, top)


func _layer(cb: Callable, z: int, parent: Node = null) -> Layer:
	var l := Layer.new()
	l.draw_cb = cb
	l.z_index = z
	(parent if parent != null else self).add_child(l)
	return l


func redraw() -> void:
	_sync_rows()
	backdrop.queue_redraw()
	live_base.queue_redraw()
	live.queue_redraw()
	glow.queue_redraw()
	fx_sprites.queue_redraw()
	_sync_frost()
	fx.queue_redraw()
	text_layer.queue_redraw()
	var sig := _queue_signature()
	if sig != _queue_sig or game.queue_shift > 0.0 or game.lock_timer > 0.0:
		_queue_sig = sig
		queue_bg.queue_redraw()
		queue_icons.queue_redraw()
		queue_fg.queue_redraw()


func invalidate_rows() -> void:
	for v in row_views.values():
		v.stamp = -1
	_animate_until.clear()
	_queue_sig = ""


func animate_row(r: int, until: float) -> void:
	_animate_until[r] = until


func clear_fx() -> void:
	for a in [_pp, _pv, _pl, _pm, _ps, _pg, _pc, _pw]:
		a.clear()
	texts.clear()
	_bub_cache.clear()


func part_count() -> int:
	return _pp.size()


func _add_part(p: Vector2, v: Vector2, life: float, mx: float, col: Color, size: float, grav: float, glowing: bool) -> void:
	if _pp.size() >= MAX_PARTS:
		return
	_pp.append(p)
	_pv.append(v)
	_pl.append(life)
	_pm.append(mx)
	_ps.append(size)
	_pg.append(grav)
	_pc.append(col)
	_pw.append(1 if glowing else 0)


# --- coordinates ---------------------------------------------------------------

## Snap to whole physical pixels so atlas sprites map 1:1 and never blur or seam.
func snap(v: float) -> float:
	var s: float = game.px_scale
	return roundf(v * s) / s


func row_y(r: int) -> float:
	return snap(game.board_rect.end.y - (r + 1 - game.cam.y) * game.T)


func shake_offset() -> Vector2:
	var o: Vector2 = game.cam.offset
	return Vector2(snap(o.x), snap(o.y))


func tile_rect(c: int, r: int) -> Rect2:
	var T: float = game.T
	return Rect2(Vector2(game.board_rect.position.x + c * T, row_y(r)) + shake_offset(), Vector2(T, T))


func w2s(w: Vector2) -> Vector2:
	var T: float = game.T
	var b: Rect2 = game.board_rect
	return Vector2(b.position.x + w.x * T, b.end.y - (w.y - game.cam.y) * T) + shake_offset()


static func h01(n: float) -> float:
	return fposmod(sin(n * 12.9898) * 43758.5453, 1.0)


func _is_live(t: Tile, c: int, r: int) -> bool:
	return t.kind == Tile.SOURCE or (game.flow.active and c == game.flow.col and r == game.flow.row)


# --- cached rows ---------------------------------------------------------------

func _sync_rows() -> void:
	var T: float = game.T
	var b: Rect2 = game.board_rect
	var key := "%.4f|%.3f|%.3f|%d" % [T, b.position.x, b.size.x, atlas.tile_px]
	if key != _layout_key:
		_layout_key = key
		invalidate_rows()
	var cam: GameCamera = game.cam
	var grid: Grid = game.grid
	var rr := cam.row_range()
	rows_root.position = shake_offset()
	for r in row_views.keys():
		if r < rr.x or r > rr.y:
			var v: Layer = row_views[r]
			v.visible = false
			_pool.append(v)
			row_views.erase(r)
	for r in _animate_until.keys():
		if _animate_until[r] < game.time:
			_animate_until.erase(r)
			grid.touch(r)
	for r in range(rr.x, rr.y + 1):
		var v: Layer = row_views.get(r)
		if v == null:
			if _pool.is_empty():
				v = Layer.new()
				v.draw_cb = _draw_row
				v.use_parent_material = true
				rows_root.add_child(v)
			else:
				v = _pool.pop_back()
			v.row = r
			v.stamp = -1
			v.visible = true
			row_views[r] = v
		v.position = Vector2(0, row_y(r))
		v.z_index = 1 + r - rr.x
		var stamp := grid.version(r) * 4 + (1 if r < grid.floor_row else 0) + (2 if grid.rows.has(r) else 0)
		if _animate_until.has(r) or v.stamp != stamp:
			v.queue_redraw()
			v.stamp = stamp


## One row in local space: x as on screen, y from 0 (row top) to T.
func _draw_row(ci: CanvasItem) -> void:
	if game == null or game.T <= 0.0 or atlas.tile_px <= 0:
		return
	var r: int = (ci as Layer).row
	var T: float = game.T
	var b: Rect2 = game.board_rect
	var grid: Grid = game.grid
	var zone := Zones.index_for_row(r)
	var pal := Zones.theme(zone)
	var tex := atlas.tile_tex(zone)
	var x0 := b.position.x
	ci.draw_rect(Rect2(x0 - T * 0.04, 0, b.size.x + T * 0.08, T), pal["board"])
	var wr := atlas.region(SpriteAtlas.WALL)
	wr.size.x *= 0.2
	var ww := T * 0.2
	ci.draw_texture_rect_region(tex, Rect2(x0 - ww, 0, ww, T), wr)
	ci.draw_texture_rect_region(tex, Rect2(b.end.x, 0, ww, T), wr)
	if r < grid.floor_row:
		_draw_bedrock(ci, r, x0, b.size.x, T)
		return
	var time: float = game.time
	for c in Tuning.COLS:
		var t := grid.get_tile(c, r)
		if t != null and (t.hidden or time - t.flip_at < Tuning.FLIP_TIME):
			continue  # Locked and flipping tiles bring their own face.
		ci.draw_texture_rect_region(tex, Rect2(x0 + c * T, 0, T, T), atlas.region(SpriteAtlas.BASE_B if (c + r) % 2 == 0 else SpriteAtlas.BASE_A))
	for c in Tuning.COLS:
		var t := grid.get_tile(c, r)
		if t == null or _is_live(t, c, r):
			continue
		var rect := Rect2(x0 + c * T, 0, T, T)
		var fk := (time - t.flip_at) / Tuning.FLIP_TIME
		if not t.hidden and fk < 0.0:
			ci.draw_texture_rect_region(tex, rect, atlas.region(SpriteAtlas.LOCKED))
			continue
		if not t.hidden and fk >= 0.0 and fk < 1.0:
			# Unlock flip: the plate turns edge-on, then the tile underneath turns face-up.
			ci.draw_set_transform(rect.get_center(), 0.0, Vector2(maxf(0.04, absf(cos(fk * PI))), 1.0 + 0.12 * sin(fk * PI)))
			var local := Rect2(-T * 0.5, -T * 0.5, T, T)
			if fk < 0.5:
				ci.draw_texture_rect_region(tex, local, atlas.region(SpriteAtlas.LOCKED))
			else:
				ci.draw_texture_rect_region(tex, local, atlas.region(SpriteAtlas.BASE_B if (c + r) % 2 == 0 else SpriteAtlas.BASE_A))
				var fs := SpriteAtlas.sprite_for(t)
				if fs >= 0:
					ci.draw_texture_rect_region(tex, local, atlas.region(fs))
			ci.draw_set_transform(Vector2.ZERO)
			continue
		var s := SpriteAtlas.sprite_for(t)
		if s < 0:
			if t.piece >= 0:
				PipeArt.draw_pipe(ci, rect.get_center(), T, t.piece, pal, t, 1.0, game.time, false)
			continue
		var k := _pop_scale(t)
		if k != 1.0:
			ci.draw_set_transform(rect.get_center(), 0.0, Vector2(k, k))
			ci.draw_texture_rect_region(tex, Rect2(-T * 0.5, -T * 0.5, T, T), atlas.region(s))
			ci.draw_set_transform(Vector2.ZERO)
		else:
			ci.draw_texture_rect_region(tex, rect, atlas.region(s))
	if r > 0 and r % Tuning.ZONE_ROWS == 0:
		var x := x0
		var dash := T * 0.25
		var k := 0
		var th := maxf(3.0, T * 0.06)
		while x < b.end.x - 0.5:
			ci.draw_rect(Rect2(x, T - th * 0.5, minf(dash, b.end.x - x), th), pal["accent"] if k % 2 == 0 else Color(0.1, 0.1, 0.1))
			x += dash
			k += 1


func _draw_bedrock(ci: CanvasItem, r: int, x0: float, w: float, T: float) -> void:
	ci.draw_rect(Rect2(x0, 0, w, T), Color("141010"))
	for i in 6:
		var x := x0 + h01(r * 13.0 + i) * w
		var y := h01(r * 7.0 + i * 3.0) * T
		var rad := T * (0.04 + h01(i + r) * 0.06)
		ci.draw_rect(Rect2(x - rad, y - rad, rad * 2.0, rad * 2.0), Color("221a18"))
	if r == game.grid.floor_row - 1:
		var x := x0
		var k := 0
		while x < x0 + w - 0.5:
			ci.draw_rect(Rect2(x, 0, minf(T * 0.25, x0 + w - x), T * 0.08), Color("ffd23a") if k % 2 == 0 else Color("1a1a1a"))
			x += T * 0.25
			k += 1


func _pop_scale(t: Tile) -> float:
	var dt: float = game.time - t.placed_at
	if dt < 0.0 or dt > 0.4:
		return 1.0
	var k := dt / 0.4
	return 1.0 - cos(k * 3.0 * PI) * exp(-5.0 * k) * 0.5


# --- live tiles: the goo's current tile and the source pump ----------------------

func _draw_live(ci: CanvasItem) -> void:
	if game == null or game.T <= 0.0:
		return
	var T: float = game.T
	var grid: Grid = game.grid
	var rr: Vector2i = game.cam.row_range()
	var src := grid.get_tile(Tuning.SOURCE_COL, 0)
	if src != null and rr.x <= 0:
		var pal := Zones.theme(0)
		var frac: float = 1.0 - clampf(game.countdown / Tuning.COUNTDOWN_TIME, 0.0, 1.0)
		PipeArt.draw_source(ci, tile_rect(Tuning.SOURCE_COL, 0).get_center(), T, src, pal, pal["goo"], game.time, frac)
	if game.flow.active:
		var t := grid.get_tile(game.flow.col, game.flow.row)
		if t != null and t.kind == Tile.EMPTY and t.piece >= 0:
			var center := tile_rect(game.flow.col, game.flow.row).get_center()
			if SpriteAtlas.dry_sprite_for(t) >= 0 and atlas.tile_px > 0:
				# The pipe itself comes from the atlas (live_base); only the water is drawn.
				PipeArt.draw_water(ci, center, T, t, game.time)
			else:
				PipeArt.draw_pipe(ci, center, T, t.piece, Zones.theme_for_row(game.flow.row), t, 1.0, game.time, false)


## The live tile's dry pipe, stamped from the atlas (much cheaper than drawing
## the pipe's metal as vectors every frame).
func _draw_live_base(ci: CanvasItem) -> void:
	if game == null or game.T <= 0.0 or atlas.tile_px <= 0 or not game.flow.active:
		return
	var t: Tile = game.grid.get_tile(game.flow.col, game.flow.row)
	if t == null:
		return
	var s := SpriteAtlas.dry_sprite_for(t)
	if s < 0:
		return
	var tex := atlas.tile_tex(Zones.index_for_row(game.flow.row))
	ci.draw_texture_rect_region(tex, tile_rect(game.flow.col, game.flow.row), atlas.region(s))


# --- glow (additive) ---------------------------------------------------------------

func _draw_glow(ci: CanvasItem) -> void:
	if game == null or game.T <= 0.0:
		return
	var T: float = game.T
	var pulse := 0.8 + 0.2 * sin(game.time * 6.0)
	if game.flow.active or game.state == game.State.SPILL:
		var hp := w2s(game.flow.head_world())
		var gc: Color = Zones.theme_for_row(game.flow.row)["goo"]
		var r := T * 0.9 * pulse
		ci.draw_texture_rect(atlas.soft, Rect2(hp - Vector2(r, r), Vector2(r, r) * 2.0), false, PipeArt.fade(gc, 0.45))
	if game.quality >= 1:
		return  # Lighter mode: no particle glow.
	var b: Rect2 = game.board_rect
	var off := shake_offset()
	var ox: float = b.position.x + off.x
	var oy: float = b.end.y + game.cam.y * T + off.y
	for i in _pp.size():
		if _pw[i] == 0:
			continue
		var a: float = clampf(_pl[i] / _pm[i], 0.0, 1.0)
		var r: float = _ps[i] * T * 3.0
		var c: Color = _pc[i]
		c.a *= 0.4 * a
		var p: Vector2 = _pp[i]
		ci.draw_texture_rect(atlas.soft, Rect2(ox + p.x * T - r, oy - p.y * T - r, r * 2.0, r * 2.0), false, c)


# --- particles ---------------------------------------------------------------------

func burst(world_pos: Vector2, col: Color, count: int, speed := 3.0, size := 0.07, life := 0.7, grav := 6.0, glowing := true) -> void:
	for i in count:
		var a := randf() * TAU
		var s := speed * (0.35 + randf() * 0.65)
		_add_part(world_pos, Vector2(cos(a), sin(a)) * s + Vector2(0, speed * 0.3), life * (0.6 + randf() * 0.4),
				life, col, size * (0.6 + randf() * 0.8), grav, glowing)


func float_text(world_pos: Vector2, text: String, col: Color, size := 0.34, life := 1.1) -> void:
	texts.append({"p": world_pos, "text": text, "col": col, "life": life, "max": life, "size": size})


## Snowflakes drifting down over the board (Flow-freeze).
func snow(count: int) -> void:
	var cam: GameCamera = game.cam
	for i in count:
		var life := 1.6 + randf() * 1.2
		_add_part(Vector2(randf() * Tuning.COLS, cam.y + cam.visible_rows * randf()),
				Vector2(randf_range(-0.25, 0.25), -0.5 - randf() * 0.4), life, life,
				Color(0.92, 0.98, 1.0, 0.95), 0.03 + randf() * 0.03, 0.0, false)


## Water dripping off the pipes as the freeze ends.
func thaw_drips() -> void:
	var grid: Grid = game.grid
	var rr: Vector2i = game.cam.row_range()
	for r in range(maxi(rr.x, grid.floor_row), rr.y + 1):
		for c in Tuning.COLS:
			var t := grid.get_tile(c, r)
			if t != null and t.has_goo() and randf() < 0.5:
				burst(Vector2(c + 0.5, r + 0.5), Zones.theme_for_row(r)["goo"], 3, 1.2, 0.05, 0.9, 7.0, false)


func update_fx(dt: float) -> void:
	var target := 1.0
	if game.state == game.State.RUNNING:
		target = game.effective_speed()
	elif game.state == game.State.COUNTDOWN:
		target = game.hold_speed_mult() if game.speed_held() else 1.0
	elif game.state != game.State.TITLE:
		target = 0.35
	# A gentler on-screen pace than the water itself (x64 would be a blur).
	target = pow(target, 0.7)
	flow_motion = lerpf(flow_motion, target, 1.0 - exp(-dt * (6.0 if target < flow_motion else 3.0)))
	flow_clock += dt * flow_motion
	# Particles: move, age, and drop the dead ones in place.
	var n := _pp.size()
	var j := 0
	for i in n:
		var l: float = _pl[i] - dt
		if l <= 0.0:
			continue
		var v: Vector2 = _pv[i]
		v.y -= _pg[i] * dt
		_pv[j] = v
		_pp[j] = _pp[i] + v * dt
		_pl[j] = l
		if j != i:
			_pm[j] = _pm[i]
			_ps[j] = _ps[i]
			_pg[j] = _pg[i]
			_pc[j] = _pc[i]
			_pw[j] = _pw[i]
		j += 1
	if j < n:
		for a in [_pp, _pv, _pl, _pm, _ps, _pg, _pc, _pw]:
			a.resize(j)
	for t in texts:
		t["p"].y += dt * 0.7
		t["life"] -= dt
	texts = texts.filter(func(t): return t["life"] > 0.0)


# --- hover ghost (atlas sprites) -------------------------------------------

func _draw_fx_sprites(ci: CanvasItem) -> void:
	if game == null or game.T <= 0.0 or atlas.tile_px <= 0:
		return
	# Ghost of the next piece under the cursor.
	for cell in _hover_cells():
		var action: String = game.placement_mode(cell.x, cell.y)
		var ghost := -1
		if action == "place" or action == "replace":
			ghost = game.queue[0]
		elif action == "drop":
			ghost = game.held_piece
		if ghost >= 0:
			var tex := atlas.tile_tex(Zones.index_for_row(cell.y))
			ci.draw_texture_rect_region(tex, tile_rect(cell.x, cell.y), atlas.region(SpriteAtlas.item_cell(ghost)), Color(0.5, 0.5, 0.5, 0.5))


func _hover_cells() -> Array:
	var cells := []
	if not (game.state == game.State.COUNTDOWN or game.state == game.State.RUNNING) or game.paused:
		return cells
	if game.hover_active and game.is_tile_visible(game.hover.x, game.hover.y):
		cells.append(game.hover)
	if game.kb_active and game.kb_cursor != game.hover and game.is_tile_visible(game.kb_cursor.x, game.kb_cursor.y):
		cells.append(game.kb_cursor)
	return cells


# --- Flow-freeze frost -----------------------------------------------------------------------

## The frost only changes when the board does: draw it once (at full
## strength) and then just move it with the camera and fade it with the
## layer's alpha, instead of redrawing every iced pipe every frame.
func _sync_frost() -> void:
	var fa: float = game.freeze_amount() if game != null and game.T > 0.0 else 0.0
	if fa <= 0.0:
		if frost.visible:
			frost.visible = false
			_frost_key = ""
		return
	frost.visible = true
	frost.modulate.a = fa
	var rr: Vector2i = game.cam.row_range()
	var vsum := 0
	for r in range(rr.x, rr.y + 1):
		vsum += game.grid.version(r)
	var key := "%d|%d|%d|%.3f|%.2f|%.2f" % [rr.x, rr.y, vsum, game.T, game.board_rect.position.x, game.board_rect.size.y]
	var off := shake_offset()
	if key != _frost_key:
		_frost_key = key
		_frost_cam = game.cam.y
		_frost_off = off
		frost.position = Vector2.ZERO
		frost.queue_redraw()
	else:
		frost.position = Vector2(off.x - _frost_off.x, (game.cam.y - _frost_cam) * game.T + off.y - _frost_off.y)


func _draw_frost(ci: CanvasItem) -> void:
	if game == null or game.T <= 0.0 or game.freeze_timer <= 0.0:
		return
	var T: float = game.T
	var b: Rect2 = game.board_rect
	var grid: Grid = game.grid
	var rr: Vector2i = game.cam.row_range()
	var off := shake_offset()
	# A cold tint over the whole board (taller than the board, as the layer
	# moves with the camera), and frost creeping in from the walls.
	ci.draw_rect(Rect2(b.position.x - T * 0.2 + off.x, b.position.y - T * 2.0, b.size.x + T * 0.4, b.size.y + T * 4.0), Color(0.72, 0.9, 1.0, 0.24))
	for r in range(rr.x, rr.y + 1):
		var y := row_y(r) + off.y
		for x in [b.position.x + off.x, b.end.x + off.x]:
			var fr := T * (0.7 + 0.25 * h01(r * 3.7 + x))
			ci.draw_texture_rect(atlas.soft, Rect2(x - fr, y + T * 0.5 - fr, fr * 2.0, fr * 2.0), false, Color(0.88, 0.97, 1.0, 0.4))
	var ice := Color(0.9, 0.98, 1.0, 0.95)
	var sheen := Color(1, 1, 1, 0.8)
	for r in range(maxi(rr.x, grid.floor_row), rr.y + 1):
		for c in Tuning.COLS:
			var t := grid.get_tile(c, r)
			if t == null or t.hidden or t.kind != Tile.EMPTY or t.piece < 0:
				continue
			var center := tile_rect(c, r).get_center()
			# The water in the pipe turns to ice.
			var w := PipeArt.W_GOO * T * (PipeArt.NARROW_SCALE if t.narrow else 1.0)
			for ch in 2:
				if t.fill_entry[ch] < 0:
					continue
				var en: int = t.fill_entry[ch]
				var ex := Pieces.exit_dir(t.piece, en)
				var p: float = t.fill[ch]
				PipeArt.stroke(ci, center, T, en, ex, w * 1.05, ice, 0.0, p)
				if t.special == Tile.SP_RESERVOIR and p > PipeArt.BULGE_T0:
					PipeArt.stroke(ci, center, T, en, ex, PipeArt.W_BULGE_GOO * T, ice, PipeArt.BULGE_T0, minf(p, 1.0 - PipeArt.BULGE_T0))
				PipeArt.stroke(ci, center, T, en, ex, w * 0.3, sheen, 0.0, p, w * 0.25)
			# Frost crystals on every pipe.
			for k in 2:
				var hx := float((t.rnd >> (k * 7)) & 63) / 63.0 - 0.5
				var hy := float((t.rnd >> (k * 7 + 13)) & 63) / 63.0 - 0.5
				var fsz := T * (0.3 + 0.12 * k)
				var fp := center + Vector2(hx, hy) * T * 0.62
				ci.draw_texture_rect(atlas.flake, Rect2(fp - Vector2(fsz, fsz) * 0.5, Vector2(fsz, fsz)), false, Color(1, 1, 1, 0.85))


# --- fx (bubbles, outlines, particles, text) -------------------------------------------

func _draw_fx(ci: CanvasItem) -> void:
	if game == null or game.T <= 0.0:
		return
	var T: float = game.T
	var grid: Grid = game.grid
	var rr: Vector2i = game.cam.row_range()
	var time: float = game.time
	if game.quality < 1:
		_draw_pipe_bubbles(ci, T, grid, rr, time)
	_draw_fx_rest(ci, T, time)


func _draw_pipe_bubbles(ci: CanvasItem, T: float, grid: Grid, rr: Vector2i, time: float) -> void:
	# Bubbles drifting along full pipes.
	var br := PipeArt.W_GOO * T * 0.17
	var sz := Vector2(br, br) * 2.0
	var off := shake_offset()
	var x0: float = game.board_rect.position.x + off.x
	for r in range(maxi(rr.x, grid.floor_row), rr.y + 1):
		var list := _row_bubbles(grid, r)
		var n := list.size()
		if n == 0:
			continue
		var cy := row_y(r) + off.y + T * 0.5
		var i := 0
		while i < n:
			var tt := fposmod(time * 0.55 + list[i + 6], 1.0)
			var px: float
			var py: float
			if list[i + 1] < 0.5:
				px = lerpf(list[i + 2], list[i + 4], tt)
				py = lerpf(list[i + 3], list[i + 5], tt)
			else:
				var ang: float = list[i + 4] + list[i + 5] * tt
				px = list[i + 2] + cos(ang) * 0.5
				py = list[i + 3] + sin(ang) * 0.5
			ci.draw_texture_rect(atlas.disk, Rect2(Vector2(x0 + (list[i] + 0.5 + px) * T - br, cy + py * T - br), sz), false,
					Color(list[i + 7], list[i + 8], list[i + 9], list[i + 10]))
			i += BUB_STRIDE


## The bubbles of row r (see _bub_cache): column, path kind (0 straight from
## a to b, 1 an arc: centre, start angle, sweep), phase, colour.
func _row_bubbles(grid: Grid, r: int) -> PackedFloat32Array:
	var ver := grid.version(r)
	var e = _bub_cache.get(r)
	if e != null and int(e[0]) == ver:
		return e[1]
	if _bub_cache.size() > 96:
		_bub_cache.clear()
	var out := PackedFloat32Array()
	for c in Tuning.COLS:
		var t := grid.get_tile(c, r)
		if t == null or not t.has_goo() or t.special == Tile.SP_RESERVOIR or t.kind != Tile.EMPTY:
			continue
		for ch in 2:
			if t.fill_entry[ch] < 0 or t.fill[ch] < 1.0:
				continue
			var en: int = t.fill_entry[ch]
			var ex := Pieces.exit_dir(t.piece, en)
			var a: Vector2 = Pieces.SIDE_MID[en]
			var bb: Vector2 = Pieces.SIDE_MID[ex]
			var col: Color = t.fill_color[ch].lightened(0.75)
			var phase := float((t.rnd + ch * 37) & 0xffff) / 997.0
			if ex == Pieces.opposite(en):
				out.append_array([c, 0.0, a.x, a.y, bb.x, bb.y, phase, col.r, col.g, col.b, col.a * 0.75])
			else:
				var cc := a + bb
				var a0 := (a - cc).angle()
				var d := wrapf((bb - cc).angle() - a0, -PI, PI)
				out.append_array([c, 1.0, cc.x, cc.y, a0, d, phase, col.r, col.g, col.b, col.a * 0.75])
	_bub_cache[r] = [ver, out]
	return out


func _draw_fx_rest(ci: CanvasItem, T: float, time: float) -> void:
	# Unlock mode: the picked-up pipe gets a bright pulsing frame.
	if game.held_piece >= 0 and game.held_from.x >= 0:
		var hr := tile_rect(game.held_from.x, game.held_from.y)
		var hp := 0.6 + 0.4 * sin(time * 10.0)
		ci.draw_rect(hr.grow(-T * 0.02), Color(1.0, 0.85, 0.2, hp), false, maxf(3.0, T * 0.07))
	_draw_sight_glasses(ci, T)
	_draw_hover(ci, T)
	if game.state == game.State.SPILL or game.state == game.State.GAMEOVER:
		_draw_spill(ci, T)
	var b: Rect2 = game.board_rect
	var off := shake_offset()
	var ox: float = b.position.x + off.x
	var oy: float = b.end.y + game.cam.y * T + off.y
	for i in _pp.size():
		var a: float = clampf(_pl[i] / _pm[i], 0.0, 1.0)
		var r: float = _ps[i] * T * (0.5 + 0.5 * a)
		var c: Color = _pc[i]
		c.a *= a
		var p: Vector2 = _pp[i]
		ci.draw_texture_rect(atlas.disk, Rect2(ox + p.x * T - r, oy - p.y * T - r, r * 2.0, r * 2.0), false, c)
	# The freeze rings out from the water's leading edge.
	if game.freeze_timer > 0.0:
		var since: float = game.time - game.freeze_started
		if since < 0.8:
			var hp := w2s(game.flow.head_world())
			ci.draw_arc(hp, since / 0.8 * T * 7.0, 0.0, TAU, 48, Color(0.92, 0.99, 1.0, (1.0 - since / 0.8) * 0.9), maxf(3.0, T * 0.09), PipeArt.aa)



## A glass channel down each side wall of the board, with the water's current
## in it: bubbles rise at the same pace as the background (on phones the board
## covers most of the background, so this is where you see the speed).
func _draw_sight_glasses(ci: CanvasItem, T: float) -> void:
	if game.state == game.State.TITLE:
		return
	var b: Rect2 = game.board_rect
	var off := shake_offset()
	var ww := T * 0.2
	var w := maxf(3.0, ww * 0.42)
	var goo: Color = Zones.theme_for_row(game.height)["goo"]
	var frozen: bool = game.freeze_timer > 0.0
	if b.size.x <= 0.0:
		return
	var water := Color(0.8, 0.95, 1.0) if frozen else goo
	var stretch := clampf((flow_motion - 1.6) / 5.0, 0.0, 1.0)
	for side in 2:
		var x := (b.position.x - ww * 0.5 if side == 0 else b.end.x + ww * 0.5) + off.x
		var glass := Rect2(x - w * 0.5, b.position.y, w, b.size.y)
		ci.draw_rect(glass, Color(0, 0, 0, 0.55))
		ci.draw_rect(glass.grow(-1.0), PipeArt.fade(water, 0.38))
		ci.draw_rect(Rect2(glass.position.x + w * 0.18, glass.position.y, maxf(1.0, w * 0.16), glass.size.y), Color(1, 1, 1, 0.18))
		var span := b.size.y + 40.0
		var fcT := flow_clock * T
		for i in (9 if game.quality < 1 else 4):
			var k := 600 + (i + side * 16) * 3
			var y := b.end.y + 20.0 - fposmod(_rt[k] * span + fcT * (1.1 + _rt[k + 1] * 0.9), span)
			var r := w * (0.22 + 0.16 * _rt[k + 2])
			var l := r * 2.0 * (1.0 + stretch * 4.0)
			ci.draw_texture_rect(atlas.disk, Rect2(Vector2(x - r, y - l * 0.5), Vector2(r * 2.0, l)), false, Color(1, 1, 1, 0.75))


## Floating score text (on the sharp layer in PS1 mode).
func _draw_text(ci: CanvasItem) -> void:
	if game == null or game.T <= 0.0:
		return
	var T: float = game.T
	var f := PipeArt.font()
	for t in texts:
		var a: float = clampf(t["life"] / t["max"] * 1.6, 0.0, 1.0)
		var fs := int(t["size"] * T)
		var pos := w2s(t["p"]) + Vector2(-T * 2.0, fs * 0.35)
		ci.draw_string_outline(f, pos, t["text"], HORIZONTAL_ALIGNMENT_CENTER, T * 4.0, fs, maxi(3, fs / 4), Color(0, 0, 0, a))
		ci.draw_string(f, pos, t["text"], HORIZONTAL_ALIGNMENT_CENTER, T * 4.0, fs, PipeArt.fade(t["col"], a))


func _draw_hover(ci: CanvasItem, T: float) -> void:
	for cell in _hover_cells():
		var mode: String = game.placement_mode(cell.x, cell.y)
		var rect := tile_rect(cell.x, cell.y)
		var col := Color(1, 1, 1, 0.85)
		match mode:
			"replace":
				col = Color("ffb030")
			"flip":
				col = Color("6ad8ff")
			"drop":
				col = Color("7dff3a")
			"deselect":
				col = Color("ffd23a")
			"locked", "no":
				col = Color(1, 0.3, 0.3, 0.6)
		ci.draw_rect(rect.grow(-T * 0.03), col, false, maxf(2.0, T * 0.05))


func _draw_spill(ci: CanvasItem, T: float) -> void:
	var sp: Dictionary = game.spill
	if sp.is_empty():
		return
	var k := clampf((game.time - float(sp["t"])) / 1.2, 0.0, 1.0)
	var pos := w2s(sp["p"])
	var col: Color = sp["col"]
	var rad := T * (0.15 + 0.35 * sqrt(k))
	for i in 7:
		var a := i * TAU / 7.0 + float(sp["seed"])
		var r2 := rad * (0.45 + 0.2 * h01(i + float(sp["seed"])))
		var p := pos + Vector2.from_angle(a) * rad * 0.7
		ci.draw_texture_rect(atlas.disk, Rect2(p - Vector2(r2, r2), Vector2(r2, r2) * 2.0), false, col)
	ci.draw_texture_rect(atlas.disk, Rect2(pos - Vector2(rad, rad), Vector2(rad, rad) * 2.0), false, col)
	var hr := rad * 0.3
	ci.draw_texture_rect(atlas.disk, Rect2(pos - Vector2(rad, rad) * 0.3 - Vector2(hr, hr), Vector2(hr, hr) * 2.0), false, col.lightened(0.5))


# --- backdrop (textured quads, redrawn every frame) -----------------------------------

func _view_palette() -> Array:
	var cr: float = game.cam.y + game.cam.visible_rows * 0.5
	var zi := Zones.index_for_row(int(floor(cr)))
	var local := cr - zi * Tuning.ZONE_ROWS
	var to := Zones.theme(zi)
	if zi > 0 and local < 6.0:
		return [Zones.theme(zi - 1), to, smoothstep(0.0, 6.0, local)]
	return [to, to, 1.0]


func _mix(a: Dictionary, b: Dictionary, key: String, t: float) -> Color:
	return (a[key] as Color).lerp(b[key], t)


func _draw_backdrop(ci: CanvasItem) -> void:
	if game == null or game.T <= 0.0:
		return
	var vp := _view_palette()
	var vs: Vector2 = game.view_size
	var top := _mix(vp[0], vp[1], "bg_top", vp[2])
	var bottom := _mix(vp[0], vp[1], "bg_bottom", vp[2])
	ci.draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(vs.x, 0), vs, Vector2(0, vs.y)]),
			PackedColorArray([top, top, bottom, bottom]))
	# Only the strips beside the board (and the panel) show: skip what's behind them.
	var b: Rect2 = game.board_rect
	_hide_a = Vector2(b.position.x - game.T * 0.3, b.end.x + game.T * 0.3)
	var q: Rect2 = game.queue_rect
	_hide_b = Vector2(q.position.x, q.end.x) if not game.portrait else Vector2(-1.0, -1.0)
	if game.quality >= 1:
		return  # Lighter mode: just the gradient.
	if vp[2] < 1.0:
		_deco(ci, vp[0], 1.0 - vp[2])
	_deco(ci, vp[1], vp[2])
	if game.quality >= 1:
		return  # Lighter mode: just the gradient.
	_draw_current(ci, _mix(vp[0], vp[1], "accent", vp[2]))


## The current: bubbles rising through the background at the water's pace,
## stretching into streaks when it runs fast, with faint flow lines.
func _draw_current(ci: CanvasItem, acc: Color) -> void:
	var vs: Vector2 = game.view_size
	var fc := flow_clock
	var stretch := clampf((flow_motion - 1.6) / 5.0, 0.0, 1.0)
	var span := vs.y + 120.0
	if stretch > 0.0:
		var lc := PipeArt.fade(acc, 0.1 * stretch)
		var l := 60.0 + 140.0 * stretch
		for i in 8:
			var k := i * 3
			var x := _rt[k] * vs.x
			if _behind(x):
				continue
			var y := vs.y + 60.0 - fposmod(_rt[k + 1] * span + fc * (160.0 + _rt[k + 2] * 120.0), span)
			ci.draw_rect(Rect2(x, y - l, 2.0, l), lc)
	var white := Color.WHITE.lerp(acc, 0.4)
	var tex: Texture2D = atlas.ring if stretch < 0.3 else atlas.disk
	var base_a := 0.3 if stretch < 0.3 else 0.22
	var wob := 5.0 * (1.0 - stretch)
	var t: float = game.time
	for i in 20:
		var k := 40 + i * 5
		var x := _rt[k] * vs.x
		if _behind(x):
			continue
		x += sin(t * 0.9 + i * 1.3) * wob
		var y := vs.y + 60.0 - fposmod(_rt[k + 1] * span + fc * (40.0 + _rt[k + 2] * 60.0), span)
		var r := 2.5 + _rt[k + 3] * 5.5
		var l := r * 2.0 * (1.0 + stretch * 5.0)
		ci.draw_texture_rect(tex, Rect2(x - r, y - l * 0.5, r * 2.0, l), false, PipeArt.fade(white, base_a * (0.6 + 0.4 * _rt[k + 4])))


var _hide_a := Vector2(-1, -1)
var _hide_b := Vector2(-1, -1)


func _behind(x: float) -> bool:
	return (x > _hide_a.x and x < _hide_a.y) or (x > _hide_b.x and x < _hide_b.y)


func _dot(ci: CanvasItem, tex: Texture2D, p: Vector2, r: float, col: Color) -> void:
	ci.draw_texture_rect(tex, Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0), false, col)


func _deco(ci: CanvasItem, pal: Dictionary, alpha: float) -> void:
	if alpha <= 0.01:
		return
	var vs: Vector2 = game.view_size
	var T: float = game.T
	var t: float = game.time
	var fc := flow_clock  # Things that drift move at the water's pace.
	var scroll: float = game.cam.y * T
	var acc: Color = pal["accent"]
	match pal["deco"]:
		"bubbles":
			var rc := PipeArt.fade(acc, 0.3 * alpha)
			var hc := PipeArt.fade(Color.WHITE, 0.18 * alpha)
			for i in 18:
				var k := 200 + i * 4
				var x := _rt[k] * vs.x
				if _behind(x):
					continue
				x += sin(t + i) * 6.0
				var sp := 18.0 + _rt[k + 1] * 40.0
				var y := vs.y - fposmod(_rt[k + 2] * vs.y + fc * sp + scroll * 0.3, vs.y + 60.0) + 30.0
				var r := 4.0 + _rt[k + 3] * 10.0
				_dot(ci, atlas.ring, Vector2(x, y), r, rc)
				_dot(ci, atlas.disk, Vector2(x - r * 0.35, y - r * 0.35), r * 0.25, hc)
		"gears":
			for i in 8:
				var left := i % 2 == 0
				var gx := (h01(i * 2.3) * 0.12 + 0.02) * vs.x
				var x := gx if left else vs.x - gx
				var y := fposmod(h01(i * 4.1) * (vs.y + 300.0) + scroll * 0.4, vs.y + 300.0) - 150.0
				var r := 40.0 + h01(i * 9.1) * 60.0
				ci.draw_set_transform(Vector2(x, y), fc * (0.4 if left else -0.4) * (1.5 - h01(i)), Vector2.ONE)
				ci.draw_texture_rect(atlas.gear, Rect2(-r, -r, r * 2.0, r * 2.0), false, PipeArt.fade(pal["wall"].darkened(0.2), 0.55 * alpha))
			ci.draw_set_transform(Vector2.ZERO)
		"grid":
			var col := PipeArt.fade(acc, 0.16 * alpha)
			var gap := 48.0
			var y := vs.y + fposmod(scroll * 0.5, gap)
			while y > -gap:
				ci.draw_rect(Rect2(0, y - 1.0, vs.x, 2.0), col)
				y -= gap
			var x := fposmod(vs.x * 0.5, gap)
			while x < vs.x:
				ci.draw_rect(Rect2(x - 1.0, 0, 2.0, vs.y), col)
				x += gap
			for i in 6:
				var sx := h01(i * 6.6) * vs.x
				var sy := fposmod(h01(i * 3.3) * vs.y + scroll * 0.5 + fc * 30.0, vs.y)
				ci.draw_rect(Rect2(sx, vs.y - sy, 3, 18), PipeArt.fade(pal["goo"], 0.4 * alpha))
		"embers":
			var hot := Color("ff4a1a")
			for i in 24:
				var k := 300 + i * 5
				var x := _rt[k] * vs.x
				if _behind(x):
					continue
				x += sin(t * 1.3 + i) * 10.0
				var sp := 30.0 + _rt[k + 1] * 60.0
				var y := vs.y - fposmod(_rt[k + 2] * vs.y + fc * sp + scroll * 0.35, vs.y + 20.0)
				var fl := 0.5 + 0.5 * sin(t * 8.0 + i * 2.0)
				_dot(ci, atlas.soft, Vector2(x, y), 3.0 + _rt[k + 3] * 5.0, PipeArt.fade(acc.lerp(hot, _rt[k + 4]), (0.45 + 0.5 * fl) * alpha))
		"stars":
			for i in 60:
				var k := 440 + i * 5
				var x := _rt[k] * vs.x
				if _behind(x):
					continue
				var layer := 0.08 + _rt[k + 1] * 0.25
				var y := fposmod(_rt[k + 2] * vs.y + scroll * layer, vs.y)
				var tw := 0.5 + 0.5 * sin(t * (1.0 + _rt[k + 3] * 3.0) + i)
				_dot(ci, atlas.disk, Vector2(x, y), 0.8 + layer * 5.0, PipeArt.fade(Color.WHITE.lerp(acc, _rt[k + 4]), (0.3 + 0.6 * tw) * alpha))


# --- queue panel ---------------------------------------------------------------------------

func _queue_signature() -> String:
	# Includes whether each animation is running, so the frame after it ends is redrawn too.
	return "%s|%d|%s|%d|%s|%d|%d|%s|%s|%s|%d|%s" % [str(game.queue), game.zone_index, game.portrait,
			game.state, game.queue_rect, atlas.icon_px, atlas.tile_px,
			game.queue_shift > 0.0, game.lock_timer > 0.0, game.mode, game.held_piece, game.stats_rect]


func _draw_queue_bg(ci: CanvasItem) -> void:
	if game == null or game.T <= 0.0 or game.state == game.State.TITLE:
		return
	var q: Rect2 = game.queue_rect
	var pal := Zones.theme(game.zone_index)
	_sb.bg_color = Color(0.05, 0.06, 0.08, 0.88)
	_sb.set_corner_radius_all(18)
	_sb.set_border_width_all(3)
	_sb.border_color = Color(0.23, 0.7, 1.0, 0.55)
	ci.draw_style_box(_sb, q)
	var slots: Array = game.queue_slot_rects()
	var unlock: bool = game.mode == "unlock"
	for i in slots.size():
		if unlock and i > 0:
			break
		var sr: Rect2 = slots[i]
		_sb.bg_color = Color(1, 1, 1, 0.07) if i > 0 else PipeArt.fade(pal["tile"], 0.95)
		_sb.set_corner_radius_all(int(sr.size.x * 0.16))
		_sb.set_border_width_all(3 if i == 0 else 0)
		_sb.border_color = Color("3ab4ff")
		ci.draw_style_box(_sb, sr)
	_sb.set_border_width_all(0)


func _draw_queue_icons(ci: CanvasItem) -> void:
	if game == null or game.T <= 0.0 or game.state == game.State.TITLE or atlas.icon_px <= 0:
		return
	var slots: Array = game.queue_slot_rects()
	var shift: float = game.queue_shift
	var itex := atlas.icon_tex(game.zone_index)
	if game.mode == "unlock":
		if not slots.is_empty() and game.held_piece >= 0:
			var s0: Rect2 = slots[0]
			var sz := s0.size.x * 0.86
			ci.draw_texture_rect_region(itex, Rect2(s0.get_center() - Vector2(sz, sz) * 0.5, Vector2(sz, sz)), atlas.icon_region(game.held_piece))
		slots = []
	for i in slots.size():
		var sr: Rect2 = slots[i]
		var pr := sr
		var a := 1.0 if i == 0 else 0.85
		# Pieces slide one slot forward after each placement.
		if shift > 0.0:
			var nxt := sr
			if i + 1 < slots.size():
				nxt = slots[i + 1]
			elif i > 0:
				nxt = Rect2(sr.position + (sr.position - (slots[i - 1] as Rect2).position), sr.size)
			pr = Rect2(sr.position.lerp(nxt.position, shift), sr.size.lerp(nxt.size, shift))
			if i == slots.size() - 1:
				a *= 1.0 - shift
		var size := pr.size.x * 0.86
		ci.draw_texture_rect_region(itex, Rect2(pr.get_center() - Vector2(size, size) * 0.5, Vector2(size, size)),
				atlas.icon_region(game.queue[i]), Color(a, a, a, a))


func _draw_queue_fg(ci: CanvasItem) -> void:
	if game == null or game.T <= 0.0 or game.state == game.State.TITLE or game.lock_timer <= 0.0:
		return
	var slots: Array = game.queue_slot_rects()
	if slots.is_empty():
		return
	var s0: Rect2 = slots[0]
	_sb.bg_color = Color(0.6, 0.05, 0.05, 0.6)
	_sb.set_corner_radius_all(int(s0.size.x * 0.16))
	_sb.set_border_width_all(0)
	ci.draw_style_box(_sb, s0)
	var frac: float = game.lock_timer / Tuning.REPLACE_LOCK_TIME
	ci.draw_arc(s0.get_center(), s0.size.x * 0.3, -PI / 2, -PI / 2 + TAU * frac, 32, Color.WHITE, maxf(3.0, s0.size.x * 0.06), true)
	_text(ci, PipeArt.font(), s0.get_center() + Vector2(0, s0.size.y * 0.08), "LOCK", int(s0.size.x * 0.17), Color.WHITE)


func _text(ci: CanvasItem, f: Font, pos: Vector2, s: String, size: int, col: Color, align := HORIZONTAL_ALIGNMENT_CENTER) -> void:
	var w := 400.0
	var p := pos + Vector2(-w * 0.5, 0) if align == HORIZONTAL_ALIGNMENT_CENTER else pos - Vector2(18, 0)
	ci.draw_string_outline(f, p, s, align, w, size, maxi(3, size / 4), Color(0, 0, 0, 0.85 * col.a))
	ci.draw_string(f, p, s, align, w, size, col)
