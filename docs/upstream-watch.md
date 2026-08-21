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

## Dependency pins and advisories

`pkgs/buzz-agent-tools.nix` pins one upstream commit of `block/buzz` and vendors that
commit's `Cargo.lock` next to it. **The lock is ours**, which is what makes a security
bump possible without moving the pin: a registry crate can be raised in the vendored
lock against the same source commit.

Position as of 2026-08-20, checked against the RustSec advisory DB rather than branch
names:

| Advisory | Crate | Needs | Status |
|---|---|---|---|
| RUSTSEC-2026-0258 | `h2` | >= 0.4.16 | cleared, lockfile-only bump on the existing pin |
| RUSTSEC-2026-0225..0230 | `nostr` | >= 0.44.7 | already clear - the pin ships 0.44.7 |
| RUSTSEC-2026-0231, 0232 | `nostr-relay-pool` | >= 0.44.3 | already clear - the pin ships 0.44.3 |

Eight of those nine were cleared by the bump to `631b05c`, which was made for an
unrelated reason (claude-agent-acp system prompt delivery) and happened to be a
descendant of the commit that fixed them. Nothing recorded that at the time, so the
backlog read nine deep when it was one. **If you are counting open advisories, read the
vendored lock, not the branch names.**

### Do NOT merge `fix/buzz-agent-tools-rustsec-nostr-bump` - superseded 2026-08-20

That branch pins `318fbf8` and its commit message says it clears
RUSTSEC-2026-0225..0232, so it reads like eight outstanding fixes. It is a **revert**.

`318fbf8` is an *ancestor* of the pin master already carries: the upstream history is
`318fbf8` -> 29 commits -> `631b05c` (master) -> 253 commits -> `cc8a8b0d`. Its crate
versions are identical to master's, so it fixes nothing that is not already fixed, and
merging it would move the pin backwards 29 commits and undo the acp system-prompt fix
that is currently live.

The general trap, because it will recur with any pin branch: **a stale branch is not
automatically behind on its purpose, but it is always behind on its base - and for a
branch whose entire content is a pin, being behind on the base makes it a revert wearing
a fix's name.** Check ancestry (`gh api repos/block/buzz/compare/A...B`) before merging
any bump that has been waiting.

The branch is kept, not deleted, so this reasoning stays attached to something.

## Waiting on upstream

