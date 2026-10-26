<?php
// Automatic updates for the launcher: download links into the Cloudflare R2 bucket the release
// script (Tools/sparking_release.py) uploads to. Only logged-in DRAGON NET players get links,
// and each link works for a few minutes, so the files can't be passed around or listed.
//
// The bucket holds:
//   <prefix>manifest.json      {"manifest": <base64 JSON>, "signature": <base64 RSA-SHA256>}:
//                              every file of the build (path, size, sha256), signed with the
//                              release key (the launcher checks the signature itself)
//   <prefix>files/<sha256>     each file, named by its own SHA-256 (old builds' files stay
//                              until the release script prunes them)
// This server never reads the bucket: it only signs links (AWS Signature Version 4, which R2
// speaks) with a read-only R2 token from config.php. The launcher downloads from Cloudflare.
//
//   GET/POST update.php?action=check[&platform=linux] -> {"ok", "manifest_url", "expires"}
//            (each platform has its own list: manifest.json = Windows, manifest-linux.json = Linux)
//   POST     update.php?action=files  {"files": [<sha256>, ...]} (at most 400)
//                                                    -> {"ok", "urls": {<sha256>: <url>}, "expires"}
// Both need the X-Sparking-Token header (banned players still get updates).
require __DIR__ . '/lib.php';

const UPDATE_LINK_SECONDS = 900;    // a link works this long (a download that started goes on)
const UPDATE_FILES_MAX = 400;
const UPDATE_PLATFORMS = ['windows' => 'manifest.json', 'linux' => 'manifest-linux.json'];

/** The R2 settings from config.php, or a 503 when updates aren't set up. */
function r2(): array
{
    return r2_settings() ?? fail('updates_not_set_up', 503);
}

if (PHP_SAPI === 'cli' && realpath($_SERVER['SCRIPT_FILENAME'] ?? '') !== __FILE__) {
    return;   // included by a test: only the functions above
}

guard(function () {
    auth(true);
    $r2 = r2();
    $expires = time() + UPDATE_LINK_SECONDS;
    switch (arg('action', 'check')) {
        case 'check':
            $platform = arg('platform', 'windows');
            if (!isset(UPDATE_PLATFORMS[$platform])) {
                fail('bad_platform');
            }
            out(['ok' => true, 'expires' => $expires, 'platform' => $platform,
                 'manifest_url' => presign($r2, $r2['prefix'] . UPDATE_PLATFORMS[$platform], UPDATE_LINK_SECONDS)]);
        case 'files':
            $files = input()['files'] ?? null;
            if (!is_array($files) || count($files) > UPDATE_FILES_MAX) {
                fail('bad_files');
            }
            $urls = [];
            foreach ($files as $sha) {
                if (!is_string($sha) || !preg_match('/^[0-9a-f]{64}$/', $sha)) {
                    fail('bad_files');
                }
                $urls[$sha] = presign($r2, $r2['prefix'] . 'files/' . $sha, UPDATE_LINK_SECONDS);
            }
            out(['ok' => true, 'expires' => $expires, 'urls' => $urls]);
        default:
            fail('bad_action');
    }
});
