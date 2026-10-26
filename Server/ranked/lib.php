<?php
// DRAGON NET Ranked server: shared code. Every endpoint includes this file.
//
// Players have a DRAGON NET account: a username + password made in the launcher (account.php).
// Profiles from before accounts were made with a Discord login: their owner logs in with Discord
// once more and sets a username + password (keeping the ratings); Discord makes no new
// profiles. Accounts also have friends (social.php: requests, who's online) and get the
// admin's messages (admin.php > Messages). Ranked lobbies are
// listed here (not on Dolphin's lobby server): a host opens one, a guest joins it, the host
// starts a match, and both players' launchers report the result. A match counts when both
// reports agree; a lone report counts after a grace period (the other player left / crashed);
// reports that disagree void the match. Leaving a running match counts as a loss.
// Ratings: Elo, separate for Single Battle and Team Battle, starting at 1000. Each game has its
// own ladder: Budokai Tenkaichi 3's modes are single / team, Budokai Tenkaichi 2's b2single /
// b2team. A lobby also records the disc version it plays (RDSPAF...): only the same version can
// join it, while ratings are shared by a game's versions.
// Seasons: ratings, records and region records belong to the current season (admin.php starts
// a new one: final standings are archived, everyone goes back to 1000 and 0-0). The career table
// (the all-time record) never resets. Banned players can't play ranked and aren't listed.
declare(strict_types=1);

const SCHEMA_VERSION = '7';
const MODES = ['single', 'team', 'b2single', 'b2team'];
const GAME_MODES = ['bt3' => ['single', 'team'], 'bt2' => ['b2single', 'b2team']];
const MODE_LABELS = ['single' => 'Single Battle FT2', 'team' => 'Team Battle',
                     'b2single' => 'BT2 Single Battle FT2', 'b2team' => 'BT2 Team Battle'];
const REGIONS = ['EA', 'CN', 'EU', 'NA', 'SA', 'OC', 'AF'];
const START_RATING = 1000;
const ELO_K = 32;
const LOBBY_TIMEOUT = 60;     // s without a host heartbeat: the lobby is gone
const GUEST_TIMEOUT = 45;     // s without a guest status call: the seat is free again
const LOGIN_TIMEOUT = 600;    // s to finish the Discord login
const MATCH_TIMEOUT = 7200;   // s: a match nobody reported is void
const ONLINE_WINDOW = 75;     // s since the last request: still online (the launcher polls every ~20 s)
const LOGIN_FAILS = 8;        // wrong passwords for one username before a pause
const LOGIN_PAUSE = 300;      // s: that pause
const FRIENDS_MAX = 200;
const PIC_SIZE = 128;          // profile pictures: PIC_SIZE x PIC_SIZE (the launcher crops to it)
const PIC_MAX_BYTES = 262144;

function cfg(): array
{
    static $c = null;
    if ($c === null) {
        $file = getenv('SPARKING_RANKED_CONFIG') ?: __DIR__ . '/config.php';
        $c = require $file;
    }
    return $c;
}

function now(): int
{
    return time() + (int)(cfg()['time_offset'] ?? 0);  // tests move the clock forward
}

