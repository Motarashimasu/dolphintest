DRAGON NET Ranked server
========================

PHP 8.1+ and MySQL/MariaDB (any cPanel hosting without a "browser check" on requests).
The launcher talks to it at https://<your site>/sparking/ (Settings: [ranked] server).

Install / update
----------------
1. Upload every file in this folder to public_html/sparking/ (File Manager > Upload, or FTP),
   EXCEPT config.php if you already have one there (keep yours).
2. First install only: copy config.example.php to config.php and fill it in:
     - db_* : the database and user from cPanel > MySQL Databases (host: localhost)
     - discord_client_secret : Discord Developer Portal > your app > OAuth2 > Client Secret
     - discord_redirect : must also be added, exactly, under OAuth2 > Redirects:
           https://tecshideout.ct.ws/sparking/discord.php
   Never share config.php: it holds the passwords. The .htaccess file blocks it from the web.
3. Open https://tecshideout.ct.ws/sparking/ in a browser: the leaderboard page. The database
   tables are created on the first request (nothing to import).
4. Delete test.php / dbtest.php if they're still there.

Admin panel
-----------
Set 'admin_key' in config.php (a long password, 12+ characters), then open
https://tecshideout.ct.ws/sparking/admin.php and sign in with it.
  Players  search; edit a player's rating / wins / losses for this season; ban (closes their
           lobbies, logs them out, hides them from the leaderboards; they see the reason) / unban
  Matches  recent matches; Void undoes a counted match's rating changes and records
  Seasons  Start new season (type RESET): the final standings are archived (viewable there),
           then every rating goes back to 1000 and every record to 0-0, region boards too.
           The all-time record keeps every season.
  Messages send a message (up to 500 characters) to every logged-in player: it pops up once on
           their launcher (outside games) until they close it with a button; players who log in
           while it's on (1-30 days) get it too. See how many closed it; Switch off stops it.
  (a player's page also has Remove picture for their profile picture)
  Replays  the shared replays (newest first, size, downloads); Delete removes one
  Log      every admin action, with what changed
Leave admin_key empty to switch the panel off.

What's in here
--------------
  admin.php        the admin panel (above)
  index.php        the website's front page: 3 downloads, players online, top players, board
  site.php         the website's shared layout, login session and helpers
  ranks.php        the leaderboard web page (mode, region, all-time record)
  player.php       players: search, and a player's page (ratings, record, latest matches)
  board.php        the message board (DRAGON NET accounts post; moderate in admin.php > Board)
  support.php      support & feedback form (answer in admin.php > Support)
  login.php        website log in / log out with a DRAGON NET account
  download.php     the download buttons (config "downloads"; counts clicks)
  leaderboard.php  the leaderboard as JSON for the launcher
  online.php       how many players are online now (the launcher's DRAGON NET menu)
  account.php      DRAGON NET accounts: register / login (username + password) / claim,
                   profile picture (128 x 128; stored in pics/, closed to browsers)
  pic.php          shows a profile picture
  social.php       friends (requests, who's online) and the admin's messages
  replays.php      shared replays: upload in pieces / search / download / delete. The files
                   go to replay_files/ (made by itself, closed to browsers). Optional limits in
                   config.php: replay_max_mb (all replays together, default 1500 MB: the oldest
                   are deleted first), replay_daily (per player per day, default 30).
  auth.php         logout; and the Discord login, only to convert a profile from before accounts
  discord.php      where Discord sends the browser back after "Authorize"
  update.php       automatic updates: short-lived download links into the Cloudflare R2
                   bucket for logged-in players (r2_* in config.php; Docs/UPDATES.md)
  me.php           your profile: ratings and records
  lobby.php        ranked lobbies: open / heartbeat / close / list / join / status / leave
  match.php        ranked matches: start / report / forfeit
  notices.php      the launcher's notification bars, in the player's language
  notices_text.example.php   the bars' text: copy to notices_text.php and edit that (below)
  lib.php          shared code (database, ratings)
  config.example.php, .htaccess

Notification bars
-----------------
The launcher shows three bars above its description box: red (emergencies, updates; always
first), blue (general announcements) and yellow (player news). Their text comes from
notices_text.php: copy notices_text.example.php to notices_text.php once, then edit that one in
File Manager (updates never overwrite it). Each bar has a line per language (en, es, it); an empty
language uses the English line, an empty bar isn't shown. Players newly reaching the global
Top 5 of a mode are added to the yellow bar automatically for 24 hours. Launchers pick up
changes within 2 minutes.

Rules
-----
- Accounts: players make a DRAGON NET account in the launcher (username 3-20 letters, digits,
  _ . -; password 6+ characters, stored hashed). 8 wrong passwords for one username = a 5-minute
  wait. Ranked profiles from before accounts were made with a Discord login: their owner uses
  "Convert my Discord ranked profile" once (Discord login, then a username + password) and keeps
  the ratings. Discord makes no new profiles. A player is "online" for friends while their
  launcher is open (it checks in every 20 seconds).
- One account = one ranked profile. Ratings: Elo (K=32), 1000 to start, separate for
  Single Battle (first to 2 wins) and Team Battle (one match), and per game: Budokai
  Tenkaichi 2 has its own ladder (modes b2single / b2team on the server, "BT2 ..." on the web
  page). A game's versions (NTSC-U / PAL / NTSC-J) share a rating, but a ranked lobby only lists
  for players on the same version.
- Updating from an older version: just upload the files; the database adds what's new on the
  first request (lobbies get a "version" column; players get username / password; friends,
  messages and login-attempt tables are made).
- A match counts when both players' launchers report the same result. One report alone counts
  after 2 minutes (the other player left or crashed). Reports that disagree void the match.
  Leaving or stopping a running match counts as a loss.
- Region boards count ranked lobbies hosted in that region; Global counts all.
- Seasons: ratings and records are per season; the all-time record (career) never resets.
