<div align="center">
  <h1>langfuse-helper</h1>
  <p>Run self-hosted Langfuse locally and trace Claude Code into it</p>
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

It clones the upstream repo, generates an env file with random secrets, brings
the stack up, and waits until it is actually serving. Optionally it provisions
your org, project, user, and API keys so there are no manual UI steps at all.

It can also trace **coding agents** into Langfuse — Claude Code and Codex, one
trace per turn carrying the prompt, the reply, every tool call, the cost, and a
tag per skill invoked — which is useful for tuning skills. See
[Tracing coding agents](#tracing-coding-agents).

## Requirements

To run Langfuse: `git`, `openssl`, `curl`, and Docker with the Compose plugin.
`make check` verifies the host tools and the Docker daemon.

To trace coding agents as well, `python3` 3.10+ (for the helpers in
[`scripts/`](scripts)) plus each harness's own needs: [`uv`](https://docs.astral.sh/uv/)
for Claude Code — **without it tracing fails silently** (see [Setup](#setup)) —
and Node.js 22+ with `npm` for Codex. `make check` verifies them once tracing is
set up; `TRACE=true make check` includes them before that.

```bash
brew install uv        # or: curl -LsSf https://astral.sh/uv/install.sh | sh
```

## Platform support

- **macOS and Linux** are supported. CI runs the whole stack — start, backup,
  clean, restore — on Ubuntu. On Linux, add yourself to the `docker` group
  (`sudo usermod -aG docker $USER`, then log in again); `make check` says so
  when that is the problem.
- **Windows** works through **WSL2** only: the Makefile needs bash, GNU make and
  POSIX tools, so it does not run from PowerShell or cmd. Use Docker Desktop with
  WSL integration and clone **inside** the WSL filesystem (`~/...`), not under
  `/mnt/c` — that is slow, and `chmod 600` does not stick there, which quietly
  weakens the protection on `.env`. The repo's `.gitattributes` keeps files LF,
  so a checkout made with Git for Windows still runs.

## Quick start

**1. Start Langfuse.**

```bash
git clone <this repo> && cd langfuse-helper
make dev/up                # or TRACE=true make dev/up to also trace Claude Code
```

This clones upstream, writes `.env` with random secrets, starts six containers,
blocks until `/api/public/health` responds (~2-3 min cold), and provisions your
org, project, user and API keys. It prints a password: sign in at
<http://localhost:3000> with your git email and that password.

Provisioning is on by default because Langfuse provisions **only on first
start**. `make dev/up HEADLESS=false` skips it so you sign up through the UI
instead — but decide now, since changing your mind later means `make clean`,
which destroys your volumes. See [Headless provisioning](#headless-provisioning).

`TRACE=true` also creates the tracing project and installs and configures the
Langfuse plugin for each harness in `TRACE_HARNESSES` (default `claude`; add
`codex` for Codex). It is needed only once; see [Setup](#setup).

**2. Label each repo you want to tell apart** (tracing only).

```bash
make trace/tag ~/Code/my-existing-repo
```

**3. Restart the agent in that repo.** Hooks and environment are read at session
launch, so a session already running is never traced. For Codex, also trust the
Langfuse hook in `/hooks` on first run. These are the steps nothing can automate.

## Daily use

```bash
make dev/up         # start (idempotent; also the default, so plain `make` works)
make docker/ps      # what is running
make docker/logs    # tail logs; SERVICE=langfuse-web to narrow
make dev/down       # stop for the day, keeping all data
make check          # pre-flight: host tools, Docker, and tracing tools if set up
make help           # the user-facing targets, with their purpose
```

`make help` lists only the targets you run by hand. The steps `dev/up` runs for
you (`langfuse/clone`, `langfuse/wait`, `docker/up`, `trace/project`, the
individual checks) are left out of it but still work when called by name.

`dev/down` is an alias for `docker/down`. It removes containers but **preserves
volumes**, so the next `make dev/up` picks up where you left off. All services are
`restart: always`, so without stopping them they come back when Docker restarts.

## Headless provisioning

`make langfuse/env` writes a `LANGFUSE_INIT_*` block into `.env` by default. The
account uses your `git config user.email`; the password and API key pair are
generated. Override any of it:

```bash
make langfuse/env HEADLESS_PROJECT_ID=my-project HEADLESS_EMAIL=me@example.com
make langfuse/env HEADLESS=false      # write nothing; sign up in the UI
```

The API key pair is **pinned** in `.env` on purpose. `make docker/clean` wipes the
volumes but keeps `.env`, so on the next start bootstrap recreates the same keys
in the fresh database and apps configured with them keep working. Without pinning,
every volume reset means fetching new keys from the UI. `make clean` also deletes
`.env` (keeping a copy as `.env.bak`), so a full clean always issues new keys.

`dev/up` applies the block as its last step. To apply it to an already-running
stack:

```bash
make langfuse/bootstrap
```

Editing `.env` does **not** affect a running container — environment is fixed at
container creation. `langfuse/bootstrap` recreates the app services for you,
refuses to run if a required value is missing, and reports what the database
actually holds (rather than echoing back your env file), ending with the
`LANGFUSE_HOST` / `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` block to paste
into your application.

Provisioning creates exactly **one** project — the variables are singular — and
once a user exists Langfuse ignores `LANGFUSE_INIT_*` entirely, so it cannot
rotate a key or add a second project. Do those in the UI.

## Projects

Run **one Langfuse project per application you instrument**, all under the same
org on this one shared server. `project_id` is the scoping key — it is stamped on
every trace row, and dashboards, retention, and API keys are all per project. So a
project boundary is a permanent analysis boundary: two applications sharing one
project means interleaved traces you cannot practically separate later.

Do **not** split by environment or, for coding agents, by repo — see
[One project for every repo](#one-project-for-every-repo).

### Adding a project

Every project after the first is created in the UI. It needs no teardown and does
not touch the running stack:

1. <http://localhost:3000> → your org → **New Project**
2. **Settings → API Keys → Create**, and copy the secret key immediately

Keys made this way are generated by Langfuse rather than pinned in `.env`, so
store them with the repo they belong to. Re-provisioning
(`make clean && make dev/up`) is never *required* just to add a project.

### Naming

`LANGFUSE_INIT_PROJECT_ID` and `_NAME` are separate fields with very different
lifetimes:

| Field | Example | Changeable |
| --- | --- | --- |
| `_PROJECT_ID` | `my-app` | **No**, once traces exist |
| `_PROJECT_NAME` | `My App` | Yes — display label only |

Use the repo's slug for the ID and a human label for the name. The ID is
referenced by `project_id` on every trace row and by foreign keys across ~49
Postgres tables, so changing it means re-provisioning rather than renaming, and
existing traces would be orphaned. Pick it before you accumulate data worth
keeping.

## Integrating an application

This deploys **Langfuse v4**. Point your app at:

```bash
LANGFUSE_HOST=http://localhost:3000
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
```

If your app runs in another container, use `http://langfuse-web:3000` on the
compose network rather than `localhost`.

Use a **v4 SDK or OTLP** (`POST /api/public/otel/v1/traces`). A v2/v3 SDK posting
trace events to `/api/public/ingestion` is rejected:

> Event type "trace-create" is not accepted by /api/public/ingestion when
> `LANGFUSE_MIGRATION_V4_WRITE_MODE` is `events_only`.

As a migration bridge for an SDK you cannot upgrade yet, set
`LANGFUSE_MIGRATION_V4_WRITE_MODE=dual` in `.env` and recreate the app services.
Setting it in `.env` alone would do **nothing**: upstream's compose file enumerates
every variable it passes, so one it does not list never reaches the container.
[`docker-compose.override.yml`](docker-compose.override.yml) declares it, which is
what makes the `.env` value take effect.

`dual` also writes the legacy `observations`/`traces` tables that dashboards read,
which `events_only` leaves empty. It does **not** backfill, so switching makes
pre-existing traces invisible to any UI path reading those tables — which is why
this repo stays on `events_only` and accepts that charts are empty.

In events-only mode the public `GET /api/public/traces` endpoint is also
disabled, so read traces in the UI. They take a few seconds to appear because the
worker batches writes.

## Tracing coding agents

Coding agent sessions can be traced into Langfuse, which is useful for tuning
skills: you see the prompt a skill received, what it produced, which tools it
ran, and what the turn cost. Two harnesses are supported:

| Harness | Plugin | Secret stored in | Per-repo tags | Needs |
| --- | --- | --- | --- | --- |
| `claude` (Claude Code) | [Claude-Observability-Plugin](https://github.com/langfuse/Claude-Observability-Plugin) | Claude Code's credential store | `<repo>/.claude/settings.json` | [`uv`](https://docs.astral.sh/uv/) |
| `codex` (Codex CLI) | [codex-observability-plugin](https://github.com/langfuse/codex-observability-plugin) | `~/.codex/langfuse.json`, mode `600` | `<repo>/.codex/langfuse.json` | Node.js 22+, `npm`, Codex 0.143+ |

Pick them with `TRACE_HARNESSES` (default `claude`):

```bash
TRACE=true TRACE_HARNESSES="claude codex" make dev/up
make trace/tag ~/Code/my-repo TRACE_HARNESSES="claude codex"
```

Both plugins read the harness's own transcript and emit **one trace per turn**
with the conversation on it. That matters for Claude Code in particular: its own
OTLP trace export cannot carry a conversation at all — the prompt is redacted
unless a flag is set, and the assistant's reply is emitted as an OTel *log*
record, which Langfuse does not ingest. The transcript has both sides.

### Setup

The commands are in [Quick start](#quick-start). What they do not explain:

**Each harness gets its own key pair**, `LANGFUSE_TRACE_<HARNESS>_PUBLIC_KEY` /
`_SECRET_KEY` in `.env`, all in the one tracing project. One can be revoked
without touching the others.

**Credentials never enter a repo.** They live in each plugin's machine-scope
config, so a configured harness traces every repo. Claude Code keeps the secret
with its other credentials — the macOS Keychain, or `~/.claude/.credentials.json`
(mode `600`) on Linux — and only the public key and base URL land in
`~/.claude/settings.json`. Codex has no credential store, so its pair is written to
`~/.codex/langfuse.json` with mode `600`, together with `user_id` set to your
Langfuse account's email — otherwise the plugin reports your Codex login email.

**Codex is enabled per repo.** The plugin needs `hooks = true` and the plugin
switched on in a Codex `config.toml`. `make trace/tag` writes those two settings
to `<repo>/.codex/config.toml` and never touches `~/.codex/config.toml`. If the
repo already has a `config.toml` that does not enable the plugin, `trace/tag`
refuses and prints the two lines to add, rather than rewriting a file it did not
write. Two things only you can do: **trust the Langfuse `Stop` hook** in Codex's
`/hooks` on first run (and again after a plugin update), and start Codex from
the repo root — the plugin reads per-repo settings from the working directory.

**Claude Code needs `uv`.** The plugin's hook declares its dependency
(`langfuse>=4.7,<5`) as PEP 723 inline metadata, and `hooks.json` runs it with
`uv run --script` when `uv` is on PATH and plain `python3` otherwise. Without
`uv` the dependency is not installed, the import fails, and **tracing silently
stops** — the hook logs and exits 0 by design, so nothing surfaces.

**`make trace/install` needs `LANGFUSE_INIT_USER_EMAIL` and `_PASSWORD` in
`.env`** to create the keys: it logs in and drives the same routes the UI uses.
Headless provisioning puts them there. If you signed up through the UI instead,
either add them to `.env`, or create the project and an API key pair per harness
in the UI and set `LANGFUSE_TRACE_<HARNESS>_*` yourself — `trace/install` then
finds working keys and only configures the plugins.

**`TRACE=true` is needed once.** The tracing steps in `dev/up` are conditional,
so a plain `make dev/up` does nothing unasked. For each harness:

| Step | Skipped when |
| --- | --- |
| `trace/project` | nothing indicates tracing is wanted: `TRACE` is not `true`, no key pair in `.env`, **and** the plugin is not configured |
| `trace/install` | no key pair, **or** the plugin already carries the current one |

After the first run, the key pair in `.env` and the configured plugin both signal
that tracing is wanted. The plugin signal is what makes `make clean` (which
deletes `.env`) recoverable: a cold `make dev/up` sees the plugin, provisions the
project, issues a key pair, notices the plugin's stored key no longer matches,
and reconfigures it. Without it the rebuild would skip tracing while the plugin
kept its dead key — and since the plugins swallow the resulting 401s, tracing
would break with no visible error.

`trace/install` warns rather than fails when a harness's CLI is absent, so
`dev/up` still works in CI or a container. Run it alone (`make trace/install`)
after rotating keys. Restart running sessions afterwards; hooks load at launch.

### What lands automatically

What each plugin records differs in detail; Claude Code's is:

| | How |
| --- | --- |
| Conversation input/output | generation `input`/`output`, as ChatML |
| Thinking blocks | separate field on the generation |
| Tool calls | `Tool: <name>` spans with full arguments and output |
| Cost and token usage | from the transcript, incl. 5m/1h cache-creation split |
| Skill invocations | trace tags `skill:<name>` and `subagent-skill:<name>` |
| Session grouping | Langfuse `session_id` |
| Repo and branch | `cwd`, `project` and `git_branch` trace metadata |

Skill tags catch both trails — a `Skill` tool call and a `/slash` invocation, which
leaves no tool call at all — so tuning a skill can be filtered by its tag. The
Codex plugin also traces turns, model calls, tool calls, token usage, subagent
threads and `skill:<name>` tags.

### One project for every repo

All repos and harnesses share one Langfuse project. Langfuse documents separate
projects for **access control** only; a project is also a hard boundary, since
keys are bound to one project and analytical queries are project-scoped.
Splitting by repo or harness would make "how does this skill behave across my
repos" unanswerable, which is usually the reason to trace skills at all.

Repos and harnesses are told apart by tags:

```bash
make trace/tag ~/Code/my-repo                       # tag defaults to the dir name
make trace/tag ~/Code/svc REPO_LABEL=billing-api
make trace/untag ~/Code/my-repo
```

For Claude Code that writes one variable to the repo's `.claude/settings.json`:

```json
{ "env": { "CC_LANGFUSE_TRACE_TAGS": "repo:my-repo,harness:claude" } }
```

For Codex it writes `{"tags": ["repo:my-repo", "harness:codex"]}` to
`.codex/langfuse.json`, next to the `config.toml` described in [Setup](#setup).
None of these hold a secret, so committing them is safe and the label travels
with the clone. `cwd`/`project`/`git_branch` metadata is added by the Claude
plugin regardless, so an untagged repo is still identifiable — the tags just give
you filter facets alongside `skill:*`. Both targets are idempotent, preserve
sibling tags and other settings keys, and refuse a file they cannot parse.

The same reasoning applies to environments, for coding agents and applications
alike: use one project and set `LANGFUSE_TRACING_ENVIRONMENT` (`development` /
`staging` / `production`), which the Langfuse SDK reads itself — in your app's
environment, or in the plugin config for Claude Code, since the plugin does not
set Langfuse's `environment` field itself (Codex has an `environment` option in
`langfuse.json`). A project per environment fragments dashboards and multiplies
key management for no benefit. Likewise a monorepo usually wants one project with
per-service spans, unless the services are genuinely owned separately.

### Plugin and proxy together

A harness can also send its model calls through a
[LiteLLM](https://docs.litellm.ai) proxy, whose Langfuse callback logs **one trace
per model call** — latency, cost and, for some kinds of request, the upstream
model that served it. That works alongside the plugin, not
instead of it: the plugin reads the transcript on your machine, so it traces a
turn the same way whichever endpoint served it.

Keep the two in **separate projects**. In one project every model call would be
counted twice — once on the plugin's turn trace, once on the proxy's call trace
— and cost and token dashboards would roughly double. They also answer different
questions: what the agent did, versus how the request was routed and what it cost.

Give them a shared tag vocabulary so one filter works in both projects: send
`repo:<label>` and `harness:<name>` on proxied requests, using the directory name
as the label as `trace/tag` does. LiteLLM reads them from an `x-litellm-tags`
header — for Claude Code, set `ANTHROPIC_CUSTOM_HEADERS` to
`x-litellm-tags: repo:<label>,harness:claude`. `scripts/langfuse_project.py` can
also mint the proxy's key pair, so both projects are provisioned the same way.

Limits, as observed with Claude Code through a local LiteLLM proxy (2026-10-01):

- **The plugin records the model name the harness asked for** — a model-group
  name such as `smart-router`, not the model that served it — so **cost on the
  plugin's traces may be missing or wrong** for groups without a price.
- **The proxy's trace may not record the model either.** LiteLLM left Model blank
  on Claude Code's streamed requests, and its output-token count was lower than
  the plugin's for the same turn (11 versus 45). Input tokens matched.
- **There is no link from a turn to its model calls.** Match them by tags and
  time; a real link needs the harness to send its session ID on every request,
  which neither does today.

### Tracing caveats

**Delivery is at-most-once.** The Claude Code hook persists its transcript offset
*before* flushing to Langfuse, caps the flush at 5s, and never retries — an
acknowledged limitation in its source. If Langfuse is down or slow when a turn
ends, that turn is lost silently and is not backfilled. Both plugins swallow
errors by default, so a stale key looks identical to success.

**Tags are immutable.** Langfuse cannot add or edit tags after ingestion, so a
tagging scheme decided later applies only to new traces.

**Payloads are truncated** by the Claude Code plugin at 20000 characters
(`CC_LANGFUSE_MAX_CHARS`), head-first, with a sha256 of the original retained so a
truncated value stays identifiable.

**This sends conversation content.** Prompts, replies, thinking blocks and tool
bodies — including file contents from reads and edits — all go to Langfuse. That
is the point of it, but it is a larger surface than infrastructure telemetry, so
decide deliberately before pointing it at anything shared.

## Backup and restore

Postgres, ClickHouse, and MinIO all hold state that `make clean` destroys.

```bash
make langfuse/backup                                     # -> backups/<UTC stamp>/
make langfuse/restore BACKUP_DEST=$PWD/backups/<stamp>
```

A backup captures all three datastores **plus the env file**, because
`ENCRYPTION_KEY` and `SALT` are bound to the data, not the deployment:
`ENCRYPTION_KEY` decrypts stored LLM credentials and `SALT` verifies hashed API
keys. Restore reinstates both from the backup, so data restored onto a
reprovisioned stack stays readable and your API keys keep working.

Datastore passwords are deliberately **not** reinstated — a reprovisioned stack
initialised its volumes from the current `.env`, so those are the passwords the
volumes accept.

Both destructive targets prompt before acting and refuse rather than proceed when
there is no terminal to confirm on. `FORCE=true` skips the prompt for scripts.
`make clean` preserves `backups/`, and refuses to delete `.env` unless the volumes
were actually removed (answering no, or Docker not running, stops it), since
`.env` holds the passwords those volumes were created with.

Only ClickHouse tables that hold data are dumped; views, materialized views and
`schema_migrations` are skipped, and restore detaches materialized views while
loading so their target tables are not written twice.

Known limitation: ClickHouse dumps load with `INSERT`, which appends. Restore
into a clean stack or rows can duplicate.

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

`LANGFUSE_VERSION` pins the **compose file**, not the images — upstream pins
`langfuse:4`, a floating major tag, so the running app version can be newer than
the checked-out ref.

For remote access set both `NEXTAUTH_URL` (in `.env`) and `LANGFUSE_URL` to the
reachable address; a mismatched `NEXTAUTH_URL` breaks login callbacks. Only ports
3000 (web) and 9090 (MinIO) need to be reachable; everything else binds to
loopback.

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

Upstream ships its own `.env.*.example` files, but they target a source checkout
rather than this compose deployment (they point `DATABASE_URL` at `db:5432`
instead of `postgres:5432` and omit several required secrets). Use
[`.env.example`](.env.example) here.

## Caveats

Single-node compose with no HA, horizontal scaling, or automated backups — use
the Helm chart for production. Observability data grows quickly, so watch disk.
Multimodal tracing needs extra blob-storage configuration because the bundled
MinIO is not reachable outside the Docker network for direct uploads.

Creating the tracing keys (`make trace/install`) drives Langfuse's internal tRPC
routes, because the REST
equivalent (`POST /api/public/projects`) needs the `admin-api` entitlement, which
belongs to `self-hosted:enterprise` — an unlicensed deployment reports plan `oss`
and gets 403. The tRPC routes carry no stability guarantee: an upstream change
breaks the target loudly at the project-creation step, and the fallback is to
create the project and keys in the UI and set `LANGFUSE_TRACE_*` by hand.

## License

This project is licensed under the terms specified in [LICENSE](LICENSE.md).
