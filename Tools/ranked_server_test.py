#!/usr/bin/env python3
"""Tests the DRAGON NET ranked server (Server/ranked) end to end: PHP's built-in web server
running the real PHP files on SQLite, with a fake Discord (OAuth2 + /users/@me).

    python3 Tools/ranked_server_test.py

Also importable: start_ranked_server() gives the UI tour a working ranked server.
"""
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER_DIR = os.path.join(ROOT, "Server", "ranked")

DISCORD_USERS = {
    "goku": {"id": "1001", "username": "goku_s", "global_name": "Goku"},
    "vegeta": {"id": "1002", "username": "vegeta_p", "global_name": "Vegeta"},
    "krillin": {"id": "1003", "username": "krillin", "global_name": None},
}


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class FakeDiscord:
    """/oauth2/authorize redirects straight back with a code (pick the user with ?as=NAME),
    /api/oauth2/token swaps it for a token, /api/users/@me says who that is."""

    def __init__(self, secret):
        self.secret = secret
        self.codes = {}
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _json(self, code, body):
                data = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                url = urllib.parse.urlparse(self.path)
                q = dict(urllib.parse.parse_qsl(url.query))
                if url.path == "/oauth2/authorize":
                    user = q.get("as", "goku")
                    if user == "deny":
                        target = f"{q['redirect_uri']}?error=access_denied&state={q['state']}"
                    else:
                        code = f"code-{user}-{len(outer.codes)}"
                        outer.codes[code] = user
                        target = f"{q['redirect_uri']}?code={code}&state={q['state']}"
                    self.send_response(302)
                    self.send_header("Location", target)
                    self.end_headers()
                elif url.path == "/api/users/@me":
                    tok = self.headers.get("Authorization", "").removeprefix("Bearer ")
                    user = tok.removeprefix("tok-")
                    if user in DISCORD_USERS:
                        self._json(200, DISCORD_USERS[user])
                    else:
                        self._json(401, {"message": "401: Unauthorized"})
                else:
                    self._json(404, {})

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
                q = dict(urllib.parse.parse_qsl(body))
                if self.path == "/api/oauth2/token" and q.get("client_secret") == outer.secret \
                        and q.get("code") in outer.codes:
                    self._json(200, {"access_token": "tok-" + outer.codes.pop(q["code"]),
                                     "token_type": "Bearer"})
                else:
                    self._json(400, {"error": "invalid_grant"})

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()


class RankedServer:
    def __init__(self, work, report_grace=3):
        self.discord = FakeDiscord("test-secret")
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}/"
        self.config = os.path.join(work, "config.php")
        self.db = os.path.join(work, "ranked.sqlite")
        self.write_config(report_grace=report_grace)
        env = dict(os.environ, SPARKING_RANKED_CONFIG=self.config)
        self.proc = subprocess.Popen(["php", "-S", f"127.0.0.1:{self.port}", "-t", SERVER_DIR],
                                     env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.2).close()
                break
            except OSError:
                time.sleep(0.05)

    def write_config(self, **extra):
        cfg = {
            "db_dsn": f"sqlite:{self.db}",
            "discord_client_id": "1431360832750620702",
            "discord_client_secret": "test-secret",
            "discord_redirect": f"http://127.0.0.1:{self.port}/discord.php",
            "discord_authorize": f"{self.discord.url}/oauth2/authorize",
            "discord_api": f"{self.discord.url}/api",
        }
        cfg.update(extra)
        items = ",\n".join(f"    {json.dumps(k)} => {json.dumps(v)}" for k, v in cfg.items())
        with open(self.config, "w") as f:
            f.write(f"<?php\nreturn [\n{items}\n];\n")

    def stop(self):
        self.proc.terminate()
        self.discord.httpd.shutdown()


