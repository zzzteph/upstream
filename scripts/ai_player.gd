## ============================================================================
##  AI PLAYER - the AI SOLVE button: plays the board like a person would.
## ============================================================================
## It only uses what is on screen: it opens hatches by tapping them and reads
## the pipes it has uncovered - never what's under a closed hatch, nor the
## generator's guaranteed path. Every move goes through game.try_place(), the
## same taps a player makes, with a visible finger at a human pace
## (AI_MOVE_SPEED, AI_THINK_MIN/MAX).
##
## Each time it decides, it plans the best route for the water from where the
## water is right now through everything open on screen (_plan: Dijkstra over
## cell + entry side; pipes that already fit are nearly free, swaps cost more,
## pieces that are running short cost more still). Because it always plans from
## the water, a route that went wrong - a dead end, a missing piece, a rock
## behind a hatch - just gets re-planned and rebuilt. Then it works through a
## strategy (_decide): finish a half-done swap, Flow-freeze when the water would
## beat it to unfinished pipe, Reveal when there are too many hatches to open
## in time, fix the most urgent cell (with a narrow pipe if the water is
## close - it slows the water), open the hatch where the route stops, fix the
## rest, and once the route runs off the top of the screen, hold the screen to
## speed the water up.
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
var _hurry := false              ## Under time pressure: quicker moves, shorter pauses.
var last_plan := {}              ## The most recent plan (debugging / tests).
var _danger := false             ## The last decision saw the water about to win.
var tally := {}                  ## Taps by kind (debugging / tests).
var trace: Array = []            ## Recent decisions, when debugging (set trace_on).
var _plan_key: Array = []         ## What the last plan was made from (see _plan).
var _plan_cache := {}
var trace_on := false
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
		draw_circle(p, r * 0.28, Color("2e9b3a"))


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
		tally = {}
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
		_hold_check = 0.1
		var w := _water()
		var plan := _plan(w)
		var ae: float = float(plan.get("arrive_end", 0.0))
		var end: Vector2i = plan.get("end", Vector2i(w["c"], w["r"]))
		if (plan.get("needs", []) as Array).is_empty() and ae >= _hold_margin() and _hidden(end, int(w["row"])).is_empty():
			return
		game.ai_hold = false
	press = maxf(0.0, press - dt * 6.0)
	if _queue.is_empty():
		_wait -= dt
		if _wait > 0.0:
			return
		_queue = _decide()
		if trace_on:
			var lp := last_plan
			var nd: Array = lp.get("needs", [])
			trace.append("t=%.1f water(%d,%d) kind=%s end=%s arrive_end=%.1f needs=%s -> %s" % [game.time, game.flow.col, game.flow.row,
					lp.get("kind", "-"), lp.get("end", "-"), float(lp.get("arrive_end", -1.0)),
					str(nd.map(func(n): return "%s@%.1f" % [n["cell"], n["arrive"]])), str(_queue.map(func(a): return [a.get("why", a["kind"]), a.get("c", -1), a.get("r", -1)]))])
			if trace.size() > 60:
				trace.pop_front()
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
			var key: String = a.get("why", a["kind"])
			tally[key] = int(tally.get(key, 0)) + 1
		else:
			tally["failed"] = int(tally.get("failed", 0)) + 1
			_queue.clear()
		_wait = randf_range(Tuning.AI_THINK_MIN, Tuning.AI_THINK_MAX) * (0.35 if _hurry else 1.0)
		if not _queue.is_empty():
			# The second half of a swap follows after a short beat.
			_wait = 0.0
			_start_move()


func _start_move() -> void:
	_from = pointer
	_move_t = -randf_range(0.03, 0.1)
	var target := _target_pos(_queue[0])
	_move_len = _from.distance_to(target) / (Tuning.AI_MOVE_SPEED * (1.7 if _hurry else 1.0)) + (0.05 if _hurry else 0.08)
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

const SWAP_TIME := 1.3      ## Rough seconds for one pick-and-drop (two taps).
const SWAP_TIME_HURRY := 0.8 ## The same when hurrying.
const TAP_TIME := 0.6       ## Rough seconds for one tap.
const INF_COST := 1.0e9
const DEAD_END := 1000.0   ## How much worse a route into a dead end rates (per the row it reaches).


## Water speed in tiles per second-unit, without the AI's own hold.
func _speed() -> float:
	var s: float = game.height_speed()
	return maxf(0.01, s)


## Where the water goes next: the cell after the tile it is filling now, the
## side it comes in through, and the seconds until it gets there.
func _water() -> Dictionary:
	var g = game
	var sp := _speed()
	if g.flow.active:
		var cur: Tile = g.grid.get_tile(g.flow.col, g.flow.row)
		var v: Vector2i = P.DIR_VEC[g.flow.exit]
		var t0: float = (1.0 - g.flow.progress) * Flow.time_factor(cur) * Tuning.BASE_SEGMENT_TIME / sp
		t0 += maxf(0.0, g.freeze_timer)
		return {"c": g.flow.col + v.x, "r": g.flow.row + v.y, "e": P.opposite(g.flow.exit), "t0": t0, "row": g.flow.row}
	var wait: float = 99.0 if g.tutorial.active else maxf(0.0, g.countdown)
	return {"c": Tuning.SOURCE_COL, "r": 1, "e": P.S, "t0": wait + Tuning.BASE_SEGMENT_TIME / sp, "row": 0}


## Rows the AI may tap: their centres are on screen.
func _rows() -> Vector2i:
	var f := Engine.get_process_frames()
	if f == _rows_frame:
		return _rows_val
	_rows_frame = f
	_rows_val = _rows_now()
	return _rows_val


var _rows_frame := -1
var _rows_val := Vector2i.ZERO


