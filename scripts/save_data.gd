## High score storage: localStorage in the browser, a config file elsewhere.
## One best score. It keeps the key the Medium difficulty used (difficulties
## are gone and the game runs at that speed), so that record carries over;
## scores from the old bonus-based scoring ("upstream_best") don't.
## Every access is guarded, so a blocked or broken store never crashes the game.
class_name SaveData
extends RefCounted

const KEY := "upstream_score_medium"   ## localStorage key.
const CFG_KEY := "score_medium"        ## Config-file key (section "scores").
const PATH := "user://upstream.cfg"


static func load_best() -> int:
	var k := [KEY, CFG_KEY]
	var best := 0
	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval(
				"(function(){try{return String(window.localStorage.getItem('%s')||'0');}catch(e){return '0';}})()" % k[0], true)
		if v != null:
			best = maxi(best, int(str(v)))
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		var v = cfg.get_value("scores", k[1], 0)
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			best = maxi(best, int(v))
	return best


static func save_best(score: int) -> void:
	var k := [KEY, CFG_KEY]
	if OS.has_feature("web"):
		JavaScriptBridge.eval(
				"(function(){try{window.localStorage.setItem('%s','%d');}catch(e){}})()" % [k[0], score], true)
	var cfg := ConfigFile.new()
	cfg.load(PATH)  # Missing file is fine.
	cfg.set_value("scores", k[1], score)
	var err := cfg.save(PATH)
	if err != OK and not OS.has_feature("web"):
		push_warning("Could not save high score (error %d)" % err)


## One-time flags, such as "tutorial_done".
static func load_flag(name: String) -> bool:
	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval(
				"(function(){try{return String(window.localStorage.getItem('upstream_%s')||'');}catch(e){return '';}})()" % name, true)
		if v != null and str(v) == "1":
			return true
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		return bool(cfg.get_value("flags", name, false))
	return false


static func save_flag(name: String, on := true) -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval(
				"(function(){try{window.localStorage.setItem('upstream_%s','%s');}catch(e){}})()" % [name, "1" if on else ""], true)
	var cfg := ConfigFile.new()
	cfg.load(PATH)  # Missing file is fine.
	cfg.set_value("flags", name, on)
	cfg.save(PATH)
