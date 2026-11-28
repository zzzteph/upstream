## Makes the Android launcher icons from icon.svg:
##   godot --headless --script res://tools/make_android_icons.gd
## A 192x192 legacy icon, and the adaptive icon's 432x432 layers: the artwork
## centred in the safe zone (Android crops adaptive icons to circles,
## squircles and so on) over a plain background in the icon's own steel colour.
extends SceneTree


func _initialize() -> void:
	var svg := FileAccess.get_file_as_string("res://icon.svg")
	_save(_render(svg, 192), 192, "res://assets/android/icon_192.png")
	var fg := Image.create(432, 432, false, Image.FORMAT_RGBA8)
	fg.fill(Color(0, 0, 0, 0))
	var art := _render(svg, 280)
	fg.blend_rect(art, Rect2i(Vector2i.ZERO, art.get_size()), Vector2i((432 - 280) / 2, (432 - 280) / 2))
	fg.save_png("res://assets/android/icon_foreground_432.png")
	var bg := Image.create(432, 432, false, Image.FORMAT_RGBA8)
	bg.fill(Color("1c252c"))
	bg.save_png("res://assets/android/icon_background_432.png")
	var mono: Image = fg.duplicate()
	for y in 432:
		for x in 432:
			var a: float = mono.get_pixel(x, y).a
			mono.set_pixel(x, y, Color(1, 1, 1, a))
	mono.save_png("res://assets/android/icon_monochrome_432.png")
	print("icons written")
	quit(0)


func _render(svg: String, px: int) -> Image:
	var img := Image.new()
	img.load_svg_from_string(svg, px / 128.0)
	if img.get_width() != px:
		img.resize(px, px, Image.INTERPOLATE_LANCZOS)
	img.convert(Image.FORMAT_RGBA8)
	return img


func _save(img: Image, _px: int, path: String) -> void:
	img.save_png(path)
