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
var trace_on := false
var _layer: CanvasLayer
var _view: Control


## A binary min-heap of (cost, state) for the route search.
class MinHeap:
	var k: Array = []
	var v: Array = []

	func is_empty() -> bool:
		return k.is_empty()

	func push(key: float, val) -> void:
		k.append(key)
		v.append(val)
		var i := k.size() - 1
		while i > 0:
			var p := (i - 1) >> 1
			if k[p] <= k[i]:
				break
			_swap(i, p)
			i = p

	func pop():
		var top = v[0]
		var last := k.size() - 1
		k[0] = k[last]
		v[0] = v[last]
		k.pop_back()
		v.pop_back()
		var i := 0
		var n := k.size()
		while true:
			var l := i * 2 + 1
			var m := i
			if l < n and k[l] < k[m]:
				m = l
			if l + 1 < n and k[l + 1] < k[m]:
				m = l + 1
			if m == i:
				break
			_swap(i, m)
			i = m
		return top

	func _swap(a: int, b: int) -> void:
		var tk = k[a]
		k[a] = k[b]
		k[b] = tk
		var tv = v[a]
		v[a] = v[b]
		v[b] = tv


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
	return best


## Dijkstra over (column, row, side the water comes in from, column where the
## route entered this row). The last part lets it snake: turning up costs
## `curvy` for every column it could still have travelled towards the far wall.
func _search(w: Dictionary, lo: int, hi: int, have: Dictionary, penalty: Dictionary, curvy: float) -> Dictionary:
	var start := Vector4i(w["c"], w["r"], w["e"], w["c"])
	var spans := {}
	var dist := {start: 0.0}
	var prev := {}
	var heap := MinHeap.new()
	heap.push(0.0, start)
	var done := {}
	while not heap.is_empty():
		var u: Vector4i = heap.pop()
		if done.has(u):
			continue
		done[u] = true
		for ex in [P.N, P.E, P.W, P.S]:
			if ex == u.z:
				continue
			var st := _step(u.x, u.y, u.z, ex, lo, hi, have, penalty)
			if st[0] >= INF_COST:
				continue
			var cost: float = st[0]
			var na := u.w
			if ex == P.N or ex == P.S:
				if ex == P.N and curvy > 0.0:
					# Only columns it could really have reached count: rocks,
					# walls and full pipes end the row's span.
					var key := Vector2i(u.y, u.w)
					if not spans.has(key):
						spans[key] = _row_span(u.y, u.w)
					cost += curvy * float(maxi(0, int(spans[key]) - absi(u.x - u.w)))
				na = u.x
			var dv: Vector2i = P.DIR_VEC[ex]
			var v := Vector4i(u.x + dv.x, u.y + dv.y, P.opposite(ex), na)
			var nd: float = dist[u] + cost
			if nd < float(dist.get(v, INF_COST)):
				dist[v] = nd
				prev[v] = [u, ex, st[1]]
				heap.push(nd, v)
	# Where should the route stop? As high as possible, then cheapest - but
	# while snaking, every column travelled along the current row counts too
	# (enough that reaching the far wall beats turning up early), so it opens
	# the hatches along the row instead of rushing up. Try the candidates best
	# first; skip any whose route would cross itself.
	var along := 50.0 * curvy / Tuning.AI_CURVY
	var cands: Array = []
	for u in dist:
		var u3 := Vector3i(u.x, u.y, u.z)
		var kind := _end_kind(u3, hi)
		var height: float = u.y
		var val := 0.0
		match kind:
			"open":
				val = (hi + 2) * 100.0
			"hidden":
				# A closed hatch with few ways out (walls, rocks around it) is a
				# likely dead end: rate it lower.
				val = height * 100.0 + 50.0 - (3 - _escapes(u3)) * 60.0 + along * absi(u.x - u.w)
			"stuck":
				val = height * 100.0 + 20.0 + along * absi(u.x - u.w)
			_:
				val = height * 100.0 - DEAD_END
		cands.append([val - float(dist[u]), u, kind])
	cands.sort_custom(func(a, b): return a[0] > b[0])
	# Try them best first; skip any whose route would cross itself. A closed
	# hatch or open cell where the water couldn't climb two more rows - through
	# cells not known to be blocked and not on the route itself - is a sealed
	# pocket: it counts as a dead end. (That only ever lowers a value, so stop
	# once nothing further down the list can beat the best so far.)
	var cells: Array = []
	var best_u := start
	var best_kind := "dead"
	var best_val := -INF
	var tried := 0
	for cand in cands:
		if float(cand[0]) <= best_val or tried >= 40:
			break
		tried += 1
		var path: Array = []
		var seen := {}
		var end: Vector4i = cand[1]
		var u: Vector4i = end
		var ok := true
		while u != start:
			var pr: Array = prev[u]
			var from: Vector4i = pr[0]
			var cv := Vector2i(from.x, from.y)
			if seen.has(cv):
				ok = false
				break
			seen[cv] = true
			path.push_front({"v": cv, "en": from.z, "ex": pr[1], "need": pr[2]})
			u = from
		if not ok:
			continue
		var val: float = cand[0]
		var kind: String = cand[2]
		if (kind == "hidden" or kind == "stuck") and not _can_climb(Vector2i(end.x, end.y), 2, int(w["row"]), seen):
			kind = "dead"
			val = end.y * 100.0 - DEAD_END - float(dist[end])
		if val > best_val:
			best_val = val
			cells = path
			best_u = end
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
	return {"cells": cells, "end": Vector2i(best_u.x, best_u.y), "kind": best_kind, "needs": needs,
			"missing": 0, "arrive_end": t, "start_ok": not cells.is_empty() or best_kind == "open"}


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
