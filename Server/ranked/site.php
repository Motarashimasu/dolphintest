<?php
// The website's shared parts (index.php, ranks.php, player.php, board.php, support.php,
// login.php): the page layout, the visitor's login (their DRAGON NET account: username and
// password, as in the launcher) and form protection. No scripts: plain pages that work anywhere.
require_once __DIR__ . '/lib.php';

const SITE_NAME = 'DRAGON BALL Sparking! Collection PC';

session_name('sparking_site');
session_set_cookie_params(['lifetime' => 60 * 60 * 24 * 30, 'path' => dirname($_SERVER['SCRIPT_NAME'] ?? '/') ?: '/',
                           'secure' => !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off',
                           'httponly' => true, 'samesite' => 'Lax']);
session_start();
if (empty($_SESSION['csrf'])) {
    $_SESSION['csrf'] = bin2hex(random_bytes(16));
}
header('Content-Type: text/html; charset=utf-8');
header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: same-origin');
header("Content-Security-Policy: default-src 'self'; img-src 'self' https://cdn.discordapp.com data:; "
       . "style-src 'self' 'unsafe-inline'; script-src 'none'; form-action 'self'; frame-ancestors 'none'");

function h($s): string
{
    return htmlspecialchars((string)$s, ENT_QUOTES);
}

/** The hidden form field every POST form carries. */
function csrf_field(): string
{
    return "<input type=hidden name=csrf value='" . h($_SESSION['csrf']) . "'>";
}

function csrf_ok(): bool
{
    return hash_equals((string)$_SESSION['csrf'], (string)($_POST['csrf'] ?? ''));
}

/** The logged-in visitor's player row (banned ones too: they can read, not post), or null. */
function web_user(): ?array
{
    static $u = false;
    if ($u !== false) {
        return $u;
    }
    $u = null;
    $id = (int)($_SESSION['uid'] ?? 0);
    if ($id > 0) {
        $st = db()->prepare('SELECT * FROM players WHERE id = ?');
        $st->execute([$id]);
        $u = $st->fetch() ?: null;
        // A password reset (admin.php) logs the player out here too.
        if ($u && ($_SESSION['pass'] ?? '') !== substr(hash('sha256', (string)$u['pass_hash']), 0, 16)) {
            $u = null;
            unset($_SESSION['uid'], $_SESSION['pass']);
        }
    }
    return $u;
}

function web_login(array $p): void
{
    session_regenerate_id(true);
    $_SESSION['uid'] = (int)$p['id'];
    $_SESSION['pass'] = substr(hash('sha256', (string)$p['pass_hash']), 0, 16);
}

/** A redirect back to a page of this site (never elsewhere). */
function go(string $to, string $flash = ''): never
{
    if ($flash !== '') {
        $_SESSION['flash'] = $flash;
    }
    if (!preg_match('~^[a-z_]+\.php(\?[A-Za-z0-9_=&%.\-]*)?(#[a-z0-9\-]+)?$~', $to)) {
        $to = 'index.php';
    }
    header("Location: $to", true, 303);
    exit;
}

/** "3 minutes ago", for dates on the pages. */
function ago(int $t): string
{
    $d = max(0, now() - $t);
    if ($d < 60) {
        return 'just now';
    }
    foreach ([[86400 * 365, 'year'], [86400 * 30, 'month'], [86400, 'day'], [3600, 'hour'], [60, 'minute']] as [$s, $w]) {
        if ($d >= $s) {
            $n = intdiv($d, $s);
            return "$n $w" . ($n === 1 ? '' : 's') . ' ago';
        }
    }
    return 'just now';
}

/** A player's name as a link to their page. */
function player_link(int $id, string $name): string
{
    return "<a class=pl href='player.php?id=$id'>" . h($name) . '</a>';
}

/** The picture of a player row (id, pic, discord_id, avatar), or the first letter of the name. */
function avatar_html(array $p, int $size = 40): string
{
    return avatar_img(player_pic($p), (string)($p['name'] ?? '?'), $size);
}

