<?php
// Ranked lobbies: listed here (the launcher's Ranked Lobby Browser), 2 players each, no
// spectators.
//   open {mode, region, join, link}   host: list my lobby (join = room code or ip:port)
//   heartbeat {lobby}                 host: every ~15 s, keeps it listed; returns status
//   close {lobby}                     host: take it down
//   list {mode?}                      open lobbies (with the host's rating)
//   join {lobby}                      guest: take the seat (then join the room in Dolphin)
//   status {lobby}                    host or guest: who's in, the running / last match
//   leave {lobby}                     guest: give the seat back
require __DIR__ . '/lib.php';

function lobby_row(int $id): array
{
    $st = db()->prepare('SELECT * FROM lobbies WHERE id = ?');
    $st->execute([$id]);
    $l = $st->fetch();
    if (!$l || (int)$l['closed'] || now() - (int)$l['heartbeat'] > LOBBY_TIMEOUT) {
        fail('lobby_gone', 404);
    }
    return $l;
}

function guest_present(array $l): bool
{
    return $l['guest_id'] !== null && now() - (int)$l['guest_seen'] <= GUEST_TIMEOUT;
}

function lobby_status(array $l, int $me): array
{
    settle_due();
    $l = lobby_row((int)$l['id']);
    $mode = $l['mode'];
    return ['ok' => true, 'lobby' => [
        'id' => (int)$l['id'], 'mode' => $mode, 'region' => $l['region'], 'join' => $l['join_target'],
        'link' => $l['link'], 'you_host' => (int)$l['host_id'] === $me,
        'host' => player_brief((int)$l['host_id'], $mode),
        'guest' => guest_present($l) ? player_brief((int)$l['guest_id'], $mode) : null,
        'match' => match_json(get_match($l['match_id'] ? (int)$l['match_id'] : null), $me),
        'last_match' => match_json(get_match($l['last_match'] ? (int)$l['last_match'] : null), $me),
    ]];
}

guard(function () {
    $p = auth();
    $me = (int)$p['id'];
    $db = db();
    switch (arg('action')) {
        case 'open':
            $mode = valid_mode(arg('mode'));
            $region = valid_region(arg('region'));
            $join = trim((string)arg('join', ''));
            if ($join === '' || strlen($join) > 128) {
                fail('bad_join');
            }
            $link = preg_replace('/[^a-z]/', '', strtolower((string)arg('link', 'unknown'))) ?: 'unknown';
            // One open lobby per host.
            $db->prepare('UPDATE lobbies SET closed = 1 WHERE host_id = ? AND closed = 0')->execute([$me]);
            $db->prepare('INSERT INTO lobbies (host_id, mode, region, join_target, link, created, heartbeat)
                          VALUES (?, ?, ?, ?, ?, ?, ?)')
                ->execute([$me, $mode, $region, $join, substr($link, 0, 16), now(), now()]);
            $id = (int)$db->lastInsertId();
            rating_row($me, $mode);
            out(lobby_status(lobby_row($id), $me));

        case 'heartbeat':
            $l = lobby_row((int)arg('lobby', '0'));
            if ((int)$l['host_id'] !== $me) {
                fail('not_host', 403);
            }
            $db->prepare('UPDATE lobbies SET heartbeat = ? WHERE id = ?')->execute([now(), $l['id']]);
            out(lobby_status($l, $me));

        case 'close':
            $db->prepare('UPDATE lobbies SET closed = 1 WHERE id = ? AND host_id = ?')
                ->execute([(int)arg('lobby', '0'), $me]);
            out(['ok' => true]);

        case 'list':
            settle_due();
            $mode = arg('mode');
            $sql = 'SELECT * FROM lobbies WHERE closed = 0 AND heartbeat >= ?';
            $params = [now() - LOBBY_TIMEOUT];
            if ($mode !== null && $mode !== '' && $mode !== 'any') {
                $sql .= ' AND mode = ?';
                $params[] = valid_mode($mode);
            }
            $st = $db->prepare($sql . ' ORDER BY created DESC LIMIT 100');
            $st->execute($params);
            $rows = [];
            foreach ($st->fetchAll() as $l) {
                $host = player_brief((int)$l['host_id'], $l['mode']);
                if (!$host) {
                    continue;
                }
                $full = guest_present($l);
                $rows[] = ['id' => (int)$l['id'], 'mode' => $l['mode'], 'region' => $l['region'],
                           'link' => $l['link'], 'host' => $host, 'full' => $full,
                           'in_match' => $l['match_id'] !== null, 'yours' => (int)$l['host_id'] === $me,
                           'players' => $full ? 2 : 1];
            }
            out(['ok' => true, 'lobbies' => $rows]);

        case 'join':
            $l = lobby_row((int)arg('lobby', '0'));
            if ((int)$l['host_id'] === $me) {
                fail('own_lobby');
            }
            if (guest_present($l) && (int)$l['guest_id'] !== $me) {
                fail('lobby_full', 409);
            }
            $db->prepare('UPDATE lobbies SET guest_id = ?, guest_seen = ? WHERE id = ?')
                ->execute([$me, now(), $l['id']]);
            rating_row($me, $l['mode']);
            out(lobby_status($l, $me));

        case 'status':
            $l = lobby_row((int)arg('lobby', '0'));
            if ((int)$l['guest_id'] === $me) {
                $db->prepare('UPDATE lobbies SET guest_seen = ? WHERE id = ?')->execute([now(), $l['id']]);
            } elseif ((int)$l['host_id'] !== $me) {
                fail('not_in_lobby', 403);
            }
            out(lobby_status($l, $me));

        case 'leave':
            $l = lobby_row((int)arg('lobby', '0'));
            if ((int)$l['guest_id'] === $me && $l['match_id'] === null) {
                $db->prepare('UPDATE lobbies SET guest_id = NULL WHERE id = ?')->execute([$l['id']]);
            }
            out(['ok' => true]);

        default:
            fail('bad_action');
    }
});
