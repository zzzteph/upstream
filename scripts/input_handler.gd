## ============================================================================
##  INPUT - mouse, touch (emulated as mouse) and keyboard.
## ============================================================================
## UI buttons and overlays eat their own clicks first; whatever reaches
## _unhandled_input is aimed at the board. A press that reaches the board
## (or the panel around it) also starts a "hold": keep it down to speed the
## water up. Releases are watched in _input so a hold always ends.
class_name InputHandler
extends Node

var game  ## The Game node (main.gd).


func _input(event: InputEvent) -> void:
	# Note how the player plays (every event passes here, even taps on buttons).
	if event is InputEventScreenTouch and event.pressed:
		game.note_input("touch")
	elif event is InputEventMouseButton and event.pressed and event.device != InputEvent.DEVICE_ID_EMULATION:
		game.note_input("mouse")
	elif event is InputEventKey and event.pressed and not event.echo:
		game.note_input("keys")
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		game.on_hold(false)
	elif event is InputEventKey and event.keycode == KEY_F and not event.pressed:
		game.on_hold_key(false)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		game.on_pointer_move(event.position, event.device == InputEvent.DEVICE_ID_EMULATION)
	elif event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			game.on_hold(true)
			game.on_pointer_press(event.position, event.device == InputEvent.DEVICE_ID_EMULATION)
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed:
		if _on_key(event.keycode, event.echo):
			get_viewport().set_input_as_handled()


func _on_key(key: int, echo: bool) -> bool:
	# Movement keys may repeat; everything else fires once per press.
	match key:
		KEY_LEFT, KEY_A:
			game.move_cursor(-1, 0)
			return true
		KEY_RIGHT, KEY_D:
			game.move_cursor(1, 0)
			return true
		KEY_UP, KEY_W:
			game.move_cursor(0, 1)
			return true
		KEY_DOWN, KEY_S:
			game.move_cursor(0, -1)
			return true
	if key == KEY_F:
		game.on_hold_key(true)  # Hold F to speed up (like holding the screen).
		return true
	if echo:
		return false
	match key:
		KEY_P, KEY_ESCAPE:
			game.toggle_pause()
		KEY_M:
			game.toggle_mute()
		KEY_R:
			game.restart_key()
		KEY_Q:
			game.use_freeze()
		KEY_E:
			game.use_reveal()
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			game.on_confirm()
		_:
			return false
	return true
