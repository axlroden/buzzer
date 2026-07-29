{
  description = "buzzer - self-hosted Buzz workspace (relay, storage, headless agent) as a NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, disko }: {
    # The reusable piece: import this into any NixOS host.
    nixosModules.buzzer = ./modules/buzzer.nix;
    nixosModules.default = self.nixosModules.buzzer;

    # A complete example host, also used to type-check the module in CI.
    nixosConfigurations.example = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        "${nixpkgs}/nixos/modules/profiles/qemu-guest.nix"
        disko.nixosModules.disko
        ./example/disko.nix
        ./example/configuration.nix
      ];
    };

    packages.x86_64-linux.buzz-agent-tools =
      nixpkgs.legacyPackages.x86_64-linux.callPackage ./pkgs/buzz-agent-tools.nix { };
  };
}
