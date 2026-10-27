<?php
// Quick Match: a pool of players searching for a Single Battle, paired two at a time. The
// launcher keeps polling `status` (every ~2 s) while it searches; once paired, the host (p1:
// picked at random, pad 1) opens a room and posts its code, the guest joins it, both see the
// other's ping and connection, and both answer. Both accept: the match goes ahead (each closes
// its Buffer Training first and says `ready`; the host starts when both are). One declines,
// can't connect, or doesn't answer in time: both are searching again, and that pair isn't made
// again for a few minutes. Needs a DRAGON NET login (a ranked suspension doesn't matter here).
//   search {game, version, region, link}   join the pool (or stay in it); returns status
//   status                                 keep searching; who you're paired with, if anyone
//   room {match, room}                     host: the room code (or ip:port) the guest joins
//   answer {match, accept: 1|0}            accept or decline the match
//   fail {match, reason}                   couldn't connect to the other player
//   ready {match}                          accepted, and Buffer Training is closed
//   leave                                  stop searching (a pair not yet agreed is called off)
require __DIR__ . '/lib.php';

const QUICK_STALE = 15;        // s without a poll: off the pool
const QUICK_ANY_REGION = 20;   // s of waiting before another region is fine
const QUICK_ANSWER = 60;       // s from pairing to both answers (connecting + the question)
const QUICK_READY = 45;        // s from both accepting to both being ready
const QUICK_AVOID = 300;       // s a declined / failed pair isn't made again
const QUICK_SHOW_ENDED = 30;   // s a called-off pair is still reported (so both hear why)

function quick_row(int $me): ?array
{
    $st = db()->prepare('SELECT * FROM quick_queue WHERE player_id = ?');
    $st->execute([$me]);
    return $st->fetch() ?: null;
}

function quick_match(?int $id): ?array
{
    if (!$id) {
        return null;
    }
    $st = db()->prepare('SELECT * FROM quick_matches WHERE id = ?');
    $st->execute([$id]);
    return $st->fetch() ?: null;
}

