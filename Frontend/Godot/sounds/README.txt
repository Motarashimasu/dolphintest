Menu sound effects. Two ways to set them (both optional; anything unset is silent):

1. In the Godot editor: open look/menu_sounds.tres and drag your audio files onto the slots
   in the Inspector (move, select, back, player_join, player_leave, message, game_start).
   Keep the files in this folder so they are exported with the launcher.
2. Without the editor: put files named after the slot in SparkingData\sounds
   (move.wav, select.ogg, player_join.mp3, ...). Those win over the slots.

  move          moving the selection, changing a value
  select        pressing A / Enter
  back          B / Escape
  player_join   someone joined the lobby
  player_leave  someone left the lobby
  message       a chat message from another player
  game_start    a game is starting (offline, or the netplay match)

Short .wav or .ogg files work best. Volume: Options > Sound effects.