/** A picture URL as a round picture, or the first letter of `name` when there's none. */
function avatar_img(?string $url, string $name, int $size = 40): string
{
    if ($url) {
        return "<img class=av src='" . h($url) . "' width=$size height=$size alt=''>";
    }
    $letter = strtoupper(mb_substr($name !== '' ? $name : '?', 0, 1));
    return "<span class=av style='width:{$size}px;height:{$size}px;line-height:{$size}px'>" . h($letter) . '</span>';
}

/** The whole page: header with the menu and the login, `$body`, footer. */
function site_page(string $title, string $active, string $body, string $wide = ''): never
{
    $nav = '';
    foreach (['index.php' => 'Home', 'ranks.php' => 'Leaderboard', 'player.php' => 'Players',
              'board.php' => 'Board', 'support.php' => 'Support'] as $href => $label) {
        $nav .= "<a href='$href'" . ($active === $href ? ' class=on' : '') . ">$label</a>";
    }
    $u = null;
    try {
        $u = web_user();
    } catch (Throwable $e) {
    }
    $me = $u ? '<form method=post action=login.php class=me>' . csrf_field() . player_link((int)$u['id'], (string)$u['name'])
            . '<button name=a value=logout class=link>Log out</button></form>'
        : "<a class=me href='login.php?next=" . rawurlencode(basename($_SERVER['SCRIPT_NAME'] ?? 'index.php')) . "'>Log in</a>";
    $flash = '';
    if (!empty($_SESSION['flash'])) {
        $flash = '<p class=flash>' . h($_SESSION['flash']) . '</p>';
        unset($_SESSION['flash']);
    }
    $title_tag = h($title === SITE_NAME ? $title : "$title · DRAGON NET");
    echo <<<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title_tag</title><style>
:root{--bg:#0d2530;--panel:#143b4a;--panel2:#10303d;--line:#2b6577;--edge:#6fc3d6;--gold:#f2b531;--orange:#ff8a1f;
--text:#fff;--muted:#a9cbd6;--bad:#e8663d;--good:#3fbf6b;--blue:#3fa9f5}
*{box-sizing:border-box}html{background:var(--bg)}body{margin:0;color:var(--text);font:16px/1.5 Tahoma,Verdana,sans-serif;
background:radial-gradient(ellipse at 50% -10%,#1d5a6e 0%,var(--bg) 60%) no-repeat}
a{color:#7fd0ff}a:hover{color:#b8e6ff}
header{border-bottom:3px solid var(--edge);background:rgba(8,26,34,.85)}
.bar{max-width:1080px;margin:0 auto;padding:10px 16px;display:flex;gap:14px;align-items:center;flex-wrap:wrap}
.logo{font-family:Impact,Haettenschweiler,'Arial Narrow Bold',sans-serif;font-size:24px;letter-spacing:.5px;color:var(--orange);
text-shadow:2px 2px 0 #6b1d0b;text-decoration:none;margin-right:auto}
nav{display:flex;gap:4px;flex-wrap:wrap}nav a{color:#fff;text-decoration:none;padding:6px 12px;border-radius:8px;border:2px solid transparent}
nav a:hover{border-color:var(--line)}nav a.on{background:var(--panel);border-color:var(--edge)}
.me{display:flex;gap:8px;align-items:center;margin:0}a.me{color:#111;background:var(--gold);padding:6px 14px;border-radius:8px;text-decoration:none;font-weight:bold}
main{max-width:1080px;margin:0 auto;padding:22px 16px 60px}$wide
h1{font-family:Impact,Haettenschweiler,'Arial Narrow Bold',sans-serif;font-weight:normal;letter-spacing:1px;color:var(--orange);
text-shadow:3px 3px 0 #6b1d0b;font-size:40px;line-height:1.1;margin:6px 0 14px}
h2{color:var(--gold);font-size:20px;margin:26px 0 10px}h3{margin:0 0 6px;font-size:18px}
.box{background:var(--panel);border:3px solid var(--line);border-radius:12px;padding:16px;margin:12px 0}
.muted{color:var(--muted)}.small{font-size:14px}.err{color:var(--bad)}.ok{color:var(--good)}
.flash{background:#1f5a3a;border:2px solid var(--good);padding:10px 14px;border-radius:10px}
table{width:100%;border-collapse:collapse;background:var(--panel);border:3px solid var(--line);border-radius:12px;overflow:hidden}
th,td{padding:9px 12px;text-align:left;vertical-align:middle}th{color:var(--gold);font-weight:normal;border-bottom:2px solid var(--line)}
tr:nth-child(even) td{background:rgba(0,0,0,.14)}td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}
input,select,textarea,button{font:inherit;padding:8px 11px;border-radius:8px;border:2px solid var(--line);background:#0b222c;color:#fff;max-width:100%}
textarea{width:100%;min-height:140px;resize:vertical}input:focus,select:focus,textarea:focus{outline:none;border-color:var(--edge)}
button,.btn{background:var(--gold);color:#141414;border-color:var(--gold);cursor:pointer;font-weight:bold;text-decoration:none;display:inline-block}
.btn{padding:8px 14px;border-radius:8px;border:2px solid var(--gold);white-space:nowrap}
button.plain{background:var(--panel);color:#fff;border-color:var(--line);font-weight:normal}
button.link{background:none;border:none;color:var(--muted);padding:0;font-weight:normal;text-decoration:underline}
button.bad{background:var(--bad);border-color:var(--bad);color:#fff}
form.row,.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}label{display:block;margin:12px 0 4px;color:var(--muted)}
.av{border-radius:50%;object-fit:cover;flex:none;display:inline-block;background:var(--line);color:#fff;text-align:center;font-weight:bold;vertical-align:middle}
a.pl{color:#fff;text-decoration:none;font-weight:bold}a.pl:hover{color:var(--gold)}
.pill{display:inline-block;padding:1px 9px;border-radius:99px;font-size:13px;border:2px solid var(--line);color:var(--muted)}
.pill.on{color:#111;background:var(--good);border-color:var(--good)}.pill.gold{color:#111;background:var(--gold);border-color:var(--gold)}
.pages{display:flex;gap:6px;margin:14px 0;flex-wrap:wrap}.pages a,.pages span{padding:4px 11px;border-radius:8px;border:2px solid var(--line);text-decoration:none;color:#fff}
.pages span{border-color:var(--edge);background:var(--panel)}
footer{max-width:1080px;margin:0 auto;padding:0 16px 40px;color:var(--muted);font-size:13px}
@media (max-width:640px){h1{font-size:32px}th,td{padding:7px 8px}.hide-s{display:none}}
</style></head><body><header><div class=bar><a class=logo href="index.php">DRAGON NET</a><nav>$nav</nav>$me</div></header>
<main>$flash$body</main>
<footer>DRAGON BALL Sparking! Collection PC is a fan project, not affiliated with Bandai Namco, Spike Chunsoft or
Toei Animation. Play with your own copy of the game. DRAGON BALL and Budokai Tenkaichi belong to their owners.</footer>
</body></html>
HTML;
    exit;
}

/** Page links for a list: `$base` + "page=N". */
function pager(string $base, int $page, int $pages): string
{
    if ($pages <= 1) {
        return '';
    }
    $out = '<div class=pages>';
    for ($i = 1; $i <= $pages; $i++) {
        if ($pages > 9 && $i > 2 && $i < $pages - 1 && abs($i - $page) > 2) {
            if ($i === 3 || $i === $pages - 2) {
                $out .= '<span class=muted style="border:none;background:none">…</span>';
            }
            continue;
        }
        $out .= $i === $page ? "<span>$i</span>" : "<a href='" . h($base . (str_contains($base, '?') ? '&' : '?') . "page=$i") . "'>$i</a>";
    }
    return $out . '</div>';
}

/** Text someone typed, safe for the page, with its line breaks and links. */
function format_text(string $t): string
{
    $t = h($t);
    $t = preg_replace('~\bhttps?://[^\s<>"\']{3,200}~', '<a href="$0" rel="nofollow noopener" target="_blank">$0</a>', $t);
    return nl2br($t, false);
}
