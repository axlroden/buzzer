# Upstream watch

Every workaround this module carries, why it exists, and **what has to happen upstream
before it can be deleted**.

Two audiences:

- **Humans**, when something behaves oddly and you want to know whether it is a bug, a
  deliberate choice, or something we are waiting on.
- **The daily tracker**, which re-checks each *Watch* reference below against
  [`block/buzz`](https://github.com/block/buzz) and opens a PR when a *Clear when* condition
  is met.

Buzz moves fast. An entry going stale is the expected outcome, not a surprise - the point of
this file is that nobody has to rediscover *why* a line of config is there.

## Waiting on upstream

| ID | Workaround | Watch | Clear when |
|---|---|---|---|
| W1 | Agent publishes `kind:0` only, so it is mentionable but unbadged | [#2987](https://github.com/block/buzz/issues/2987), [#3277](https://github.com/block/buzz/issues/3277) | `shouldHideAgentFromMentions` reaches its invocability branch |
| W2 | Agent must create its own channel; it cannot be added to an existing one | not filed (see `reconcile-channels`) | Relay or CLI gains a membership grant for an existing pubkey |
| W5 | Relay runs from the upstream container image, not built from source | not filed | Upstream publishes the frontend assets, or a source build produces the web surface |
| W6 | Postgres needs `enableTCPIP` + a loopback `trust` rule | gated on W5 | The relay no longer runs in a container |

### W1 - badged or mentionable, not both

The client's "agent" badge comes from a `kind:30177` registration signed by the *owner*
(its `d` tag is the agent's pubkey), which is how desktop-managed agents get one. The
declaration for an *external* agent is `kind:10100` - but publishing it makes the agent
**un-mentionable**, because the invocability branch of `shouldHideAgentFromMentions` is
unreachable ([#2987](https://github.com/block/buzz/issues/2987), open).

So a headless agent publishes `kind:0` only. It appears as an ordinary member: unbadged,
but mentionable and fully functional. That is what this module assumes.

Two things that look like solutions and are not:

- `buzz agents draft-create` does not register an existing identity - it proposes a *new*
  desktop-managed agent.
- Desktop-managed agents are only mentionable from the machine running them
  ([#3277](https://github.com/block/buzz/issues/3277), open), which is the reason to run one
  server-side in the first place.

**Clear when** #2987 lands: publish `kind:10100` alongside `kind:0` and the agent should be
badged *and* mentionable. Verify in a client that @-autocomplete still offers it - that
regression is exactly what the issue is about.

### W2 - no way to add an agent to an existing channel

The relay serves channel membership from *events* (`kind:39002`), not from the
`channel_members` table, so writing that table directly has no effect - the harness keeps
reporting `discovered 0 channel(s)`. There is no API, CLI verb, or client affordance to
grant an existing pubkey membership of an existing channel.

The workaround is to have the agent create its own channel, since the creator is a member
automatically:

```bash
buzz channels create --name <name> --type stream --visibility open
```

The nearest thing that exists is `buzz-admin reconcile-channels`, which emits
`kind:39000/39002` for channels **missing them entirely** - it backfills discovery events
for channels created by direct SQL, and is idempotent. That is not a membership grant: a
channel that already has its events is not "missing" them, so running it after inserting a
`channel_members` row changes nothing. Do not mistake it for a fix.

It is worth watching precisely because it is close. If those `39002` events are generated
from `channel_members`, then a force / per-channel re-emit would make the table-write
approach work and clear this row. That hypothesis is **untested here** - confirming it means
mutating a live workspace, so check upstream's implementation rather than experimenting on a
running deployment.

**Clear when** a membership grant exists (an owner-signed event, a `buzz channels
add-member`-style verb, or `reconcile-channels` gaining a force mode that re-emits `39002`
from the table). Then agents can join the channels people already use, and the "agent
creates its own channel" step disappears from setup.

### W3 / W4 - resolved 2026-07-29 by moving off Garage

Both rows were Garage limitations, and both went away when the object store changed to
SeaweedFS. Kept here because the reasoning is the useful part.

**W4 was the important one: it blocked the client's Projects feature.** Buzz's git object
store requires atomic compare-and-swap (`If-Match`). Garage cannot provide it - not as a
missing feature but by design, since it has no consensus algorithm, and its own
documentation says if-none-match cannot be used for mutual exclusion between concurrent
writers. Verified here: with `BUZZ_GIT_CONFORMANCE_PROBE=true` the relay refused to start
on Garage 1.3.1. Waiting for upstream Garage would have been waiting forever.

On SeaweedFS 4.40 the same probe passes:

```
running git object-store conformance probe (A3 gate)   race_width=32 race_rounds=3
git object-store backend admitted: A3 conformance probe passed   transport_drops=0
```

So the probe now runs enabled, and relay-hosted git works. SeaweedFS was chosen over MinIO
(licence trajectory; nixpkgs marks its package insecure) and Ceph RGW (correct, but a
distributed storage system is the wrong weight for a single host). Its one known conditional
-write bug affects versioned + object-locked buckets only, which this deployment does not
use.

**W3** was that the relay signs S3 requests for `us-east-1` and exposes no region setting,
while Garage validated the signature scope. SeaweedFS does not, so the pin is unnecessary
and the `region` option is gone. If the object store is ever changed again, re-check this
first - it fails as `AuthorizationHeaderMalformed`, which does not obviously point at region.

### W5 / W6 - the relay is an image, the agent is built

Upstream publishes a container image for the **relay** only, and the relay serves bundled
web/admin assets produced by the frontend build - compiling just its Rust binary would leave
it without a web surface. The agent-side crates (`buzz-acp`, `buzz-cli`) have no published
artifacts at all, so this flake builds them from a pinned revision with a vendored
`Cargo.lock`.

The container is also why Postgres needs `enableTCPIP` and a loopback `trust` rule (W6): it
shares the host's network namespace but **not** its mounts, so it cannot reach the unix
socket.

**Clear when** a source build can produce the full web surface - that removes Docker from
the dependency set, and W6 with it.

Until then the pins are bumped by hand - recipe in the README under *Updating the pins*.

## Worth filing upstream

Not blocking anything, but each would let this module get simpler. W2 above is the
strongest candidate; also:

- **Community rename / rehost.** Communities are keyed to the hostname, so changing
  `domain` after first run makes the relay create a second, empty community instead of
  moving the existing one. The fix today is repointing the `communities.host` row by hand.
- **Agent profile bootstrap.** An agent with no `kind:0` profile is invisible to the
  client's member search, which reads as "the agent is broken" rather than "the agent has no
  name". Setting a profile could be part of registering an agent identity.

## Deployment notes

Not upstream's problem, and they will not clear - but they cost real time to diagnose.

- **Match the NIC by `Name`, not `Type`.** `matchConfig.Type = "ether"` also matches
  container veth interfaces, so networkd hands them the host's address and a duplicate
  default route, and container egress dies.
- **`nixos-rebuild ... | tail` hides failures.** The pipeline returns `tail`'s exit status,
  so a failed build looks successful. Redirect to a file and check `$?`.
- **Restore dumps as the database owner, not as `postgres`.** Objects restored by a
  superuser stay owned by it, and the relay then fails with
  `permission denied for table _sqlx_migrations`.
- **SeaweedFS's volume server defaults to port 8080, which the relay also binds.** Left at
  the default the volume server never starts and the S3 gateway serves nothing, with no
  obvious error. This module moves it to 8081.
- **`weed` cannot read a root-owned 0600 secrets file.** It runs unprivileged, so the S3
  identities file is passed via systemd `LoadCredential` rather than by loosening the file's
  permissions.
- **Redis state is disposable.** Everything the relay keeps in Redis is TTL'd - NIP-98 auth
  nonces, presence, rate-limit counters - so the store can be flushed or rebuilt without
  data loss. That also means the implementation can be swapped (Redis, Valkey, any
  wire-compatible fork) with no migration: stop, clear any `dump.rdb` the previous
  implementation wrote, start. An RDB written by one is not always readable by the other,
  and that is the only thing that bites.
- **SeaweedFS rather than Garage or MinIO**: it is the lightweight option that implements
  S3 conditional writes, which Buzz's git object store requires (see W3/W4). Apache-2.0,
  so no licence trajectory to worry about.