func _rows_now() -> Vector2i:
	var lo: int = maxi(game.grid.floor_row, floori(game.cam.y))
	var hi: int = lo
	for r in range(lo, game.grid.top_row + 1):
		if game.is_tile_visible(0, r):
			hi = r
		elif r > lo:
			break
	return Vector2i(lo, hi)


## Loose pipes on screen, by piece: {piece: [cells]}.
func _pool() -> Dictionary:
	var f := Engine.get_process_frames()
	if f != _pool_frame:
		_pool_frame = f
		_pool_val = _pool_now()
	return _pool_val


var _pool_frame := -1
var _pool_val := {}


func _pool_now() -> Dictionary:
	var pool := {}
	var rows := _rows()
	for r in range(rows.x, rows.y + 1):
		for c in Tuning.COLS:
			var t: Tile = game.grid.get_tile(c, r)
			if t == null or not t.is_loose() or not game.is_tile_visible(c, r):
				continue
			if not pool.has(t.piece):
				pool[t.piece] = []
			pool[t.piece].append(Vector2i(c, r))
	return pool


## Closed hatches on screen, nearest to `near` first.
func _hidden(near: Vector2i, rmin := -1000000, rmax := 1000000) -> Array:
	var out: Array = []
	var rows := _rows()
	for r in range(maxi(rows.x, rmin), mini(rows.y, rmax) + 1):
		for c in Tuning.COLS:
			var t: Tile = game.grid.get_tile(c, r)
			if t != null and t.hidden and game.is_tile_visible(c, r):
				out.append(Vector2i(c, r))
	out.sort_custom(func(a, b): return absi(a.x - near.x) + absi(a.y - near.y) * 2 < absi(b.x - near.x) + absi(b.y - near.y) * 2)
	return out


## Cost for the water to go through cell (c, r) from side `en` out of side `ex`
## (INF_COST if it can't). Pipes that already fit cost almost nothing (slow
## ones - reservoirs and narrow pipes - even less: they buy time); a swap costs
## 10 plus a penalty when that piece is running short; going down costs extra.
func _step(c: int, r: int, en: int, ex: int, lo: int, hi: int, have: Dictionary, penalty: Dictionary) -> Array:
	if c < 0 or c >= Tuning.COLS or r < lo or r > hi:
		return [INF_COST, -1]
	var t: Tile = game.grid.get_tile(c, r)
	if t == null or t.hidden or t.kind != Tile.EMPTY:
		return [INF_COST, -1]
	var down := 6.0 if ex == P.S else 0.0
	if t.piece >= 0 and P.exit_dir(t.piece, en) == ex and (t.special != Tile.SP_ONEWAY or t.oneway_entry == en) \
			and t.fill_entry[P.channel_for(t.piece, en)] < 0:
		var slow := t.special == Tile.SP_RESERVOIR or t.narrow
		return [(0.1 if slow else 0.3) + down, -1]
	if t.fixed or t.has_goo() or not game.is_tile_visible(c, r):
		return [INF_COST, -1]
	var need := P.piece_for(en, ex)
	var n: int = have.get(need, 0)
	if P.is_straight(need):
		n += int(have.get(P.CROSS, 0))
	if n <= 0:
		return [INF_COST, -1]
	return [11.0 + float(penalty.get(need, 0.0)) + down, need]


## The best route for the water from where it is now, through everything open
## on screen: a Dijkstra search over (cell, entry side), then the best place
## to stop. Returns {"cells": [...], "end": Vector2i, "kind": String,
## "needs": [...], "missing": int, "arrive_end": float}.
##   kind "open"   - the route runs off the top of the screen (all built ahead)
##        "hidden" - it stops at a closed hatch (open it to see further)
##        "stuck"  - it stops at an open cell it can't fill yet (missing pipes)
##        "dead"   - it runs into a rock, wall or full pipe (only if nothing better)
func _plan(w: Dictionary) -> Dictionary:
	var rows := _rows()
	var lo: int = maxi(rows.x, int(w["row"]) - 2)
	var hi: int = rows.y
	# Nothing changed since the last plan (same board, same cell for the
	# water, same hand)? Reuse it, with the times moved on by how far the
	# water has got through its cell. (The hold check asks every 0.1 s.)
	var vsum := 0
	for r in range(lo, hi + 1):
		vsum += game.grid.version(r)
	var key := [int(w["c"]), int(w["r"]), int(w["e"]), lo, hi, vsum, game.held_piece, game.held_from, _danger, snappedf(_speed(), 0.05)]
	if key == _plan_key and not _plan_cache.is_empty():
		return _shifted(_plan_cache, float(_plan_cache["t0"]) - float(w["t0"]))
	_snapshot(lo, hi)
	var pool := _pool()
	var have := {}
	for p in pool:
		have[p] = (pool[p] as Array).size()
	var penalty := {}
	var best := {}
	# How strongly to snake across the full width before going up: strong while
	# the water is slow (more tubes, more points, more interesting), fading out
	# as it gets fast, and off when the last plan was in danger.
	var curvy := Tuning.AI_CURVY * clampf((Tuning.AI_CURVY_UNTIL_SPEED - _speed()) / 1.0, 0.0, 1.0)
	if _danger:
		curvy = 0.0
	for attempt in 4:
		best = _search(w, lo, hi, have, penalty, curvy)
		if best.is_empty():
			return {}
		# Check the pipes the route needs against what's on screen (cells the
		# route keeps don't count as spares). Short? Penalise and search again.
		var keep := {}
		for cell in best["cells"]:
			if cell["need"] < 0:
				keep[cell["v"]] = true
		var want := {}
		for n in best["needs"]:
			want[n["piece"]] = int(want.get(n["piece"], 0)) + 1
		var crosses := 0
		for v in pool.get(P.CROSS, []):
			if not keep.has(v):
				crosses += 1
		var missing := 0
		var short := {}
		for p in want:
			var n := 0
			for v in pool.get(p, []):
				if not keep.has(v):
					n += 1
			var lack: int = maxi(0, want[p] - n)
			if lack > 0 and P.is_straight(p):
				var use := mini(lack, crosses)
				crosses -= use
				lack -= use
			if lack > 0:
				short[p] = lack
				missing += lack
		best["missing"] = missing
		if missing == 0:
			break
		for p in short:
			penalty[p] = float(penalty.get(p, 0.0)) + 15.0 * short[p]
			if attempt >= 1:
				# Still short: only count the pipes that are really spare.
				have[p] = maxi(0, int(want[p]) - int(short[p]))
	_plan_key = key
	_plan_cache = best
	_plan_cache["t0"] = float(w["t0"])
	return best


