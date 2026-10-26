<?php
// The website's front page: what the collection is, the three downloads (config.php
// "downloads"), players online, the top of the leaderboard and the board's latest topics.
// index.php?mode=...&region=... (the launcher's leaderboard link) shows the leaderboard.
if (isset($_GET['mode']) || isset($_GET['region'])) {
    require __DIR__ . '/ranks.php';
    exit;
}
require_once __DIR__ . '/site.php';

/** The downloads from config.php, three of them (missing ones: "coming soon"). */
function site_downloads(): array
{
    $list = cfg()['downloads'] ?? [];
    $defaults = [['label' => 'Windows', 'note' => 'Installer for Windows 10 / 11'],
                 ['label' => 'Linux', 'note' => 'For Linux and Steam Deck'],
                 ['label' => 'Portable', 'note' => 'Windows, no install (zip)']];
    $out = [];
    for ($i = 0; $i < 3; $i++) {
        $d = is_array($list[$i] ?? null) ? $list[$i] : [];
        $ready = trim((string)($d['url'] ?? '')) !== '' || trim((string)($d['r2'] ?? '')) !== '';
        $out[] = ['label' => (string)($d['label'] ?? $defaults[$i]['label']),
                  'note' => (string)($d['note'] ?? $defaults[$i]['note']),
                  'version' => (string)($d['version'] ?? ''), 'size' => (string)($d['size'] ?? ''),
                  'ready' => $ready, 'i' => $i];
    }
    return $out;
}

$online = 0;
$top = [];
$topics = [];
$names = [];
try {
    settle_due();
    $db = db();
    $st = $db->prepare('SELECT COUNT(*) FROM players WHERE banned = 0 AND last_seen >= ?');
    $st->execute([now() - ONLINE_WINDOW]);
    $online = (int)$st->fetchColumn();
    $top = leaderboard('single', 'global', 5);
    $topics = $db->query('SELECT * FROM board_topics WHERE deleted = 0 ORDER BY pinned DESC, last_post DESC LIMIT 5')->fetchAll();
    foreach ($topics as $t) {
        $names[(int)$t['last_author']] = '';
    }
    if ($names) {
        $in = implode(',', array_map('intval', array_keys($names)));
        foreach ($db->query("SELECT id, name FROM players WHERE id IN ($in)")->fetchAll() as $r) {
            $names[(int)$r['id']] = $r['name'];
        }
    }
} catch (Throwable $e) {
    error_log('site index: ' . $e->getMessage());
}

$cards = '';
foreach (site_downloads() as $d) {
    $meta = trim(implode(' · ', array_filter([$d['version'] !== '' ? 'Version ' . $d['version'] : '', $d['size']])));
    $cards .= '<div class=dl><h3>' . h($d['label']) . '</h3><p class=muted>' . h($d['note']) . '</p>'
        . ($meta !== '' ? '<p class="small muted" style="margin-top:-6px">' . h($meta) . '</p>' : '')
        . ($d['ready'] ? "<a class='btn big' href='download.php?i={$d['i']}'>Download</a>"
                       : "<span class='btn big off'>Coming soon</span>") . '</div>';
}
$top_rows = '';
foreach ($top as $r) {
    $top_rows .= "<li><span class=rk>{$r['rank']}</span>" . avatar_img($r['avatar'] ?? null, (string)$r['name'], 28)
        . player_link((int)$r['id'], (string)$r['name']) . "<span class='n muted'>{$r['rating']}</span></li>";
}
$topic_rows = '';
foreach ($topics as $t) {
    $topic_rows .= "<li><a href='board.php?t={$t['id']}'>" . ((int)$t['pinned'] ? '📌 ' : '') . h($t['title']) . '</a>'
        . "<span class='small muted'>" . h($names[(int)$t['last_author']] ?? '') . ' · ' . ago((int)$t['last_post']) . '</span></li>';
}

$body = <<<HTML
<section class=hero>
  <p class=kicker><span class='pill on'>$online online now</span></p>
  <h1 class=big>DRAGON BALL<br>Sparking! Collection PC</h1>
  <p class=lead>Budokai Tenkaichi 3 and 2 on PC, ready to play online: ranked matches with a leaderboard, the
  Battle Lounge, replays, friends, HD textures and controller presets. Built on Dolphin, made by and for the community.</p>
</section>
<section class=dls>$cards</section>
<p class="small muted">You need your own copy of the game: the collection builds its game copy from your disc (Sparking! 4.0 from
the PAL disc, the Japanese versions from theirs). No game files are shared here.</p>
<div class=cols>
  <section class=box><h2 style="margin-top:0">Top players</h2>
    <ol class=list>{$top_rows}</ol>
    <p style="margin-bottom:0"><a href="ranks.php">Full leaderboard →</a></p></section>
  <section class=box><h2 style="margin-top:0">On the board</h2>
    <ul class=list>{$topic_rows}</ul>
    <p style="margin-bottom:0"><a href="board.php">Go to the board →</a></p></section>
</div>
<section class="box row" style="justify-content:space-between">
  <div><h3>Need help, or have an idea?</h3><p class=muted style="margin:0">Send it to the team: bugs, account problems, suggestions.</p></div>
  <a class=btn href="support.php">Support & feedback</a>
</section>
HTML;
if ($top_rows === '') {
    $body = str_replace('<ol class=list></ol>', '<p class=muted>No ranked matches yet: be the first.</p>', $body);
}
if ($topic_rows === '') {
    $body = str_replace('<ul class=list></ul>', '<p class=muted>Nothing posted yet.</p>', $body);
}
$style = <<<CSS
.hero{text-align:center;padding:26px 0 8px}.hero h1.big{font-size:58px;margin:10px 0 16px}
.lead{max-width:720px;margin:0 auto;color:#d9eef4;font-size:18px}
.dls{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin:26px 0 10px}
.dl{background:var(--panel);border:3px solid var(--edge);border-radius:14px;padding:18px;text-align:center}
.dl h3{font-size:22px;color:var(--gold)}.dl p{margin:4px 0 14px}
.btn.big{padding:11px 26px;border-radius:10px;font-size:18px}.btn.off{background:var(--panel2);border-color:var(--line);color:var(--muted);cursor:default}
.cols{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:10px}
.list{list-style:none;padding:0;margin:0}.list li{display:flex;gap:10px;align-items:center;padding:7px 0;border-bottom:1px solid var(--line)}
.list li:last-child{border-bottom:none}.list .rk{width:22px;color:var(--gold);font-weight:bold}.list .n{margin-left:auto}
ul.list li{flex-direction:column;align-items:flex-start;gap:0}
@media (max-width:760px){.dls,.cols{grid-template-columns:1fr}.hero h1.big{font-size:40px}}
CSS;
site_page(SITE_NAME, 'index.php', $body, $style);
