<?php
// The logged-in player's ranked profile: ratings and records per mode, and lifetime record.
require __DIR__ . '/lib.php';

guard(function () {
    $p = auth(true);   // a banned player still sees their profile (and why)
    settle_due();
    $modes = [];
    foreach (MODES as $mode) {
        $modes[$mode] = rating_row((int)$p['id'], $mode);
    }
    // All-time record: every season (career never resets).
    $st = db()->prepare('SELECT COALESCE(SUM(wins), 0) AS w, COALESCE(SUM(losses), 0) AS l FROM career WHERE player_id = ?');
    $st->execute([(int)$p['id']]);
    $life = $st->fetch();
    out(['ok' => true, 'player' => ['id' => (int)$p['id'], 'name' => $p['name'],
         'discord_id' => $p['discord_id'], 'avatar' => $p['avatar'],
         'banned' => (bool)(int)$p['banned'], 'ban_reason' => (string)($p['ban_reason'] ?? '')],
         'season' => season_info(),
         'ratings' => $modes, 'lifetime' => ['wins' => (int)$life['w'], 'losses' => (int)$life['l']]]);
});
