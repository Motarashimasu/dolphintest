<?php
// Shared replays: players upload their ranked replays (the launcher's Replays screen, or
// automatically after a ranked match), everyone can search and download them (Replay Search).
// A replay is the .dtm (inputs) + .dtm.sav (the state it starts from) Dolphin-Sparking records,
// and its .json info (game, mode, players, score, winner, codes...).
//
//   start  {meta, dtm_size, sav_size, dtm_sha, sav_sha, match?}   (logged in)
//          -> {id, chunk}: upload the files in pieces with `part`, then `finish`.
//          -> {id, exists: true} when that replay (same inputs file, or the same ranked match) is
//             already shared: nothing to upload.
//   part   {id, which: dtm|sav, offset, data (base64)}  (the uploader) appends a piece; offset =
//          what's there so far
//   finish {id}  (the uploader) checks sizes + SHA-1: the replay is listed from now on
//   search {q?, game?: bt3|bt2, mode?, version?, page?} -> {replays: [...], more}  newest first;
//          q = part of a player's name. No login needed.
//   get    {id} -> {replay}: the listing entry + the full .json info (`meta`)
//   file   {id, which: dtm|sav} -> the file itself (application/octet-stream)
//   delete {id}  (the uploader) removes it
// Limits (config.php, optional): replay_dir (default ./replay_files, keep it out of reach of
// browsers: an .htaccess is written there), replay_max_mb (all replays together, default 1500:
// the oldest go first), replay_daily (uploads per player per day, default 30).
require __DIR__ . '/lib.php';

const REPLAY_CHUNK = 262144;            // bytes per `part` (before base64)
const REPLAY_DTM_MAX = 16 * 1048576;
const REPLAY_SAV_MAX = 64 * 1048576;
const REPLAY_PAGE = 20;
const REPLAY_UPLOAD_TIMEOUT = 3600;     // s: an unfinished upload is thrown away

function replay_row(int $id): array
{
    $st = db()->prepare('SELECT * FROM replays WHERE id = ?');
    $st->execute([$id]);
    $r = $st->fetch();
    if (!$r) {
        fail('no_such_replay', 404);
    }
    return $r;
}

/** Unfinished uploads past their time, and the oldest replays while over the size limit. */
function replay_cleanup(): void
{
    $db = db();
    $st = $db->prepare("SELECT * FROM replays WHERE state = 'upload' AND created < ?");
    $st->execute([now() - REPLAY_UPLOAD_TIMEOUT]);
    foreach ($st->fetchAll() as $r) {
        replay_remove($r);
    }
    $max = (int)(cfg()['replay_max_mb'] ?? 1500) * 1048576;
    $total = (int)$db->query('SELECT COALESCE(SUM(dtm_size + sav_size), 0) FROM replays')->fetchColumn();
    if ($total <= $max) {
        return;
    }
    foreach ($db->query("SELECT * FROM replays WHERE state = 'ready' ORDER BY id")->fetchAll() as $r) {
        if ($total <= $max) {
            break;
        }
        $total -= (int)$r['dtm_size'] + (int)$r['sav_size'];
        replay_remove($r);
    }
}

function replay_json(array $r, bool $full = false): array
{
    $out = [
        'id' => (int)$r['id'], 'game' => $r['game'], 'game_id' => $r['game_id'], 'mode' => $r['mode'],
        'players' => [$r['p1'], $r['p2']], 'wins' => [(int)$r['w1'], (int)$r['w2']],
        'winner' => $r['winner'], 'seconds' => (int)$r['seconds'], 'date' => $r['played'],
        'size' => (int)$r['dtm_size'] + (int)$r['sav_size'], 'downloads' => (int)$r['downloads'],
        'uploaded' => (int)$r['created'], 'uploader' => (string)($r['uploader_name'] ?? ''),
        'ranked' => $r['match_id'] !== null,
    ];
    if ($full) {
        $out['meta'] = json_decode((string)$r['meta'], true) ?: new stdClass();
    }
    return $out;
}

function text_field(array $meta, string $key, int $max): string
{
    $v = $meta[$key] ?? '';
    return is_scalar($v) ? mb_substr(trim((string)$v), 0, $max) : '';
}

$action = arg('action');

