#!/usr/bin/env python3
"""Tests automatic updates end to end:

  - a stand-in for Cloudflare R2 (the S3 API: PUT / GET / DELETE / list, every request's AWS
    Signature Version 4 checked, presigned links' expiry too);
  - the real ranked server (Server/ranked, PHP on SQLite) with update.php;
  - the real release script (Tools/sparking_release.py: keygen, publish, prune);
  - the real launcher (headless Godot, tests/update_check.gd) updating a fake install.

    python3 Tools/update_test.py <godot binary>
"""
import datetime
import hashlib
import hmac
import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Tools"))
import sparking_release as release  # noqa: E402
from ranked_server_test import RankedServer, login, call, free_port  # noqa: E402

KEY, SECRET, BUCKET = "test-access-key", "test-secret-key-0123456789", "updates"


class FakeR2:
    def __init__(self):
        self.objects = {}
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        self.gets = []          # object keys downloaded through presigned links
        self.rejected = 0
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def _reply(self, code, body=b"", ctype="application/octet-stream"):
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _key(self, path):
                parts = urllib.parse.unquote(path).split("/", 2)
                if len(parts) < 2 or parts[1] != BUCKET:
                    return None
                return parts[2] if len(parts) > 2 else ""

            def _header_auth_ok(self, method, path, query):
                auth = self.headers.get("Authorization", "")
                if not auth.startswith("AWS4-HMAC-SHA256 "):
                    return False
                fields = dict(p.strip().split("=", 1) for p in auth[17:].split(","))
                signed = fields["SignedHeaders"].split(";")
                hdrs = {h: self.headers.get(h, "") for h in signed
                        if h not in ("host", "x-amz-date", "x-amz-content-sha256")}
                at = datetime.datetime.strptime(self.headers["x-amz-date"], "%Y%m%dT%H%M%SZ").replace(
                    tzinfo=datetime.timezone.utc)
                if abs((datetime.datetime.now(datetime.timezone.utc) - at).total_seconds()) > 900:
                    return False
                want = release.R2.authorization(method, self.headers["Host"], urllib.parse.unquote(path), query,
                                                hdrs, self.headers["x-amz-content-sha256"], KEY, SECRET,
                                                "auto", at)
                return hmac.compare_digest(want["authorization"], auth)

            def _presign_ok(self, path, query):
                q = dict(query)
                sig = q.pop("X-Amz-Signature", "")
                stamp = q["X-Amz-Date"]
                at = datetime.datetime.strptime(stamp, "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.timezone.utc)
                if (datetime.datetime.now(datetime.timezone.utc) - at).total_seconds() > int(q["X-Amz-Expires"]):
                    return False
                if q["X-Amz-Credential"] != f"{KEY}/{stamp[:8]}/auto/s3/aws4_request":
                    return False
                qs = "&".join(f"{urllib.parse.quote(k, safe='-_.~')}={urllib.parse.quote(v, safe='-_.~')}"
                              for k, v in sorted(q.items()))
                canonical = f"GET\n{path}\n{qs}\nhost:{self.headers['Host']}\n\nhost\nUNSIGNED-PAYLOAD"
                to_sign = f"AWS4-HMAC-SHA256\n{stamp}\n{stamp[:8]}/auto/s3/aws4_request\n" \
                          + hashlib.sha256(canonical.encode()).hexdigest()
                k = hmac.new(("AWS4" + SECRET).encode(), stamp[:8].encode(), hashlib.sha256).digest()
                for part in ("auto", "s3", "aws4_request"):
                    k = hmac.new(k, part.encode(), hashlib.sha256).digest()
                return hmac.compare_digest(hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest(), sig)

            def _route(self, method):
                url = urllib.parse.urlsplit(self.path)
                query = dict(urllib.parse.parse_qsl(url.query, keep_blank_values=True))
                key = self._key(url.path)
                body = b""
                if "Content-Length" in self.headers:
                    body = self.rfile.read(int(self.headers["Content-Length"]))
                if key is None:
                    return self._reply(404)
                if "X-Amz-Signature" in query:
                    if method != "GET" or not self._presign_ok(url.path, query):
                        outer.rejected += 1
                        return self._reply(403, b"<Error>SignatureDoesNotMatch</Error>")
                    if key not in outer.objects:
                        return self._reply(404)
                    outer.gets.append(key)
                    return self._reply(200, outer.objects[key])
                if not self._header_auth_ok(method, url.path, query):
                    outer.rejected += 1
                    return self._reply(403, b"<Error>SignatureDoesNotMatch</Error>")
                if method == "PUT":
                    outer.objects[key] = body
                    return self._reply(200)
                if method == "DELETE":
                    outer.objects.pop(key, None)
                    return self._reply(204)
                if method == "GET" and key == "" and query.get("list-type") == "2":
                    keys = sorted(k for k in outer.objects if k.startswith(query.get("prefix", "")))
                    xml = "".join(f"<Contents><Key>{k}</Key></Contents>" for k in keys)
                    return self._reply(200, (f'<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                                             f"{xml}<IsTruncated>false</IsTruncated></ListBucketResult>").encode(),
                                       "application/xml")
                if method == "GET":
                    if key not in outer.objects:
                        return self._reply(404)
                    return self._reply(200, outer.objects[key])
                return self._reply(400)

            def do_GET(self):
                self._route("GET")

            def do_PUT(self):
                self._route("PUT")

            def do_DELETE(self):
                self._route("DELETE")

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def read(path):
    with open(path, "rb") as f:
        return f.read()


def main():
    godot = sys.argv[1]
    work = tempfile.mkdtemp(prefix="sparking-update-")
    failures = []

    def check(label, cond):
        print(("  ok   " if cond else "  FAIL ") + label)
        if not cond:
            failures.append(label)

    r2 = FakeR2()
    server = RankedServer(work)
    try:
        # Before the server has R2 settings: a clear "not set up".
        p, _ = login(server, "goku")
        token = p["token"]
        status, r = call(server, "update.php", token, action="check")
        check("update.php without R2 settings: updates_not_set_up", status == 503 and r.get("error") == "updates_not_set_up")
        status, r = call(server, "update.php", None, action="check")
        check("update.php needs a login", status == 401)
        server.write_config(report_grace=3, r2_account_id="acc", r2_access_key=KEY, r2_secret_key=SECRET,
                            r2_bucket=BUCKET, r2_endpoint=r2.url)
        time.sleep(1.1)   # (a config rewritten within the same second can still be read stale)
        status, r = call(server, "update.php", token, action="files", files=["../etc"])
        check("update.php refuses a file that isn't a hash", status == 400)

        # The release key, and the release config (as on the user's PC).
        subprocess.run([sys.executable, os.path.join(ROOT, "Tools", "sparking_release.py"), "keygen",
                        os.path.join(work, "keys")], check=True, stdout=subprocess.DEVNULL)
        cfg = os.path.join(work, "release.json")
        with open(cfg, "w") as f:
            json.dump({"r2_account_id": "acc", "r2_endpoint": r2.url, "r2_access_key": KEY,
                       "r2_secret_key": SECRET, "r2_bucket": BUCKET,
                       "private_key": os.path.join(work, "keys", "release_private.pem"),
                       "launcher": "Launcher.exe"}, f)

        def publish(build, version, extra=()):
            out = subprocess.run([sys.executable, os.path.join(ROOT, "Tools", "sparking_release.py"), "publish",
                                  build, "--config", cfg, "--version", version, *extra],
                                 capture_output=True, text=True)
            if out.returncode:
                print(out.stdout, out.stderr)
            return out

        # Build 1, installed on a player's PC (with their own files next to it).
        b1 = os.path.join(work, "build1")
        write(os.path.join(b1, "Launcher.exe"), b"launcher v1")
        write(os.path.join(b1, "Launcher.pck"), b"menus v1")
        write(os.path.join(b1, "Dolphin/DolphinNoGUI.exe"), b"dolphin v1")
        write(os.path.join(b1, "Dolphin/Sys/GameSettings/RDSPAF.ini"), b"[Gecko]\nv1\n")
        write(os.path.join(b1, "Dolphin/Sys/GameSettings/OLD.ini"), b"goes away in v2")
        write(os.path.join(b1, "SparkingData/states/RDSPAF-SingleBattle.sav"), os.urandom(300000))
        write(os.path.join(b1, "SparkingData/textures/RDSPAF/big.png"), os.urandom(3 * 1048576 + 123))   # hashed in pieces
        write(os.path.join(b1, "SparkingData/settings.bat"), b"the developer's own: not shipped")
        write(os.path.join(b1, "SparkingData/saves/netplay/RDSPAF/title/00010000/52445350/data/DBZT3"), b"unlocked save")
        write(os.path.join(b1, "SparkingData/saves/netplay/RDSPAF/shared2/sys/SYSCONF"), b"this PC's Wii settings")
        write(os.path.join(b1, "SparkingData/saves/solo/title/00010000/52445350/data/DBZT3"), b"developer's progress")
        out = publish(b1, "205")
        check("publish build 205", out.returncode == 0 and "Published windows version 205" in out.stdout)
        paths1 = {f["path"] for f in json.loads(release.base64.b64decode(
            json.loads(r2.objects["manifest.json"])["manifest"]))["files"]}
        check("the DRAGON NET save is in the update, Dolphin's own NAND files and solo saves aren't",
              "SparkingData/saves/netplay/RDSPAF/title/00010000/52445350/data/DBZT3" in paths1
              and not any("SYSCONF" in p or "/solo/" in p for p in paths1))
        check("the developer's .bat isn't in the update", "settings.bat" not in json.dumps(
            list(r2.objects)) and not any(b"the developer" in v for v in r2.objects.values()))
        install = os.path.join(work, "install")
        shutil.copytree(b1, install)
        write(os.path.join(install, "SparkingData/saves/netplay/RDSPAF/save.bin"), b"player's save")
        write(os.path.join(install, "SparkingData/frontend.cfg"), b"player's settings")

        settings = os.path.join(work, "frontend.cfg")
        with open(settings, "w") as f:
            f.write(f'[ranked]\nserver="{server.url}"\ntoken="{token}"\nname="Goku"\n'
                    f'[update]\nroot="{install}"\nkey="{os.path.join(work, "keys", "release_public.pem")}"\n'
                    f'platform="windows"\n')

        def run_launcher(own="Launcher.exe,Launcher.pck", hitch=0, pack="", action=""):
            env = dict(os.environ, UPDATE_OWN=own, UPDATE_HITCH_MS=str(hitch), UPDATE_PACK=pack,
                       UPDATE_ACTION=action)
            p = subprocess.run([godot, "--headless", "--path", os.path.join(ROOT, "Frontend", "Godot"),
                                "--", "--update-check", settings], capture_output=True, text=True, env=env,
                               timeout=180)
            for line in p.stdout.splitlines():
                if "SCRIPT ERROR" in line:
                    print("   ", line[:200])
                if line.startswith("UPDATE_RESULT "):
                    return json.loads(line[len("UPDATE_RESULT "):])
            print(p.stdout[-3000:], p.stderr[-3000:])
            return {}

        res = run_launcher()
        check(f"same build: up to date {res}", res.get("state") == "up_to_date" and res.get("version") == "205")
        check("installed.json written", os.path.exists(os.path.join(install, "SparkingData/update/installed.json")))

        # Build 206: a new ini, a changed state, a new texture, OLD.ini gone, new launcher.
        b2 = os.path.join(work, "build2")
        shutil.copytree(b1, b2)
        os.remove(os.path.join(b2, "Dolphin/Sys/GameSettings/OLD.ini"))
        write(os.path.join(b2, "Dolphin/Sys/GameSettings/RDSPAF.ini"), b"[Gecko]\nv2\n")
        write(os.path.join(b2, "SparkingData/states/RDSPAF-SingleBattle.sav"), os.urandom(400000))
        write(os.path.join(b2, "SparkingData/textures/RDSPAF/@Buttons/x.png"), b"png v2")
        write(os.path.join(b2, "Launcher.pck"), b"menus v2")
        gets_before = len(r2.gets)
        out = publish(b2, "206", ["--notes", "New codes"])
        check("publish build 206 uploads only the 4 new files",
              out.returncode == 0 and "Uploading 4 new files" in out.stdout)
        res = run_launcher()
        check(f"build 206: installed, restart for the launcher's own file {res}",
              res.get("state") == "restarting" and res.get("version") == "206" and res.get("files") == 4
              and res.get("restarted"))
        check("only the changed files were downloaded (+ the list)",
              sorted(set(r2.gets[gets_before:])) == sorted(
                  {"manifest.json"} | {"files/" + hashlib.sha256(read(os.path.join(b2, p))).hexdigest()
                                        for p in ("Dolphin/Sys/GameSettings/RDSPAF.ini",
                                                  "SparkingData/states/RDSPAF-SingleBattle.sav",
                                                  "SparkingData/textures/RDSPAF/@Buttons/x.png",
                                                  "Launcher.pck")}))
        for rel in ("Dolphin/Sys/GameSettings/RDSPAF.ini", "SparkingData/states/RDSPAF-SingleBattle.sav",
                    "SparkingData/textures/RDSPAF/@Buttons/x.png"):
            check(f"updated: {rel}", read(os.path.join(install, rel)) == read(os.path.join(b2, rel)))
        check("removed: OLD.ini (gone from the build)",
              not os.path.exists(os.path.join(install, "Dolphin/Sys/GameSettings/OLD.ini")))
        check("player's save and settings untouched",
              read(os.path.join(install, "SparkingData/saves/netplay/RDSPAF/save.bin")) == b"player's save"
              and read(os.path.join(install, "SparkingData/frontend.cfg")) == b"player's settings")
        check("the running launcher's .pck waits for the restart script",
              read(os.path.join(install, "Launcher.pck")) == b"menus v1")
        script = os.path.join(install, "SparkingData/update/finish_update.sh")
        check("restart script written", os.path.exists(script))
        check("downloads are kept under their final names (nothing to rename)",
              not any(n.endswith(".part") for n in os.listdir(os.path.join(install, "SparkingData/update/download"))))
        # The restart happened but the files didn't get in (Windows held them): starting again must
        # not restart again (it looped: restart, same update, restart...).
        res = run_launcher()
        check(f"a restart that didn't install the files doesn't loop {res}",
              res.get("state") == "failed" and "couldn't replace" in res.get("error", "") and not res.get("restarted"))
        if os.path.exists(script):
            subprocess.run(["/bin/sh", script], check=True, timeout=30)   # (the launcher has exited)
        check("restart script put the new .pck in", read(os.path.join(install, "Launcher.pck")) == b"menus v2")
        res = run_launcher()
        check(f"after the restart: up to date {res}", res.get("state") == "up_to_date" and res.get("version") == "206")

        # A player's file edited / damaged: put back to the build's. The launcher hangs for 25 s
        # just before asking for the links (build 206's hashing freeze made them "time out").
        write(os.path.join(install, "Dolphin/Sys/GameSettings/RDSPAF.ini"), b"edited by hand")
        res = run_launcher(hitch=25000)
        check(f"an edited managed file is restored, even after a 25 s hang {res}", res.get("state") == "up_to_date" and res.get("files") == 1
              and read(os.path.join(install, "Dolphin/Sys/GameSettings/RDSPAF.ini")) == b"[Gecko]\nv2\n")

        # Attacks: a list not signed by the release key; a file swapped on the bucket.
        good = r2.objects["manifest.json"]
        env = json.loads(good)
        m = json.loads(release.base64.b64decode(env["manifest"]))
        m["files"][0]["sha256"] = "0" * 64
        env["manifest"] = release.base64.b64encode(json.dumps(m).encode()).decode()
        r2.objects["manifest.json"] = json.dumps(env).encode()
        res = run_launcher()
        check(f"a list not signed by the release key is refused {res}",
              res.get("state") == "failed" and "signed" in res.get("error", ""))
        r2.objects["manifest.json"] = good
        b3 = os.path.join(work, "build3")
        shutil.copytree(b2, b3)
        write(os.path.join(b3, "Dolphin/DolphinNoGUI.exe"), b"dolphin v3")
        publish(b3, "207")
        sha = hashlib.sha256(b"dolphin v3").hexdigest()
        r2.objects["files/" + sha] = b"malware!!!"
        res = run_launcher()
        check(f"a file that doesn't match the signed hash is refused {res}",
              res.get("state") == "failed" and read(os.path.join(install, "Dolphin/DolphinNoGUI.exe")) == b"dolphin v1")
        r2.objects["files/" + sha] = b"dolphin v3"
        res = run_launcher()
        check(f"build 207 then installs {res}", res.get("state") == "up_to_date"
              and read(os.path.join(install, "Dolphin/DolphinNoGUI.exe")) == b"dolphin v3")

        # --- Packs: the Enhanced textures, an optional download --------------------------------
        enh = "SparkingData/textures/RDSPAF/@Graphics/Enhanced/"
        b4 = os.path.join(work, "build4")
        shutil.copytree(b3, b4)
        write(os.path.join(b4, enh + "a.png"), os.urandom(1048576 + 7))
        write(os.path.join(b4, enh + "menus/b.png"), b"hd menu v1")
        out = publish(b4, "208")
        m = json.loads(release.base64.b64decode(json.loads(r2.objects["manifest.json"])["manifest"]))
        tagged = {f["path"]: f.get("pack") for f in m["files"]}
        check(f"publish: the Enhanced textures are an optional pack ({out.stdout.strip().splitlines()[1:3]})",
              out.returncode == 0 and "optional \"Enhanced textures\"" in out.stdout
              and tagged.get(enh + "a.png") == "enhanced_textures" and tagged.get(enh + "menus/b.png") == "enhanced_textures"
              and tagged.get("SparkingData/textures/RDSPAF/@Buttons/x.png") is None
              and m["packs"]["enhanced_textures"]["files"] == 2)
        pack_shas = {"files/" + hashlib.sha256(read(os.path.join(b4, enh + n))).hexdigest() for n in ("a.png", "menus/b.png")}
        gets_before = len(r2.gets)
        res = run_launcher()
        check(f"the update leaves the pack out for a player who doesn't have it {res}",
              res.get("state") == "up_to_date" and res.get("version") == "208"
              and not pack_shas & set(r2.gets[gets_before:]) and not os.path.exists(os.path.join(install, enh)))
        res = run_launcher(pack="enhanced_textures", action="info")
        check(f"pack info: known, not installed, its size {res.get('pack')}",
              res["pack"].get("known") and not res["pack"].get("installed") and res["pack"].get("present") == 0
              and res["pack"].get("bytes") == 1048576 + 7 + len(b"hd menu v1") and not res["pack"].get("wanted"))
        b5 = os.path.join(work, "build5")
        shutil.copytree(b4, b5)
        write(os.path.join(b5, "Dolphin/Sys/GameSettings/RDSPAF.ini"), b"[Gecko]\nv3\n")
        publish(b5, "209")
        gets_before = len(r2.gets)
        res = run_launcher(pack="enhanced_textures", action="install")
        check(f"Download: only the pack, not the waiting update {res}",
              res.get("state") == "up_to_date" and res.get("files") == 2
              and set(r2.gets[gets_before:]) == {"manifest.json"} | pack_shas
              and read(os.path.join(install, enh + "menus/b.png")) == b"hd menu v1"
              and read(os.path.join(install, "Dolphin/Sys/GameSettings/RDSPAF.ini")) == b"[Gecko]\nv2\n"
              and res.get("installed_version") == "208" and res["pack"].get("installed"))
        res = run_launcher()
        check(f"then the update installs build 209 and keeps the pack {res}",
              res.get("state") == "up_to_date" and res.get("files") == 1
              and read(os.path.join(install, "Dolphin/Sys/GameSettings/RDSPAF.ini")) == b"[Gecko]\nv3\n"
              and os.path.exists(os.path.join(install, enh + "a.png")))
        b6 = os.path.join(work, "build6")
        shutil.copytree(b5, b6)
        write(os.path.join(b6, enh + "menus/b.png"), b"hd menu v2")
        publish(b6, "210")
        res = run_launcher()
        check(f"a chosen pack is kept up to date by the updates {res}",
              res.get("state") == "up_to_date" and res.get("files") == 1
              and read(os.path.join(install, enh + "menus/b.png")) == b"hd menu v2")
        res = run_launcher(pack="enhanced_textures", action="remove")
        check(f"Remove: the pack's files and emptied folders gone, the rest kept {res.get('removed')}",
              res.get("removed") == 2 and not os.path.exists(os.path.join(install, "SparkingData/textures/RDSPAF/@Graphics"))
              and os.path.exists(os.path.join(install, "SparkingData/textures/RDSPAF/@Buttons/x.png"))
              and not res["pack"].get("wanted"))
        gets_before = len(r2.gets)
        res = run_launcher()
        check(f"after Remove the update doesn't bring it back {res}",
              res.get("state") == "up_to_date" and set(r2.gets[gets_before:]) == {"manifest.json"}
              and not os.path.exists(os.path.join(install, enh)))
        # Copied in by hand (or kept from an older install): found, kept up to date, nothing downloaded.
        write(os.path.join(install, enh + "a.png"), read(os.path.join(b6, enh + "a.png")))
        write(os.path.join(install, enh + "menus/b.png"), b"hd menu v1")   # an older copy
        res = run_launcher(pack="enhanced_textures", action="info")
        check(f"files already here are found {res.get('pack')}",
              res["pack"].get("installed") and res["pack"].get("wanted"))
        gets_before = len(r2.gets)
        res = run_launcher()
        check(f"...and only the out-of-date one is downloaded {res}",
              res.get("files") == 1 and res.get("state") == "up_to_date"
              and set(r2.gets[gets_before:]) == {"manifest.json", "files/" + hashlib.sha256(b"hd menu v2").hexdigest()}
              and read(os.path.join(install, enh + "menus/b.png")) == b"hd menu v2")
        gets_before = len(r2.gets)
        res = run_launcher(pack="enhanced_textures", action="install")
        check(f"Download with everything here: nothing to download {res}",
              res.get("state") == "up_to_date" and res.get("files") == 0 and set(r2.gets[gets_before:]) == {"manifest.json"})
        b3 = b6   # (the later tests compare against the current build)

        # An older signed list put back on the bucket: never installed over a newer build.
        current = r2.objects["manifest.json"]
        old = r2.objects[sorted(k for k in r2.objects if k.startswith("manifests/"))[0]]
        r2.objects["manifest.json"] = old
        res = run_launcher()
        check(f"an older build's list doesn't downgrade {res}", res.get("state") == "up_to_date"
              and read(os.path.join(install, "Dolphin/DolphinNoGUI.exe")) == b"dolphin v3")
        r2.objects["manifest.json"] = current

        # Not logged in: nothing happens.
        with open(settings) as f:
            s = f.read()
        with open(settings, "w") as f:
            f.write(s.replace(f'token="{token}"', 'token=""'))
        res = run_launcher()
        check(f"not logged in: no update {res}", res.get("state") == "no_login")

        # A login that expired on the server: "log in again", not "can't reach".
        with open(settings, "w") as f:
            f.write(s.replace(f'token="{token}"', 'token="' + "x" * 40 + '"'))
        res = run_launcher()
        check(f"an expired login: asks to log in {res}", res.get("state") == "no_login")

        # --- Linux: its own list, the same file store -----------------------------------------
        import stat
        l1 = os.path.join(work, "linux1")
        write(os.path.join(l1, "Launcher.x86_64"), b"#!/bin/sh\ntouch \"$(dirname \"$0\")/relaunched\"\n")
        write(os.path.join(l1, "Launcher.pck"), b"linux menus v1")
        write(os.path.join(l1, "Dolphin/dolphin-emu-nogui"), b"#!/bin/sh\necho v1\n")
        write(os.path.join(l1, "Dolphin/Sys/GameSettings/RDSPAF.ini"), read(os.path.join(b3, "Dolphin/Sys/GameSettings/RDSPAF.ini")))
        write(os.path.join(l1, "SparkingData/states/RDSPAF-SingleBattle.sav"),
              read(os.path.join(b3, "SparkingData/states/RDSPAF-SingleBattle.sav")))
        win_list = r2.objects["manifest.json"]
        out = publish(l1, "207", ["--platform", "linux"])
        check(f"Linux build: only its own files uploaded (the ini and state are shared) [{out.stdout.strip().splitlines()[-2:]}]",
              out.returncode == 0 and "Uploading 3 new files" in out.stdout and "manifest-linux.json" in r2.objects)
        check("publishing for Linux leaves the Windows list alone", r2.objects["manifest.json"] == win_list)
        out = publish(b3, "207", ["--platform", "linux"])
        check("a Windows build folder published as Linux is refused", out.returncode != 0)
        linst = os.path.join(work, "linst")
        shutil.copytree(l1, linst)
        for rel in ("Launcher.x86_64", "Dolphin/dolphin-emu-nogui"):
            os.chmod(os.path.join(linst, rel), 0o644)   # unpacked from a Windows-made archive
        lset = os.path.join(work, "linux.cfg")
        with open(lset, "w") as f:
            f.write(f'[ranked]\nserver="{server.url}"\ntoken="{token}"\nname="Goku"\n'
                    f'[update]\nroot="{linst}"\nkey="{os.path.join(work, "keys", "release_public.pem")}"\n'
                    f'platform="linux"\n')
        settings_win = settings
        settings = lset
        res = run_launcher(own="Launcher.x86_64,Launcher.pck")
        check(f"Linux install: up to date on its own list {res}", res.get("state") == "up_to_date")
        l2 = os.path.join(work, "linux2")
        shutil.copytree(l1, l2)
        write(os.path.join(l2, "Dolphin/dolphin-emu-nogui"), b"#!/bin/sh\necho v2\n")
        write(os.path.join(l2, "Launcher.pck"), b"linux menus v2")
        publish(l2, "208", ["--platform", "linux"])
        res = run_launcher(own="Launcher.x86_64,Launcher.pck")
        dolphin = os.path.join(linst, "Dolphin/dolphin-emu-nogui")
        check(f"Linux update: Dolphin replaced and executable again {res}",
              res.get("state") == "restarting" and read(dolphin) == b"#!/bin/sh\necho v2\n"
              and os.stat(dolphin).st_mode & stat.S_IXUSR)
        script = os.path.join(linst, "SparkingData/update/finish_update.sh")
        subprocess.run(["/bin/sh", script], check=True, timeout=60)
        for _ in range(50):
            if os.path.exists(os.path.join(linst, "relaunched")):
                break
            time.sleep(0.1)
        logtext = open(os.path.join(linst, "SparkingData/update/finish_update.log")).read()
        check("Linux restart script: new .pck in, launcher executable and started again, logged",
              read(os.path.join(linst, "Launcher.pck")) == b"linux menus v2"
              and os.stat(os.path.join(linst, "Launcher.x86_64")).st_mode & stat.S_IXUSR
              and os.path.exists(os.path.join(linst, "relaunched")) and "launcher started" in logtext)
        res = run_launcher(own="Launcher.x86_64,Launcher.pck")
        check(f"Linux install: up to date after the restart {res}", res.get("state") == "up_to_date" and res.get("version") == "208")
        # A Windows launcher handed the Linux list (server mix-up) refuses it.
        settings = settings_win
        with open(settings, "w") as f:
            f.write(f'[ranked]\nserver="{server.url}"\ntoken="{token}"\nname="Goku"\n'
                    f'[update]\nroot="{install}"\nkey="{os.path.join(work, "keys", "release_public.pem")}"\n'
                    f'platform="windows"\n')
        r2.objects["manifest.json"] = r2.objects["manifest-linux.json"]
        res = run_launcher()
        check(f"a Windows launcher refuses the Linux list {res}",
              res.get("state") == "failed" and "another system" in res.get("error", ""))
        r2.objects["manifest.json"] = win_list

        # Prune: files only the oldest builds used.
        out = subprocess.run([sys.executable, os.path.join(ROOT, "Tools", "sparking_release.py"), "prune",
                              "--config", cfg, "--keep", "1", "--yes"], capture_output=True, text=True)
        live = {"files/" + f["sha256"] for k in ("manifest.json", "manifest-linux.json")
                for f in json.loads(release.base64.b64decode(json.loads(r2.objects[k])["manifest"]))["files"]}
        check(f"prune keeps exactly the current builds' files, Windows and Linux ({out.stdout.strip()})",
              {k for k in r2.objects if k.startswith("files/")} == live)
        check("no request had a bad signature", r2.rejected == 0)
    finally:
        server.stop()
        r2.httpd.shutdown()
    print("UPDATE TEST " + ("PASSED" if not failures else f"FAILED ({len(failures)})"))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