function db(): PDO
{
    static $db = null;
    if ($db) {
        return $db;
    }
    $c = cfg();
    $dsn = $c['db_dsn'] ?? "mysql:host={$c['db_host']};dbname={$c['db_name']};charset=utf8mb4";
    $db = new PDO($dsn, $c['db_user'] ?? null, $c['db_pass'] ?? null, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
    if (is_sqlite($db)) {
        $db->exec('PRAGMA busy_timeout = 5000');
    }
    migrate($db);
    return $db;
}

function is_sqlite(PDO $db): bool
{
    return $db->getAttribute(PDO::ATTR_DRIVER_NAME) === 'sqlite';
}

function migrate(PDO $db): void
{
    try {
        $v = $db->query("SELECT v FROM meta WHERE k = 'schema'")->fetchColumn();
        if ($v === SCHEMA_VERSION) {
            return;
        }
    } catch (Throwable $e) {
        // first run: no tables yet
    }
    $lite = is_sqlite($db);
    $id = $lite ? 'INTEGER PRIMARY KEY AUTOINCREMENT' : 'INTEGER PRIMARY KEY AUTO_INCREMENT';
    $tail = $lite ? '' : ' ENGINE=InnoDB DEFAULT CHARSET=utf8mb4';
    $tables = [
        "meta (k VARCHAR(32) PRIMARY KEY, v VARCHAR(64))",
        "players (id $id, discord_id VARCHAR(32) NOT NULL UNIQUE, name VARCHAR(64) NOT NULL,
            avatar VARCHAR(64), created INTEGER NOT NULL, last_seen INTEGER NOT NULL)",
        "sessions (token_hash CHAR(64) PRIMARY KEY, player_id INTEGER NOT NULL,
            created INTEGER NOT NULL, last_used INTEGER NOT NULL)",
        "logins (id CHAR(32) PRIMARY KEY, poll_hash CHAR(64) NOT NULL, created INTEGER NOT NULL,
            player_id INTEGER NULL, error VARCHAR(255) NULL)",
        "ratings (player_id INTEGER NOT NULL, mode VARCHAR(8) NOT NULL, rating INTEGER NOT NULL,
            wins INTEGER NOT NULL DEFAULT 0, losses INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (player_id, mode))",
        "region_records (player_id INTEGER NOT NULL, mode VARCHAR(8) NOT NULL,
            region VARCHAR(4) NOT NULL, wins INTEGER NOT NULL DEFAULT 0,
            losses INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (player_id, mode, region))",
        "lobbies (id $id, host_id INTEGER NOT NULL, guest_id INTEGER NULL,
            mode VARCHAR(8) NOT NULL, region VARCHAR(4) NOT NULL, join_target VARCHAR(128) NOT NULL,
            link VARCHAR(16) NOT NULL, created INTEGER NOT NULL, heartbeat INTEGER NOT NULL,
            guest_seen INTEGER NOT NULL DEFAULT 0, closed INTEGER NOT NULL DEFAULT 0,
            match_id INTEGER NULL, last_match INTEGER NULL)",
        "career (player_id INTEGER NOT NULL, mode VARCHAR(8) NOT NULL,
            region VARCHAR(4) NOT NULL, wins INTEGER NOT NULL DEFAULT 0,
            losses INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (player_id, mode, region))",
        "seasons (id $id, number INTEGER NOT NULL, name VARCHAR(64) NOT NULL,
            started INTEGER NOT NULL, ended INTEGER NOT NULL, standings TEXT NOT NULL)",
        "admin_log (id $id, at INTEGER NOT NULL, action VARCHAR(32) NOT NULL,
            detail VARCHAR(255) NOT NULL)",
        // Version 4: friends (a < b; requester = who asked; state pending | friends), admin
        // messages and who has closed each, login failures per username.
        "friends (a INTEGER NOT NULL, b INTEGER NOT NULL, requester INTEGER NOT NULL,
            state VARCHAR(8) NOT NULL, created INTEGER NOT NULL, PRIMARY KEY (a, b))",
        "messages (id $id, at INTEGER NOT NULL, text TEXT NOT NULL, expires INTEGER NOT NULL,
            active INTEGER NOT NULL DEFAULT 1)",
        "message_reads (message_id INTEGER NOT NULL, player_id INTEGER NOT NULL,
            PRIMARY KEY (message_id, player_id))",
        "login_fails (k VARCHAR(64) PRIMARY KEY, n INTEGER NOT NULL, until INTEGER NOT NULL)",
        // Version 5: shared replays (replays.php). Files in replay_dir: <id>.dtm, <id>.sav.
        "replays (id $id, uploader INTEGER NOT NULL, state VARCHAR(8) NOT NULL,
            game VARCHAR(4) NOT NULL, game_id VARCHAR(8) NOT NULL, mode VARCHAR(8) NOT NULL, p1 VARCHAR(64) NOT NULL,
            p2 VARCHAR(64) NOT NULL, w1 INTEGER NOT NULL, w2 INTEGER NOT NULL,
            winner VARCHAR(64) NOT NULL, seconds INTEGER NOT NULL, played VARCHAR(32) NOT NULL,
            meta TEXT NOT NULL, dtm_size INTEGER NOT NULL, sav_size INTEGER NOT NULL,
            dtm_sha CHAR(40) NOT NULL, sav_sha CHAR(40) NOT NULL, match_id INTEGER NULL,
            created INTEGER NOT NULL, downloads INTEGER NOT NULL DEFAULT 0)",
        // Version 7: the website (site.php): message board, support messages, rate limits.
        "board_topics (id $id, title VARCHAR(120) NOT NULL, author INTEGER NOT NULL,
            created INTEGER NOT NULL, last_post INTEGER NOT NULL, last_author INTEGER NOT NULL,
            replies INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0,
            locked INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0)",
        "board_posts (id $id, topic_id INTEGER NOT NULL, author INTEGER NOT NULL, body TEXT NOT NULL,
            created INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0)",
        "support (id $id, created INTEGER NOT NULL, player_id INTEGER NULL, name VARCHAR(64) NOT NULL,
            contact VARCHAR(128) NOT NULL, topic VARCHAR(16) NOT NULL, body TEXT NOT NULL,
            state VARCHAR(8) NOT NULL, reply TEXT NULL, replied INTEGER NULL, ip_hash CHAR(64) NOT NULL)",
        "web_rate (k VARCHAR(80) PRIMARY KEY, n INTEGER NOT NULL, until INTEGER NOT NULL)",
        "matches (id $id, lobby_id INTEGER NOT NULL, mode VARCHAR(8) NOT NULL,
            region VARCHAR(4) NOT NULL, p1 INTEGER NOT NULL, p2 INTEGER NOT NULL,
            state VARCHAR(8) NOT NULL, r1 VARCHAR(8) NULL, r2 VARCHAR(8) NULL,
            r1_at INTEGER NULL, r2_at INTEGER NULL, winner INTEGER NULL,
            d1 INTEGER NOT NULL DEFAULT 0, d2 INTEGER NOT NULL DEFAULT 0,
            created INTEGER NOT NULL, finished INTEGER NULL, reason VARCHAR(32) NULL)",
    ];
    foreach ($tables as $t) {
        $db->exec("CREATE TABLE IF NOT EXISTS $t$tail");
    }
    // Version 2 columns (bans, seasons). Already there on a fresh install from these tables'
    // older versions? ALTER fails harmlessly then.
    foreach (['players ADD COLUMN banned INTEGER NOT NULL DEFAULT 0',
              'players ADD COLUMN ban_reason VARCHAR(255) NULL',
              'matches ADD COLUMN season INTEGER NOT NULL DEFAULT 1',
              // Version 3: the disc version a lobby plays ('' = before versions: BT3 PAL).
              "lobbies ADD COLUMN version VARCHAR(8) NOT NULL DEFAULT ''",
              // Version 4: accounts (uname_key = the username in lowercase, unique).
              'players ADD COLUMN username VARCHAR(24) NULL',
              'players ADD COLUMN uname_key VARCHAR(24) NULL',
              'players ADD COLUMN pass_hash VARCHAR(255) NULL',
              // Version 5: when a player last came online (friends' "is online" pop-ups).
              'players ADD COLUMN online_since INTEGER NOT NULL DEFAULT 0',
              // Version 6: profile pictures (account.php > picture). 0 = none, else its version.
              'players ADD COLUMN pic INTEGER NOT NULL DEFAULT 0'] as $alter) {
        try {
            $db->exec("ALTER TABLE $alter");
        } catch (Throwable $e) {
            // column exists
        }
    }
    try {
        $db->exec('CREATE UNIQUE INDEX players_uname ON players (uname_key)');
    } catch (Throwable $e) {
        // index exists
    }
    // The all-time record starts from everything played so far.
    if (!(int)$db->query('SELECT COUNT(*) FROM career')->fetchColumn()) {
        $db->exec('INSERT INTO career (player_id, mode, region, wins, losses)
                   SELECT player_id, mode, region, wins, losses FROM region_records');
    }
    if ($db->query("SELECT v FROM meta WHERE k = 'season'")->fetchColumn() === false) {
        $db->prepare('INSERT INTO meta (k, v) VALUES (?, ?)')->execute(['season', '1']);
        $db->prepare('INSERT INTO meta (k, v) VALUES (?, ?)')->execute(['season_name', 'Season 1']);
        $db->prepare('INSERT INTO meta (k, v) VALUES (?, ?)')->execute(['season_started', (string)now()]);
    }
    $db->prepare('DELETE FROM meta WHERE k = ?')->execute(['schema']);
    $db->prepare('INSERT INTO meta (k, v) VALUES (?, ?)')->execute(['schema', SCHEMA_VERSION]);
}

