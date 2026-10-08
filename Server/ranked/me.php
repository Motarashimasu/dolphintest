<?php
// The logged-in player's ranked profile: ratings and records per mode, and lifetime record.
require __DIR__ . '/lib.php';

guard(function () {
    $p = auth();
    settle_due();
    $modes = [];
    $wins = $losses = 0;
    foreach (MODES as $mode) {
        $r = rating_row((int)$p['id'], $mode);
        $modes[$mode] = $r;
        $wins += $r['wins'];
        $losses += $r['losses'];
    }
    out(['ok' => true, 'player' => ['id' => (int)$p['id'], 'name' => $p['name'],
         'discord_id' => $p['discord_id'], 'avatar' => $p['avatar']],
         'ratings' => $modes, 'lifetime' => ['wins' => $wins, 'losses' => $losses]]);
});
