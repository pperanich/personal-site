---
title: 'Dotfiles, Part 2: A NixOS Home Router — From VLANs to Declarative DNS'
description: 'Building a full home router as composable NixOS modules — typed options, auto-derived nftables rules, VLAN isolation, and a custom Go CLI for Cloudflare DNS sync.'
pubDate: 2026-03-07
tags: ['nix', 'networking', 'infrastructure']
---

One of the nine machines in [my dotfiles flake](/posts/dotfiles-part-1-dendritic-flakes) is a home router running NixOS. Rather than hand-writing nftables rules and systemd-networkd configs, I built a module system that lets me declare what I want — subnets, VLANs, isolation levels, port forwards — and derives all the low-level configuration at build time.

This post walks through how it works, using the actual `pp-router1` machine config as a concrete example.

## The Router as a Composed Module

The router is itself an aggregated module that imports 14 sub-modules:

```nix
# modules/router/default.nix
flake.modules.nixos.router = { modules, ... }: {
  imports = with modules.nixos; [
    routerCoreInternal
    routerCore
    routerInterfaces
    routerFirewall
    routerDhcp
    routerDns
    routerBlocky
    routerDdns
    routerMdns
    routerSqm
    routerMonitoring
    routerVlans
    routerUnifi
    routerSsdpRelay
  ];
};
```

Each sub-module is independently defined via import-tree (as described in [Part 1](/posts/dotfiles-part-1-dendritic-flakes)), and the aggregated `router` module pulls them together. A machine opts in by importing `router` from its module list. This is the same dendritic pattern used everywhere else — the router just happens to be a larger composition.

## The Option Tree

The core module (`modules/router/core.nix`) defines a `my.router` option tree with typed submodules and validated constraints. Here's the interesting part:

```nix
# Custom validated types
octetType = types.ints.between 1 254;
portType = types.ints.between 1 65535;
macType = types.strMatching "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$";

machineSubmodule = types.submodule {
  options = {
    name = mkOption { type = types.str; };
    ip   = mkOption { type = octetType; };
    mac  = mkOption { type = macType; };
    portForwards = mkOption {
      type = types.listOf (types.submodule {
        options = {
          port     = mkOption { type = portType; };
          protocol = mkOption { type = types.enum [ "tcp" "udp" ]; default = "tcp"; };
        };
      });
      default = [];
    };
  };
};
```

MAC addresses are regex-validated. Port numbers are range-checked. IP octets can't be 0 or 255. This is type checking at the Nix evaluation level — invalid values are caught before anything touches the network.

Computed values are derived from user-facing options and exposed as read-only:

```nix
config = lib.mkIf cfg.enable {
  my.router.lan = {
    address    = "${cfg.lan.subnet}.1";      # e.g., "10.0.0.1"
    cidr       = "${cfg.lan.subnet}.0/24";   # e.g., "10.0.0.0/24"
    bridgeName = "br-lan";
  };
};
```

## Build-Time Assertions

The core module includes assertions that prevent deployment of invalid configurations:

```nix
assertions = [
  { assertion = cfg.lan.interfaces != [];
    message = "router: lan.interfaces must contain at least one interface"; }
  { assertion = cfg.lan.dhcpRange.start < cfg.lan.dhcpRange.end;
    message = "router: DHCP range start must be less than end"; }
  { assertion = builtins.all (m: m.ip < cfg.lan.dhcpRange.start || m.ip > cfg.lan.dhcpRange.end)
      cfg.machines;
    message = "router: Static machine IPs must be outside DHCP range"; }
  { assertion = let allPorts = ... in allPorts == lib.unique allPorts;
    message = "router: Duplicate port forwards detected"; }
  { assertion = let ips = map (m: m.ip) cfg.machines; in ips == lib.unique ips;
    message = "router: Duplicate machine IPs detected"; }
];
```

Duplicate IPs, duplicate port forwards, DHCP/static IP overlap, reserved addresses — these are all caught at `nix build` time, not at 2 AM when the router refuses to start. The VLAN module adds its own assertions on top: unique VLAN IDs, unique subnets, valid cross-references in `allowAccessFrom`/`allowAccessTo`, and at most one untagged main LAN.

## Cross-Module Firewall Composition

The trickiest design problem was getting firewall rules from multiple modules into a single nftables ruleset. Each sub-module (VLANs, mDNS, monitoring, Unifi, SSDP) needs to inject its own rules, but only the firewall module should assemble the final table.

The solution is an internal plumbing layer. Sub-modules deposit their rules into `config.my.router._internal`:

```nix
# From vlans.nix
my.router._internal.networkFirewall = {
  inputRules   = allInputRules;    # DHCP, DNS, NTP for each VLAN
  forwardRules = allForwardRules;  # Isolation-aware forwarding
  natRules     = allNatRules;      # Per-VLAN masquerade
};

# From mdns.nix
my.router._internal.mdnsFirewall = {
  inputRules   = "...";  # mDNS multicast on port 5353
  inputRulesV6 = "...";
};
```

The firewall module collects them all with safe defaults:

```nix
netFw  = internal.networkFirewall or { inputRules = ""; forwardRules = ""; natRules = ""; };
mdnsFw = internal.mdnsFirewall or { inputRules = ""; inputRulesV6 = ""; };
monFw  = internal.monitoringFirewall or { inputRules = ""; };
ssdpFw = internal.ssdpFirewall or { inputRules = ""; forwardRules = ""; };
unifiFw = internal.unifiFirewall or { inputRules = ""; };
```

