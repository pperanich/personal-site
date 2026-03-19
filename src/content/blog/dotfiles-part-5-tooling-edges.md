---
title: 'Dotfiles, Part 5: Custom Tooling and the Platform Edges'
description: 'A Cloudflare CLI with a tunnel state machine, GNU Stow inside Nix, triple-platform service modules, secure credential hashing, declarative ZFS, and dev shell bootstrapping.'
pubDate: 2026-03-19
tags: ['nix', 'tooling', 'infrastructure']
---

In Parts [1](/blog/dotfiles-part-1-dendritic-flakes)–[4](/blog/dotfiles-part-4-network-services), the focus was on module architecture and network services. This post covers the tools and patterns that handle operational edges: interacting with external APIs, bridging Nix with non-Nix workflows, running services across Darwin and NixOS, and making the dev shell a complete operational environment.

## The `cf` Tunnel State Machine

The `cf` CLI (`pkgs/cf/`) is a Go tool built with `buildGoModule` that manages Cloudflare DNS records and tunnels. The DNS sync side is straightforward — read a JSON config, diff against the API, apply changes. The tunnel provisioning side is more interesting because it has to manage state across three independent sources.

A tunnel's state is the combination of three booleans: does the tunnel exist in the Cloudflare API, does a metadata file exist locally, and does a sops-encrypted credentials file exist? That's 8 possible states, and each one requires a different action:

```go
switch {
case !hasTunnel && !hasMeta && !hasCreds:
    // Fresh start — create everything

case hasTunnel && hasMeta && hasCreds:
    // All present — verify match, update CNAMEs if needed

case hasTunnel && hasMeta && !hasCreds:
    // FATAL — tunnel secret can't be recovered from API

case hasTunnel && !hasMeta && hasCreds:
    // Reconstruct metadata from API

case !hasTunnel && hasMeta && hasCreds:
    // Stale state — tunnel deleted, require --force to recreate

default:
    // Other partial states — require --force
}
```

The FATAL case is load-bearing: Cloudflare's API doesn't expose the tunnel secret after creation. If the credentials file is lost but the tunnel still exists, the only option is to delete the tunnel and start over. The CLI makes this explicit rather than silently creating a second tunnel.

Credential handling is also worth noting. The CLI writes plaintext credentials, immediately encrypts them in-place with `sops -e -i --input-type binary`, and cleans up on failure — including deleting the orphaned tunnel from Cloudflare:

```go
if err := cmd.Run(); err != nil {
    os.Remove(credsPath)
    cleanupTunnel(ctx, client, accountID, tunnel.ID)
    log.Fatalf("Failed to encrypt credentials with sops: %v\n"+
        "Ensure sops/.sops.yaml has a creation_rule for cloudflared-tunnel.json", err)
}
```

A nil-UUID placeholder (`00000000-0000-0000-0000-000000000000`) distinguishes "metadata file exists with real data" from "metadata file exists but was never populated." The Nix tunnel module validates against this at build time, catching forgotten provisioning steps before deployment.

Everything defaults to dry-run (exit code 2 when changes are needed, 0 when clean). `--apply` is required to mutate state, and `--force` is required for recovery from unexpected states.

## GNU Stow + Nix: The Hybrid Approach

Not every config file benefits from Nix templating. Editor configs managed by the editor itself, tool-specific dotfiles that change frequently — these are easier to manage as plain files. The `home/` directory in the repo uses GNU Stow's symlink convention, and a home-manager activation hook runs it after every switch:

```nix
# modules/system/base.nix — homeManager variant
home.activation = {
  stowHome = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    pushd ${config.home.homeDirectory}/dotfiles/ >/dev/null
    ${pkgs.stow}/bin/stow home
    popd >/dev/null
  '';
};
```

The `entryAfter ["writeBoundary"]` ordering is important: home-manager writes its files first, then stow creates symlinks for everything else. This means Nix-managed files take precedence — stow won't overwrite them because they already exist at the target path.

