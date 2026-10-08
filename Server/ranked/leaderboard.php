<?php
// Public leaderboard (JSON). mode = single | team | all (lifetime record across modes),
// region = global | EA CN EU NA SA OC AF, limit = 1-200.
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
    out(['ok' => true, 'mode' => $mode, 'region' => $region,
         'rows' => leaderboard($mode, $region, (int)arg('limit', '100'))]);
});
