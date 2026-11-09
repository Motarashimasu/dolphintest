<?php
// The website's background picture (admin.php > Website): sitebg.php?v=<version>.
// The version changes with every new picture, so it can be cached for long.
require __DIR__ . '/lib.php';

$look = site_look();
$path = $look['bg'] !== '' ? pic_dir() . '/' . $look['bg'] : '';
if ($path === '' || !is_file($path)) {
    http_response_code(404);
    header('Content-Type: text/plain');
    echo 'no background';
    exit;
}
$types = ['jpg' => 'image/jpeg', 'png' => 'image/png', 'webp' => 'image/webp'];
header('Content-Type: ' . $types[pathinfo($path, PATHINFO_EXTENSION)]);
header('Content-Length: ' . filesize($path));
header('Cache-Control: public, max-age=31536000, immutable');
header('X-Content-Type-Options: nosniff');
readfile($path);