This hybrid approach solves a real migration problem. Converting every config file to Nix at once is impractical. Stow lets you keep files as-is while progressively moving things into home-manager modules. Files that are templated or conditional (like the home profile's desktop flag) go into Nix. Files that are static and tool-managed stay in `home/` and get symlinked.

## Triple-Platform Service Modules

The Kimaki Discord bot module (`modules/services/kimaki.nix`) demonstrates a pattern for services that need to run on both macOS and NixOS. A single 420-line file exports three module variants:

```nix
flake.modules = {
  darwin.kimaki = { ... }: {
    # launchd.user.agents.kimaki with KeepAlive, ThrottleInterval
  };
  nixos.kimaki = { ... }: {
    # systemd.user.services.kimaki with Restart, ConditionPathExists
  };
  homeManager.kimaki = { ... }: {
    # Platform detection: systemd.user on Linux, launchd.agents on Darwin
  };
};
```

The interesting aspects:

**Platform-specific compilers.** Native Node modules (better-sqlite3) require `clang` on Darwin for `-stdlib=libc++` support and `gcc` on Linux. The home-manager variant detects this:

```nix
buildDeps = [ pkgs.bun pkgs.git pkgs.sqlite pkgs.python3 pkgs.gnumake ... ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.clang ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.gcc ];
```

**Initialization guard.** A wrapper script validates the database and credentials before starting, because the bot requires manual first-run setup (Discord token entry). Rather than failing cryptically, it checks for the database file and queries the `bot_tokens` table:

```nix
kimakiWrapper = pkgs.writeShellScript "kimaki-wrapper" ''
  DB_FILE="$DATA_DIR/discord-sessions.db"

  if [ ! -f "$DB_FILE" ]; then
    echo "ERROR: Kimaki not initialized."
    echo "Run 'bunx kimaki@latest --data-dir ${cfg.dataDir}' manually first."
    exit 1
  fi

  if ! sqlite3 "$DB_FILE" "SELECT 1 FROM bot_tokens LIMIT 1;" >/dev/null 2>&1; then
    echo "ERROR: Database exists but has no bot credentials."
    exit 1
  fi

  exec bunx kimaki@latest ${kimakiArgsStr}
'';
```

**Darwin session variable injection.** The Colima module (`modules/services/colima.nix`) shows a related pattern — reading home-manager session variables and baking them into the launchd plist:

```nix
sessionVars = config.home-manager.users.${primaryUser}.home.sessionVariables;

launchd.user.agents.colima.serviceConfig = {
  EnvironmentVariables = sessionVars // {
    PATH = lib.makeBinPath [ pkgs.docker-client pkgs.docker-compose ... ];
  };
};
```

This solves `launchctl setenv` ordering issues where services start before environment variables are set. The variables are baked into the plist at build time.

## Secure Credential Handling: Vaultwarden Admin Token

The Vaultwarden module (`modules/services/vaultwarden.nix`) demonstrates a pattern where a service should never see plaintext credentials. The admin token is stored in sops as plaintext, but Vaultwarden expects an Argon2id hash. A separate systemd service handles the hashing:

```nix
systemd.services.vaultwarden-admin-hash = lib.mkIf (cfg.adminTokenFile != null) {
  description = "Hash Vaultwarden admin token with Argon2id";
  requiredBy = [ "vaultwarden.service" ];
  before = [ "vaultwarden.service" ];
  serviceConfig.Type = "oneshot";
  script = ''
    TOKEN=$(<"${cfg.adminTokenFile}")
    SALT=$(openssl rand -base64 32)
    HASH=$(echo -n "$TOKEN" | argon2 "$SALT" -e -id -k 65540 -t 3 -p 4)
    printf 'ADMIN_TOKEN=%s\n' "$HASH" > /run/vaultwarden-admin-token.env
    chown vaultwarden:vaultwarden /run/vaultwarden-admin-token.env
    chmod 400 /run/vaultwarden-admin-token.env
  '';
};
```

The ordering chain: sops decrypts the plaintext token → the hasher reads it, generates a random salt, hashes with argon2id, writes the hash to a runtime file → Vaultwarden starts and reads the hash via `EnvironmentFile`. The plaintext token exists only briefly in the hasher's process memory. A fresh salt is generated on every boot, so the hash changes each time.

The module also conditionally opens the firewall only when Vaultwarden binds to non-loopback addresses — if it's behind a reverse proxy on localhost, no firewall rule is needed.

## Declarative ZFS with Disko

The NAS storage layout (`machines/pp-nas1/disko.nix`) uses disko to declaratively define a ZFS mirror across two NVMe drives. The dataset hierarchy uses a container pattern:

```nix
datasets = {
  # Non-mountable container — organizational parent only
  "root" = { type = "zfs_fs"; options.mountpoint = "none"; };

  # System datasets with quotas
  "root/nixos" = {
    type = "zfs_fs";
    mountpoint = "/";
    options = { quota = "50G"; "com.sun:auto-snapshot" = "true"; };
  };
  "nix" = {
    type = "zfs_fs";
    mountpoint = "/nix";
    options = { quota = "250G"; "com.sun:auto-snapshot" = "false"; };
  };

  # Media pool with reservation (not quota)
  "tank" = {
    type = "zfs_fs";
    options = { mountpoint = "none"; reservation = "1500G"; };
  };
  "tank/appdata" = {
    type = "zfs_fs";
    mountpoint = "/tank/appdata";
    # Inherits from parent — no explicit reservation
  };
};
```

The distinction between `quota` and `reservation` matters: `quota` limits how much a dataset can grow, while `reservation` guarantees minimum available space. The `/nix` store gets a 250G quota (it doesn't need guarantees — it can be rebuilt), but `tank` gets a 1.5TB reservation because media data is irreplaceable.

Pool-wide settings apply zstd compression, disable atime (reduces write amplification), set a small xattr inline size, and enable POSIX ACLs. The `/nix` dataset disables auto-snapshots since the store is reproducible — snapshotting it wastes space.

Both NVMe drives get GRUB installed, so the system can boot from either drive if one fails. The entire layout is reproducible from a single file — `disko` can partition, format, and mount everything from scratch.

## Dev Shell as Operational Environment

The dev shell (`modules/flake-parts/shell.nix`) is where fleet management actually happens. The shell hook bootstraps everything needed for `sops` and `clan` to work:

```nix
devShells.default = pkgs.mkShell {
  packages = with pkgs; [
    sops ssh-to-age age
    jq nix-output-monitor
    wg-add-peer cf
  ];

  shellHook = ''
    if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
      export SOPS_AGE_KEY=$(ssh-to-age -private-key < "$HOME/.ssh/id_ed25519" 2>/dev/null)
    fi
    export PATH=$PWD/bin/:$PATH
  '';
};
```

The `ssh-to-age` conversion means you don't need a separate age key — your existing SSH key is reused. Combined with the `bin/` PATH addition (for repo-local scripts), entering the dev shell with `nix develop` gives you a complete operational environment: `sops` can decrypt secrets, `clan` can deploy machines, `cf` can sync DNS, and `wg-add-peer` can onboard devices.

This is the bridge between the declarative Nix world and day-to-day operations. You don't need to remember which tools to install or which environment variables to set — `nix develop` handles it.

## Wrapping Up

These five posts have covered the full stack: module architecture ([Part 1](/blog/dotfiles-part-1-dendritic-flakes)), router framework ([Part 2](/blog/dotfiles-part-2-nixos-router)), secrets and fleet management ([Part 3](/blog/dotfiles-part-3-secrets-fleet)), network-aware services ([Part 4](/blog/dotfiles-part-4-network-services)), and the custom tooling that ties it together.

The common thread is that Nix's evaluation model — where everything is data before it becomes configuration — makes these patterns possible. VLANs drive firewall rules and DNS policy. A JSON file of peers becomes WireGuard config and `/etc/hosts` entries. A state machine in Go produces metadata that Nix consumes at build time. Each layer feeds the next.

The full setup is in my [dotfiles repo](https://github.com/pperanich/dotfiles).
