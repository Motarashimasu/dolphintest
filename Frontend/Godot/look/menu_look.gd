@tool
extends Resource
## The look of the menus. Open res://look/menu_look.tres in the Godot editor and change it in
## the Inspector: colors, fonts, pictures. Run the project (F5) to see it, or press F9 in the
## running menus to reload it after saving.
##
## The background behind the menus is its own scene, res://scenes/Backdrop.tscn: open it in the
## 2D editor to move, replace or delete the sky, clouds and ground, or to add your own art.
## Its CornerLeft / CornerRight clouds (look/corner_left.png, corner_right.png) sit over the menu
## pictures and behind everything else, on every menu.

@export_group("Fonts")
## Screen titles (the big one at the top, and in-game menus). Empty = menu_font.
@export var title_font: Font
## The lobby's headings and names. Empty = Godot's built-in font (bold).
@export var menu_font: Font
## Button text: the menu wheel, the rows of the settings screens, the button hints at the bottom.
## Empty = Impact (installed with Windows).
@export var button_font: Font
## Descriptions and everything else. Empty = Tahoma (installed with Windows).
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
## The Battle Lounge (King of the Hill) lobby. Empty = the lobby picture.
@export var background_battle_lounge: Texture2D
## Ranked Match lobbies. Empty = the lobby picture.
@export var background_ranked: Texture2D
@export var background_terminology: Texture2D

@export_group("Title")
## The letters: a gradient from title_color (top) to title_color_bottom (the baseline).
@export var title_color := Color("#fcb630")
@export var title_color_bottom := Color("#fd2a24")
## The dark edge around the letters...
@export var title_outline_color := Color("#631c12")
## ... and the light rim around that (0 = none).
@export var title_rim_color := Color("#fdecd6")
@export_range(16, 128) var title_size := 64
@export_range(0, 24) var title_outline := 12
@export_range(0, 24) var title_rim := 10
## Drop shadow distance (0 = none).
@export_range(0, 24) var title_shadow := 6

@export_group("Menu wheel")
## The bar behind the selected item (drawn as-is, stretched to the size below).
@export var selected_bar: Texture2D = preload("res://look/bar_selected.png")
@export var selected_bar_size := Vector2i(860, 72)
## The bar behind every other item.
@export var row_bar: Texture2D = preload("res://look/bar_row.png")
@export var row_bar_size := Vector2i(500, 44)
## The menu arrows: the wheel's up/down buttons, both ends of changeable values, selectors.
## Empty = look/arrow_left.png, arrow_right.png, arrow_up.png, arrow_down.png.
@export var arrow_left: Texture2D
@export var arrow_right: Texture2D
@export var arrow_up: Texture2D
@export var arrow_down: Texture2D
## Popup box (e.g. "Receiving Ranking Data..."). Empty = look/popup_box.png. Its notched
## corners keep their size (the margins below, in the picture's pixels), the middle stretches.
@export var popup_box: Texture2D
@export var popup_box_margins := Vector4i(100, 64, 100, 64)   # left, top, right, bottom
@export var selected_text := Color("#fff4d6")
@export var selected_outline := Color("#4a1a08")
@export var text := Color("#5b3a8c")
@export var text_outline := Color.WHITE
@export_range(16, 96) var text_size := 46
## The round letter icon before each item.
@export var badges := true
@export var arrow_color := Color("#f7a531")
@export var arrow_hover_color := Color("#ffd27a")

@export_group("Transitions")
## Changing menus: the new menu fades in from this color.
@export var fade_color := Color.BLACK
## How long that fade takes, in seconds (0 = no fade).
@export_range(0.0, 2.0, 0.05) var fade_time := 0.35
## Entering a DRAGON NET lobby: fades in from this color instead.
@export var lobby_fade_color := Color.WHITE
@export_range(0.0, 2.0, 0.05) var lobby_fade_time := 0.6

@export_group("Item colors")
## Color of a menu item by its label, e.g. "DRAGON NET" -> blue. Items not listed keep their own.
@export var item_colors: Dictionary = {}

@export_group("Description bar")
@export var description_color := Color("#0f3a48")
@export var description_border := Color("#cfe9ee")
@export var description_text := Color.WHITE
## A picture for the whole bar (stretched to 1280 x 190); it replaces the color and border.
## Empty = the flat description_color bar.
@export var description_image: Texture2D = preload("res://look/description_bar.png")

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
