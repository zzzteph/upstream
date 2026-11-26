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
var tally := {}                  ## Taps by kind (debugging / tests).
var trace: Array = []            ## Recent decisions, when debugging (set trace_on).
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
		_hold_check = 0.2
		var plan := _plan(_water())
		var at_hold: float = float(plan.get("arrive_end", 0.0)) / Tuning.HOLD_SPEED_MULT
		if plan.get("kind", "") == "open" and (plan.get("needs", []) as Array).is_empty() and at_hold >= 2.0:
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
			if trace.size() > 14:
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
	_move_len = _from.distance_to(target) / (Tuning.AI_MOVE_SPEED * (1.7 if _hurry else 1.0)) + (0.06 if _hurry else 0.1)
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


## Water speed in tiles per second-unit, without the AI's own hold.
func _speed() -> float:
	var s: float = game.height_speed() * float(Tuning.DIFFICULTY_SPEED.get(game.difficulty, 1.0))
	if game.surge_timer > 0.0:
		s *= Tuning.ALARM_SURGE_MULT
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
	var down := 3.0 if ex == P.S else 0.0
	if t.piece >= 0 and P.exit_dir(t.piece, en) == ex and (t.special != Tile.SP_ONEWAY or t.oneway_entry == en) \
			and t.fill_entry[P.channel_for(t.piece, en)] < 0:
		var slow := t.special == Tile.SP_RESERVOIR or t.narrow
		return [(0.4 if slow else 1.0) + down, -1]
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
	for attempt in 4:
		best = _search(w, lo, hi, have, penalty)
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


func _search(w: Dictionary, lo: int, hi: int, have: Dictionary, penalty: Dictionary) -> Dictionary:
	var start := Vector3i(w["c"], w["r"], w["e"])
	var dist := {start: 0.0}
	var prev := {}
	var open: Array = [start]
	var done := {}
	while not open.is_empty():
		var bi := 0
		for i in range(1, open.size()):
			if dist[open[i]] < dist[open[bi]]:
				bi = i
		var u: Vector3i = open[bi]
		open.remove_at(bi)
		if done.has(u):
			continue
		done[u] = true
		for ex in [P.N, P.E, P.W, P.S]:
			if ex == u.z:
				continue
			var st := _step(u.x, u.y, u.z, ex, lo, hi, have, penalty)
			if st[0] >= INF_COST:
				continue
			var dv: Vector2i = P.DIR_VEC[ex]
			var v := Vector3i(u.x + dv.x, u.y + dv.y, P.opposite(ex))
			var nd: float = dist[u] + st[0]
			if nd < float(dist.get(v, INF_COST)):
				dist[v] = nd
				prev[v] = [u, ex, st[1]]
				open.append(v)
	# Pick where the route should stop: as high as possible, then cheapest.
	var best_u := Vector3i(-99, -99, -1)
	var best_val := -INF
	var best_kind := ""
	for u in dist:
		var kind := _end_kind(u, hi)
		var height: float = u.y
		var val := 0.0
		match kind:
			"open":
				val = (hi + 2) * 100.0
			"hidden":
				# A closed hatch with few ways out (walls, rocks around it) is a
				# likely dead end: rate it lower.
				val = height * 100.0 + 50.0 - (3 - _escapes(u)) * 60.0
			"stuck":
				val = height * 100.0 + 20.0
			_:
				val = height * 100.0 - 1000.0
		val -= dist[u]
		if val > best_val:
			best_val = val
			best_u = u
			best_kind = kind
	# Walk back to the start.
	var cells: Array = []
	var seen := {}
	var u := best_u
	while u != start:
		var pr: Array = prev[u]
		var from: Vector3i = pr[0]
		var cv := Vector2i(from.x, from.y)
		if seen.has(cv):
			return {}  # A loop through the same cell; shouldn't happen with these costs.
		seen[cv] = true
		cells.push_front({"v": cv, "en": from.z, "ex": pr[1], "need": pr[2]})
		u = from
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
	return "stuck"


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
	#    building towards it (it may hide a rock), unless a fix can't wait.
	var slack0: float = 99.0 if needs.is_empty() else float(needs[0]["arrive"]) - SWAP_TIME_HURRY
	if kind == "hidden" and g.is_tile_visible(end.x, end.y) and (slack0 > TAP_TIME + 1.0 or (arrive_end < 6.0 and slack0 > TAP_TIME * 0.6)):
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
	# 9) All built to the top of the screen: hold to hurry the water along.
	if kind == "open" and needs.is_empty() and arrive_end > 4.0:
		return [{"kind": "hold"}]
	# 10) Spare time: open hatches ahead so the next plan has more to work with.
	var ahead := _hidden(end, int(w["row"]))
	if not ahead.is_empty() and arrive_end > 3.0:
		return [_tile(ahead[0], "flip")]
	return []


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
	cands.sort_custom(func(a, b): return _source_key(a, cell_v, urgent, water_row) < _source_key(b, cell_v, urgent, water_row))
	return [_tile(cands[0], "pick"), _tile(cell_v, "drop")]


func _source_key(v: Vector2i, target: Vector2i, urgent: bool, water_row: int) -> float:
	var t: Tile = game.grid.get_tile(v.x, v.y)
	var k := float(absi(v.x - target.x) + absi(v.y - target.y))
	if v.y < water_row:
		k -= 3.0  # Rows the water has left behind are free to plunder.
	if urgent and t != null and t.narrow:
		k -= 6.0  # A narrow pipe right in front of the water buys time.
	elif not urgent and t != null and t.narrow:
		k += 2.0
	return k


func _fits(item: int, piece: int) -> bool:
	var p := P.item_piece(item)
	return p == piece or (p == P.CROSS and P.is_straight(piece))


func _tile(v: Vector2i, why: String) -> Dictionary:
	var T: float = game.T
	return {"kind": "tile", "c": v.x, "r": v.y, "why": why,
			"jitter": Vector2(randf_range(-0.14, 0.14), randf_range(-0.14, 0.14)) * T}
