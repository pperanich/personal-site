---
title: 'Dotfiles, Part 4: Network-Aware Services — From Split Tunneling to Topology-Driven DNS'
description: 'ProtonVPN with network namespace split tunneling, ad-blocking derived from VLAN topology, DHCP-to-DNS sync, and dynamic WireGuard peer onboarding — all as composable NixOS modules.'
pubDate: 2026-03-15
tags: ['nix', 'networking', 'security', 'infrastructure']
---

In Parts [1](/blog/dotfiles-part-1-dendritic-flakes)–[3](/blog/dotfiles-part-3-secrets-fleet), I covered the module architecture, the router framework, and fleet management. This post is about a different kind of composability: services that derive their behavior from the network topology instead of being configured independently.

## ProtonVPN with Network Namespace Split Tunneling

The ProtonVPN module (`modules/services/protonvpn.nix`) supports two operating modes. **Host mode** routes all traffic through the VPN using wg-quick. **Namespace mode** creates a separate Linux network namespace — only services explicitly placed inside it use the VPN. Host traffic is unaffected.

Namespace mode exists because wg-quick is unsuitable for split tunneling. It applies address, DNS, and routing in the host namespace before `postUp` runs, and its teardown can't find the interface after it's been moved to a different namespace. Its DNS setting also poisons the host resolver. So namespace mode uses raw `ip` and `wg` commands instead:

```nix
# Create the network namespace
systemd.services.protonvpn-netns = {
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = "${ip} netns add ${nsName}";
    ExecStartPost = "${ip} -n ${nsName} link set lo up";
    ExecStop = "${ip} netns del ${nsName}";
  };
};

# WireGuard tunnel — create in host, configure, then move into namespace
systemd.services.protonvpn-tunnel = {
  bindsTo = [ "protonvpn-netns.service" ];
  serviceConfig.ExecStart = pkgs.writeShellScript "protonvpn-tunnel-up" ''
    # Create interface and load key in host namespace
    ${ip} link add ${ifName} type wireguard
    ${wg} set ${ifName} private-key ${keyFile} \
      peer ${cfg.endpoint.publicKey} \
        endpoint ${cfg.endpoint.ip}:${toString cfg.endpoint.port} \
        allowed-ips 0.0.0.0/0,::/0 \
        persistent-keepalive 25

    # Move into namespace and configure there
    ${ip} link set ${ifName} netns ${nsName}
    ${ip} -n ${nsName} addr add ${cfg.interface.ip} dev ${ifName}
    ${ip} -n ${nsName} link set ${ifName} up
    ${ip} -n ${nsName} route add default dev ${ifName}
  '';
};
```

The key insight is creating the WireGuard interface in the host namespace (where the kernel loads the private key), then moving it into the isolated namespace. Once moved, the interface and its routes only exist inside the namespace.

### Confining Services with Socket Proxies

Any systemd service can be placed inside the namespace declaratively:

```nix
my.protonvpn = {
  mode = "namespace";
  namespace.confinedServices.transmission = {
    serviceUnit = "transmission";
    socketProxy = {
      "0.0.0.0:9091" = "127.0.0.1:9091";
    };
  };
};
```

The `mkConfinedService` function overrides the target service to run inside the namespace, then creates `socat`-based TCP proxies to bridge the boundary:

```nix
mkConfinedService = name: svcCfg: {
  systemd.services.${svcCfg.serviceUnit} = {
    bindsTo = [ "protonvpn-netns.service" "protonvpn-tunnel.service" ];
    serviceConfig = {
      NetworkNamespacePath = "/var/run/netns/${nsName}";
      BindReadOnlyPaths = [ "/etc/netns/${nsName}/resolv.conf:/etc/resolv.conf" ];
    };
  };
  # For each socketProxy entry, create a socat bridge service
  # Host listens on hostAddr:hostPort, forwards into namespace via ip netns exec
};
```

The confined service can only reach the network through the VPN tunnel. The socket proxy makes its web UI accessible from the host without breaking isolation.

### Dual Kill Switch Architecture

Host mode offers two kill switch variants:

**Inline iptables** rules are added in `postUp` and removed in `preDown`. If the VPN drops unexpectedly (wg-quick crashes), the rules vanish with it — traffic leaks.

