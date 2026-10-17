Menu music. Put a file here named after the track (ogg, mp3 or wav):

  main_menu    Main Menu, Video Settings, Options, Files & Folders (also the fallback
               for any track that has no file)
  game_menu    Budokai Tenkaichi 3 menu, Controller Setup, Modifications
  bt2_game_menu, bt2_netplay, bt2_lobby, bt2_battle_lounge, bt2_ranked
               Budokai Tenkaichi 2's menus (its own; no file = bt2_lobby for the
               lounge / ranked ones, else main_menu)
  netplay      Netplay, Player Match, Host, Find, Lobby Browser
  lobby        The lobby screen
  battle_lounge  The Battle Lounge lobby (no file = the lobby track)
  ranked       Ranked Match lobbies (no file = the lobby track)
  terminology  Tenkaichi Terminology

e.g. music/main_menu.ogg. Files in SparkingData\music\ (ogg or mp3) with the same names
override these without re-exporting. Music fades out while a game runs and resumes after.
