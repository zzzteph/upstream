## ============================================================================
##  AI PLAYER - the AI SOLVE button: plays the board like a person would.
## ============================================================================
## It only uses what is on screen: it opens hatches by tapping them, reads the
## pipes it has uncovered, plans a route for the water a row or two ahead, and
## builds it by picking pipes up and putting them down - the same taps a
## player makes, through game.try_place(). A visible finger moves to every tap
## at a human pace (AI_MOVE_SPEED, AI_THINK_MIN/MAX). It never looks under a
## closed hatch or at the generator's guaranteed path.
##
## When the water is about to reach unfinished pipe it uses Flow-freeze; when
## lots of hatches are still closed and time is short it uses Reveal; when the
## route ahead is ready it holds the screen to speed the water up.
class_name AIPlayer
extends Node

const P := preload("res://scripts/pieces.gd")

var game  ## The Game node (main.gd).
var enabled := false
var pointer := Vector2.ZERO      ## Finger position on screen.
var pointer_visible := false
var press := 0.0                 ## 0..1 how far the finger is pressed in.
var ripple_age := 10.0           ## Seconds since the last tap (for the ripple).
var actions := 0                 ## Taps made (tests / stats).

var _queue: Array = []           ## Pending actions (see _act()).
var _from := Vector2.ZERO
var _move_t := 0.0
var _move_len := 0.0
var _wait := 0.0
var _arc := 1.0
var _hold_check := 0.0
var _layer: CanvasLayer
var _view: Control


class PointerView:
	extends Control
	var ai

	func _draw() -> void:
		if ai == null or not ai.enabled or not ai.pointer_visible:
			return
		var p: Vector2 = ai.pointer
		if ai.ripple_age < 0.45:
			var k: float = ai.ripple_age / 0.45
			draw_arc(p, 16.0 + 30.0 * k, 0.0, TAU, 40, Color(0.6, 1.0, 0.55, 1.0 - k), 3.0, true)
		var r := 16.0 - 4.0 * float(ai.press)
		draw_circle(p + Vector2(3, 5), r + 1.0, Color(0, 0, 0, 0.35))
		draw_circle(p, r, Color(1, 1, 1, 0.82))
		draw_arc(p, r, 0.0, TAU, 40, Color("7dff6a"), 3.0, true)
		draw_string(PipeArt.font(), p + Vector2(-r, 5), "AI", HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, 13, Color("0b2a12"))


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 15
	add_child(_layer)
	_view = PointerView.new()
	_view.ai = self
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layer.add_child(_view)


func set_enabled(on: bool) -> void:
	enabled = on
	_queue.clear()
	_wait = 0.3
	game.ai_hold = false
	press = 0.0
	if on:
		actions = 0
		pointer = game.view_size * Vector2(0.5, 0.8)
		pointer_visible = true
	_view.queue_redraw()


func _process(dt: float) -> void:
	ripple_age += dt
	if not enabled:
		return
	_view.queue_redraw()
	var playing: bool = game.state == game.State.COUNTDOWN or game.state == game.State.RUNNING
	if not playing or game.paused:
		game.ai_hold = false
		return
	if game.ai_hold:
		# Holding the screen: let go as soon as there's work or the water gets close.
		press = 1.0
		_hold_check -= dt
		if _hold_check > 0.0:
			return
		_hold_check = 0.2
		var f := _frontier()
		if f["eta"] >= 2.5 and not _needs_work(f):
			return
		game.ai_hold = false
	press = maxf(0.0, press - dt * 6.0)
	if _queue.is_empty():
		_wait -= dt
		if _wait > 0.0:
			return
		_queue = _decide()
		if _queue.is_empty():
			_wait = 0.25
			return
		_start_move()
	var target := _target_pos(_queue[0])
	if target.x < -9000.0:
		_queue.clear()  # The target scrolled away.
		return
	_move_t += dt
	var k := clampf(_move_t / maxf(0.05, _move_len), 0.0, 1.0)
	var e := k * k * (3.0 - 2.0 * k)
	var straight := _from.lerp(target, e)
	var side := (target - _from).orthogonal().normalized() * sin(e * PI) * minf(40.0, _from.distance_to(target) * 0.08) * _arc
	pointer = straight + side
	if k >= 1.0:
		pointer = target
		var a: Dictionary = _queue.pop_front()
		if _act(a):
			press = 1.0
			ripple_age = 0.0
			actions += 1
		else:
			_queue.clear()
		_wait = randf_range(Tuning.AI_THINK_MIN, Tuning.AI_THINK_MAX)
		if not _queue.is_empty():
			# The second half of a swap follows after a short beat.
			_wait = 0.0
			_start_move()


