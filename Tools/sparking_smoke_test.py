#!/usr/bin/env python3
"""End-to-end smoke test for the Dolphin-Sparking frontend protocol (Docs/SPARKING.md).

Spawns a netplay host and a joiner as separate dolphin-emu-nogui processes on localhost, drives
them only through stdin commands, and asserts on the [SPARKING] events they print. Uses a tiny
generated DOL (a single `b .` loop) as the "game" so no disc image is needed.

    python3 Tools/sparking_smoke_test.py path/to/dolphin-emu-nogui
"""

import json
import os
import queue
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time

PREFIX = "[SPARKING] "


def make_test_dol(path):
    """GameCube DOL whose entry point is an infinite loop at 0x80003100."""
    code = struct.pack(">I", 0x48000000).ljust(0x20, b"\0")  # b .
    header = bytearray(0x100)
    struct.pack_into(">I", header, 0x00, 0x100)          # text0 file offset
    struct.pack_into(">I", header, 0x48, 0x80003100)     # text0 load address
    struct.pack_into(">I", header, 0x90, len(code))      # text0 size
    struct.pack_into(">I", header, 0xD8, 0x80003200)     # bss address
    struct.pack_into(">I", header, 0xDC, 0)              # bss size
    struct.pack_into(">I", header, 0xE0, 0x80003100)     # entry point
    with open(path, "wb") as f:
        f.write(header + code)


