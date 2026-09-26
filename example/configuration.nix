# Example host. Copy this, fill in your own values, and keep it OUT of version control
# if it contains anything you would not publish.
{ lib, ... }:
{
  # Claude Code and its ACP adapter are unfree; the agent module leaves this to consumers.
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "claude-code" "claude-agent-acp" ];

  imports = [ ../modules/buzzer.nix ];

  services.buzzer = {
    enable = true;
    domain = "buzz.example.com";

    # Pinned by digest. A tag is neither pinned nor tracking: oci-containers pulls it
    # once and never refreshes it, so `:main` would silently be whatever was current at
    # first boot. Bump it deliberately, alongside the crate pin (README, "Updating the
    # pins"): skopeo inspect --no-tags docker://ghcr.io/block/buzz:main | jq -r .Digest
    # (2026-09-26 build below)
    relay.image = "ghcr.io/block/buzz@sha256:ac4521f3e464c9dd09c92de52697182257da95e62b3c723805688594257fa74e";
    relay.environmentFile = "/etc/buzz/relay.env";

    database.passwordFile = "/etc/buzz/postgres.pass";
    redis.passwordFile  = "/etc/buzz/redis.pass";
    seaweedfs.s3ConfigFile = "/etc/buzz/seaweedfs-s3.json";

    agent.enable = true;
    agent.environmentFile = "/etc/buzz/agent.env";

    tunnel.enable = true;
    tunnel.name = "buzz-tunnel";
    tunnel.credentialsFile = "/etc/cloudflared/credentials.json";
  };

  # --- host specifics: replace all of these -------------------------------------
  boot.loader.grub.enable = true;
  networking.hostName = "buzz";
  networking.firewall.allowedTCPPorts = [ 22 ];   # tunnel is the only ingress
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... you@example" ];

  # Static addressing is optional; DHCP is fine. If you do set a static address, match
  # the NIC by Name - matchConfig.Type = "ether" also matches container veth interfaces
  # and will break container networking.
  # networking.useNetworkd = true;
  # systemd.network.networks."10-lan" = {
  #   matchConfig.Name = "enp1s0";
  #   address = [ "192.0.2.10/24" ];
  #   gateway = [ "192.0.2.1" ];
  # };

  system.stateVersion = "26.05";
}