## A copy of a plan with every arrival time `dt` seconds sooner.
func _shifted(plan: Dictionary, dt: float) -> Dictionary:
	var out := plan.duplicate(true)
	if dt == 0.0:
		return out
	for cell in out["cells"]:
		cell["arrive"] = float(cell["arrive"]) - dt
	for n in out["needs"]:
		n["arrive"] = float(n["arrive"]) - dt
	out["arrive_end"] = float(out["arrive_end"]) - dt
	return out


## The rows the planner looks at, read once per plan into flat arrays so the
## search never touches the grid. Cells are indexed (r - lo + 1) * SW + c + 1:
## a border of off-board cells all round (walls, the row below the range, the
## row above the screen).
const SW := Tuning.COLS + 2
var _s_lo := 0
var _s_hi := 0
var _s_rows := 0
var _s_fit := PackedFloat32Array()   ## cell * 16 + en * 4 + ex: cost through the pipe already there, or -1.
var _s_swap := PackedByteArray()     ## 1 = an open, visible cell whose pipe can be swapped.
var _s_kind := PackedByteArray()     ## cell * 4 + entry: end kind (0 open, 1 hidden, 2 stuck, 3 dead), 255 = not worked out yet.
var _s_esc := PackedInt32Array()     ## cell: ways on (see _escapes), -1 = not worked out yet.
var _s_span := PackedInt32Array()    ## (row index) * COLS + entry column: see _row_span, -1 = not worked out yet.
const KINDS := ["open", "hidden", "stuck", "dead"]
static var NEED := PackedInt32Array()   ## en * 4 + ex -> the piece that takes the water that way.
static var EXIT := PackedInt32Array()     ## piece * 4 + entry -> exit side, or -1.
static var CHAN := PackedInt32Array()     ## piece * 4 + entry -> fill channel.
static var STRAIGHT := PackedByteArray()  ## piece -> 1 for the two straight pipes.
static var OPP := PackedInt32Array([P.S, P.W, P.N, P.E])
static var ORDER := PackedInt32Array([P.N, P.E, P.W, P.S])   ## The order the search tries exits in.
static var DOFF := PackedInt32Array()     ## side -> cell index offset.
var _s_open := PackedByteArray()          ## 1 = the water might get through (closed hatch, or open with no water).
## What each cell is, for the end-of-route checks (rows lo-1 .. hi+1):
## 0 nothing there, 1 closed hatch, 2 open with no water (any pipe can go
## in), 3 a fixed pipe with no water, 4 blocked (rock, full pipe, ...).
var _s_cls := PackedByteArray()
var _s_pc := PackedInt32Array()           ## The pipe in a class-3 cell.
var _s_ow := PackedInt32Array()           ## A one-way pipe's entry side, else -1.


static func _tables() -> void:
	if not NEED.is_empty():
		return
	NEED.resize(16)
	for en in 4:
		for ex in 4:
			NEED[en * 4 + ex] = P.piece_for(en, ex) if en != ex else -1
	EXIT.resize(P.COUNT * 4)
	CHAN.resize(P.COUNT * 4)
	STRAIGHT.resize(P.COUNT)
	for pc in P.COUNT:
		STRAIGHT[pc] = 1 if P.is_straight(pc) else 0
		for en in 4:
			EXIT[pc * 4 + en] = P.exit_dir(pc, en)
			CHAN[pc * 4 + en] = P.channel_for(pc, en) if P.exit_dir(pc, en) >= 0 else 0
	DOFF.resize(4)
	for d in 4:
		var dv: Vector2i = P.DIR_VEC[d]
		DOFF[d] = dv.x + dv.y * SW


