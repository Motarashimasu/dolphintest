<?php
// ONE-OFF ADMIN TOOL. Records a test ranked match between two players already in the database,
// through the same code real matches use (both reports agree -> Elo, records, region records).
//
//   1. Add to config.php:   'admin_key' => 'some-long-random-word',
//   2. Upload this file next to lib.php (public_html/sparking/).
//   3. Open https://<site>/sparking/stattest.php?key=some-long-random-word
//   4. DELETE this file when done (and you can remove admin_key again).
require __DIR__ . '/lib.php';

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
$h = fn($s) => htmlspecialchars((string)$s, ENT_QUOTES);

function shell(string $body): never
{
    echo '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
        . '<title>Ranked stat test</title><style>body{margin:0;background:#0f2a35;color:#fff;font-family:Tahoma,Verdana,sans-serif}'
        . 'main{max-width:900px;margin:0 auto;padding:24px 16px}h1{color:#ff8a1f;font-family:Impact,sans-serif;font-weight:normal}'
        . 'table{width:100%;border-collapse:collapse;background:#163f4f;margin:12px 0}th,td{padding:8px 10px;text-align:left;border-bottom:1px solid #2b6577}'
        . 'th{color:#f2b531}td.n{text-align:right}select,button{font:inherit;padding:6px 10px;border-radius:6px;border:2px solid #6fc3d6;background:#163f4f;color:#fff}'
        . 'button{background:#f2b531;color:#111;border-color:#f2b531;cursor:pointer}.ok{color:#3fbf6b}.bad{color:#e8663d}form{display:flex;gap:8px;flex-wrap:wrap;align-items:center}'
        . '</style></head><body><main><h1>Ranked stat test</h1>' . $body . '</main></body></html>';
    exit;
}

$c = cfg();
$admin = (string)($c['admin_key'] ?? '');
$key = (string)($_GET['key'] ?? '');
if (strlen($admin) < 12 || !hash_equals($admin, $key)) {
    http_response_code(403);
    shell('<p class="bad">Locked.</p><p>Add <code>\'admin_key\' =&gt; \'a-long-random-word\',</code> (12+ characters) to config.php, then open <code>stattest.php?key=a-long-random-word</code>.</p>');
}

try {
    $db = db();
    $players = $db->query('SELECT id, name, discord_id FROM players ORDER BY id')->fetchAll();
    $by_id = [];
    foreach ($players as $p) {
        $by_id[(int)$p['id']] = $p;
    }
    $table = function () use ($players, $h): string {
        $rows = '';
        foreach ($players as $p) {
            $s = rating_row((int)$p['id'], 'single');
            $t = rating_row((int)$p['id'], 'team');
            $rows .= '<tr><td>' . (int)$p['id'] . '</td><td>' . $h($p['name']) . '</td>'
                . "<td class=n>{$s['rating']}</td><td class=n>{$s['wins']}-{$s['losses']}</td>"
                . "<td class=n>{$t['rating']}</td><td class=n>{$t['wins']}-{$t['losses']}</td></tr>";
        }
        return '<table><tr><th>#</th><th>Player</th><th class=n>Single</th><th class=n>W-L</th><th class=n>Team</th><th class=n>W-L</th></tr>'
            . ($rows ?: '<tr><td colspan=6>No players yet: log in from the game first.</td></tr>') . '</table>';
    };

    $msg = '';
    $winner = (int)($_GET['winner'] ?? 0);
    $loser = (int)($_GET['loser'] ?? 0);
    if ($winner || $loser) {
        $mode = valid_mode($_GET['mode'] ?? 'single');
        $region = valid_region($_GET['region'] ?? 'NA');
        if (!isset($by_id[$winner], $by_id[$loser]) || $winner === $loser) {
            $msg = '<p class="bad">Pick two different players.</p>';
        } else {
            $before = [$winner => rating_row($winner, $mode)['rating'], $loser => rating_row($loser, $mode)['rating']];
            // Same path as a real match: a (closed) lobby, a live match, both players' reports.
            $t = now();
            $db->prepare("INSERT INTO lobbies (host_id, guest_id, mode, region, join_target, link, created, heartbeat, guest_seen, closed)
                          VALUES (?, ?, ?, ?, 'stat-test', 'unknown', ?, ?, ?, 1)")
                ->execute([$winner, $loser, $mode, $region, $t, $t, $t]);
            $lobby = (int)$db->lastInsertId();
            $db->prepare("INSERT INTO matches (lobby_id, mode, region, p1, p2, state, created, r1, r1_at, r2, r2_at)
                          VALUES (?, ?, ?, ?, ?, 'live', ?, 'win', ?, 'loss', ?)")
                ->execute([$lobby, $mode, $region, $winner, $loser, $t, $t, $t]);
            $mid = (int)$db->lastInsertId();
            $db->prepare('UPDATE lobbies SET match_id = ? WHERE id = ?')->execute([$mid, $lobby]);
            settle(get_match($mid));
            $m = get_match($mid);
            $after = [$winner => rating_row($winner, $mode)['rating'], $loser => rating_row($loser, $mode)['rating']];
            $ok = $m['state'] === 'done' && (int)$m['winner'] === $winner;
            $msg = '<p class="' . ($ok ? 'ok' : 'bad') . '">' . ($ok ? 'Recorded' : 'Something went wrong') . ": match #$mid ("
                . $h($mode) . ', ' . $h($region) . ', ' . $h($m['state']) . ', ' . $h($m['reason']) . ').</p>'
                . '<p>' . $h($by_id[$winner]['name']) . ": {$before[$winner]} → {$after[$winner]} (" . sprintf('%+d', (int)$m['d1']) . ')<br>'
                . $h($by_id[$loser]['name']) . ": {$before[$loser]} → {$after[$loser]} (" . sprintf('%+d', (int)$m['d2']) . ')</p>';
        }
    }

    $opts = '';
    foreach ($players as $p) {
        $opts .= '<option value="' . (int)$p['id'] . '">' . $h($p['name']) . '</option>';
    }
    $regions = '';
    foreach (REGIONS as $r) {
        $regions .= "<option" . ($r === 'NA' ? ' selected' : '') . ">$r</option>";
    }
    shell($msg . $table()
        . '<form method="get"><input type="hidden" name="key" value="' . $h($key) . '">'
        . 'Winner <select name="winner">' . $opts . '</select> beats <select name="loser">' . $opts . '</select>'
        . ' in <select name="mode"><option value="single">Single Battle FT2</option><option value="team">Team Battle</option></select>'
        . ' <select name="region">' . $regions . '</select> <button type="submit">Record test match</button></form>'
        . '<p>Check the result in the game (Ranked Match &gt; Leaderboard / Profile) or on the leaderboard page. '
        . '<b>Delete stattest.php when you are done.</b></p>');
} catch (Throwable $e) {
    error_log('ranked stattest: ' . $e->getMessage());
    shell('<p class="bad">Error: ' . $h($e->getMessage()) . '</p>');
}
