# coolcontrol 🧊

A lightweight fan control daemon for HP Victus laptops (and other HP models using EC registers `0x2C`/`0x2D`). Written in Zig 0.15.2 for maximum efficiency and safety.

## Features
- **Smart Auto Mode:** Fully customizable fan curve with linear interpolation.
- **Manual Control:** Set individual speeds for each fan (e.g., `set 40 60`).
- **Safety First:** Hardcoded and configurable critical temperature overrides (defaults to 85°C).
- **NixOS Ready:** Built-in Flake with a NixOS module for declarative configuration.
- **Zero Dependencies:** Compiles to a tiny, static binary.

---

## 🚀 Installation

### 1. Manual Build (Generic Linux)
**Requirements:** [Zig 0.15.2](https://ziglang.org/download/)

```bash
git clone https://github.com/youruser/coolcontrol
cd coolcontrol
zig build -Doptimize=ReleaseSafe
# Binary will be at zig-out/bin/coolcontrol
sudo cp zig-out/bin/coolcontrol /usr/local/bin/
```

### 2. Binary Release
Download the latest binary from the [Releases](https://github.com/youruser/coolcontrol/releases) page.
```bash
chmod +x coolcontrol
sudo mv coolcontrol /usr/local/bin/
```

### 3. NixOS (Flake)
Add `coolcontrol` to your `flake.nix`:

```nix
{
  inputs.coolcontrol.url = "github:youruser/coolcontrol";

  outputs = { self, nixpkgs, coolcontrol, ... }: {
    nixosConfigurations.your-hostname = nixpkgs.lib.nixosSystem {
      modules = [
        ./configuration.nix
        coolcontrol.nixosModules.default
      ];
    };
  };
}
```

Then configure the service in your `configuration.nix`:
```nix
services.coolcontrol = {
  enable = true;
  config = {
    critical_temp = 82.0;
    fan_curve = [
      { temp = 40.0; speed = 30; }
      { temp = 55.0; speed = 80; }
      { temp = 70.0; speed = 150; }
      { temp = 80.0; speed = 255; }
    ];
  };
};
```

---

## 🛠 Configuration

Create `/etc/coolcontrol.json`:
```json
{
    "ec_path": "/sys/kernel/debug/ec/ec0/io",
    "temp_path": "/sys/class/thermal/thermal_zone0/temp",
    "fan_addresses": [44, 45],
    "critical_temp": 85.0,
    "fan_curve": [
        {"temp": 40.0, "speed": 50},
        {"temp": 60.0, "speed": 150},
        {"temp": 80.0, "speed": 255}
    ]
}
```

## 🕹 Usage

```bash
# Start the daemon (usually handled by systemd)
sudo coolcontrol daemon --config /etc/coolcontrol.json

# Check current status
coolcontrol status

# Manual override
coolcontrol set 50      # Set all fans to 50/255
coolcontrol set 40 60   # Set Fan #0 to 40 and Fan #1 to 60

# Return to auto mode
coolcontrol auto
```

## ⚠️ Requirements
Make sure the `ec_sys` module is loaded with write support:
```bash
sudo modprobe ec_sys write_support=1
```
*The NixOS module and the provided `.service` file handle this automatically.*

---

## License
MIT
