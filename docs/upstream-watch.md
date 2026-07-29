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
| W2 | Agent must create its own channel; it cannot be added to an existing one | not filed | Relay or CLI gains a membership grant for an existing pubkey |
| W3 | `garage.region` pinned to `us-east-1` | not filed | Relay exposes an S3 region setting |
| W4 | `BUZZ_GIT_CONFORMANCE_PROBE=false`; Buzz git hosting unused | not filed (also Garage) | Garage ships conditional writes, or the probe becomes granular |
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

**Clear when** a membership grant exists (an owner-signed event, or a `buzz channels
add-member`-style verb). Then agents can join the channels people already use, and the
"agent creates its own channel" step disappears from setup.

### W3 - the relay's S3 region is not configurable

The relay signs S3 requests for `us-east-1` and exposes no region setting. Garage validates
the signature scope (MinIO does not), so if Garage advertises a different region every
request fails with `AuthorizationHeaderMalformed`. Hence `services.buzzer.garage.region`
defaults to `us-east-1` and should not be changed.

**Clear when** the relay gains a region option: the pin can go, and the option can default
to whatever the object store prefers.

### W4 - Garage cannot back the git object store

The relay's startup conformance probe requires atomic compare-and-swap (`If-Match`). On
Garage every racer wins, so the probe fails and the relay refuses to start. We set
`BUZZ_GIT_CONFORMANCE_PROBE=false`, which is safe here because Buzz's git hosting is unused
(upstream still lists it as unbuilt). Media and attachments are unaffected - they need no
conditional writes.

**Clear when** either side moves: Garage implementing conditional writes, or the probe
becoming per-feature rather than all-or-nothing. Then git hosting becomes available without
swapping object stores. Worth re-checking on **both** projects, not just Buzz.

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

Not blocking anything, but each would let this module get simpler. W2 and W3 above are the
strongest candidates; also:

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
- **Valkey rather than Redis**: BSD-licensed fork versus a source-available Redis. It ships
  `redis-server` compatibility symlinks, so the NixOS redis module drives it unchanged and
  `REDIS_URL` needs no adjustment.
- **Garage rather than MinIO**: nixpkgs marks its MinIO package insecure, and Garage is a
  lighter single-node S3.
