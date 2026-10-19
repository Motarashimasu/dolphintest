<?php
// A player's profile picture (account.php > picture): pic.php?id=<player>&v=<version>.
// The version changes with every new picture, so it can be cached for long.
require __DIR__ . '/lib.php';

$id = (int)($_GET['id'] ?? 0);
$path = $id > 0 ? pic_path($id) : '';
if ($path === '' || !is_file($path)) {
    http_response_code(404);
    header('Content-Type: text/plain');
    echo 'no picture';
    exit;
}
header('Content-Type: image/png');
header('Content-Length: ' . filesize($path));
header('Cache-Control: public, max-age=31536000, immutable');
header('X-Content-Type-Options: nosniff');
readfile($path);
