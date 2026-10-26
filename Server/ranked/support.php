<?php
// Support and feedback: anyone can send the team a message (a bug, an account problem, the game
// copy, online play, an idea). The admin reads and answers them in admin.php > Support; a
// logged-in player sees their messages and the answers here. Limited per visitor (no spam).
require_once __DIR__ . '/site.php';

const SUPPORT_TOPICS = ['bug' => 'Something doesn\'t work (bug)', 'account' => 'DRAGON NET account / login',
                        'disc' => 'Game copy / disc check', 'online' => 'Online play, lobbies, ranked',
                        'idea' => 'Suggestion / feedback', 'other' => 'Something else'];
const SUPPORT_MAX = 4000;
const SUPPORT_PER_HOUR = 5;

$db = db();
$u = web_user();
$sent = 0;
$error = '';
$f = ['topic' => 'bug', 'name' => $u ? (string)$u['name'] : '', 'contact' => '', 'body' => ''];

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    foreach ($f as $k => $v) {
        $f[$k] = trim(str_replace("\r\n", "\n", (string)($_POST[$k] ?? $v)));
    }
    if (!csrf_ok()) {
        $error = 'That form expired: send it again.';
    } elseif (!isset(SUPPORT_TOPICS[$f['topic']])) {
        $error = 'Pick what it\'s about.';
    } elseif (mb_strlen($f['body']) < 10 || mb_strlen($f['body']) > SUPPORT_MAX) {
        $error = 'Tell us a bit more (10 to ' . SUPPORT_MAX . ' characters).';
    } elseif (trim((string)($_POST['website'] ?? '')) !== '') {
        $error = 'Sent.';   // (the hidden field only robots fill in)
    } elseif (!rate_ok('support:' . ip_hash(), SUPPORT_PER_HOUR, 3600)
            || ($u && !rate_ok('support-u:' . $u['id'], SUPPORT_PER_HOUR, 3600))) {
        $error = 'You\'ve sent several messages already: wait an hour, or post on the board.';
    } else {
        $name = mb_substr($f['name'] !== '' ? $f['name'] : 'Anonymous', 0, 64);
        $db->prepare("INSERT INTO support (created, player_id, name, contact, topic, body, state, ip_hash)
                      VALUES (?, ?, ?, ?, ?, ?, 'open', ?)")
            ->execute([now(), $u ? (int)$u['id'] : null, $name, mb_substr($f['contact'], 0, 128), $f['topic'],
                       $f['body'], ip_hash()]);
        $sent = (int)$db->lastInsertId();
        $f['body'] = '';
    }
}

$opts = '';
foreach (SUPPORT_TOPICS as $k => $v) {
    $opts .= "<option value='$k'" . ($f['topic'] === $k ? ' selected' : '') . '>' . h($v) . '</option>';
}
$body = '<h1>Support & feedback</h1>'
    . ($sent ? "<p class=flash>Thanks! Your message is #$sent. " . ($u ? 'The answer shows up below.' : 'We answer where you said we can reach you.') . '</p>' : '')
    . ($error !== '' ? '<p class=err>' . h($error) . '</p>' : '')
    . '<div class=cols><form method=post class=box>' . csrf_field()
    . '<label for=to style="margin-top:0">What is it about?</label><select id=to name=topic>' . $opts . '</select>'
    . '<label for=bo>Your message</label><textarea id=bo name=body maxlength=' . SUPPORT_MAX . ' required placeholder="What happened, what you expected, and what you tried. For game copy problems, paste the launcher\'s Copy details.">'
    . h($f['body']) . '</textarea>'
    . '<label for=na>Your name</label><input id=na name=name maxlength=64 value="' . h($f['name']) . '" style="width:100%">'
    . '<label for=co>How can we reach you? <span class=small>(optional: Discord name or email)</span></label>'
    . '<input id=co name=contact maxlength=128 value="' . h($f['contact']) . '" style="width:100%">'
    . '<div style="position:absolute;left:-9999px" aria-hidden=true><input name=website tabindex=-1 autocomplete=off></div>'
    . '<p style="margin-bottom:0"><button type=submit>Send</button></p></form>'
    . '<aside><div class=box><h3>Before you send</h3><ul class=tips>'
    . '<li><b>Disc refused?</b> Use the launcher\'s <i>Copy details</i> and paste it in your message.</li>'
    . '<li><b>Game closed or froze?</b> Say which version and mode, and what you did just before.</li>'
    . '<li><b>Forgot your password?</b> Log in isn\'t needed: give your DRAGON NET username and how to reach you.</li>'
    . '<li><b>Ideas and questions</b> other players could answer: the <a href="board.php">board</a> is quicker.</li>'
    . '</ul></div></aside></div>';

if ($u) {
    $st = $db->prepare('SELECT * FROM support WHERE player_id = ? ORDER BY id DESC LIMIT 20');
    $st->execute([(int)$u['id']]);
    $mine = '';
    foreach ($st->fetchAll() as $t) {
        $state = $t['state'] === 'closed' ? '<span class="pill on">answered</span>' : '<span class=pill>open</span>';
        $mine .= "<article class=box><div class=row style='justify-content:space-between'><b>#{$t['id']} · "
            . h(SUPPORT_TOPICS[$t['topic']] ?? $t['topic']) . "</b>$state</div><p class='small muted'>" . h(ago((int)$t['created'])) . '</p>'
            . '<div>' . format_text((string)$t['body']) . '</div>'
            . ((string)($t['reply'] ?? '') !== '' ? '<div class=reply><b>Answer</b> <span class="small muted">'
                . h(ago((int)$t['replied'])) . '</span><div>' . format_text((string)$t['reply']) . '</div></div>' : '')
            . '</article>';
    }
    if ($mine !== '') {
        $body .= '<h2>Your messages</h2>' . $mine;
    }
}
$style = '.cols{display:grid;grid-template-columns:3fr 2fr;gap:14px;align-items:start}.tips{padding-left:18px;margin:8px 0 0}'
    . '.tips li{margin:6px 0}.reply{margin-top:12px;border-left:4px solid var(--good);padding:6px 12px;background:var(--panel2);border-radius:6px}'
    . '@media (max-width:760px){.cols{grid-template-columns:1fr}}';
site_page('Support', 'support.php', $body, $style);
