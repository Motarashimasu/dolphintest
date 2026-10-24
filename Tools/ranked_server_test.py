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
    "bulma": {"id": "1004", "username": "bulma_b", "global_name": "Bulma"},
    "yamcha": {"id": "1005", "username": "yamcha", "global_name": "Yamcha"},
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
            "replay_dir": os.path.join(os.path.dirname(self.db), "replay_files"),
            "pic_dir": os.path.join(os.path.dirname(self.db), "pics"),
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


def account_name(who):
    u = DISCORD_USERS.get(who, {"username": who})
    return u.get("global_name") or u["username"]


def login(server, who):
    """The launcher's DRAGON NET account login (made the first time): (response, "")."""
    name, password = account_name(who), f"pw-{who}-123"
    _, p = call(server, "account.php", action="login", username=name, password=password)
    if not p.get("ok"):
        _, p = call(server, "account.php", action="register", username=name, password=password)
    return p, ""


def seed_discord_profile(server, who):
    """A profile from before accounts (made by the old Discord login), straight into the database."""
    import sqlite3
    u = DISCORD_USERS[who]
    con = sqlite3.connect(server.db)
    con.execute("INSERT INTO players (discord_id, name, avatar, created, last_seen) VALUES (?, ?, NULL, ?, ?)",
                (u["id"], u.get("global_name") or u["username"], int(time.time()), int(time.time())))
    con.commit()
    pid = con.execute("SELECT id FROM players WHERE discord_id = ?", (u["id"],)).fetchone()[0]
    con.execute("INSERT INTO ratings (player_id, mode, rating, wins, losses) VALUES (?, 'single', 1111, 0, 0)", (pid,))
    con.commit()
    con.close()
    return pid


def discord_login(server, who):
    """The launcher's Discord login: start, the browser visits Discord, poll for the session."""
    _, s = call(server, "auth.php", action="start")
    try:
        with urllib.request.urlopen(s["url"] + f"&as={who}", timeout=10) as r:
            page = r.read().decode()
    except urllib.error.HTTPError as e:   # the login-failed page
        page = e.read().decode()
    _, p = call(server, "auth.php", action="poll", login=s["login"], poll=s["poll"])
    return p, page


def social_checks(server, check, G, V, K):
    def poll(tok):
        return call(server, "social.php", tok, action="poll")[1]
    _, r = call(server, "social.php", G, action="request", name="vegeta")
    check("friend request by username (any case)", r.get("state") == "pending" and r.get("name") == "Vegeta")
    p = poll(V)
    check(f"Vegeta sees Goku's request {p.get('incoming')}", [x["name"] for x in p["incoming"]] == ["Goku"])
    check("Goku sees his request waiting", [x["name"] for x in poll(G)["outgoing"]] == ["Vegeta"])
    _, a = call(server, "social.php", V, action="accept", id=p["incoming"][0]["id"])
    p = poll(G)
    f0 = p["friends"][0]
    check(f"friends now, Vegeta online {p['friends']}", len(p["friends"]) == 1 and f0["name"] == "Vegeta"
          and f0["online"] is True and f0["since"] > 0 and p["now"] >= f0["since"])
    since0 = f0["since"]
    # A launcher (re)start says so: a new "came online" time even within the online window.
    time.sleep(1.1)
    call(server, "social.php", V, action="poll", start=True)
    since1 = poll(G)["friends"][0]["since"]
    check(f"start=1: Vegeta came online again ({since0} -> {since1})", since1 > since0)
    time.sleep(1.1)
    poll(V)
    check("a normal poll keeps the time Vegeta came online", poll(G)["friends"][0]["since"] == since1)
    _, r = call(server, "social.php", K, action="request", name="Goku")
    _, r2 = call(server, "social.php", G, action="request", name="krillin")
    check("asking someone who asked you: friends at once", r2.get("state") == "friends")
    _, nf = call(server, "social.php", G, action="request", name="nobody_here")
    check("unknown username", nf.get("error") == "no_such_player")
    _, own = call(server, "social.php", G, action="request", name="Goku")
    check("not yourself", own.get("error") == "own_name")
    server.write_config(report_grace=3, time_offset=200)   # nobody polled for 200 s
    time.sleep(3)
    p = poll(G)
    check(f"friends who stopped polling are offline {p['friends']}", all(not f["online"] for f in p["friends"]))
    check("offline friends: since 0", all(f["since"] == 0 for f in p["friends"]))
    vp = poll(V)   # Vegeta comes back after the pause: any request makes him online again
    v_since = [f for f in poll(G)["friends"] if f["name"] == "Vegeta"][0]["since"]
    check(f"back online after being offline: a newer since ({since1} -> {v_since})", v_since >= since1 + 200)
    server.write_config(report_grace=3)
    time.sleep(3)
    kid = [f["id"] for f in poll(G)["friends"] if f["name"] == "krillin"][0]
    call(server, "social.php", G, action="remove", id=kid)
    check("unfriend", [f["name"] for f in poll(G)["friends"]] == ["Vegeta"])
    check("messages: none yet", poll(G)["messages"] == [])