func _start_move() -> void:
	_from = pointer
	_move_t = -randf_range(0.03, 0.1)
	var target := _target_pos(_queue[0])
	_move_len = _from.distance_to(target) / Tuning.AI_MOVE_SPEED + 0.1
	_arc = -1.0 if randf() < 0.5 else 1.0


## Screen position of an action's target (x = -10000 when it's gone).
func _target_pos(a: Dictionary) -> Vector2:
	match a["kind"]:
		"tile":
			if not game.is_tile_visible(a["c"], a["r"]):
				return Vector2(-10000, 0)
			return game.renderer.tile_rect(a["c"], a["r"]).get_center() + a.get("jitter", Vector2.ZERO)
		"freeze":
			return game.ui.btn_freeze.get_global_rect().get_center()
		"reveal":
			return game.ui.btn_reveal.get_global_rect().get_center()
		"hold":
			var b: Rect2 = game.board_rect
			return Vector2(b.get_center().x, b.position.y + b.size.y * 0.25)
	return pointer


## Carry out a tap. Returns false if it no longer makes sense.
func _act(a: Dictionary) -> bool:
	match a["kind"]:
		"tile":
			var c: int = a["c"]
			var r: int = a["r"]
			var t: Tile = game.grid.get_tile(c, r)
			if t == null or not game.is_tile_visible(c, r):
				return false
			match a["why"]:
				"flip":
					if not t.hidden:
						return false
				"pick":
					if game.held_piece >= 0 or not t.is_loose():
						return false
				"drop":
					if game.held_piece < 0 or not (t.is_slot() or t.is_loose()) or Vector2i(c, r) == game.held_from:
						return false
				"deselect":
					if game.held_piece < 0:
						return false
			game.try_place(c, r)
			return true
		"freeze":
			return game.use_freeze()
		"reveal":
			return game.use_reveal()
		"hold":
			game.ai_hold = true
			return true
	return false


# --- reading the board ----------------------------------------------------------------------

## Follow the water from where it is through every pipe already connected, to
## the first cell that isn't: the frontier. Also estimates the seconds left
## before the water gets there.
func _frontier() -> Dictionary:
	var g = game
	var c: int
	var r: int
	var e: int
	var tiles := 0.0
	var extra := 0.0
	if g.flow.active:
		var cur: Tile = g.grid.get_tile(g.flow.col, g.flow.row)
		tiles = (1.0 - g.flow.progress) * Flow.time_factor(cur)
		var v: Vector2i = P.DIR_VEC[g.flow.exit]
		c = g.flow.col + v.x
		r = g.flow.row + v.y
		e = P.opposite(g.flow.exit)
	else:
		c = Tuning.SOURCE_COL
		r = 1
		e = P.S
		extra = maxf(0.0, g.countdown) if not g.tutorial.active else 99.0
	var chain: Array = []
	for i in 80:
		if c < 0 or c >= Tuning.COLS:
			break
		var t: Tile = g.grid.get_tile(c, r)
		if t == null or Flow.check_enter(t, e) != "":
			break
		var ex := P.exit_dir(t.piece, e)
		chain.append(Vector2i(c, r))
		tiles += Flow.time_factor(t)
		var v: Vector2i = P.DIR_VEC[ex]
		c += v.x
		r += v.y
		e = P.opposite(ex)
	var speed: float = g.effective_speed()
	if speed <= 0.0:
		speed = maxf(0.01, g.height_speed() * float(Tuning.DIFFICULTY_SPEED.get(g.difficulty, 1.0)))
		extra += maxf(0.0, g.freeze_timer)
	var eta: float = tiles * Tuning.BASE_SEGMENT_TIME / speed + extra
	return {"c": c, "r": r, "e": e, "chain": chain, "eta": eta}


