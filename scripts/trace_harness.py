#!/usr/bin/env python3
"""Per-harness plugin setup behind the 'make trace/*' targets.

  python3 scripts/trace_harness.py <action> <harness>

Actions:
  wanted   exit 0 if tracing is wanted for this harness, 1 otherwise (silent)
  check    verify the host tools the harness's plugin needs
  install  install/configure the plugin with the harness's key pair (idempotent)
  tag      label a repo's traces with repo:<label> and harness:<name>
  untag    remove those labels (and, for Codex, the per-repo enable file)

Inputs come from the environment so the Makefile never has to quote anything
onto a command line:

  ENV_FILE              langfuse-helper's .env, read for the harness's key pair
                        LANGFUSE_TRACE_<HARNESS>_PUBLIC_KEY / _SECRET_KEY
  LANGFUSE_URL          base URL the plugin sends traces to
  TRACE                 'true' forces 'wanted' (first run, before any signal)
  OPTIONAL              'true' turns "nothing to do" errors into quiet exits
  USER_ID               Langfuse user to attach to traces, where configurable
  REPO_DIR, REPO_LABEL  tag/untag target and label
  CLAUDE_SETTINGS_FILE  optional override of <repo>/.claude/settings.json

Each harness is one class with the same methods, so adding one (OpenCode, Hermes)
means adding a class and a HARNESSES entry -- the Makefile does not change.
"""
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Resolve because Python puts this script's own directory on sys.path.
import claude_settings
from env_file import read_env, write_atomic


def env(name, default=""):
    return os.environ.get(name) or default


def require(name):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"[ERROR] {name} is required.")
    return value


def truthy(name):
    return env(name).lower() == "true"


def home():
    # Both plugins resolve their config from $HOME, not from CODEX_HOME or
    # similar, so this must too or it would write where nothing reads.
    return Path(env("HOME") or Path.home())


def load_json(path):
    """A JSON object from `path`, {} if absent or empty; exit on anything else.

    A file that is not valid JSON is refused rather than overwritten: it belongs
    to a tool we do not control, and we cannot round-trip what we cannot parse.
    """
    if not path.exists() or not path.read_text().strip():
        return {}
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        sys.exit(f"[ERROR] '{path}' is not valid JSON: {exc}")
    if not isinstance(data, dict):
        sys.exit(f"[ERROR] '{path}' must hold a JSON object.")
    return data


def version_tuple(text):
    match = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", text or "")
    return tuple(int(part or 0) for part in match.groups()) if match else None


