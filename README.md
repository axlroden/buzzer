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

If the agent backend is Claude Code, supply `CLAUDE_CODE_OAUTH_TOKEN` (from
`claude setup-token`) and **do not set `ANTHROPIC_API_KEY`** - it takes precedence and
silently switches from subscription to per-token API billing.

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
3. **Give the agent a channel and a profile** (see gotchas).

## Auth model

The tunnel (or any proxy you place in front) provides **transport only**. Cloudflare Access
in particular cannot authenticate this workload: the Buzz client opens a bare
`new WebSocket(url)` and cannot attach `CF-Access-Client-*` headers, so Access would reject
the socket.

Identity is Buzz's own and is cryptographic: NIP-42 proves possession of a private key, and
relay membership is an explicit allowlist. It behaves like SSH with `authorized_keys` - the
endpoint may be public, but it is useless without a registered key.

## Gotchas

- **An agent cannot be added to an existing channel via any API.** Writing the
  `channel_members` table directly has no effect: the relay serves membership from *events*
  (kind 39002), so the harness keeps reporting `discovered 0 channel(s)`. Have the agent
  create its own channel instead - the creator is automatically a member:
  `buzz channels create --name <name> --type stream --visibility open`
- **An agent with no `kind:0` profile is invisible** to the client's member search and
  cannot be @mentioned: `buzz users set-profile --name <name> --about ...`
- **A self-hosted agent cannot be both badged and mentionable today.** The client's "agent"
  badge for desktop-managed agents comes from a `kind:30177` registration signed by the
  *owner* (its `d` tag is the agent's pubkey). For an *external* agent the declaration is
  `kind:10100` - but publishing it makes the agent **un-mentionable**, because the
  invocability branch of `shouldHideAgentFromMentions` is unreachable
  ([block/buzz#2987](https://github.com/block/buzz/issues/2987), open). So a headless agent
  should publish `kind:0` only: it then appears as an ordinary member - unbadged, but
  mentionable and fully functional, which is what this module assumes.
  Note `buzz agents draft-create` does not register an existing identity; it proposes a
  *new desktop-managed* agent. And desktop-managed agents are only mentionable from the
  machine running them ([#3277](https://github.com/block/buzz/issues/3277), open) - which is
  the reason to run one server-side in the first place.
- **Changing `domain` after first run forks the workspace.** Communities are keyed to the
  hostname, so a new one makes the relay create a second, empty community instead of moving
  the existing one. Repoint the `communities.host` row instead.
- **Static addressing: match the NIC by `Name`.** `matchConfig.Type = "ether"` also matches
  container veth interfaces, so networkd assigns them the host's address and a duplicate
  default route, and container egress dies.
- **`nixos-rebuild ... | tail` hides failures** - the pipeline returns `tail`'s exit status,
  so a failed build looks successful. Redirect to a file and check `$?`.
- **Garage cannot back Buzz's git object store.** The relay's startup conformance probe
  requires atomic compare-and-swap (`If-Match`); on Garage every racer wins, so the probe
  fails and the relay refuses to start. Set `BUZZ_GIT_CONFORMANCE_PROBE=false` if you do
  not use Buzz's git hosting (upstream still lists it as unbuilt), or use an object store
  with conditional-write semantics if you do. Media/attachments work fine either way.
- **Garage validates the S3 signature region; MinIO does not.** The relay signs for
  `us-east-1` and exposes no region setting, so Garage must advertise the same region or
  every request fails with `AuthorizationHeaderMalformed`.
- **Restore dumps as the database owner, not as `postgres`.** Objects restored by a
  superuser stay owned by it, and the relay then fails with
  `permission denied for table _sqlx_migrations`.
- **The relay container shares the host network namespace but not its mounts**, so it
  cannot reach Postgres over the unix socket - it needs `enableTCPIP` and a loopback host
  rule.
- Valkey is used rather than Redis (BSD vs source-available licence); it provides
  `redis-server` compatibility symlinks, so the NixOS redis module drives it unchanged.
  Garage is used rather than MinIO, whose nixpkgs package is marked insecure.

## Why the relay is an image but the agent is built

Upstream publishes a container image for the **relay** only, and the relay serves bundled
web/admin assets produced by the frontend build - compiling just its Rust binary would
leave it without a web surface. The agent-side crates (`buzz-acp`, `buzz-cli`) have no
published artifacts at all, so this flake builds them from a pinned source revision with a
vendored `Cargo.lock`.

To update: bump `rev`/`hash` in `pkgs/buzz-agent-tools.nix`
(`nix flake prefetch --json github:block/buzz/<rev> | jq -r .hash`), copy that revision's
`Cargo.lock` into `pkgs/`, and re-pin `relay.image` to the matching digest.

## Security notes

The agent runs as an unprivileged user under systemd hardening (`NoNewPrivileges`,
`ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, writes confined to its state
directory). It still runs its backend with permission prompts disabled, so treat it as
capable of running any tool it is given - grant repository or production credentials
deliberately, not by default.

## Status

Early. It works, but it is a small amount of glue around a young upstream project; expect
to read the code before relying on it.

## Licence

Apache-2.0, matching upstream Buzz.
