<?php
// The launcher's notification bars. Copy this file to notices_text.php (same folder) and edit
// THAT one: updates never overwrite it. Leave a line empty ('') to send nothing for it.
//
//   red     emergency announcements: updates, important notices. Shown first, before the others.
//   blue    general announcements.
//   yellow  Tenkaichi 3 ranked player news (shown only in the Tenkaichi 3 menus). Players newly
//           reaching the global Top 5 are added automatically.
//
// Each bar has one line per language the launcher supports. A language left empty shows the
// English line instead. Launchers check for changes every 2 minutes.
return [
    'red' => [
        'en' => '',
        'es' => '',
        'it' => '',
    ],
    'blue' => [
        'en' => 'Welcome to DRAGON NET! Ranked Match, Battle Lounge and Player Match are open.',
        'es' => '¡Bienvenido a DRAGON NET! Partida clasificatoria, Battle Lounge y Partida entre jugadores están abiertas.',
        'it' => 'Benvenuto su DRAGON NET! Partita classificata, Battle Lounge e Partita tra giocatori sono aperte.',
    ],
    'yellow' => [
        'en' => '',
        'es' => '',
        'it' => '',
    ],
];
