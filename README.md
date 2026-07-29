# buzzer

A NixOS module that runs a self-hosted [Buzz](https://github.com/block/buzz) workspace on a
single host: the relay, its data services, and (optionally) a **headless agent** that stays
online when no desktop client is running.

Buzz ships a desktop app whose agents run as child processes of that app - close the laptop
and they stop. This module runs the same ACP harness as a system service instead, so an
agent is a permanent member of the workspace rather than a feature of one machine.

## What it sets up

| Component | How |
|---|---|
| Postgres | native NixOS service, loopback only |
| Valkey | native NixOS service, loopback only |
| Garage (S3) | native NixOS service, loopback only |
| Buzz relay | upstream container image, host networking |
| `buzz-acp` + `buzz` CLI | **built from source** by this flake |
| Ingress | optional Cloudflare tunnel |
| Backups | optional nightly `pg_dump`, auto-pruned |

Only the ingress is reachable from outside the host; every data service binds to
`127.0.0.1`.

## Usage

```nix
{
  inputs.buzzer.url = "github:<you>/buzzer";

  # in your host's modules:
  imports = [ inputs.buzzer.nixosModules.buzzer ];

  services.buzzer = {
    enable = true;
    domain = "buzz.example.com";
    relay.environmentFile   = "/etc/buzz/relay.env";
    valkey.passwordFile     = "/etc/buzz/valkey.pass";
    garage.environmentFile  = "/etc/buzz/garage.env";
    agent.enable            = true;
    agent.environmentFile   = "/etc/buzz/agent.env";
    backup.enable           = true;   # nightly pg_dump, pruned after 14 days
    tunnel.enable           = true;
    tunnel.name             = "buzz-tunnel";
    tunnel.credentialsFile  = "/etc/cloudflared/credentials.json";
  };
}
```

A complete host is in [`example/`](example/), which is also what `nix flake check`
type-checks the module against.

## Secrets

Referenced by path so they stay out of the world-readable Nix store. Create them `0600`
before the first switch.

| File | Contents |
|---|---|
| `relay.env` | `DATABASE_URL`, `REDIS_URL`, `BUZZ_S3_*`, `BUZZ_RELAY_PRIVATE_KEY`, `RELAY_OWNER_PUBKEY`, `BUZZ_DOMAIN`, `BUZZ_CORS_ORIGINS`, `BUZZ_MEDIA_*` |
| `agent.env` | `BUZZ_PRIVATE_KEY`, `BUZZ_RELAY_URL`, `BUZZ_ACP_AGENT_OWNER`, `BUZZ_ACP_AGENT_COMMAND`, plus the agent backend's own credential |
| `valkey.pass`, `garage.env` | Valkey password; `GARAGE_RPC_SECRET` |
| `credentials.json` | Cloudflare tunnel credentials |

## First-run bootstrap

1. **Garage layout.** A fresh node has no layout and will refuse S3 requests until one is
   applied:
   ```bash
   garage status                                   # note the node id
   garage layout assign -z dc1 -c 10G <node-id>
   garage layout apply --version 1
   garage bucket create <bucket>
   garage key create buzz                          # put the key/secret in relay.env
   garage bucket allow --read --write <bucket> --key buzz
   ```
2. **Relay membership.** The relay is closed by default
   (`BUZZ_REQUIRE_RELAY_MEMBERSHIP=true`): a pubkey that is not a member can neither read
   nor write. Add yourself and any agent:
   ```bash
   docker exec buzz-relay buzz-admin generate-key      # mint an agent identity
   docker exec buzz-relay buzz-admin add-member --pubkey <64-hex>
   ```
3. **Set up the agent** - see the next section; it is the fiddly part.

## Setting up the agent

The agent is a Buzz member like any human: its own keypair, its own relay membership, and
it answers when mentioned. `buzz-acp` is the harness - it subscribes to relay events and
drives an **ACP-speaking backend** (Claude Code here; Goose and Codex work the same way).
Nothing about it depends on the desktop app.

This module passes **no arguments** to `buzz-acp`, so every setting below is an environment
variable in `agent.env`. `buzz-acp --help` is the authoritative list.

### 1. Mint an identity for it

```bash
docker exec buzz-relay buzz-admin generate-key
# Public key:  <64-hex>     -> becomes a relay member
# Secret key:  <64-hex>     -> becomes BUZZ_PRIVATE_KEY. Not recoverable; save it now.
docker exec buzz-relay buzz-admin add-member --pubkey <agent-64-hex>
```

Give every agent its own keypair. Two processes sharing one key both answer every mention.

### 2. Get a credential for the backend

For Claude Code, a subscription token rather than an API key:

```bash
claude setup-token      # long-lived token, printed once
```

### 3. Write `agent.env` (mode 0600)

```ini
BUZZ_PRIVATE_KEY=<agent secret key from step 1>
BUZZ_RELAY_URL=wss://buzz.example.com
BUZZ_ACP_AGENT_COMMAND=claude-agent-acp
BUZZ_ACP_AGENT_OWNER=<your own 64-hex pubkey>
BUZZ_ACP_RESPOND_TO=owner-only
BUZZ_ACP_MODEL=opus
CLAUDE_CODE_OAUTH_TOKEN=<token from step 2>
```

- `BUZZ_ACP_AGENT_OWNER` is **required** in the default `owner-only` mode. Without it the
  harness logs `respond-to=owner-only but no owner is set` and silently drops everything.
- Do not set `ANTHROPIC_API_KEY`: it outranks `CLAUDE_CODE_OAUTH_TOKEN` and silently moves
  you from subscription to per-token API billing.
- `BUZZ_ACP_AGENT_ARGS` defaults to `acp`, which is Goose's invocation. `claude-agent-acp`
  tolerates the stray argument, but set `BUZZ_ACP_AGENT_ARGS=""` if you prefer it exact.

Then `nixos-rebuild switch` and confirm it came up:

```bash
journalctl -u buzz-acp -f
# connected to relay ...
# agent owner: <your pubkey>
# discovered N channel(s)
```

### 4. Give it a channel

`discovered 0 channel(s)` here is expected, not a fault: the harness only subscribes to
channels the agent belongs to, and there is no API to add an agent to an existing one.
Have the agent create its own - the creator is a member automatically:

```bash
# runs as the agent because it reads the same env
sudo -u buzz env $(cat /etc/buzz/agent.env | xargs) \
  buzz channels create --name agents --type stream --visibility open
systemctl restart buzz-acp     # re-runs discovery
```

### 5. Give it a profile

With no `kind:0` profile the agent has no display name, so the client's member search
cannot find it and it cannot be @mentioned:

```bash
sudo -u buzz env $(cat /etc/buzz/agent.env | xargs) \
  buzz users set-profile --name Nova --about "Headless agent (always on)"
```

### 6. Talk to it

Open that channel in the client, **join** it, and @mention the agent. The harness renders
the mention (plus recent thread context) into a prompt, runs the backend, and posts the
reply in-thread. It shows typing indicators and online presence while it works.

### Permissions and blast radius

`BUZZ_ACP_PERMISSION_MODE` defaults to **`bypass-permissions`** - the backend's per-tool-call
approval flow is skipped entirely, because there is no human at a terminal to approve it.
So anyone the author gate admits can cause tool execution as the agent user. Two controls
matter, and this module sets both:

- **The author gate** (`BUZZ_ACP_RESPOND_TO`) decides who is heard at all. Keep it
  `owner-only`, or `allowlist` with an explicit
  `BUZZ_ACP_RESPOND_TO_ALLOWLIST=<hex>,<hex>`. `anyone` on a reachable relay means any
  member can drive your agent. `BUZZ_ACP_ALLOWED_RESPOND_TO` is a separate belt-and-braces
  guard: list the modes that are permitted and the harness refuses to start outside them.
- **The systemd sandbox** decides what execution can reach. The unit runs as an
  unprivileged user with no capabilities, `ProtectHome=tmpfs`, and the container sockets
  made inaccessible - a Docker socket would be a one-line root escape.

Tighten with `accept-edits` (edits auto-approved, other tools still asked - only useful with
an interactive-capable backend), `plan` (no tool execution), or `dont-ask` (refuse anything
needing approval).

### Tuning

| Variable | Default | What it does |
|---|---|---|
| `BUZZ_ACP_MODEL` | backend default | `opus`, `sonnet`, `haiku`. Discover with `buzz-acp models` |
| `BUZZ_ACP_SUBSCRIBE` | `mentions` | `all` reacts to every message; `config` uses `buzz-acp.toml` |
| `BUZZ_ACP_CHANNELS` | all joined | Restrict to specific channels |
| `BUZZ_ACP_SYSTEM_PROMPT{,_FILE}` | - | Persona, layered before team instructions and memory |
| `BUZZ_ACP_TEAM_INSTRUCTIONS` | - | Team-owned instructions applied after the persona |
| `BUZZ_ACP_MULTIPLE_EVENT_HANDLING` | `steer` | Mid-turn mentions are woven into the running task rather than queued; also `queue`, `interrupt`, `owner-interrupt` |
| `BUZZ_ACP_CONTEXT_MESSAGE_LIMIT` | `12` | Prior messages included for thread replies and DMs |
| `BUZZ_ACP_MAX_TURN_DURATION` | `7200` | Hard wall-clock cap per turn |
| `BUZZ_ACP_IDLE_TIMEOUT` | unset | Kill a turn after this many seconds of no output |
| `BUZZ_ACP_AGENTS` | `1` | Parallel backend subprocesses |
| `BUZZ_ACP_MEMORY` | on | NIP-AE core memory injected into prompts; `BUZZ_ACP_NO_MEMORY=true` to opt out |
| `BUZZ_ACP_NO_PRESENCE` / `_NO_TYPING` | off | Suppress presence and typing indicators |

### Troubleshooting

| Symptom | Cause |
|---|---|
| `all events will be dropped` | `BUZZ_ACP_AGENT_OWNER` unset in `owner-only` mode |
| `discovered 0 channel(s)` | agent is in no channel - step 4 (writing `channel_members` does not work) |
| Not offered in @-autocomplete | no `kind:0` profile - step 5 |
| `failed to spawn agent: No such file or directory` | `BUZZ_ACP_AGENT_COMMAND` not on the unit's `path` |
| Replies "authentication failed" | backend credential expired; re-run `claude setup-token` |
| No "agent" badge | expected for self-hosted agents; see gotchas |
| Answers twice | two processes sharing one `BUZZ_PRIVATE_KEY` |

## Auth model

The tunnel (or any proxy you place in front) provides **transport only**. Cloudflare Access
in particular cannot authenticate this workload: the Buzz client opens a bare
`new WebSocket(url)` and cannot attach `CF-Access-Client-*` headers, so Access would reject
the socket.

Identity is Buzz's own and is cryptographic: NIP-42 proves possession of a private key, and
relay membership is an explicit allowlist. It behaves like SSH with `authorized_keys` - the
endpoint may be public, but it is useless without a registered key.

## Operating notes

Every workaround this module carries - and what has to happen upstream before it can be
deleted - is in **[docs/upstream-watch.md](docs/upstream-watch.md)**, along with the
deployment traps that cost the most time to diagnose. Read it before changing the object
store, the domain, or the agent's identity events.

## Updating the pins

The relay runs from the upstream image while the agent-side crates are built from source;
[docs/upstream-watch.md](docs/upstream-watch.md) explains why, and what would let both be
built the same way.

Bump `rev`/`hash` in `pkgs/buzz-agent-tools.nix`
(`nix flake prefetch --json github:block/buzz/<rev> | jq -r .hash`), copy that revision's
`Cargo.lock` into `pkgs/`, and re-pin `relay.image` to the matching digest.

## Security notes

The agent runs as an unprivileged user under systemd hardening (`NoNewPrivileges`,
`ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, writes confined to its state
directory). It still runs its backend with permission prompts disabled - see
[Permissions and blast radius](#permissions-and-blast-radius) - so treat it as capable of
running any tool it is given, and grant repository or production credentials deliberately
rather than by default.

## Status

Early. It works, but it is a small amount of glue around a young upstream project; expect
to read the code before relying on it.

## Licence

[Apache-2.0](LICENSE), matching upstream [block/buzz](https://github.com/block/buzz).
