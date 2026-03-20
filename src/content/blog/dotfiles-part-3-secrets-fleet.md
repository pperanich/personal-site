---
title: 'Dotfiles, Part 3: Secrets, Fleet Management, and the User Bridge'
description: 'How I bootstrap 9 machines with sops-nix, clan-core, and a user module pattern that solves the secrets chicken-and-egg problem — plus service exposure via Caddy and Cloudflare Tunnel.'
pubDate: 2026-03-11
tags: ['nix', 'security', 'infrastructure']
---

In [Part 1](/posts/dotfiles-part-1-dendritic-flakes), I covered the module architecture. [Part 2](/posts/dotfiles-part-2-nixos-router) walked through the router. This post is about the operational side: how secrets get where they need to go, how machines get deployed, and how the same user module works across NixOS and macOS without duplication.

## Two Secret Systems, Two Jobs

I use two complementary systems because no single one handles everything:

**Clan vars** handles machine bootstrap secrets — age keypairs, SSH host keys, WireGuard configs, user passwords. These are generated with `clan vars generate <hostname>` and uploaded with `clan vars upload <hostname>`. They're the foundation everything else builds on.

**sops-nix** handles application secrets — API keys, service credentials, SSH private keys. These live in an encrypted `sops/secrets.yaml` committed to the repo, decrypted at activation time using the machine's age key (which was deployed by clan vars).

The split is deliberate. Clan vars bootstraps the machine identity. sops-nix uses that identity to decrypt everything else.

## The Chicken-and-Egg Problem

Home-manager's sops module needs an SSH private key to decrypt secrets. But the SSH private key is itself a secret. If home-manager can't decrypt without the key, and the key is encrypted, how does anything start?

The answer is ordering. System-level sops runs first — it decrypts using the machine's host age key (derived from `/etc/ssh/ssh_host_ed25519_key`, which clan vars deployed). The user module deploys the SSH private key at the system level, before home-manager activates:

```nix
# modules/users/pperanich.nix — NixOS variant
sops.secrets."private_keys/pperanich" = {
  sopsFile = "${sopsFolder}/secrets.yaml";
  owner = "pperanich";
  group = "users";
  mode = "0400";
  path = "/home/pperanich/.ssh/id_ed25519";
};
```

By the time home-manager's sops module runs, the SSH key is already on disk. Home-manager converts it to an age key and decrypts user-level secrets (API tokens, service credentials) without issue.

The sops module itself reflects this ordering in its configuration:

```nix
# modules/system/sops.nix — home-manager variant
sops.age.sshKeyPaths = [
  "${config.home.homeDirectory}/.ssh/id_ed25519"  # Deployed by system sops
  "/etc/ssh/ssh_host_ed25519_key"                 # Fallback to host key
];
```

This two-phase approach — system sops deploys the user's key, then home-manager sops uses it — breaks the circular dependency cleanly.

## The User Bridge Module

The user module is where system configuration and home-manager meet. A single file (`modules/users/pperanich.nix`) exports to both platforms:

```nix
flake.modules.nixos.pperanich = { config, lib, pkgs, modules, ... }: {
  # 1. Deploy SSH key via system sops (before home-manager)
  sops.secrets."private_keys/pperanich" = { ... };

  # 2. Create system user
  users.users.pperanich = {
    openssh.authorizedKeys.keys = builtins.attrValues lib.my.sshKeys;
    shell = pkgs.zsh;
  };

  # 3. Wire up home-manager
  home-manager.users.pperanich.imports = lib.flatten [
    (_: import (lib.my.relativeToRoot "home-profiles/pperanich") {
      inherit (modules) homeManager;
      config = config.home-manager.users.pperanich;
      inherit (config.my.pperanich) desktop;
    })
  ];
};

flake.modules.darwin.pperanich = { config, lib, pkgs, modules, ... }: {
  # Same pattern, different paths and platform details
  sops.secrets."private_keys/pperanich" = {
    path = "/Users/pperanich/.ssh/id_ed25519";
    group = "staff";  # macOS group
    ...
  };
  # ...
};
```

One file handles three things: secret deployment, system user creation, and home-manager wiring — for both NixOS and Darwin. When a machine imports `pperanich`, it gets all three in the right order.

The `desktop` flag controls whether the home profile includes fonts and GUI apps:

```nix
options.my.pperanich.desktop = lib.mkOption {
  type = lib.types.bool;
  default = true;
};
```

Servers set `my.pperanich.desktop = false`. Laptops get the default. The same home profile handles both — it conditionally imports desktop modules based on the flag:

