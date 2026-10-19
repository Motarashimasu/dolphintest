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

    // Password for admin.php (12+ characters). Leave empty to turn the admin panel off.
    'admin_key' => '',

    // Shared replays (replays.php), all optional: where the files go (keep it out of reach of
    // browsers; an .htaccess is written there), the total size kept (the oldest go first) and
    // how many replays one player may share per day.
    // 'replay_dir' => __DIR__ . '/replay_files',
    // 'replay_max_mb' => 1500,
    // 'replay_daily' => 30,

    // Profile pictures (account.php > picture): where they're kept, and this server's public
    // address for their links (normally worked out from the request).
    // 'pic_dir' => __DIR__ . '/pics',
    // 'public_url' => 'https://tecshideout.ct.ws/sparking/',
];