## Read rows lo..hi into the snapshot arrays, and (one pass for both) the
## loose pipes on screen into the pool.
func _snapshot(lo: int, hi: int) -> void:
	_tables()
	_s_lo = lo
	_s_hi = hi
	_s_rows = hi - lo + 3
	var n := _s_rows * SW
	_s_fit.resize(n * 16)
	_s_fit.fill(-1.0)
	_s_swap.resize(n)
	_s_swap.fill(0)
	_s_open.resize(n)
	_s_open.fill(0)
	_s_cls.resize(n)
	_s_cls.fill(0)
	_s_pc.resize(n)
	_s_ow.resize(n)
	_s_kind.resize(n * 4)
	_s_kind.fill(255)
	_s_esc.resize(n)
	_s_esc.fill(-1)
	_s_span.resize(_s_rows * Tuning.COLS)
	_s_span.fill(-1)
	var rows := _rows()
	var pool := {}
	var grid = game.grid
	var b: Rect2 = game.board_rect
	var T: float = game.T
	var cam_y: float = game.cam.y
	for r in range(mini(rows.x, lo - 1), hi + 2):
		# Visible: the cell's centre is on the board (see is_tile_visible).
		var cy := b.end.y - (r + 0.5 - cam_y) * T
		var vis: bool = r >= grid.floor_row and r <= grid.top_row and cy >= b.position.y and cy <= b.end.y
		var row: Array = grid.rows.get(r, [])
		if row.is_empty():
			continue
		var base := (r - lo + 1) * SW + 1
		for c in Tuning.COLS:
			var t: Tile = row[c]
			if t == null:
				continue
			var hidden := t.hidden
			var empty := t.kind == Tile.EMPTY
			var goo: bool = t.fill_entry[0] >= 0 or t.fill_entry[1] >= 0
			var pc := t.piece
			if vis and empty and pc >= 0 and not t.fixed and not hidden and not goo and r <= hi:
				if not pool.has(pc):
					pool[pc] = []
				pool[pc].append(Vector2i(c, r))
			if r < lo - 1:
				continue
			var cell := base + c
			var cls := 1 if hidden else (4 if not empty or goo else (3 if t.fixed else 2))
			_s_cls[cell] = cls
			if cls == 3:
				_s_pc[cell] = pc
				_s_ow[cell] = t.oneway_entry if t.special == Tile.SP_ONEWAY else -1
			if r < lo or r > hi:
				continue
			if hidden or (empty and not goo):
				_s_open[cell] = 1
			if hidden or not empty:
				continue
			if pc >= 0:
				var slow := t.special == Tile.SP_RESERVOIR or t.narrow
				for en in 4:
					var ex: int = EXIT[pc * 4 + en]
					if ex < 0 or ex == en:
						continue
					if (t.special != Tile.SP_ONEWAY or t.oneway_entry == en) and t.fill_entry[CHAN[pc * 4 + en]] < 0:
						_s_fit[cell * 16 + en * 4 + ex] = 0.1 if slow else 0.3
			if vis and not t.fixed and not goo:
				_s_swap[cell] = 1
	_pool_frame = Engine.get_process_frames()
	_pool_val = pool


