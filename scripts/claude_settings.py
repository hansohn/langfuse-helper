#!/usr/bin/env python3
"""Idempotently add or remove a repo tag in a repo's Claude Code settings file.

Used by scripts/trace_harness.py (the Claude Code adapter behind 'make trace/tag'
and 'make trace/untag') through apply(). Also runnable on its own, with inputs
from the environment so nothing is quoted onto a command line:

  SETTINGS_FILE  path to .claude/settings.json (created if absent)
  MODE           'enable' (default) or 'disable'
  ATTR_KEY       tag prefix to set/remove (default: repo)
  ATTR_VALUE     enable: value for the prefix, i.e. repo:<ATTR_VALUE>

The Langfuse plugin reads CC_LANGFUSE_TRACE_TAGS as a comma-separated list of
plain tag values and turns them into Langfuse trace tags. Skill tags
(skill:<name>) and cwd/git_branch metadata are automatic and need nothing here,
so this file contains only the repo tag -- and therefore no secret, which is why
it is safe to commit. The plugin's credentials live in its machine-scope config.

Merging is conservative:
  - every other top-level settings key is preserved
  - every other env var is preserved
  - the tag list is a comma-separated list of values, so only the tag with our
    prefix is replaced and sibling tags survive
  - a file that is not valid JSON is refused, never overwritten
"""
import json
import os
import sys
from pathlib import Path

# The only env var this tool manages. Anything else in the env block is left
# alone, including any other CC_LANGFUSE_* option the operator has set.
TAGS_VAR = "CC_LANGFUSE_TRACE_TAGS"

# Variables written by the OTel-collector setup this replaced. They are pruned on
# enable because they are actively harmful once the collector is gone: Claude Code
# would keep exporting to a port with nothing listening, failing silently. Nothing
# writes them any more, so this is a one-way migration and a no-op afterwards.
LEGACY_COLLECTOR_VARS = (
    "CLAUDE_CODE_ENABLE_TELEMETRY",
    "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA",
    "OTEL_TRACES_EXPORTER",
    "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL",
    "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
    "OTEL_LOG_TOOL_DETAILS",
    "OTEL_LOG_TOOL_CONTENT",
    "OTEL_RESOURCE_ATTRIBUTES",
)


def require(name):
    """Read a required input, failing the same way as every other error here."""
    value = os.environ.get(name)
    if not value:
        sys.exit(f"[ERROR] {name} is required.")
    return value


def parse_tags(raw):
    """'a,b:1,c' -> ['a', 'b:1', 'c'], order preserved, blanks and dupes dropped."""
    tags = []
    for part in raw.split(","):
        part = part.strip()
        if part and part not in tags:
            tags.append(part)
    return tags


def format_tags(tags):
    return ",".join(tags)


