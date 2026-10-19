<?php
// The logged-in player's ranked profile: ratings and records per mode, and lifetime record.
// game = bt3 (default) | bt2: `ratings` holds that game's modes under their plain names (single,
// team) and `lifetime` is that game's; `all_ratings` has every mode.
require __DIR__ . '/lib.php';

guard(function () {
    $p = auth(true);   // a banned player still sees their profile (and why)
    settle_due();
    $game = valid_game(arg('game'));
    $all = [];
    foreach (MODES as $mode) {
        $all[$mode] = rating_row((int)$p['id'], $mode);
    }
    $modes = [];
    foreach (GAME_MODES[$game] as $mode) {
        $modes[preg_replace('/^b2/', '', $mode)] = $all[$mode];   // b2single -> single
    }
    // All-time record: every season (career never resets), this game's modes.
    $in = implode(',', array_fill(0, count(GAME_MODES[$game]), '?'));
    $st = db()->prepare("SELECT COALESCE(SUM(wins), 0) AS w, COALESCE(SUM(losses), 0) AS l FROM career
                         WHERE player_id = ? AND mode IN ($in)");
    $st->execute(array_merge([(int)$p['id']], GAME_MODES[$game]));
    $life = $st->fetch();
    out(['ok' => true, 'player' => ['id' => (int)$p['id'], 'name' => $p['name'],
         'discord_id' => $p['discord_id'], 'avatar' => $p['avatar'], 'picture' => player_pic($p),
         'banned' => (bool)(int)$p['banned'], 'ban_reason' => (string)($p['ban_reason'] ?? '')],
         'season' => season_info(),
         'game' => $game, 'ratings' => $modes, 'all_ratings' => $all, 'lifetime' => ['wins' => (int)$life['w'], 'losses' => (int)$life['l']]]);
});
