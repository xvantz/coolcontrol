{
  description = "HP Victus Fan Control Daemon";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (system: {
        default = pkgsFor system.stdenv.mkDerivation {
          pname = "coolcontrol";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [ (pkgsFor system).zig.hook ];

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
        in
        {
          options.services.coolcontrol = {
            enable = mkEnableOption "coolcontrol fan control daemon";
            package = mkOption {
              type = types.package;
              default = self.packages.${pkgs.system}.default;
            };
            config = mkOption {
              type = types.attrs;
              default = {
                ec_path = "/sys/kernel/debug/ec/ec0/io";
                temp_path = "/sys/class/thermal/thermal_zone0/temp";
                fan_addresses = [ 44 45 ];
                critical_temp = 85.0;
                fan_curve = [
                  { temp = 40.0; speed = 50; }
                  { temp = 55.0; speed = 100; }
                  { temp = 70.0; speed = 180; }
                  { temp = 80.0; speed = 255; }
                ];
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
