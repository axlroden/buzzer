# Workspace test: the data services come up correctly and the object store provides the
# one property Buzz's git hosting depends on.
#
# The relay container is not started - a sandboxed test cannot pull an image - so this
# covers everything this flake is actually responsible for.
{ pkgs, self }:

let
  s3Config = pkgs.writeText "s3.json" (builtins.toJSON {
    identities = [{
      name = "buzz";
      credentials = [{ accessKey = "testkey"; secretKey = "testsecret"; }];
      actions = [ "Admin" "Read" "Write" "List" "Tagging" ];
    }];
  });
  sigv4 = ''--aws-sigv4 "aws:amz:us-east-1:s3" -u "testkey:testsecret"'';
in
pkgs.testers.runNixOSTest {
  name = "buzzer-workspace";

  nodes.machine = { lib, ... }: {
    imports = [ self.nixosModules.buzzer ];

    virtualisation.memorySize = 3072;
    virtualisation.diskSize = 6144;

    services.buzzer = {
      enable = true;
      domain = "buzz.test";
      relay.environmentFile = pkgs.writeText "relay.env" "BUZZ_DOMAIN=buzz.test\n";
      redis.passwordFile = pkgs.writeText "redis.pass" "testpassword";
      seaweedfs.s3ConfigFile = s3Config;
      agent.enable = false;
      backup.enable = true;
      tunnel.enable = false;
    };

    # No image pulling in the sandbox.
    systemd.services.docker-buzz-relay.wantedBy = lib.mkForce [ ];

    environment.systemPackages = [ pkgs.curl pkgs.iproute2 ];
  };

  testScript = ''
    machine.start()

    with subtest("data services come up"):
        machine.wait_for_unit("postgresql.service")
        machine.wait_for_unit("redis-buzz.service")
        machine.wait_for_unit("seaweedfs.service")

    with subtest("seaweedfs binds all four ports on loopback"):
        machine.wait_for_open_port(3900)   # S3 API
        machine.wait_for_open_port(8081)   # volume
        machine.wait_for_open_port(8888)   # filer
        machine.wait_for_open_port(9333)   # master

    with subtest("seaweedfs does NOT squat on 8080 - the relay binds it"):
        # Regression: weed's volume server defaults to 8080. Left at the default it collides
        # with the relay, never starts, and the S3 gateway silently serves nothing.
        machine.fail("ss -lntH '( sport = :8080 )' | grep -q .")

    with subtest("nothing is exposed beyond loopback"):
        # Check the LOCAL address column only: ss prints "0.0.0.0:*" as the peer address on
        # every listening socket, so grepping the whole line always matches.
        for port in ["3900", "8081", "8888", "9333", "5432", "6379"]:
            addrs = machine.succeed(
                f"ss -lntH '( sport = :{port} )' | awk '{{print $4}}'"
            ).split()
            assert addrs, f"nothing listening on {port}"
            for a in addrs:
                assert a.startswith("127.0.0.1:") or a.startswith("[::1]:"), \
                    f"port {port} is bound beyond loopback: {a}"

    with subtest("postgres accepts the owning role over TCP"):
        # The relay is a container: it shares the network namespace but not the mounts, so
        # it needs TCP plus the loopback trust rule rather than the unix socket.
        machine.succeed("psql -h 127.0.0.1 -U buzz -d buzz -c 'select 1'")

    with subtest("redis requires its password"):
        # redis-cli exits 0 even when the server refuses, so assert on the reply, not $?.
        out = machine.succeed("redis-cli -p 6379 ping 2>&1 || true")
        assert "NOAUTH" in out, f"redis answered an unauthenticated PING: {out!r}"
        machine.succeed(
            "redis-cli -p 6379 -a testpassword --no-auth-warning ping | grep -q PONG"
        )

    with subtest("S3 works and enforces conditional writes"):
        # This is why SeaweedFS replaced Garage: Buzz's git object store needs atomic
        # compare-and-swap. Without it the relay refuses to start with its conformance
        # probe enabled, and Projects cannot work.
        machine.succeed(
            'curl -sf -X PUT ${sigv4} http://127.0.0.1:3900/testbucket'
        )
        machine.succeed(
            'curl -sf -X PUT ${sigv4} -H "If-None-Match: *" '
            '--data-binary "first" http://127.0.0.1:3900/testbucket/cas-probe'
        )
        code = machine.succeed(
            'curl -s -o /dev/null -w "%{http_code}" -X PUT ${sigv4} -H "If-None-Match: *" '
            '--data-binary "second" http://127.0.0.1:3900/testbucket/cas-probe'
        ).strip()
        assert code == "412", f"conditional write not enforced: expected 412, got {code}"

        body = machine.succeed(
            'curl -sf ${sigv4} http://127.0.0.1:3900/testbucket/cas-probe'
        ).strip()
        assert body == "first", f"losing racer overwrote the winner: got {body!r}"

    with subtest("nightly dump is scheduled"):
        machine.succeed("systemctl list-timers --all | grep -q postgresqlBackup")
  '';
}