class Instance:
    def __init__(self, name, argv):
        self.name = name
        self.events = queue.Queue()
        self.history = []  # every event ever received, for order-independent checks
        self.log = []
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            line = line.rstrip("\n")
            self.log.append(line)
            if line.startswith(PREFIX):
                ev = json.loads(line[len(PREFIX):])
                self.history.append(ev)
                self.events.put(ev)
        self.events.put({"event": "__eof__"})

    def send(self, cmd):
        self.proc.stdin.write(cmd + "\n")
        self.proc.stdin.flush()

    def seen(self, event, pred=lambda e: True, timeout=20):
        """Like wait_for, but also matches events that already arrived (any order)."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            for e in list(self.history):
                if e["event"] == event and pred(e):
                    return e
            time.sleep(0.1)
        raise AssertionError(f"{self.name}: never saw '{event}'")

    def wait_for(self, event, pred=lambda e: True, timeout=20):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                e = self.events.get(timeout=max(0.05, deadline - time.time()))
            except queue.Empty:
                break
            if e["event"] == event and pred(e):
                return e
            if e["event"] == "__eof__":
                break
        tail = "\n    ".join(self.log[-25:])
        raise AssertionError(f"{self.name}: timed out waiting for '{event}'. Last output:\n    {tail}")


def check(label, cond):
    print(("  PASS  " if cond else "  FAIL  ") + label)
    if not cond:
        raise SystemExit(1)


def main():
    exe = os.path.abspath(sys.argv[1])
    work = tempfile.mkdtemp(prefix="sparking-test-")
    dol = os.path.join(work, "sparking_test.dol")
    make_test_dol(dol)

    def user_dir(name):
        d = os.path.join(work, name)
        os.makedirs(os.path.join(d, "Config"))
        with open(os.path.join(d, "Config", "Dolphin.ini"), "w") as f:
            f.write("[NetPlay]\nTraversalChoice = direct\nHostPort = 26262\n"
                    "SyncSaves = False\nSyncCodes = False\n"
                    "[Analytics]\nPermissionAsked = True\nEnabled = False\n")
        return d

    common = ["-p", "headless", "-v", "Null"]
    nands = {n: os.path.join(work, f"nand-{n}") for n in ("solo", "host", "joiner")}
    states = {n: os.path.join(work, f"states-{n}") for n in ("solo", "host", "joiner")}
    for d in states.values():
        os.makedirs(d)
    try:
        print("solo mode")
        solo = Instance("solo", [exe, *common, "--sparking", "-u", user_dir("solo"),
                                 "--state-dir", states["solo"],
                                 "--nand", nands["solo"], "--local-players", "2", "-e", dol])
        check("ready event, mode=solo", solo.wait_for("ready")["mode"] == "solo")
        solo.send("hello")
        check("hello handshake", solo.wait_for("hello")["protocol"] == 1)
        solo.wait_for("game_started")
        check("game_started", True)
        info = solo.seen("game_info")["session"]
        check(f"solo: 2 GameCube pads, no Wii Remotes {info['pads']}",
              info["pads"] == ["gc", "gc", "none", "none"] and set(info["wiimotes"]) == {"none"})
        check("solo: own save folder (NAND)", info["nand"].rstrip("/\\").endswith("nand-solo"))
        check("solo: Dolphin's built-in Discord presence off", info["dolphin_discord"] is False)
        solo.send("save_state 1")
        check("save_state acknowledged", solo.wait_for("state_saved")["slot"] == 1)
        time.sleep(1)
        solo.send("save_state_file battle.sst")
        saved = solo.wait_for("state_file_saved")
        battle = os.path.join(states["solo"], "battle.sst")
        check(f"captured battle state (sha1 {saved['sha1'][:12]}...)",
              os.path.getsize(battle) > 0 and saved["name"] == "battle.sst")
        solo.send("save_state_file ../escape.sst")
        check("path traversal in state name rejected",
              solo.wait_for("error")["code"] == "bad_state_name")
        solo.send("quit")
        check("exit code 0", solo.wait_for("exit")["code"] == 0)
        solo.proc.wait(timeout=20)

        print("netplay: host + joiner")
        # Netplay saves: host has the "unlocked" save, joiner a different one. A DOL has title ID 0,
        # so its Wii save folder is title/00000000/00000000/data inside each NAND.
        def write_save(nand, payload):
            d = os.path.join(nands[nand], "title", "00000000", "00000000", "data")
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "save.bin"), "wb") as f:
                f.write(payload)
        write_save("host", b"ALL-CHARACTERS-UNLOCKED" * 100)
        write_save("joiner", b"FRESH-SAVE" * 100)

        host = Instance("host", [exe, *common, "-u", user_dir("host"), "--netplay-host", dol,
                                 "--state-dir", states["host"], "--nand", nands["host"],
                                 "--nickname", "Goku", "--automap", "gc"])
        host.send("hello")
        check("host lobby_ready", host.wait_for("lobby_ready")["role"] == "host")
        room = host.wait_for("room", lambda e: e["state"] == "ready")
        check(f"room is direct on port 26262 ({room.get('addresses')})",
              room["type"] == "direct" and room["port"] == 26262)

        joiner = Instance("joiner", [exe, *common, "-u", user_dir("joiner"),
                                     "--netplay-join", "127.0.0.1:26262",
                                     "--netplay-game", dol, "--nickname", "Vegeta",
                                     "--state-dir", states["joiner"], "--nand", nands["joiner"]])
        joiner.send("hello")
        check("joiner lobby_ready", joiner.wait_for("lobby_ready")["role"] == "client")
        gc = joiner.wait_for("game_changed")
        check(f"joiner sees host's game, local_status={gc['local_status']}",
              gc["local_status"] == "ok")

        host.wait_for("player_joined", lambda e: e["name"] == "Vegeta")
        both = host.wait_for("players", lambda e: len(e["players"]) == 2 and
                             all(p["gc_slot"] > 0 for p in e["players"]))
        check("automap put both players in GC slots " +
              str({p["name"]: p["gc_slot"] for p in both["players"]}), True)
        check("all_have_game", both["all_have_game"])

        joiner.send("chat kakarot!")
        check("host receives chat", "kakarot!" in host.wait_for("chat")["text"])

        joiner.send("start")
        check("joiner cannot start (host_only)",
              joiner.wait_for("error")["code"] == "host_only")

        print("netplay: save data must match")
        p = host.wait_for("players", lambda e: len(e["players"]) == 2 and
                          any(x["save_status"] == "mismatch" for x in e["players"]))
        check("host sees joiner's save differs (save_status=mismatch)", bool(p))
        check("joiner told its save doesn't match",
              joiner.seen("save_data", lambda e: e.get("local_status") == "mismatch")["host_hash"]
              != "missing")
        host.send("start")
        check("start blocked: save_data_mismatch",
              host.wait_for("error")["code"] == "save_data_mismatch")
        write_save("joiner", b"ALL-CHARACTERS-UNLOCKED" * 100)  # joiner installs the same save
        host.send("save_check")
        host.wait_for("save_data", lambda e: e.get("ready") is True)
        check("after identical saves: every player verified -> ready", True)

        print("netplay: battle state sync")
        shutil.copy(battle, states["host"])
        with open(battle, "rb") as f:
            tampered = bytearray(f.read())
        tampered[-1] ^= 0xFF
        with open(os.path.join(states["joiner"], "battle.sst"), "wb") as f:
            f.write(tampered)

        host.send("battle_state battle.sst")
        bs = host.wait_for("battle_state", lambda e: e["active"])
        check("host selects battle state, matching captured sha1", bs["sha1"] == saved["sha1"])
        jbs = joiner.wait_for("battle_state", lambda e: e["active"])
        check("joiner detects tampered copy (local_ok=false)", jbs["local_ok"] is False)
        p = host.wait_for("players", lambda e: any(x["state_status"] == "mismatch"
                                                   for x in e["players"]))
        check("host sees joiner state_status=mismatch", bool(p))
        host.send("start")
        check("start blocked: battle_state_not_ready",
              host.wait_for("error")["code"] == "battle_state_not_ready")

        shutil.copy(battle, states["joiner"])  # joiner gets the right bytes
        host.send("battle_state battle.sst")
        host.wait_for("battle_state", lambda e: e.get("ready") is True)
        check("after fix, every player verified -> ready", True)

        host.send("start")
        hb = host.wait_for("game_booting", timeout=40)
        jb = joiner.wait_for("game_booting", timeout=40)
        check("both boot with battle state injected",
              hb["battle_state"] == "battle.sst" and jb["battle_state"] == "battle.sst")
        host.wait_for("state_applied", timeout=40)
        joiner.wait_for("state_applied", timeout=40)
        check("state actually loaded on both peers despite netplay", True)
        host.wait_for("game_started", timeout=40)
        joiner.wait_for("game_started", timeout=40)
        check("both instances running the match", True)
        for inst in (host, joiner):
            si = inst.seen("game_info")["session"]
            check(f"{inst.name}: netplay mapped 2 GameCube pads, no Wii Remotes {si}",
                  si["pads"] == ["gc", "gc", "none", "none"] and set(si["wiimotes"]) == {"none"})
            check(f"{inst.name}: netplay uses host save, read-only",
                  si["netplay_save_load"] is True and si["netplay_save_write"] is False)
            check(f"{inst.name}: netplay save folder separate from solo",
                  "nand-solo" not in si["nand"])

        time.sleep(3)
        joiner.send("stop")  # a client-initiated stop ends the match for everyone
        host.wait_for("game_stopped", timeout=30)
        joiner.wait_for("game_stopped", timeout=30)
        check("both instances returned to the lobby", True)

        again = host.wait_for("players", lambda e: len(e["players"]) == 2 and not e["in_game"])
        check("session survives the match (still 2 players, not in game)", bool(again))

        joiner.send("quit")
        check("joiner exit 0", joiner.wait_for("exit")["code"] == 0)
        host.wait_for("player_left", lambda e: e["name"] == "Vegeta")
        check("host sees joiner leave", True)
        host.proc.stdin.close()  # frontend "crashes": EOF after hello should quit
        check("host exits on stdin EOF", host.wait_for("exit")["code"] == 0)
        for inst in (host, joiner):
            inst.proc.wait(timeout=20)
        discord_check(exe, dol)
        print("ALL PASSED")
    finally:
        for inst in [v for v in locals().values() if isinstance(v, Instance)]:
            if inst.proc.poll() is None:
                inst.proc.kill()
        shutil.rmtree(work, ignore_errors=True)


def discord_check(exe, dol):
    """A fake Discord IPC socket: Dolphin's built-in presence must NOT connect in Sparking mode.
    Plain dolphin-emu-nogui is the control (it should connect if Discord support is compiled in)."""
    import socket
    print("discord: built-in presence suppressed")
    work = tempfile.mkdtemp(prefix="sparking-discord-")
    sock_path = os.path.join(work, "discord-ipc-0")
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(4)
    srv.settimeout(0.5)
    env = dict(os.environ, XDG_RUNTIME_DIR=work, TMPDIR=work)
    user = os.path.join(work, "user", "Config")
    os.makedirs(user)
    with open(os.path.join(user, "Dolphin.ini"), "w") as f:
        f.write("[Analytics]\nPermissionAsked = True\n[General]\nUseDiscordPresence = True\n")

    def connections(extra):
        p = subprocess.Popen([exe, "-p", "headless", "-v", "Null", "-u", os.path.dirname(user),
                              *extra, "-e", dol], env=env, stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        n, deadline = 0, time.time() + 6
        while time.time() < deadline:
            try:
                c, _ = srv.accept()
                n += 1
                c.close()
            except socket.timeout:
                pass
        p.kill()
        p.wait()
        return n

    try:
        control = connections([])
        if control == 0:
            print("  SKIP  Discord support not compiled into this build")
            return
        check(f"control: plain nogui connects to Discord ({control}x)", True)
        check("sparking mode never connects to Discord", connections(["--sparking"]) == 0)
    finally:
        srv.close()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
