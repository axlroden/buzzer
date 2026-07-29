# NixOS module for a single-host, self-hosted Buzz workspace:
# relay + Postgres + Redis + SeaweedFS (S3) + optional headless agent and Cloudflare tunnel.
#
# Everything binds to loopback; the only intended ingress is the tunnel (or a reverse
# proxy you place in front yourself).
{ config, lib, pkgs, ... }:

let
  cfg = config.services.buzzer;
  buzz-agent-tools = pkgs.callPackage ../pkgs/buzz-agent-tools.nix { };
in
{
  options.services.buzzer = {
    enable = lib.mkEnableOption "a self-hosted Buzz workspace";

    domain = lib.mkOption {
      type = lib.types.str;
      example = "buzz.example.com";
      description = ''
        Public hostname clients connect to (they use wss://<domain>).

        Note: the relay keys each community to this hostname, so changing it after the
        fact makes the relay create a second, empty community rather than moving the
        existing one.
      '';
    };

    relay = {
      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/block/buzz:main";
        example = "ghcr.io/block/buzz@sha256:...";
        description = ''
          Upstream relay image. Pin by digest for reproducibility.

          Upstream publishes an image for the relay only, and it serves bundled web/admin
          assets from the frontend build, so compiling just the Rust binary would leave it
          without a web surface. The agent-side crates are built from source instead.
        '';
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3000;
        description = "Loopback port the relay listens on.";
      };
      environmentFile = lib.mkOption {
        type = lib.types.path;
        example = "/etc/buzz/relay.env";
        description = ''
          Relay environment, kept out of the Nix store. Expected keys include
          DATABASE_URL, REDIS_URL, BUZZ_S3_ENDPOINT/ACCESS_KEY/SECRET_KEY/BUCKET,
          BUZZ_RELAY_PRIVATE_KEY, RELAY_OWNER_PUBKEY, BUZZ_DOMAIN and BUZZ_CORS_ORIGINS.
        '';
      };
    };

    database.name = lib.mkOption {
      type = lib.types.str;
      default = "buzz";
      description = "Postgres database and owning role.";
    };

    redis.passwordFile = lib.mkOption {
      type = lib.types.path;
      example = "/etc/buzz/redis.pass";
      description = "File containing the Redis password.";
    };

    seaweedfs = {
      s3Port = lib.mkOption {
        type = lib.types.port;
        default = 3900;
        description = "Loopback port the S3 API listens on.";
      };
      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/seaweedfs";
        description = "Where volumes, filer metadata and S3 objects are stored.";
      };
      s3ConfigFile = lib.mkOption {
        type = lib.types.path;
        example = "/etc/buzz/seaweedfs-s3.json";
        description = ''
          SeaweedFS S3 identities file, kept out of the Nix store because it holds the
          access key and secret the relay authenticates with. Minimal shape:

          {"identities":[{"name":"buzz",
            "credentials":[{"accessKey":"...","secretKey":"..."}],
            "actions":["Admin","Read","Write","List","Tagging"]}]}
        '';
      };
    };

    agent = {
      enable = lib.mkEnableOption ''
        the headless agent (buzz-acp driving an ACP-speaking coding agent), so it keeps
        answering when no desktop client is running
      '';
      environmentFile = lib.mkOption {
        type = lib.types.path;
        example = "/etc/buzz/agent.env";
        description = ''
          Agent environment, kept out of the Nix store: BUZZ_PRIVATE_KEY (its own identity),
          BUZZ_RELAY_URL, BUZZ_ACP_AGENT_OWNER, BUZZ_ACP_AGENT_COMMAND and whatever
          credential the chosen agent backend needs.
        '';
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "buzz";
        description = "Unprivileged user the agent runs as.";
      };
    };

    backup = {
      enable = lib.mkEnableOption "a nightly pg_dump of the Buzz database";
      directory = lib.mkOption {
        type = lib.types.str;
        default = "/var/backup/buzz";
        description = "Where dumps are written.";
      };
      keepDays = lib.mkOption {
        type = lib.types.int;
        default = 14;
        description = "Dumps older than this are pruned.";
      };
    };

    tunnel = {
      enable = lib.mkEnableOption "a Cloudflare tunnel as the sole ingress";
      name = lib.mkOption {
        type = lib.types.str;
        example = "buzz-tunnel";
        description = "Named tunnel to run.";
      };
      credentialsFile = lib.mkOption {
        type = lib.types.path;
        example = "/etc/cloudflared/credentials.json";
        description = "Tunnel credentials, provisioned out of band.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # ------------------------------------------------------------------ data services
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_17;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [{ name = cfg.database.name; ensureDBOwnership = true; }];
      # The relay runs in a container: it shares the host network namespace but NOT the
      # mount namespace, so it cannot use the unix socket and needs TCP on loopback.
      enableTCPIP = true;
      authentication = lib.mkAfter ''
        # Loopback only, and the firewall exposes nothing but SSH, so trust here is
        # equivalent to the unix-socket peer trust it replaces.
        host ${cfg.database.name} ${cfg.database.name} 127.0.0.1/32 trust
      '';
      settings.listen_addresses = lib.mkForce "127.0.0.1";
    };

    # Stock Redis via the NixOS module. Everything the relay keeps here is ephemeral and
    # TTL'd - NIP-98 auth nonces, presence, rate-limit counters - so the store can be lost
    # or rebuilt without data loss, and swapping the implementation needs no migration.
    services.redis.servers.buzz = {
      enable = true;
      bind = "127.0.0.1";
      port = 6379;
      requirePassFile = cfg.redis.passwordFile;
    };

    # SeaweedFS rather than Garage or MinIO.
    #
    # Buzz's git object store needs atomic compare-and-swap (`If-Match`). Garage cannot
    # provide it: it has no consensus algorithm, so conditional writes are architecturally
    # out of reach rather than merely unimplemented, and the relay refuses to start with its
    # conformance probe enabled. SeaweedFS implements conditional writes on standard
    # (non-versioned) buckets and is Apache-2.0, avoiding MinIO's licence trajectory.
    #
    # `weed server` runs master, volume, filer and the S3 gateway in one process - the right
    # shape for a single host. Everything binds to loopback.
    users.users.seaweedfs = {
      isSystemUser = true;
      group = "seaweedfs";
      home = cfg.seaweedfs.dataDir;
      createHome = true;
    };
    users.groups.seaweedfs = { };

    systemd.services.seaweedfs = {
      description = "SeaweedFS S3 object storage";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.seaweedfs}/bin/weed server"
          "-dir=${cfg.seaweedfs.dataDir}"
          "-ip=127.0.0.1 -ip.bind=127.0.0.1"
          "-master.port=9333"
          # The volume server defaults to 8080, which the relay in this very module already
          # binds. Left alone, the volume server never comes up and the S3 gateway serves
          # nothing.
          "-volume.port=8081"
          "-filer -filer.port=8888"
          "-s3 -s3.port=${toString cfg.seaweedfs.s3Port}"
          # Read via systemd's credential mechanism so the file can stay root-owned 0600:
          # weed runs unprivileged and cannot open it directly.
          "-s3.config=%d/s3config"
        ];
        LoadCredential = [ "s3config:${cfg.seaweedfs.s3ConfigFile}" ];
        User = "seaweedfs";
        Group = "seaweedfs";
        Restart = "always";
        RestartSec = 5;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.seaweedfs.dataDir ];
        PrivateTmp = true;
        ProtectHome = true;
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };

    # ------------------------------------------------------------------ relay
    virtualisation.docker.enable = true;
    virtualisation.oci-containers.backend = "docker";
    virtualisation.oci-containers.containers.buzz-relay = {
      image = cfg.relay.image;
      autoStart = true;
      # Host networking: the relay reaches the data services on loopback and stays
      # unreachable from outside this host.
      extraOptions = [ "--network=host" ];
      environmentFiles = [ cfg.relay.environmentFile ];
    };
    systemd.services.docker-buzz-relay = {
      after = [ "postgresql.service" "redis-buzz.service" "seaweedfs.service" ];
      requires = [ "postgresql.service" ];
    };

    # ------------------------------------------------------------------ agent
    users.users.${cfg.agent.user} = lib.mkIf cfg.agent.enable {
      isSystemUser = true;
      group = cfg.agent.user;
      home = "/var/lib/buzz-agent";
      createHome = true;
    };
    users.groups.${cfg.agent.user} = lib.mkIf cfg.agent.enable { };

    systemd.services.buzz-acp = lib.mkIf cfg.agent.enable {
      description = "Buzz ACP harness (headless agent)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "docker-buzz-relay.service" ];
      wants = [ "network-online.target" ];
      # bashInteractive is NOT optional: the harness's base prompt tells the agent to reply
      # by shelling out to `buzz messages send`, so a missing shell means it can never
      # answer - it reacts, runs its turn, and posts nothing. `buzz` itself comes from
      # buzz-agent-tools below.
      path = [
        pkgs.claude-agent-acp
        pkgs.claude-code
        pkgs.bashInteractive
        buzz-agent-tools
        pkgs.git
        pkgs.nodejs_22
      ];
      serviceConfig = {
        ExecStart = "${buzz-agent-tools}/bin/buzz-acp";
        EnvironmentFile = cfg.agent.environmentFile;
        User = cfg.agent.user;
        Group = cfg.agent.user;
        Restart = "always";
        RestartSec = 15;
        StateDirectory = "buzz-agent";
        WorkingDirectory = "/var/lib/buzz-agent";
        # SHELL must be set explicitly. Claude Code refuses to run its Bash tool without it
        # ("No suitable shell found"), and systemd units inherit no login environment, so
        # /bin/sh existing on the host is not enough.
        Environment = [
          "HOME=/var/lib/buzz-agent"
          "SHELL=${pkgs.bashInteractive}/bin/bash"
        ];
        # Hardening. The agent executes tool calls on behalf of chat messages, so it is
        # treated as semi-untrusted: no capabilities, no container sockets (which would be
        # a trivial root escape), no device access, and only the sockets it needs.
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        SystemCallArchitectures = "native";
        InaccessiblePaths = [ "-/run/docker.sock" "-/run/podman/podman.sock" ];
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        ReadWritePaths = [ "/var/lib/buzz-agent" ];
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };

    # ------------------------------------------------------------------ backups
    # The relay's state (community, channels, members, identities) is all in Postgres;
    # object storage only holds media. A dump is therefore the thing worth keeping.
    services.postgresqlBackup = lib.mkIf cfg.backup.enable {
      enable = true;
      databases = [ cfg.database.name ];
      location = cfg.backup.directory;
      startAt = "*-*-* 03:15:00";
    };
    systemd.tmpfiles.rules = lib.mkIf cfg.backup.enable [
      "d ${cfg.backup.directory} 0700 postgres postgres - -"
      "e ${cfg.backup.directory} - - - ${toString cfg.backup.keepDays}d"
    ];

    # ------------------------------------------------------------------ ingress
    services.cloudflared = lib.mkIf cfg.tunnel.enable {
      enable = true;
      tunnels.${cfg.tunnel.name} = {
        credentialsFile = cfg.tunnel.credentialsFile;
        ingress."${cfg.domain}" = "http://127.0.0.1:${toString cfg.relay.port}";
        default = "http_status:404";
      };
    };

    environment.systemPackages = [ buzz-agent-tools pkgs.seaweedfs pkgs.postgresql_17 ];

    # claude-code and the ACP adapter are unfree.
    nixpkgs.config.allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) [ "claude-code" "claude-agent-acp" ];
  };
}
