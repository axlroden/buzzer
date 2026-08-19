# Builds the Buzz agent binaries from source: `buzz-acp` (the ACP harness that bridges
# relay events to an agent) and `buzz` (the CLI the agent uses to post, create channels
# and set its profile). Block publishes an image for the RELAY only - these crates are
# expected to be compiled, so we build them here rather than copying a hand-built image
# between hosts.
{ lib, rustPlatform, fetchFromGitHub, pkg-config, openssl, protobuf, cmake }:

rustPlatform.buildRustPackage rec {
  pname = "buzz-agent-tools";
  version = "0-unstable-2026-08-04";

  src = fetchFromGitHub {
    owner = "block";
    repo = "buzz";
    rev = "631b05c883f58e9533e9038b4669ebdfb1d9cf27";
    hash = "sha256-20FhGBXe7koihZB9ClbhBApVXuQH7sISL0uTWsi0WWI=";
  };

  # The workspace lock file pulls ~40 git dependencies; allowBuiltinFetchGit avoids
  # hand-maintaining an outputHashes entry for every one of them.
  # The vendored lock below is not merely a copy of upstream's - it carries a
  # security bump upstream has not made (h2 >= 0.4.16, RUSTSEC-2026-0258).
  # rustPlatform asserts the source tree's Cargo.lock is byte-identical to the
  # vendored one and fails the build otherwise, so the source's copy is replaced
  # with ours before that check runs. Without this the two differ by exactly the
  # bumped crate and the build stops at patchPhase.
  postPatch = "cp ${./Cargo.lock} Cargo.lock";

  cargoLock = {
    lockFile = ./Cargo.lock;   # vendored: keeps eval pure (no import-from-derivation)
    allowBuiltinFetchGit = true;
  };

  nativeBuildInputs = [ pkg-config protobuf cmake ];
  buildInputs = [ openssl ];

  # Only the two agent-side crates; the relay/desktop members are not needed here.
  cargoBuildFlags = [ "-p" "buzz-acp" "-p" "buzz-cli" "-p" "git-credential-nostr" ];
  doCheck = false;

  meta = with lib; {
    description = "Buzz ACP harness and CLI (agent-side binaries)";
    homepage = "https://github.com/block/buzz";
    license = licenses.asl20;
    platforms = platforms.linux;
  };
}