def write_atomic(path, text, mode=0o644):
    """Write via a temp file in the same directory, then rename over the target.

    An interrupted or out-of-space in-place write would leave a truncated file;
    os.replace is atomic on the same filesystem, so readers see old or new.
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


def load(path):
    """Returns (data, existed) or exits non-zero on unusable content."""
    if not path.exists():
        return {}, False
    text = path.read_text()
    if not text.strip():
        return {}, True
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        # Claude Code settings files are strict JSON too, so a trailing comma or
        # a // comment is already broken there. Refuse rather than overwrite
        # something we cannot round-trip.
        sys.exit(f"[ERROR] '{path}' is not valid JSON: {exc}")
    if not isinstance(data, dict):
        sys.exit(f"[ERROR] '{path}' must hold a JSON object.")
    return data, True


def set_tag(env, prefix, value):
    """Set the `<prefix>:<value>` tag, replacing any existing tag with that prefix."""
    tags = parse_tags(env.get(TAGS_VAR, ""))
    wanted = f"{prefix}:{value}"
    previous = next((t for t in tags if t.startswith(f"{prefix}:")), None)
    if previous is None:
        tags.append(wanted)
    else:
        tags[tags.index(previous)] = wanted
    env[TAGS_VAR] = format_tags(tags)
    return previous, [t for t in tags if t != wanted]


def drop_tag(env, prefix):
    """Remove our tag, keeping siblings. Drops the var only when nothing is left."""
    tags = [t for t in parse_tags(env.get(TAGS_VAR, "")) if not t.startswith(f"{prefix}:")]
    if tags:
        env[TAGS_VAR] = format_tags(tags)
    else:
        env.pop(TAGS_VAR, None)
    return tags


def apply(path, mode, tags):
    """Set (mode 'enable') or remove (mode 'disable') one tag per prefix in `tags`.

    enable:  tags is {prefix: value}, e.g. {"repo": "my-repo", "harness": "claude"}
    disable: tags is an iterable of prefixes, e.g. ["repo", "harness"]

    Returns (changed, messages). Exits non-zero on unusable input or content.
    """
    path = Path(path)
    if mode not in ("enable", "disable"):
        sys.exit(f"[ERROR] MODE must be 'enable' or 'disable', got '{mode}'.")

    if mode == "disable" and not path.exists():
        return False, [f"{path} does not exist, nothing to disable."]

    data, existed = load(path)

    env = data.get("env", {})
    if not isinstance(env, dict):
        sys.exit(f"[ERROR] 'env' in '{path}' must be a JSON object.")

    before = json.dumps(data, sort_keys=True)
    messages = []

    if mode == "disable":
        # Remove our tags but keep any siblings. Note this cannot tell a tag we
        # wrote from one the project set itself under the same prefix.
        for prefix in tags:
            siblings = drop_tag(env, prefix)
        messages.append(f"removed the {', '.join(p + ':' for p in tags)} tag(s)")
        if TAGS_VAR in env:
            messages.append(f"kept: {', '.join(siblings)}")
    else:
        for prefix, value in tags.items():
            # A tag is one item in a comma-separated list, so a ',' would silently
            # inject a second tag. Langfuse also drops any tag over 200 characters.
            if "," in value:
                sys.exit(f"[ERROR] Label may not contain ',': '{value}'")
            if len(f"{prefix}:{value}") > 200:
                sys.exit(f"[ERROR] Tag '{prefix}:{value}' exceeds 200 characters.")

        legacy = [k for k in LEGACY_COLLECTOR_VARS if k in env]
        for key in legacy:
            env.pop(key)

        for prefix, value in tags.items():
            previous, _ = set_tag(env, prefix, value)
            if previous is None:
                messages.append(f"added tag {prefix}:{value}")
            elif previous != f"{prefix}:{value}":
                messages.append(f"tag: '{previous}' -> '{prefix}:{value}'")
        if legacy:
            messages.append(f"pruned {len(legacy)} obsolete collector variable(s)")
        ours = {f"{p}:{v}" for p, v in tags.items()}
        siblings = [t for t in parse_tags(env.get(TAGS_VAR, "")) if t not in ours]
        if siblings:
            messages.append(f"preserved other tags: {', '.join(siblings)}")

    # An empty env block is noise; drop it rather than leaving "env": {}.
    if env:
        data["env"] = env
    else:
        data.pop("env", None)

    if json.dumps(data, sort_keys=True) == before:
        state = "enabled" if mode == "enable" else "disabled"
        return False, [f"{path}: already {state}, no change."]

    path.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(path, json.dumps(data, indent=2) + "\n")
    return True, [f"{'Created' if not existed else 'Updated'} {path}"] + [f"  {m}" for m in messages]


def main():
    mode = os.environ.get("MODE") or "enable"
    attr_key = os.environ.get("ATTR_KEY") or "repo"
    tags = {attr_key: require("ATTR_VALUE")} if mode == "enable" else [attr_key]
    _, messages = apply(require("SETTINGS_FILE"), mode, tags)
    for message in messages:
        print(f"[INFO] {message}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