def call(server, endpoint, token=None, **params):
    req = urllib.request.Request(server.url + endpoint, data=json.dumps(params).encode(),
                                 headers={"Content-Type": "application/json",
                                          **({"X-Sparking-Token": token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def login(server, who):
    """The launcher's Discord login: start, the browser visits Discord, poll for the session."""
    _, s = call(server, "auth.php", action="start")
    try:
        with urllib.request.urlopen(s["url"] + f"&as={who}", timeout=10) as r:
            page = r.read().decode()
    except urllib.error.HTTPError as e:   # the login-failed page
        page = e.read().decode()
    _, p = call(server, "auth.php", action="poll", login=s["login"], poll=s["poll"])
    return p, page


def admin_checks(server, check, tokens):
    """admin.php: sign in, edit stats, void a match, ban / unban, new season, log."""
    import http.cookiejar
    import re
    server.write_config(admin_key="admin-test-key-123")
    time.sleep(3)
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    def page(q="", **form):
        data = urllib.parse.urlencode(form).encode() if form else None
        try:
            with opener.open(server.url + "admin.php" + q, data=data, timeout=10) as r:
                return r.read().decode()
        except urllib.error.HTTPError as e:
            return e.read().decode()

    def act(**form):
        csrf = re.search(r"name=csrf value='([0-9a-f]+)'", page("?p=players")).group(1)
        return page("", csrf=csrf, **form)

    def me(who):
        return call(server, "me.php", tokens[who])[1]

    check("admin: locked before signing in", "Sign in" in page() and "Players" not in page("?p=players").split("Sign in")[0][-50:])
    check("admin: wrong password refused", "Wrong password" in page("", a="login", key="nope"))
    page("", a="login", key="admin-test-key-123")
    lst = page("?p=players")
    check("admin: player list after signing in", "Goku" in lst and "Vegeta" in lst and "krillin" in lst)
    gid = me("goku")["player"]["id"]
    vid = me("vegeta")["player"]["id"]
    kid = me("krillin")["player"]["id"]

    act(a="stats", player=vid, mode="single", rating=1234, wins=7, losses=3)
    check(f"admin: edit stats {me('vegeta')['ratings']['single']}",
          me("vegeta")["ratings"]["single"] == {"rating": 1234, "wins": 7, "losses": 3})

    # Void the Team Battle match Goku won against krillin (+16 / -16): both back to 1000, 0-0.
    tm = re.findall(r"name=match value=(\d+)>", page("?p=matches&state=done"))
    team_before = (me("goku")["ratings"]["team"], me("krillin")["ratings"]["team"])
    life_before = me("goku")["lifetime"]
    act(a="void", match=tm[0])
    check(f"admin: void undoes the rating change {team_before} -> {me('goku')['ratings']['team']}",
          me("goku")["ratings"]["team"] == {"rating": 1000, "wins": 0, "losses": 0}
          and me("krillin")["ratings"]["team"] == {"rating": 1000, "wins": 0, "losses": 0})
    check("admin: void also undoes the all-time record",
          me("goku")["lifetime"]["wins"] == life_before["wins"] - 1)

    act(a="ban", player=kid, reason="exploiting")
    code, b = call(server, "lobby.php", tokens["krillin"], action="list")
    check(f"admin: banned player can't play ranked ({code})", code in (401, 403))
    k2, _ = login(server, "krillin")
    _, kme = call(server, "me.php", k2["token"])
    check("admin: banned player sees why", kme["player"]["banned"] is True and kme["player"]["ban_reason"] == "exploiting")
    _, lb = call(server, "leaderboard.php?mode=all&region=global")
    check("admin: banned player off the leaderboards", all(r["name"] != "krillin" for r in lb["rows"]))
    act(a="unban", player=kid)
    _, kme = call(server, "me.php", k2["token"])
    check("admin: unban", kme["player"]["banned"] is False)

    life = me("goku")["lifetime"]
    out = act(a="season", name="Season 2", confirm="nope")
    check("admin: new season needs RESET typed", "Type RESET" in out and me("vegeta")["ratings"]["single"]["rating"] == 1234)
    act(a="season", name="Season 2", confirm="RESET")
    v = me("vegeta")
    check(f"admin: new season resets ratings and records {v['ratings']}",
          v["ratings"]["single"] == {"rating": 1000, "wins": 0, "losses": 0} and v["season"]["name"] == "Season 2")
    check("admin: the all-time record survives the reset", me("goku")["lifetime"] == life)
    _, lb = call(server, "leaderboard.php?mode=single&region=global")
    check("admin: season boards start empty", lb["rows"] == [] and lb["season"]["number"] == 2)
    seasons = page("?p=seasons")
    check("admin: past season archived with final standings", "Season 1" in seasons and "Final standings" in seasons)
    sid = re.search(r"view=(\d+)", seasons).group(1)
    check("admin: final standings kept", "1234" in page(f"?p=seasons&view={sid}"))
    log = page("?p=log")
    check("admin: every action logged", all(w in log for w in ("edit_stats", "void_match", "ban", "unban", "new_season")))
    server.write_config(admin_key="")


def main():
    work = tempfile.mkdtemp(prefix="ranked-")
    server = RankedServer(work)
    failures = []

    def check(label, cond):
        print(("  PASS  " if cond else "  FAIL  ") + label)
        if not cond:
            failures.append(label)

    try:
        _, me = call(server, "me.php")
        check("profile needs a login", me.get("error") == "login_required")
        g, page = login(server, "goku")
        check(f"Discord login hands the launcher a session ({g.get('state')})",
              g.get("state") == "done" and len(g.get("token", "")) == 64 and "Logged in as Goku" in page)
        _, again = call(server, "auth.php", action="poll", login="x" * 32, poll="y" * 32)
        check("a session is handed out once (unknown login expires)", again.get("state") == "expired")
        v, _ = login(server, "vegeta")
        k, _ = login(server, "krillin")
        check("no display name: the Discord username", k.get("player", {}).get("name") == "krillin")
        d, page = login(server, "deny")
        check("cancelled on Discord: the launcher hears so", d.get("state") == "error" and "cancelled" in page)
        G, V, K = g["token"], v["token"], k["token"]
        _, me = call(server, "me.php", G)
        check(f"profile: 1000 in both modes {me.get('ratings')}",
              me["ratings"]["single"]["rating"] == 1000 and me["ratings"]["team"]["rating"] == 1000)
        g2, _ = login(server, "goku")
        _, me2 = call(server, "me.php", g2["token"])
        check("logging in again is the same profile", me2["player"]["id"] == me["player"]["id"])

        # Lobby: Goku hosts Single Battle in NA, Vegeta finds and joins it, Krillin can't.
        _, o = call(server, "lobby.php", G, action="open", mode="single", region="NA",
                    join="ABCDEFGH", link="wired")
        lob = o["lobby"]["id"]
        check("host opens a ranked lobby", o["ok"] and o["lobby"]["you_host"])
        _, ls = call(server, "lobby.php", V, action="list", mode="single")
        mine = [x for x in ls["lobbies"] if x["id"] == lob]
        check(f"listed with the host's rating {mine}", mine and mine[0]["host"]["name"] == "Goku"
              and mine[0]["host"]["rating"] == 1000 and mine[0]["players"] == 1 and "join" not in mine[0])
        _, ls = call(server, "lobby.php", V, action="list", mode="team")
        check("mode filter", all(x["id"] != lob for x in ls["lobbies"]))
        _, j = call(server, "lobby.php", V, action="join", lobby=lob)
        check("guest takes the seat and gets the room", j["ok"] and j["lobby"]["join"] == "ABCDEFGH")
        code, jk = call(server, "lobby.php", K, action="join", lobby=lob)
        check(f"a third player is turned away ({code})", code == 409 and jk["error"] == "lobby_full")
        _, own = call(server, "lobby.php", G, action="join", lobby=lob)
        check("can't join your own lobby", own.get("error") == "own_lobby")
        code, _ = call(server, "match.php", V, action="start", lobby=lob)
        check("only the host starts a match", code == 403)

        def play(reports, wait=0):
            _, s = call(server, "match.php", G, action="start", lobby=lob)
            for tok, res in reports:
                if res == "forfeit":
                    call(server, "match.php", tok, action="forfeit", lobby=lob)
                else:
                    call(server, "match.php", tok, action="report", lobby=lob, result=res)
            if wait:
                time.sleep(wait)
            _, st = call(server, "lobby.php", G, action="heartbeat", lobby=lob)
            return s["match"]["id"], st["lobby"]

        mid, st = play([(G, "win"), (V, "loss")])
        lm = st["last_match"]
        check(f"both agree: Goku wins, +16 {lm}", lm and lm["id"] == mid and lm["state"] == "done"
              and lm["you_won"] is True and lm["rating_change"] == 16 and st["match"] is None)
        _, vme = call(server, "me.php", V)
        check(f"Vegeta 984, 0-1 {vme['ratings']['single']}",
              vme["ratings"]["single"] == {"rating": 984, "wins": 0, "losses": 1})

        mid, st = play([(G, "win"), (V, "win")])
        check("reports disagree: void, no rating change",
              st["last_match"]["state"] == "void" and st["last_match"]["reason"] == "disagree")
        mid, st = play([(V, "win")])
        check("one report: not decided yet", st["match"] and st["match"]["state"] == "live")
        time.sleep(4)
        _, st = call(server, "lobby.php", G, action="heartbeat", lobby=lob)
        st = st["lobby"]
        check(f"lone report counts after the grace period {st.get('last_match')}",
              st["last_match"]["state"] == "done" and st["last_match"]["you_won"] is False
              and st["last_match"]["reason"] == "single_report")
        mid, st = play([(V, "forfeit"), (G, "win")])
        check("leaving a running match is a loss", st["last_match"]["you_won"] is True
              and st["last_match"]["reason"] == "agreed")
        code, _ = call(server, "match.php", G, action="report", lobby=lob, result="win")
        check("no match running: report refused", code == 404)

        # Team Battle in EU: Krillin hosts, Goku joins and wins.
        _, o = call(server, "lobby.php", K, action="open", mode="team", region="EU",
                    join="1.2.3.4:2626", link="wireless")
        tl = o["lobby"]["id"]
        call(server, "lobby.php", G, action="join", lobby=tl)
        call(server, "match.php", K, action="start", lobby=tl)
        call(server, "match.php", K, action="report", lobby=tl, result="loss")
        call(server, "match.php", G, action="report", lobby=tl, result="win")

        def board(mode, region):
            _, b = call(server, f"leaderboard.php?mode={mode}&region={region}")
            return [(r["name"], r.get("rating"), r["wins"], r["losses"]) for r in b["rows"]]

        check(f"Single global {board('single', 'global')}",
              [n for n, *_ in board("single", "global")] == ["Goku", "Vegeta"])
        check(f"Single in NA {board('single', 'NA')}", len(board("single", "NA")) == 2)
        check("Single in EU: nobody", board("single", "EU") == [])
        check(f"Team in EU {board('team', 'EU')}",
              board("team", "EU") == [("Goku", 1016, 1, 0), ("krillin", 984, 0, 1)])
        allt = board("all", "global")
        check(f"all-time record across modes {allt}", allt[0] == ("Goku", None, 3, 1))
        check(f"all-time in EU {board('all', 'EU')}", [n for n, *_ in board("all", "EU")] == ["Goku", "krillin"])
        _, bad = call(server, "leaderboard.php?mode=ranked")
        check("bad mode refused", bad.get("error") == "bad_mode")
        with urllib.request.urlopen(server.url + "index.php?mode=team&region=EU", timeout=10) as r:
            html = r.read().decode()
        check("leaderboard web page", "DRAGON NET Ranked" in html and "Goku" in html and "1016" in html)

        # Host closes; the lobby disappears.
        call(server, "lobby.php", G, action="close", lobby=lob)
        _, ls = call(server, "lobby.php", V, action="list")
        check("closed lobby unlisted", all(x["id"] != lob for x in ls["lobbies"]))
        G2 = login(server, "goku")[0]["token"]   # a second session (the first logs out next)
        call(server, "auth.php", G, action="logout")
        code, _ = call(server, "me.php", G)
        check("logged out", code == 401)

        admin_checks(server, check, {"goku": G2, "vegeta": V, "krillin": K})

        server.write_config(discord_client_secret="PUT-YOUR-DISCORD-CLIENT-SECRET-HERE")
        time.sleep(3)   # PHP's file cache notices the change after a moment
        code, nc = call(server, "auth.php", action="start")
        check("no Client Secret yet: says so", code == 503 and nc["error"] == "discord_not_configured")
    finally:
        server.stop()
    print("RANKED SERVER", "PASSED" if not failures else f"FAILED ({len(failures)})")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