## Dijkstra over (column, row, side the water comes in from, column where the
## route entered this row). The last part lets it snake: turning up costs
## `curvy` for every column it could still have travelled towards the far wall
## (without snaking it isn't needed, so the search is 7 times smaller). States
## are ints and live in packed arrays: this runs several times a second.
func _search(w: Dictionary, lo: int, hi: int, have: Dictionary, penalty: Dictionary, curvy: float) -> Dictionary:
	var WD := Tuning.COLS if curvy > 0.0 else 1
	var nstates := _s_rows * SW * 4 * WD
	var hv := PackedInt32Array()
	hv.resize(7)
	var pen := PackedFloat32Array()
	pen.resize(7)
	for k in 7:
		hv[k] = int(have.get(k, 0))
		pen[k] = float(penalty.get(k, 0.0))
	var dist := PackedFloat64Array()
	dist.resize(nstates)
	dist.fill(INF_COST)
	var prev_id := PackedInt32Array()
	prev_id.resize(nstates)
	var prev_ex := PackedByteArray()
	prev_ex.resize(nstates)
	var prev_need := PackedInt32Array()
	prev_need.resize(nstates)
	var done := PackedByteArray()
	done.resize(nstates)
	var reached := PackedInt32Array()
	var sc: int = w["c"]
	var sr: int = w["r"]
	if sr - lo + 1 < 0 or sr - lo + 1 >= _s_rows or sc < -1 or sc > Tuning.COLS:
		# The water's next cell is outside the rows we look at: nowhere to go.
		var k0 := _end_kind(Vector3i(sc, sr, int(w["e"])), hi)
		return {"cells": [], "end": Vector2i(sc, sr), "kind": k0, "needs": [], "missing": 0,
				"arrive_end": float(w["t0"]), "start_ok": k0 == "open"}
	var start := ((((sr - lo + 1) * SW + sc + 1) * 4 + int(w["e"])) * WD) + (clampi(sc, 0, Tuning.COLS - 1) if WD > 1 else 0)
	dist[start] = 0.0
	reached.append(start)
	# A binary heap, inlined (function calls are slow in GDScript), with a
	# logical size so it never shrinks or reallocates.
	var hk := PackedFloat64Array()
	var hvals := PackedInt32Array()
	hk.resize(512)
	hvals.resize(512)
	hk[0] = 0.0
	hvals[0] = start
	var hn := 1
	var ncols := Tuning.COLS
	var order := ORDER
	var doff := DOFF
	var opp := OPP
	var need_t := NEED
	var straight := STRAIGHT
	var fit := _s_fit
	var swp := _s_swap
	var spans := _s_span
	while hn > 0:
		var u: int = hvals[0]
		hn -= 1
		if hn > 0:
			var key: float = hk[hn]
			var val: int = hvals[hn]
			var i := 0
			while true:
				var l := i * 2 + 1
				if l >= hn:
					break
				var m := l
				if l + 1 < hn and hk[l + 1] < hk[l]:
					m = l + 1
				if hk[m] >= key:
					break
				hk[i] = hk[m]
				hvals[i] = hvals[m]
				i = m
			hk[i] = key
			hvals[i] = val
		if done[u] == 1:
			continue
		done[u] = 1
		var uw := u % WD
		var t1 := u / WD
		var ue := t1 % 4
		var cell := t1 / 4
		var ry := cell / SW
		var cx := cell % SW
		var du: float = dist[u]
		var fbase := cell * 16 + ue * 4
		for j in 4:
			var ex: int = order[j]
			if ex == ue:
				continue
			# The cost through this cell: a pipe that already fits is nearly
			# free, a swap costs 11 + a shortage penalty, going down 6 more.
			var cost: float = fit[fbase + ex]
			var need := -1
			if cost < 0.0:
				if swp[cell] == 0:
					continue
				need = need_t[ue * 4 + ex]
				var n: int = hv[need]
				if straight[need] == 1:
					n += hv[P.CROSS]
				if n <= 0:
					continue
				cost = 11.0 + pen[need]
			if ex == P.S:
				cost += 6.0
			var na := uw
			if WD > 1 and (ex == P.N or ex == P.S):
				var c := cx - 1
				if ex == P.N:
					# Only columns it could really have reached count: rocks,
					# walls and full pipes end the row's span.
					var sk := ry * ncols + uw
					var span: int = spans[sk]
					if span < 0:
						span = _span_fast(ry, uw)
						spans[sk] = span
					cost += curvy * float(maxi(0, span - absi(c - uw)))
				na = c
			var v := (((cell + doff[ex]) * 4 + opp[ex]) * WD) + na
			var nd: float = du + cost
			if nd < dist[v]:
				if dist[v] >= INF_COST:
					reached.append(v)
				dist[v] = nd
				prev_id[v] = u
				prev_ex[v] = ex
				prev_need[v] = need
				if hn == hk.size():
					hk.resize(hn * 2)
					hvals.resize(hn * 2)
				var i := hn
				hn += 1
				while i > 0:
					var pi := (i - 1) >> 1
					if hk[pi] <= nd:
						break
					hk[i] = hk[pi]
					hvals[i] = hvals[pi]
					i = pi
				hk[i] = nd
				hvals[i] = v
	# Where should the route stop? As high as possible, then cheapest - but
	# while snaking, every column travelled along the current row counts too
	# (enough that reaching the far wall beats turning up early), so it opens
	# the hatches along the row instead of rushing up.
	var along := 50.0 * curvy / Tuning.AI_CURVY
	var nr := reached.size()
	var vals := PackedFloat64Array()
	vals.resize(nr)
	var kinds := PackedByteArray()
	kinds.resize(nr)
	for k in nr:
		var id: int = reached[k]
		var t1 := id / WD
		var e := t1 % 4
		var cell := t1 / 4
		var r := cell / SW - 1 + lo
		var c := cell % SW - 1
		var kind: int = _s_kind[cell * 4 + e]
		if kind == 255:
			kind = _cell_kind(cell, c, r, e, hi)
		var val := 0.0
		var col_w := id % WD if WD > 1 else c
		match kind:
			0:
				val = (hi + 2) * 100.0
			1:
				# A closed hatch with few ways out (walls, rocks around it) is a
				# likely dead end: rate it lower.
				var esc: int = _s_esc[cell]
				if esc < 0:
					esc = _esc_fast(cell, c) if r >= lo else _escapes(Vector3i(c, r, e))
					_s_esc[cell] = esc
				val = r * 100.0 + 50.0 - (3 - esc) * 60.0 + along * absi(c - col_w)
			2:
				val = r * 100.0 + 20.0 + along * absi(c - col_w)
			_:
				val = r * 100.0 - DEAD_END
		vals[k] = val - dist[id]
		kinds[k] = kind
	# The best 40 or so, best first.
	var sorted := vals.duplicate()
	sorted.sort()
	var cut: float = sorted[maxi(0, nr - 40)] if nr > 0 else 0.0
	var cands: Array = []
	for k in nr:
		if vals[k] >= cut:
			cands.append([vals[k], reached[k], kinds[k]])
	cands.sort_custom(func(a, b): return a[0] > b[0])
	# Try them best first; skip any whose route would cross itself. A closed
	# hatch or open cell where the water couldn't climb two more rows - through
	# cells not known to be blocked and not on the route itself - is a sealed
	# pocket: it counts as a dead end. (That only ever lowers a value, so stop
	# once nothing further down the list can beat the best so far.)
	var cells: Array = []
	var best_end := Vector2i(sc, sr)
	var best_kind := 3
	var best_val := -INF
	var tried := 0
	for cand in cands:
		if float(cand[0]) <= best_val or tried >= 40:
			break
		tried += 1
		var path: Array = []
		var seen := {}
		var end_id: int = cand[1]
		var u := end_id
		var ok := true
		while u != start:
			var from: int = prev_id[u]
			var ft := from / WD
			var fcell := ft / 4
			var cv := Vector2i(fcell % SW - 1, fcell / SW - 1 + lo)
			if seen.has(cv):
				ok = false
				break
			seen[cv] = true
			path.push_front({"v": cv, "en": ft % 4, "ex": int(prev_ex[u]), "need": prev_need[u]})
			u = from
		if not ok:
			continue
		var val: float = cand[0]
		var kind: int = cand[2]
		var ecell := (end_id / WD) / 4
		var end := Vector2i(ecell % SW - 1, ecell / SW - 1 + lo)
		if (kind == 1 or kind == 2) and not _climbs(end, 2, int(w["row"]), seen):
			kind = 3
			val = end.y * 100.0 - DEAD_END - dist[end_id]
		if val > best_val:
			best_val = val
			cells = path
			best_end = end
			best_kind = kind
	# When does the water reach each cell?
	var sp := _speed()
	var t: float = w["t0"]
	var needs: Array = []
	for cell in cells:
		cell["arrive"] = t
		if cell["need"] >= 0:
			needs.append({"cell": cell["v"], "piece": cell["need"], "arrive": t})
			t += Tuning.BASE_SEGMENT_TIME / sp
		else:
			var tt: Tile = game.grid.get_tile(cell["v"].x, cell["v"].y)
			t += Tuning.BASE_SEGMENT_TIME * Flow.time_factor(tt) / sp
	return {"cells": cells, "end": best_end, "kind": KINDS[best_kind], "needs": needs,
			"missing": 0, "arrive_end": t, "start_ok": not cells.is_empty() or best_kind == 0}


## End kind of a state (see _end_kind), cached per cell and entry side,
## worked out from the snapshot (rows lo..hi; the rare cell below them asks
## the grid).
func _cell_kind(cell: int, c: int, r: int, e: int, hi: int) -> int:
	var k: int = _s_kind[cell * 4 + e]
	if k != 255:
		return k
	if c < 0 or c >= Tuning.COLS:
		k = 3
	elif r > hi:
		k = 0
	elif r < _s_lo:
		k = KINDS.find(_end_kind(Vector3i(c, r, e), hi))
	else:
		match _s_cls[cell]:
			1:
				k = 1
			2:
				k = 2 if _way_on(cell, c, e) else 3
			_:
				k = 3
	_s_kind[cell * 4 + e] = k
	return k


