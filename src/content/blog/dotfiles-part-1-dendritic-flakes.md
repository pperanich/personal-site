---
title: 'Dotfiles, Part 1: Why Dendritic Flakes Work for Managing 9 Machines'
description: 'How I use import-tree, flake-parts, and clan-core to manage NixOS, macOS, and WSL machines from a single flake — without maintaining a central import list.'
pubDate: 2026-03-03
tags: ['nix', 'dotfiles', 'infrastructure']
---

I manage nine machines from a single Nix flake: three macOS laptops, a NixOS desktop, a NixOS laptop, a NAS, a home router, a Raspberry Pi, and a WSL instance. They share a common set of modules but compose different subsets depending on their role. This post explains the architecture I've settled on and why it works.

I didn't invent the dendritic flake pattern — it comes from [dendrix](https://github.com/vic/dendrix) by Víctor Borja, which builds on [import-tree](https://github.com/vic/import-tree) and the broader [flake-parts](https://flake.parts/) ecosystem. But after adopting it and building on top of it for a while, I've found it scales better than anything else I've tried for a multi-machine, multi-platform setup. Here's how it fits together.

## The One-Liner Flake

My entire `flake.nix` output is a single line:

```nix
outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);
```

`import-tree` recursively discovers every `.nix` file under `modules/` and merges them into a single flake-parts module. There is no central import list. Adding a new module means dropping a file into the right directory — nothing else needs to change.

The `modules/` directory has around 48 files organized by function:

```
modules/
├── flake-parts/   # Flake plumbing (nixpkgs, clan, home-manager, dev shell, formatting)
├── system/        # Cross-platform base config + secrets
├── users/         # User creation + home-manager wiring
├── shell/         # Dev tools (neovim, rust, CLI tools)
├── desktop/       # Fonts, window management, GUI apps
├── services/      # Self-hosted services (Immich, Nextcloud, Vaultwarden, ...)
├── router/        # Custom NixOS router framework
└── work.nix       # Corporate environment overrides
```

Every file is automatically loaded and composed. No boilerplate, no manual registration.

## Self-Registering Modules

Each module declares where it belongs by exporting to a `flake.modules.<platform>.<name>` namespace. For example, here's a simplified version of the Rust toolchain module:

```nix
# modules/shell/rust.nix
_: {
  flake.modules.homeManager.rust = { pkgs, ... }: {
    # Nightly Rust with cross-compilation targets
  };
  flake.modules.nixos.rust = { pkgs, ... }: {
    # NixOS-specific Rust config
  };
  flake.modules.darwin.rust = _: {
    # Darwin-specific Rust config (if any)
  };
}
```

A single file declares its configuration for all relevant platforms at once. The module decides its own export path — no registry file needs updating. This is what makes the pattern "dendritic": modules are leaves on a tree that self-attach to the right branches.

The most important example is the unified base module (`modules/system/base.nix`), which exports to all three platforms:

```nix
{
  flake.modules = {
    nixos.base = { pkgs, ... }: { ... };
    darwin.base = { pkgs, ... }: { ... };
    homeManager.base = { lib, pkgs, config, ... }: { ... };
  };
}
```

Having NixOS, Darwin, and home-manager base configs in the same file makes it obvious when they drift out of sync. All three apply the same overlays from a single source, configure the same default packages, and set up the same foundational options.

## Named Module Composition

Machines compose modules by name. Here's my personal MacBook:

```nix
# machines/pp-ml1/configuration.nix
{ lib, modules, ... }:
{
  imports = with modules.darwin; [
    base
    sops
    pperanich
    rust
    sketchybar
    colima
    kimaki
  ];

  networking.hostName = "pp-ml1";
  nixpkgs.hostPlatform = "aarch64-darwin";
}
```

And the NAS:

```nix
# machines/pp-nas1/configuration.nix
{ modules, ... }:
{
  imports = with modules.nixos; [
    base sops pperanich rust
    immich nextcloud opencloud radicale
  ];
}
```

The import list doubles as documentation — you can read exactly what's enabled on each machine at a glance. Modules are opt-in: a machine only gets what it explicitly imports. There's no implicit inheritance to debug.

But how does `modules` get into scope? That's where clan-core comes in.

## Clan-Core: Fleet Management and Machine Discovery

