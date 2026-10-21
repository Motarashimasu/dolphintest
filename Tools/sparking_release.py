#!/usr/bin/env python3
"""Publish a Dolphin-Sparking build as an automatic update (Cloudflare R2), or make the signing key.

    python Tools/sparking_release.py keygen  <folder>
    python Tools/sparking_release.py publish <build folder> --config release.json --version 206
    python Tools/sparking_release.py prune   --config release.json        (old builds' files)

Pure Python 3.9+, no packages. See Docs/UPDATES.md for the whole setup.

keygen: makes the release signing key in <folder>: release_private.pem (keep it on your PC,
never share it, never commit it: whoever has it can push files to every player) and
release_public.pem (goes in the launcher: Frontend/Godot/data/update_key.pem).

publish: hashes every file of the build that the update manages (release.json "include" /
"exclude", paths relative to the build folder), uploads the ones the bucket doesn't have yet as
files/<sha256>, then the signed list of them as manifest.json (last, so players never see a list
whose files aren't there yet). Players' launchers download what differs from their copy.

release.json (keep it on your PC: it holds the R2 key that can write to the bucket):
    {
      "r2_account_id": "...", "r2_access_key": "...", "r2_secret_key": "...",
      "r2_bucket": "dbzsc-updates", "update_prefix": "",
      "private_key": "C:/Keys/release_private.pem",
      "launcher": "DRAGON BALL Sparking! Collection.exe",
      "include": ["*.exe", "*.pck", "*.ico", "Dolphin/**", "SparkingData/states/*",
                  "SparkingData/textures/**"],
      "exclude": []
    }
("r2_endpoint" may replace the account's R2 address, e.g. for a local test server.)
"""
from __future__ import annotations

import argparse
import base64
import datetime
import fnmatch
import hashlib
import hmac
import json
import math
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

FORMAT = 1


# --- RSA (PKCS#1 v1.5 signatures with SHA-256), keys as standard PEM ---------------------------

def _is_probable_prime(n: int, rounds: int = 64) -> bool:
    if n < 2:
        return False
    for p in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37):
        if n % p == 0:
            return n == p
    d, r = n - 1, 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for _ in range(rounds):
        a = secrets.randbelow(n - 3) + 2
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True


def _prime(bits: int, e: int) -> int:
    while True:
        p = secrets.randbits(bits) | (1 << (bits - 1)) | (1 << (bits - 2)) | 1
        if math.gcd(p - 1, e) == 1 and _is_probable_prime(p):
            return p


