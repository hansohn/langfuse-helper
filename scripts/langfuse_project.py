#!/usr/bin/env python3
"""Idempotently ensure a Langfuse project and API key pair exist for tracing.

Driven by 'make trace/project'. Exists because 'make clean' regenerates SALT and
deletes .env, which invalidates every key in the database -- and LANGFUSE_INIT_*
only ever provisions ONE project, on first run. Without this, a reset silently
costs you the tracing project and its keys, to be rebuilt by hand in the UI.

Uses the same tRPC routes the UI calls. The REST equivalent
(POST /api/public/projects) needs the 'admin-api' entitlement, which belongs to
self-hosted:enterprise; an unlicensed deployment reports plan 'oss' and gets 403.

Inputs (environment):
  ENV_FILE       path to .env  (read for credentials, written for the key pair)
                 The plugin does NOT read this file -- it is the store this script
                 checks for idempotency, and the source of the values to paste
                 into the plugin's own machine-scope config.
  LANGFUSE_URL   base URL of the web service
  PROJECT_NAME   display name of the project to find or create

Reads LANGFUSE_INIT_USER_EMAIL / _PASSWORD and LANGFUSE_INIT_ORG_ID from ENV_FILE.
Writes LANGFUSE_TRACE_PUBLIC_KEY / _SECRET_KEY back into it.
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.cookiejar import CookieJar
from pathlib import Path


def require(name):
    """Read a required input, failing the same way as every other error here."""
    value = os.environ.get(name)
    if not value:
        sys.exit(f"[ERROR] {name} is required.")
    return value


def write_atomic(path, text, mode=0o600):
    """Write via a temp file in the same directory, then rename over the target.

    This file holds SALT and ENCRYPTION_KEY. An interrupted or out-of-space
    in-place write would truncate it, and losing SALT invalidates every API key
    in the database while losing ENCRYPTION_KEY makes stored LLM credentials
    permanently unreadable. os.replace is atomic on one filesystem, and the temp
    file is created 0600 so secrets are never briefly world-readable.
    """
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def read_env(path):
    """Minimal .env reader. Values may contain spaces and '='.

    A matched pair of surrounding quotes is stripped. Line endings are normalised
    to LF when the file is rewritten.
    """
    values = {}
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        # Unwrap a matched quote pair; docker compose accepts quoted values, and
        # leaving the quotes on turns a correct password into a login failure.
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value
    return values


# Written by the OTel-collector setup this replaced: a base64 basic-auth header
# derived from the key pair. Nothing reads it now, and a stale value derived from a
# rotated pair is worse than none, so it is dropped whenever this file is rewritten.
DERIVED_VARS = ("LANGFUSE_AUTH_B64",)


def write_env_keys(path, pairs):
    """Replace or append each key, preserving every other line and its order."""
    lines = path.read_text().splitlines() if path.exists() else []
    remaining = dict(pairs)
    seen = set()
    out = []
    for line in lines:
        key = line.split("=", 1)[0].strip() if "=" in line else None
        if key in DERIVED_VARS:
            continue
        if key in remaining:
            out.append(f"{key}={remaining.pop(key)}")
            seen.add(key)
        elif key is not None and key in seen:
            # A duplicate assignment of a key we already rewrote. Readers here
            # take last-wins while this writer rewrites the first occurrence, so
            # leaving it would make the file never converge and mint a new key
            # pair on every run.
            continue
        else:
            out.append(line)
    if remaining:
        if out and out[-1].strip():
            out.append("")
        out.append("# --- claude code tracing (written by 'make trace/project') ---")
        out.extend(f"{k}={v}" for k, v in remaining.items())
    write_atomic(path, "\n".join(out) + "\n")


class Client:
    """Authenticated session against Langfuse's NextAuth + tRPC endpoints."""

    def __init__(self, base):
        self.base = base.rstrip("/")
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(CookieJar())
        )

    def _json(self, request):
        try:
            with self.opener.open(request, timeout=30) as response:
                body = response.read().decode()
        except urllib.error.HTTPError:
            raise
        except OSError as exc:
            sys.exit(f"[ERROR] Cannot reach {self.base}: {exc}")
        return json.loads(body) if body else {}

    def get(self, path):
        return self._json(urllib.request.Request(f"{self.base}{path}"))

    def csrf(self):
        return self.get("/api/auth/csrf")["csrfToken"]

    def login(self, email, password):
        data = urllib.parse.urlencode(
            {
                "email": email,
                "password": password,
                "csrfToken": self.csrf(),
                "json": "true",
            }
        ).encode()
        self.opener.open(
            urllib.request.Request(
                f"{self.base}/api/auth/callback/credentials",
                data=data,
                method="POST",
            ),
            timeout=30,
        )
        session = self.get("/api/auth/session")
        if not session.get("user"):
            sys.exit("[ERROR] Login failed. Check LANGFUSE_INIT_USER_EMAIL/_PASSWORD.")
        return session

    def trpc(self, route, payload):
        request = urllib.request.Request(
            f"{self.base}/api/trpc/{route}",
            data=json.dumps({"json": payload}).encode(),
            method="POST",
            headers={
                "Content-Type": "application/json",
                "x-csrf-token": self.csrf(),
            },
        )
        try:
            payload = self._json(request)
        except urllib.error.HTTPError as exc:
            sys.exit(f"[ERROR] {route} failed ({exc.code}): {exc.read().decode()[:300]}")
        try:
            return payload["result"]["data"]["json"]
        except (KeyError, TypeError):
            # These are Langfuse's internal tRPC routes, with no stability
            # guarantee. Say so rather than raising an opaque KeyError.
            sys.exit(
                f"[ERROR] {route} returned an unexpected shape. The internal tRPC\n"
                f"[ERROR] API may have changed upstream; create the project and keys\n"
                f"[ERROR] in the UI and set LANGFUSE_TRACE_* by hand."
            )


