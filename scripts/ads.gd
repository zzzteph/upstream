## ============================================================================
##  ADS - AdMob on Android: a rewarded ad for a second chance after a leak,
##  and now and then a full-screen ad between runs. Nowhere else.
## ============================================================================
## On Android it drives the AdMob plugin (godot-sdk-integrations/godot-admob,
## added to the project by the Android build, see .github/workflows/android.yml)
## through its `Admob` node, created here in code so that nothing else in the
## game depends on the plugin: the web build and the tests have no plugin, and
## then there are simply no ads (and no second chance).
##
## Google's consent form (EU/UK and other regions that need it) is shown on
## start through the plugin; ads load once consent is sorted.
##
## Test ads unless res://ad_units.cfg says otherwise (the Android build writes
## it from the repository's ADMOB_* variables). ?fakeads (web) or --fakeads
## pretends to show ads, for trying the flow out and for tests.
class_name Ads
extends Node

const ADMOB_SCRIPT := "res://addons/AdmobPlugin/Admob.gd"
const UNITS_FILE := "res://ad_units.cfg"
const INTERSTITIAL_EVERY := 3     ## Game overs between full-screen ads...
const INTERSTITIAL_GAP := 180.0   ## ...and at least this many seconds since the last ad of any kind.
const RETRY_AFTER := 30.0         ## Seconds before trying again when an ad fails to load.

var fake := false                 ## Pretend: no plugin, a short "TEST AD" screen instead.
var fake_seconds := 1.5           ## How long a pretend ad lasts.
var shown_rewarded := 0           ## Counters (tests, debugging).
var shown_interstitial := 0

var _admob: Node = null
var _rewarded_ready := false
var _interstitial_ready := false
var _rewarded_done := Callable()
var _earned := false
var _interstitial_done := Callable()
var _runs_since := 0
var _last_ad := -1.0e9            ## Seconds (engine clock) when the last ad was shown.
var _retry_rewarded := -1.0
var _retry_interstitial := -1.0
var _fake_layer: CanvasLayer


## Start ads if this build has them. `fake_mode`: pretend (see above).
func setup(fake_mode: bool) -> void:
	fake = fake_mode
	if fake:
		_rewarded_ready = true
		_interstitial_ready = true
		return
	if OS.get_name() != "Android" or not ResourceLoader.exists(ADMOB_SCRIPT):
		return
	var script = load(ADMOB_SCRIPT)
	if script == null:
		return
	_admob = script.new()
	var units := ConfigFile.new()
	if units.load(UNITS_FILE) == OK and bool(units.get_value("ads", "is_real", false)):
		_admob.set("is_real", true)
		_admob.set("android_real_rewarded_id", str(units.get_value("ads", "rewarded", "")))
		_admob.set("android_real_interstitial_id", str(units.get_value("ads", "interstitial", "")))
	add_child(_admob)
	_admob.connect("initialization_completed", func(_status): _check_consent())
	_admob.connect("consent_info_updated", func(): _check_consent())
	_admob.connect("consent_info_update_failed", func(_err): _load_all())
	_admob.connect("consent_form_loaded", func(): _admob.call("show_consent_form"))
	_admob.connect("consent_form_dismissed", func(_err): _check_consent())
	_admob.connect("consent_form_failed_to_load", func(_err): _load_all())
	_admob.connect("rewarded_ad_loaded", func(_info, _resp): _rewarded_ready = true)
	_admob.connect("rewarded_ad_failed_to_load", func(_info, _err): _retry_rewarded = RETRY_AFTER)
	_admob.connect("rewarded_ad_user_earned_reward", func(_info, _reward): _earned = true)
	_admob.connect("rewarded_ad_dismissed_full_screen_content", func(_info): _finish_rewarded())
	_admob.connect("rewarded_ad_failed_to_show_full_screen_content", func(_info, _err): _finish_rewarded())
	_admob.connect("interstitial_ad_loaded", func(_info, _resp): _interstitial_ready = true)
	_admob.connect("interstitial_ad_failed_to_load", func(_info, _err): _retry_interstitial = RETRY_AFTER)
	_admob.connect("interstitial_ad_dismissed_full_screen_content", func(_info): _finish_interstitial())
	_admob.connect("interstitial_ad_failed_to_show_full_screen_content", func(_info, _err): _finish_interstitial())
	_admob.call("initialize")