| ID | Workaround | Watch | Clear when |
|---|---|---|---|
| W1 | Agent publishes `kind:0` only, so it is mentionable but unbadged | [#2987](https://github.com/block/buzz/issues/2987), [#3277](https://github.com/block/buzz/issues/3277), [#5484](https://github.com/block/buzz/pull/5484), [#5483](https://github.com/block/buzz/pull/5483) | For our `owner-only` config specifically: #5484 merges (adds owner comparison to `relayAgentIsSharedWithUser`) and #5483 merges (directory reads `kind:10100` in addition to `kind:30177`) |
| W5 | Relay runs from the upstream container image, not built from source | not filed | Upstream publishes the frontend assets, or a source build produces the web surface |
| W6 | Postgres needs `enableTCPIP` + a loopback `trust` rule | gated on W5 | The relay no longer runs in a container |
| W8 | Since desktop v0.5.12, the agent lost @-mentionability: the send-boundary gate requires `kind:10100` `channel_ids`/`respond_to` fields that nothing in this stack publishes | [#5681](https://github.com/block/buzz/pull/5681) (merged, the regression), [#5869](https://github.com/block/buzz/issues/5869), [#5878](https://github.com/block/buzz/pull/5878), [#5928](https://github.com/block/buzz/issues/5928) | #5878 or #5928 merges (either publishes our agent's `kind:10100` directory record) and we adopt it, or the gate ships a membership-based fallback |
| W9 | `buzz-acp`'s MCP shell config puts `BUZZ_PRIVATE_KEY`/`BUZZ_AUTH_TAG` in reach of model-controlled shell commands - this deployment gives the agent unit a shell (see README, "The agent replies by shelling out") | [#2883](https://github.com/block/buzz/issues/2883), [#5288](https://github.com/block/buzz/pull/5288) | #5288 merges (isolates the signing key behind a session capability, adds a typed `buzz_send_message` tool) - would also let us drop the shell workaround entirely |

### W1 - badged or mentionable, not both

The client's "agent" badge comes from a `kind:30177` registration signed by the *owner*
(its `d` tag is the agent's pubkey), which is how desktop-managed agents get one. The
declaration for an *external* agent is `kind:10100` - but publishing it makes the agent
**un-mentionable**, because the invocability branch of `shouldHideAgentFromMentions` is
unreachable ([#2987](https://github.com/block/buzz/issues/2987), open).

So a headless agent publishes `kind:0` only. It appears as an ordinary member: unbadged,
but mentionable and fully functional. That is what this module assumes.

**#2987 landing is not sufficient for our config.** A 2026-08-13 comment on that issue
traced `relayAgentIsSharedWithUser` (`desktop/src/features/agents/lib/agentAutocompleteEligibility.ts`)
and found it has exactly two paths that return true: `allowlist` with a matching pubkey, or
`anyone` with a shared channel. `respond_to: "owner-only"` - what `agent.env` sets here -
falls through to `false` unconditionally, for every viewer including the owner, because
neither `RelayAgentInfo` nor `RelayAgent` carries an owner field to compare against. Fixing
the invocability branch (#2987's stated Clear when) does not touch this: `owner-only` would
still never be offered in @-mention autocomplete.

[#5484](https://github.com/block/buzz/pull/5484) is the actual fix - it sources verified
NIP-OA ownership from `kind:0` profiles so `owner-only` has an owner to compare against.
[#5483](https://github.com/block/buzz/pull/5483) matters too: it reads the union of
`kind:10100` and `kind:30177` for the directory, which is the other half of "publishing
kind:10100 helps a headless seat" - without it, publishing 10100 populates a directory
Desktop's own mention picker still doesn't consult for external agents. Both are open, not
yet merged, as of this writing.

Two things that look like solutions and are not:

- `buzz agents draft-create` does not register an existing identity - it proposes a *new*
  desktop-managed agent.
- Desktop-managed agents are only mentionable from the machine running them
  ([#3277](https://github.com/block/buzz/issues/3277), open), which is the reason to run one
  server-side in the first place.

**Clear when** #2987 lands: publish `kind:10100` alongside `kind:0` and the agent should be
badged *and* mentionable. Verify in a client that @-autocomplete still offers it - that
regression is exactly what the issue is about.

**Owner-only has a second blocker specific to our shape.** [#4223](https://github.com/block/buzz/issues/4223)
(open) reports that on a *closed* relay (`require_relay_membership = true`, our config) the
NIP-OA owner attestation is silently dropped for an agent that is a *direct* relay member
(also our config) - `users.agent_owner_pubkey` never gets populated, only the inverse
(open relay, or membership granted via the owner) works. So even after #5484 merges,
`owner-only` would still not resolve an owner for us specifically. A 2026-08-15 comment on
that issue adds that the same code path 403s NIP-AM turn-metric events
(`kind:44200`, added by #4950, merged 2026-08-12) for every agent in this shape - something
to watch for before bumping `buzz-agent-tools` past that rev.

[#5581](https://github.com/block/buzz/pull/5581) is the fix in progress: it hoists owner
resolution out of the `require_relay_membership` conditional at both materialization sites
(HTTP submit and NIP-42 AUTH), so a direct member's self-presented NIP-OA tag is trusted the
same way a delegated one already is. A 2026-08-15 comment confirms a live repro against a
real relay clears both the turn-metric 403 and the rate-class throttling - with one condition
to check against our config once it merges: the reviewed version also requires the *owner*
key, not just the agent, to be a relay member on a closed relay (otherwise a direct member
could self-attest a throwaway owner). Our owner is already added as a member (bootstrap step
2 adds "yourself and any agent"), so this should not bite us, but worth confirming after
`buzz-agent-tools` picks up a rev built from this fix. Open, not merged, as of this writing.

### W2 - withdrawn 2026-07-30, it was never true

**This row was wrong.** It claimed there was "no API, CLI verb, or client affordance" to
grant an existing pubkey membership of an existing channel. There is, and there always was:

```bash
buzz channels add-member --channel <uuid> --pubkey <64-hex> [--role member|bot|admin|guest]
buzz channels join --channel <uuid>
```

Verified against the build predating this row, so the verb was present the whole time.

How the mistake happened, because the shape of it is worth avoiding: the symptom was real -
writing the `channel_members` table directly had no effect, since the relay serves
membership from `kind:39002` events. From that true observation the row concluded no
mechanism existed, without ever running `buzz channels --help`. A failed *workaround* was
generalised into a claim about the *whole interface*.

The lesson for anything added here: before recording that something is impossible, check the
tool's own help output. "I could not find a way" and "there is no way" are different claims,
and only the second belongs in this table.

The genuinely useful residue: `buzz-admin reconcile-channels` backfills `kind:39000/39002`
for channels *missing them entirely* (direct-SQL/seed cases) and is idempotent. It is not a
membership grant - use `add-member` for that.

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

### W7 - resolved 2026-07-30 by upstream binding support

The relay gates git reads on a **buzz-channel binding** carried by the `kind:30617`
announcement. Without it every fetch was denied:

```
WARN git read gate: missing/malformed buzz-channel binding (deny)  repo=constellation
```

The client surfaced that as *"Could not fetch repository … repository not found"*, which was
misleading - the repo name was registered and auth succeeded (the relay logged 200s, no
401s). The denial was the binding check, not a missing repo or a credential problem.

`buzz repos create` previously had no flag for it, so any announcement made from the CLI was
structurally unusable and there was no CLI path to repair or retract one either.

[block/buzz#3626](https://github.com/block/buzz/pull/3626) (merged) fixed this: `buzz repos
create` now takes an optional `--channel <uuid>` that emits the `buzz-channel` tag at
creation, and a new `buzz repos bind --id <repo> --channel <uuid>` rebinds an
already-announced repo (the remediation path for anything created before this landed,
including announcements this deployment made while the workaround was in force). Picked up
here via the `pkgs/buzz-agent-tools.nix` rev bump to
`63496cc1d4c6f1b7c613801bdcc694169dcf391a`.

Projects can now be provisioned with `buzz repos create --id <repo> --channel <uuid>`
instead of only from the desktop client. The two related facts below still hold:

- Announcing reserves the name in `git_repo_names` but does not create the repo; a repo
  comes into being on first push. There is no create/init endpoint - the only git routes are
  `info/refs`, `git-upload-pack` and `git-receive-pack`.
- Pushing **can** be scripted, contrary to an earlier note here: upstream ships a
  `git-credential-nostr` crate ("Git credential helper that produces NIP-98 auth headers for
  Buzz's git server"). It is simply not one of the binaries this flake used to build - now
  added to `cargoBuildFlags`. Recipe in the README under *Pushing to a Buzz-hosted repo*.
  The earlier claim came from checking the `buzz` CLI's subcommands and the shipped binaries,
  and not the upstream workspace's crate list.

### W8 - a fail-closed mention gate with no publisher for the fields it requires

[#5681](https://github.com/block/buzz/pull/5681) (merged 2026-08-13, shipped in desktop
v0.5.12 onward) changed the @-mention send-boundary gate: a non-managed agent is admitted
only when its `kind:10100` directory record's *content* carries `channel_ids` including the
current channel and `respond_to` of `anyone`/`allowlist`. Channel membership alone no longer
counts - the gate went fail-open to fail-closed.

The problem, per [#5869](https://github.com/block/buzz/issues/5869): no publisher of those
fields exists anywhere in the upstream repo. The only thing that emits `kind:10100` is
`buzz channels set-add-policy`, whose content is just `{"channel_add_policy": "<policy>"}` -
no `channel_ids`, no `respond_to`. Since `kind:10100` is replaceable, even that publish
clobbers any richer record. Net effect: any headless/relay-hosted agent, including ours, is
structurally un-mentionable on desktop v0.5.12+ regardless of the W1 badge tradeoff.

[#5878](https://github.com/block/buzz/pull/5878) (open) adds `buzz agents set-directory`, a
CLI publisher that read-merges the existing `kind:10100` record (preserving
`channel_add_policy`) and derives `channel_ids` from the agent's own `kind:39002`
memberships. Its author reports 24 production relay-hosted agents already republished with
it and confirmed admitted by the new gate. Not merged as of this writing, so not yet
something we can pin to.

[#5928](https://github.com/block/buzz/issues/5928) proposes a different shape of fix: rather
than a one-off CLI publish, have `buzz-acp` itself reconcile a complete `kind:10100` profile
at startup after channel discovery - preserving unknown fields, publishing real channel ids
and the effective response policy, and folding in the implicit owner for
`owner-only`/`allowlist` (Desktop evaluates the directory allowlist literally, so ours needs
the owner listed explicitly even though `buzz-acp` admits it implicitly at runtime). If this
lands instead of or alongside #5878, it removes the operational step of re-running the
publisher after every channel join. Filed 2026-08-15 with a reproduction against desktop
v0.5.14; no PR yet.

**Clear when** #5878 or #5928 merges and we adopt it to publish our agent's directory record,
or the gate ships a membership-based fallback.

### W9 - the agent's shell can read its own signing key

This deployment gives the `buzz-agent` systemd unit a shell because the ACP harness's base
prompt has the agent reply by shelling out to `buzz messages send` rather than taking the
reply from the backend's final text (see README, "The agent replies by shelling out").

[#2883](https://github.com/block/buzz/issues/2883) (open) reports that `buzz-acp` puts
`BUZZ_PRIVATE_KEY` in the MCP shell tool's environment, and `BUZZ_AUTH_TAG` goes with it. Any
command the agent runs - including ones the model, not an adversary, chooses to run - can
read the raw signing key. A 2026-08-15 comment on the issue is a real (not hypothetical)
repro: an agent asked a benign question ran `env | grep`, printed the key, and it was
rendered verbatim into the channel transcript, visible to every member. Provider API keys
are *not* exported into the same shell - only the Buzz signing material is.

[#5288](https://github.com/block/buzz/pull/5288) (open) is the fix in progress: keep the
signing key inside `buzz-acp`, give the shell no publishing capability, and add a typed
`buzz_send_message` MCP tool instead. If it lands as described, it would also let us retire
the shell/`bashInteractive` workaround from W9's cause entirely - the agent would no longer
need to shell out to reply.

**Clear when** #5288 (or an equivalent fix) merges. Until then, `BUZZ_PRIVATE_KEY` should be
treated as readable by anything the agent's model decides to run.

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

Not blocking anything, but each would let this module get simpler:

- **Community rename / rehost.** Communities are keyed to the hostname, so changing
  `domain` after first run makes the relay create a second, empty community instead of
  moving the existing one. The fix today is repointing the `communities.host` row by hand.
- **Agent profile bootstrap.** An agent with no `kind:0` profile is invisible to the
  client's member search, which reads as "the agent is broken" rather than "the agent has no
  name". Setting a profile could be part of registering an agent identity.

## Module layout

`buzz-agent` is a standalone module, not a sub-option of `buzzer`. The agent is the piece most
people want and the piece with the widest blast radius - it executes tool calls on behalf of
chat messages with permission prompts disabled - so it is deployable, and reasonable about,
on its own. `buzzer` imports it and forwards `environmentFile`/`user` for the co-hosted case;
anything finer is set directly on `services.buzz-agent`.

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
