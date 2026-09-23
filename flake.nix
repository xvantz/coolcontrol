{
  description = "HP Victus Fan Control Daemon";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # Zig 0.16.0 lives here (verified 2026-09-23: unstable default zig = zig_0_16).
    # nixos-25.11 only has up to 0.15.2, and our code uses 0.16 Io APIs.
    # flake.lock pins the exact rev, so the toolchain is reproducible.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
    }:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
      unstableFor = system: nixpkgs-unstable.legacyPackages.${system};
      # Pinned toolchain: zig 0.16.x from unstable. Fail loudly on major drift
      # instead of breaking with obscure compile errors after `nix flake update`.
      zigFor = system: let z = (unstableFor system).zig; in assert nixpkgs.lib.hasPrefix "0.16." z.version; z;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          zigPkg = zigFor system;
        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname = "coolcontrol";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [ zigPkg.hook ];

            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              zig build -Doptimize=ReleaseSafe --prefix $out
            '';
          };
        });

      nixosModules.default = { config, lib, pkgs, ... }:
        with lib;
        let
          cfg = config.services.coolcontrol;
          # Use hostPlatform for newer Nixpkgs compatibility
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          options.services.coolcontrol = {
            enable = mkEnableOption "coolcontrol fan control daemon";
            package = mkOption {
              type = types.package;
              default = self.packages.${system}.default;
            };
            config = mkOption {
              type = types.attrs;
              # NOTE: source of truth for the curve is
              # /dotfiles/modules/system/coolcontrol.nix on Victus.
              # Keep these defaults in sync with src/common.zig.
              default = {
                ec_path = "/sys/kernel/debug/ec/ec0/io";
                temp_path = "/sys/class/thermal/thermal_zone0/temp";
                fan_addresses = [ 44 45 ];
                critical_temp = 92.0;
                fan_curve = [
                  { temp = 45.0; speed = 50; }
                  { temp = 60.0; speed = 90; }
                  { temp = 75.0; speed = 160; }
                  { temp = 85.0; speed = 210; }
                  { temp = 92.0; speed = 254; }
                ];
                smoothing = {
                  ema_alpha = 0.3;
                  max_step_up = 8;
                  max_step_down = 4;
                  min_step = 2;
                  hysteresis_temp = 2.0;
                  hysteresis_delay_s = 5;
                  only_downward = true;
                };
              };
              description = "Configuration for coolcontrol. See coolcontrol.json for structure.";
            };
          };

          config = mkIf cfg.enable {
            environment.systemPackages = [ cfg.package ];

            environment.etc."coolcontrol.json".text = builtins.toJSON cfg.config;

            systemd.services.coolcontrol = {
              description = "HP Victus Fan Control Daemon";
              after = [ "network.target" ];
              wantedBy = [ "multi-user.target" ];

              serviceConfig = {
                ExecStartPre = "${pkgs.kmod}/bin/modprobe ec_sys write_support=1";
                ExecStart = "${cfg.package}/bin/coolcontrol daemon -c /etc/coolcontrol.json";
                Restart = "always";
                RestartSec = 5;
              };
            };
          };
        };
    };
}
