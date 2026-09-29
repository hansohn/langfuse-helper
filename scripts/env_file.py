"""Read and update a generated .env file.

Shared by scripts/langfuse_project.py and scripts/trace_harness.py, and -- via
langfuse_project.py -- by litellm-helper, so there is one implementation of the
two operations that must not go wrong on a file holding SALT and ENCRYPTION_KEY:
a truncated write loses SALT (every API key in the database stops working) or
ENCRYPTION_KEY (stored LLM credentials become unreadable), and a non-converging
write mints a new key pair on every run.
"""
import os
from pathlib import Path


def write_atomic(path, text, mode=0o600):
    """Write via a temp file in the same directory, then rename over the target.

    os.replace is atomic on one filesystem, so a reader sees the old file or the
    new one, never a half-written one. The temp file is created with `mode`
    (0600 by default) so secrets are never briefly world-readable.
    """
    path = Path(path)
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

    A matched pair of surrounding quotes is stripped: compose accepts quoted
    values, and leaving the quotes on turns a correct password into a login
    failure.
    """
    values = {}
    path = Path(path)
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def write_env_keys(path, pairs, heading):
    """Replace or append each key, preserving every other line and its order.

    Rewrites the FIRST occurrence of a key and drops later duplicates. Readers
    take last-wins, so leaving a stale duplicate behind would mean the file never
    converges and a new key pair is minted on every run.
    """
    path = Path(path)
    lines = path.read_text().splitlines() if path.exists() else []
    remaining = dict(pairs)
    seen = set()
    out = []
    for line in lines:
        key = line.split("=", 1)[0].strip() if "=" in line else None
        if key in remaining:
            out.append(f"{key}={remaining.pop(key)}")
            seen.add(key)
        elif key is not None and key in seen:
            continue
        else:
            out.append(line)
    if remaining:
        if out and out[-1].strip():
            out.append("")
        out.append(heading)
        out.extend(f"{k}={v}" for k, v in remaining.items())
    write_atomic(path, "\n".join(out) + "\n")