if ($action === 'file') {
    // Raw bytes, not JSON.
    $r = replay_row((int)arg('id', '0'));
    $which = arg('which') === 'sav' ? 'sav' : 'dtm';
    if ($r['state'] !== 'ready' || !is_file(replay_path((int)$r['id'], $which))) {
        fail('no_such_replay', 404);
    }
    if ($which === 'dtm') {
        db()->prepare('UPDATE replays SET downloads = downloads + 1 WHERE id = ?')->execute([$r['id']]);
    }
    $path = replay_path((int)$r['id'], $which);
    header('Content-Type: application/octet-stream');
    header('Content-Length: ' . filesize($path));
    header('Content-Disposition: attachment; filename="replay' . (int)$r['id'] . ($which === 'dtm' ? '.dtm' : '.dtm.sav') . '"');
    header('Cache-Control: no-store');
    readfile($path);
    exit;
}

guard(function () use ($action) {
    $db = db();
    switch ($action) {
        case 'start':
            $p = auth();
            $me = (int)$p['id'];
            $meta = input()['meta'] ?? null;
            if (!is_array($meta)) {
                fail('bad_replay');
            }
            $dtm_size = (int)arg('dtm_size', '0');
            $sav_size = (int)arg('sav_size', '0');
            $dtm_sha = strtolower((string)arg('dtm_sha', ''));
            $sav_sha = strtolower((string)arg('sav_sha', ''));
            $game = text_field($meta, 'game_id', 8);
            if ($dtm_size <= 0 || $sav_size <= 0 || !preg_match('/^[0-9a-f]{40}$/', $dtm_sha)
                || !preg_match('/^[0-9a-f]{40}$/', $sav_sha) || !preg_match('/^[A-Za-z0-9_-]{1,8}$/', $game)) {
                fail('bad_replay');
            }
            if ($dtm_size > REPLAY_DTM_MAX || $sav_size > REPLAY_SAV_MAX) {
                fail('replay_too_big', 413);
            }
            replay_cleanup();
            // Already shared (by either player of that match)?
            $match = (int)arg('match', '0');
            $match_id = null;
            if ($match > 0) {
                $m = get_match($match);
                if ($m && ((int)$m['p1'] === $me || (int)$m['p2'] === $me)) {
                    $match_id = $match;
                }
            }
            $st = $db->prepare("SELECT id FROM replays WHERE state = 'ready' AND (dtm_sha = ?"
                . ($match_id !== null ? ' OR match_id = ?' : '') . ')');
            $st->execute($match_id !== null ? [$dtm_sha, $match_id] : [$dtm_sha]);
            if (($old = $st->fetchColumn()) !== false) {
                out(['ok' => true, 'id' => (int)$old, 'exists' => true]);
            }
            // An unfinished upload of the same replay by this player (cut off): start over.
            $st = $db->prepare("SELECT * FROM replays WHERE state = 'upload' AND uploader = ? AND dtm_sha = ?");
            $st->execute([$me, $dtm_sha]);
            foreach ($st->fetchAll() as $old_row) {
                replay_remove($old_row);
            }
            $st = $db->prepare('SELECT COUNT(*) FROM replays WHERE uploader = ? AND created > ?');
            $st->execute([$me, now() - 86400]);
            if ((int)$st->fetchColumn() >= (int)(cfg()['replay_daily'] ?? 30)) {
                fail('too_many_uploads', 429);
            }
            $players = is_array($meta['players'] ?? null) ? array_values($meta['players']) : [];
            $wins = is_array($meta['wins'] ?? null) ? array_values($meta['wins']) : [];
            $mode = text_field($meta, 'mode', 8);
            // Which game: the launcher says (the menus it's in), else the disc ID tells.
            $which_game = (string)arg('game', '');
            if (!isset(GAME_MODES[$which_game])) {
                $which_game = str_starts_with($game, 'RDB') ? 'bt2' : 'bt3';
            }
            if ($which_game === 'bt2' && in_array($mode, ['single', 'team'], true)) {
                $mode = 'b2' . $mode;   // Budokai Tenkaichi 2's ladder names
            }
            $db->prepare('INSERT INTO replays (uploader, state, game, game_id, mode, p1, p2, w1, w2, winner, seconds,
                          played, meta, dtm_size, sav_size, dtm_sha, sav_sha, match_id, created)
                          VALUES (?, \'upload\', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
                ->execute([$me, $which_game, $game, in_array($mode, MODES, true) ? $mode : '',
                           mb_substr(trim((string)($players[0] ?? '?')), 0, 64) ?: '?',
                           mb_substr(trim((string)($players[1] ?? '?')), 0, 64) ?: '?',
                           max(0, min(99, (int)($wins[0] ?? 0))), max(0, min(99, (int)($wins[1] ?? 0))),
                           text_field($meta, 'winner', 64), max(0, (int)($meta['seconds'] ?? 0)),
                           text_field($meta, 'date', 32), json_encode($meta, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
                           $dtm_size, $sav_size, $dtm_sha, $sav_sha, $match_id, now()]);
            $id = (int)$db->lastInsertId();
            foreach (['dtm', 'sav'] as $w) {
                file_put_contents(replay_path($id, $w), '');
            }
            out(['ok' => true, 'id' => $id, 'chunk' => REPLAY_CHUNK]);

        case 'part':
            $p = auth();
            $r = replay_row((int)arg('id', '0'));
            if ((int)$r['uploader'] !== (int)$p['id'] || $r['state'] !== 'upload') {
                fail('not_yours', 403);
            }
            $which = arg('which') === 'sav' ? 'sav' : 'dtm';
            $data = base64_decode((string)arg('data', ''), true);
            if ($data === false || strlen($data) > REPLAY_CHUNK) {
                fail('bad_part');
            }
            $path = replay_path((int)$r['id'], $which);
            clearstatcache(true, $path);
            $have = is_file($path) ? filesize($path) : 0;
            if ((int)arg('offset', '-1') !== $have) {
                fail('wrong_offset', 409, ['have' => $have]);
            }
            if ($have + strlen($data) > (int)$r[$which . '_size']) {
                fail('bad_part');
            }
            file_put_contents($path, $data, FILE_APPEND | LOCK_EX);
            out(['ok' => true, 'have' => $have + strlen($data)]);

        case 'finish':
            $p = auth();
            $r = replay_row((int)arg('id', '0'));
            if ((int)$r['uploader'] !== (int)$p['id'] || $r['state'] !== 'upload') {
                fail('not_yours', 403);
            }
            foreach (['dtm', 'sav'] as $w) {
                $path = replay_path((int)$r['id'], $w);
                clearstatcache(true, $path);
                if (!is_file($path) || filesize($path) !== (int)$r[$w . '_size'] || sha1_file($path) !== $r[$w . '_sha']) {
                    replay_remove($r);
                    fail('upload_broken');
                }
            }
            $db->prepare("UPDATE replays SET state = 'ready', created = ? WHERE id = ?")->execute([now(), $r['id']]);
            replay_cleanup();
            out(['ok' => true, 'id' => (int)$r['id']]);

        case 'search':
            $where = ["r.state = 'ready'"];
            $args = [];
            $q = trim((string)arg('q', ''));
            if ($q !== '') {
                $where[] = "(r.p1 LIKE ? ESCAPE '!' OR r.p2 LIKE ? ESCAPE '!')";
                $like = '%' . str_replace(['!', '%', '_'], ['!!', '!%', '!_'], mb_substr($q, 0, 24)) . '%';
                array_push($args, $like, $like);
            }
            $game = (string)arg('game', '');
            if (isset(GAME_MODES[$game])) {
                $where[] = 'r.game = ?';
                $args[] = $game;
            }
            $mode = (string)arg('mode', '');
            if (in_array($mode, MODES, true)) {
                $where[] = 'r.mode = ?';
                $args[] = $mode;
            }
            $version = (string)arg('version', '');
            if (preg_match('/^[A-Za-z0-9_-]{1,8}$/', $version)) {
                $where[] = 'r.game_id = ?';
                $args[] = $version;
            }
            $page = max(0, min(500, (int)arg('page', '0')));
            $st = $db->prepare('SELECT r.*, p.name AS uploader_name FROM replays r LEFT JOIN players p ON p.id = r.uploader
                                WHERE ' . implode(' AND ', $where) . ' ORDER BY r.id DESC LIMIT '
                . (REPLAY_PAGE + 1) . ' OFFSET ' . ($page * REPLAY_PAGE));
            $st->execute($args);
            $rows = $st->fetchAll();
            out(['ok' => true, 'replays' => array_map('replay_json', array_slice($rows, 0, REPLAY_PAGE)),
                 'more' => count($rows) > REPLAY_PAGE, 'page' => $page]);

        case 'get':
            $st = $db->prepare("SELECT r.*, p.name AS uploader_name FROM replays r LEFT JOIN players p ON p.id = r.uploader
                                WHERE r.id = ? AND r.state = 'ready'");
            $st->execute([(int)arg('id', '0')]);
            $r = $st->fetch();
            if (!$r) {
                fail('no_such_replay', 404);
            }
            out(['ok' => true, 'replay' => replay_json($r, true)]);

        case 'delete':
            $p = auth();
            $r = replay_row((int)arg('id', '0'));
            if ((int)$r['uploader'] !== (int)$p['id']) {
                fail('not_yours', 403);
            }
            replay_remove($r);
            out(['ok' => true]);

        default:
            fail('bad_action');
    }
});