def tool_version(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return version_tuple(result.stdout + result.stderr)


def run_quiet(command):
    """Run a CLI step, showing its output only if it fails."""
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        sys.exit(f"[ERROR] '{' '.join(command[:4])} ...' failed ({result.returncode}).")


class Claude:
    name = "claude"
    cli = "claude"
    plugin = "langfuse-observability@langfuse-observability"
    marketplace = "langfuse/Claude-Observability-Plugin"

    def check(self):
        # The plugin's hook declares its langfuse dependency as PEP 723 metadata
        # and is run with 'uv run --script'. Without uv it falls back to bare
        # python3, the import fails, and the hook exits 0 -- so tracing stops
        # with nothing to see.
        if not shutil.which("uv"):
            sys.exit(
                "[ERROR] uv is not installed. Claude Code tracing fails silently without it.\n"
                "[ERROR] Install it: https://docs.astral.sh/uv/getting-started/installation/"
            )
        print(f"[INFO] claude: uv {'.'.join(map(str, tool_version(['uv', '--version']) or ()))} present.")

    def installed(self):
        path = home() / ".claude" / "plugins" / "installed_plugins.json"
        return path.exists() and self.plugin in path.read_text()

    def current(self, public_key, url):
        settings = home() / ".claude" / "settings.json"
        try:
            options = json.loads(settings.read_text())["pluginConfigs"][self.plugin]["options"]
        except (OSError, ValueError, KeyError, TypeError):
            return False
        return options.get("LANGFUSE_PUBLIC_KEY") == public_key and options.get("LANGFUSE_BASE_URL", url) == url

    def install(self, public_key, secret_key, url):
        subprocess.run(["claude", "plugin", "marketplace", "add", self.marketplace], capture_output=True, check=False)
        # The secret is on this command line, so it is briefly visible in the
        # process list -- the same exposure as pasting the command by hand.
        run_quiet(
            [
                "claude", "plugin", "install", self.plugin,
                "--config", f"LANGFUSE_PUBLIC_KEY={public_key}",
                "--config", f"LANGFUSE_SECRET_KEY={secret_key}",
                "--config", f"LANGFUSE_BASE_URL={url}",
            ]
        )
        # Where Claude Code keeps credentials: the Keychain on macOS, a mode-600
        # file under ~/.claude elsewhere. Say which, rather than promising a keychain.
        store = "the macOS Keychain" if sys.platform == "darwin" else "~/.claude/.credentials.json (mode 600)"
        print(f"[INFO] claude: plugin configured. The secret is in {store}, not in a repo.")
        print("[INFO] claude: restart any running session -- hooks load at launch.")

    def manual(self, url):
        return [
            f"claude plugin marketplace add {self.marketplace}",
            (
                f"claude plugin install {self.plugin} --config LANGFUSE_PUBLIC_KEY=... "
                f"--config LANGFUSE_SECRET_KEY=... --config LANGFUSE_BASE_URL={url}"
            ),
        ]

    def _settings(self, repo):
        return Path(env("CLAUDE_SETTINGS_FILE") or repo / ".claude" / "settings.json")

    def tag(self, repo, label):
        return claude_settings.apply(self._settings(repo), "enable", {"repo": label, "harness": self.name})

    def untag(self, repo):
        return claude_settings.apply(self._settings(repo), "disable", ["repo", "harness"])


class Codex:
    name = "codex"
    cli = "codex"
    plugin = "tracing@codex-observability-plugin"
    marketplace = "langfuse/codex-observability-plugin"
    min_node = (22, 0, 0)
    min_codex = (0, 143, 0)

    # Marks <repo>/.codex/config.toml as ours, so untag only deletes a file it
    # wrote and never one the repo already had.
    marker = "# generated by langfuse-helper 'make trace/tag' -- enables Langfuse tracing"

    def check(self):
        node = tool_version(["node", "--version"]) if shutil.which("node") else None
        if not node or node < self.min_node:
            sys.exit("[ERROR] codex: the plugin's hook needs Node.js 22+ on PATH.")
        if not shutil.which("npm"):
            sys.exit("[ERROR] codex: the npm CLI must be on PATH; Codex uses it to fetch the plugin.")
        if shutil.which(self.cli):
            codex = tool_version([self.cli, "--version"])
            if codex and codex < self.min_codex:
                sys.exit(f"[ERROR] codex: {'.'.join(map(str, codex))} found, the plugin needs 0.143+.")
        print(f"[INFO] codex: node {'.'.join(map(str, node))} and npm present.")

    def _global(self):
        return home() / ".codex" / "langfuse.json"

    def installed(self):
        return bool(load_json(self._global()).get("public_key"))

    def current(self, public_key, url):
        config = load_json(self._global())
        user_id = env("USER_ID")
        return (
            config.get("enabled") is True
            and config.get("public_key") == public_key
            and config.get("base_url") == url
            and (not user_id or config.get("user_id") == user_id)
        )

    def install(self, public_key, secret_key, url):
        subprocess.run([self.cli, "plugin", "marketplace", "add", self.marketplace], capture_output=True, check=False)
        path = self._global()
        config = load_json(path)
        config.update(enabled=True, public_key=public_key, secret_key=secret_key, base_url=url)
        # The plugin defaults user_id to the Codex login email; pin it to the
        # Langfuse account's so every harness reports the same user.
        if env("USER_ID"):
            config["user_id"] = env("USER_ID")
        path.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(path, json.dumps(config, indent=2) + "\n", mode=0o600)
        path.chmod(0o600)
        print(f"[INFO] codex: credentials written to {path} (mode 600).")
        print("[INFO] codex: enable it per repo with 'make trace/tag <repo>', then trust the")
        print("[INFO] codex: Langfuse Stop hook in Codex's /hooks on first run.")

    def manual(self, url):
        return [
            f"codex plugin marketplace add {self.marketplace}",
            f"write {self._global()} with enabled, public_key, secret_key, base_url={url}",
        ]

    def _render_config(self):
        return "\n".join(
            [
                self.marker,
                "# Safe to commit: it only enables the plugin, which stays off without",
                "# credentials in ~/.codex/langfuse.json. Remove with 'make trace/untag'.",
                "",
                "[features]",
                "hooks = true",
                "",
                f'[plugins."{self.plugin}"]',
                "enabled = true",
                "",
            ]
        )

    def _config_state(self, path):
        """'missing', 'ours', 'enabled' (someone else's file, already on), or
        'foreign' (someone else's file that does not enable the plugin)."""
        if not path.exists():
            return "missing"
        text = path.read_text()
        if text.startswith(self.marker):
            return "ours"
        # Only needed for a config.toml someone else wrote, so the 3.11 floor
        # applies here rather than to tracing as a whole.
        try:
            import tomllib
        except ImportError:
            sys.exit(f"[ERROR] Reading the existing '{path}' needs Python 3.11+.")

        try:
            config = tomllib.loads(text)
        except tomllib.TOMLDecodeError as exc:
            sys.exit(f"[ERROR] '{path}' is not valid TOML: {exc}")
        hooks = config.get("features", {}).get("hooks") is True
        plugin = config.get("plugins", {}).get(self.plugin, {}).get("enabled") is True
        return "enabled" if hooks and plugin else "foreign"

    def tag(self, repo, label):
        config_path = repo / ".codex" / "config.toml"
        tags_path = repo / ".codex" / "langfuse.json"
        state = self._config_state(config_path)
        # Checked before writing anything, so a refusal leaves the repo untouched.
        if state == "foreign":
            sys.exit(
                f"[ERROR] '{config_path}' exists and does not enable the plugin. Add:\n"
                f"[ERROR]   [features] hooks = true\n"
                f'[ERROR]   [plugins."{self.plugin}"] enabled = true\n'
                f"[ERROR] It was left unchanged, since it is not a file this tool wrote."
            )

        messages = []
        if state == "missing" or (state == "ours" and config_path.read_text() != self._render_config()):
            config_path.parent.mkdir(parents=True, exist_ok=True)
            write_atomic(config_path, self._render_config(), mode=0o644)
            messages.append(f"{'Created' if state == 'missing' else 'Updated'} {config_path}")

        # Tags only, never credentials: the plugin merges this over the global
        # ~/.codex/langfuse.json, so the file holds no secret and can be committed.
        data = load_json(tags_path)
        existing = data.get("tags") or []
        if isinstance(existing, str):
            existing = [t.strip() for t in existing.split(",") if t.strip()]
        wanted = {"repo": label, "harness": self.name}
        for prefix, value in wanted.items():
            if "," in value or len(f"{prefix}:{value}") > 200:
                sys.exit(f"[ERROR] Invalid tag '{prefix}:{value}'.")
        kept = [t for t in existing if not t.startswith(tuple(f"{p}:" for p in wanted))]
        tags = kept + [f"{p}:{v}" for p, v in wanted.items()]
        if tags != existing:
            data["tags"] = tags
            tags_path.parent.mkdir(parents=True, exist_ok=True)
            write_atomic(tags_path, json.dumps(data, indent=2) + "\n", mode=0o644)
            messages.append(f"Wrote tags {', '.join(tags)} to {tags_path}")

        if not messages:
            return False, [f"{repo}: codex already enabled and tagged, no change."]
        return True, messages

    def untag(self, repo):
        config_path = repo / ".codex" / "config.toml"
        tags_path = repo / ".codex" / "langfuse.json"
        messages = []

        if tags_path.exists():
            data = load_json(tags_path)
            tags = data.get("tags") or []
            if isinstance(tags, str):
                tags = [t.strip() for t in tags.split(",") if t.strip()]
            kept = [t for t in tags if not t.startswith(("repo:", "harness:"))]
            if kept:
                data["tags"] = kept
            else:
                data.pop("tags", None)
            if data:
                write_atomic(tags_path, json.dumps(data, indent=2) + "\n", mode=0o644)
                messages.append(f"Removed repo:/harness: tags from {tags_path}")
            else:
                tags_path.unlink()
                messages.append(f"Removed {tags_path}")

        state = self._config_state(config_path)
        if state == "ours" and config_path.read_text() == self._render_config():
            config_path.unlink()
            messages.append(f"Removed {config_path}")
        elif state == "ours":
            messages.append(f"Left {config_path}: it was edited after this tool wrote it.")

        codex_dir = repo / ".codex"
        if codex_dir.is_dir() and not any(codex_dir.iterdir()):
            codex_dir.rmdir()

        if not messages:
            return False, [f"{repo}: codex not tagged here, nothing to remove."]
        return True, messages


HARNESSES = {h.name: h for h in (Claude(), Codex())}


def key_pair(harness):
    values = read_env(require("ENV_FILE"))
    prefix = f"LANGFUSE_TRACE_{harness.name.upper()}"
    return values.get(f"{prefix}_PUBLIC_KEY"), values.get(f"{prefix}_SECRET_KEY")


def main(argv):
    if len(argv) != 3 or argv[2] not in HARNESSES:
        sys.exit(f"usage: trace_harness.py <wanted|check|install|tag|untag> <{'|'.join(HARNESSES)}>")
    action, harness = argv[1], HARNESSES[argv[2]]

    if action == "wanted":
        # Three signals, because 'make clean' deletes the env file: TRACE=true
        # (a first run), a key pair in the env file, or the plugin already being
        # configured. The last is what makes a clean recoverable -- without it a
        # rebuild skips provisioning while the plugin keeps its now-dead key, and
        # the plugins swallow the resulting 401s, so tracing breaks silently.
        return 0 if truthy("TRACE") or any(key_pair(harness)) or harness.installed() else 1

    if action == "check":
        harness.check()
        return 0

    if action == "install":
        url = require("LANGFUSE_URL")
        public_key, secret_key = key_pair(harness)
        if not (public_key and secret_key):
            if truthy("OPTIONAL"):
                return 0
            sys.exit(f"[ERROR] {harness.name}: no key pair in '{env('ENV_FILE')}'. Run 'make trace/install' to create one.")
        if harness.current(public_key, url):
            if not truthy("OPTIONAL"):
                print(f"[INFO] {harness.name}: plugin already configured with the current key pair. No change.")
            return 0
        if not shutil.which(harness.cli):
            # Not an error under OPTIONAL: 'dev/up' must still work where the
            # CLI is absent, such as CI or a container.
            print(f"[WARN] {harness.name}: '{harness.cli}' is not on PATH, so the plugin was not configured.")
            print("[WARN] Configure it yourself with:")
            for line in harness.manual(url):
                print(f"[WARN]   {line}")
            return 0 if truthy("OPTIONAL") else 1
        harness.check()
        print(f"[INFO] {harness.name}: configuring the Langfuse plugin.")
        harness.install(public_key, secret_key, url)
        return 0

    if action in ("tag", "untag"):
        repo = Path(require("REPO_DIR")).expanduser().resolve()
        if not repo.is_dir():
            sys.exit(f"[ERROR] '{repo}' does not exist.")
        if action == "tag":
            _, messages = harness.tag(repo, require("REPO_LABEL"))
        else:
            _, messages = harness.untag(repo)
        for message in messages:
            print(f"[INFO] {harness.name}: {message}")
        return 0

    sys.exit(f"[ERROR] Unknown action '{action}'.")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
