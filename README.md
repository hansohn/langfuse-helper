<div align="center">
  <h1>langfuse-helper</h1>
  <p>Run self-hosted Langfuse locally and trace coding agents into it</p>
  <p>
    <!-- Build Status -->
    <a href="https://github.com/hansohn/langfuse-helper/actions/workflows/ci.yml"><img alt="CI status" src="https://img.shields.io/github/actions/workflow/status/hansohn/langfuse-helper/ci.yml?style=for-the-badge"></a>
    <!-- Github Tag -->
    <a href="https://github.com/hansohn/langfuse-helper/tags/"><img alt="Latest tag" src="https://img.shields.io/github/v/tag/hansohn/langfuse-helper?style=for-the-badge&sort=semver"></a>
    <!-- License -->
    <a href="https://github.com/hansohn/langfuse-helper/blob/main/LICENSE.md"><img alt="License" src="https://img.shields.io/github/license/hansohn/langfuse-helper.svg?style=for-the-badge"></a>
  </p>
</div>

## Description

Makefile wrapper for running [Langfuse](https://langfuse.com) locally via Docker
Compose, following the [self-hosting compose guide](https://langfuse.com/self-hosting/deployment/docker-compose).
It clones upstream, generates an env file with random secrets, starts the stack,
waits until it is serving, and provisions your org, project, user and API keys.

It can also trace **coding agents** (Claude Code and Codex) into Langfuse: one
trace per turn with the prompt, reply, tool calls, cost, and a tag per skill
invoked. See [Tracing coding agents](#tracing-coding-agents).

## Requirements

- **Langfuse:** `git`, `openssl`, `curl`, and Docker with the Compose plugin.
- **Tracing:** `python3` 3.10+, plus [`uv`](https://docs.astral.sh/uv/) for
  Claude Code (**without it tracing fails silently**) and Node.js 22+ with `npm`
  for Codex.

`make check` verifies all of these (the tracing tools once tracing is set up, or
with `TRACE=true`).

```bash
brew install uv        # or: curl -LsSf https://astral.sh/uv/install.sh | sh
```

## Platform support

- **macOS and Linux.** CI runs the full stack on Ubuntu. On Linux, add yourself
  to the `docker` group (`sudo usermod -aG docker $USER`, then log in again).
- **Windows via WSL2 only.** Use Docker Desktop with WSL integration and clone
  inside the WSL filesystem (`~/...`), not under `/mnt/c`, where it is slow and
  `chmod 600` on `.env` does not stick.

## Quick start

```bash
git clone <this repo> && cd langfuse-helper
make dev/up                # or TRACE=true make dev/up to also set up tracing
```

This starts six containers, waits for `/api/public/health` (~2-3 min cold), and
prints a password. Sign in at <http://localhost:3000> with your git email and that
password.

Langfuse provisions **only on first start**. To sign up through the UI instead,
use `make dev/up HEADLESS=false` now; switching later means `make clean`, which
destroys your volumes.

For tracing, also:

```bash
make trace/tag ~/Code/my-repo    # label each repo you want to tell apart
```

Then restart the agent in that repo, since hooks load at session launch. For
Codex, also trust the Langfuse hook in `/hooks` on first run.

## Daily use

```bash
make dev/up         # start (idempotent; also the default target)
make docker/ps      # what is running
make docker/logs    # tail logs; SERVICE=langfuse-web to narrow
make dev/down       # stop, keeping all data
make check          # pre-flight: host tools, Docker, tracing tools
make help           # user-facing targets
```

`dev/down` keeps volumes, so the next `dev/up` picks up where you left off.
Services are `restart: always`, so unless stopped they return when Docker
restarts.

## Headless provisioning

`make langfuse/env` writes a `LANGFUSE_INIT_*` block into `.env` using your
`git config user.email` and a generated password and API key pair:

```bash
make langfuse/env HEADLESS_PROJECT_ID=my-project HEADLESS_EMAIL=me@example.com
make langfuse/env HEADLESS=false      # write nothing; sign up in the UI
```

The key pair is **pinned** in `.env`, so after `make docker/clean` (wipes volumes,
keeps `.env`) the same keys are recreated and your apps keep working. `make clean`
also deletes `.env` (keeping `.env.bak`), so it always issues new keys.

Editing `.env` does not affect running containers. `make langfuse/bootstrap`
applies the block to a running stack, recreating the app services, and prints the
`LANGFUSE_HOST` / `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` block for your app.

Provisioning creates exactly **one** project, and once a user exists Langfuse
ignores `LANGFUSE_INIT_*`. Add projects and rotate keys in the UI.

## Projects

Use **one project per application**, all in the same org. A project is a
permanent analysis boundary: traces, dashboards, retention and API keys are all
scoped to it. Do **not** split by environment or, for coding agents, by repo (see
[One project for every repo](#one-project-for-every-repo)).

To add a project: <http://localhost:3000> → your org → **New Project**, then
**Settings → API Keys → Create** and copy the secret key immediately. No restart
is needed.

The project **ID** (e.g. `my-app`) cannot change once traces exist; it is
stamped on every trace row and referenced across Postgres. The **name** (e.g.
`My App`) is a display label you can change any time.

## Integrating an application

This deploys **Langfuse v4**. Point your app at:

```bash
LANGFUSE_HOST=http://localhost:3000   # http://langfuse-web:3000 from another container
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
```

Use a **v4 SDK or OTLP** (`POST /api/public/otel/v1/traces`). v2/v3 SDKs posting
to `/api/public/ingestion` are rejected with `Event type "trace-create" is not
accepted`.

For an SDK you cannot upgrade yet, set `LANGFUSE_MIGRATION_V4_WRITE_MODE=dual` in
`.env` and recreate the app services ([`docker-compose.override.yml`](docker-compose.override.yml)
passes it through). `dual` also fills the legacy tables dashboards read, but does
not backfill, so this repo stays on `events_only` and accepts empty charts.

In events-only mode `GET /api/public/traces` is disabled; read traces in the UI.
They appear after a few seconds because the worker batches writes.

## Tracing coding agents

Tracing shows the prompt a skill received, what it produced, which tools it ran,
and what the turn cost. Two harnesses are supported:

| Harness | Plugin | Secret stored in | Per-repo tags | Needs |
| --- | --- | --- | --- | --- |
| `claude` (Claude Code) | [Claude-Observability-Plugin](https://github.com/langfuse/Claude-Observability-Plugin) | Claude Code's credential store | `<repo>/.claude/settings.json` | [`uv`](https://docs.astral.sh/uv/) |
| `codex` (Codex CLI) | [codex-observability-plugin](https://github.com/langfuse/codex-observability-plugin) | `~/.codex/langfuse.json`, mode `600` | `<repo>/.codex/langfuse.json` | Node.js 22+, `npm`, Codex 0.143+ |

Pick them with `TRACE_HARNESSES` (default `claude`):

```bash
TRACE=true TRACE_HARNESSES="claude codex" make dev/up
make trace/tag ~/Code/my-repo TRACE_HARNESSES="claude codex"
```

Both plugins read the harness's transcript and emit **one trace per turn**.
Claude Code's own OTLP export cannot carry the conversation (the prompt is
redacted and the reply is an OTel log, which Langfuse does not ingest).

### Setup

The commands are in [Quick start](#quick-start). Beyond those:

- **Each harness gets its own key pair** (`LANGFUSE_TRACE_<HARNESS>_*` in `.env`),
  all in one tracing project, so one can be revoked alone.
- **Credentials never enter a repo.** Claude Code keeps the secret in the macOS
  Keychain or `~/.claude/.credentials.json` (Linux); Codex's pair goes to
  `~/.codex/langfuse.json` (mode `600`) with `user_id` set to your Langfuse email.
- **Codex is enabled per repo.** `make trace/tag` writes `hooks = true` and the
  plugin switch to `<repo>/.codex/config.toml`, never `~/.codex/config.toml`. If
  that file exists without them, it prints the two lines to add instead. Start
  Codex from the repo root, and re-trust the hook after plugin updates.
- **Claude Code needs `uv`** to install the hook's `langfuse` dependency. Without
  it the import fails and the hook exits 0, so tracing stops with no error.
- **`make trace/install` needs `LANGFUSE_INIT_USER_EMAIL` and `_PASSWORD`** in
  `.env` (headless provisioning sets them). Otherwise add them, or create the
  project and keys in the UI and set `LANGFUSE_TRACE_<HARNESS>_*` yourself.
- **`TRACE=true` is needed once.** Afterwards the keys in `.env` and the
  configured plugin signal that tracing is wanted, so even after `make clean` a
  plain `make dev/up` reprovisions the project and updates the plugin's key.

Run `make trace/install` alone after rotating keys, then restart running sessions.
It warns rather than fails when a harness's CLI is missing.

### What lands automatically

For Claude Code:

| | How |
| --- | --- |
| Conversation input/output | generation `input`/`output`, as ChatML |
| Thinking blocks | separate field on the generation |
| Tool calls | `Tool: <name>` spans with full arguments and output |
| Cost and token usage | from the transcript, incl. 5m/1h cache-creation split |
| Skill invocations | trace tags `skill:<name>` and `subagent-skill:<name>` |
| Session grouping | Langfuse `session_id` |
| Repo and branch | `cwd`, `project` and `git_branch` trace metadata |

Skill tags cover both `Skill` tool calls and `/slash` invocations. The Codex
plugin traces turns, model calls, tool calls, token usage, subagent threads and
`skill:<name>` tags.

### One project for every repo

All repos and harnesses share one project, so you can ask how a skill behaves
across repos. Keys and queries are project-scoped, so splitting would make that
unanswerable. Tell repos apart with tags:

```bash
make trace/tag ~/Code/my-repo                       # tag defaults to the dir name
make trace/tag ~/Code/svc REPO_LABEL=billing-api
make trace/untag ~/Code/my-repo
```

This writes `CC_LANGFUSE_TRACE_TAGS` (e.g. `repo:my-repo,harness:claude`) to the
repo's `.claude/settings.json`, and `{"tags": [...]}` to `.codex/langfuse.json`.
Neither holds a secret, so they are safe to commit. Both targets are idempotent
and preserve other settings.

For environments, likewise use one project and set `LANGFUSE_TRACING_ENVIRONMENT`
(`development` / `staging` / `production`): in your app's environment, in the
plugin config for Claude Code, or as `environment` in Codex's `langfuse.json`.

### Plugin and proxy together

A [LiteLLM](https://docs.litellm.ai) proxy's Langfuse callback logs **one trace
per model call** (latency, cost, sometimes the serving model). It complements the
plugin, which traces each turn from the transcript regardless of endpoint.

Keep them in **separate projects**, or every model call is counted twice and cost
dashboards roughly double. Share tags so one filter works in both: send
`x-litellm-tags: repo:<label>,harness:claude` via `ANTHROPIC_CUSTOM_HEADERS` for
Claude Code. `scripts/langfuse_project.py` can mint the proxy's key pair too.

Limits observed with Claude Code through a local LiteLLM proxy (2026-10-01):

- **The plugin records the requested model name** (e.g. a group like
  `smart-router`), so its cost may be missing or wrong for unpriced groups.
- **The proxy may not record the model either.** LiteLLM left Model blank on
  streamed requests and undercounted output tokens (11 vs. 45); input matched.
- **Turns are not linked to their model calls.** Match by tags and time.

### Tracing caveats

- **Delivery is at-most-once.** If Langfuse is down or slow (>5s) when a turn
  ends, that turn is lost silently and never retried. Both plugins swallow errors,
  so a stale key looks like success.
- **Tags are immutable** after ingestion; new schemes apply only to new traces.
- **Payloads are truncated** at 20000 characters (`CC_LANGFUSE_MAX_CHARS`), with a
  sha256 of the original kept.
- **Conversation content is sent**, including file contents from reads and edits.
  Decide deliberately before pointing it at anything shared.

## Backup and restore

```bash
make langfuse/backup                                     # -> backups/<UTC stamp>/
make langfuse/restore BACKUP_DEST=$PWD/backups/<stamp>
```

A backup holds Postgres, ClickHouse, MinIO **and the env file**. Restore
reinstates `ENCRYPTION_KEY` and `SALT`, which are bound to the data, so restored
data stays readable and API keys keep working. Datastore passwords are kept from
the current `.env`, since the volumes were created with them.

Destructive targets prompt first (`FORCE=true` skips) and refuse without a
terminal. `make clean` keeps `backups/` and deletes `.env` only if the volumes
were actually removed.

Restore into a clean stack: ClickHouse dumps load with `INSERT`, so rows can
duplicate otherwise.

## Variables

Override on the command line, e.g. `SERVICE=langfuse-worker make docker/logs`.

| Variable | Default | Effect |
| --- | --- | --- |
| `SERVICE` | *(all)* | Limit a target to one compose service |
| `FORCE` | `false` | Skip confirmation prompts; regenerate `.env` |
| `FOLLOW` | `true` | `false` makes `docker/logs` one-shot (for CI) |
| `TAIL` | `100` | Log lines to show |
| `LANGFUSE_VERSION` | `v4.48.0` | Any git ref of the upstream repo; `main` follows upstream |
| `LANGFUSE_URL` | `http://localhost:3000` | Externally reachable URL |
| `BACKUP_DEST` | `backups/<stamp>` | Backup source/target directory |
| `LANGFUSE_WAIT_TIMEOUT` | `300` | Seconds `langfuse/wait` waits |
| `LANGFUSE_WEB_PORT` | `3000` | Host port for the web service |
| `HEADLESS` | `true` | `false` writes no provisioning block; sign up in the UI |
| `HEADLESS_EMAIL` | `git config user.email` | Account the provisioning block creates |
| `HEADLESS_PROJECT_ID` | `claude-code-skills` | Provisioned project's permanent ID |
| `HEADLESS_PROJECT_NAME` | `Coding Agents` | Provisioned project's display name; changeable later |
| `TRACE` | `false` | `true` makes `dev/up` set up tracing on a first run |
| `TRACE_HARNESSES` | `claude` | Harnesses the `trace/*` targets act on: `claude`, `codex` |
| `TRACE_PROJECT_NAME` | `HEADLESS_PROJECT_NAME` | Project `trace/project` finds (by ID first) or creates; `LANGFUSE_TRACE_PROJECT_NAME` in `.env` overrides |
| `REPO_DIR` | *(this repo)* | Repo `trace/tag` acts on; also settable as a bare path argument |
| `REPO_LABEL` | *(dir name)* | Value written as the `repo:<label>` tag |
| `CLAUDE_SETTINGS_FILE` | `<repo>/.claude/settings.json` | Claude Code settings file to tag; point at `settings.local.json` to keep it personal |

`LANGFUSE_VERSION` pins the **compose file**, not the images: upstream uses the
floating `langfuse:4` tag, so the app can be newer than the checked-out ref.

For remote access set both `NEXTAUTH_URL` (in `.env`) and `LANGFUSE_URL` to the
reachable address, or login callbacks break. Only ports 3000 (web) and 9090
(MinIO) need to be reachable; everything else binds to loopback.

## Files

| Path | Committed | Notes |
| --- | --- | --- |
| `Makefile`, `Makefile.helpers` | yes | Targets and the help-screen machinery |
| `.env.example` | yes | Reference for every variable; placeholders only |
| `.env` | **no** | Generated, mode `600`, holds live secrets |
| `docker-compose.override.yml` | yes | Stack env vars upstream's compose does not expose |
| `scripts/` | yes | Key minting (reusable by other tools, such as a LiteLLM setup) and the per-harness tracing adapters |
| `.claude/settings.json` | yes | This repo's `repo:`/`harness:` trace tags; example for others |
| `.claude/settings.local.json` | **no** | Personal overrides, if you use them |
| `.langfuse/` | no | Upstream clone |
| `backups/` | no | Dumps — contain the encryption key |

Use [`.env.example`](.env.example), not upstream's `.env.*.example` files, which
target a source checkout rather than this compose deployment.

## Caveats

- Single-node compose with no HA, scaling or automated backups; use the Helm chart
  for production. Observability data grows quickly, so watch disk.
- Multimodal tracing needs extra blob-storage configuration, because the bundled
  MinIO is not reachable outside the Docker network.
- `make trace/install` uses Langfuse's internal tRPC routes, because the REST
  project API needs an enterprise licence. If upstream changes them it fails
  loudly; create the project and keys in the UI and set `LANGFUSE_TRACE_*` by hand.

## License

This project is licensed under the terms specified in [LICENSE](LICENSE.md).
