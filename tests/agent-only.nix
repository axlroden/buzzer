# Agent-only test: the headless agent stands alone.
#
# The point of splitting `buzz-agent` out is that you can run an agent against a relay you do
# not host. This test fails if the agent ever quietly drags the server stack back in, and
# guards the two settings that silently break replies.
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "buzz-agent-only";

  nodes.machine = { ... }: {
    imports = [ self.nixosModules.buzz-agent ];

    services.buzz-agent = {
      enable = true;
      relayUrl = "wss://relay.example.com";
      # The backend is unfree and irrelevant here: this test asserts unit wiring, not that
      # Claude Code runs. Emptying it keeps the test buildable without an unfree predicate.
      backendPackages = [ ];
      environmentFile = pkgs.writeText "agent.env" ''
        BUZZ_PRIVATE_KEY=0000000000000000000000000000000000000000000000000000000000000001
        BUZZ_ACP_AGENT_COMMAND=claude-agent-acp
        BUZZ_ACP_AGENT_OWNER=0000000000000000000000000000000000000000000000000000000000000002
      '';
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("the agent unit exists and runs as an unprivileged user"):
        machine.succeed("systemctl cat buzz-acp")
        assert machine.succeed("systemctl show buzz-acp -p User --value").strip() == "buzz"
        machine.succeed("id buzz")

    with subtest("no server stack is pulled in"):
        # Enabling an agent must not require a relay, a database or an object store.
        machine.fail("systemctl is-enabled postgresql.service")
        machine.fail("systemctl is-enabled docker.service")
        machine.fail("systemctl is-enabled seaweedfs.service")
        machine.fail("systemctl is-enabled redis-buzz.service")

    with subtest("SHELL is set"):
        # Regression: the harness replies by shelling out to `buzz messages send`. Claude
        # Code refuses to run its Bash tool with SHELL unset, so the agent reacts, runs a
        # full turn, and posts nothing - looking alive the whole time it is broken.
        env = machine.succeed("systemctl show buzz-acp -p Environment --value")
        assert "SHELL=" in env, f"SHELL missing from unit environment: {env}"

    with subtest("a shell and the buzz CLI are on the unit PATH"):
        path = [w for w in machine.succeed(
            "systemctl show buzz-acp -p Environment --value"
        ).split() if w.startswith("PATH=")][0]
        for tool in ["bash", "buzz-agent-tools"]:
            assert tool in path, f"{tool} missing from unit PATH: {path}"

    with subtest("relayUrl reaches the process"):
        env = machine.succeed("systemctl show buzz-acp -p Environment --value")
        assert "BUZZ_RELAY_URL=wss://relay.example.com" in env, env

    with subtest("the sandbox is applied"):
        for prop, want in [
            ("NoNewPrivileges", "yes"),
            ("ProtectSystem", "strict"),
            ("ProtectHome", "tmpfs"),
            ("PrivateDevices", "yes"),
            ("RestrictNamespaces", "yes"),
        ]:
            got = machine.succeed(f"systemctl show buzz-acp -p {prop} --value").strip()
            assert got == want, f"{prop}: expected {want}, got {got}"
        # A container socket would be a trivial root escape for an agent whose permission
        # prompts are disabled by default.
        inacc = machine.succeed("systemctl show buzz-acp -p InaccessiblePaths --value")
        assert "docker.sock" in inacc, inacc
  '';
}
