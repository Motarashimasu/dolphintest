<?php
// DRAGON NET Ranked server: shared code. Every endpoint includes this file.
//
// Players log in with Discord (one Discord account = one ranked profile). Ranked lobbies are
// listed here (not on Dolphin's lobby server): a host opens one, a guest joins it, the host
// starts a match, and both players' launchers report the result. A match counts when both
// reports agree; a lone report counts after a grace period (the other player left / crashed);
// reports that disagree void the match. Leaving a running match counts as a loss.
// Ratings: Elo, separate for Single Battle and Team Battle, starting at 1000.
// Seasons: ratings, records and region records belong to the current season (admin.php starts
// a new one: final standings are archived, everyone goes back to 1000 and 0-0). The career table
// (the all-time record) never resets. Banned players can't play ranked and aren't listed.
declare(strict_types=1);

const SCHEMA_VERSION = '2';
const MODES = ['single', 'team'];
const REGIONS = ['EA', 'CN', 'EU', 'NA', 'SA', 'OC', 'AF'];
const START_RATING = 1000;
const ELO_K = 32;
const LOBBY_TIMEOUT = 60;     // s without a host heartbeat: the lobby is gone
const GUEST_TIMEOUT = 45;     // s without a guest status call: the seat is free again
const LOGIN_TIMEOUT = 600;    // s to finish the Discord login
const MATCH_TIMEOUT = 7200;   // s: a match nobody reported is void

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
              'matches ADD COLUMN season INTEGER NOT NULL DEFAULT 1'] as $alter) {
        try {
            $db->exec("ALTER TABLE $alter");
        } catch (Throwable $e) {
            // column exists
        }
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
    db()->prepare('UPDATE players SET last_seen = ? WHERE id = ?')->execute([$t, $p['id']]);
    if ((int)($p['banned'] ?? 0) && !$allow_banned) {
        fail('banned', 403, ['reason' => (string)($p['ban_reason'] ?? '')]);
    }
    return $p;
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
 * $mode: single | team | all (all = lifetime record across modes). $region: global or a region.
 * Mode boards rank by rating; the lifetime board by wins.
 */
function leaderboard(string $mode, string $region, int $limit = 100): array
{
    $db = db();
    $limit = max(1, min(200, $limit));
    $global = $region === 'global';
    if ($mode === 'all') {
        // The all-time record: every season, every mode (career never resets).
        $where = $global ? '' : 'AND r.region = ?';
        $st = $db->prepare("SELECT p.id, p.name, SUM(r.wins) AS wins, SUM(r.losses) AS losses
            FROM career r JOIN players p ON p.id = r.player_id WHERE p.banned = 0 $where
            GROUP BY p.id, p.name HAVING SUM(r.wins) + SUM(r.losses) > 0
            ORDER BY wins DESC, losses ASC, p.name ASC LIMIT $limit");
        $st->execute($global ? [] : [$region]);
    } elseif ($global) {
        $st = $db->prepare("SELECT p.id, p.name, r.rating, r.wins, r.losses
            FROM ratings r JOIN players p ON p.id = r.player_id
            WHERE r.mode = ? AND r.wins + r.losses > 0 AND p.banned = 0
            ORDER BY r.rating DESC, r.wins DESC, p.name ASC LIMIT $limit");
        $st->execute([$mode]);
    } else {
        // Players who played ranked lobbies in that region: their rating, their record there.
        $st = $db->prepare("SELECT p.id, p.name, r.rating, g.wins, g.losses
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
        $rows[] = $row;
    }
    return $rows;
}