def _der_len(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def _der(tag: int, body: bytes) -> bytes:
    return bytes([tag]) + _der_len(len(body)) + body


def _der_int(v: int) -> bytes:
    b = v.to_bytes(max(1, (v.bit_length() + 8) // 8), "big")   # room for the sign bit
    return _der(0x02, b)


def _der_read(data: bytes, pos: int) -> tuple[int, bytes, int]:
    """(tag, body, next position)"""
    tag = data[pos]
    n = data[pos + 1]
    pos += 2
    if n & 0x80:
        k = n & 0x7F
        n = int.from_bytes(data[pos:pos + k], "big")
        pos += k
    return tag, data[pos:pos + n], pos + n


def _pem(label: str, der: bytes) -> str:
    b = base64.b64encode(der).decode()
    return f"-----BEGIN {label}-----\n" + "\n".join(b[i:i + 64] for i in range(0, len(b), 64)) \
        + f"\n-----END {label}-----\n"


def _unpem(text: str) -> bytes:
    lines = [l for l in text.strip().splitlines() if not l.startswith("-----")]
    return base64.b64decode("".join(lines))


RSA_OID = bytes.fromhex("06092a864886f70d0101010500")   # rsaEncryption, NULL
SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")


def keygen(bits: int = 3072) -> tuple[str, str]:
    e = 65537
    while True:
        p = _prime(bits // 2, e)
        q = _prime(bits // 2, e)
        n = p * q
        if p != q and n.bit_length() == bits:
            break
    d = pow(e, -1, (p - 1) * (q - 1))
    private = _der(0x30, b"".join(_der_int(v) for v in
                                  (0, n, e, d, p, q, d % (p - 1), d % (q - 1), pow(q, -1, p))))
    rsa_public = _der(0x30, _der_int(n) + _der_int(e))
    spki = _der(0x30, _der(0x30, RSA_OID) + _der(0x03, b"\x00" + rsa_public))
    return _pem("RSA PRIVATE KEY", private), _pem("PUBLIC KEY", spki)


def load_private(text: str) -> tuple[int, int]:
    """(n, d) from an "RSA PRIVATE KEY" (PKCS#1) PEM."""
    _, seq, _ = _der_read(_unpem(text), 0)
    vals, pos = [], 0
    while pos < len(seq):
        _, body, pos = _der_read(seq, pos)
        vals.append(int.from_bytes(body, "big"))
    return vals[1], vals[3]


def load_public(text: str) -> tuple[int, int]:
    """(n, e) from a "PUBLIC KEY" (SubjectPublicKeyInfo) PEM."""
    _, spki, _ = _der_read(_unpem(text), 0)
    _, _, pos = _der_read(spki, 0)               # algorithm
    _, bits, _ = _der_read(spki, pos)            # BIT STRING
    _, rsa, _ = _der_read(bits[1:], 0)
    _, n, pos = _der_read(rsa, 0)
    _, e, _ = _der_read(rsa, pos)
    return int.from_bytes(n, "big"), int.from_bytes(e, "big")


def _emsa(digest: bytes, k: int) -> int:
    t = SHA256_DIGEST_INFO + digest
    return int.from_bytes(b"\x00\x01" + b"\xff" * (k - len(t) - 3) + b"\x00" + t, "big")


def sign(data: bytes, n: int, d: int) -> bytes:
    k = (n.bit_length() + 7) // 8
    return pow(_emsa(hashlib.sha256(data).digest(), k), d, n).to_bytes(k, "big")


def verify(data: bytes, sig: bytes, n: int, e: int) -> bool:
    k = (n.bit_length() + 7) // 8
    return len(sig) == k and pow(int.from_bytes(sig, "big"), e, n) == _emsa(hashlib.sha256(data).digest(), k)


# --- R2 (S3 API, AWS Signature Version 4 in the Authorization header) --------------------------

class R2:
    def __init__(self, cfg: dict):
        self.endpoint = (cfg.get("r2_endpoint") or
                         f"https://{cfg['r2_account_id']}.r2.cloudflarestorage.com").rstrip("/")
        self.bucket = cfg["r2_bucket"]
        self.key = cfg["r2_access_key"]
        self.secret = cfg["r2_secret_key"]
        prefix = str(cfg.get("update_prefix", "")).strip("/")
        self.prefix = prefix + "/" if prefix else ""

    @staticmethod
    def authorization(method: str, host: str, path: str, query: dict, headers: dict,
                      payload_hash: str, key: str, secret: str, region: str, at: datetime.datetime) -> dict:
        """The headers to send (incl. Authorization) for one request. Also checked against AWS's
        documented examples (--self-test)."""
        stamp = at.strftime("%Y%m%dT%H%M%SZ")
        date = stamp[:8]
        hdrs = {k.lower(): str(v).strip() for k, v in headers.items()}
        hdrs["host"] = host
        hdrs["x-amz-date"] = stamp
        hdrs["x-amz-content-sha256"] = payload_hash
        signed = ";".join(sorted(hdrs))
        canonical_headers = "".join(f"{k}:{hdrs[k]}\n" for k in sorted(hdrs))
        qs = "&".join(f"{urllib.parse.quote(k, safe='-_.~')}={urllib.parse.quote(str(v), safe='-_.~')}"
                      for k, v in sorted(query.items()))
        canonical = "\n".join([method, urllib.parse.quote(path, safe="/-_.~"), qs, canonical_headers,
                               signed, payload_hash])
        scope = f"{date}/{region}/s3/aws4_request"
        to_sign = "\n".join(["AWS4-HMAC-SHA256", stamp, scope, hashlib.sha256(canonical.encode()).hexdigest()])
        k = hmac.new(("AWS4" + secret).encode(), date.encode(), hashlib.sha256).digest()
        for part in (region, "s3", "aws4_request"):
            k = hmac.new(k, part.encode(), hashlib.sha256).digest()
        sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
        hdrs["authorization"] = (f"AWS4-HMAC-SHA256 Credential={key}/{scope}, "
                                 f"SignedHeaders={signed}, Signature={sig}")
        return hdrs

    def request(self, method: str, obj: str = "", query: dict | None = None, body=None,
                length: int | None = None, headers: dict | None = None) -> tuple[int, bytes]:
        query = query or {}
        u = urllib.parse.urlsplit(self.endpoint)
        path = (u.path.rstrip("/") + "/" + self.bucket + ("/" + obj if obj else "")) if obj else \
            (u.path.rstrip("/") + "/" + self.bucket)
        hdrs = dict(headers or {})
        if length is not None:
            hdrs["Content-Length"] = str(length)
        signed = self.authorization(method, u.netloc, path, query, hdrs, "UNSIGNED-PAYLOAD",
                                    self.key, self.secret, "auto", datetime.datetime.now(datetime.timezone.utc))
        url = f"{u.scheme}://{u.netloc}{urllib.parse.quote(path, safe='/-_.~')}"
        if query:
            url += "?" + urllib.parse.urlencode(sorted(query.items()), quote_via=urllib.parse.quote)
        req = urllib.request.Request(url, data=body, method=method,
                                     headers={k: v for k, v in signed.items() if k != "host"})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=600) as r:
                    return r.status, r.read()
            except urllib.error.HTTPError as e:
                if e.code < 500 or attempt == 3:
                    return e.code, e.read()
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                if attempt == 3:
                    raise
            time.sleep(2 * (attempt + 1))
            if hasattr(body, "seek"):
                body.seek(0)
        raise RuntimeError("unreachable")

    def list_keys(self, sub: str) -> set[str]:
        keys, token = set(), None
        while True:
            q = {"list-type": "2", "prefix": self.prefix + sub}
            if token:
                q["continuation-token"] = token
            status, body = self.request("GET", query=q)
            if status != 200:
                raise SystemExit(f"Listing the bucket failed ({status}): {body[:300]!r}")
            root = ET.fromstring(body)
            ns = root.tag.split("}")[0] + "}" if root.tag.startswith("{") else ""
            for c in root.iter(ns + "Contents"):
                keys.add(c.find(ns + "Key").text)
            if (root.findtext(ns + "IsTruncated") or "false") != "true":
                return keys
            token = root.findtext(ns + "NextContinuationToken")

    def put_file(self, obj: str, path: str) -> None:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            status, body = self.request("PUT", self.prefix + obj, body=f, length=size)
        if status != 200:
            raise SystemExit(f"Uploading {obj} failed ({status}): {body[:300]!r}")

    def put_bytes(self, obj: str, data: bytes, content_type: str) -> None:
        status, body = self.request("PUT", self.prefix + obj, body=data, length=len(data),
                                    headers={"Content-Type": content_type})
        if status != 200:
            raise SystemExit(f"Uploading {obj} failed ({status}): {body[:300]!r}")

    def get(self, obj: str) -> tuple[int, bytes]:
        return self.request("GET", self.prefix + obj)

    def delete(self, obj: str) -> None:
        status, body = self.request("DELETE", obj)
        if status not in (200, 204):
            raise SystemExit(f"Deleting {obj} failed ({status}): {body[:300]!r}")


# --- The build's files -----------------------------------------------------------------------

def matches(rel: str, patterns: list[str]) -> bool:
    """fnmatch, where "dir/**" means everything under dir and "*" never crosses a folder."""
    for p in patterns:
        if p.endswith("/**"):
            if rel.startswith(p[:-2]):
                return True
        elif "/" not in p.replace("**", "") and "/" in rel:
            continue
        elif fnmatch.fnmatchcase(rel, p):
            return True
    return False


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def collect(build: str, include: list[str], exclude: list[str]) -> list[dict]:
    files = []
    for root, dirs, names in os.walk(build):
        dirs.sort()
        for name in sorted(names):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, build).replace(os.sep, "/")
            if matches(rel, include) and not matches(rel, exclude):
                files.append({"path": rel, "size": os.path.getsize(full), "sha256": sha256_file(full)})
    return files


def load_config(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    for k in ("r2_access_key", "r2_secret_key", "r2_bucket", "private_key"):
        if not cfg.get(k):
            raise SystemExit(f"{path}: \"{k}\" is missing")
    if not cfg.get("r2_endpoint") and not cfg.get("r2_account_id"):
        raise SystemExit(f"{path}: \"r2_account_id\" is missing")
    return cfg


def cmd_keygen(args) -> None:
    os.makedirs(args.folder, exist_ok=True)
    priv_path = os.path.join(args.folder, "release_private.pem")
    if os.path.exists(priv_path) and not args.force:
        raise SystemExit(f"{priv_path} already exists (a new key needs a new launcher: --force to replace it)")
    print("Making a 3072-bit RSA key (takes a few seconds)...")
    priv, pub = keygen()
    with open(priv_path, "w") as f:
        f.write(priv)
    with open(os.path.join(args.folder, "release_public.pem"), "w") as f:
        f.write(pub)
    n, d = load_private(priv)
    assert verify(b"test", sign(b"test", n, d), *load_public(pub))
    print(f"Wrote {priv_path} (keep it secret, back it up)\n"
          f"  and {os.path.join(args.folder, 'release_public.pem')} "
          f"(copy it to Frontend/Godot/data/update_key.pem)")


def cmd_publish(args) -> None:
    cfg = load_config(args.config)
    build = os.path.abspath(args.build)
    include = cfg.get("include") or ["*.exe", "*.pck", "*.ico", "Dolphin/**", "SparkingData/states/*",
                                     "SparkingData/textures/**"]
    exclude = cfg.get("exclude") or []
    launcher = cfg.get("launcher", "")
    with open(cfg["private_key"]) as f:
        n, d = load_private(f.read())
    print(f"Hashing {build} ...")
    files = collect(build, include, exclude)
    if not files:
        raise SystemExit("No files matched \"include\".")
    if launcher and not any(f["path"] == launcher for f in files):
        raise SystemExit(f"The launcher \"{launcher}\" isn't in the build (release.json \"launcher\").")
    total = sum(f["size"] for f in files)
    manifest = {"format": FORMAT, "version": args.version, "build": int(time.time()),
                "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "launcher": launcher, "notes": args.notes or "", "files": files}
    data = json.dumps(manifest, indent=1, ensure_ascii=False).encode()
    envelope = json.dumps({"manifest": base64.b64encode(data).decode(),
                           "signature": base64.b64encode(sign(data, n, d)).decode()}).encode()
    print(f"{len(files)} files, {total / 1048576:.1f} MB")
    if args.dry_run:
        for f in files:
            print(f"  {f['path']}  {f['size']}")
        return
    r2 = R2(cfg)
    have = {k.rsplit("/", 1)[-1] for k in r2.list_keys("files/")}
    todo = {}
    for f in files:
        if f["sha256"] not in have:
            todo.setdefault(f["sha256"], f)
    up = sum(f["size"] for f in todo.values())
    print(f"Uploading {len(todo)} new files ({up / 1048576:.1f} MB); {len(files) - len(todo)} already there")
    for i, f in enumerate(todo.values(), 1):
        print(f"  [{i}/{len(todo)}] {f['path']} ({f['size'] / 1048576:.1f} MB)")
        r2.put_file("files/" + f["sha256"], os.path.join(build, f["path"]))
    r2.put_bytes("manifest.json", envelope, "application/json")
    # Keep a copy of each published list (prune keeps their files).
    r2.put_bytes(f"manifests/{manifest['build']}.json", envelope, "application/json")
    print(f"Published version {args.version} (build {manifest['build']}). Launchers update on their next start.")


def cmd_prune(args) -> None:
    """Delete files/ objects no kept manifest needs (the newest --keep builds)."""
    cfg = load_config(args.config)
    r2 = R2(cfg)
    lists = sorted(r2.list_keys("manifests/"), key=lambda k: int(k.rsplit("/", 1)[-1].split(".")[0]))
    keep = lists[-args.keep:] if args.keep > 0 else []
    needed = set()
    for k in keep + [r2.prefix + "manifest.json"]:
        status, body = r2.request("GET", k)
        if status == 200:
            m = json.loads(base64.b64decode(json.loads(body)["manifest"]))
            needed |= {f["sha256"] for f in m["files"]}
    stale = [k for k in r2.list_keys("files/") if k.rsplit("/", 1)[-1] not in needed]
    print(f"{len(stale)} files no kept build needs" + ("" if args.yes else " (--yes to delete them)"))
    if args.yes:
        for k in stale:
            r2.delete(k)
        for k in lists[:-args.keep] if args.keep > 0 else lists:
            r2.delete(k)


def self_test() -> None:
    """AWS's documented Signature Version 4 examples (S3 docs, "Examples: Signature Calculations")
    and an RSA round trip."""
    at = datetime.datetime(2013, 5, 24, tzinfo=datetime.timezone.utc)
    key, secret = "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    empty = hashlib.sha256(b"").hexdigest()
    got = R2.authorization("GET", "examplebucket.s3.amazonaws.com", "/test.txt", {},
                           {"Range": "bytes=0-9"}, empty, key, secret, "us-east-1", at)
    assert got["authorization"].endswith("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"), got
    body = b"Welcome to Amazon S3."
    got = R2.authorization("PUT", "examplebucket.s3.amazonaws.com", "/test$file.text", {},
                           {"Date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class": "REDUCED_REDUNDANCY"},
                           hashlib.sha256(body).hexdigest(), key, secret, "us-east-1", at)
    assert got["authorization"].endswith("98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"), got
    got = R2.authorization("GET", "examplebucket.s3.amazonaws.com", "/", {"max-keys": "2", "prefix": "J"},
                           {}, empty, key, secret, "us-east-1", at)
    assert got["authorization"].endswith("34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"), got
    priv, pub = keygen(1024)
    n, d = load_private(priv)
    s = sign(b"hello", n, d)
    assert verify(b"hello", s, *load_public(pub)) and not verify(b"hellp", s, *load_public(pub))
    print("self-test ok")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    k = sub.add_parser("keygen", help="make the release signing key")
    k.add_argument("folder")
    k.add_argument("--force", action="store_true")
    p = sub.add_parser("publish", help="upload a build and make it the current update")
    p.add_argument("build")
    p.add_argument("--config", required=True)
    p.add_argument("--version", required=True, help="shown to players, e.g. 206")
    p.add_argument("--notes", help="one line shown while updating")
    p.add_argument("--dry-run", action="store_true", help="list the files, upload nothing")
    r = sub.add_parser("prune", help="delete files only old builds used")
    r.add_argument("--config", required=True)
    r.add_argument("--keep", type=int, default=3, help="also keep the newest N builds' files")
    r.add_argument("--yes", action="store_true")
    sub.add_parser("self-test", help="check the signing code against AWS's examples")
    args = ap.parse_args()
    {"keygen": cmd_keygen, "publish": cmd_publish, "prune": cmd_prune,
     "self-test": lambda a: self_test()}[args.cmd](args)


if __name__ == "__main__":
    main()
