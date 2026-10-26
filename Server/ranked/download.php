<?php
// The front page's downloads: download.php?i=0..2 (config.php "downloads"). Each one is a link
// ("url") or a file in the Cloudflare R2 bucket ("r2": its name in the bucket; a link that
// works for 10 minutes is made for each click, so the bucket stays private). Counted in meta.
require_once __DIR__ . '/lib.php';

$i = (int)($_GET['i'] ?? -1);
$d = cfg()['downloads'][$i] ?? null;
$to = '';
if (is_array($d)) {
    if (trim((string)($d['url'] ?? '')) !== '' && preg_match('~^https?://~i', (string)$d['url'])) {
        $to = (string)$d['url'];
    } elseif (trim((string)($d['r2'] ?? '')) !== '' && ($r2 = r2_settings())) {
        $to = presign($r2, ltrim((string)$d['r2'], '/'), 600);
    }
}
if ($to === '') {
    header('Location: index.php', true, 303);
    exit;
}
try {
    $k = "downloads_$i";
    meta_set($k, (string)((int)meta_get($k, '0') + 1));
} catch (Throwable $e) {
    error_log('site download count: ' . $e->getMessage());
}
header('Cache-Control: no-store');
header('Location: ' . $to, true, 302);
