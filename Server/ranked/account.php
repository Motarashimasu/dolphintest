<?php
// DRAGON NET accounts, made in the launcher: a username + password.
//   register {username, password}  -> {token, player}: a new account, logged in
//   login    {username, password}  -> {token, player}
//   claim    {username, password}  (logged in) a profile from before accounts (made with the
//                                  Discord login, auth.php) gets its username + password; its
//                                  ratings and records stay. Once: a profile with a username
//                                  can't claim again.
//   picture  {data}   (logged in) the profile picture: a PIC_SIZE x PIC_SIZE PNG / JPEG / WebP
//                     (base64; the launcher crops and scales to it) -> {picture: url}
//   picture_remove    (logged in) back to none
// Logging out: auth.php action=logout.
// Wrong passwords: after LOGIN_FAILS for one username, that username waits LOGIN_PAUSE seconds.
require __DIR__ . '/lib.php';

function account_json(array $p): array
{
    return ['id' => (int)$p['id'], 'name' => $p['name'], 'username' => $p['username']];
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

        case 'picture':
            $p = auth();
            $bytes = base64_decode((string)arg('data', ''), true);
            if ($bytes === false || $bytes === '' || strlen($bytes) > PIC_MAX_BYTES) {
                fail('bad_picture');
            }
            $info = @getimagesizefromstring($bytes);
            $types = [IMAGETYPE_PNG, IMAGETYPE_JPEG];
            if (defined('IMAGETYPE_WEBP')) {
                $types[] = IMAGETYPE_WEBP;
            }
            if (!$info || !in_array($info[2], $types, true)) {
                fail('bad_picture');
            }
            if ((int)$info[0] !== PIC_SIZE || (int)$info[1] !== PIC_SIZE) {
                fail('bad_picture_size', 400, ['size' => PIC_SIZE]);
            }
            // Drawn again from its pixels when GD is there: nothing but the picture is kept.
            if (function_exists('imagecreatefromstring') && function_exists('imagepng')) {
                $img = @imagecreatefromstring($bytes);
                if (!$img) {
                    fail('bad_picture');
                }
                imagesavealpha($img, true);
                ob_start();
                imagepng($img, null, 9);
                $bytes = (string)ob_get_clean();
                imagedestroy($img);
            } elseif ($info[2] !== IMAGETYPE_PNG) {
                fail('bad_picture');   // without GD only PNGs (stored as they are)
            }
            if (file_put_contents(pic_path((int)$p['id']), $bytes) === false) {
                fail('database_error', 500);
            }
            $v = max(now(), (int)$p['pic'] + 1);
            $db->prepare('UPDATE players SET pic = ? WHERE id = ?')->execute([$v, $p['id']]);
            $p['pic'] = $v;
            out(['ok' => true, 'picture' => player_pic($p)]);

        case 'picture_remove':
            $p = auth();
            @unlink(pic_path((int)$p['id']));
            $db->prepare('UPDATE players SET pic = 0 WHERE id = ?')->execute([$p['id']]);
            $p['pic'] = 0;
            out(['ok' => true, 'picture' => player_pic($p)]);

        default:
            fail('bad_action');
    }
});