func _needs_work(f: Dictionary) -> bool:
	if _hidden_in_row(f["r"]).size() > 0:
		return true
	var plan := _plan(f["c"], f["r"], f["e"], _set_of(f["chain"]))
	return not plan.is_empty() and plan["needs"].size() > 0


func _set_of(cells: Array) -> Dictionary:
	var d := {}
	for v in cells:
		d[v] = true
	return d


## Closed hatches in row r that are on screen, nearest to column `near` first.
func _hidden_in_row(r: int, near := -1) -> Array:
	var out: Array = []
	for c in Tuning.COLS:
		var t: Tile = game.grid.get_tile(c, r)
		if t != null and t.hidden and game.is_tile_visible(c, r):
			out.append(Vector2i(c, r))
	if near >= 0:
		out.sort_custom(func(a, b): return absi(a.x - near) < absi(b.x - near))
	return out


## What cell (c, r) needs so the water can go from side `en` to side `ex`:
## {"ok": true} if it already works, {"need": piece} for a swap, {} if it can't.
func _cell(c: int, r: int, en: int, ex: int, blocked: Dictionary) -> Dictionary:
	if c < 0 or c >= Tuning.COLS or blocked.has(Vector2i(c, r)):
		return {}
	var t: Tile = game.grid.get_tile(c, r)
	if t == null or t.hidden or t.kind != Tile.EMPTY or t.has_goo():
		return {}
	if t.piece >= 0 and P.exit_dir(t.piece, en) == ex and (t.special != Tile.SP_ONEWAY or t.oneway_entry == en):
		return {"ok": true}
	if t.fixed or not game.is_tile_visible(c, r):
		return {}
	return {"need": P.piece_for(en, ex)}


## Every way through row r for water entering column a from side e: straight
## up, or along the row to a column b and then up.
func _segments(a: int, r: int, e: int) -> Array:
	var out: Array = []
	if e != P.N:
		out.append([[a, r, e, P.N]])
	for dir in [P.E, P.W]:
		if dir == e:
			continue
		var step := 1 if dir == P.E else -1
		var b := a + step
		while b >= 0 and b < Tuning.COLS:
			var cells: Array = [[a, r, e, dir]]
			var x := a + step
			while x != b:
				cells.append([x, r, P.opposite(dir), dir])
				x += step
			cells.append([b, r, P.opposite(dir), P.N])
			out.append(cells)
			b += step
	return out


## Score a list of cells: null if impossible, else {"needs": [...], "keep": {...}}.
func _evaluate(cells: Array, blocked: Dictionary) -> Variant:
	var needs: Array = []
	var keep := {}
	for cell in cells:
		var res := _cell(cell[0], cell[1], cell[2], cell[3], blocked)
		if res.is_empty():
			return null
		if res.has("ok"):
			keep[Vector2i(cell[0], cell[1])] = true
		else:
			needs.append({"cell": Vector2i(cell[0], cell[1]), "piece": res["need"]})
	return {"needs": needs, "keep": keep}


func _count(pool: Dictionary, piece: int, excl: Dictionary) -> int:
	var n := 0
	for v in pool.get(piece, []):
		if not excl.has(v):
			n += 1
	return n


## Loose pipes on screen that can be moved, by piece.
func _pool(exclude: Dictionary) -> Dictionary:
	var pool := {}
	var lo: int = maxi(game.grid.floor_row, floori(game.cam.y))
	var hi: int = mini(game.grid.top_row, floori(game.cam.y + game.cam.visible_rows))
	for r in range(lo, hi + 1):
		for c in Tuning.COLS:
			var t: Tile = game.grid.get_tile(c, r)
			if t == null or not t.is_loose() or exclude.has(Vector2i(c, r)) or not game.is_tile_visible(c, r):
				continue
			if not pool.has(t.piece):
				pool[t.piece] = []
			pool[t.piece].append(Vector2i(c, r))
	return pool


