<?php
// The leaderboard as a web page (same data as leaderboard.php).
require __DIR__ . '/lib.php';

$modes = ['single' => 'Single Battle (FT2)', 'team' => 'Team Battle', 'all' => 'All-time record'];
$region_names = ['global' => 'Global', 'NA' => 'North America', 'SA' => 'South America',
                 'EU' => 'Europe', 'AF' => 'Africa', 'EA' => 'East Asia', 'CN' => 'China',
                 'OC' => 'Oceania'];
$mode = $_GET['mode'] ?? 'single';
$mode = isset($modes[$mode]) ? $mode : 'single';
$region = strtoupper($_GET['region'] ?? 'global');
$region = $region === 'GLOBAL' || !isset($region_names[$region]) ? 'global' : $region;
try {
    settle_due();
    $rows = leaderboard($mode, $region, 100);
    $error = '';
} catch (Throwable $e) {
    error_log('ranked index: ' . $e->getMessage());
    $rows = [];
    $error = 'The leaderboard is unavailable right now.';
}
$h = fn($s) => htmlspecialchars((string)$s, ENT_QUOTES);
header('Content-Type: text/html; charset=utf-8');
?><!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>DRAGON NET Ranked Leaderboard</title>
<style>
:root{--bg:#0f2a35;--panel:#163f4f;--line:#6fc3d6;--gold:#f2b531;--text:#fff;--muted:#a9cbd6}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:Tahoma,Verdana,sans-serif}
main{max-width:860px;margin:0 auto;padding:24px 16px}
h1{font-family:Impact,Haettenschweiler,sans-serif;font-weight:normal;letter-spacing:1px;color:#ff8a1f;
   text-shadow:3px 3px 0 #6b1d0b;font-size:44px;margin:8px 0 18px}
form{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:16px}
select,button{font:inherit;font-size:16px;padding:8px 12px;border-radius:8px;border:2px solid var(--line);
   background:var(--panel);color:var(--text)}button{background:var(--gold);color:#1b1b1b;border-color:var(--gold);cursor:pointer}
table{width:100%;border-collapse:collapse;background:var(--panel);border:3px solid var(--line);border-radius:12px;overflow:hidden}
th,td{padding:10px 12px;text-align:left}th{color:var(--gold);border-bottom:2px solid var(--line)}
tr:nth-child(even) td{background:rgba(0,0,0,.15)}td.n{text-align:right;font-variant-numeric:tabular-nums}
.rank{width:56px;color:var(--muted)}tr.top td.rank{color:var(--gold);font-weight:bold}
.empty,.err{color:var(--muted);padding:24px;text-align:center}.err{color:#e8663d}
</style></head><body><main>
<h1>DRAGON NET Ranked</h1>
<form method="get">
  <select name="mode" aria-label="Mode">
    <?php foreach ($modes as $k => $v): ?><option value="<?= $h($k) ?>"<?= $k === $mode ? ' selected' : '' ?>><?= $h($v) ?></option><?php endforeach ?>
  </select>
  <select name="region" aria-label="Region">
    <?php foreach ($region_names as $k => $v): ?><option value="<?= $h($k) ?>"<?= $k === $region ? ' selected' : '' ?>><?= $h($v) ?></option><?php endforeach ?>
  </select>
  <button type="submit">Show</button>
</form>
<?php if ($error): ?><p class="err"><?= $h($error) ?></p><?php elseif (!$rows): ?>
<p class="empty">No ranked matches here yet.</p>
<?php else: ?>
<table><thead><tr><th class="rank">#</th><th>Player</th><?php if ($mode !== 'all'): ?><th class="n">Rating</th><?php endif ?><th class="n">Wins</th><th class="n">Losses</th></tr></thead><tbody>
<?php foreach ($rows as $r): ?>
<tr class="<?= $r['rank'] <= 3 ? 'top' : '' ?>"><td class="rank"><?= $r['rank'] ?></td><td><?= $h($r['name']) ?></td>
<?php if ($mode !== 'all'): ?><td class="n"><?= $r['rating'] ?></td><?php endif ?><td class="n"><?= $r['wins'] ?></td><td class="n"><?= $r['losses'] ?></td></tr>
<?php endforeach ?>
</tbody></table>
<?php endif ?>
</main></body></html>
