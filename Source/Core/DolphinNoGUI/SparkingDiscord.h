// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Discord Rich Presence helper for the frontend (--discord-presence <application id>).
// A long-running process with no game: the frontend keeps one alive across its menus, lobbies and
// matches and sends it what to show. It talks to the Discord app on this PC through Dolphin's
// bundled discord-rpc library (local IPC; no network, no token).
//
// Commands (stdin, after "hello"):
//   presence {json}   show this; keys (all optional): details, state, large_image, large_text,
//                     small_image, small_text, start, end (unix seconds), party_id, party_size,
//                     party_max, join_secret, match_secret
//   clear             show nothing
//   respond <user id> yes|no|ignore   answer an "Ask to Join" request
//   quit
// Events: ready {protocol, mode, enabled}, connected {user_id, username},
//   disconnected {code, message}, error {code: "discord", message}, join {secret},
//   join_request {user_id, username}

#pragma once

namespace optparse
{
class Values;
}

namespace Sparking
{
int RunDiscordPresence(const optparse::Values& options);
}
