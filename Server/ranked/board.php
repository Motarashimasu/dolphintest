<?php
// The message board. Everyone can read; DRAGON NET players (logged in, not suspended) can start
// topics and reply, and delete their own posts. The admin pins, locks and deletes (admin.php >
// Board). Plain text: line breaks and links are kept, nothing else.
//   board.php            topics (pinned first, then the latest replies)
//   board.php?t=<id>     a topic and its posts
//   board.php?new=1      start a topic
require_once __DIR__ . '/site.php';

const BOARD_PAGE = 30;
const TITLE_MAX = 120;
const BODY_MAX = 5000;
const POST_GAP = 20;        // s between two posts of one player
const POSTS_PER_DAY = 60;

$db = db();
$u = web_user();
$can_post = $u && !(int)$u['banned'] && (string)($u['username'] ?? '') !== '';

function topic(int $id): ?array
{
    $st = db()->prepare('SELECT * FROM board_topics WHERE id = ? AND deleted = 0');
    $st->execute([$id]);
    return $st->fetch() ?: null;
}

/** Why `$u` can't post right now, or ''. */
function post_limit(array $u): string
{
    if (!rate_ok('post-gap:' . $u['id'], 1, POST_GAP)) {
        return 'Slow down a little: one post every ' . POST_GAP . ' seconds.';
    }
    if (!rate_ok('post-day:' . $u['id'], POSTS_PER_DAY, 86400)) {
        return "That's a lot of posts for one day: try again tomorrow.";
    }
    return '';
}

function names_of(array $ids): array
{
    $out = [];
    $ids = array_values(array_unique(array_map('intval', $ids)));
    if ($ids) {
        $in = implode(',', $ids);
        foreach (db()->query("SELECT * FROM players WHERE id IN ($in)")->fetchAll() as $r) {
            $out[(int)$r['id']] = $r;
        }
    }
    return $out;
}

// --- Posting -------------------------------------------------------------------------------
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $back = 'board.php' . (isset($_POST['t']) ? '?t=' . (int)$_POST['t'] : '');
    if (!csrf_ok()) {
        go($back, 'That form expired: try again.');
    }
    if (!$u) {
        go('login.php?next=board.php', 'Log in with your DRAGON NET account to post.');
    }
    if (!$can_post) {
        go($back, (int)$u['banned'] ? 'Suspended players can\'t post.' : 'Finish your DRAGON NET account in the launcher first.');
    }
    $a = (string)($_POST['a'] ?? '');
    $body = trim(str_replace("\r\n", "\n", (string)($_POST['body'] ?? '')));
    if ($a === 'new') {
        $title = trim(preg_replace('/\s+/u', ' ', (string)($_POST['title'] ?? '')));
        if (mb_strlen($title) < 3 || mb_strlen($title) > TITLE_MAX) {
            go('board.php?new=1', 'The title needs 3 to ' . TITLE_MAX . ' characters.');
        }
        if ($body === '' || mb_strlen($body) > BODY_MAX) {
            go('board.php?new=1', 'Write something (at most ' . BODY_MAX . ' characters).');
        }
        if (($why = post_limit($u)) !== '') {
            go('board.php?new=1', $why);
        }
        $t = now();
        $db->prepare('INSERT INTO board_topics (title, author, created, last_post, last_author) VALUES (?, ?, ?, ?, ?)')
            ->execute([$title, $u['id'], $t, $t, $u['id']]);
        $tid = (int)$db->lastInsertId();
        $db->prepare('INSERT INTO board_posts (topic_id, author, body, created) VALUES (?, ?, ?, ?)')
            ->execute([$tid, $u['id'], $body, $t]);
        go("board.php?t=$tid", 'Topic posted.');
    }
    if ($a === 'reply') {
        $topic = topic((int)($_POST['t'] ?? 0));
        if (!$topic) {
            go('board.php', 'That topic is gone.');
        }
        if ((int)$topic['locked']) {
            go("board.php?t={$topic['id']}", 'That topic is locked.');
        }
        if ($body === '' || mb_strlen($body) > BODY_MAX) {
            go("board.php?t={$topic['id']}", 'Write something (at most ' . BODY_MAX . ' characters).');
        }
        if (($why = post_limit($u)) !== '') {
            go("board.php?t={$topic['id']}", $why);
        }
        $t = now();
        $db->prepare('INSERT INTO board_posts (topic_id, author, body, created) VALUES (?, ?, ?, ?)')
            ->execute([$topic['id'], $u['id'], $body, $t]);
        $pid = (int)$db->lastInsertId();
        $db->prepare('UPDATE board_topics SET last_post = ?, last_author = ?, replies = replies + 1 WHERE id = ?')
            ->execute([$t, $u['id'], $topic['id']]);
        $st = $db->prepare('SELECT COUNT(*) FROM board_posts WHERE topic_id = ? AND deleted = 0');
        $st->execute([$topic['id']]);
        $page = (int)ceil((int)$st->fetchColumn() / BOARD_PAGE);
        go("board.php?t={$topic['id']}&page=$page#p$pid");
    }
    if ($a === 'delete') {
        $st = $db->prepare('SELECT * FROM board_posts WHERE id = ? AND deleted = 0');
        $st->execute([(int)($_POST['post'] ?? 0)]);
        $post = $st->fetch();
        if (!$post || (int)$post['author'] !== (int)$u['id']) {
            go($back, 'You can only delete your own posts.');
        }
        $db->prepare('UPDATE board_posts SET deleted = 1 WHERE id = ?')->execute([$post['id']]);
        // The topic's first post: the whole topic goes.
        $st = $db->prepare('SELECT MIN(id) FROM board_posts WHERE topic_id = ?');
        $st->execute([$post['topic_id']]);
        if ((int)$st->fetchColumn() === (int)$post['id']) {
            $db->prepare('UPDATE board_topics SET deleted = 1 WHERE id = ?')->execute([$post['topic_id']]);
            go('board.php', 'Topic deleted.');
        }
        $db->prepare('UPDATE board_topics SET replies = CASE WHEN replies > 0 THEN replies - 1 ELSE 0 END WHERE id = ?')->execute([$post['topic_id']]);
        go("board.php?t={$post['topic_id']}", 'Post deleted.');
    }
    go('board.php');
}