## How many needed pieces can't be found (crosses stand in for straights).
## Pipes on cells in `excl` (the route itself) don't count.
func _missing(needs: Array, pool: Dictionary, excl: Dictionary) -> int:
	var want := {}
	for n in needs:
		want[n["piece"]] = want.get(n["piece"], 0) + 1
	var spare_cross := _count(pool, P.CROSS, excl)
	var missing := 0
	for p in want:
		var have := _count(pool, p, excl)
		var short: int = maxi(0, want[p] - have)
		if short > 0 and P.is_straight(p):
			var use := mini(short, spare_cross)
			spare_cross -= use
			short -= use
		missing += short
	return missing


## The best route from the frontier through this row and, if it's open on
## screen, the next. {"needs", "keep", "missing"} or {} if there is no way.
func _plan(fc: int, fr: int, fe: int, chain: Dictionary) -> Dictionary:
	var best := {}
	var best_score := INF
	var pool := _pool({})
	var two_rows: bool = _hidden_in_row(fr + 1).is_empty() and game.is_tile_visible(0, fr + 1)
	for seg in _segments(fc, fr, fe):
		var ev1 = _evaluate(seg, chain)
		if ev1 == null:
			continue
		var options: Array = [ev1]
		var dead_end := 0.0
		if two_rows:
			options = []
			var used := chain.duplicate()
			for cell in seg:
				used[Vector2i(cell[0], cell[1])] = true
			var b: int = seg[seg.size() - 1][0]
			for seg2 in _segments(b, fr + 1, P.S):
				var ev2 = _evaluate(seg2, used)
				if ev2 == null:
					continue
				var keep: Dictionary = (ev1["keep"] as Dictionary).duplicate()
				keep.merge(ev2["keep"])
				# Steer away from routes that run straight into a rock or wall.
				var b2: int = seg2[seg2.size() - 1][0]
				var above: Tile = game.grid.get_tile(b2, fr + 2)
				var risk := 50.0 if above != null and not above.hidden and (above.kind == Tile.ROCK or above.fixed) else 0.0
				options.append({"needs": (ev1["needs"] as Array) + (ev2["needs"] as Array), "keep": keep, "risk": risk})
			if options.is_empty():
				# No way on through the next row from here: only as a last resort.
				options = [ev1]
				dead_end = 1000.0
		for opt in options:
			var excl: Dictionary = chain.duplicate()
			excl.merge(opt["keep"])
			var miss := _missing(opt["needs"], pool, excl)
			var score: float = dead_end + float(opt.get("risk", 0.0)) + miss * 100.0 + (opt["needs"] as Array).size() * 10.0 + seg.size()
			if score < best_score:
				best_score = score
				best = {"needs": opt["needs"], "keep": opt["keep"], "missing": miss, "score": score}
	return best


# --- deciding -------------------------------------------------------------------------------

