<?php
// Discord sends the player's browser back here after "Authorize" (OAuth2 redirect). We swap the
// code for the player's Discord identity, link it to their ranked profile, and the launcher
// (polling auth.php) picks the session up.
require __DIR__ . '/lib.php';

function page(string $title, string $text, bool $ok): never
{
    http_response_code($ok ? 200 : 400);
    header('Content-Type: text/html; charset=utf-8');
    $t = htmlspecialchars($title);
    $x = htmlspecialchars($text);
    $color = $ok ? '#3fbf6b' : '#e8663d';
    echo <<<HTML
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>DRAGON NET Ranked</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0f2a35;color:#fff;
font-family:Tahoma,Verdana,sans-serif}main{max-width:520px;padding:32px;border-radius:14px;background:#163f4f;
border:3px solid #6fc3d6;text-align:center}h1{color:$color;margin:0 0 12px;font-size:28px}p{font-size:18px;line-height:1.5}</style>
</head><body><main><h1>$t</h1><p>$x</p></main></body></html>
HTML;
    exit;
}

function http_json(string $method, string $url, array $headers, ?string $body = null): ?array
{
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 15,
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_HTTPHEADER => $headers,
    ]);
    if ($body !== null) {
        curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
    }
    $res = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    if ($res === false || $code < 200 || $code >= 300) {
        error_log("ranked discord: $method $url -> $code");
        return null;
    }
    $j = json_decode($res, true);
    return is_array($j) ? $j : null;
}

try {
    $c = cfg();
    $db = db();
    $login = arg('state', '');
    $st = $db->prepare('SELECT * FROM logins WHERE id = ?');
    $st->execute([$login]);
    $l = $st->fetch();
    if (!$l || now() - (int)$l['created'] > LOGIN_TIMEOUT) {
        page('Login expired', 'Start the Discord login again from the game.', false);
    }
    $fail = function (string $why, string $text) use ($db, $login): never {
        $db->prepare('UPDATE logins SET error = ? WHERE id = ?')->execute([$why, $login]);
        page('Login failed', $text, false);
    };
    if (arg('error')) {
        $fail('denied', 'Discord login was cancelled. You can try again from the game.');
    }
    $code = arg('code', '');
    if ($code === '') {
        $fail('no_code', 'Discord did not send a login code. Try again from the game.');
    }
    $api = rtrim($c['discord_api'] ?? 'https://discord.com/api', '/');
    $tok = http_json('POST', "$api/oauth2/token", ['Content-Type: application/x-www-form-urlencoded'],
        http_build_query([
            'client_id' => $c['discord_client_id'],
            'client_secret' => $c['discord_client_secret'],
            'grant_type' => 'authorization_code',
            'code' => $code,
            'redirect_uri' => $c['discord_redirect'],
        ]));
    if (!$tok || empty($tok['access_token'])) {
        $fail('token_exchange', 'Discord did not accept the login (check the Client Secret and Redirect on the server).');
    }
    $me = http_json('GET', "$api/users/@me", ['Authorization: Bearer ' . $tok['access_token']]);
    if (!$me || empty($me['id'])) {
        $fail('no_identity', 'Could not read your Discord account. Try again from the game.');
    }
    $discord_id = (string)$me['id'];
    $name = trim((string)($me['global_name'] ?? '')) ?: (string)($me['username'] ?? 'Player');
    $name = mb_substr($name, 0, 32);
    $avatar = isset($me['avatar']) ? (string)$me['avatar'] : null;

    $st = $db->prepare('SELECT id FROM players WHERE discord_id = ?');
    $st->execute([$discord_id]);
    $pid = $st->fetchColumn();
    if ($pid) {
        $db->prepare('UPDATE players SET name = ?, avatar = ?, last_seen = ? WHERE id = ?')
            ->execute([$name, $avatar, now(), $pid]);
    } else {
        $db->prepare('INSERT INTO players (discord_id, name, avatar, created, last_seen) VALUES (?, ?, ?, ?, ?)')
            ->execute([$discord_id, $name, $avatar, now(), now()]);
        $pid = $db->lastInsertId();
    }
    $db->prepare('UPDATE logins SET player_id = ? WHERE id = ?')->execute([(int)$pid, $login]);
    page("Logged in as $name", 'You can close this tab and go back to the game.', true);
} catch (Throwable $e) {
    error_log('ranked discord: ' . $e->getMessage());
    page('Login failed', 'Something went wrong on the ranked server. Try again later.', false);
}