Then it assembles the final nftables table, interleaving the collected rules at the right points in the chain. Five sub-modules contribute firewall fragments; the firewall module decides where each one goes. No module writes raw nftables rules directly — they declare *what* they need, and the firewall module handles *how* it's expressed.

The generated firewall includes anti-spoofing (BCP38 bogon filtering), port scan detection, rate limiting, flow offloading, MSS clamping, hairpin NAT, RA Guard at the bridge level, and IPv6 support with a full ICMPv6 policy — all derived from the option tree.

## VLAN Isolation

Network segments are declared with isolation levels:

```nix
my.router.networks.segments = {
  main = {
    subnet = "10.0.0";
    isolation = "none";       # Full access to everything
  };
  iot = {
    vlan = 20;
    subnet = "10.0.20";
    isolation = "internet";   # Internet only + explicit allows
    allowAccessFrom = [ "main" ];  # Main can reach IoT devices
  };
  guest = {
    vlan = 30;
    subnet = "10.0.30";
    isolation = "full";       # Internet only, no inter-network
  };
};
```

From this, the VLAN module automatically derives:

- **systemd-networkd netdevs** — 802.1Q VLAN interfaces and per-VLAN bridges
- **Kea DHCP pools** — per-subnet ranges with correct gateway and DNS options
- **nftables forward rules** — `none` gets full forwarding, `internet` gets WAN + explicit allows, `full` gets WAN only
- **NAT rules** — per-VLAN masquerade for outbound traffic
- **Chrony NTP access** — per-VLAN allow rules

Adding a new VLAN is a few lines. The firewall, DHCP, DNS, and NTP configuration all follow automatically.

## Declarative DNS with a Custom Go CLI

DNS records for internal services are declared in the machine config alongside a local helper:

```nix
# machines/pp-router1/configuration.nix
mkDnsRecords = subdomains: lib.concatMap (name: [
  { type = "A";    name = "${name}.prestonperanich.com"; content = lanIp; }
  { type = "AAAA"; name = "${name}.prestonperanich.com"; content = wgIpv6; }
]) subdomains;

my.cloudflareDns = {
  enable = true;
  zone = "prestonperanich.com";
  records = mkDnsRecords [
    "immich" "nextcloud" "jellyfin" "navidrome"
    "audiobookshelf" "home" "vault-admin" "ntopng" "unifi"
  ] ++ [
    { type = "TXT"; name = "prestonperanich.com";
      content = "v=spf1 include:_spf.resend.com ~all"; }
    { type = "TXT"; name = "_dmarc.prestonperanich.com";
      content = "v=DMARC1; p=none; rua=mailto:dmarc@prestonperanich.com"; }
  ];
};
```

The `mkDnsRecords` helper generates A + AAAA pairs for each subdomain, pointing to the router's LAN IP and WireGuard IPv6 address. These records resolve to private IPs — they're only useful from the LAN or VPN, but having them in public DNS means clients don't need custom resolvers.

To sync these records to Cloudflare, I wrote [`cf`](https://github.com/pperanich/dotfiles/tree/main/pkgs/cf), a Go CLI packaged with `buildGoModule`. It reads a JSON config (generated at Nix build time from the records list), compares it to what's in Cloudflare, and applies the diff. Only records tagged `managed-by:cf-dns` are touched — manually created records like dyndns entries are left alone.

The Nix module wires it into a systemd timer:

```nix
systemd.services.cf-dns-sync = {
  serviceConfig = {
    Type = "oneshot";
    EnvironmentFile = cfg.environmentFile;  # CLOUDFLARE_API_TOKEN from sops
    ExecStart = "${pkgs.cf}/bin/cf dns sync --config ${configJson} --apply";
    DynamicUser = true;
  };
};

systemd.timers.cf-dns-sync = {
  timerConfig = {
    OnBootSec = "5min";
    OnUnitActiveSec = cfg.interval;  # default: 12h
    Persistent = true;
  };
};
```

The same `cf` tool also handles Cloudflare Tunnel provisioning — creating tunnels, encrypting credentials with sops, and generating CNAME records. The whole DNS + tunnel setup is declarative: define records in Nix, `cf` syncs them, Caddy serves them, and the tunnel exposes what needs to be public.

## The Full Machine Config

Putting it all together, here's what `pp-router1` imports:

```nix
imports = with modules.nixos; [
  base sops pperanich
  router
  cloudflareDns cloudflareTunnel vaultwarden stalwart
  rust
];
```

One line for the router framework, one line per service. The rest of the 628-line config is machine-specific values: which interfaces are LAN vs WAN, the VLAN topology, Caddy vhosts, sops secret paths, SSH hardening, kernel tuning (BBR, SQM), and the Cloudflare DNS record list.

Every nftables rule, every DHCP pool, every VLAN bridge — generated from a handful of high-level options. And if I misconfigure something, the build fails with a message telling me exactly what's wrong.

In the [next post](/posts/dotfiles-part-3-secrets-fleet), I'll cover the secrets architecture, service exposure (Caddy + Cloudflare Tunnel), and fleet management that makes deploying all of this to multiple machines practical.