/** Calls a pair off: both back to searching (their rows keep it as last_match). */
function quick_end(array $m, string $state, ?int $by, string $reason = '', bool $avoid = true): void
{
    $db = db();
    $db->prepare('UPDATE quick_matches SET state = ?, by_player = ?, reason = ?, updated = ?
                  WHERE id = ? AND state IN (?, ?)')
        ->execute([$state, $by, $reason, now(), $m['id'], 'pairing', 'go']);
    $db->prepare('UPDATE quick_queue SET match_id = NULL, last_match = ?, joined = ? WHERE match_id = ?')
        ->execute([$m['id'], now(), $m['id']]);
    if ($avoid) {
        [$a, $b] = [min((int)$m['p1'], (int)$m['p2']), max((int)$m['p1'], (int)$m['p2'])];
        $db->prepare('DELETE FROM quick_avoid WHERE a = ? AND b = ?')->execute([$a, $b]);
        $db->prepare('INSERT INTO quick_avoid (a, b, until) VALUES (?, ?, ?)')->execute([$a, $b, now() + QUICK_AVOID]);
    }
}

/** Pairs that ran out of time: unanswered (counts as declined by whoever didn't), or accepted
 *  but never both ready. */
function quick_timeouts(): void
{
    $db = db();
    $st = $db->prepare("SELECT * FROM quick_matches WHERE (state = 'pairing' AND created < ?)
                        OR (state = 'go' AND updated < ? AND (ready1 = 0 OR ready2 = 0))");
    $st->execute([now() - QUICK_ANSWER, now() - QUICK_READY]);
    foreach ($st->fetchAll() as $m) {
        if ($m['state'] === 'go') {
            quick_end($m, 'failed', null, 'not_ready');
            continue;
        }
        $by = $m['a1'] === null ? (int)$m['p1'] : ($m['a2'] === null ? (int)$m['p2'] : null);
        quick_end($m, 'expired', $by, $m['room'] === null ? 'no_room' : 'no_answer');
    }
    $db->prepare('DELETE FROM quick_queue WHERE seen < ? AND match_id IS NULL')->execute([now() - QUICK_STALE]);
    $db->prepare('DELETE FROM quick_avoid WHERE until < ?')->execute([now()]);
}

/** Pairs this searching player with the best other one: same game and disc version, recently
 *  seen, not avoided; the same region first (another one once either has waited a while). */
function quick_pair(array $me): void
{
    $db = db();
    $id = (int)$me['player_id'];
    $st = $db->prepare('SELECT q.* FROM quick_queue q WHERE q.player_id <> ? AND q.match_id IS NULL
                        AND q.seen >= ? AND q.game = ? AND q.version = ?
                        AND NOT EXISTS (SELECT 1 FROM quick_avoid v WHERE v.until >= ?
                            AND v.a = CASE WHEN q.player_id < ? THEN q.player_id ELSE ? END
                            AND v.b = CASE WHEN q.player_id < ? THEN ? ELSE q.player_id END)
                        ORDER BY CASE WHEN q.region = ? THEN 0 ELSE 1 END, q.joined LIMIT 10');
    $st->execute([$id, now() - QUICK_STALE, $me['game'], $me['version'], now(), $id, $id, $id, $id, $me['region']]);
    foreach ($st->fetchAll() as $o) {
        $waited = max(now() - (int)$me['joined'], now() - (int)$o['joined']);
        if ($o['region'] !== $me['region'] && $waited < QUICK_ANY_REGION) {
            continue;
        }
        $db->beginTransaction();
        $host = random_int(0, 1) ? $id : (int)$o['player_id'];
        $guest = $host === $id ? (int)$o['player_id'] : $id;
        $db->prepare("INSERT INTO quick_matches (p1, p2, game, version, state, created, updated)
                      VALUES (?, ?, ?, ?, 'pairing', ?, ?)")
            ->execute([$host, $guest, $me['game'], $me['version'], now(), now()]);
        $mid = (int)$db->lastInsertId();
        $u = $db->prepare('UPDATE quick_queue SET match_id = ? WHERE player_id = ? AND match_id IS NULL');
        $u->execute([$mid, $id]);
        $ok = $u->rowCount() === 1;
        $u->execute([$mid, (int)$o['player_id']]);
        if ($ok && $u->rowCount() === 1) {
            $db->commit();
            return;
        }
        $db->rollBack();   // (someone else paired one of them first)
        return;
    }
}

function quick_status(int $me): array
{
    $row = quick_row($me);
    $count = (int)db()->query('SELECT COUNT(*) FROM quick_queue WHERE match_id IS NULL AND seen >= '
        . (now() - QUICK_STALE))->fetchColumn();
    if (!$row) {
        return ['ok' => true, 'state' => 'idle', 'searching' => $count];
    }
    $out = ['ok' => true, 'state' => $row['match_id'] ? 'match' : 'searching', 'searching' => $count,
            'since' => (int)$row['joined']];
    if ($m = quick_match($row['match_id'] ? (int)$row['match_id'] : null)) {
        $out['match'] = quick_match_json($m, $me);
    }
    $last = quick_match($row['last_match'] ? (int)$row['last_match'] : null);
    if ($last && now() - (int)$last['updated'] <= QUICK_SHOW_ENDED) {
        $out['ended'] = ['id' => (int)$last['id'], 'state' => $last['state'], 'reason' => (string)$last['reason'],
                         'by_you' => (int)$last['by_player'] === $me, 'by_them' => $last['by_player'] !== null
                             && (int)$last['by_player'] !== $me];
    }
    return $out;
}

function quick_match_json(array $m, int $me): array
{
    $host = (int)$m['p1'] === $me;
    $other = $host ? (int)$m['p2'] : (int)$m['p1'];
    $st = db()->prepare('SELECT p.name, q.link, q.region FROM players p LEFT JOIN quick_queue q
                         ON q.player_id = p.id WHERE p.id = ?');
    $st->execute([$other]);
    $o = $st->fetch() ?: ['name' => '?', 'link' => 'unknown', 'region' => ''];
    return ['id' => (int)$m['id'], 'state' => $m['state'], 'role' => $host ? 'host' : 'guest',
            'room' => $m['room'], 'opponent' => ['name' => $o['name'], 'link' => $o['link'] ?? 'unknown',
            'region' => $o['region'] ?? ''],
            'you_answered' => ($host ? $m['a1'] : $m['a2']) !== null,
            'they_answered' => ($host ? $m['a2'] : $m['a1']) !== null,
            'you_ready' => (bool)($host ? $m['ready1'] : $m['ready2']),
            'they_ready' => (bool)($host ? $m['ready2'] : $m['ready1'])];
}

/** The caller's current pair (from the request's "match"), or a 409. */
function quick_mine(int $me): array
{
    $m = quick_match((int)arg('match', '0'));
    if (!$m || ((int)$m['p1'] !== $me && (int)$m['p2'] !== $me)) {
        fail('no_match', 404);
    }
    return $m;
}

guard(function () {
    $p = auth(true);
    $me = (int)$p['id'];
    $db = db();
    quick_timeouts();
    switch (arg('action')) {
        case 'search':
            $game = valid_game(arg('game'));
            $version = valid_version(arg('version'));
            $region = valid_region(arg('region'));
            $link = preg_replace('/[^a-z]/', '', strtolower((string)arg('link', 'unknown'))) ?: 'unknown';
            if (quick_row($me)) {
                $db->prepare('UPDATE quick_queue SET game = ?, version = ?, region = ?, link = ?, seen = ?
                              WHERE player_id = ?')->execute([$game, $version, $region, substr($link, 0, 16), now(), $me]);
            } else {
                $db->prepare('INSERT INTO quick_queue (player_id, game, version, region, link, joined, seen)
                              VALUES (?, ?, ?, ?, ?, ?, ?)')
                    ->execute([$me, $game, $version, $region, substr($link, 0, 16), now(), now()]);
            }
            $row = quick_row($me);
            if (!$row['match_id']) {
                quick_pair($row);
            }
            out(quick_status($me));

        case 'status':
            $db->prepare('UPDATE quick_queue SET seen = ? WHERE player_id = ?')->execute([now(), $me]);
            $row = quick_row($me);
            if ($row && !$row['match_id']) {
                quick_pair($row);
            }
            out(quick_status($me));

        case 'room':
            $m = quick_mine($me);
            $room = trim((string)arg('room', ''));
            if ((int)$m['p1'] !== $me || $m['state'] !== 'pairing' || $room === '' || strlen($room) > 128) {
                fail('bad_room');
            }
            $db->prepare('UPDATE quick_matches SET room = ?, updated = ? WHERE id = ?')->execute([$room, now(), $m['id']]);
            out(quick_status($me));

        case 'answer':
            $m = quick_mine($me);
            if ($m['state'] !== 'pairing') {
                out(quick_status($me));   // (already called off, or already agreed)
            }
            $col = (int)$m['p1'] === $me ? 'a1' : 'a2';
            if (arg('accept') === '1' || arg('accept') === 'true') {
                $db->prepare("UPDATE quick_matches SET $col = 'yes', updated = ? WHERE id = ?")->execute([now(), $m['id']]);
                $m = quick_match((int)$m['id']);
                if ($m['a1'] === 'yes' && $m['a2'] === 'yes') {
                    $db->prepare("UPDATE quick_matches SET state = 'go', updated = ? WHERE id = ? AND state = 'pairing'")
                        ->execute([now(), $m['id']]);
                }
            } else {
                $db->prepare("UPDATE quick_matches SET $col = 'no' WHERE id = ?")->execute([$m['id']]);
                quick_end($m, 'declined', $me);
            }
            out(quick_status($me));

        case 'fail':
            $m = quick_mine($me);
            if (in_array($m['state'], ['pairing', 'go'], true)) {
                quick_end($m, 'failed', null, substr(preg_replace('/[^a-z_]/', '', (string)arg('reason', 'connect')), 0, 32));
            }
            out(quick_status($me));

        case 'ready':
            $m = quick_mine($me);
            if ($m['state'] !== 'go') {
                fail('not_agreed', 409);
            }
            $col = (int)$m['p1'] === $me ? 'ready1' : 'ready2';
            $db->prepare("UPDATE quick_matches SET $col = 1 WHERE id = ?")->execute([$m['id']]);
            out(quick_status($me));

        case 'leave':
            $row = quick_row($me);
            if ($row && ($m = quick_match($row['match_id'] ? (int)$row['match_id'] : null)) && $m['state'] === 'pairing') {
                quick_end($m, 'left', $me);
            }
            $db->prepare('DELETE FROM quick_queue WHERE player_id = ?')->execute([$me]);
            out(['ok' => true, 'state' => 'idle']);

        default:
            fail('bad_action');
    }
});
