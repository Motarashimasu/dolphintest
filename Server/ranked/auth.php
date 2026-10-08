<?php
// Discord login for the launcher.
//   action=start  -> {login, poll, url}: the launcher opens `url` (Discord's authorize page) in
//                    the browser, then polls with login + poll.
//   action=poll   -> {state: waiting | done (+ token, player) | error | expired}
//   action=logout -> ends this session (X-Sparking-Token).
require __DIR__ . '/lib.php';

guard(function () {
    $c = cfg();
    $db = db();
    switch (arg('action')) {
        case 'start':
            if (empty($c['discord_client_secret']) || str_starts_with($c['discord_client_secret'], 'PUT-')) {
                fail('discord_not_configured', 503);
            }
            $db->prepare('DELETE FROM logins WHERE created < ?')->execute([now() - LOGIN_TIMEOUT]);
            $login = bin2hex(random_bytes(16));
            $poll = bin2hex(random_bytes(16));
            $db->prepare('INSERT INTO logins (id, poll_hash, created) VALUES (?, ?, ?)')
                ->execute([$login, token_hash($poll), now()]);
            $url = ($c['discord_authorize'] ?? 'https://discord.com/oauth2/authorize') . '?' . http_build_query([
                'response_type' => 'code',
                'client_id' => $c['discord_client_id'],
                'scope' => 'identify',
                'redirect_uri' => $c['discord_redirect'],
                'state' => $login,
                'prompt' => 'none',
            ]);
            out(['ok' => true, 'login' => $login, 'poll' => $poll, 'url' => $url,
                 'expires_in' => LOGIN_TIMEOUT]);

        case 'poll':
            $st = $db->prepare('SELECT * FROM logins WHERE id = ?');
            $st->execute([arg('login', '')]);
            $l = $st->fetch();
            if (!$l || !hash_equals($l['poll_hash'], token_hash(arg('poll', '')))) {
                out(['ok' => true, 'state' => 'expired']);
            }
            if ($l['error']) {
                $db->prepare('DELETE FROM logins WHERE id = ?')->execute([$l['id']]);
                out(['ok' => true, 'state' => 'error', 'error' => $l['error']]);
            }
            if (!$l['player_id']) {
                if (now() - (int)$l['created'] > LOGIN_TIMEOUT) {
                    out(['ok' => true, 'state' => 'expired']);
                }
                out(['ok' => true, 'state' => 'waiting']);
            }
            // Hand the session over exactly once.
            $del = $db->prepare('DELETE FROM logins WHERE id = ?');
            $del->execute([$l['id']]);
            if ($del->rowCount() !== 1) {
                out(['ok' => true, 'state' => 'expired']);
            }
            $token = new_session((int)$l['player_id']);
            out(['ok' => true, 'state' => 'done', 'token' => $token,
                 'player' => player_brief((int)$l['player_id'], 'single')]);

        case 'logout':
            $token = $_SERVER['HTTP_X_SPARKING_TOKEN'] ?? arg('token') ?? '';
            $db->prepare('DELETE FROM sessions WHERE token_hash = ?')->execute([token_hash($token)]);
            out(['ok' => true]);

        default:
            fail('bad_action');
    }
});
