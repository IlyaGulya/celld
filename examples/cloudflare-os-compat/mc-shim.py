#!/usr/bin/env python3
"""The slice of MinIO's `mc` that the Phase 0 fleet gates need.

The OSS `mc` binary is no longer published (`dl.min.io` answers 410 since the
project was archived), so this directory's fleet gates stay runnable without a
MinIO installation: `restore-test.sh` takes this script through `CELLD_MC` (and
`PHASE0_MC` in the AgentOS release gate). It implements exactly the subcommands
those gates call:

    mc-shim.py alias set <name> <endpoint> <access> <secret>
    mc-shim.py alias remove <name>
    mc-shim.py mb <alias>/<bucket>
    mc-shim.py rm --recursive --force <alias>/<bucket>/<prefix>
    mc-shim.py mirror --overwrite <alias>/<bucket>/<prefix> <alias>/<bucket>/<prefix>

`mirror` copies server-side, because a celld object store mixes SQLite
snapshots, LBAs and sealed segments: the endpoint is the only party that can
promise the copy is byte-identical, and the objects never travel through this
process. Aliases live in `$MC_SHIM_STATE` (default `~/.mc-shim/aliases.json`).

A missing alias, an empty mirror source or a refused copy is an error, so a
broken storage setup fails the gate instead of silently copying nothing.
"""
import datetime
import hashlib
import hmac
import json
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree

REGION = os.environ.get("MC_SHIM_REGION", "us-east-1")
ALIASES = pathlib.Path(
    os.environ.get("MC_SHIM_STATE", pathlib.Path.home() / ".mc-shim/aliases.json")
)
NS = "{http://s3.amazonaws.com/doc/2006-03-01/}"


def _sign(key, message):
    return hmac.new(key, message.encode(), hashlib.sha256).digest()


class Client:
    """One alias: its endpoint, credentials, and a SigV4 signer."""

    def __init__(self, endpoint, access, secret):
        self.endpoint = endpoint
        self.access = access
        self.secret = secret

    def request(self, method, path, query="", payload=b"", raw=False, headers=None):
        date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d")
        key = _sign(_sign(_sign(("AWS4" + self.secret).encode(), date), REGION), "s3")
        key = _sign(key, "aws4_request")
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        host = self.endpoint.split("//", 1)[1]
        url = self.endpoint + path + (("?" + query) if query else "")
        payload_hash = hashlib.sha256(payload).hexdigest()
        # S3 requires every x-amz-* header to be signed, so a caller passes one
        # here rather than setting it on the wire request.
        signed = {
            "host": host,
            "x-amz-content-sha256": payload_hash,
            "x-amz-date": stamp,
        }
        signed.update({n.lower(): v for n, v in (headers or {}).items()})
        names = sorted(signed)
        canonical_headers = "".join(f"{name}:{signed[name]}\n" for name in names)
        canonical_request = "\n".join(
            [
                method,
                path,
                query,
                canonical_headers,
                ";".join(names),
                payload_hash,
            ]
        )
        scope = f"{date}/{REGION}/s3/aws4_request"
        string_to_sign = "\n".join(
            [
                "AWS4-HMAC-SHA256",
                stamp,
                scope,
                hashlib.sha256(canonical_request.encode()).hexdigest(),
            ]
        )
        signature = hmac.new(key, string_to_sign.encode(), hashlib.sha256).hexdigest()
        request = urllib.request.Request(url, method=method, data=payload or None)
        request.add_header(
            "Authorization",
            f"AWS4-HMAC-SHA256 Credential={self.access}/{scope}, "
            f"SignedHeaders={';'.join(names)}, Signature={signature}",
        )
        request.add_header("x-amz-date", stamp)
        request.add_header("x-amz-content-sha256", payload_hash)
        for name, value in (headers or {}).items():
            request.add_header(name, value)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
                return response.status, body if raw else body.decode("utf-8", "replace")
        except urllib.error.HTTPError as error:
            body = error.read()
            return error.code, body if raw else body.decode("utf-8", "replace")