// --- Requests / responses -----------------------------------------------------------------

function input(): array
{
    static $in = null;
    if ($in === null) {
        $body = json_decode(file_get_contents('php://input') ?: '', true);
        $in = array_merge($_GET, $_POST, is_array($body) ? $body : []);
    }
    return $in;
}

function arg(string $key, ?string $default = null): ?string
{
    $v = input()[$key] ?? $default;
    return $v === null ? null : (is_scalar($v) ? (string)$v : null);
}

function out(array $data, int $http = 200): never
{
    http_response_code($http);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function fail(string $code, int $http = 400, array $extra = []): never
{
    out(['ok' => false, 'error' => $code] + $extra, $http);
}

function guard(callable $fn): void
{
    try {
        $fn();
    } catch (PDOException $e) {
        error_log('ranked: ' . $e->getMessage());
        fail('database_error', 500);
    }
}

// --- Players / sessions ---------------------------------------------------------------------

function token_hash(string $token): string
{
    return hash('sha256', $token);
}

/** The logged-in player (X-Sparking-Token header, or "token" in the body), or a 401. */
/** The logged-in player, or a 401. Banned players get a 403 unless $allow_banned. */
function auth(bool $allow_banned = false): array
{
    $token = $_SERVER['HTTP_X_SPARKING_TOKEN'] ?? arg('token') ?? '';
    if (strlen($token) < 32) {
        fail('login_required', 401);
    }
    $st = db()->prepare('SELECT p.* FROM sessions s JOIN players p ON p.id = s.player_id
                         WHERE s.token_hash = ?');
    $st->execute([token_hash($token)]);
    $p = $st->fetch();
    if (!$p) {
        fail('login_required', 401);
    }
    $t = now();
    db()->prepare('UPDATE sessions SET last_used = ? WHERE token_hash = ?')->execute([$t, token_hash($token)]);
    // Offline until now (or never seen): online from now on.
    if (!is_online($p) || !(int)($p['online_since'] ?? 0)) {
        db()->prepare('UPDATE players SET online_since = ? WHERE id = ?')->execute([$t, $p['id']]);
        $p['online_since'] = $t;
    }
    db()->prepare('UPDATE players SET last_seen = ? WHERE id = ?')->execute([$t, $p['id']]);
    $p['last_seen'] = $t;
    if ((int)($p['banned'] ?? 0) && !$allow_banned) {
        fail('banned', 403, ['reason' => (string)($p['ban_reason'] ?? '')]);
    }
    return $p;
}

/** A username: 3-20 letters, digits, _ . - (spaces not allowed, so names are easy to type). */
function valid_username(?string $name): string
{
    $name = trim((string)$name);
    if (!preg_match('/^[A-Za-z0-9_.\-]{3,20}$/', $name)) {
        fail('bad_username');
    }
    return $name;
}

function valid_password(?string $pass): string
{
    $pass = (string)$pass;
    if (strlen($pass) < 6 || strlen($pass) > 128) {
        fail('bad_password');
    }
    return $pass;
}

function find_by_username(string $name): ?array
{
    $st = db()->prepare('SELECT * FROM players WHERE uname_key = ?');
    $st->execute([strtolower($name)]);
    $p = $st->fetch();
    return $p ?: null;
}

function is_online(array $p): bool
{
    return now() - (int)$p['last_seen'] <= ONLINE_WINDOW;
}

function new_session(int $player_id): string
{
    $token = bin2hex(random_bytes(32));
    db()->prepare('INSERT INTO sessions (token_hash, player_id, created, last_used) VALUES (?, ?, ?, ?)')
        ->execute([token_hash($token), $player_id, now(), now()]);
    return $token;
}

function rating_row(int $player_id, string $mode): array
{
    $st = db()->prepare('SELECT rating, wins, losses FROM ratings WHERE player_id = ? AND mode = ?');
    $st->execute([$player_id, $mode]);
    $r = $st->fetch();
    if (!$r) {
        db()->prepare('INSERT INTO ratings (player_id, mode, rating, wins, losses) VALUES (?, ?, ?, 0, 0)')
            ->execute([$player_id, $mode, START_RATING]);
        $r = ['rating' => START_RATING, 'wins' => 0, 'losses' => 0];
    }
    return array_map('intval', $r);
}

function player_brief(?int $id, string $mode): ?array
{
    if (!$id) {
        return null;
    }
    $st = db()->prepare('SELECT id, name, avatar FROM players WHERE id = ?');
    $st->execute([$id]);
    $p = $st->fetch();
    if (!$p) {
        return null;
    }
    $r = rating_row($id, $mode);
    return ['id' => (int)$p['id'], 'name' => $p['name'], 'rating' => $r['rating'],
            'wins' => $r['wins'], 'losses' => $r['losses']];
}

function valid_mode(?string $mode): string
{
    if (!in_array($mode, MODES, true)) {
        fail('bad_mode');
    }
    return $mode;
}

/** A disc ID (6 letters / digits), or '' when not given. */
function valid_version(?string $version): string
{
    $version = strtoupper(trim((string)$version));
    if ($version !== '' && !preg_match('/^[A-Z0-9]{6}$/', $version)) {
        fail('bad_version');
    }
    return $version;
}

/** The game a request is about: bt3 (also when not given: older launchers) or bt2. */
function valid_game(?string $game): string
{
    return isset(GAME_MODES[$game ?? '']) ? $game : 'bt3';
}

function mode_label(string $mode): string
{
    return MODE_LABELS[$mode] ?? $mode;
}

function valid_region(?string $region): string
{
    $region = strtoupper((string)$region);
    if (!in_array($region, REGIONS, true)) {
        fail('bad_region');
    }
    return $region;
}

// --- Matches ------------------------------------------------------------------------------

/** New ratings after a ranked match: [winner's change, loser's change]. */
function elo_changes(int $winner_rating, int $loser_rating): array
{
    $expected = 1 / (1 + 10 ** (($loser_rating - $winner_rating) / 400));
    $d = (int)round(ELO_K * (1 - $expected));
    $d = max(1, $d);
    return [$d, -$d];
}

/** +1 (or -1) win or loss in region_records / career, creating the row when needed. */
function bump_record(string $table, int $player_id, string $mode, string $region, string $col, int $by): void
{
    $db = db();
    $st = $db->prepare("SELECT 1 FROM $table WHERE player_id = ? AND mode = ? AND region = ?");
    $st->execute([$player_id, $mode, $region]);
    if (!$st->fetchColumn()) {
        $db->prepare("INSERT INTO $table (player_id, mode, region, wins, losses) VALUES (?, ?, ?, 0, 0)")
            ->execute([$player_id, $mode, $region]);
    }
    $db->prepare("UPDATE $table SET $col = CASE WHEN $col + ? < 0 THEN 0 ELSE $col + ? END
                  WHERE player_id = ? AND mode = ? AND region = ?")
        ->execute([$by, $by, $player_id, $mode, $region]);
}

function add_record(int $player_id, string $mode, string $region, bool $won, int $delta): void
{
    rating_row($player_id, $mode);
    $col = $won ? 'wins' : 'losses';
    db()->prepare("UPDATE ratings SET rating = rating + ?, $col = $col + 1 WHERE player_id = ? AND mode = ?")
        ->execute([$delta, $player_id, $mode]);
    bump_record('region_records', $player_id, $mode, $region, $col, 1);
    bump_record('career', $player_id, $mode, $region, $col, 1);
}

// --- Seasons / admin --------------------------------------------------------------------------

function meta_get(string $k, string $default = ''): string
{
    $st = db()->prepare('SELECT v FROM meta WHERE k = ?');
    $st->execute([$k]);
    $v = $st->fetchColumn();
    return $v === false ? $default : (string)$v;
}

function meta_set(string $k, string $v): void
{
    db()->prepare('DELETE FROM meta WHERE k = ?')->execute([$k]);
    db()->prepare('INSERT INTO meta (k, v) VALUES (?, ?)')->execute([$k, $v]);
}

function current_season(): int
{
    return (int)meta_get('season', '1');
}

function season_info(): array
{
    return ['number' => current_season(), 'name' => meta_get('season_name', 'Season 1'),
            'started' => (int)meta_get('season_started', '0')];
}

function admin_log(string $action, string $detail): void
{
    db()->prepare('INSERT INTO admin_log (at, action, detail) VALUES (?, ?, ?)')
        ->execute([now(), substr($action, 0, 32), mb_substr($detail, 0, 255)]);
}

/** Undoes a counted match: its rating changes and records (this season's only if it was played
 *  this season; the all-time record always). The match becomes void. */
function void_match(array $m, string $reason): bool
{
    $db = db();
    $db->beginTransaction();
    try {
        $claim = $db->prepare("UPDATE matches SET state = 'void', reason = ? WHERE id = ? AND state = 'done'");
        $claim->execute([$reason, $m['id']]);
        if ($claim->rowCount() !== 1) {
            $db->rollBack();
            return false;
        }
        $same_season = (int)($m['season'] ?? 1) === current_season();
        foreach ([[(int)$m['p1'], (int)$m['d1']], [(int)$m['p2'], (int)$m['d2']]] as [$pid, $delta]) {
            $col = (int)$m['winner'] === $pid ? 'wins' : 'losses';
            if ($same_season) {
                rating_row($pid, $m['mode']);
                $db->prepare("UPDATE ratings SET rating = rating - ?,
                              $col = CASE WHEN $col > 0 THEN $col - 1 ELSE 0 END
                              WHERE player_id = ? AND mode = ?")->execute([$delta, $pid, $m['mode']]);
                bump_record('region_records', $pid, $m['mode'], $m['region'], $col, -1);
            }
            bump_record('career', $pid, $m['mode'], $m['region'], $col, -1);
        }
        $db->commit();
        return true;
    } catch (Throwable $e) {
        $db->rollBack();
        throw $e;
    }
}

/** Archives the season's final standings, then everyone back to 1000 and 0-0. */
function start_new_season(string $new_name): int
{
    $db = db();
    // Matches still running don't belong to either season.
    foreach ($db->query("SELECT * FROM matches WHERE state = 'live'")->fetchAll() as $m) {
        finish_match($m, null, 'season_reset');
    }
    $old = season_info();
    $standings = [];
    foreach (MODES as $mode) {
        $standings[$mode] = leaderboard($mode, 'global', 200);
    }
    $db->beginTransaction();
    try {
        $db->prepare('INSERT INTO seasons (number, name, started, ended, standings) VALUES (?, ?, ?, ?, ?)')
            ->execute([$old['number'], $old['name'], $old['started'], now(),
                       json_encode($standings, JSON_UNESCAPED_UNICODE)]);
        $db->prepare('UPDATE ratings SET rating = ?, wins = 0, losses = 0')->execute([START_RATING]);
        $db->exec('DELETE FROM region_records');
        $next = $old['number'] + 1;
        meta_set('season', (string)$next);
        meta_set('season_name', $new_name !== '' ? mb_substr($new_name, 0, 64) : "Season $next");
        meta_set('season_started', (string)now());
        $db->commit();
        return $next;
    } catch (Throwable $e) {
        $db->rollBack();
        throw $e;
    }
}

/** Ends a live match: $winner = player id, or null to void it. Safe to call twice. */
function finish_match(array $m, ?int $winner, string $reason): void
{
    $db = db();
    $db->beginTransaction();
    try {
        $claim = $db->prepare("UPDATE matches SET state = ?, finished = ?, reason = ?, winner = ?
                               WHERE id = ? AND state = 'live'");
        $claim->execute([$winner ? 'done' : 'void', now(), $reason, $winner, $m['id']]);
        if ($claim->rowCount() === 1 && $winner) {
            $p1 = (int)$m['p1'];
            $p2 = (int)$m['p2'];
            $loser = $winner === $p1 ? $p2 : $p1;
            [$dw, $dl] = elo_changes(rating_row($winner, $m['mode'])['rating'],
                                     rating_row($loser, $m['mode'])['rating']);
            add_record($winner, $m['mode'], $m['region'], true, $dw);
            add_record($loser, $m['mode'], $m['region'], false, $dl);
            $db->prepare('UPDATE matches SET d1 = ?, d2 = ? WHERE id = ?')
                ->execute([$winner === $p1 ? $dw : $dl, $winner === $p2 ? $dw : $dl, $m['id']]);
        }
        $db->prepare('UPDATE lobbies SET match_id = NULL, last_match = ? WHERE id = ? AND match_id = ?')
            ->execute([$m['id'], $m['lobby_id'], $m['id']]);
        $db->commit();
    } catch (Throwable $e) {
        $db->rollBack();
        throw $e;
    }
}

/** Decides a match from its reports, if it can be decided now. */
function settle(array $m): void
{
    if ($m['state'] !== 'live') {
        return;
    }
    $p1 = (int)$m['p1'];
    $p2 = (int)$m['p2'];
    $r1 = $m['r1'];
    $r2 = $m['r2'];
    $winner_by = fn(?string $r, int $me, int $other) => $r === 'win' ? $me : ($r === 'loss' ? $other : null);
    $w1 = $winner_by($r1, $p1, $p2);
    $w2 = $winner_by($r2, $p2, $p1);
    if ($r1 !== null && $r2 !== null) {
        if ($w1 === $w2) {
            finish_match($m, $w1, 'agreed');
        } else {
            finish_match($m, null, 'disagree');
        }
        return;
    }
    // One report only: counts once the other player had time to report too.
    $grace = (int)(cfg()['report_grace'] ?? 120);
    $at = $r1 !== null ? (int)$m['r1_at'] : ($r2 !== null ? (int)$m['r2_at'] : null);
    if ($at !== null && now() - $at >= $grace) {
        finish_match($m, $r1 !== null ? $w1 : $w2, 'single_report');
        return;
    }
    if ($at === null && now() - (int)$m['created'] >= MATCH_TIMEOUT) {
        finish_match($m, null, 'no_report');
    }
}

/** Settles any match that has waited long enough (runs on ordinary requests; no cron needed). */
function settle_due(): void
{
    $grace = (int)(cfg()['report_grace'] ?? 120);
    $t = now();
    $st = db()->prepare("SELECT * FROM matches WHERE state = 'live' AND (
        (r1 IS NOT NULL AND r1_at <= ?) OR (r2 IS NOT NULL AND r2_at <= ?) OR created <= ?) LIMIT 20");
    $st->execute([$t - $grace, $t - $grace, $t - MATCH_TIMEOUT]);
    foreach ($st->fetchAll() as $m) {
        settle($m);
    }
}

function match_json(?array $m, int $me): ?array
{
    if (!$m) {
        return null;
    }
    $mine = (int)$m['p1'] === $me ? 'd1' : 'd2';
    return ['id' => (int)$m['id'], 'state' => $m['state'], 'mode' => $m['mode'],
            'region' => $m['region'], 'reason' => $m['reason'],
            'winner' => $m['winner'] === null ? null : (int)$m['winner'],
            'you_won' => $m['winner'] === null ? null : (int)$m['winner'] === $me,
            'rating_change' => (int)$m[$mine]];
}

function get_match(?int $id): ?array
{
    if (!$id) {
        return null;
    }
    $st = db()->prepare('SELECT * FROM matches WHERE id = ?');
    $st->execute([$id]);
    return $st->fetch() ?: null;
}

// --- Leaderboard ------------------------------------------------------------------------------

/**
 * $mode: one of MODES, or all (the lifetime record across $game's modes). $region: global or a
 * region.
 * Mode boards rank by rating; the lifetime board by wins.
 */
// A Discord avatar picture (64 px) for the launcher's leaderboard cards; null = none set.
function avatar_url($discord_id, $avatar): ?string
{
    if (!$discord_id || !$avatar || !preg_match('/^[a-z0-9_]+$/i', (string)$avatar)
            || !preg_match('/^[0-9]+$/', (string)$discord_id)) {
        return null;
    }
    return "https://cdn.discordapp.com/avatars/$discord_id/$avatar.png?size=64";
}

/** This server's own address, for links it hands out (config public_url, else the request's). */
function base_url(): string
{
    $u = (string)(cfg()['public_url'] ?? '');
    if ($u === '') {
        $https = !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off'
            || ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https';
        $dir = rtrim(str_replace('\\', '/', dirname($_SERVER['SCRIPT_NAME'] ?? '/')), '/');
        $u = ($https ? 'https' : 'http') . '://' . ($_SERVER['HTTP_HOST'] ?? 'localhost') . $dir;
    }
    return rtrim($u, '/') . '/';
}

function pic_dir(): string
{
    $dir = cfg()['pic_dir'] ?? (__DIR__ . '/pics');
    if (!is_dir($dir)) {
        @mkdir($dir, 0755, true);
    }
    if (!is_file("$dir/.htaccess")) {
        @file_put_contents("$dir/.htaccess", "Require all denied\nDeny from all\n");
        @file_put_contents("$dir/index.html", '');
    }
    return $dir;
}

function pic_path(int $player_id): string
{
    return pic_dir() . "/$player_id.png";
}

/** A player's picture URL: their own (account.php > picture), else their Discord avatar, else null.
 *  $r needs id, pic, discord_id, avatar. */
function player_pic(array $r): ?string
{
    if ((int)($r['pic'] ?? 0) > 0) {
        return base_url() . 'pic.php?id=' . (int)$r['id'] . '&v=' . (int)$r['pic'];
    }
    return avatar_url($r['discord_id'] ?? null, $r['avatar'] ?? null);
}

function leaderboard(string $mode, string $region, int $limit = 100, string $game = 'bt3'): array
{
    $db = db();
    $limit = max(1, min(200, $limit));
    $global = $region === 'global';
    if ($mode === 'all') {
        // The all-time record: every season, every mode of the game (career never resets).
        $modes = GAME_MODES[valid_game($game)];
        $in = implode(',', array_fill(0, count($modes), '?'));
        $where = $global ? '' : 'AND r.region = ?';
        $st = $db->prepare("SELECT p.id, p.name, p.discord_id, p.avatar, p.pic, SUM(r.wins) AS wins, SUM(r.losses) AS losses
            FROM career r JOIN players p ON p.id = r.player_id WHERE p.banned = 0 AND r.mode IN ($in) $where
            GROUP BY p.id, p.name, p.discord_id, p.avatar, p.pic HAVING SUM(r.wins) + SUM(r.losses) > 0
            ORDER BY wins DESC, losses ASC, p.name ASC LIMIT $limit");
        $st->execute($global ? $modes : array_merge($modes, [$region]));
    } elseif ($global) {
        $st = $db->prepare("SELECT p.id, p.name, p.discord_id, p.avatar, p.pic, r.rating, r.wins, r.losses
            FROM ratings r JOIN players p ON p.id = r.player_id
            WHERE r.mode = ? AND r.wins + r.losses > 0 AND p.banned = 0
            ORDER BY r.rating DESC, r.wins DESC, p.name ASC LIMIT $limit");
        $st->execute([$mode]);
    } else {
        // Players who played ranked lobbies in that region: their rating, their record there.
        $st = $db->prepare("SELECT p.id, p.name, p.discord_id, p.avatar, p.pic, r.rating, g.wins, g.losses
            FROM region_records g JOIN players p ON p.id = g.player_id
            JOIN ratings r ON r.player_id = g.player_id AND r.mode = g.mode
            WHERE g.mode = ? AND g.region = ? AND g.wins + g.losses > 0 AND p.banned = 0
            ORDER BY r.rating DESC, g.wins DESC, p.name ASC LIMIT $limit");
        $st->execute([$mode, $region]);
    }
    $rows = [];
    foreach ($st->fetchAll() as $i => $r) {
        $row = ['rank' => $i + 1, 'id' => (int)$r['id'], 'name' => $r['name'],
                'wins' => (int)$r['wins'], 'losses' => (int)$r['losses']];
        if (isset($r['rating'])) {
            $row['rating'] = (int)$r['rating'];
        }
        $row['avatar'] = player_pic($r);
        $rows[] = $row;
    }
    return $rows;
}

// --- Shared replays (replays.php, admin.php) -------------------------------------------------

function replay_dir(): string
{
    $dir = cfg()['replay_dir'] ?? (__DIR__ . '/replay_files');
    if (!is_dir($dir)) {
        @mkdir($dir, 0755, true);
    }
    if (!is_file("$dir/.htaccess")) {
        @file_put_contents("$dir/.htaccess", "Require all denied\nDeny from all\n");
        @file_put_contents("$dir/index.html", '');
    }
    return $dir;
}

function replay_path(int $id, string $which): string
{
    return replay_dir() . "/$id." . ($which === 'dtm' ? 'dtm' : 'sav');
}

function replay_remove(array $r): void
{
    foreach (['dtm', 'sav'] as $w) {
        @unlink(replay_path((int)$r['id'], $w));
    }
    db()->prepare('DELETE FROM replays WHERE id = ?')->execute([$r['id']]);
}


// --- Wrong passwords (account.php, the website's login) ---------------------------------------

function too_many_fails(string $key): bool
{
    $st = db()->prepare('SELECT n, until FROM login_fails WHERE k = ?');
    $st->execute([$key]);
    $f = $st->fetch();
    return $f && (int)$f['n'] >= LOGIN_FAILS && now() < (int)$f['until'];
}

function note_fail(string $key): void
{
    $db = db();
    $st = $db->prepare('SELECT n, until FROM login_fails WHERE k = ?');
    $st->execute([$key]);
    $f = $st->fetch();
    $n = $f && now() < (int)$f['until'] + LOGIN_PAUSE ? (int)$f['n'] + 1 : 1;
    $db->prepare('DELETE FROM login_fails WHERE k = ?')->execute([$key]);
    $db->prepare('INSERT INTO login_fails (k, n, until) VALUES (?, ?, ?)')
        ->execute([$key, $n, now() + LOGIN_PAUSE]);
}


// --- Rate limits (the website) ---------------------------------------------------------------

/** Counts one more `key` event; false once there were `max` within `window` seconds. */
function rate_ok(string $key, int $max, int $window): bool
{
    $db = db();
    $st = $db->prepare('SELECT n, until FROM web_rate WHERE k = ?');
    $st->execute([$key]);
    $r = $st->fetch();
    if ($r && now() < (int)$r['until']) {
        if ((int)$r['n'] >= $max) {
            return false;
        }
        $db->prepare('UPDATE web_rate SET n = n + 1 WHERE k = ?')->execute([$key]);
        return true;
    }
    $db->prepare('DELETE FROM web_rate WHERE k = ?')->execute([$key]);
    $db->prepare('INSERT INTO web_rate (k, n, until) VALUES (?, 1, ?)')->execute([$key, now() + $window]);
    return true;
}

/** The visitor's address, hashed (support messages and limits keep no plain addresses). */
function ip_hash(): string
{
    return hash('sha256', 'sparking-ip|' . ($_SERVER['REMOTE_ADDR'] ?? ''));
}


// --- Cloudflare R2 links (update.php, the website's downloads) -------------------------------

/** The R2 settings from config.php, or null when they aren't set. */
function r2_settings(): ?array
{
    $c = cfg();
    foreach (['r2_account_id', 'r2_access_key', 'r2_secret_key', 'r2_bucket'] as $k) {
        if (trim((string)($c[$k] ?? '')) === '') {
            return null;
        }
    }
    $endpoint = rtrim((string)($c['r2_endpoint'] ?? ''), '/');   // tests: a local S3 stand-in
    if ($endpoint === '') {
        $endpoint = 'https://' . $c['r2_account_id'] . '.r2.cloudflarestorage.com';
    }
    $prefix = trim((string)($c['update_prefix'] ?? ''), '/');
    return ['endpoint' => $endpoint, 'bucket' => (string)$c['r2_bucket'],
            'key' => (string)$c['r2_access_key'], 'secret' => (string)$c['r2_secret_key'],
            'prefix' => $prefix === '' ? '' : $prefix . '/'];
}

/** A presigned GET link for one object (SigV4, query string, region "auto", path style).
 *  ($region and an empty bucket = virtual-host style are only for the AWS test vectors.) */
function presign(array $r2, string $object, int $seconds, ?int $at = null, string $region = 'auto'): string
{
    $at = $at ?? time();
    $date = gmdate('Ymd', $at);
    $stamp = gmdate('Ymd\THis\Z', $at);
    $parts = parse_url($r2['endpoint']);
    $host = $parts['host'] . (isset($parts['port']) ? ':' . $parts['port'] : '');
    $base = rtrim($parts['path'] ?? '', '/');
    $path = $base . ($r2['bucket'] === '' ? '' : '/' . rawurlencode($r2['bucket'])) . '/'
        . implode('/', array_map('rawurlencode', explode('/', $object)));
    $scope = "$date/$region/s3/aws4_request";
    $query = [
        'X-Amz-Algorithm' => 'AWS4-HMAC-SHA256',
        'X-Amz-Credential' => $r2['key'] . '/' . $scope,
        'X-Amz-Date' => $stamp,
        'X-Amz-Expires' => (string)$seconds,
        'X-Amz-SignedHeaders' => 'host',
    ];
    ksort($query, SORT_STRING);
    $qs = implode('&', array_map(fn($k, $v) => rawurlencode($k) . '=' . rawurlencode($v),
                                 array_keys($query), $query));
    $canonical = "GET\n$path\n$qs\nhost:$host\n\nhost\nUNSIGNED-PAYLOAD";
    $to_sign = "AWS4-HMAC-SHA256\n$stamp\n$scope\n" . hash('sha256', $canonical);
    $k = hash_hmac('sha256', $date, 'AWS4' . $r2['secret'], true);
    $k = hash_hmac('sha256', $region, $k, true);
    $k = hash_hmac('sha256', 's3', $k, true);
    $k = hash_hmac('sha256', 'aws4_request', $k, true);
    $sig = hash_hmac('sha256', $to_sign, $k);
    return $parts['scheme'] . '://' . $host . $path . '?' . $qs . '&X-Amz-Signature=' . $sig;
}
