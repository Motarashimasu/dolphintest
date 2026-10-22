# Game copies built from the player's disc

The collection never ships the game. For a version with a **disc recipe**, the launcher builds
its own copy from the player's original disc and plays only that copy:

- **Sparking! 4.0** (shown as "4.0"; it's PAL internally, disc ID RDSPAF) is built from the
  player's original PAL disc: the disc is checked, then your 4.0 changes are applied.
- **NTSC-J** can get a recipe made from the original alone: the launcher then only checks the
  disc and makes its own copy of it (same files, same layout).
- Versions without a recipe work as before (the picked disc image is played as it is).

What players see: Setup (and Options > Game Copies) asks which version they want to play, then
for their disc file. The launcher checks it (a few minutes), builds the copy into
`SparkingData/title/<ID>.rvz` and from then on plays that. Their disc file is only read.

## What's checked

The player's disc can be any format Dolphin reads: ISO, WBFS (including scrubbed ones), RVZ / WIA,
GCZ, CISO, NKit. What's checked is the files inside the game partition, which are the same in
every good copy of a disc whatever the container:

- the disc ID (RDSPAF for 4.0): another version is refused with "That's the NTSC-U disc
  (RDSE70). 4.0 is built from the PAL disc (RDSPAF)." and the like;
- the disc revision;
- every file: none missing, none extra, every size and SHA-1 the original's. A modified copy
  (someone's 4.0 ISO, a texture hack) or a damaged one is refused, naming the file.

## The copy is locked

The built copy's size, date and SHA-256 are kept in the launcher's settings. If the file is
replaced or changed, it stops counting as a copy until it's built again from a disc (if only the
date changed, e.g. after a backup was restored, a hash check confirms it's still the same). It can't
be swapped from the launcher's menus either: a version with a recipe can only be **built** from a
disc, never pointed at a file. (Anyone can still change files on their own PC; this stops wrong
versions and casual swaps, which is what keeps online matches in sync.)

Every player's copy is byte-identical: it's built from the files only, not from their dump's
container, scrubbing or update partition. So online matches between players with ISO, WBFS or
NKit dumps are on exactly the same disc.

## Save states keep working

Every file of your version goes exactly where it is on your 4.0 disc (the file table and
main.dol too), and the game partition is at 0xF800000, where Wii discs have it. The game's file
table in a save state (which says where each file is) therefore matches the built copy, so the
states you made on your 4.0 disc load on players' built copies. `sparking_release.py disc` warns
if your disc has the game partition elsewhere (some rebuilding tools move it); then make the
states again on a built copy. Either way, try one state on a built copy before publishing.

## Making a recipe

You need DolphinTool (built with Dolphin) and your two discs: a clean copy of the original PAL
disc (any format; `DolphinTool.exe verify -i <disc>` should report no problems) and your
4.0 disc.

```
cmake --build --preset visualstudio-build-release-x64 --target dolphin-tool
```

That makes `DolphinTool.exe` next to `DolphinNoGUI.exe` in Dolphin's Binaries folder. **Copy it
into the build's `Dolphin` folder too**: the launcher runs it to build copies.

```
python Tools\sparking_release.py disc --original "E:\Discs\BT3 PAL original.wbfs" --modded "E:\Discs\Sparking 4.0.iso" --name "4.0" --out "E:\SparkDol\DBZSC\SparkingData\discs\RDSPAF" --dolphin-tool "E:\SparkDol\DBZSC\Dolphin\DolphinTool.exe"
python Tools\sparking_release.py disc --original "E:\Discs\BT3 NTSC-J.iso" --name "NTSC-J" --out "E:\SparkDol\DBZSC\SparkingData\discs\RDSJAF" --dolphin-tool "E:\SparkDol\DBZSC\Dolphin\DolphinTool.exe"
```

- `--out` is the build's `SparkingData\discs\<the original's disc ID>`.
- It extracts both discs to a temporary folder (`--temp` to choose where: needs room for both).
- It prints what's in `data.bin`: only bytes that aren't already in the same file on the
  original disc (your changes, your new files). Files you copied from the original disc to
  another place are referenced, not stored. If the list shows big files you didn't make (e.g. a
  model taken from another game), those would be shipped as they are: leave them out of 4.0.
- It rebuilds every changed file from the recipe and compares before writing it.

Then publish the build as usual (`sparking_release.py publish`): `SparkingData/discs/**` is in
the default update list. If your release.json has its own `"include"`, add
`"SparkingData/discs/**"` to it.

When you change 4.0: make the recipe again and publish. Players' launchers see the new recipe
and offer to build their copy again from the disc they used before (it's remembered).

## Players who already have a copy

After the update, a player whose 4.0 was set the old way (a picked ISO) sees "Game Copies: 4.0
is now built from your original PAL disc. Build it from <their file>?". If that file is the
original disc, it's built from it; if it's a 4.0 ISO (modified), it's refused with "That copy
isn't the original disc" and they pick their original.

## Testing

`python3 Tools/sparking_disc_test.py <dolphin-tool> [work folder] [godot]` makes made-up Wii
discs (no game data) in every format and checks the whole thing, including the launcher's side.
