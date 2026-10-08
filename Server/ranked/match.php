<?php
// Ranked matches.
//   start {lobby}                 host, when it presses Start Match: opens the match (2 players)
//   report {lobby, result}        both players: result = win | loss (from their own side)
//   forfeit {lobby}               a player leaving a running match: counts as their loss
// A match counts when both reports agree. One report alone counts after `report_grace`
// seconds (the other player left or crashed). Reports that disagree void the match.
require __DIR__ . '/lib.php';

function live_match_for(int $lobby, int $me): array
{
    $st = db()->prepare('SELECT m.* FROM matches m JOIN lobbies l ON l.match_id = m.id
                         WHERE l.id = ? AND m.state = \'live\'');
    $st->execute([$lobby]);
    $m = $st->fetch();
    if (!$m) {
        fail('no_match', 404);
    }
    if ((int)$m['p1'] !== $me && (int)$m['p2'] !== $me) {
        fail('not_in_match', 403);
    }
    return $m;
}

function record_report(array $m, int $me, string $result): array
{
    $col = (int)$m['p1'] === $me ? '1' : '2';
    // First report wins; a player can't change their mind afterwards.
    db()->prepare("UPDATE matches SET r$col = ?, r{$col}_at = ? WHERE id = ? AND r$col IS NULL AND state = 'live'")
        ->execute([$result, now(), $m['id']]);
    $m = get_match((int)$m['id']);
    settle($m);
    return get_match((int)$m['id']);
}

guard(function () {
    $p = auth();
    $me = (int)$p['id'];
    $db = db();
    $lobby = (int)arg('lobby', '0');
    switch (arg('action')) {
        case 'start':
            $st = $db->prepare('SELECT * FROM lobbies WHERE id = ? AND closed = 0');
            $st->execute([$lobby]);
            $l = $st->fetch();
            if (!$l) {
                fail('lobby_gone', 404);
            }
            if ((int)$l['host_id'] !== $me) {
                fail('not_host', 403);
            }
            if ($l['guest_id'] === null || now() - (int)$l['guest_seen'] > GUEST_TIMEOUT) {
                fail('no_opponent', 409);
            }
            if ($l['match_id'] !== null) {
                $m = get_match((int)$l['match_id']);
                if ($m && $m['state'] === 'live') {
                    out(['ok' => true, 'match' => match_json($m, $me)]);  // already started
                }
            }
            $db->prepare("INSERT INTO matches (lobby_id, mode, region, p1, p2, state, created)
                          VALUES (?, ?, ?, ?, ?, 'live', ?)")
                ->execute([$l['id'], $l['mode'], $l['region'], $me, (int)$l['guest_id'], now()]);
            $id = (int)$db->lastInsertId();
            $db->prepare('UPDATE lobbies SET match_id = ? WHERE id = ?')->execute([$id, $l['id']]);
            out(['ok' => true, 'match' => match_json(get_match($id), $me)]);

        case 'report':
            $result = arg('result');
            if (!in_array($result, ['win', 'loss'], true)) {
                fail('bad_result');
            }
            $m = record_report(live_match_for($lobby, $me), $me, $result);
            out(['ok' => true, 'match' => match_json($m, $me)]);

        case 'forfeit':
            $m = record_report(live_match_for($lobby, $me), $me, 'loss');
            out(['ok' => true, 'match' => match_json($m, $me)]);

        default:
            fail('bad_action');
    }
});
