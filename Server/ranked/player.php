<?php
// Players: search by name (player.php?q=), and a player's page (player.php?id= or ?name=): their
// picture, online or last seen, this season's rating and record per mode, the all-time record
// per game, and their latest ranked matches. Only what the leaderboard already shows publicly.
require_once __DIR__ . '/site.php';

$db = db();
settle_due();
$id = (int)($_GET['id'] ?? 0);
if ($id <= 0 && trim((string)($_GET['name'] ?? '')) !== '') {
    $st = $db->prepare('SELECT id FROM players WHERE uname_key = ? OR name = ? ORDER BY last_seen DESC LIMIT 1');
    $n = trim((string)$_GET['name']);
    $st->execute([strtolower($n), $n]);
    $id = (int)$st->fetchColumn();
}
$q = trim((string)($_GET['q'] ?? ''));
$search = "<form method=get action=player.php class=row style='margin-bottom:16px'><input name=q value='" . h($q)
    . "' placeholder='Player name' aria-label='Player name' maxlength=40 style='flex:1;min-width:200px'>"
    . '<button type=submit>Search</button></form>';

if ($id <= 0) {
    // Search, or the most recently active players.
    if ($q !== '') {
        $like = '%' . str_replace(['!', '%', '_'], ['!!', '!%', '!_'], $q) . '%';
        $st = $db->prepare("SELECT * FROM players WHERE banned = 0 AND (name LIKE ? ESCAPE '!' OR username LIKE ? ESCAPE '!')
                            ORDER BY last_seen DESC LIMIT 50");
        $st->execute([$like, $like]);
        $title = 'Players matching "' . $q . '"';
    } else {
        $st = $db->query('SELECT * FROM players WHERE banned = 0 ORDER BY last_seen DESC LIMIT 30');
        $title = 'Recently active';
    }
    $rows = '';
    foreach ($st->fetchAll() as $p) {
        $s = rating_row((int)$p['id'], 'single');
        $rows .= '<tr><td><span class=row style="gap:10px;flex-wrap:nowrap">' . avatar_html($p, 32)
            . player_link((int)$p['id'], (string)$p['name']) . '</span></td>'
            . '<td>' . (is_online($p) ? '<span class="pill on">online</span>' : '<span class="muted small">' . ago((int)$p['last_seen']) . '</span>') . '</td>'
            . "<td class=n>{$s['rating']}</td><td class='n hide-s'>{$s['wins']}-{$s['losses']}</td></tr>";
    }
    $body = '<h1>Players</h1>' . $search . '<h2>' . h($title) . '</h2>'
        . ($rows === '' ? '<div class=box><p class=muted style="margin:0">Nobody by that name.</p></div>'
            : "<table><thead><tr><th>Player</th><th>Seen</th><th class=n>Single</th><th class='n hide-s'>W-L</th></tr></thead><tbody>$rows</tbody></table>");
    site_page('Players', 'player.php', $body);
}

$st = $db->prepare('SELECT * FROM players WHERE id = ?');
$st->execute([$id]);
$p = $st->fetch();
if (!$p) {
    site_page('Players', 'player.php', '<h1>Players</h1>' . $search . '<div class=box><p class=muted style="margin:0">No such player.</p></div>');
}
$name = (string)$p['name'];
$status = (int)$p['banned'] ? '<span class=pill style="color:var(--bad);border-color:var(--bad)">suspended from ranked</span>'
    : (is_online($p) ? '<span class="pill on">online now</span>' : '<span class=pill>last seen ' . h(ago((int)$p['last_seen'])) . '</span>');

// This season, per mode.
$season = season_info()['name'];
$cards = '';
foreach (['bt3' => 'Tenkaichi 3', 'bt2' => 'Tenkaichi 2'] as $game => $gname) {
    $in = implode(',', array_fill(0, count(GAME_MODES[$game]), '?'));
    $c = $db->prepare("SELECT COALESCE(SUM(wins),0) w, COALESCE(SUM(losses),0) l FROM career WHERE player_id = ? AND mode IN ($in)");
    $c->execute(array_merge([$id], GAME_MODES[$game]));
    $life = $c->fetch();
    $cells = '';
    foreach (GAME_MODES[$game] as $mode) {
        $r = rating_row($id, $mode);
        $played = $r['wins'] + $r['losses'];
        $pct = $played ? round(100 * $r['wins'] / $played) . '%' : '-';
        $cells .= '<div class=stat><span class=muted>' . h(mode_label($mode)) . "</span><b>{$r['rating']}</b>"
            . "<span>{$r['wins']} W · {$r['losses']} L · $pct</span></div>";
    }
    $cards .= "<section class=box><h2 style='margin-top:0'>" . h($gname) . "</h2><div class=stats>$cells"
        . "<div class=stat><span class=muted>All-time record</span><b>{$life['w']}-{$life['l']}</b><span>every season</span></div></div></section>";
}

// Latest ranked matches.
$st = $db->prepare("SELECT * FROM matches WHERE (p1 = ? OR p2 = ?) AND state = 'done' ORDER BY finished DESC LIMIT 15");
$st->execute([$id, $id]);
$matches = $st->fetchAll();
$others = [];
foreach ($matches as $m) {
    $others[(int)$m['p1'] === $id ? (int)$m['p2'] : (int)$m['p1']] = '';
}
if ($others) {
    $in = implode(',', array_map('intval', array_keys($others)));
    foreach ($db->query("SELECT id, name FROM players WHERE id IN ($in)")->fetchAll() as $r) {
        $others[(int)$r['id']] = $r['name'];
    }
}
$mrows = '';
foreach ($matches as $m) {
    $me1 = (int)$m['p1'] === $id;
    $opp = $me1 ? (int)$m['p2'] : (int)$m['p1'];
    $won = (int)$m['winner'] === $id;
    $delta = (int)($me1 ? $m['d1'] : $m['d2']);
    $mrows .= '<tr><td>' . ($won ? '<b class=ok>Win</b>' : '<b class=err>Loss</b>') . '</td><td>'
        . player_link($opp, (string)($others[$opp] ?? '?')) . '</td><td class=hide-s>' . h(mode_label((string)$m['mode']))
        . "</td><td class=n>" . sprintf('%+d', $delta) . "</td><td class='small muted'>" . h(ago((int)($m['finished'] ?? $m['created']))) . '</td></tr>';
}
$st = $db->prepare("SELECT COUNT(*) FROM replays WHERE state = 'ready' AND (p1 = ? OR p2 = ?)");
$st->execute([$name, $name]);
$replays = (int)$st->fetchColumn();

$body = $search . '<section class="box row" style="gap:18px">' . avatar_html($p, 96)
    . '<div><h1 style="margin:0 0 6px">' . h($name) . '</h1><div class=row style="gap:8px">' . $status
    . '<span class=pill>joined ' . h(gmdate('M Y', (int)$p['created'])) . '</span>'
    . ($replays ? "<span class=pill>$replays shared replay" . ($replays === 1 ? '' : 's') . '</span>' : '')
    . '</div></div></section>'
    . '<p class=muted style="margin:14px 0 0">Ratings: ' . h($season) . '</p>' . $cards
    . '<h2>Latest ranked matches</h2>'
    . ($mrows === '' ? '<div class=box><p class=muted style="margin:0">No ranked matches yet.</p></div>'
        : "<table><thead><tr><th>Result</th><th>Against</th><th class=hide-s>Mode</th><th class=n>Rating</th><th>When</th></tr></thead><tbody>$mrows</tbody></table>");
$style = '.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}.stat{background:var(--panel2);border:2px solid var(--line);'
    . 'border-radius:10px;padding:10px 12px;display:flex;flex-direction:column}.stat b{font-size:28px;color:var(--gold);line-height:1.2}'
    . '@media (max-width:640px){.stats{grid-template-columns:1fr}}';
site_page($name, 'player.php', $body, $style);