## _has_way_on from the snapshot.
func _way_on(cell: int, c: int, e: int) -> bool:
	for d in 4:
		if d == e:
			continue
		if (d == P.E and c + 1 >= Tuning.COLS) or (d == P.W and c - 1 < 0):
			continue
		var nc: int = cell + DOFF[d]
		var cls: int = _s_cls[nc]
		if cls == 1 or cls == 2:
			return true
		if cls == 3:
			var od: int = OPP[d]
			var ow: int = _s_ow[nc]
			if EXIT[_s_pc[nc] * 4 + od] >= 0 and (ow < 0 or ow == od):
				return true
	return false


## _escapes from the snapshot (rows lo..hi).
func _esc_fast(cell: int, c: int) -> int:
	var n := 0
	for d in [P.N, P.E, P.W]:
		if (d == P.E and c + 1 >= Tuning.COLS) or (d == P.W and c - 1 < 0):
			continue
		var cls: int = _s_cls[cell + DOFF[d]]
		if cls <= 2:
			n += 1
	return n


## _row_span from the snapshot (row index ry, rows lo..hi).
func _span_fast(ry: int, a: int) -> int:
	var best := 0
	var base := ry * SW + 1
	for step in [-1, 1]:
		var n := 0
		var c: int = a + step
		while c >= 0 and c < Tuning.COLS:
			var cls: int = _s_cls[base + c]
			if cls == 0 or cls == 4 or (cls == 3 and _s_pc[base + c] != P.H and _s_pc[base + c] != P.CROSS):
				break
			n += 1
			c += step
		best = maxi(best, n)
	return best


## How many ways on (N, E, W) cell u might have, judging by what's known.
func _escapes(u: Vector3i) -> int:
	var n := 0
	for d in [P.N, P.E, P.W]:
		var v: Vector2i = Vector2i(u.x, u.y) + P.DIR_VEC[d]
		if v.x < 0 or v.x >= Tuning.COLS:
			continue
		var t: Tile = game.grid.get_tile(v.x, v.y)
		if t == null or t.hidden or (t.kind == Tile.EMPTY and not t.fixed and not t.has_goo()):
			n += 1
	return n


## How far a route entering row r at column a could run along the row: the
## longer of the open stretches to its left and right (closed hatches count
## as open; rocks, walls, full pipes and fixed pipes that don't run sideways
## end a stretch).
func _row_span(r: int, a: int) -> int:
	var best := 0
	for step in [-1, 1]:
		var n := 0
		var c: int = a + step
		while c >= 0 and c < Tuning.COLS:
			var t: Tile = game.grid.get_tile(c, r)
			if t == null or (not t.hidden and (t.kind != Tile.EMPTY or t.has_goo()
					or (t.fixed and t.piece != P.H and t.piece != P.CROSS))):
				break
			n += 1
			c += step
		best = maxi(best, n)
	return best


## _can_climb on the snapshot (cells below the snapshot count as blocked).
func _climbs(v: Vector2i, rows_up: int, water_row: int, route: Dictionary) -> bool:
	var goal: int = mini(v.y + rows_up, _s_hi + 1)
	var lo_ok: int = maxi(water_row, _s_lo)
	var seen := PackedByteArray()
	seen.resize(_s_rows * SW)
	for cv in route:
		var rc: Vector2i = cv
		if rc.y >= _s_lo and rc.y <= _s_hi:
			seen[(rc.y - _s_lo + 1) * SW + rc.x + 1] = 1
	var start := (v.y - _s_lo + 1) * SW + v.x + 1
	if start < 0 or start >= seen.size():
		return _can_climb(v, rows_up, water_row, route)
	seen[start] = 1
	var todo := PackedInt32Array([start])
	while not todo.is_empty():
		var cell: int = todo[todo.size() - 1]
		todo.resize(todo.size() - 1)
		var r := cell / SW - 1 + _s_lo
		if r >= goal:
			return true
		var cx := cell % SW
		for d in 4:
			var ncx := cx + (1 if d == P.E else (-1 if d == P.W else 0))
			if ncx < 1 or ncx > Tuning.COLS:
				continue
			var nr := r + (1 if d == P.N else (-1 if d == P.S else 0))
			if nr < lo_ok:
				continue
			if nr > _s_hi:
				return true
			var ncell := (nr - _s_lo + 1) * SW + ncx
			if seen[ncell] == 1:
				continue
			seen[ncell] = 1
			if _s_open[ncell] == 1:
				todo.append(ncell)
	return false


## Is there any way up from cell v - at least `rows_up` rows, or off the top
## of the screen - through cells that aren't known to be blocked? Closed
## hatches count as open; cells in `route` (the way the water gets to v) are
## taken. A flood fill over the rows from the water upwards.
func _can_climb(v: Vector2i, rows_up: int, water_row: int, route: Dictionary = {}) -> bool:
	var top := _rows().y
	var goal: int = mini(v.y + rows_up, top + 1)
	var seen := route.duplicate()
	seen[v] = true
	var todo: Array = [v]
	while not todo.is_empty():
		var c: Vector2i = todo.pop_back()
		if c.y >= goal:
			return true
		for d in 4:
			var n: Vector2i = c + P.DIR_VEC[d]
			if n.x < 0 or n.x >= Tuning.COLS or n.y < water_row or seen.has(n):
				continue
			seen[n] = true
			if n.y > top:
				return true
			var t: Tile = game.grid.get_tile(n.x, n.y)
			if t == null:
				continue
			if t.hidden or (t.kind == Tile.EMPTY and not t.has_goo()):
				todo.append(n)
	return false


