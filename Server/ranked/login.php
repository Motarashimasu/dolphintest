<?php
// Logging in to the website with a DRAGON NET account (the same username and password as in the
// launcher; accounts are made in the launcher: DRAGON NET > Profile). Log out: POST a=logout.
require_once __DIR__ . '/site.php';

$next = (string)($_GET['next'] ?? $_POST['next'] ?? 'index.php');
if (!preg_match('~^[a-z_]+\.php(\?[A-Za-z0-9_=&%.\-]*)?$~', $next) || $next === 'login.php') {
    $next = 'index.php';
}
$error = '';
$name = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!csrf_ok()) {
        go('login.php', 'That form expired: try again.');
    }
    if (($_POST['a'] ?? '') === 'logout') {
        unset($_SESSION['uid'], $_SESSION['pass']);
        session_regenerate_id(true);
        go('index.php', 'Logged out.');
    }
    $name = trim((string)($_POST['username'] ?? ''));
    $pass = (string)($_POST['password'] ?? '');
    $key = 'u:' . strtolower(substr($name, 0, 40));
    try {
        if (!rate_ok('login:' . ip_hash(), 30, 600)) {
            $error = 'Too many tries from here: wait 10 minutes.';
        } elseif (too_many_fails($key)) {
            $error = 'Too many wrong passwords: wait 5 minutes and try again.';
        } else {
            $p = $name !== '' ? find_by_username($name) : null;
            if (!$p || !$p['pass_hash'] || !password_verify($pass, $p['pass_hash'])) {
                note_fail($key);
                $error = 'Wrong username or password.';
            } else {
                db()->prepare('DELETE FROM login_fails WHERE k = ?')->execute([$key]);
                web_login($p);
                go($next, 'Logged in as ' . $p['name'] . '.');
            }
        }
    } catch (Throwable $e) {
        error_log('site login: ' . $e->getMessage());
        $error = 'The server had a problem. Try again in a moment.';
    }
}
if (web_user()) {
    go($next);
}
$body = '<h1>Log in</h1><div class=box style="max-width:460px">'
    . ($error !== '' ? '<p class=err style="margin-top:0">' . h($error) . '</p>' : '')
    . '<form method=post>' . csrf_field() . "<input type=hidden name=next value='" . h($next) . "'>"
    . "<label for=u style='margin-top:0'>DRAGON NET username</label><input id=u name=username value='" . h($name)
    . "' autocomplete=username required maxlength=24 style='width:100%'>"
    . '<label for=p>Password</label><input id=p type=password name=password autocomplete=current-password required style="width:100%">'
    . '<p><button type=submit>Log in</button></p></form>'
    . '<p class="muted small" style="margin-bottom:0">No account yet? Make one in the launcher: DRAGON NET &gt; Profile.'
    . ' Forgot your password? Ask on the <a href="support.php">support page</a>.</p></div>';
site_page('Log in', '', $body);