[Clan-core](https://clan.lol/) handles machine discovery and deployment. In `modules/flake-parts/clan.nix`, I define the fleet inventory and pass `modules` as a special argument:

```nix
flake.clan = {
  meta.name = "pperanich-clan";

  specialArgs = {
    inherit inputs;
    inherit (config.flake) modules lib;
  };

  inventory = {
    machines = {
      "pp-ml1"       = { machineClass = "darwin"; tags = [ "laptop" "all" ]; };
      "pp-router1"   = { machineClass = "nixos";  tags = [ "router" "nixos" "all" ]; };
      "pp-nas1"      = { machineClass = "nixos";  tags = [ "nas" "nixos" "all" ]; };
      "pp-wsl1"      = { machineClass = "nixos";  tags = [ "vm" "nixos" "all" ]; };
      # ...
    };
  };
};
```

The `specialArgs` block is key. By passing `config.flake.modules` and `config.flake.lib`, every machine configuration file receives the full module namespace and custom library functions as arguments. That's what makes `with modules.darwin; [ base sops rust ]` possible in machine configs.

Clan also auto-discovers machines from the `machines/` directory. Each subdirectory with a `configuration.nix` becomes a machine — no need to register it separately. The `machineClass` field in the inventory tells clan whether to use NixOS or nix-darwin to evaluate it.

Beyond machine discovery, clan manages services through an inventory system with roles and tags. WireGuard, borgbackup, syncthing, SSH, and dynamic DNS are all assigned declaratively:

```nix
instances = {
  pp-wg = {
    module = { name = "wireguard"; input = "clan-core"; };
    roles = {
      controller.machines.pp-router1 = {
        settings.endpoint = "vpn.prestonperanich.com";
      };
      peer.machines = {
        pp-nas1 = {};
        pp-wsl1 = {};
        pp-ml1 = {};
      };
    };
  };

  borgbackup = {
    module = { name = "borgbackup"; input = "clan-core"; };
    roles = {
      server.machines.pp-router1 = {};
      client.machines.pp-nas1 = {};
    };
  };
};
```

This means WireGuard configuration, key generation, and peer wiring happen automatically across machines. `clan machines update pp-router1` builds, uploads, and activates in one command. Secrets (age keypairs, SSH host keys, WireGuard configs) are generated with `clan vars generate` and uploaded with `clan vars upload` — no manual key distribution.

## Extending the Library

Custom library functions live in `lib/default.nix` and are injected into `lib.my.*` so every module can use them:

```nix
# modules/flake-parts/nixpkgs.nix
extendedLib = inputs.nixpkgs.lib.extend (
  _self: _super: {
    my = import ../../lib { inherit (inputs.nixpkgs) lib; };
  }
);
_module.args.lib = extendedLib;
```

The library provides helpers like `relativeToRoot` for path resolution, a single source of truth for SSH public keys, and `mkHomeConfigurations` — a function that auto-generates `homeConfigurations` by scanning the `home-profiles/` directory for any subdirectory containing a `default.nix`.

## Home-Manager Composition

Home profiles mirror the same named-import pattern. My personal profile:

```nix
# home-profiles/pperanich/default.nix
{ homeManager, desktop ? true, ... }:
{
  imports = with homeManager; [
    base sops nvim rust tools opencode
  ] ++ (if desktop then with homeManager; [ fonts applications ] else []);

  home.username = "pperanich";
}
```

The `desktop` flag is set per-machine in the user bridge module, so headless servers skip fonts and GUI apps without duplicating the profile. The user bridge and how home profiles wire into machines are covered in [Part 3](/blog/dotfiles-part-3-secrets-fleet).

## Why This Works

The combination of import-tree, flake-parts, and clan-core eliminates most of the boilerplate that makes large Nix configurations painful:

- **No central import list** — modules self-register, so adding one is a single file drop
- **Cross-platform in one file** — a module can export to NixOS, Darwin, and home-manager simultaneously
- **Named composition** — machine configs read like a feature list, not a pile of path imports
- **Automatic machine discovery** — clan picks up `machines/*/configuration.nix` without registration
- **`specialArgs` threading** — `modules` and `lib` are available everywhere without manual plumbing
- **Service assignment via roles** — WireGuard, backups, and SSH are wired fleet-wide from the inventory

It's not zero-maintenance — overlays still need hash updates, and clan is still maturing — but for managing nine machines across three operating systems, this is the least friction I've found.

The [dotfiles repo](https://github.com/pperanich/dotfiles) is public if you want to see the full setup. In the next post, I'll walk through the NixOS router framework that runs on one of these machines.