## Could the water go anywhere from state u (cell + side it comes in from),
## judging by what's known? (Closed hatches might be open.)
func _has_way_on(u: Vector3i) -> bool:
	for d in [P.N, P.E, P.W, P.S]:
		if d == u.z:
			continue
		var v: Vector2i = Vector2i(u.x, u.y) + P.DIR_VEC[d]
		if v.x < 0 or v.x >= Tuning.COLS:
			continue
		var t: Tile = game.grid.get_tile(v.x, v.y)
		if t == null:
			continue
		if t.hidden or (t.kind == Tile.EMPTY and not t.has_goo() and not t.fixed):
			return true
		if t.kind == Tile.EMPTY and t.fixed and not t.has_goo() and P.exit_dir(t.piece, P.opposite(d)) >= 0 \
				and (t.special != Tile.SP_ONEWAY or t.oneway_entry == P.opposite(d)):
			return true
	return false


## What stops a route at state u (the cell the water would enter next).
func _end_kind(u: Vector3i, hi: int) -> String:
	if u.x < 0 or u.x >= Tuning.COLS:
		return "dead"
	if u.y > hi:
		return "open"
	var t: Tile = game.grid.get_tile(u.x, u.y)
	if t == null:
		return "dead"
	if t.hidden:
		return "hidden"
	if t.kind != Tile.EMPTY:
		return "dead"
	if t.piece >= 0 and (t.fixed or t.has_goo()):
		return "dead"
	# An open cell it can't fill yet - unless it's boxed in (rocks, walls,
	# full pipes all round), which makes it a dead end, not a wait.
	return "stuck" if _has_way_on(u) else "dead"


# --- deciding -------------------------------------------------------------------------------

## The next action (or a pick-and-drop pair), or [] to wait. The strategy, in
## order: use a pipe still in hand; freeze when the water will beat us to
## unfinished pipe; Reveal when there are too many hatches to open in time;
## fix the most urgent cell; open the hatch where the route stops; fix the
## rest; then, with the route built off the top of the screen, hold to speed up.
func _decide() -> Array:
	var g = game
	var w := _water()
	var plan := _plan(w)
	last_plan = plan
	last_plan["water"] = w
	var needs: Array = plan.get("needs", [])
	var kind: String = plan.get("kind", "dead")
	var end: Vector2i = plan.get("end", Vector2i(w["c"], w["r"]))
	var arrive_end: float = plan.get("arrive_end", w["t0"])
	var missing: int = plan.get("missing", 0)
	var running: bool = g.state == g.State.RUNNING
	# 1) A pipe in hand (the second tap of a swap got interrupted).
	if g.held_piece >= 0:
		for n in needs:
			if _fits(g.held_piece, n["piece"]):
				return [_tile(n["cell"], "drop")]
		if g.held_from.x >= 0:
			return [_tile(g.held_from, "deselect")]
	# 2) Danger: will the water reach a cell before we can finish it, even
	#    hurrying? (Freezes are rare - one every 100 rows - so only then.)
	var danger := false
	var cum := 0.0
	for n in needs:
		cum += SWAP_TIME_HURRY
		if n["arrive"] < cum + 0.2:
			danger = true
			break
	if kind != "open" and arrive_end < (TAP_TIME + SWAP_TIME_HURRY if kind == "hidden" else 1.0):
		danger = true
	if plan.is_empty() and w["t0"] < 1.5:
		danger = true
	_danger = danger
	var hidden_near := _hidden(end, int(w["row"]), int(w["row"]) + 4)
	# Hurry (like a person under pressure) when the work ahead barely fits the time left.
	var work_time := needs.size() * SWAP_TIME + (TAP_TIME if kind == "hidden" else 0.0)
	_hurry = danger or (kind != "open" and arrive_end < work_time + 3.0)
	if danger and running and g.freezes > 0 and g.freeze_timer <= 0.0:
		return [{"kind": "freeze"}]
	# 3) Reveal: lots of closed hatches and not enough time to open them by hand.
	# (One comes every 100 rows, so use it when it saves the most taps.)
	if running and g.reveals > 0 and hidden_near.size() >= 8 and (kind == "hidden" or kind == "stuck" or missing > 0):
		if (arrive_end < 8.0 and arrive_end < hidden_near.size() * TAP_TIME + 2.0) or (_speed() > 2.0 and hidden_near.size() >= 12):
			return [{"kind": "reveal"}]
	# 4) Look before you leap: open the hatch where the route stops before
	#    building towards it - it may hide a rock. Earliest deadline first: that
	#    hatch must be seen while there is still time to re-route (open it, then
	#    rebuild up to two pipes); the first fix must be done before the water
	#    gets there. Whichever deadline comes sooner goes first.
	var slack0: float = 99.0 if needs.is_empty() else float(needs[0]["arrive"]) - SWAP_TIME_HURRY
	if kind == "hidden" and g.is_tile_visible(end.x, end.y):
		var look_by := arrive_end - (TAP_TIME + 2.0 * SWAP_TIME_HURRY)
		if look_by <= slack0 or slack0 > TAP_TIME + 1.0:
			return [_tile(end, "flip")]
	# 5) The most urgent fix first.
	if not needs.is_empty() and (needs[0]["arrive"] < 6.0 or kind == "open"):
		var sw := _swap(needs[0], plan)
		if not sw.is_empty():
			return sw
		if needs[0]["arrive"] < 6.0:
			# No pipe for it anywhere on screen: Reveal if we can, else open the
			# hatches closest to that cell to find one.
			if g.reveals > 0 and not hidden_near.is_empty():
				return [{"kind": "reveal"}]
			var close := _hidden(needs[0]["cell"], int(w["row"]))
			if not close.is_empty():
				return [_tile(close[0], "flip")]
	# 6) See further: open the hatch where the route stops.
	if kind == "hidden" and g.is_tile_visible(end.x, end.y):
		return [_tile(end, "flip")]
	# 7) Missing pipes or no way on: open more hatches nearby to find some.
	if kind == "stuck" or kind == "dead" or missing > 0:
		var more := _hidden(end, int(w["row"]))
		if not more.is_empty():
			return [_tile(more[0], "flip")]
	# 8) The rest of the route, nearest the water first.
	for n in needs:
		var sw := _swap(n, plan)
		if not sw.is_empty():
			return sw
	# 9) Spare time with the route built: swap narrow pipes into it (each one
	#    makes the water take 2.5x as long there - time to build further).
	if needs.is_empty():
		var up := _upgrade(plan)
		if not up.is_empty():
			return up
	# 10) Spare time: open hatches ahead so the next plan has more to work with.
	var ahead := _hidden(end, int(w["row"]))
	if not ahead.is_empty() and arrive_end > 3.0:
		return [_tile(ahead[0], "flip")]
	# 11) Nothing to fix and nothing to open, with the water well behind the
	#     route: hold the screen to hurry it along (and score double).
	if needs.is_empty() and arrive_end > _hold_margin() + 2.0:
		return [{"kind": "hold"}]
	return []


