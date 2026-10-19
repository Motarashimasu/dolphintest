<?php
// DRAGON NET Ranked admin panel (browser). Sign in with the admin_key from config.php.
//   Players: search, edit this season's rating / wins / losses per mode, ban / unban, remove a
//            profile picture.
//   Matches: recent matches; Void undoes a counted match (ratings and records).
//   Seasons: start a new season (final standings archived, everyone back to 1000 and 0-0; the
//            all-time record keeps counting), and see past seasons' final standings.
//   Replays: the shared replays (replays.php), newest first; Delete removes one.
//   Log: every admin action.
require __DIR__ . '/lib.php';

session_name('sparking_admin');
session_set_cookie_params(['lifetime' => 0, 'path' => dirname($_SERVER['SCRIPT_NAME'] ?? '/') ?: '/',
                           'secure' => !empty($_SERVER['HTTPS']), 'httponly' => true, 'samesite' => 'Strict']);
session_start();
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
header('X-Frame-Options: DENY');

$h = fn($s) => htmlspecialchars((string)$s, ENT_QUOTES);
$self = basename(__FILE__);

function page(string $title, string $body, bool $nav = true): never
{
    global $h, $self;
    $season = '';
    if ($nav) {
        try {
            $s = season_info();
            $season = ' · ' . $h($s['name']);
        } catch (Throwable $e) {
        }
    }
    $links = $nav ? "<nav><a href='$self?p=players'>Players</a><a href='$self?p=matches'>Matches</a>"
        . "<a href='$self?p=seasons'>Seasons</a><a href='$self?p=messages'>Messages</a><a href='$self?p=replays'>Replays</a><a href='$self?p=log'>Log</a>"
        . "<form method=post class=inline><input type=hidden name=csrf value='" . $h($_SESSION['csrf'] ?? '') . "'>"
        . "<button name=a value=logout>Sign out</button></form></nav>" : '';
    $flash = '';
    if (!empty($_SESSION['flash'])) {
        $flash = '<p class="flash">' . $h($_SESSION['flash']) . '</p>';
        unset($_SESSION['flash']);
    }
    echo <<<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ranked admin</title><style>
:root{--bg:#0f2a35;--panel:#163f4f;--line:#2b6577;--edge:#6fc3d6;--gold:#f2b531;--muted:#a9cbd6;--bad:#e8663d;--good:#3fbf6b}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:#fff;font-family:Tahoma,Verdana,sans-serif;font-size:15px}
main{max-width:1100px;margin:0 auto;padding:20px 16px 60px}h1{font-family:Impact,sans-serif;font-weight:normal;color:#ff8a1f;
text-shadow:2px 2px 0 #6b1d0b;margin:6px 0 4px;font-size:36px}h2{color:var(--gold);font-size:19px;margin:22px 0 8px}
.sub{color:var(--muted);margin:0 0 14px}nav{display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin:0 0 16px}
nav a{color:#fff;text-decoration:none;background:var(--panel);border:2px solid var(--line);padding:6px 12px;border-radius:8px}
nav a:hover{border-color:var(--edge)}table{width:100%;border-collapse:collapse;background:var(--panel);border:2px solid var(--line)}
th,td{padding:7px 9px;text-align:left;border-bottom:1px solid var(--line);vertical-align:middle}th{color:var(--gold);font-weight:normal}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}a{color:#7fd0ff}input,select,button,textarea{font:inherit;padding:6px 9px;
border-radius:6px;border:2px solid var(--line);background:#0c2430;color:#fff}input[type=number]{width:90px}
button{background:var(--gold);color:#111;border-color:var(--gold);cursor:pointer}button.bad{background:var(--bad);border-color:var(--bad);color:#fff}
button.plain{background:var(--panel);color:#fff;border-color:var(--line)}form.inline{display:inline;margin:0}.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:8px 0}
.box{background:var(--panel);border:2px solid var(--line);border-radius:10px;padding:14px;margin:10px 0}.flash{background:#1f5a3a;border:2px solid var(--good);padding:8px 12px;border-radius:8px}
.err{color:var(--bad)}.ban{color:var(--bad);font-weight:bold}.muted{color:var(--muted)}code{color:var(--gold)}
</style></head><body><main><h1>Ranked admin</h1><p class="sub">$title$season</p>$links$flash$body</main></body></html>
HTML;
    exit;
}

function back(string $to, string $msg): never
{
    global $self;
    $_SESSION['flash'] = $msg;
    header("Location: $self?$to", true, 303);
    exit;
}

$c = cfg();
$admin_key = (string)($c['admin_key'] ?? '');
if (strlen($admin_key) < 12) {
    page('Not set up', '<div class="box"><p>Add an admin password to <code>config.php</code> (12+ characters):</p>'
        . "<p><code>'admin_key' =&gt; 'a-long-random-password',</code></p></div>", false);
}

// --- Sign in ---------------------------------------------------------------------------------
if (empty($_SESSION['admin'])) {
    $err = '';
    if (($_POST['a'] ?? '') === 'login') {
        if (hash_equals($admin_key, (string)($_POST['key'] ?? ''))) {
            session_regenerate_id(true);
            $_SESSION['admin'] = true;
            $_SESSION['csrf'] = bin2hex(random_bytes(16));
            try {
                admin_log('login', 'signed in from ' . ($_SERVER['REMOTE_ADDR'] ?? '?'));
            } catch (Throwable $e) {
            }
            header("Location: $self", true, 303);
            exit;
        }
        sleep(2);   // slow down guessing
        $err = '<p class="err">Wrong password.</p>';
    }
    page('Sign in', "<div class='box'>$err<form method=post class=row><input type=hidden name=a value=login>"
        . "<input type=password name=key placeholder='admin_key from config.php' autofocus required size=34>"
        . '<button>Sign in</button></form></div>', false);
}

// --- Actions (POST, CSRF-checked) --------------------------------------------------------------
try {
    $db = db();
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        if (!hash_equals($_SESSION['csrf'] ?? '', (string)($_POST['csrf'] ?? ''))) {
            back('p=players', 'Session expired: try again.');
        }
        $pid = (int)($_POST['player'] ?? 0);
        $name_of = function (int $id) use ($db): string {
            $st = $db->prepare('SELECT name FROM players WHERE id = ?');
            $st->execute([$id]);
            return (string)($st->fetchColumn() ?: "#$id");
        };
        switch ($_POST['a'] ?? '') {
            case 'logout':
                $_SESSION = [];
                session_destroy();
                header("Location: $self", true, 303);
                exit;

            case 'stats':
                $mode = valid_mode($_POST['mode'] ?? '');
                $rating = max(0, min(5000, (int)($_POST['rating'] ?? START_RATING)));
                $wins = max(0, (int)($_POST['wins'] ?? 0));
                $losses = max(0, (int)($_POST['losses'] ?? 0));
                $old = rating_row($pid, $mode);
                $db->prepare('UPDATE ratings SET rating = ?, wins = ?, losses = ? WHERE player_id = ? AND mode = ?')
                    ->execute([$rating, $wins, $losses, $pid, $mode]);
                admin_log('edit_stats', sprintf('%s %s: %d %d-%d -> %d %d-%d', $name_of($pid), $mode,
                    $old['rating'], $old['wins'], $old['losses'], $rating, $wins, $losses));
                back("p=player&id=$pid", "Saved {$mode} stats for " . $name_of($pid) . '.');

            case 'ban':
                $reason = trim((string)($_POST['reason'] ?? ''));
                $db->prepare('UPDATE players SET banned = 1, ban_reason = ? WHERE id = ?')->execute([$reason, $pid]);
                $db->prepare('UPDATE lobbies SET closed = 1 WHERE host_id = ? AND closed = 0')->execute([$pid]);
                $db->prepare('DELETE FROM sessions WHERE player_id = ?')->execute([$pid]);
                admin_log('ban', $name_of($pid) . ($reason !== '' ? ": $reason" : ''));
                back("p=player&id=$pid", $name_of($pid) . ' is banned from ranked.');

            case 'unban':
                $db->prepare('UPDATE players SET banned = 0, ban_reason = NULL WHERE id = ?')->execute([$pid]);
                admin_log('unban', $name_of($pid));
                back("p=player&id=$pid", $name_of($pid) . ' can play ranked again.');

            case 'pic_remove':
                @unlink(pic_path($pid));
                $db->prepare('UPDATE players SET pic = 0 WHERE id = ?')->execute([$pid]);
                admin_log('pic_remove', $name_of($pid));
                back("p=player&id=$pid", $name_of($pid) . "'s picture removed.");

            case 'void':
                $m = get_match((int)($_POST['match'] ?? 0));
                if (!$m) {
                    back('p=matches', 'No such match.');
                }
                if ($m['state'] === 'live') {
                    finish_match($m, null, 'admin_void');
                    $ok = true;
                } else {
                    $ok = void_match($m, 'admin_void');
                }
                if ($ok) {
                    admin_log('void_match', sprintf('#%d %s: %s vs %s (%+d / %+d undone)', $m['id'], $m['mode'],
                        $name_of((int)$m['p1']), $name_of((int)$m['p2']), (int)$m['d1'], (int)$m['d2']));
                }
                $to = isset($_POST['return_player']) ? 'p=player&id=' . (int)$_POST['return_player'] : 'p=matches';
                back($to, $ok ? "Match #{$m['id']} voided: its rating changes and records are undone." : "Match #{$m['id']} wasn't counted, nothing to undo.");

            case 'message':
                $text = trim(str_replace("\r\n", "\n", (string)($_POST['text'] ?? '')));
                if ($text === '' || mb_strlen($text) > 500) {
                    back('p=messages', 'A message needs 1 to 500 characters.');
                }
                $days = max(1, min(30, (int)($_POST['days'] ?? 3)));
                $db->prepare('INSERT INTO messages (at, text, expires, active) VALUES (?, ?, ?, 1)')
                    ->execute([now(), $text, now() + $days * 86400]);
                admin_log('message', mb_substr($text, 0, 200));
                back('p=messages', "Sent: every logged-in player sees it once (for $days day" . ($days > 1 ? 's' : '') . ').');

            case 'message_off':
                $mid = (int)($_POST['message'] ?? 0);
                $db->prepare('UPDATE messages SET active = 0 WHERE id = ?')->execute([$mid]);
                admin_log('message_off', "#$mid");
                back('p=messages', "Message #$mid switched off: nobody else gets it.");

            case 'replay_delete':
                $rid = (int)($_POST['replay'] ?? 0);
                $st = $db->prepare('SELECT * FROM replays WHERE id = ?');
                $st->execute([$rid]);
                if ($r = $st->fetch()) {
                    replay_remove($r);
                    admin_log('replay_delete', "#$rid {$r['p1']} vs {$r['p2']}");
                }
                back('p=replays', "Replay #$rid deleted.");

            case 'season':
                if (trim((string)($_POST['confirm'] ?? '')) !== 'RESET') {
                    back('p=seasons', 'Type RESET to confirm a new season.');
                }
                $old = season_info();
                $next = start_new_season(trim((string)($_POST['name'] ?? '')));
                admin_log('new_season', "{$old['name']} archived; season $next started");
                back('p=seasons', "{$old['name']} is archived. Everyone starts season $next at " . START_RATING . ' and 0-0.');
        }
        back('p=players', 'Unknown action.');
    }

    // --- Pages ------------------------------------------------------------------------------------
    settle_due();
    $csrf = "<input type=hidden name=csrf value='" . $h($_SESSION['csrf']) . "'>";
    $p = $_GET['p'] ?? 'players';
    $when = fn($t) => $t ? gmdate('Y-m-d H:i', (int)$t) . ' UTC' : '-';
    $names = [];
    foreach ($db->query('SELECT id, name FROM players')->fetchAll() as $r) {
        $names[(int)$r['id']] = $r['name'];
    }
    $match_rows = function (array $matches, ?int $return_player = null) use ($h, $names, $csrf, $when): string {
        $rows = '';
        foreach ($matches as $m) {
            $p1 = $h($names[(int)$m['p1']] ?? '?');
            $p2 = $h($names[(int)$m['p2']] ?? '?');
            $won = $m['winner'] === null ? '-' : $h($names[(int)$m['winner']] ?? '?');
            $void = '';
            if (in_array($m['state'], ['done', 'live'], true)) {
                $ret = $return_player ? "<input type=hidden name=return_player value=$return_player>" : '';
                $void = "<form method=post class=inline onsubmit=\"return confirm('Void match #{$m['id']} and undo its rating changes?')\">"
                    . "$csrf$ret<input type=hidden name=match value={$m['id']}><button class=bad name=a value=void>Void</button></form>";
            }
            $rows .= "<tr><td>#{$m['id']}</td><td>" . $when($m['created']) . "</td><td>{$h($m['mode'])}</td><td>{$h($m['region'])}</td>"
                . "<td>S" . (int)($m['season'] ?? 1) . "</td><td>$p1 <span class=muted>(" . sprintf('%+d', $m['d1']) . ")</span> vs $p2 <span class=muted>("
                . sprintf('%+d', $m['d2']) . ")</span></td><td>$won</td><td>{$h($m['state'])}<br><span class=muted>{$h($m['reason'])}</span></td><td>$void</td></tr>";
        }
        return '<table><tr><th>Match</th><th>When</th><th>Mode</th><th>Region</th><th>Season</th><th>Players (rating change)</th><th>Winner</th><th>State</th><th></th></tr>'
            . ($rows ?: '<tr><td colspan=9 class=muted>No matches.</td></tr>') . '</table>';
    };

    switch ($p) {
        case 'player':
            $id = (int)($_GET['id'] ?? 0);
            $st = $db->prepare('SELECT * FROM players WHERE id = ?');
            $st->execute([$id]);
            $pl = $st->fetch();
            if (!$pl) {
                back('p=players', 'No such player.');
            }
            $body = '<div class=box><b>' . $h($pl['name']) . '</b> <span class=muted>· player #' . $id . ' · Discord ID '
                . $h($pl['discord_id']) . ' · joined ' . $when($pl['created']) . ' · last seen ' . $when($pl['last_seen']) . '</span>';
            if ((int)$pl['banned']) {
                $body .= '<p class=ban>Banned' . ($pl['ban_reason'] ? ': ' . $h($pl['ban_reason']) : '') . '</p>'
                    . "<form method=post>$csrf<input type=hidden name=player value=$id><button name=a value=unban>Unban</button></form>";
            } else {
                $body .= "<form method=post class=row onsubmit=\"return confirm('Ban this player from ranked?')\">$csrf<input type=hidden name=player value=$id>"
                    . "<input name=reason placeholder='reason (shown to them)' size=40><button class=bad name=a value=ban>Ban from ranked</button></form>";
            }
            if ((int)$pl['pic'] > 0) {
                $body .= "<div class=row><img src='pic.php?id=$id&v=" . (int)$pl['pic'] . "' width=64 height=64 alt=''>"
                    . "<form method=post class=inline>$csrf<input type=hidden name=player value=$id>"
                    . "<button class=bad name=a value=pic_remove>Remove picture</button></form></div>";
            }
            $body .= '</div><h2>This season\'s stats</h2>';
            foreach (MODES as $mode) {
                $r = rating_row($id, $mode);
                $label = mode_label($mode);
                $body .= "<form method=post class='box row'>$csrf<input type=hidden name=player value=$id><input type=hidden name=mode value=$mode>"
                    . "<b style='width:160px'>$label</b> Rating <input type=number name=rating value={$r['rating']} min=0 max=5000>"
                    . " Wins <input type=number name=wins value={$r['wins']} min=0> Losses <input type=number name=losses value={$r['losses']} min=0>"
                    . '<button name=a value=stats>Save</button></form>';
            }
            $st = $db->prepare('SELECT mode, region, wins, losses FROM career WHERE player_id = ? ORDER BY mode, region');
            $st->execute([$id]);
            $career = '';
            foreach ($st->fetchAll() as $r) {
                $career .= "<tr><td>{$h($r['mode'])}</td><td>{$h($r['region'])}</td><td class=n>{$r['wins']}</td><td class=n>{$r['losses']}</td></tr>";
            }
            $body .= '<h2>All-time record (every season)</h2><table><tr><th>Mode</th><th>Region</th><th class=n>Wins</th><th class=n>Losses</th></tr>'
                . ($career ?: '<tr><td colspan=4 class=muted>No matches yet.</td></tr>') . '</table>';
            $st = $db->prepare('SELECT * FROM matches WHERE p1 = ? OR p2 = ? ORDER BY id DESC LIMIT 50');
            $st->execute([$id, $id]);
            $body .= '<h2>Matches</h2>' . $match_rows($st->fetchAll(), $id);
            page($pl['name'], $body);

        case 'matches':
            $state = $_GET['state'] ?? '';
            $sql = 'SELECT * FROM matches' . (in_array($state, ['done', 'void', 'live'], true) ? ' WHERE state = ?' : '') . ' ORDER BY id DESC LIMIT 150';
            $st = $db->prepare($sql);
            $st->execute(in_array($state, ['done', 'void', 'live'], true) ? [$state] : []);
            $filter = "<form method=get class=row><input type=hidden name=p value=matches><select name=state>";
            foreach (['' => 'All', 'done' => 'Counted', 'live' => 'Running', 'void' => 'Void'] as $k => $v) {
                $filter .= "<option value='$k'" . ($k === $state ? ' selected' : '') . ">$v</option>";
            }
            $filter .= '</select><button class=plain>Show</button></form>';
            page('Matches', $filter . $match_rows($st->fetchAll()));

        case 'seasons':
            $s = season_info();
            $body = "<div class=box><p><b>{$h($s['name'])}</b> (season {$s['number']}) since " . $when($s['started']) . '.</p>'
                . "<form method=post class=row onsubmit=\"return confirm('Archive this season and reset everyone to " . START_RATING . " and 0-0?')\">$csrf"
                . "<input name=name placeholder='new season name, e.g. Season " . ($s['number'] + 1) . "' size=30>"
                . "<input name=confirm placeholder='type RESET' size=12><button class=bad name=a value=season>Start new season</button></form>"
                . '<p class=muted>Archives the final standings, then every rating goes back to ' . START_RATING
                . ' and every record to 0-0 (region boards too). The all-time record keeps everything.</p></div>';
            $view = (int)($_GET['view'] ?? 0);
            $rows = '';
            foreach ($db->query('SELECT id, number, name, started, ended FROM seasons ORDER BY number DESC')->fetchAll() as $r) {
                $rows .= "<tr><td>{$r['number']}</td><td>{$h($r['name'])}</td><td>" . $when($r['started']) . '</td><td>' . $when($r['ended'])
                    . "</td><td><a href='?p=seasons&view={$r['id']}'>Final standings</a></td></tr>";
            }
            $body .= '<h2>Past seasons</h2><table><tr><th>#</th><th>Name</th><th>Started</th><th>Ended</th><th></th></tr>'
                . ($rows ?: '<tr><td colspan=5 class=muted>None yet.</td></tr>') . '</table>';
            if ($view) {
                $st = $db->prepare('SELECT * FROM seasons WHERE id = ?');
                $st->execute([$view]);
                if ($ss = $st->fetch()) {
                    $standings = json_decode($ss['standings'], true) ?: [];
                    foreach ($standings as $mode => $list) {
                        $t = '';
                        foreach ($list as $r) {
                            $t .= "<tr><td>{$r['rank']}</td><td>{$h($r['name'])}</td><td class=n>{$r['rating']}</td><td class=n>{$r['wins']}-{$r['losses']}</td></tr>";
                        }
                        $body .= '<h2>' . $h($ss['name']) . ' · ' . mode_label($mode) . '</h2>'
                            . '<table><tr><th>#</th><th>Player</th><th class=n>Rating</th><th class=n>W-L</th></tr>'
                            . ($t ?: '<tr><td colspan=4 class=muted>Nobody played.</td></tr>') . '</table>';
                    }
                }
            }
            page('Seasons', $body);

        case 'messages':
            $rows = '';
            foreach ($db->query('SELECT m.*, (SELECT COUNT(*) FROM message_reads r WHERE r.message_id = m.id) AS seen
                                 FROM messages m ORDER BY m.id DESC LIMIT 100')->fetchAll() as $m) {
                $live = (int)$m['active'] && (int)$m['expires'] > now();
                $off = $live ? "<form method=post class=inline>$csrf<input type=hidden name=message value={$m['id']}>"
                    . "<button class=plain name=a value=message_off>Switch off</button></form>" : '<span class=muted>off</span>';
                $rows .= "<tr><td>#{$m['id']}</td><td>" . $when($m['at']) . '</td><td>' . nl2br($h($m['text']))
                    . "</td><td class=n>{$m['seen']}</td><td>" . $when($m['expires']) . "</td><td>$off</td></tr>";
            }
            $form = "<form method=post class=box>$csrf<p>Pops up once on every logged-in player's launcher (outside games; "
                . 'they close it with a button). Players who log in while it is on get it too.</p>'
                . "<textarea name=text rows=4 cols=70 maxlength=500 placeholder='Your message (500 characters at most)'></textarea>"
                . "<div class=row>Show for <input type=number name=days value=3 min=1 max=30> days <button name=a value=message>Send</button></div></form>";
            page('Messages', $form . '<table><tr><th>#</th><th>Sent</th><th>Text</th><th class=n>Closed by</th><th>Until</th><th></th></tr>'
                . ($rows ?: '<tr><td colspan=6 class=muted>No messages yet.</td></tr>') . '</table>');

        case 'replays':
            $rows = '';
            $total = 0;
            foreach ($db->query("SELECT r.*, p.name AS up FROM replays r LEFT JOIN players p ON p.id = r.uploader
                                 ORDER BY r.id DESC LIMIT 200")->fetchAll() as $r) {
                $mb = ((int)$r['dtm_size'] + (int)$r['sav_size']) / 1048576;
                $total += $mb;
                $del = "<form method=post class=inline>$csrf<input type=hidden name=replay value={$r['id']}>"
                    . "<button class=bad name=a value=replay_delete>Delete</button></form>";
                $rows .= "<tr><td>#{$r['id']}</td><td>" . $h("{$r['p1']} {$r['w1']} - {$r['w2']} {$r['p2']}")
                    . '</td><td>' . $h($r['game_id'] . ' ' . $r['mode']) . '</td><td>' . $h((string)$r['up'])
                    . ($r['state'] === 'ready' ? '' : ' <span class=muted>(uploading)</span>')
                    . '</td><td>' . $when($r['created']) . "</td><td class=n>{$r['downloads']}</td><td class=n>"
                    . sprintf('%.1f', $mb) . " MB</td><td>$del</td></tr>";
            }
            page('Replays', '<p class=muted>' . sprintf('%.0f', $total) . ' MB in the newest 200 (limit: replay_max_mb in config.php, '
                . 'the oldest are deleted first).</p><table><tr><th>#</th><th>Match</th><th>Game</th><th>Shared by</th>'
                . '<th>When</th><th class=n>Downloads</th><th class=n>Size</th><th></th></tr>'
                . ($rows ?: '<tr><td colspan=8 class=muted>No replays yet.</td></tr>') . '</table>');

        case 'log':
            $rows = '';
            foreach ($db->query('SELECT * FROM admin_log ORDER BY id DESC LIMIT 300')->fetchAll() as $r) {
                $rows .= '<tr><td>' . $when($r['at']) . "</td><td>{$h($r['action'])}</td><td>{$h($r['detail'])}</td></tr>";
            }
            page('Admin log', '<table><tr><th>When</th><th>Action</th><th>Detail</th></tr>'
                . ($rows ?: '<tr><td colspan=3 class=muted>Nothing yet.</td></tr>') . '</table>');

        default:
            $q = trim((string)($_GET['q'] ?? ''));
            $sql = 'SELECT * FROM players' . ($q !== '' ? ' WHERE name LIKE ? OR discord_id = ?' : '') . ' ORDER BY last_seen DESC LIMIT 200';
            $st = $db->prepare($sql);
            $st->execute($q !== '' ? ['%' . $q . '%', $q] : []);
            $rows = '';
            foreach ($st->fetchAll() as $pl) {
                $id = (int)$pl['id'];
                $s = rating_row($id, 'single');
                $t = rating_row($id, 'team');
                $c2 = $db->prepare('SELECT COALESCE(SUM(wins),0) w, COALESCE(SUM(losses),0) l FROM career WHERE player_id = ?');
                $c2->execute([$id]);
                $life = $c2->fetch();
                $rows .= "<tr><td>$id</td><td><a href='?p=player&id=$id'>" . $h($pl['name']) . '</a>'
                    . ((int)$pl['banned'] ? ' <span class=ban>BANNED</span>' : '') . "</td>"
                    . "<td class=n>{$s['rating']}</td><td class=n>{$s['wins']}-{$s['losses']}</td>"
                    . "<td class=n>{$t['rating']}</td><td class=n>{$t['wins']}-{$t['losses']}</td>"
                    . "<td class=n>{$life['w']}-{$life['l']}</td><td>" . $when($pl['last_seen']) . '</td></tr>';
            }
            $search = "<form method=get class=row><input type=hidden name=p value=players><input name=q value='" . $h($q)
                . "' placeholder='name or Discord ID' size=30><button class=plain>Search</button></form>";
            page('Players', $search . '<table><tr><th>#</th><th>Player</th><th class=n>Single</th><th class=n>W-L</th>'
                . '<th class=n>Team</th><th class=n>W-L</th><th class=n>All-time</th><th>Last seen</th></tr>'
                . ($rows ?: '<tr><td colspan=8 class=muted>No players yet.</td></tr>') . '</table>');
    }
} catch (Throwable $e) {
    error_log('ranked admin: ' . $e->getMessage());
    page('Error', '<p class=err>' . $h($e->getMessage()) . '</p>');
}