def key_project(base, public_key, secret_key):
    """Name of the project a key pair belongs to, or None if it cannot authenticate.

    A pair only authenticates while SALT is unchanged, and this endpoint returns
    the key's own project, so one call answers both "do these still work" and
    "do they point at the project we were asked for".
    """
    if not public_key or not secret_key:
        return None
    token = base64.b64encode(f"{public_key}:{secret_key}".encode()).decode()
    request = urllib.request.Request(
        f"{base.rstrip('/')}/api/public/projects",
        headers={"Authorization": f"Basic {token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            return None
        # A 5xx from a still-starting web service is not "these keys are bad";
        # treating it as such would mint a spurious key pair on every retry.
        sys.exit(f"[ERROR] Unexpected {exc.code} checking keys against {base}.")
    except OSError as exc:
        sys.exit(f"[ERROR] Cannot reach {base}: {exc}")
    projects = payload.get("data") or []
    return projects[0].get("name") if projects else None


def main():
    env_file = Path(require("ENV_FILE"))
    base = require("LANGFUSE_URL")
    project_name = require("PROJECT_NAME")

    env = read_env(env_file)
    email = env.get("LANGFUSE_INIT_USER_EMAIL")
    password = env.get("LANGFUSE_INIT_USER_PASSWORD")
    org_id = env.get("LANGFUSE_INIT_ORG_ID")

    public_key = env.get("LANGFUSE_TRACE_PUBLIC_KEY")
    secret_key = env.get("LANGFUSE_TRACE_SECRET_KEY")

    current = key_project(base, public_key, secret_key)
    if current == project_name:
        print(f"[INFO] LANGFUSE_TRACE_* keys already authenticate for '{project_name}'.")
        return 0

    if not (email and password):
        sys.exit(
            "[ERROR] Need LANGFUSE_INIT_USER_EMAIL and _PASSWORD in the env file to\n"
            "[ERROR] create the project. Set them, or create the project and keys in\n"
            "[ERROR] the UI and put the pair in LANGFUSE_TRACE_PUBLIC_KEY/_SECRET_KEY."
        )

    if current:
        # Valid keys, wrong project: the caller changed TRACE_PROJECT_NAME.
        print(f"[INFO] Keys currently point at '{current}', not '{project_name}'.")
        print("[INFO] Issuing a pair for the requested project instead.")
    elif public_key or secret_key:
        print("[WARN] LANGFUSE_TRACE_* keys are set but do not authenticate.")
        print("[WARN] Expected after 'make clean', which regenerates SALT. Reissuing.")

    client = Client(base)
    session = client.login(email, password)

    orgs = session.get("user", {}).get("organizations") or []
    if not orgs:
        sys.exit("[ERROR] User belongs to no organization. Run 'make langfuse/bootstrap'.")
    if org_id:
        org = next((o for o in orgs if o.get("id") == org_id), None)
        if org is None:
            available = ", ".join(o.get("id", "?") for o in orgs)
            sys.exit(
                f"[ERROR] LANGFUSE_INIT_ORG_ID '{org_id}' not found for this user.\n"
                f"[ERROR] Available: {available}."
            )
    else:
        org = orgs[0]

    project = next(
        (p for p in org.get("projects", []) if p.get("name") == project_name), None
    )
    if project:
        project_id = project["id"]
        print(f"[INFO] Reusing project '{project_name}' ({project_id}).")
    else:
        created = client.trpc(
            "projects.create",
            {"name": project_name, "orgId": org["id"], "retention": 0},
        )
        project_id = created["id"]
        print(f"[INFO] Created project '{project_name}' ({project_id}) in '{org['id']}'.")

    key = client.trpc(
        "projectApiKeys.create",
        {"projectId": project_id, "note": "claude code tracing (langfuse plugin)"},
    )
    write_env_keys(
        env_file,
        {
            "LANGFUSE_TRACE_PUBLIC_KEY": key["publicKey"],
            "LANGFUSE_TRACE_SECRET_KEY": key["secretKey"],
        },
    )
    print(f"[INFO] Wrote a new key pair to {env_file} (public {key['publicKey']}).")
    # The plugin never reads this file: its credentials live in machine-scope
    # config. Print what to paste so the pair does not have to be dug out.
    print("[INFO] Configure the plugin with this pair (stored outside any repo --")
    print("[INFO] the secret goes to the OS keychain, not to a file):")
    print("[INFO]")
    print(f"[INFO]   claude plugin install langfuse-observability@langfuse-observability \\")
    print(f"[INFO]     --config LANGFUSE_PUBLIC_KEY={key['publicKey']} \\")
    print(f"[INFO]     --config LANGFUSE_SECRET_KEY={key['secretKey']} \\")
    print(f"[INFO]     --config LANGFUSE_BASE_URL={base}")
    print("[INFO]")
    print("[INFO] Any previous key pair still exists in Langfuse; revoke it in the UI")
    print("[INFO] under Settings -> API Keys if you no longer want it valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
