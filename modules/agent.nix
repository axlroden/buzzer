# Standalone headless Buzz agent.
#
# This module runs the ACP harness on its own and does NOT require a relay on the same host:
# point `relayUrl` (or BUZZ_RELAY_URL in the environment file) at any Buzz relay you are a
# member of. Use `services.buzzer` instead if you want a whole workspace; that module enables
# this one for you.
#
# Buzz's desktop app runs agents as child processes, so they stop when the machine sleeps.
# Running the same harness as a system service makes the agent a permanent workspace member.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.buzz-agent;
  buzz-agent-tools = pkgs.callPackage ../pkgs/buzz-agent-tools.nix { };
in
{
  options.services.buzz-agent = {
    enable = lib.mkEnableOption "a headless Buzz agent (buzz-acp driving an ACP-speaking coding agent)";

    environmentFile = lib.mkOption {
      type = lib.types.path;
      example = "/etc/buzz/agent.env";
      description = ''
        Agent environment, kept out of the Nix store because it holds the agent's identity
        and its backend credential. Expected keys:

          BUZZ_PRIVATE_KEY        the agent's own Nostr secret (its identity, not yours)
          BUZZ_RELAY_URL          relay to connect to, unless set via `relayUrl`
          BUZZ_ACP_AGENT_COMMAND  the ACP backend, e.g. claude-agent-acp
          BUZZ_ACP_AGENT_OWNER    your pubkey; REQUIRED in the default owner-only mode
          plus whatever credential the backend needs (for Claude Code,
          CLAUDE_CODE_OAUTH_TOKEN - and never ANTHROPIC_API_KEY, which silently
          switches to per-token API billing)
      '';
    };

    relayUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "wss://buzz.example.com";
      description = ''
        Relay to connect to. Set here for a relay you do not host; leave null to take
        BUZZ_RELAY_URL from the environment file instead.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "buzz";
      description = "Unprivileged user the agent runs as.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/buzz-agent";
      description = "Agent home and state directory - the only path it may write to.";
    };

    backendPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ pkgs.claude-agent-acp pkgs.claude-code pkgs.nodejs_22 ];
      defaultText = lib.literalExpression "[ pkgs.claude-agent-acp pkgs.claude-code pkgs.nodejs_22 ]";
      description = ''
        The ACP backend and its runtime, placed on the unit's PATH. Override for a different
        backend, e.g. `[ pkgs.goose-cli ]` or a Codex adapter.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.ripgrep pkgs.jq ]";
      description = "Extra tools the agent may use, added to the unit's PATH.";
    };

    after = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "Extra units to order after - set by services.buzzer when co-hosted.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = cfg.stateDir;
      createHome = true;
    };
    users.groups.${cfg.user} = { };

    systemd.services.buzz-acp = {
      description = "Buzz ACP harness (headless agent)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ] ++ cfg.after;
      wants = [ "network-online.target" ];
      # bashInteractive and the buzz CLI are NOT optional: the harness's base prompt tells the
      # agent to reply by shelling out to `buzz messages send`, so without a shell it reacts,
      # runs a full turn, and posts nothing.
      path = [ buzz-agent-tools pkgs.bashInteractive pkgs.git ]
        ++ cfg.backendPackages
        ++ cfg.extraPackages;
      serviceConfig = {
        ExecStart = "${buzz-agent-tools}/bin/buzz-acp";
        EnvironmentFile = cfg.environmentFile;
        User = cfg.user;
        Group = cfg.user;
        Restart = "always";
        RestartSec = 15;
        StateDirectory = baseNameOf cfg.stateDir;
        WorkingDirectory = cfg.stateDir;
        # SHELL must be set explicitly. Claude Code refuses to run its Bash tool without it
        # ("No suitable shell found"), and systemd units inherit no login environment, so
        # /bin/sh existing on the host is not enough.
        Environment = [
          "HOME=${cfg.stateDir}"
          "SHELL=${pkgs.bashInteractive}/bin/bash"
        ] ++ lib.optional (cfg.relayUrl != null) "BUZZ_RELAY_URL=${cfg.relayUrl}";
        # Hardening. The agent executes tool calls on behalf of chat messages, and its
        # permission prompts are disabled by default, so it is treated as semi-untrusted:
        # no capabilities, no container sockets (a trivial root escape), no device access.
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        SystemCallArchitectures = "native";
        InaccessiblePaths = [ "-/run/docker.sock" "-/run/podman/podman.sock" ];
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        ReadWritePaths = [ cfg.stateDir ];
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

    # claude-code and the ACP adapter are unfree.
    nixpkgs.config.allowUnfreePredicate = lib.mkDefault (pkg:
      builtins.elem (lib.getName pkg) [ "claude-code" "claude-agent-acp" ]);
  };
}
