@tool
extends Resource
## The look of the menus. Open res://look/menu_look.tres in the Godot editor and change it in
## the Inspector: colors, fonts, pictures. Run the project (F5) to see it, or press F9 in the
## running menus to reload it after saving.
##
## The background behind the menus is its own scene, res://scenes/Backdrop.tscn: open it in the
## 2D editor to move, replace or delete the sky, clouds and ground, or to add your own art.

@export_group("Fonts")
## Titles and the menu wheel. Empty = Godot's built-in font (bold).
@export var menu_font: Font
## Everything else. Empty = Godot's built-in font.
@export var body_font: Font

@export_group("Menu pictures")
## A picture over the backdrop for every menu (covers the whole window). Empty = the backdrop
## scene shows through.
@export var background_default: Texture2D
## Per menu (they win over the default):
@export var background_main_menu: Texture2D
@export var background_game_menu: Texture2D
@export var background_netplay: Texture2D
@export var background_lobby: Texture2D
@export var background_terminology: Texture2D

@export_group("Title")
@export var title_color := Color("#ff8a1f")
@export var title_outline_color := Color("#6b1d0b")
@export_range(16, 128) var title_size := 64
@export_range(0, 24) var title_outline := 8
## Drop shadow distance (0 = none).
@export_range(0, 24) var title_shadow := 6

@export_group("Menu wheel")
## On: the highlight band takes each item's own color (see Item colors). Off: band_color.
@export var band_uses_item_color := true
@export var band_color := Color("#f2b531")
@export_range(0.0, 1.0) var band_opacity := 0.82
@export var band_border_color := Color(1, 1, 1, 0.8)
@export_range(0, 16) var band_border := 3
## A picture for the highlight band (stretched to 860 x 72) instead of the flat color.
@export var band_image: Texture2D
## On: the picture is tinted with the band color. Off: shown as drawn.
@export var band_image_tint := true
@export var selected_text := Color("#fff4d6")
@export var selected_outline := Color("#4a1a08")
@export var text := Color("#5b3a8c")
@export var text_outline := Color.WHITE
@export_range(16, 96) var text_size := 46
## The round letter icon before each item.
@export var badges := true
@export var arrow_color := Color("#f7a531")
@export var arrow_hover_color := Color("#ffd27a")

@export_group("Item colors")
## Color of a menu item by its label, e.g. "Netplay" -> blue. Items not listed keep their own.
@export var item_colors: Dictionary = {}

@export_group("Description bar")
@export var description_color := Color("#0f3a48")
@export var description_border := Color("#cfe9ee")
@export var description_text := Color.WHITE
## A picture for the whole bar (stretched to 1280 x 190), drawn over the color.
@export var description_image: Texture2D

@export_group("Panels")
## Settings screens and the lobby.
@export var panel_color := Color("#2b6478", 0.94)
@export var panel_border := Color(1, 1, 1, 0.45)
@export_range(0, 48) var panel_radius := 18
## A picture for panels instead of the flat color (9-slice: panel_image_margin px corners).
@export var panel_image: Texture2D
@export_range(0, 128) var panel_image_margin := 24
@export var row_color := Color("#0f3a48", 0.72)
@export var row_selected_color := Color("#f2b531", 0.85)
@export var row_selected_border := Color(1, 1, 1, 0.85)
@export var row_text := Color.WHITE
@export var row_selected_text := Color("#fff4d6")
@export_range(0, 32) var row_radius := 10

@export_group("Other colors")
## Text-field focus, player 1 badge, headings.
@export var accent := Color("#f2b531")
## Connection quality and button prompts.
@export var good := Color("#3fbf6b")
@export var ok := Color("#f2b531")
@export var poor := Color("#e8663d")
@export var muted := Color("#8a9bb0")
@export var toast_color := Color("#1b1b24")
@export var toast_text := Color.WHITE