$hint = $u ? ($can_post ? '' : '<p class=muted>' . ((int)$u['banned'] ? 'Suspended players can read the board but not post.'
        : 'Finish your DRAGON NET account in the launcher (DRAGON NET > Profile) to post.') . '</p>')
    : '<p class=muted><a href="login.php?next=board.php">Log in</a> with your DRAGON NET account to post.</p>';

// --- A new topic ---------------------------------------------------------------------------
if (isset($_GET['new'])) {
    if (!$can_post) {
        site_page('Board', 'board.php', '<h1>New topic</h1>' . $hint);
    }
    $body = '<h1>New topic</h1><form method=post class=box>' . csrf_field() . '<input type=hidden name=a value=new>'
        . '<label for=ti style="margin-top:0">Title</label><input id=ti name=title maxlength=' . TITLE_MAX . ' required style="width:100%">'
        . '<label for=bo>Message</label><textarea id=bo name=body maxlength=' . BODY_MAX . ' required></textarea>'
        . '<p style="margin-bottom:0" class=row><button type=submit>Post topic</button><a href="board.php">Cancel</a></p></form>'
        . '<p class="small muted">Be decent: no game files or download links for them, no personal attacks. Posts that break that are removed.</p>';
    site_page('New topic', 'board.php', $body);
}

