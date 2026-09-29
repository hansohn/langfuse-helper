<div align="center">
  <h1>langfuse-helper</h1>
  <p>Makefile wrapper for running [Langfuse](https://langfuse.com) locally via Docker</p>
  <p>
    <!-- Build Status -->
    <a href="https://github.com/hansohn/langfuse-helper/actions/workflows/shellcheck.yml"><img src="https://img.shields.io/github/actions/workflow/status/hansohn/langfuse-helper/shellcheck.yml?style=for-the-badge"></a>
    <!-- Github Tag -->
    <a href="https://github.com/hansohn/langfuse-helper/tags/"><img src="https://img.shields.io/github/v/tag/hansohn/langfuse-helper?style=for-the-badge&sort=semver"></a>
    <!-- License -->
    <a href="https://github.com/hansohn/langfuse-helper/blob/main/LICENSE.md"><img src="https://img.shields.io/github/license/hansohn/langfuse-helper.svg?style=for-the-badge"></a>
  </p>
</div>

Makefile wrapper for running [Langfuse](https://langfuse.com) locally via Docker
Compose, following the [self-hosting compose guide](https://langfuse.com/self-hosting/deployment/docker-compose).

It clones the upstream repo, generates an env file with random secrets, brings
the stack up, and waits until it is actually serving. Optionally it provisions
your org, project, user, and API keys so there are no manual UI steps at all.

It can also trace **Claude Code itself** into Langfuse — one trace per turn
carrying the prompt, the reply, every tool call, the cost, and a tag per skill
invoked — which is useful for tuning skills. See
[Tracing Claude Code](#tracing-claude-code).

## Requirements

To run Langfuse: `git`, `openssl`, `curl`, and Docker with the Compose plugin.
`make langfuse/check` verifies the host tools; `make docker/check` verifies the
daemon.

To trace Claude Code as well (see [Tracing Claude Code](#tracing-claude-code)):

| Tool | Needed for | Why |
| --- | --- | --- |
| `python3` (3.10+) | `trace/project`, `trace/tag` | the two helper scripts in [`scripts/`](scripts) |
| [`uv`](https://docs.astral.sh/uv/) | the plugin's hook | it resolves the hook's pinned `langfuse` SDK; **without it tracing fails silently** |

```bash
brew install uv        # or: curl -LsSf https://astral.sh/uv/install.sh | sh
```

`make trace/check` verifies both.

## Quick start

```bash
make dev/up
```

Clones upstream, writes `.env` with random secrets, starts six containers, and
blocks until `/api/public/health` responds (~2-3 min cold). Then open
<http://localhost:3000> and sign in with your git email and the password it
printed.

`dev/up` writes a headless provisioning block by default, so the org, project,
user and API keys are created for you and the command prints the password. Pass
`HEADLESS=false` to skip that and sign up through the UI instead — but decide
now, because Langfuse provisions **only on first start** and changing your mind
later means `make clean`, which destroys your volumes. See
[Setting up from scratch](#setting-up-from-scratch).

## Setting up from scratch

**1. Host tools.** See [Requirements](#requirements). For tracing also `uv` and
`python3` 3.10+.

**2. Configure and start.**

```bash
git clone <this repo> && cd langfuse-helper
make dev/up
```

To also trace Claude Code, opt in on the first run:

```bash
TRACE=true make dev/up
```

`dev/up` clones upstream, generates `.env` **with a headless provisioning block**,
starts six containers, waits for health, and provisions your org/project/user/keys.
With `TRACE=true` it also creates the tracing project and installs and configures
the plugin. You only need `TRACE=true` once: after that the key pair in `.env` and
the installed plugin both signal that tracing is wanted, so a plain `make dev/up`
keeps it working (including after `make clean`).

Every tracing step is a no-op when it has nothing to do, so re-running `dev/up`
daily costs nothing and prints nothing extra.

It prints the password for the account it created — sign in at
<http://localhost:3000> with your git email.

**3. Label each repo you want to tell apart.**

```bash
make trace/tag ~/Code/my-existing-repo
```

**4. Restart Claude Code in that repo.** Hooks and environment are read at session
launch, so a session already running is never traced. This is the one step nothing
can automate.

### Variations

```bash
make dev/up HEADLESS=false     # no provisioning block; sign up in the UI instead
make trace/install             # just the plugin, e.g. after rotating keys
make trace/check               # just the host-tool check
```

The tracing steps in `dev/up` are all conditional, so it does nothing unasked:

| Step | Skipped when |
| --- | --- |
| `trace/project` | nothing indicates tracing is wanted: `TRACE` is not `true`, no `LANGFUSE_TRACE_*` in `.env`, **and** the plugin is not installed |
| `trace/install` | no key pair, **or** the installed plugin already carries the current one |

Both conditions matter after `make clean`, which deletes `.env`. The
plugin-installed signal is what makes a reset recoverable: a cold `make dev/up`
sees the plugin, provisions the project, issues a key pair, notices the plugin's
stored key no longer matches, and reconfigures it. Without that second signal the
rebuild would skip tracing entirely while the plugin kept its dead key — and since
Langfuse swallows the resulting 401s, tracing would break with no visible error.

`trace/install` warns rather than fails when the `claude` CLI is absent, so
`dev/up` still works in CI or a container.

Headless provisioning is the default because Langfuse provisions **only on first
start** and `trace/project` signs in with those credentials. Opting out and
changing your mind later means `make clean`, which destroys volumes.

## Daily use

```bash
make dev/up         # start (idempotent; safe to re-run)
make docker/ps      # what is running
make docker/logs    # tail logs; SERVICE=langfuse-web to narrow
make dev/down       # stop for the day, keeping all data
```

`dev/down` is an alias for `docker/down`. It removes containers but **preserves
volumes**, so the next `make dev/up` picks up where you left off. All services are
`restart: always`, so without stopping them they come back when Docker restarts.

## Headless provisioning

`make langfuse/env` writes a `LANGFUSE_INIT_*` block by default, so `dev/up`
provisions the org, project, user and a working API key pair with no UI steps. The
account uses your `git config user.email`; the password is generated and printed.

Override any of it:

```bash
make langfuse/env HEADLESS_PROJECT_ID=my-project HEADLESS_EMAIL=me@example.com
make langfuse/env HEADLESS=false      # write nothing; sign up in the UI
```

The API key pair is **pinned** in `.env` on purpose. `make docker/clean` wipes the
volumes but keeps `.env`, so on the next start bootstrap recreates the same keys
in the fresh database and apps configured with them keep working. Without pinning,
every volume reset means fetching new keys from the UI. `make clean` also deletes
`.env` (keeping a copy as `.env.bak`), so a full clean always issues new keys.

To apply the block to an already-running stack:

```bash
make langfuse/bootstrap
```

Editing `.env` does **not** affect a running container — environment is fixed at
container creation. `langfuse/bootstrap` recreates the app services for you,
refuses to run if a required value is missing, and reports what the database
actually holds (rather than echoing back your env file), ending with the
`LANGFUSE_HOST` / `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` block to paste
into your application.

`dev/up` runs bootstrap as its last step, so with the block configured a single
`make dev/up` provisions everything. Without it, bootstrap is a silent no-op.

Provisioning applies **only on first run**, and creates exactly **one** project —
the variables are singular. Once a user exists Langfuse ignores `LANGFUSE_INIT_*`
entirely, so it cannot rotate a key or add a second project. Do those in the UI
(see [Projects](#projects)).

## Projects

Run **one Langfuse project per application you instrument**, all under the same
org on this one shared server. `project_id` is the scoping key — it is stamped on
every trace row, and dashboards, retention, and API keys are all per project. So a
project boundary is a permanent analysis boundary: two applications sharing one
project means interleaved traces you cannot practically separate later.

Claude Code traces are the deliberate exception: they share a single project across
every repo, because the point is comparing a skill's behaviour *between* repos. See
[One project for every repo](#one-project-for-every-repo).

This repo needs no project of its own: it is infrastructure that runs the server
and instruments no application. It does trace its own Claude Code sessions, but
those go to the shared Claude Code project like every other repo's — see
[Tracing Claude Code](#tracing-claude-code).

### Adding a project

`langfuse/bootstrap` provisions your first project. Every one after that is
created in the UI, which is also the quickest way to add one at any time — it
needs no teardown and does not touch the running stack:

1. <http://localhost:3000> → your org → **New Project**
2. **Settings → API Keys → Create**, and copy the secret key immediately

There is a REST endpoint for this (`POST /api/public/projects`), but it needs the
`admin-api` entitlement, which belongs to `self-hosted:enterprise` — an
unlicensed deployment reports plan `oss` and gets 403. The UI is the path here.

Keys made this way are generated by Langfuse rather than pinned in `.env`, so
store them with the repo they belong to. Only re-provision
(`make clean && make dev/up`) if you specifically want a clean slate with keys you
control from `.env` — it is never *required* just to add a project.

### Naming

`LANGFUSE_INIT_PROJECT_ID` and `_NAME` are separate fields with very different
lifetimes:

| Field | Example | Changeable |
| --- | --- | --- |
| `_PROJECT_ID` | `sre-oncall-skills` | **No**, once traces exist |
| `_PROJECT_NAME` | `SRE Oncall Skills` | Yes — display label only |

Use the repo's slug for the ID and a human label for the name. The ID is
referenced by `project_id` on every trace row and by foreign keys across ~49
Postgres tables, so changing it means re-provisioning rather than renaming, and
existing traces would be orphaned. Pick it before you accumulate data worth
keeping.

### Do not split by environment

Use one project across all environments and separate them with the tracing
environment instead:

```bash
LANGFUSE_TRACING_ENVIRONMENT=development   # or staging / production
```

Same project, same keys, filterable in the UI. A project per environment
fragments dashboards and multiplies key management for no benefit. Likewise a
monorepo usually wants one project with per-service spans, unless the services
are genuinely owned separately.

The same reasoning applies to Claude Code traces, which share one project across
every repo: repo is a filterable field (see
[One project for every repo](#one-project-for-every-repo)), not a project split.

## Integrating an application

This deploys **Langfuse v4**. Point your app at:

```bash
LANGFUSE_HOST=http://localhost:3000
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
```

Use a **v4 SDK or OTLP** (`POST /api/public/otel/v1/traces`). A v2/v3 SDK posting
trace events to `/api/public/ingestion` is rejected:

> Event type "trace-create" is not accepted by /api/public/ingestion when
> `LANGFUSE_MIGRATION_V4_WRITE_MODE` is `events_only`.

As a migration bridge for an SDK you cannot upgrade yet, set
`LANGFUSE_MIGRATION_V4_WRITE_MODE=dual` in `.env` and recreate the app services.
Setting it in `.env` alone does **nothing**: upstream's compose file enumerates
every variable it passes, so one it does not list never reaches the container.
[`docker-compose.override.yml`](docker-compose.override.yml) declares it, which is
what makes the `.env` value take effect.

`dual` also writes the legacy `observations`/`traces` tables that dashboards read,
which `events_only` leaves empty. It does **not** backfill, so switching makes
pre-existing traces invisible to any UI path reading those tables — which is why
this repo stays on `events_only` and accepts that charts are empty.

Two other v4 notes: the public `GET /api/public/traces` read endpoint is disabled
in events-only mode (read traces in the UI), and ingested traces take a few
seconds to appear because the worker batches writes.

If your app runs in another container, use `http://langfuse-web:3000` on the
compose network rather than `localhost`.

## Tracing Claude Code

Claude Code sessions can be traced into Langfuse, which is useful for tuning
skills: you see the prompt a skill received, what it produced, which tools it
ran, and what the turn cost.

This uses the official
[Langfuse plugin](https://github.com/langfuse/Claude-Observability-Plugin). It
reads Claude Code's transcript and emits **one trace per turn** with the
conversation on it. That matters: Claude Code's own OTLP trace export cannot carry
a conversation at all — the prompt is redacted unless a flag is set, and the
assistant's reply is emitted as an OTel *log* record, which Langfuse does not
ingest. The transcript has both sides, so the plugin does.

### Setup

The commands are in [Setting up from scratch](#setting-up-from-scratch).
What those steps do not explain:

**`make trace/project` needs `LANGFUSE_INIT_USER_EMAIL` and `_PASSWORD` in
`.env`** to log in, because it drives the same routes the UI uses. If you provisioned with
[Headless provisioning](#headless-provisioning) they are already there. If you
signed up through the UI instead, either add them to `.env` or skip the target:
create the project and an API key pair in the UI and put them in
`LANGFUSE_TRACE_PUBLIC_KEY` / `_SECRET_KEY` yourself. The target says as much if
they are missing.

**`uv` is required.** The plugin's hook declares its dependency
(`langfuse>=4.7,<5`) as PEP 723 inline metadata, and `hooks.json` runs it with
`uv run --script` when `uv` is on PATH and plain `python3` otherwise. Without
`uv` the dependency is not installed, the import fails, and **tracing silently
stops** — the hook logs and exits 0 by design, so nothing surfaces.

Credentials live in the plugin's own machine-scope config, so tracing is on for
every repo and **no secret ever enters this or any other repo**. Claude Code puts
the secret in the OS keychain; only the public key and base URL land in
`~/.claude/settings.json`.

### What lands automatically

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
leaves no tool call at all — so tuning a skill can be filtered by its tag.

### One project for every repo

All repos share one Langfuse project. Langfuse documents separate projects for
**access control** only; a project is also a hard boundary, since keys are bound to
one project and analytical queries are project-scoped. Splitting by repo would make
"how does this skill behave across my repos" unanswerable, which is usually the
reason to trace skills at all.

Repos are told apart three ways, all queryable:

```bash
make trace/tag ~/Code/my-repo                       # tag defaults to the dir name
make trace/tag ~/Code/svc REPO_LABEL=billing-api
make trace/untag ~/Code/my-repo
```

That writes one variable to the repo's `.claude/settings.json`:

```json
{ "env": { "CC_LANGFUSE_TRACE_TAGS": "repo:my-repo" } }
```

It holds no secret, so committing it is safe and the label travels with the clone.
`cwd`/`project`/`git_branch` metadata is added by the plugin regardless, so an
untagged repo is still identifiable — the tag just gives you a filter facet
alongside `skill:*`. Both targets are idempotent, preserve sibling tags and other
settings keys, refuse a file that is not valid JSON, and prune the obsolete
variables left by the OTel-collector setup this replaced.

Environments are **not** a reason to split projects either. The plugin does not set
Langfuse's `environment` field, but the Langfuse SDK reads
`LANGFUSE_TRACING_ENVIRONMENT` itself, so set that in the plugin config to separate
`development` / `staging` / `production` within the one project.

### Tracing caveats

**Delivery is at-most-once.** The hook persists its transcript offset *before*
flushing to Langfuse, caps the flush at 5s, and never retries — an acknowledged
limitation in its source. If Langfuse is down or slow when a turn ends, that turn
is lost silently and is not backfilled. Auth failures are swallowed too, so a stale
key looks identical to success.

**Tags are immutable.** Langfuse cannot add or edit tags after ingestion, so a
tagging scheme decided later applies only to new traces.

**Payloads are truncated** at 20000 characters (`CC_LANGFUSE_MAX_CHARS`),
head-first, with a sha256 of the original retained so a truncated value stays
identifiable.

**This sends conversation content.** Prompts, replies, thinking blocks and tool
bodies — including file contents from `Read`/`Edit` — all go to Langfuse. That is
the point of it, but it is a larger surface than infrastructure telemetry, so decide
deliberately before pointing it at anything shared.

**Traces take a few seconds** to appear: the hook fires at turn end and the worker
batches writes. `GET /api/public/traces` is disabled in events-only mode, so read
in the UI.

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

## Targets

`make help` lists every target with its purpose. Reproduced here, and generated
from the `##` comments in the [`Makefile`](Makefile) so the two cannot disagree:

```console
$ make help
Available targets:

  clean                               Remove compose state, langfuse source and .env (keeps backups)
  dev/down                            Stop everything for the day, keeping all data
  dev/up                              Clone, configure and start Langfuse (default goal)
  docker/check                        Verify the Docker daemon is running and the compose file exists
  docker/clean                        Remove compose containers, networks and volumes (prompts first)
  docker/down                         Remove compose containers and networks, preserving volumes
  docker/logs                         Tail compose service logs
  docker/ps                           Show compose service status, including stopped containers
  docker/up                           Create and start compose services, restarting any that are stopped
  help                                Help screen
  help/all                            Display help for all targets
  help/short                          This help short screen
  langfuse/backup                     Back up datastores and the encryption key
  langfuse/bootstrap                  Provision the initial org, project, user and API keys
  langfuse/check                      Verify required host dependencies are installed
  langfuse/clone                      Clone or update langfuse source at LANGFUSE_VERSION
  langfuse/env                        Generate env file with random secrets (headless provisioning by default)
  langfuse/restore                    Restore datastores from BACKUP_DEST
  langfuse/wait                       Wait for the langfuse web service to become healthy
  trace/check                         Verify the host tools tracing needs
  trace/install                       Install and configure the Langfuse plugin (idempotent, machine-scope)
  trace/project                       Ensure the tracing project and API keys exist (idempotent)
  trace/tag                           Label a repo's traces with repo:<name> (idempotent)
  trace/untag                         Remove the repo:<name> tag from a repo
```

`help/all` includes targets from every included makefile. Running `make` with no
goal runs `dev/up`, not help.

There is deliberately no `docker/build` or `docker/push`: every service uses a
prebuilt image, so the compose file has no `build:` sections.

## Variables

Override on the command line, e.g. `SERVICE=langfuse-worker make docker/logs`.

| Variable | Default | Effect |
| --- | --- | --- |
| `SERVICE` | *(all)* | Limit a target to one compose service |
| `FORCE` | `false` | Skip confirmation prompts; regenerate `.env` |
| `FOLLOW` | `true` | `false` makes `docker/logs` one-shot (for CI) |
| `TAIL` | `100` | Log lines to show |
| `LANGFUSE_VERSION` | `main` | Any git ref of the upstream repo |
| `LANGFUSE_URL` | `http://localhost:3000` | Externally reachable URL |
| `BACKUP_DEST` | `backups/<stamp>` | Backup source/target directory |
| `LANGFUSE_WAIT_TIMEOUT` | `300` | Seconds `langfuse/wait` waits |
| `LANGFUSE_WEB_PORT` | `3000` | Host port for the web service |
| `HEADLESS` | `true` | `false` writes no provisioning block; sign up in the UI |
| `HEADLESS_EMAIL` | `git config user.email` | Account the provisioning block creates |
| `HEADLESS_PROJECT_ID` | `claude-code-skills` | Provisioned project's permanent ID |
| `TRACE` | `false` | `true` makes `dev/up` set up Claude Code tracing on a first run |
| `TRACE_PROJECT_NAME` | `Claude Code Skills` | Project `trace/project` finds or creates; read from `.env` when set there |
| `REPO_DIR` | *(this repo)* | Repo `trace/tag` acts on; also settable as a bare path argument |
| `REPO_LABEL` | *(dir name)* | Value written as the `repo:<label>` tag |
| `REPO_SETTINGS_FILE` | `<repo>/.claude/settings.json` | Settings file to write; point at `settings.local.json` to keep it personal |

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
| `scripts/` | yes | Helpers for `trace/project` and `trace/tag` |
| `.claude/settings.json` | yes | This repo's `repo:` trace tag; example for others |
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

`make trace/project` drives Langfuse's internal tRPC routes, because the REST
equivalent (`POST /api/public/projects`) needs the enterprise-only `admin-api`
entitlement. Those routes carry no stability guarantee — an upstream change breaks
it loudly at the project-creation step, and the fallback is to create the project
and keys in the UI and set `LANGFUSE_TRACE_*` by hand.

Tracing caveats specific to the plugin are in
[Tracing caveats](#tracing-caveats) — the important one is that delivery is
at-most-once.
