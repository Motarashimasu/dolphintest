<?php
// The launcher's notification bars (red / blue / yellow) in the player's language.
// Text: notices_text.php (copy of notices_text.example.php). Yellow also gets automatic player
// news: players newly reaching the global Top 5 of a mode (shown for 24 hours).
require __DIR__ . '/lib.php';

const NOTICE_LANGS = ['en', 'es', 'it'];
const TOP5_NEWS = [
    'en' => '%s reached the global Top 5 in %s!',
    'es' => '¡%s ha entrado en el Top 5 mundial de %s!',
    'it' => '%s è entrato nella Top 5 mondiale di %s!',
];
const MODE_NAMES = [
    'single' => ['en' => 'Single Battle FT2', 'es' => 'Combate individual FT2', 'it' => 'Battaglia singola FT2'],
    'team' => ['en' => 'Team Battle', 'es' => 'Combate por equipos', 'it' => 'Battaglia a squadre'],
];
const NEWS_HOURS = 24;

// Players newly in a mode's global Top 5 since the last check -> yellow news.
function top5_news(): array
{
    $news = json_decode(meta_get('top5_news', '[]'), true) ?: [];
    foreach (MODES as $mode) {
        $ids = [];
        $names = [];
        foreach (leaderboard($mode, 'global', 5) as $r) {
            $ids[] = $r['id'];
            $names[$r['id']] = $r['name'];
        }
        $before = json_decode(meta_get("top5_$mode", 'null'), true);
        if (is_array($before)) {   // (the first check only remembers: no news for everyone)
            foreach (array_diff($ids, $before) as $id) {
                $news[] = ['mode' => $mode, 'name' => $names[$id], 't' => now()];
            }
        }
        meta_set("top5_$mode", json_encode($ids));
    }
    $news = array_values(array_filter($news, fn($n) => now() - (int)$n['t'] < NEWS_HOURS * 3600));
    $news = array_slice($news, -5);
    meta_set('top5_news', json_encode($news));
    return $news;
}

guard(function () {
    $lang = arg('lang', 'en');
    if (!in_array($lang, NOTICE_LANGS, true)) {
        $lang = 'en';
    }
    $file = is_file(__DIR__ . '/notices_text.php') ? '/notices_text.php' : '/notices_text.example.php';
    $text = require __DIR__ . $file;
    $pick = function (string $bar) use ($text, $lang): string {
        $lines = is_array($text[$bar] ?? null) ? $text[$bar] : [];
        $line = trim((string)($lines[$lang] ?? ''));
        return $line !== '' ? $line : trim((string)($lines['en'] ?? ''));
    };
    $notices = ['red' => $pick('red'), 'blue' => $pick('blue'), 'yellow' => $pick('yellow')];
    $yellow = $notices['yellow'] !== '' ? [$notices['yellow']] : [];
    foreach (top5_news() as $n) {
        $mode = MODE_NAMES[$n['mode']][$lang] ?? $n['mode'];
        $yellow[] = sprintf(TOP5_NEWS[$lang], $n['name'], $mode);
    }
    $notices['yellow'] = implode('     ✦     ', $yellow);
    out(['ok' => true, 'lang' => $lang, 'notices' => $notices]);
});