// --- A topic -------------------------------------------------------------------------------
if (isset($_GET['t'])) {
    $topic = topic((int)$_GET['t']);
    if (!$topic) {
        site_page('Board', 'board.php', '<h1>Board</h1><div class=box><p class=muted style="margin:0">That topic is gone. '
            . '<a href="board.php">Back to the board</a>.</p></div>');
    }
    $tid = (int)$topic['id'];
    $st = $db->prepare('SELECT COUNT(*) FROM board_posts WHERE topic_id = ? AND deleted = 0');
    $st->execute([$tid]);
    $pages = max(1, (int)ceil((int)$st->fetchColumn() / BOARD_PAGE));
    $page = max(1, min($pages, (int)($_GET['page'] ?? 1)));
    $st = $db->prepare('SELECT * FROM board_posts WHERE topic_id = ? AND deleted = 0 ORDER BY id LIMIT ' . BOARD_PAGE
        . ' OFFSET ' . (($page - 1) * BOARD_PAGE));
    $st->execute([$tid]);
    $posts = $st->fetchAll();
    $who = names_of(array_column($posts, 'author'));
    $html = '';
    foreach ($posts as $post) {
        $a = $who[(int)$post['author']] ?? ['id' => 0, 'name' => '?'];
        $own = $u && (int)$u['id'] === (int)$post['author'];
        $html .= "<article class=post id=p{$post['id']}><div class=who>" . avatar_html($a, 44)
            . '<div>' . player_link((int)$a['id'], (string)$a['name']) . '<br><span class="small muted">' . h(ago((int)$post['created'])) . '</span></div>'
            . ($own ? '<form method=post style="margin-left:auto">' . csrf_field()
                . "<input type=hidden name=t value=$tid><input type=hidden name=post value={$post['id']}>"
                . '<button class=link name=a value=delete>Delete</button></form>' : '')
            . '</div><div class=text>' . format_text((string)$post['body']) . '</div></article>';
    }
    $reply = '';
    if ((int)$topic['locked']) {
        $reply = '<p class=muted>🔒 This topic is locked.</p>';
    } elseif ($can_post) {
        $reply = '<form method=post class=box>' . csrf_field() . "<input type=hidden name=a value=reply><input type=hidden name=t value=$tid>"
            . '<label for=bo style="margin-top:0">Reply</label><textarea id=bo name=body maxlength=' . BODY_MAX . ' required></textarea>'
            . '<p style="margin-bottom:0"><button type=submit>Post reply</button></p></form>';
    } else {
        $reply = $hint;
    }
    $body = '<p class=small><a href="board.php">← Board</a></p><h1 style="font-size:32px">' . ((int)$topic['pinned'] ? '📌 ' : '')
        . h($topic['title']) . '</h1>' . pager("board.php?t=$tid", $page, $pages) . $html . pager("board.php?t=$tid", $page, $pages) . $reply;
    $style = '.post{background:var(--panel);border:3px solid var(--line);border-radius:12px;padding:14px 16px;margin:12px 0}'
        . '.post .who{display:flex;gap:12px;align-items:center;margin-bottom:10px}.post .text{overflow-wrap:anywhere}';
    site_page((string)$topic['title'], 'board.php', $body, $style);
}

// --- The topics ----------------------------------------------------------------------------
$total = (int)$db->query('SELECT COUNT(*) FROM board_topics WHERE deleted = 0')->fetchColumn();
$pages = max(1, (int)ceil($total / BOARD_PAGE));
$page = max(1, min($pages, (int)($_GET['page'] ?? 1)));
$topics = $db->query('SELECT * FROM board_topics WHERE deleted = 0 ORDER BY pinned DESC, last_post DESC LIMIT ' . BOARD_PAGE
    . ' OFFSET ' . (($page - 1) * BOARD_PAGE))->fetchAll();
$who = names_of(array_merge(array_column($topics, 'author'), array_column($topics, 'last_author')));
$rows = '';
foreach ($topics as $t) {
    $by = $who[(int)$t['author']]['name'] ?? '?';
    $last = $who[(int)$t['last_author']]['name'] ?? '?';
    $rows .= "<tr><td><a class=pl href='board.php?t={$t['id']}'>" . ((int)$t['pinned'] ? '📌 ' : '') . ((int)$t['locked'] ? '🔒 ' : '')
        . h($t['title']) . '</a><br><span class="small muted">by ' . h($by) . '</span></td>'
        . "<td class='n hide-s'>{$t['replies']}</td><td class=small>" . h($last) . '<br><span class=muted>' . h(ago((int)$t['last_post'])) . '</span></td></tr>';
}
$body = '<div class=row style="justify-content:space-between"><h1>Board</h1>'
    . ($can_post ? '<a class=btn href="board.php?new=1">New topic</a>' : '') . '</div>' . $hint
    . ($rows === '' ? '<div class=box><p class=muted style="margin:0">Nothing posted yet.</p></div>'
        : "<table><thead><tr><th>Topic</th><th class='n hide-s'>Replies</th><th>Latest</th></tr></thead><tbody>$rows</tbody></table>")
    . pager('board.php', $page, $pages);
site_page('Board', 'board.php', $body);