**Persistent chain** solves this with a separate systemd service that installs a custom iptables chain *before* the VPN starts and removes it only on explicit stop:

```nix
# Allow: loopback, VPN interface, VPN endpoint, RFC1918 (LAN),
#        ULA IPv6 (WireGuard mesh), link-local IPv6
# Reject everything else
${iptables} -A ${chainName} -o lo -j ACCEPT
${iptables} -A ${chainName} -o ${ifName} -j ACCEPT
${iptables} -A ${chainName} -d ${cfg.endpoint.ip}/32 -p udp \
  --dport ${toString cfg.endpoint.port} -j ACCEPT
${iptables} -A ${chainName} -d 10.0.0.0/8 -j ACCEPT
${iptables} -A ${chainName} -d 172.16.0.0/12 -j ACCEPT
${iptables} -A ${chainName} -d 192.168.0.0/16 -j ACCEPT
${ip6tables} -A ${chainName} -d fc00::/7 -j ACCEPT
${iptables} -A ${chainName} -j REJECT
```

Traffic is blocked even between VPN stop and start. LAN and the WireGuard mesh remain reachable throughout.

In namespace mode, kill switches are unnecessary — and the module enforces this with an assertion:

```nix
assertion = cfg.mode == "host" || cfg.killSwitch == "none";
message = "killSwitch is only supported in host mode. In namespace mode, services are inherently isolated.";
```

### Leak Verification as a Systemd Service

The module includes an on-demand leak test that *actually stops the tunnel* to prove isolation works:

```nix
systemd.services.protonvpn-verify-leak = {
  # No wantedBy — manual start: systemctl start protonvpn-verify-leak
  serviceConfig.ExecStart = pkgs.writeShellScript "protonvpn-verify-leak" ''
    # Step 1: Confirm tunnel works, record namespace IP
    # Step 2: Stop the tunnel
    systemctl stop protonvpn-tunnel.service

    # Step 3: Verify isolation
    # Check 1: No non-loopback interfaces in namespace
    # Check 2: No default route
    # Check 3: Cannot reach internet (curl returns BLOCKED)

    # Step 4: Restart tunnel
    # Step 5: Confirm connectivity restored
  '';
};
```

Five steps: verify the tunnel works, stop it, prove the namespace has no connectivity (no interfaces, no routes, no internet), restart, confirm restored. It's unusual to see testing infrastructure built directly into a NixOS module, but for something as security-critical as VPN isolation, being able to run `systemctl start protonvpn-verify-leak` and get a definitive answer is valuable.

## Ad-Blocking Derived from Network Topology

The Blocky DNS module (`modules/router/blocky.nix`) sits in front of Unbound: clients query Blocky on port 53, Blocky handles ad/malware blocking, and forwards clean queries to Unbound on port 5335.

The interesting pattern is how per-subnet blocking policies are derived automatically from the VLAN topology when no explicit configuration is provided:

```nix
autoClientGroups = { default = [ "ads" "malware" ]; }
// lib.mapAttrs' (_name: net: {
  name = net.cidr;
  value = if net.isolation == "internet"
    then [ "ads" "malware" "telemetry" ]
    else [ "ads" "malware" ];
}) vlanNets;

effectiveClientGroups =
  if blockyCfg.clientGroupsBlock != { }
  then blockyCfg.clientGroupsBlock
  else autoClientGroups;
```

Networks with `isolation = "internet"` (IoT devices) automatically get aggressive telemetry blocking — Apple, Amazon, TikTok, and Windows/Office telemetry lists. Trusted networks get standard ad/malware blocking. No per-subnet configuration needed.

The `effectiveClientGroups` pattern means you can override this for specific subnets without losing the auto-derivation for others. And the module validates that referenced blocking groups actually exist:

```nix
assertion = invalidGroups == [ ];
message = "clientGroupsBlock references undefined denylist groups: ${toString invalidGroups}";
```

The local zone and RFC 1918 reverse DNS are conditionally routed to Unbound via Blocky's `conditional.mapping`, including programmatically generated zones for all 172.16–31.x.x subnets:

```nix
map (n: "${toString n}.172.in-addr.arpa") (lib.range 16 31)
```

## DHCP-to-DNS Sync with Dual Triggers

The DDNS module (`modules/router/ddns.nix`) makes DHCP hostnames resolvable as `<hostname>.home.arpa` via Unbound. The sync architecture has three notable properties.