def replay_checks(server, check, G, V):
    """replays.php: share a replay in pieces, find it, download it, no duplicates, delete."""
    import base64
    import hashlib
    dtm = bytes(range(256)) * 1200 + b"end"             # ~300 KB: two pieces
    sav = b"STATE" * 70000
    meta = {"game_id": "RDSPAF", "mode": "single", "players": ["Goku", "Vegeta"], "wins": [2, 1],
            "winner": "Goku", "seconds": 185, "date": "2026-10-19 01:30:00", "gecko": ["Infinite Health"],
            "frames": 11100, "dtm": "x.dtm"}

    def start(tok, **extra):
        body = dict(action="start", meta=meta, dtm_size=len(dtm), sav_size=len(sav),
                    dtm_sha=hashlib.sha1(dtm).hexdigest(), sav_sha=hashlib.sha1(sav).hexdigest())
        body.update(extra)
        return call(server, "replays.php", tok, **body)[1]

    def send(tok, rid, which, data, chunk):
        for off in range(0, len(data), chunk):
            _, r = call(server, "replays.php", tok, action="part", id=rid, which=which, offset=off,
                        data=base64.b64encode(data[off:off + chunk]).decode())
            if not r.get("ok"):
                return r
        return {"ok": True}

    _, anon = call(server, "replays.php", action="start", meta=meta)
    check("sharing a replay needs a login", anon.get("error") == "login_required")
    st = start(G)
    check(f"upload starts {st}", st.get("ok") and st.get("id") and st.get("chunk") == 262144)
    rid, chunk = st["id"], st["chunk"]
    _, bad = call(server, "replays.php", G, action="part", id=rid, which="dtm", offset=5,
                  data=base64.b64encode(b"x").decode())
    check("a piece at the wrong place is refused", bad.get("error") == "wrong_offset" and bad.get("have") == 0)
    _, nope = call(server, "replays.php", V, action="part", id=rid, which="dtm", offset=0,
                   data=base64.b64encode(b"x").decode())
    check("someone else can't add to it", nope.get("error") == "not_yours")
    _, s0 = call(server, "replays.php", action="search")
    check("not listed while uploading", s0.get("ok") and s0["replays"] == [])
    check("inputs uploaded in pieces", send(G, rid, "dtm", dtm, chunk).get("ok"))
    check("start state uploaded", send(G, rid, "sav", sav, chunk).get("ok"))
    _, fin = call(server, "replays.php", G, action="finish", id=rid)
    check(f"finish: sizes + SHA-1 check out {fin}", fin.get("ok") and fin.get("id") == rid)
    _, s1 = call(server, "replays.php", action="search", q="vege")
    hit = s1["replays"][0] if s1.get("replays") else {}
    check(f"search by part of a name {hit}", hit.get("id") == rid and hit["players"] == ["Goku", "Vegeta"]
          and hit["wins"] == [2, 1] and hit["winner"] == "Goku" and hit["uploader"] == "Goku"
          and hit["size"] == len(dtm) + len(sav) and hit["mode"] == "single")
    _, s2 = call(server, "replays.php", action="search", q="krillin")
    check("no match: empty", s2["replays"] == [])
    _, s3 = call(server, "replays.php", action="search", game="bt2")
    check("game filter (BT2: none)", s3["replays"] == [])
    _, s4 = call(server, "replays.php", action="search", game="bt3", mode="single", version="RDSPAF")
    check("game + mode + version filter", [r["id"] for r in s4["replays"]] == [rid])
    _, s5 = call(server, "replays.php", action="search", q="%")
    check("a % in the search is just a character", s5["replays"] == [])
    _, got = call(server, "replays.php", action="get", id=rid)
    check("get: the full info", got["replay"]["meta"]["gecko"] == ["Infinite Health"])
    for which, data in (("dtm", dtm), ("sav", sav)):
        with urllib.request.urlopen(f"{server.url}replays.php?action=file&id={rid}&which={which}", timeout=10) as r:
            body = r.read()
        check(f"download {which}: same bytes ({len(body)})", body == data)
    _, s6 = call(server, "replays.php", action="search")
    check("downloads counted", s6["replays"][0]["downloads"] == 1)
    again = start(V)
    check(f"the same replay again: already there {again}", again.get("exists") is True and again.get("id") == rid)
    _, dl = call(server, "replays.php", V, action="delete", id=rid)
    check("only the one who shared it can delete it", dl.get("error") == "not_yours")
    _, dl = call(server, "replays.php", G, action="delete", id=rid)
    _, s7 = call(server, "replays.php", action="search")
    check("deleted", dl.get("ok") and s7["replays"] == [])
    big = start(G, sav_size=200 * 1048576)
    check("too big refused", big.get("error") == "replay_too_big")
    broken = start(G)
    send(G, broken["id"], "dtm", dtm, chunk)
    send(G, broken["id"], "sav", sav[:-1] + b"X", chunk)
    _, fin2 = call(server, "replays.php", G, action="finish", id=broken["id"])
    check("a damaged upload is thrown away", fin2.get("error") == "upload_broken")
    cut = start(G)
    send(G, cut["id"], "dtm", dtm[:chunk], chunk)   # cut off half-way
    again3 = start(G)
    _, gone = call(server, "replays.php", G, action="part", id=cut["id"], which="dtm", offset=chunk,
                   data=base64.b64encode(b"x").decode())
    check("starting the same replay again replaces the cut-off upload",
          again3.get("ok") and again3["id"] != cut["id"] and gone.get("error") == "no_such_replay")


