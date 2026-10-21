# Automatic updates

The launcher updates itself and everything shipped next to it. You publish a build once with
one command, and every logged-in player's launcher picks it up the next time it starts.

```
your PC                         Cloudflare R2 (private bucket)        your ranked site
-------                         ------------------------------        ----------------
sparking_release.py publish --> files/<sha256>, manifest.json
                                          ^                            update.php: "here's a
launcher (logged in) ---- asks for links ----------------------------> link, valid 15 min"
launcher <---------------- downloads with those links -----------------
```

- **Who can download:** only logged-in DRAGON NET players. The bucket is private, and
  `update.php` hands out download links that expire after 15 minutes. A shared link stops
  working, and nobody can list the bucket.
- **What's checked:** the list of files (the manifest) is signed with your release key. The
  launcher refuses any list that isn't, and checks each downloaded file's SHA-256 against the
  list. Someone who got into the bucket or your website still can't push files to players
  without the private key on your PC. A list older than the installed build is ignored, so an
  old signed list put back can't downgrade players.
- **Never during a game:** a running game holds Dolphin's files, so an update waits until the
  game is closed.
- **What's updated:** only the files in the list: the launcher's `.exe` and `.pck`, the `Dolphin`
  folder, battle states and texture packs (the release config's `include`). Players' saves,
  settings (`frontend.cfg`), controller profiles, replays and Dolphin user folders are never
  touched. A file that an earlier update installed and the new build no longer has is deleted.
- **Only changes are downloaded:** files are stored under their own hash, so publishing uploads
  only new files, and a launcher downloads only the files that differ from its copy. A changed
  ini is a few KB.
- **The launcher itself:** Windows doesn't let a running program overwrite its own `.exe` or
  `.pck`. The launcher downloads them, starts a small hidden PowerShell script, and closes. The
  script waits for it to exit, copies the files in and starts the launcher again
  (`SparkingData/update/finish_update.ps1`, which deletes itself).

## One-time setup

### 1. Cloudflare R2

1. Cloudflare dashboard > **R2 Object Storage** > **Create bucket**, e.g. `dbzsc-updates`. Leave
   public access **off**.
2. Note your **Account ID** (R2 overview page, right side).
3. **R2 > Manage API tokens > Create API token**, twice:
   - `ranked-site-read`: permission **Object Read only**, applied to this bucket only. It goes in
     `config.php` (step 3).
   - `release-upload`: permission **Object Read & Write**, this bucket only. It goes in
     `release.json` on your PC (step 4).
   Each one shows an **Access Key ID** and a **Secret Access Key** once; copy them then.

### 2. The release key (on your PC)

```
python Tools/sparking_release.py keygen C:\SparkingKeys
```

This writes `C:\SparkingKeys\release_private.pem` and `release_public.pem`.

- Copy `release_public.pem` to `Frontend/Godot/data/update_key.pem` and commit it. Public is
  fine: it can only check signatures.
- **Keep `release_private.pem` secret and back it up** (a USB stick, a password manager). Never
  commit it or send it to anyone. Whoever has it can push files to every player. If you lose
  it, you need a new key, which means a new launcher installed by hand.

Until `data/update_key.pem` exists, the launcher's updates stay off (Options > Updates:
"Not set up").

### 3. Your ranked site

1. Upload `Server/ranked/update.php` next to the other PHP files.
2. Add the read-only token to your own `config.php` (see `config.example.php`):
   ```php
   'r2_account_id' => '<Account ID>',
   'r2_access_key' => '<ranked-site-read Access Key ID>',
   'r2_secret_key' => '<ranked-site-read Secret Access Key>',
   'r2_bucket' => 'dbzsc-updates',
   ```
   Your site and R2 being separate doesn't matter: the site only signs links, it never contacts
   R2.

### 4. `release.json` (on your PC, next to the key, never in the repo)

```json
{
  "r2_account_id": "<Account ID>",
  "r2_access_key": "<release-upload Access Key ID>",
  "r2_secret_key": "<release-upload Secret Access Key>",
  "r2_bucket": "dbzsc-updates",
  "private_key": "C:/SparkingKeys/release_private.pem",
  "launcher": "DRAGON BALL Sparking! Collection.exe",
  "include": ["*.exe", "*.pck", "*.ico", "Dolphin/**", "SparkingData/states/*",
              "SparkingData/textures/**"],
  "exclude": []
}
```

- `launcher`: the launcher's file name in the build folder. The restart script starts it.
  **Keep this name the same from build to build**, because players' shortcuts point to it.
- `include` / `exclude`: paths relative to the build folder. `Folder/**` means everything under
  it; `*` never crosses a folder. Anything not included is never sent: your `.bat` test scripts,
  `saves`, `user`, `frontend.cfg`, `statebackup`...

### 5. The installer

- The launcher must be able to write to its own folder. Install it per user, not under
  Program Files: in the `.iss`, `PrivilegesRequired=lowest`, plus the `[Dirs]` entry with
  `users-modify` (as in `dbzsc.iss`).
- Export the launcher with its `.pck` next to the `.exe` (`export_presets.cfg`:
  `embed_pck=false`, already set). Then a menu change downloads the `.pck` (your music and
  pictures) and never the Godot engine (the `.exe`).
- Players on a build from before automatic updates (205 and older) install the first updating
  build by hand, once.

## Publishing a build

1. Put the build together as usual (e.g. `E:\SparkDol\DBZSCv206`).
2. Check what would be sent:
   ```
   python Tools/sparking_release.py publish E:\SparkDol\DBZSCv206 --config C:\SparkingKeys\release.json --version 206 --dry-run
   ```
3. Publish:
   ```
   python Tools/sparking_release.py publish E:\SparkDol\DBZSCv206 --config C:\SparkingKeys\release.json --version 206 --notes "BT2 battle states fixed"
   ```
   New files are uploaded first and the signed list last, so a player never sees a list whose
   files aren't there yet.
4. Every logged-in player gets it on their next launcher start, or from Options > Updates.

Now and then, delete files that only old builds used (keeps the newest 3 builds' files):

```
python Tools/sparking_release.py prune --config C:\SparkingKeys\release.json --yes
```

## For players

- **At start**, when logged in: if there's a newer build, the **Update** screen downloads it
  (progress, version, what's new) and installs it. If the launcher's own files changed, it
  restarts by itself. **Back** = later: they play the current build, and what was downloaded is
  kept for the next try.
- **Options > Updates**: the state ("Up to date (206)", "Needs a DRAGON NET login"...); press it
  to check now.
- Not logged in: no updates (everything else works as before).

## Tests

- `python3 Tools/sparking_release.py self-test`: the R2 signing code against AWS's published
  Signature Version 4 examples, and RSA sign / verify.
- `python3 Tools/update_test.py <godot>`: end to end. A stand-in for R2 that checks every
  request's signature, the real ranked server with `update.php`, the real release script and the
  real launcher updating a fake install. Covers: only changed files downloaded; players' files
  untouched; files removed from the build deleted; hand-edited files restored; the launcher's own
  `.pck` installed by the restart script; a list not signed by the release key refused; a file
  swapped on the bucket refused; no update without a login; prune.
- `update.php`'s link signing matches AWS's published presigned-URL example exactly.