def load_aliases():
    if not ALIASES.exists():
        return {}
    return json.loads(ALIASES.read_text())


def save_aliases(aliases):
    ALIASES.parent.mkdir(parents=True, exist_ok=True)
    ALIASES.write_text(json.dumps(aliases, indent=2) + "\n")


def client_for(target):
    alias, _, rest = target.partition("/")
    aliases = load_aliases()
    if alias not in aliases:
        raise SystemExit(f"mc-shim: alias {alias!r} is not configured")
    bucket, _, prefix = rest.partition("/")
    if not bucket:
        raise SystemExit(f"mc-shim: {target!r} names no bucket")
    endpoint, access, secret = aliases[alias]
    return Client(endpoint, access, secret), bucket, prefix


def list_objects(client, bucket, prefix):
    keys = []
    token = ""
    while True:
        query = "list-type=2&prefix=" + urllib.parse.quote(prefix)
        if token:
            query += "&continuation-token=" + urllib.parse.quote(token)
        status, body = client.request("GET", f"/{bucket}/", query)
        if status != 200:
            raise SystemExit(
                f"mc-shim: list {bucket}/{prefix} failed: {status} {body[:200]}"
            )
        root = ElementTree.fromstring(body)
        for item in root.findall(f"{NS}Contents"):
            key = item.find(f"{NS}Key")
            if key is not None and key.text:
                keys.append(key.text)
        if root.findtext(f"{NS}IsTruncated") != "true":
            return keys
        token = root.findtext(f"{NS}NextContinuationToken") or ""


def delete_object(client, bucket, key):
    status, body = client.request("DELETE", f"/{bucket}/{urllib.parse.quote(key)}")
    if status not in (200, 204):
        raise SystemExit(f"mc-shim: delete {bucket}/{key} failed: {status} {body[:200]}")


def copy_object(client, source_bucket, key, destination_bucket, destination_key):
    status, body = client.request(
        "PUT",
        f"/{destination_bucket}/{urllib.parse.quote(destination_key)}",
        headers={"x-amz-copy-source": f"/{source_bucket}/{urllib.parse.quote(key)}"},
    )
    if status != 200 or "Code>" in body:
        raise SystemExit(
            f"mc-shim: copy {source_bucket}/{key} failed: {status} {body[:200]}"
        )


def main(argv):
    if len(argv) < 2:
        raise SystemExit("usage: mc-shim <subcommand> [args]")
    command = argv[1]
    if command == "alias":
        action = argv[2]
        if action == "set":
            name, endpoint, access, secret = argv[3:7]
            aliases = load_aliases()
            aliases[name] = [endpoint, access, secret]
            save_aliases(aliases)
            return 0
        if action == "remove":
            aliases = load_aliases()
            aliases.pop(argv[3], None)
            save_aliases(aliases)
            return 0
        raise SystemExit(f"mc-shim: unsupported alias action {action!r}")
    if command == "mb":
        client, bucket, _ = client_for(argv[-1])
        status, body = client.request("PUT", f"/{bucket}/")
        if status not in (200, 204):
            raise SystemExit(f"mc-shim: mb {bucket} failed: {status} {body[:200]}")
        return 0
    if command == "rm":
        client, bucket, prefix = client_for(argv[-1])
        for key in list_objects(client, bucket, prefix):
            delete_object(client, bucket, key)
        return 0
    if command == "mirror":
        source, destination = argv[-2], argv[-1]
        source_client, source_bucket, source_prefix = client_for(source)
        destination_client, destination_bucket, destination_prefix = client_for(
            destination
        )
        keys = list_objects(source_client, source_bucket, source_prefix)
        if not keys:
            raise SystemExit(f"mc-shim: mirror source {source} is empty")
        for key in keys:
            relative = (
                key[len(source_prefix):] if key.startswith(source_prefix) else key
            )
            copy_object(
                source_client,
                source_bucket,
                key,
                destination_bucket,
                destination_prefix + relative,
            )
        return 0
    raise SystemExit(f"mc-shim: unsupported subcommand {command!r}")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