## Seconds of built route (at normal speed) to keep ahead of the water while
## holding: more when the water is fast.
func _hold_margin() -> float:
	return maxf(8.0, 3.0 * _speed())


## Pick-and-drop for one needed cell: fetch the best matching loose pipe.
## When the water is close, prefer a narrow pipe there (it slows the water).
## Never take a pipe the route keeps, or one the water is in.
func _swap(n: Dictionary, plan: Dictionary) -> Array:
	var keep := {}
	for cell in plan.get("cells", []):
		if cell["need"] < 0:
			keep[cell["v"]] = true
	var pool := _pool()
	var cell_v: Vector2i = n["cell"]
	var cands: Array = []
	for p in ([n["piece"], P.CROSS] if P.is_straight(n["piece"]) else [n["piece"]]):
		for v in pool.get(p, []):
			if v != cell_v and not keep.has(v):
				cands.append(v)
		if not cands.is_empty():
			break
	if cands.is_empty() and n["arrive"] < 4.0:
		# Emergency: borrow a matching pipe from further along our own route
		# (the water gets there much later) and rebuild that spot afterwards.
		for cell in plan.get("cells", []):
			if cell["need"] >= 0 or cell["arrive"] < n["arrive"] + 4.0:
				continue
			var t: Tile = game.grid.get_tile(cell["v"].x, cell["v"].y)
			if t != null and t.is_loose() and game.is_tile_visible(cell["v"].x, cell["v"].y) and _fits(t.get_item(), n["piece"]):
				cands.append(cell["v"])
	if cands.is_empty():
		return []
	var urgent: bool = n["arrive"] < 8.0 or _speed() > 1.6
	var water_row: int = game.flow.row if game.flow.active else 0
	# Two for one: a source that is itself a route cell wanting the pipe that
	# the target holds now gets fixed by the same swap.
	var tt: Tile = game.grid.get_tile(cell_v.x, cell_v.y)
	var give: int = tt.get_item() if tt != null else -1
	var wants := {}
	for c in plan.get("cells", []):
		if c["need"] >= 0 and c["v"] != cell_v:
			wants[c["v"]] = c["need"]
	cands.sort_custom(func(a, b): return _source_key(a, cell_v, urgent, water_row, give, wants) < _source_key(b, cell_v, urgent, water_row, give, wants))
	return [_tile(cands[0], "pick"), _tile(cell_v, "drop")]


## Replace a normal pipe on the route with a narrow one of the same shape,
## when that gains more time than the swap costs.
func _upgrade(plan: Dictionary) -> Array:
	var sp := _speed()
	var gain := Tuning.BASE_SEGMENT_TIME * (Tuning.NARROW_FILL_FACTOR - 1.0) / sp
	if gain < SWAP_TIME * 1.3:
		return []
	var keep := {}
	for cell in plan.get("cells", []):
		if cell["need"] < 0:
			keep[cell["v"]] = true
	var pool := _pool()
	for cell in plan.get("cells", []):
		if cell["need"] >= 0 or cell["arrive"] < 3.0:
			continue
		var v: Vector2i = cell["v"]
		var t: Tile = game.grid.get_tile(v.x, v.y)
		if t == null or not t.is_loose() or t.narrow or t.piece == P.CROSS or not game.is_tile_visible(v.x, v.y):
			continue
		for src in pool.get(t.piece, []):
			var s: Tile = game.grid.get_tile(src.x, src.y)
			if src != v and not keep.has(src) and s.narrow:
				return [_tile(src, "pick"), _tile(v, "drop")]
	return []


func _source_key(v: Vector2i, target: Vector2i, urgent: bool, water_row: int, give: int, wants: Dictionary) -> float:
	var t: Tile = game.grid.get_tile(v.x, v.y)
	var k := float(absi(v.x - target.x) + absi(v.y - target.y))
	if v.y < water_row:
		k -= 3.0  # Rows the water has left behind are free to plunder.
	if t != null and t.narrow:
		k -= 6.0 if urgent else 3.0  # A narrow pipe on the route buys time.
	if give >= 0 and wants.has(v) and _fits(give, wants[v]):
		k -= 10.0  # Two cells fixed with one swap.
	return k


func _fits(item: int, piece: int) -> bool:
	var p := P.item_piece(item)
	return p == piece or (p == P.CROSS and P.is_straight(piece))


func _tile(v: Vector2i, why: String) -> Dictionary:
	var T: float = game.T
	return {"kind": "tile", "c": v.x, "r": v.y, "why": why,
			"jitter": Vector2(randf_range(-0.14, 0.14), randf_range(-0.14, 0.14)) * T}