## The next action (or a pick-and-drop pair), or [] to wait.
func _decide() -> Array:
	var g = game
	var f := _frontier()
	var fc: int = f["c"]
	var fr: int = f["r"]
	var chain := _set_of(f["chain"])
	var plan := _plan(fc, fr, f["e"], chain)
	# Frontier can't be used at all (rock, wall, full pipe): rebuild the last
	# connected pipe instead.
	var back := 0
	var ft: Tile = g.grid.get_tile(fc, fr)
	var known: bool = fc < 0 or fc >= Tuning.COLS or (ft != null and not ft.hidden)
	while (plan.is_empty() or float(plan.get("score", 0.0)) >= 1000.0) and known and back < 3 and not (f["chain"] as Array).is_empty():
		var last: Vector2i = f["chain"].pop_back()
		var lt: Tile = g.grid.get_tile(last.x, last.y)
		if lt == null or lt.fixed or lt.has_goo():
			break
		chain.erase(last)
		fc = last.x
		fr = last.y
		var prev_exit := -1
		if (f["chain"] as Array).is_empty():
			prev_exit = g.flow.exit if g.flow.active else P.N
			if g.flow.active and Vector2i(g.flow.col, g.flow.row) + P.DIR_VEC[g.flow.exit] != last:
				break
		else:
			var pv: Vector2i = f["chain"].back()
			prev_exit = _dir_between(pv, last)
		f["e"] = P.opposite(prev_exit)
		plan = _plan(fc, fr, f["e"], chain)
		back += 1
	var work := not plan.is_empty() and (plan["needs"] as Array).size() > 0
	var hidden_here := _hidden_in_row(fr, fc)
	# 1) In trouble: freeze the water.
	if g.freezes > 0 and g.freeze_timer <= 0.0 and g.state == g.State.RUNNING \
			and f["eta"] < Tuning.AI_FREEZE_WHEN and (work or not hidden_here.is_empty() or plan.is_empty()):
		return [{"kind": "freeze"}]
	# 2) Lots still closed and little time: Reveal the screen.
	if g.reveals > 0 and f["eta"] < 5.0:
		var closed := hidden_here.size() + _hidden_in_row(fr + 1).size() + _hidden_in_row(fr + 2).size()
		if closed >= 9:
			return [{"kind": "reveal"}]
	# 3) Something in hand from an interrupted swap: use it or put it back.
	if g.held_piece >= 0:
		if work:
			for n in plan["needs"]:
				if _fits(g.held_piece, n["piece"]):
					return [_tile(n["cell"], "drop")]
		if g.held_from.x >= 0:
			return [_tile(g.held_from, "deselect")]
	# 4) Open the hatches in the water's row, nearest first.
	if not hidden_here.is_empty():
		return [_tile(hidden_here[0], "flip")]
	# 5) And the row above, while there's time, so the plan can look two rows ahead.
	var hidden_next := _hidden_in_row(fr + 1, fc)
	if not hidden_next.is_empty() and (f["eta"] > 3.0 or plan.is_empty()):
		return [_tile(hidden_next[0], "flip")]
	# 6) Build the route: fetch a matching pipe for the first unfinished cell.
	if work:
		var excl := chain.duplicate()
		excl.merge(plan["keep"])
		var pool := _pool(excl)
		for n in plan["needs"]:
			var src := _source(n["piece"], n["cell"], pool, fr)
			if src.x >= 0:
				return [_tile(src, "pick"), _tile(n["cell"], "drop")]
	# 7) Route ready and nothing to open: hold the screen to speed things up.
	if not work and not plan.is_empty() and f["eta"] > 6.0 and g.state == g.State.RUNNING \
			and _hidden_in_row(fr + 1).is_empty():
		return [{"kind": "hold"}]
	if not work and plan.is_empty() and not hidden_next.is_empty():
		return [_tile(hidden_next[0], "flip")]
	return []


func _fits(item: int, piece: int) -> bool:
	var p := P.item_piece(item)
	return p == piece or (p == P.CROSS and P.is_straight(piece))


## The best loose pipe to fetch for `piece` at `cell`: from rows the water has
## already passed first, then this row, then further up; nearest first.
func _source(piece: int, cell: Vector2i, pool: Dictionary, fr: int) -> Vector2i:
	var cands: Array = []
	for p in ([piece, P.CROSS] if P.is_straight(piece) else [piece]):
		for v in pool.get(p, []):
			if v != cell:
				cands.append(v)
		if not cands.is_empty():
			break
	if cands.is_empty():
		return Vector2i(-1, -1)
	cands.sort_custom(func(a, b):
		var ka := (0 if a.y < fr else (1 if a.y == fr else 2)) * 100 + absi(a.x - cell.x) + absi(a.y - cell.y)
		var kb := (0 if b.y < fr else (1 if b.y == fr else 2)) * 100 + absi(b.x - cell.x) + absi(b.y - cell.y)
		return ka < kb)
	return cands[0]


func _tile(v: Vector2i, why: String) -> Dictionary:
	var T: float = game.T
	return {"kind": "tile", "c": v.x, "r": v.y, "why": why,
			"jitter": Vector2(randf_range(-0.14, 0.14), randf_range(-0.14, 0.14)) * T}


func _dir_between(a: Vector2i, b: Vector2i) -> int:
	for d in 4:
		if a + P.DIR_VEC[d] == b:
			return d
	return P.N
