{
  description = "buzzer - self-hosted Buzz workspace (relay, storage, headless agent) as a NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, disko }: {
    # Two reusable pieces, deliberately separable:
    #   buzzer     - the whole workspace: relay, data services, ingress, backups
    #   buzz-agent - just the headless agent, usable against ANY relay you are a member of
    # `buzzer` imports `buzz-agent` for the co-hosted case, so importing both is harmless.
    nixosModules.buzzer = ./modules/buzzer.nix;
    nixosModules.buzz-agent = ./modules/agent.nix;
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

    # NixOS VM tests. Run with: nix flake check  (or `nix build .#checks.x86_64-linux.<name>`)
    # These are regression tests for failures this module has actually had, not smoke tests.
    checks.x86_64-linux = {
      workspace = import ./tests/workspace.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        inherit self;
      };
      agent-only = import ./tests/agent-only.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        inherit self;
      };
    };
  };
}