def png(w, h, color=(200, 60, 40, 255)):
    """A plain w x h PNG (no PIL needed)."""
    import struct
    import zlib
    raw = b"".join(b"\0" + bytes(color) * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def picture_checks(server, check, G, V):
    """account.php > picture: 128 x 128 only, shown in the profile, to friends and on the boards."""
    import base64
    b64 = lambda b: base64.b64encode(b).decode()
    _, r = call(server, "account.php", G, action="picture", data=b64(png(300, 200)))
    check("a picture that isn't 128 x 128 is refused", r.get("error") == "bad_picture_size" and r.get("size") == 128)
    _, r = call(server, "account.php", G, action="picture", data=b64(b"<?php echo 1; ?>" * 10))
    check("not a picture: refused", r.get("error") == "bad_picture")
    _, r = call(server, "account.php", action="picture", data=b64(png(128, 128)))
    check("needs a login", r.get("error") == "login_required")
    _, r = call(server, "account.php", G, action="picture", data=b64(png(128, 128)))
    url = r.get("picture") or ""
    check(f"picture saved {url}", r.get("ok") and "pic.php?id=" in url and "&v=" in url)
    with urllib.request.urlopen(url, timeout=10) as resp:
        body = resp.read()
        ctype = resp.headers.get("Content-Type")
    check(f"served as a PNG ({len(body)} bytes, {ctype})", body.startswith(b"\x89PNG") and ctype == "image/png")
    _, me = call(server, "me.php", G)
    check("profile has it", me["player"]["picture"] == url)
    _, p = call(server, "social.php", V, action="poll")
    goku = [f for f in p["friends"] if f["name"] == "Goku"]
    check("friends see it", goku and goku[0]["pic"] == url)
    _, r2 = call(server, "account.php", G, action="picture", data=b64(png(128, 128, (10, 200, 90, 255))))
    check("a new picture gets a new address (no stale cache)", r2.get("picture") and r2["picture"] != url)
    _, rm = call(server, "account.php", G, action="picture_remove")
    _, me = call(server, "me.php", G)
    check("removed", rm.get("ok") and me["player"]["picture"] is None)
    call(server, "account.php", G, action="picture", data=b64(png(128, 128)))   # keep one for the boards


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
    tm = re.findall(r"<tr><td>#(\d+)</td><td>[^<]*</td><td>team</td>", page("?p=matches&state=done"))
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

    # A forgotten password: reset to a temporary one, shown once; the old one stops working,
    # the player is logged out, and the temporary one logs in.
    _, b = call(server, "account.php", action="register", username="Forgetful", password="pw-forgot-123")
    check(f"admin: a player who'll forget their password ({b.get('error', 'ok')})", b.get("ok") is True)
    bid = call(server, "me.php", b.get("token", ""))[1].get("player", {}).get("id", 0)
    out = act(a="reset_password", player=bid)
    m = re.search(r"New temporary password for Forgetful: ([a-z2-9]{10})", out)
    check("admin: reset password shows a temporary one", m is not None)
    code, _ = call(server, "me.php", b.get("token", ""))
    check(f"admin: reset logs the player out everywhere ({code})", code == 401)
    _, r = call(server, "account.php", action="login", username="Forgetful", password="pw-forgot-123")
    check("admin: the old password stops working", r.get("error") == "wrong_login")
    _, r = call(server, "account.php", action="login", username="forgetful", password=m.group(1) if m else "")
    check("admin: the temporary password logs in", r.get("ok") is True)
    check("admin: the password itself isn't in the log", m is None or m.group(1) not in page("?p=log"))

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
    # Messages: every logged-in player gets it once, until they close it.
    out = act(a="message", text="Server maintenance tonight at 22:00 UTC.", days="2")
    check("admin: message sent", "every logged-in player sees it once" in out)
    msgs = call(server, "social.php", tokens["vegeta"], action="poll")[1]["messages"]
    check(f"players get the message {msgs}", [m["text"] for m in msgs] == ["Server maintenance tonight at 22:00 UTC."])
    call(server, "social.php", tokens["vegeta"], action="ack", message=msgs[0]["id"])
    check("closed: not sent again", call(server, "social.php", tokens["vegeta"], action="poll")[1]["messages"] == [])
    check("others still get it", len(call(server, "social.php", tokens["goku"], action="poll")[1]["messages"]) == 1)
    check("admin: how many closed it", ">1</td>" in page("?p=messages"))
    act(a="message_off", message=msgs[0]["id"])
    check("switched off: nobody else gets it", call(server, "social.php", tokens["goku"], action="poll")[1]["messages"] == [])
    log = page("?p=log")
    check("admin: every action logged", all(w in log for w in ("edit_stats", "void_match", "ban", "unban", "new_season", "message", "reset_password")))
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
        # DRAGON NET accounts: made in the launcher, username + password.
        _, r = call(server, "account.php", action="register", username="Goku", password="pw-goku-123")
        check(f"account made, logged in ({r.get('player')})",
              r.get("ok") and len(r.get("token", "")) == 64 and r["player"]["name"] == "Goku")
        g = r
        code, dup = call(server, "account.php", action="register", username="goku", password="whatever1")
        check("a username is taken whatever its case", code == 409 and dup["error"] == "username_taken")
        for bad_name, bad_pass, err in (("ab", "secret12", "bad_username"), ("Goku Son", "secret12", "bad_username"),
                                        ("Gohan", "123", "bad_password")):
            _, b = call(server, "account.php", action="register", username=bad_name, password=bad_pass)
            check(f"refused: {bad_name!r} / {bad_pass!r} -> {b.get('error')}", b.get("error") == err)
        code, wrong = call(server, "account.php", action="login", username="Goku", password="nope-nope")
        check("wrong password refused", code == 401 and wrong["error"] == "wrong_login")
        _, again = call(server, "account.php", action="login", username="GOKU", password="pw-goku-123")
        check("log in (username in any case)", again.get("ok") and again["player"]["id"] == g["player"]["id"])
        for _ in range(9):
            call(server, "account.php", action="login", username="Vegeta", password="guessing")
        _, slow = call(server, "account.php", action="login", username="Vegeta", password="guessing")
        check("too many wrong passwords: that username waits", slow.get("error") == "too_many_attempts")
        server.write_config(report_grace=3, time_offset=400)   # the pause is over
        time.sleep(3)
        v, _ = login(server, "vegeta")
        k, _ = login(server, "krillin")
        server.write_config(report_grace=3)
        time.sleep(3)
        check("accounts for Vegeta and krillin", v.get("ok") and k.get("player", {}).get("name") == "krillin")

        # Discord: only to bring back a profile from before accounts, once, keeping its ratings.
        bulma_id = seed_discord_profile(server, "bulma")
        b, page = discord_login(server, "bulma")
        check(f"old Discord profile: logged in, asked to make its account ({b.get('state')})",
              b.get("state") == "done" and b.get("needs_account") is True and "Logged in as Bulma" in page)
        _, taken = call(server, "account.php", b["token"], action="claim", username="Goku", password="bulma-pw-1")
        check("claiming a taken username refused", taken.get("error") == "username_taken")
        _, cl = call(server, "account.php", b["token"], action="claim", username="Bulma", password="bulma-pw-1")
        check("old profile gets its username + password", cl.get("ok") and cl["player"]["id"] == bulma_id)
        _, bl = call(server, "account.php", action="login", username="Bulma", password="bulma-pw-1")
        _, bme = call(server, "me.php", bl["token"])
        check(f"and logs in with it, ratings kept ({bme['ratings']['single']})",
              bme["player"]["id"] == bulma_id and bme["ratings"]["single"]["rating"] == 1111)
        _, again2 = call(server, "account.php", b["token"], action="claim", username="Bulma2", password="bulma-pw-1")
        check("claiming twice refused", again2.get("error") == "already_claimed")
        b2, _ = discord_login(server, "bulma")
        check("Discord again: no account to make now", b2.get("state") == "done" and b2.get("needs_account") is False
              and b2.get("username") == "Bulma")
        y, page = discord_login(server, "yamcha")
        check("Discord makes no new profiles", y.get("state") == "error" and "Make a DRAGON NET account" in page)
        d, page = discord_login(server, "deny")
        check("cancelled on Discord: the launcher hears so", d.get("state") == "error" and "cancelled" in page)
        _, again = call(server, "auth.php", action="poll", login="x" * 32, poll="y" * 32)
        check("a session is handed out once (unknown login expires)", again.get("state") == "expired")
        G, V, K = g["token"], v["token"], k["token"]

        # Friends, who's online, and the admin's messages.
        social_checks(server, check, G, V, K)
        replay_checks(server, check, G, V)
        picture_checks(server, check, G, V)
        _, me = call(server, "me.php", G)
        check(f"profile: 1000 in both modes {me.get('ratings')}",
              me["ratings"]["single"]["rating"] == 1000 and me["ratings"]["team"]["rating"] == 1000)
        # Notification bars: the example text, in each language; nobody ranked yet = no news.
        _, nt = call(server, "notices.php", lang="en")
        check(f"notices: blue in English, red empty {nt}", nt["ok"] and nt["notices"]["blue"].startswith("Welcome")
              and nt["notices"]["red"] == "" and nt["notices"]["yellow"] == "")
        _, nt = call(server, "notices.php", lang="es")
        check("notices: Spanish line", nt["notices"]["blue"].startswith("¡Bienvenido"))
        _, nt = call(server, "notices.php", lang="xx")
        check("notices: unknown language = English", nt["lang"] == "en")
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

        _, nt = call(server, "notices.php", lang="en")
        check(f"yellow news: new global Top 5 players {nt['notices']['yellow']}",
              "Goku reached the global Top 5 in Single Battle FT2!" in nt["notices"]["yellow"])
        _, nt = call(server, "notices.php", lang="it")
        check("yellow news in Italian", "Top 5 mondiale" in nt["notices"]["yellow"])
        _, nt2 = call(server, "notices.php", lang="en")
        check("news isn't repeated", nt2["notices"]["yellow"].count("Goku reached the global Top 5 in Single") == 1)

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
        # Budokai Tenkaichi 2: its own ladder (b2single / b2team), lobbies per disc version.
        _, o = call(server, "lobby.php", V, action="open", mode="b2single", region="NA",
                    join="ABCDEF", link="wired", version="RDBE70")
        b2l = o["lobby"]["id"]
        check(f"BT2 lobby opened with its version {o['lobby'].get('version')}", o["lobby"].get("version") == "RDBE70")
        _, ls = call(server, "lobby.php", G, action="list")
        check("older launchers' list: Tenkaichi 3 lobbies only", all(x["id"] != b2l for x in ls["lobbies"]))
        _, ls = call(server, "lobby.php", G, action="list", game="bt2", version="RDBE70")
        check("BT2 list on that version finds it", [x["id"] for x in ls["lobbies"]] == [b2l])
        _, ls = call(server, "lobby.php", G, action="list", game="bt2", version="RDBPAF")
        check("another version doesn't", ls["lobbies"] == [])
        _, ls = call(server, "lobby.php", G, action="list", game="bt3", version="RDSPAF")
        check(f"a lobby from before versions counts as BT3 PAL ({len(ls['lobbies'])})",
              any(x["version"] == "RDSPAF" for x in ls["lobbies"]))
        _, ls = call(server, "lobby.php", G, action="list", game="bt3", version="RDSE70")
        check("... and not as BT3 NTSC-U", all(x["version"] == "RDSE70" for x in ls["lobbies"]))
        call(server, "lobby.php", G, action="join", lobby=b2l)
        call(server, "match.php", V, action="start", lobby=b2l)
        call(server, "match.php", V, action="report", lobby=b2l, result="win")
        call(server, "match.php", G, action="report", lobby=b2l, result="loss")
        check(f"BT2 board {board('b2single', 'global')}",
              board("b2single", "global") == [("Vegeta", 1016, 1, 0), ("Goku", 984, 0, 1)])
        check("Tenkaichi 3's board unchanged", [n for n, *_ in board("single", "global")] == ["Goku", "Vegeta"])
        _, me2 = call(server, "me.php", V, game="bt2")
        check(f"BT2 profile: its ratings under plain names {me2['ratings']['single']}",
              me2["ratings"]["single"]["rating"] == 1016 and me2["lifetime"] == {"wins": 1, "losses": 0})
        _, me3 = call(server, "me.php", V)
        check("Tenkaichi 3 profile: its own", me3["ratings"]["single"]["rating"] != 1016 or me3["lifetime"]["wins"] != 1)
        _, b2all = call(server, "leaderboard.php?mode=all&region=global&game=bt2")
        check(f"BT2 all-time record {b2all['rows']}", [(r["name"], r["wins"]) for r in b2all["rows"]] == [("Vegeta", 1), ("Goku", 0)])
        check(f"Tenkaichi 3 all-time record without BT2 {board('all', 'global')}", board("all", "global")[0] == ("Goku", None, 3, 1))
        _, nt = call(server, "notices.php", lang="en")
        check("yellow news is Tenkaichi 3's only", "BT2" not in nt["notices"]["yellow"])
        call(server, "lobby.php", V, action="close", lobby=b2l)
        code, badv = call(server, "lobby.php", G, action="list", version="RDS")
        check("bad version refused", badv.get("error") == "bad_version")

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
