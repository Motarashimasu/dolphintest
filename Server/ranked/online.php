<?php
// How many DRAGON NET players are online right now (public, JSON): {ok, online}. "Online" =
// a logged-in launcher that checked in within the online window (it polls every ~20 s).
require __DIR__ . '/lib.php';

guard(function () {
    $st = db()->prepare('SELECT COUNT(*) FROM players WHERE banned = 0 AND last_seen >= ?');
    $st->execute([now() - ONLINE_WINDOW]);
    header('Cache-Control: max-age=15');
    out(['ok' => true, 'online' => (int)$st->fetchColumn()]);
});
