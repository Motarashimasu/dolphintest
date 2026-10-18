<?php
// Friends, who's online, and the admin's messages. Everything needs a login.
//   poll                -> {friends: [{id, name, online}], incoming: [{id, name}],
//                           outgoing: [{id, name}], messages: [{id, text, at}]}
//                          The launcher calls it every ~20 s: that's what keeps a player online.
//                          messages = the admin's active messages this player hasn't closed.
//   request {name}      ask someone (by username) to be friends; if they had asked you, you're
//                       friends at once
//   accept {id}         accept a request from player id
//   decline {id}        decline a request from id / cancel yours to id
//   remove {id}         stop being friends
//   ack {message}       this player closed message id (it isn't sent again)
require __DIR__ . '/lib.php';

/** The friends row of two players (a < b), or null. */
function pair(int $x, int $y): ?array
{
    $st = db()->prepare('SELECT * FROM friends WHERE a = ? AND b = ?');
    $st->execute([min($x, $y), max($x, $y)]);
    $r = $st->fetch();
    return $r ?: null;
}

function friend_count(int $me): int
{
    $st = db()->prepare("SELECT COUNT(*) FROM friends WHERE (a = ? OR b = ?) AND state = 'friends'");
    $st->execute([$me, $me]);
    return (int)$st->fetchColumn();
}

guard(function () {
    $p = auth();
    $me = (int)$p['id'];
    $db = db();
    switch (arg('action')) {
        case 'poll':
            $st = $db->prepare('SELECT f.*, p.id AS pid, p.name, p.last_seen, p.banned FROM friends f
                JOIN players p ON p.id = (CASE WHEN f.a = ? THEN f.b ELSE f.a END)
                WHERE f.a = ? OR f.b = ? ORDER BY p.name');
            $st->execute([$me, $me, $me]);
            $friends = $incoming = $outgoing = [];
            foreach ($st->fetchAll() as $r) {
                $who = ['id' => (int)$r['pid'], 'name' => $r['name']];
                if ($r['state'] === 'friends') {
                    $who['online'] = !(int)$r['banned'] && is_online($r);
                    $friends[] = $who;
                } elseif ((int)$r['requester'] === $me) {
                    $outgoing[] = $who;
                } else {
                    $incoming[] = $who;
                }
            }
            $st = $db->prepare('SELECT m.id, m.text, m.at FROM messages m
                LEFT JOIN message_reads r ON r.message_id = m.id AND r.player_id = ?
                WHERE m.active = 1 AND m.expires > ? AND r.message_id IS NULL ORDER BY m.id');
            $st->execute([$me, now()]);
            $messages = array_map(fn($m) => ['id' => (int)$m['id'], 'text' => $m['text'], 'at' => (int)$m['at']],
                                  $st->fetchAll());
            out(['ok' => true, 'friends' => $friends, 'incoming' => $incoming, 'outgoing' => $outgoing,
                 'messages' => $messages]);

        case 'request':
            $name = trim((string)arg('name', ''));
            $other = $name !== '' ? find_by_username($name) : null;
            if (!$other || (int)$other['banned']) {
                fail('no_such_player', 404);
            }
            $id = (int)$other['id'];
            if ($id === $me) {
                fail('own_name');
            }
            $r = pair($me, $id);
            if ($r && $r['state'] === 'friends') {
                fail('already_friends', 409);
            }
            if (friend_count($me) >= FRIENDS_MAX) {
                fail('too_many_friends', 409);
            }
            if ($r && (int)$r['requester'] !== $me) {
                // They had asked first: friends now.
                $db->prepare("UPDATE friends SET state = 'friends' WHERE a = ? AND b = ?")
                    ->execute([min($me, $id), max($me, $id)]);
                out(['ok' => true, 'state' => 'friends', 'name' => $other['name']]);
            }
            if (!$r) {
                $db->prepare("INSERT INTO friends (a, b, requester, state, created) VALUES (?, ?, ?, 'pending', ?)")
                    ->execute([min($me, $id), max($me, $id), $me, now()]);
            }
            out(['ok' => true, 'state' => 'pending', 'name' => $other['name']]);

        case 'accept':
            $id = (int)arg('id', '0');
            $r = pair($me, $id);
            if (!$r || $r['state'] !== 'pending' || (int)$r['requester'] === $me) {
                fail('no_request', 404);
            }
            if (friend_count($me) >= FRIENDS_MAX) {
                fail('too_many_friends', 409);
            }
            $db->prepare("UPDATE friends SET state = 'friends' WHERE a = ? AND b = ?")
                ->execute([min($me, $id), max($me, $id)]);
            out(['ok' => true]);

        case 'decline':
        case 'remove':
            $id = (int)arg('id', '0');
            $db->prepare('DELETE FROM friends WHERE a = ? AND b = ?')->execute([min($me, $id), max($me, $id)]);
            out(['ok' => true]);

        case 'ack':
            $mid = (int)arg('message', '0');
            $db->prepare('DELETE FROM message_reads WHERE message_id = ? AND player_id = ?')->execute([$mid, $me]);
            $db->prepare('INSERT INTO message_reads (message_id, player_id) VALUES (?, ?)')->execute([$mid, $me]);
            out(['ok' => true]);

        default:
            fail('bad_action');
    }
});
