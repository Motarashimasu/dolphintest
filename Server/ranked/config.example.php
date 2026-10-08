<?php
// Ranked server settings. Copy this file to config.php (same folder) and fill it in.
// config.php stays on your hosting: never share its contents (it holds passwords).
return [
    // MySQL / MariaDB (cPanel > MySQL Databases). On cPanel the host is almost always localhost.
    'db_host' => 'localhost',
    'db_name' => 'tecshideout_sparking',
    'db_user' => 'tecshideout_nottec2',
    'db_pass' => 'PUT-YOUR-DB-PASSWORD-HERE',

    // Discord login (Discord Developer Portal > your app > OAuth2).
    'discord_client_id' => '1431360832750620702',
    'discord_client_secret' => 'PUT-YOUR-DISCORD-CLIENT-SECRET-HERE',
    // Must match a Redirect added under OAuth2 > Redirects, exactly.
    'discord_redirect' => 'https://tecshideout.ct.ws/sparking/discord.php',
];
