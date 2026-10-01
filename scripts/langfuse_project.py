#!/usr/bin/env python3
"""Idempotently ensure a Langfuse project and API key pair exist.

Driven by 'make trace/install', via its trace/project step (one pair per traced
harness), and by
litellm-helper's 'make langfuse/project' (the proxy's pair), which calls this
file rather than keeping a copy. Exists because 'make clean' regenerates SALT and
deletes .env, which invalidates every key in the database -- and LANGFUSE_INIT_*
only ever provisions ONE project, on first run. Without this, a reset silently
costs you each project's keys, to be rebuilt by hand in the UI.

Uses the same tRPC routes the UI calls. The REST equivalent
(POST /api/public/projects) needs the 'admin-api' entitlement, which belongs to
self-hosted:enterprise; an unlicensed deployment reports plan 'oss' and gets 403.

Inputs (environment):
  ENV_FILE              .env the key pair is written to, and read from to check
                        whether the pair already works
  CREDENTIALS_ENV_FILE  langfuse-helper's .env, read (never written) for
                        LANGFUSE_INIT_USER_EMAIL / _PASSWORD / _ORG_ID.
                        Defaults to ENV_FILE.
  LANGFUSE_URL          base URL of the web service
  PROJECT_NAME          display name of the project to find or create
  PROJECT_ID            optional. Found by ID first, so renaming a project's
                        display name never creates a second one.
  KEY_PREFIX            writes <KEY_PREFIX>_PUBLIC_KEY / _SECRET_KEY
                        (default: LANGFUSE_TRACE)
  KEY_NOTE              note shown on the key in Settings -> API Keys
  HEADING               comment written above the pair when it is first added
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

# Resolves because Python puts this script's own directory on sys.path, including
# when litellm-helper runs it by absolute path.
from env_file import read_env, write_env_keys


def require(name):
    """Read a required input, failing the same way as every other error here."""
    value = os.environ.get(name)
    if not value:
        sys.exit(f"[ERROR] {name} is required.")
    return value


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
        try:
            self.opener.open(
                urllib.request.Request(
                    f"{self.base}/api/auth/callback/credentials",
                    data=data,
                    method="POST",
                ),
                timeout=30,
            )
        except urllib.error.HTTPError as exc:
            # NextAuth answers a bad password with an error status on some
            # versions; the session check below gives the actionable message.
            if exc.code >= 500:
                sys.exit(f"[ERROR] Login failed ({exc.code}) at {self.base}.")
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
                f"[ERROR] in the UI and set the key pair by hand."
            )


def key_project(base, public_key, secret_key):
    """The project a key pair belongs to, as a dict with 'id' and 'name', or None
    if the pair cannot authenticate.

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
    return projects[0] if projects else None


def main():
    env_file = Path(require("ENV_FILE"))
    credentials_file = Path(os.environ.get("CREDENTIALS_ENV_FILE") or env_file)
    base = require("LANGFUSE_URL")
    project_name = require("PROJECT_NAME")
    project_id = os.environ.get("PROJECT_ID") or None
    prefix = os.environ.get("KEY_PREFIX") or "LANGFUSE_TRACE"
    note = os.environ.get("KEY_NOTE") or "langfuse-helper"
    heading = os.environ.get("HEADING") or f"# --- {prefix} (written by langfuse-helper) ---"
    public_var, secret_var = f"{prefix}_PUBLIC_KEY", f"{prefix}_SECRET_KEY"

    env = read_env(env_file)
    public_key = env.get(public_var)
    secret_key = env.get(secret_var)

    # Matching on ID or name: a project created from PROJECT_NAME (no headless
    # provisioning, so no known ID) gets a random ID, and comparing on ID alone
    # would then mint a new pair on every run.
    current = key_project(base, public_key, secret_key)
    if current and (current.get("id") == project_id or current.get("name") == project_name):
        print(f"[INFO] {prefix}_* keys already authenticate for '{current.get('name')}'.")
        return 0

    if not credentials_file.exists():
        sys.exit(
            f"[ERROR] Langfuse env file '{credentials_file}' not found. Create the project\n"
            f"[ERROR] and keys in the UI and set {public_var}/_SECRET_KEY in\n"
            f"[ERROR] {env_file} by hand."
        )
    credentials = read_env(credentials_file)
    email = credentials.get("LANGFUSE_INIT_USER_EMAIL")
    password = credentials.get("LANGFUSE_INIT_USER_PASSWORD")
    org_id = credentials.get("LANGFUSE_INIT_ORG_ID")

    if not (email and password):
        sys.exit(
            f"[ERROR] Need LANGFUSE_INIT_USER_EMAIL and _PASSWORD in '{credentials_file}'\n"
            f"[ERROR] to create the project. Headless provisioning writes them. If you\n"
            f"[ERROR] signed up through the UI instead, create the project and an API key\n"
            f"[ERROR] pair there and set {public_var}/_SECRET_KEY in {env_file}."
        )

    if current:
        print(f"[INFO] Keys currently point at '{current.get('name')}', not '{project_name}'.")
        print("[INFO] Issuing a pair for the requested project instead.")
    elif public_key or secret_key:
        print(f"[WARN] {prefix}_* keys are set but do not authenticate.")
        print("[WARN] Expected after 'make clean', which regenerates SALT. Reissuing.")

    client = Client(base)
    session = client.login(email, password)

    orgs = session.get("user", {}).get("organizations") or []
    if not orgs:
        sys.exit("[ERROR] User belongs to no organization. Run langfuse-helper's 'make langfuse/bootstrap'.")
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

    projects = org.get("projects", [])
    project = next((p for p in projects if project_id and p.get("id") == project_id), None) or next(
        (p for p in projects if p.get("name") == project_name), None
    )
    if project:
        found_id = project["id"]
        print(f"[INFO] Reusing project '{project.get('name')}' ({found_id}).")
    else:
        created = client.trpc(
            "projects.create",
            {"name": project_name, "orgId": org["id"], "retention": 0},
        )
        found_id = created["id"]
        print(f"[INFO] Created project '{project_name}' ({found_id}) in '{org['id']}'.")

    key = client.trpc("projectApiKeys.create", {"projectId": found_id, "note": note})
    write_env_keys(
        env_file,
        {public_var: key["publicKey"], secret_var: key["secretKey"]},
        heading,
    )
    print(f"[INFO] Wrote a new key pair to {env_file} (public {key['publicKey']}).")
    print("[INFO] Any previous key pair still exists in Langfuse; revoke it in the UI")
    print("[INFO] under Settings -> API Keys if you no longer want it valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
