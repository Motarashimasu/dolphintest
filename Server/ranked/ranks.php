<?php
// The leaderboard as a web page (same data as leaderboard.php). index.php?mode=...&region=...
// (the launcher's "open in browser") comes here too.
require_once __DIR__ . '/site.php';

$modes = ['single' => 'Single Battle (FT2)', 'team' => 'Team Battle', 'all' => 'All-time record',
          'b2single' => 'BT2 Single Battle (FT2)', 'b2team' => 'BT2 Team Battle', 'b2all' => 'BT2 All-time record'];
$region_names = ['global' => 'Global', 'NA' => 'North America', 'SA' => 'South America',
                 'EU' => 'Europe', 'AF' => 'Africa', 'EA' => 'East Asia', 'CN' => 'China',
                 'OC' => 'Oceania'];
$mode = $_GET['mode'] ?? 'single';
$mode = isset($modes[$mode]) ? $mode : 'single';
$region = strtoupper((string)($_GET['region'] ?? 'global'));
$region = $region === 'GLOBAL' || !isset($region_names[$region]) ? 'global' : $region;
try {
    settle_due();
    $rows = $mode === 'b2all' ? leaderboard('all', $region, 100, 'bt2') : leaderboard($mode, $region, 100);
    $season = season_info()['name'];
    $error = '';
} catch (Throwable $e) {
    error_log('ranked ranks: ' . $e->getMessage());
    $rows = [];
    $season = '';
    $error = 'The leaderboard is unavailable right now.';
}

$opts = fn(array $list, string $cur) => implode('', array_map(
    fn($k, $v) => "<option value='" . h($k) . "'" . ($k === $cur ? ' selected' : '') . '>' . h($v) . '</option>',
    array_keys($list), $list));
$rated = !str_ends_with($mode, 'all');
$body = '<h1>Leaderboard</h1>'
    . ($season !== '' && $rated ? '<p style="color:var(--gold);margin:-6px 0 14px">' . h($season) . '</p>' : '')
    . "<form method=get class=row style='margin-bottom:14px'><select name=mode aria-label=Mode>" . $opts($modes, $mode)
    . "</select><select name=region aria-label=Region>" . $opts($region_names, $region)
    . '</select><button type=submit>Show</button></form>';
if ($error) {
    $body .= '<p class=err>' . h($error) . '</p>';
} elseif (!$rows) {
    $body .= '<div class=box><p class=muted style="margin:0">No ranked matches here yet.</p></div>';
} else {
    $trs = '';
    foreach ($rows as $r) {
        $rank = $r['rank'] <= 3 ? "<b style='color:var(--gold)'>{$r['rank']}</b>" : $r['rank'];
        $trs .= "<tr><td class=n style='width:56px'>$rank</td><td><span class=row style='gap:10px;flex-wrap:nowrap'>"
            . avatar_img($r['avatar'] ?? null, (string)$r['name'], 32)
            . player_link((int)$r['id'], (string)$r['name']) . '</span></td>'
            . ($rated ? "<td class=n>{$r['rating']}</td>" : '') . "<td class=n>{$r['wins']}</td><td class=n>{$r['losses']}</td></tr>";
    }
    $body .= '<table><thead><tr><th class=n>#</th><th>Player</th>' . ($rated ? '<th class=n>Rating</th>' : '')
        . "<th class=n>Wins</th><th class=n>Losses</th></tr></thead><tbody>$trs</tbody></table>";
}
site_page('Leaderboard', 'ranks.php', $body);
