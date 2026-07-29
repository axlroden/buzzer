# Example host. Copy this, fill in your own values, and keep it OUT of version control
# if it contains anything you would not publish.
{ ... }:
{
  imports = [ ../modules/buzzer.nix ];

  services.buzzer = {
    enable = true;
    domain = "buzz.example.com";

    # Pin by digest: docker inspect ghcr.io/block/buzz:main --format '{{index .RepoDigests 0}}'
    relay.image = "ghcr.io/block/buzz:main";
    relay.environmentFile = "/etc/buzz/relay.env";

    redis.passwordFile  = "/etc/buzz/redis.pass";
    garage.environmentFile = "/etc/buzz/garage.env";

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
