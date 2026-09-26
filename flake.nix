{
  description = "buzzer - self-hosted Buzz workspace (relay, storage, headless agent) as a NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, disko }:
  let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in
  {
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

    # `pkgs.buzz-agent-tools` for consumers who compose their own package set; the
    # modules default to the same derivation.
    overlays.default = final: _prev: {
      buzz-agent-tools = final.callPackage ./pkgs/buzz-agent-tools.nix { };
    };

    packages = forAll (pkgs: {
      buzz-agent-tools = pkgs.callPackage ./pkgs/buzz-agent-tools.nix { };
      default = pkgs.callPackage ./pkgs/buzz-agent-tools.nix { };
    });

    # NixOS VM tests. Run with: nix flake check  (or `nix build .#checks.x86_64-linux.<name>`)
    # These are regression tests for failures this module has actually had, not smoke tests.
    checks = forAll (pkgs: {
      workspace = import ./tests/workspace.nix { inherit pkgs self; };
      agent-only = import ./tests/agent-only.nix { inherit pkgs self; };
    });
  };
}