## Are there ads in this build at all?
func available() -> bool:
	return fake or _admob != null


## Is a rewarded ad loaded and ready to show?
func rewarded_ready() -> bool:
	return available() and _rewarded_ready


## Show the rewarded ad; `done.call(earned: bool)` when it closes.
func show_rewarded(done: Callable) -> void:
	_rewarded_done = done
	_earned = false
	_rewarded_ready = false
	_last_ad = _now()
	shown_rewarded += 1
	if fake:
		_fake_show("REWARDED TEST AD", func():
			_earned = true
			_finish_rewarded())
		return
	_admob.call("show_rewarded_ad")


## A run ended (counts towards the next full-screen ad).
func run_ended() -> void:
	_runs_since += 1


## Between runs: show a full-screen ad if one is due (every few game overs,
## never twice within a few minutes), then `then.call()`. If none is due, or
## there are no ads, `then` runs straight away.
func between_runs(then: Callable) -> void:
	var due := _runs_since >= INTERSTITIAL_EVERY and _now() - _last_ad >= INTERSTITIAL_GAP
	if not (available() and _interstitial_ready and due):
		then.call()
		return
	_runs_since = 0
	_last_ad = _now()
	_interstitial_done = then
	_interstitial_ready = false
	shown_interstitial += 1
	if fake:
		_fake_show("TEST AD", _finish_interstitial)
		return
	_admob.call("show_interstitial_ad")


func _process(dt: float) -> void:
	if _admob == null:
		return
	if _retry_rewarded > 0.0:
		_retry_rewarded -= dt
		if _retry_rewarded <= 0.0:
			_admob.call("load_rewarded_ad")
	if _retry_interstitial > 0.0:
		_retry_interstitial -= dt
		if _retry_interstitial <= 0.0:
			_admob.call("load_interstitial_ad")


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## Consent first (the plugin shows Google's form where the law needs it),
## then load the ads.
func _check_consent() -> void:
	var consent = _admob.call("get_consent_status")
	var status: String = consent.call("to_status_string") if consent != null else "UNKNOWN"
	match status:
		"UNKNOWN":
			_admob.call("update_consent_info")
		"REQUIRED":
			_admob.call("load_consent_form")
		_:
			_load_all()


func _load_all() -> void:
	if not _rewarded_ready:
		_admob.call("load_rewarded_ad")
	if not _interstitial_ready:
		_admob.call("load_interstitial_ad")


func _finish_rewarded() -> void:
	var cb := _rewarded_done
	_rewarded_done = Callable()
	if _admob != null:
		_admob.call("load_rewarded_ad")
	elif fake:
		_rewarded_ready = true
	if cb.is_valid():
		cb.call(_earned)


func _finish_interstitial() -> void:
	var cb := _interstitial_done
	_interstitial_done = Callable()
	if _admob != null:
		_admob.call("load_interstitial_ad")
	elif fake:
		_interstitial_ready = true
	if cb.is_valid():
		cb.call()


## Pretend ad: a full-screen card for fake_seconds, then `finish`.
func _fake_show(text: String, finish: Callable) -> void:
	if _fake_layer == null:
		_fake_layer = CanvasLayer.new()
		_fake_layer.layer = 50
		add_child(_fake_layer)
		var bg := ColorRect.new()
		bg.color = Color(0.02, 0.02, 0.03, 0.96)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		_fake_layer.add_child(bg)
		var l := Label.new()
		l.name = "Text"
		l.set_anchors_preset(Control.PRESET_FULL_RECT)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 40)
		_fake_layer.add_child(l)
	(_fake_layer.get_node("Text") as Label).text = text
	_fake_layer.visible = true
	get_tree().create_timer(fake_seconds, true).timeout.connect(func():
		_fake_layer.visible = false
		finish.call())
