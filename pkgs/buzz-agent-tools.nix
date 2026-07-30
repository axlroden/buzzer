# Builds the Buzz agent binaries from source: `buzz-acp` (the ACP harness that bridges
# relay events to an agent) and `buzz` (the CLI the agent uses to post, create channels
# and set its profile). Block publishes an image for the RELAY only - these crates are
# expected to be compiled, so we build them here rather than copying a hand-built image
# between hosts.
{ lib, rustPlatform, fetchFromGitHub, pkg-config, openssl, protobuf, cmake }:

rustPlatform.buildRustPackage rec {
  pname = "buzz-agent-tools";
  version = "0-unstable-2026-07-30";

  src = fetchFromGitHub {
    owner = "block";
    repo = "buzz";
    rev = "63496cc1d4c6f1b7c613801bdcc694169dcf391a";
    hash = "sha256-iC+as1J/GYRIYSUnZWUEqXHF86t0Ks6C+WSyGB7ucGA=";
  };

  # The workspace lock file pulls ~40 git dependencies; allowBuiltinFetchGit avoids
  # hand-maintaining an outputHashes entry for every one of them.
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
