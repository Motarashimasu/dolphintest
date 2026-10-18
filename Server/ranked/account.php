<?php
// DRAGON NET accounts, made in the launcher: a username + password.
//   register {username, password}  -> {token, player}: a new account, logged in
//   login    {username, password}  -> {token, player}
//   claim    {username, password}  (logged in) a profile from before accounts (made with the
//                                  Discord login, auth.php) gets its username + password; its
//                                  ratings and records stay. Once: a profile with a username
//                                  can't claim again.
// Logging out: auth.php action=logout.
// Wrong passwords: after LOGIN_FAILS for one username, that username waits LOGIN_PAUSE seconds.
require __DIR__ . '/lib.php';

function account_json(array $p): array
{
    return ['id' => (int)$p['id'], 'name' => $p['name'], 'username' => $p['username']];
}

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

guard(function () {
    $db = db();
    switch (arg('action')) {
        case 'register':
            $name = valid_username(arg('username'));
            $pass = valid_password(arg('password'));
            if (find_by_username($name)) {
                fail('username_taken', 409);
            }
            // Accounts have no Discord ID; the column is NOT NULL UNIQUE from Discord times, so it
            // gets a unique placeholder (never a number, so no Discord avatar is looked up).
            $db->prepare('INSERT INTO players (discord_id, name, avatar, created, last_seen, username,
                          uname_key, pass_hash) VALUES (?, ?, NULL, ?, ?, ?, ?, ?)')
                ->execute(['acct:' . bin2hex(random_bytes(12)), $name, now(), now(), $name,
                           strtolower($name), password_hash($pass, PASSWORD_DEFAULT)]);
            $p = find_by_username($name);
            out(['ok' => true, 'token' => new_session((int)$p['id']), 'player' => account_json($p)]);

        case 'login':
            $name = trim((string)arg('username', ''));
            $pass = (string)arg('password', '');
            $key = 'u:' . strtolower(substr($name, 0, 40));
            if (too_many_fails($key)) {
                fail('too_many_attempts', 429);
            }
            $p = $name !== '' ? find_by_username($name) : null;
            if (!$p || !$p['pass_hash'] || !password_verify($pass, $p['pass_hash'])) {
                note_fail($key);
                fail('wrong_login', 401);
            }
            $db->prepare('DELETE FROM login_fails WHERE k = ?')->execute([$key]);
            if (password_needs_rehash($p['pass_hash'], PASSWORD_DEFAULT)) {
                $db->prepare('UPDATE players SET pass_hash = ? WHERE id = ?')
                    ->execute([password_hash($pass, PASSWORD_DEFAULT), $p['id']]);
            }
            out(['ok' => true, 'token' => new_session((int)$p['id']), 'player' => account_json($p)]);

        case 'claim':
            $p = auth(true);
            if ($p['username'] !== null && $p['username'] !== '') {
                fail('already_claimed', 409, ['username' => $p['username']]);
            }
            $name = valid_username(arg('username'));
            $pass = valid_password(arg('password'));
            if (find_by_username($name)) {
                fail('username_taken', 409);
            }
            $db->prepare('UPDATE players SET username = ?, uname_key = ?, pass_hash = ?, name = ? WHERE id = ?')
                ->execute([$name, strtolower($name), password_hash($pass, PASSWORD_DEFAULT), $name, $p['id']]);
            out(['ok' => true, 'player' => account_json(find_by_username($name))]);

        default:
            fail('bad_action');
    }
});