```nix
# home-profiles/pperanich/default.nix
imports = with homeManager; [
  base sops nvim rust tools opencode
] ++ (if desktop then with homeManager; [ fonts applications ] else []);
```

## Fleet Deployment with Clan

Deploying a machine is one command:

```sh
clan machines update pp-router1
```

This builds the configuration, uploads it to the target, and activates it. The target host is specified per-machine:

```nix
clan.core.networking.targetHost = lib.mkForce "root@pp-router1.pp-wg";
```

Some machines build locally, others offload. The NAS, for example, builds on a different machine:

```nix
clan.core.networking.buildHost = "root@pp-wsl1.pp-wg";
```

The inventory (from [Part 1](/posts/dotfiles-part-1-dendritic-flakes)) drives service assignment across the fleet. WireGuard peers are wired automatically — `pp-router1` is the controller, and all other machines are peers. Borgbackup runs with the router as server and the NAS as client. SSH keys, authorized keys, and certificate search domains are applied fleet-wide via tags:

```nix
sshd-basic = {
  module = { name = "sshd"; input = "clan-core"; };
  roles = {
    server.tags.all = {
      settings = {
        authorizedKeys = self.lib.my.sshKeys;
        generateRootKey = true;
      };
    };
    client.tags.all = {};
  };
};
```

Every machine tagged `all` gets SSH server and client configuration with the right keys. No per-machine SSH setup needed.

## Service Exposure: Caddy + Cloudflare Tunnel

Internal services are exposed through two layers, both configured on the router.

**Caddy** handles HTTPS on the LAN and WireGuard interfaces. It uses the Cloudflare DNS challenge for certificates (no ports exposed to the internet), and a helper function keeps vhost definitions consistent:

```nix
mkProxy = backend: mkVhost ''reverse_proxy ${backend}'';

services.caddy.virtualHosts = {
  "immich.prestonperanich.com"     = mkProxy "http://${nasHost}:2283";
  "nextcloud.prestonperanich.com"  = mkProxy "http://${nasHost}:80";
  "vault.prestonperanich.com"      = mkProxy "localhost:${toString config.my.vaultwarden.port}";
  # ...
};
```

**Cloudflare Tunnel** exposes select services publicly without opening any WAN ports. A dedicated localhost-only Caddy listener blocks the admin panel before proxying to Vaultwarden:

```nix
"http://:8223" = {
  listenAddresses = [ "127.0.0.1" ];
  extraConfig = ''
    handle /admin* { respond "Forbidden" 403 }
    handle { reverse_proxy localhost:${toString config.my.vaultwarden.port} }
  '';
};
```

The tunnel module validates the UUID format at build time, catching both invalid and placeholder values — the same assertion pattern used throughout the router framework in [Part 2](/posts/dotfiles-part-2-nixos-router).

## Work Environment Isolation

Two of my machines are work laptops. They need a corporate root CA and OpenSSL 1.1, but those changes shouldn't bleed into personal machines. A single overlay in `modules/work.nix` swaps `curl`, `git`, `buildGoModule`, and `rustPlatform` to use OpenSSL 1.1 and the corporate CA. The home-manager variant injects the cert bundle into every environment variable that tools check (`NIX_SSL_CERT_FILE`, `SSL_CERT_FILE`, `CURL_CA_BUNDLE`, etc.). Work machines import the `work` module; personal machines don't. Same flake, different overlays.

## Putting It Together

The full operational flow for adding a new machine:

1. Create `machines/<hostname>/configuration.nix` with the module imports
2. Add the machine to the clan inventory (name, class, tags)
3. Run `clan vars generate <hostname>` to create bootstrap secrets
4. Run `clan vars upload <hostname>` to deploy them
5. Run `clan machines update <hostname>` to build and activate

From that point on, updates are just `clan machines update <hostname>`. Secrets rotate with `clan vars generate` + `upload`. Adding a service is adding a module to the machine's import list and re-deploying.

Nine machines, three operating systems, one flake. The secrets bootstrap cleanly, the user bridge keeps NixOS and Darwin in sync, and clan handles deployment. It's not zero-maintenance, but it's close to the minimum viable complexity for this many machines.

The full setup is in my [dotfiles repo](https://github.com/pperanich/dotfiles). In the [next post](/posts/dotfiles-part-4-network-services), I'll cover the network-aware services that derive their behavior from the topology — split-tunnel VPNs, topology-driven DNS blocking, and dynamic WireGuard peer onboarding.
