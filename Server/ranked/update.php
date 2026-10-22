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
    $c = cfg();
    foreach (['r2_account_id', 'r2_access_key', 'r2_secret_key', 'r2_bucket'] as $k) {
        if (trim((string)($c[$k] ?? '')) === '') {
            fail('updates_not_set_up', 503);
        }
    }
    $endpoint = rtrim((string)($c['r2_endpoint'] ?? ''), '/');   // tests: a local S3 stand-in
    if ($endpoint === '') {
        $endpoint = 'https://' . $c['r2_account_id'] . '.r2.cloudflarestorage.com';
    }
    $prefix = trim((string)($c['update_prefix'] ?? ''), '/');
    return ['endpoint' => $endpoint, 'bucket' => (string)$c['r2_bucket'],
            'key' => (string)$c['r2_access_key'], 'secret' => (string)$c['r2_secret_key'],
            'prefix' => $prefix === '' ? '' : $prefix . '/'];
}

/** A presigned GET link for one object (SigV4, query string, region "auto", path style).
 *  ($region and an empty bucket = virtual-host style are only for the AWS test vectors.) */
function presign(array $r2, string $object, int $seconds, ?int $at = null, string $region = 'auto'): string
{
    $at = $at ?? time();
    $date = gmdate('Ymd', $at);
    $stamp = gmdate('Ymd\THis\Z', $at);
    $parts = parse_url($r2['endpoint']);
    $host = $parts['host'] . (isset($parts['port']) ? ':' . $parts['port'] : '');
    $base = rtrim($parts['path'] ?? '', '/');
    $path = $base . ($r2['bucket'] === '' ? '' : '/' . rawurlencode($r2['bucket'])) . '/'
        . implode('/', array_map('rawurlencode', explode('/', $object)));
    $scope = "$date/$region/s3/aws4_request";
    $query = [
        'X-Amz-Algorithm' => 'AWS4-HMAC-SHA256',
        'X-Amz-Credential' => $r2['key'] . '/' . $scope,
        'X-Amz-Date' => $stamp,
        'X-Amz-Expires' => (string)$seconds,
        'X-Amz-SignedHeaders' => 'host',
    ];
    ksort($query, SORT_STRING);
    $qs = implode('&', array_map(fn($k, $v) => rawurlencode($k) . '=' . rawurlencode($v),
                                 array_keys($query), $query));
    $canonical = "GET\n$path\n$qs\nhost:$host\n\nhost\nUNSIGNED-PAYLOAD";
    $to_sign = "AWS4-HMAC-SHA256\n$stamp\n$scope\n" . hash('sha256', $canonical);
    $k = hash_hmac('sha256', $date, 'AWS4' . $r2['secret'], true);
    $k = hash_hmac('sha256', $region, $k, true);
    $k = hash_hmac('sha256', 's3', $k, true);
    $k = hash_hmac('sha256', 'aws4_request', $k, true);
    $sig = hash_hmac('sha256', $to_sign, $k);
    return $parts['scheme'] . '://' . $host . $path . '?' . $qs . '&X-Amz-Signature=' . $sig;
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
