<?php
// Public leaderboard (JSON). mode = single | team | b2single | b2team | all (lifetime record
// across the game's modes; game = bt3 | bt2), region = global | EA CN EU NA SA OC AF, limit = 1-200.
require __DIR__ . '/lib.php';

guard(function () {
    settle_due();
    $mode = arg('mode', 'single');
    if ($mode !== 'all') {
        valid_mode($mode);
    }
    $region = arg('region', 'global');
    if ($region !== 'global') {
        $region = valid_region($region);
    }
    out(['ok' => true, 'mode' => $mode, 'region' => $region, 'season' => season_info(),
         'rows' => leaderboard($mode, $region, (int)arg('limit', '100'), valid_game(arg('game')))]);
});
