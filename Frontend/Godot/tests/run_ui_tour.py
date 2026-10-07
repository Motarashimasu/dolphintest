#!/usr/bin/env python3
"""Runs the Godot frontend's automated UI tour (tests/ui_tour.gd) against a real
dolphin-emu-nogui, with a fake lobby server, a second player joining the tour's lobby and a
public lobby to find in the browser. Saves a screenshot of every screen.

    python3 Frontend/Godot/tests/run_ui_tour.py <dolphin-emu-nogui> <godot binary> [out_dir]

Linux: runs Godot under xvfb-run (needs Xvfb + Mesa). The test "game" is the smoke test's DOL.
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "Tools"))
from sparking_smoke_test import FakeLobbyServer, Instance, make_test_dol  # noqa: E402

FAKE_GAME = "Dragon Ball Z Budokai Tenkaichi 3 (RDSPAF)"
COMMON = ["-p", "headless", "-v", "Null"]


def fake_discord(path, activities):
    """Minimal Discord IPC server: handshake -> READY, then record SET_ACTIVITY payloads."""
    import socket
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(4)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=_discord_client, args=(c, activities), daemon=True).start()


def _discord_client(c, activities):
    import struct
    def recv(n):
        b = b""
        while len(b) < n:
            chunk = c.recv(n - len(b))
            if not chunk:
                raise EOFError
            b += chunk
        return b
    try:
        while True:
            op, ln = struct.unpack("<II", recv(8))
            body = json.loads(recv(ln))
            if op == 0:
                ready = json.dumps({"cmd": "DISPATCH", "evt": "READY", "data": {"v": 1, "user": {
                    "id": "42", "username": "TourTester", "discriminator": "0", "avatar": ""}}}).encode()
                c.sendall(struct.pack("<II", 1, len(ready)) + ready)
            elif op == 1:
                if body.get("cmd") == "SET_ACTIVITY":
                    activities.append(body.get("args", {}).get("activity"))
                if body.get("nonce"):
                    reply = json.dumps({"cmd": body.get("cmd"), "nonce": body["nonce"], "data": {}, "evt": None}).encode()
                    c.sendall(struct.pack("<II", 1, len(reply)) + reply)
    except (EOFError, OSError):
        pass


def main():
    exe = os.path.abspath(sys.argv[1])
    godot = os.path.abspath(sys.argv[2])
    work = tempfile.mkdtemp(prefix="sparking-ui-")
    out_dir = os.path.abspath(sys.argv[3]) if len(sys.argv) > 3 else os.path.join(work, "shots")
    os.makedirs(out_dir, exist_ok=True)
    dol = os.path.join(work, "game.dol")
    make_test_dol(dol)

    server = FakeLobbyServer()

    # Show every listing as BT3 in the browser (the DOL has no real game name).
    def rename_games():
        while True:
            for s in list(server.sessions.values()):
                s["game"] = FAKE_GAME
            time.sleep(0.1)
    threading.Thread(target=rename_games, daemon=True).start()

    def user(path, port):
        os.makedirs(os.path.join(path, "Config"), exist_ok=True)
        with open(os.path.join(path, "Config", "Dolphin.ini"), "w") as f:
            f.write(f"[NetPlay]\nTraversalChoice = direct\nHostPort = {port}\n"
                    f"IndexServer = {server.url}\nSyncSaves = False\n"
                    "[Analytics]\nPermissionAsked = True\nEnabled = False\n")
        return path

    data = os.path.join(work, "SparkingData")
    godot_user = user(os.path.join(data, "user"), 26300)
    joiner_user = user(os.path.join(work, "joiner"), 26301)
    piccolo_user = user(os.path.join(work, "piccolo"), 26310)
    trunks_user = user(os.path.join(work, "trunks"), 26311)

    # The DOL's game ID, for its Gecko codes and texture pack.
    # It also captures the state Buffer Training boots ([Sparking.Modes] Training, below).
    os.makedirs(os.path.join(data, "states"), exist_ok=True)
    probe = Instance("probe", [exe, *COMMON, "--sparking", "-u", user(os.path.join(work, "probe"), 26399),
                               "--state-dir", os.path.join(data, "states"),
                               "-e", dol])
    probe.send("hello")
    game_id = probe.seen("game_info")["game_id"]
    probe.seen("game_started", timeout=30)
    time.sleep(1)
    probe.send("save_state_file training.sst")
    probe.seen("state_file_saved", timeout=30)
    probe.send("quit")
    probe.proc.wait(timeout=15)
    print("test game id:", game_id)

    for u in (godot_user, joiner_user, piccolo_user, trunks_user):
        os.makedirs(os.path.join(u, "GameSettings"), exist_ok=True)
        with open(os.path.join(u, "GameSettings", f"{game_id}.ini"), "w") as f:
            f.write("[Gecko]\n$Player 1 Splitscreen Remover\n04001000 00000001\n"
                    "$Player 2 Splitscreen Remover\n04001004 00000002\n"
                    "$16:9 aspect ratio\n04001008 00000003\n"
                    "[Gecko_Enabled]\n$16:9 aspect ratio\n"
                    "[Sparking.Modes]\nTraining = training.sst\n")
    # Texture pack with the frontend's variant groups (empty placeholder textures).
    png = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"
                        "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082")
    for group, options in (("Graphics", ["Enhanced", "Legacy"]),
                           ("Buttons", ["Vanilla", "PlayStation", "Xbox"])):
        for opt in options:
            d = os.path.join(data, "textures", game_id, "@" + group, opt)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, f"tex1_8x8_{group.lower()}00000000_0.png"), "wb") as f:
                f.write(png)

    netplay_codes = ["--netplay-gecko", "1=Player 1 Splitscreen Remover",
                     "--netplay-gecko", "2=Player 2 Splitscreen Remover"]

    # A public Team Battle lobby for the Lobby Browser step.
    piccolo = Instance("piccolo", [exe, *COMMON, "-u", piccolo_user, "--netplay-host", dol,
                                   "--netplay-direct", "--public", "--mode", "team", "--region", "EU",
                                   "--public-address", "127.0.0.1", "--nickname", "Piccolo",
                                   "--link", "wired", *netplay_codes])
    piccolo.send("hello")
    piccolo.seen("public", lambda e: e.get("listed"))
    # A public King of the Hill lobby (only the King of the Hill browser lists it).
    trunks = Instance("trunks", [exe, *COMMON, "-u", trunks_user, "--netplay-host", dol,
                                 "--netplay-direct", "--public", "--koth", "--mode", "single",
                                 "--region", "EU", "--public-address", "127.0.0.1",
                                 "--nickname", "Trunks", "--link", "wired", *netplay_codes])
    trunks.send("hello")
    trunks.seen("public", lambda e: e.get("listed"))

    # A stand-in for the Terminology Google Doc ("mobilebasic" HTML: one table per category,
    # rows of term | definition | GIF). Images only answer at the "=s650" URL, so the
    # downloader's "=s0" (original size) attempt fails first, like a doc without originals.
    from PIL import Image, ImageDraw
    import http.server
    gifs = {}
    def make_gif(color, n):
        import io
        frames = []
        for i in range(n):
            im = Image.new("RGB", (650, 366), (20, 30, 60))
            d = ImageDraw.Draw(im)
            d.ellipse([40 + i * 40, 120, 160 + i * 40, 240], fill=color)
            d.text((12, 12), f"demo frame {i}", fill=(255, 255, 255))
            frames.append(im)
        buf = io.BytesIO()
        frames[0].save(buf, "GIF", save_all=True, append_images=frames[1:], duration=80, loop=0)
        return buf.getvalue()
    rows = {"Movement": [("Drifting", [(255, 200, 0)]), ("Dashing", [(0, 200, 255)])],
            "Blast-2": [("Blast-2 Boost", [(255, 80, 80), (80, 255, 80)])],
            "Defense": [("Emergency Blaster Wave (EBW/Double L1)", [])]}
    html = ["<html><body>"]
    for cat, terms in rows.items():
        html.append(f"<h1>{cat}</h1><table><tbody>")
        for term, colors in terms:
            imgs = ""
            for k, c in enumerate(colors):
                name = f"img{len(gifs)}"
                gifs[name + "=s650"] = make_gif(c, 10)
                imgs += f'<span><img alt="" src="DOCURL/docs-images-rt/{name}=s650" title=""></span>'
            html.append(f'<tr class="c1"><td class="c2" colspan="1"><p><span>{term.replace("&", "&amp;")}</span></p></td>'
                        f'<td><p><span>Definition &amp; more</span></p></td><td><p>{imgs}</p></td></tr>')
        html.append("</tbody></table>")
    html.append("</body></html>")

    class DocHandler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            if self.path == "/doc/mobilebasic":
                body, ctype = "".join(html).replace("DOCURL", doc_url).encode(), "text/html"
            elif self.path.startswith("/docs-images-rt/") and self.path.split("/")[-1] in gifs:
                body, ctype = gifs[self.path.split("/")[-1]], "image/gif"
            else:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    doc_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DocHandler)
    doc_url = f"http://127.0.0.1:{doc_server.server_address[1]}"
    threading.Thread(target=doc_server.serve_forever, daemon=True).start()

    # The current mapping, as 1_setup.bat would have copied it (ports 1 and 2).
    with open(os.path.join(godot_user, "Config", "GCPadNew.ini"), "w") as f:
        f.write("[GCPad1]\nDevice = XInput/0/Gamepad\nButtons/A = `Button X`\n"
                "[GCPad2]\nDevice = XInput/1/Gamepad\nButtons/A = `Button X`\n")

    # Menu music: main_menu (also the fallback) and lobby; game_menu falls back to main_menu.
    os.makedirs(os.path.join(data, "music"), exist_ok=True)
    for name, freq in (("main_menu", 440), ("lobby", 660)):
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                        f"sine=frequency={freq}:duration=20", "-c:a", "libvorbis",
                        os.path.join(data, "music", name + ".ogg")], check=True)

    # One sound effect file, to check SparkingData\sounds is used (the rest stay empty).
    os.makedirs(os.path.join(data, "sounds"), exist_ok=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=880:duration=0.1",
                    os.path.join(data, "sounds", "select.wav")], check=True)

    config = os.path.join(work, "tour.json")
    with open(config, "w") as f:
        json.dump({
            "out_dir": out_dir,
            "settings_file": os.path.join(work, "settings.cfg"),
            "settings": {
                "paths": {"dolphin": exe, "game": dol, "data": data, "profile": "user",
                          "extra_args": " ".join(COMMON)},
                "player": {"nickname": "Goku", "region": "EU"},
                "netplay": {"public": True, "mode": "single", "traversal": True,
                            "public_address": "127.0.0.1", "find_mode": "any", "buffer": 4},
                "options": {"minimize_while_playing": False, "buttons": "Vanilla", "language": "en"},
                "controller": {"preset": "keep"},
                "terminology": {"source": doc_url + "/doc/mobilebasic"},
            },
        }, f)

    # A fake Discord app (Rich Presence IPC on $XDG_RUNTIME_DIR/discord-ipc-0): records every
    # activity the frontend's presence helper sends.
    activities = []
    discord_dir = os.path.join(work, "discord")
    os.makedirs(discord_dir)
    threading.Thread(target=fake_discord, args=(os.path.join(discord_dir, "discord-ipc-0"), activities),
                     daemon=True).start()
    env = dict(os.environ, XDG_RUNTIME_DIR=discord_dir)

    cmd = ["xvfb-run", "-a", "-s", "-screen 0 1280x720x24", *os.environ.get("TOUR_WRAP", "").split(), godot, "--path",
           os.path.join(ROOT, "Frontend", "Godot"), "--rendering-driver", "opengl3",
           "--", "--ui-tour", config]
    # stdin must be open: on Linux, Godot 4.3's execute_with_pipe breaks the child's stdin when
    # the frontend's own fd 0 is closed (the pipe lands on fd 0 and gets closed in the child).
    tour = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, bufsize=1, env=env)
    joiner = None
    result = None
    # Watchdog: a broken script leaves Godot open; don't wait forever.
    def watchdog():
        time.sleep(540)
        if tour.poll() is None:
            print("TOUR TIMEOUT: killing Godot")
            tour.kill()
            subprocess.run(["pkill", "-f", "Godot_v4"], check=False)
    threading.Thread(target=watchdog, daemon=True).start()
    for line in tour.stdout:
        line = line.rstrip("\n")
        if "[SPARKING]" not in line:
            print(line)
        if line == "TOUR_EVENT host_ready":
            joiner = Instance("vegeta", [exe, *COMMON, "-u", joiner_user, "--netplay-join", "127.0.0.1:26300",
                                         "--netplay-game", dol, "--nickname", "Vegeta", "--link", "wireless",
                                         *netplay_codes])
            joiner.send("hello")
            joiner.seen("lobby_ready")
            joiner.send("chat hello from Vegeta")
        elif line in ("TOUR_EVENT joiner_leave", "TOUR_EVENT host_left") and joiner and joiner.proc.poll() is None:
            joiner.send("quit")
        elif line.startswith("TOUR_RESULT"):
            result = line.split()[1]
    tour.wait(timeout=30)
    for inst in (piccolo, trunks, joiner):
        if inst and inst.proc.poll() is None:
            inst.send("quit")
            try:
                inst.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                inst.proc.kill()
    print("discord presence seen:")
    for a in activities:
        print("   ", json.dumps(a))
    def seen(pred):
        return any(pred(a) for a in activities if a)
    discord_ok = True
    for label, pred in [
        ("menus", lambda a: a.get("details") == "In the menus" and a.get("assets", {}).get("large_image") == "sparklaunchpadbackround"
            and a.get("assets", {}).get("small_image") == "dbzsparkhdbackup" and a.get("timestamps", {}).get("start")),
        ("hosted public lobby with Ask to Join", lambda a: a.get("details") == "Single Battle lobby"
            and str(a.get("secrets", {}).get("join", "")).startswith("spk1:") and a.get("party", {}).get("size")),
        ("netplay match vs the other player", lambda a: a.get("details") == "DRAGON NET: Single Battle" and a.get("state") == "vs Vegeta"),
        ("buffer training", lambda a: a.get("details") == "DRAGON NET: Buffer Training"
            and str(a.get("state", "")).startswith("Practicing") and not a.get("secrets") and not a.get("party")),
        ("offline game", lambda a: a.get("state") == "Playing offline"),
    ]:
        ok = seen(pred)
        discord_ok = discord_ok and ok
        print(f"  {'ok  ' if ok else 'FAIL'} discord presence: {label}")
    if not discord_ok:
        result = "discord_failed"
    print("godot exit code:", tour.returncode)
    print("screenshots:", out_dir)
    print("UI TOUR", "PASSED" if result == "ok" and tour.returncode == 0 else "FAILED")
    sys.exit(0 if result == "ok" else 1)


if __name__ == "__main__":
    main()
