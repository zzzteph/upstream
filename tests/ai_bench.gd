## AI benchmark: how far does the AI SOLVE bot get? Plays 5 seeded games per
## difficulty (up to row 250 or 15 minutes of game time each) and prints the
## height, score, taps per second, longest pause and why it lost, plus the
## AI's last plan when the water spills (and its recent decisions for early
## losses). Not part of CI - it takes a few minutes:
##   godot --headless --fixed-fps 60 --script res://tests/ai_bench.gd [-- medium hard]
extends SceneTree

const P := preload("res://scripts/pieces.gd")

var game


func _initialize() -> void:
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	_run.call_deferred()


func _run() -> void:
	for i in 3:
		await process_frame
	game.tutorial_pending = false
	var S = game.State
	var args := OS.get_cmdline_user_args()
	var diffs: Array = ["easy", "medium", "hard"] if args.is_empty() else Array(args)
	for diff in diffs:
		for trial in 5:
			seed(1000 + trial)
			game.rng.seed = 77 + trial
			game.start_run(diff)
			await process_frame
			game.toggle_ai()
			game.ai.trace_on = true
			game.ai.trace = []
			var frames := 0
			var idle := 0
			var max_idle := 0
			var last_actions := 0
			var dumped := false
			while game.state != S.GAMEOVER and frames < 60 * 900 and game.height < 250:
				await process_frame
				if game.state == S.SPILL and not dumped:
					dumped = true
					var lp: Dictionary = game.ai.last_plan
					var cells := []
					for c in lp.get("cells", []):
						cells.append("%s%s%s" % [c["v"], "*" if c["need"] >= 0 else "", "@%.1f" % c["arrive"]])
					var sv: Vector2i = Vector2i(game.spill["p"].x, game.spill["p"].y) if not game.spill.is_empty() else Vector2i(-1, -1)
					print("   DEATH %s at flow (%d,%d) exit %d | plan kind %s end %s missing %s needs %d | cells %s | queue %s | hurry %s speed %.2f" % [
						game.last_reason, game.flow.col, game.flow.row, game.flow.exit, lp.get("kind", "?"), lp.get("end", "?"), lp.get("missing", "?"),
						(lp.get("needs", []) as Array).size(), " ".join(cells.slice(0, 8)), str(game.ai._queue.map(func(a): return [a["kind"], a.get("why", ""), a.get("c", -1), a.get("r", -1)])),
						game.ai._hurry, game.ai._speed()])
					if game.height < 60:
						for line in game.ai.trace:
							print("      ", line)
						var rows := ""
						for r in range(game.flow.row + 2, game.flow.row - 3, -1):
							var line := "      r%d " % r
							for c in Tuning.COLS:
								var t: Tile = game.grid.get_tile(c, r)
								line += ("##" if t.hidden else ("RK" if t.kind == Tile.ROCK else (P.NAMES[t.piece] + ("~" if t.has_goo() else " ") if t.piece >= 0 else ". "))) + " "
							rows += line + "\n"
						print(rows)
				frames += 1
				if game.ai.actions == last_actions and not game.ai_hold:
					idle += 1
					max_idle = maxi(max_idle, idle)
				else:
					idle = 0
				last_actions = game.ai.actions
			var secs := frames / 60.0
			print("%s #%d: height %d score %d in %.0fs, taps %d (%.2f/s), longest idle %.1fs, freezes left %d reveals left %d, end: %s" % [
					diff, trial, game.height, game.score, secs, game.ai.actions, game.ai.actions / maxf(1.0, secs), max_idle / 60.0,
					game.freezes, game.reveals, game.last_reason if game.state == S.GAMEOVER else "still going"])
			print("   taps: ", game.ai.tally)
			game.go_to_title()
			await process_frame
	quit(0)