**Dual triggering.** A systemd path unit watches Kea's lease file via inotify for immediate updates. A timer fires every 5 minutes as a fallback for missed events. Both trigger the same oneshot sync service.

**Self-healing after Unbound restarts.** Unbound loses all dynamic records when it restarts. The module handles this through systemd lifecycle hooks:

```nix
# Clear tracking file when Unbound stops (dynamic records are lost)
systemd.services.unbound.serviceConfig.ExecStopPost =
  "+-${pkgs.coreutils}/bin/rm -f ${trackingFile}";

# Re-sync immediately after Unbound starts
systemd.services.unbound.serviceConfig.ExecStartPost =
  "+-${pkgs.systemd}/bin/systemctl start --no-block kea-unbound-sync.service";

# Timer restarts with Unbound via partOf binding
systemd.timers.kea-unbound-sync.partOf = [ "unbound.service" ];
```

When the tracking file is missing, the sync script re-adds all current leases (the `local_data` call is idempotent). No manual intervention needed.

**Hostname sanitization.** DHCP hostnames come from clients — they're attacker-influenced input. The script sanitizes them for RFC 952 compliance before adding DNS records: lowercase, strip non-alphanumeric characters, trim leading/trailing hyphens. The systemd service is also sandboxed with `ProtectSystem`, `ProtectHome`, and `NoNewPrivileges`.

The script handles Kea's two-file lease format: `.csv.2` contains consolidated leases from the last LFC (Lease File Cleanup) run, and `.csv` is an append-only journal of changes since. Both files are read in order so recent changes win.

## Dynamic WireGuard Peer Onboarding

Clan-core manages WireGuard peers for machines in the fleet, but external devices (phones, tablets) need a different approach. These peers are stored in a JSON file loaded at Nix evaluation time:

```nix
# machines/pp-router1/configuration.nix
systemd.network.netdevs."40-pp-wg".wireguardPeers =
  let
    peers = builtins.fromJSON (builtins.readFile ./wg-external-peers.json);
  in
  lib.mapAttrsToList (_name: peer: {
    PublicKey = peer.publicKey;
    AllowedIPs = [ "${wgPrefix}::${peer.addressSuffix}/128" ];
    PersistentKeepalive = 25;
  }) peers;
```

The JSON structure is minimal:

```json
{
  "phone1": {
    "name": "Preston's iPhone",
    "publicKey": "As57FlqV...",
    "addressSuffix": "f001"
  }
}
```

The `wg-add-peer` CLI (`pkgs/wg-add-peer/`) automates the full onboarding workflow:

1. Auto-increments the hex IPv6 suffix by parsing existing peers
2. Generates a WireGuard keypair
3. Updates the peers JSON file
4. Stores the private key in sops via `sops set`
5. Saves a redacted config to `docs/wireguard/` for reference
6. Displays a QR code for the WireGuard mobile app

After running `wg-add-peer phone3`, one `clan machines update pp-router1` deploys the new peer. The private key never touches the Nix store — it goes directly into the sops-encrypted secrets file.

The hostname is also registered in `/etc/hosts` so devices are reachable as `phone1.pp-wg` from any machine on the mesh:

```nix
networking.extraHosts =
  let peers = builtins.fromJSON (builtins.readFile ./wg-external-peers.json);
  in lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: peer:
      "${wgPrefix}::${peer.addressSuffix} ${name}.pp-wg") peers
  );
```

## Why These Patterns Matter

All four of these services share a common design principle: they derive configuration from the network topology rather than requiring independent manual setup.

- ProtonVPN's namespace mode confines services without touching their own config
- Blocky reads VLAN isolation levels to set blocking policy
- DDNS reads DHCP leases to populate DNS — no static host entries
- WireGuard peers are loaded from data, not hardcoded in Nix expressions

The router's option tree (from [Part 2](/blog/dotfiles-part-2-nixos-router)) makes this possible. Because subnets, isolation levels, and machine definitions are structured data, downstream modules can consume them programmatically. The topology is declared once; everything else follows.

The full setup is in my [dotfiles repo](https://github.com/pperanich/dotfiles). In the [next post](/blog/dotfiles-part-5-tooling-edges), I'll cover the custom CLI tools and cross-platform patterns that handle the operational edges.
