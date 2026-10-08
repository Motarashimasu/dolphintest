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

What's in here
--------------
  index.php        the leaderboard web page (mode, region, all-time record)
  leaderboard.php  the same as JSON for the launcher
  auth.php         Discord login for the launcher (start / poll / logout)
  discord.php      where Discord sends the browser back after "Authorize"
  me.php           your profile: ratings and records
  lobby.php        ranked lobbies: open / heartbeat / close / list / join / status / leave
  match.php        ranked matches: start / report / forfeit
  lib.php          shared code (database, ratings)
  config.example.php, .htaccess

Rules
-----
- One Discord account = one ranked profile. Ratings: Elo (K=32), 1000 to start, separate for
  Single Battle (first to 2 wins) and Team Battle (one match).
- A match counts when both players' launchers report the same result. One report alone counts
  after 2 minutes (the other player left or crashed). Reports that disagree void the match.
  Leaving or stopping a running match counts as a loss.
- Region boards count ranked lobbies hosted in that region; Global counts all.
