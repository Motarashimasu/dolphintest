@tool
extends Resource
## The menus' sound effects. Open res://look/menu_sounds.tres in the Godot editor and drag an audio
## file (.wav, .ogg or .mp3 from the FileSystem dock) onto each slot in the Inspector. An empty
## slot is silent.
##
## Without the editor: put files named after the slot in SparkingData\sounds (or res://sounds),
## e.g. move.wav, select.ogg, player_join.mp3. Those win over the slots.
## Volume: Options > Sound effects.

@export_group("Menus")
## Moving the selection (Up/Down), and changing a value (Left/Right).
@export var move: AudioStream
## Pressing A / Enter on something.
@export var select: AudioStream
## Going back (B / Escape).
@export var back: AudioStream

@export_group("Lobby")
## Someone joined the lobby.
@export var player_join: AudioStream
## Someone left the lobby.
@export var player_leave: AudioStream
## A chat message from another player.
@export var message: AudioStream

@export_group("Game")
## A game is starting (offline, or the host started the netplay match).
@export var game_start: AudioStream

@export_group("Volume")
## Extra volume for all of them, in dB (0 = as recorded; -6 = half as loud).
@export_range(-30.0, 12.0, 0.5) var volume_db := 0.0
