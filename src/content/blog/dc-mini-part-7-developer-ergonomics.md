---
title: 'DC Mini Part 7: Developer Ergonomics — xtask, Nix, and the Prelude'
description: 'Build orchestration with xtask, reproducible toolchains with Nix flakes, and a prelude pattern for managing imports in a complex embedded workspace.'
pubDate: 2026-02-24
tags: ['rust', 'embedded', 'eeg', 'open-source', 'nix', 'developer-experience']
---

In [Part 6](/posts/dc-mini-part-6-executors-dfu-neopixel) we covered the runtime infrastructure — executors, DFU, and the Neopixel driver. This final post steps back from the firmware itself to look at the developer experience: how we build it, how we keep the environment reproducible, and how we manage complexity in a multi-crate workspace.

Embedded Rust projects accumulate friction fast. The toolchain is nightly. The target is a cross-compilation triple most developers haven't seen before. Building requires multiple passes for the bootloader and application. Flashing requires a debug probe and specific tool configuration. Every one of these is a place where a new contributor can get stuck.

## xtask: Build Orchestration Without Shell Scripts

DC Mini's firmware has a two-stage build. The bootloader must be compiled before the application — they're separate crates with different Cargo features and memory layouts. The bootloader goes into one flash region, the application into another. Getting this sequence wrong produces opaque failures: a missing bootloader means the application boots to a hard fault, and a feature mismatch means the BLE stack silently fails to initialize.

Rather than a `Makefile` or a shell script that grows organically and breaks across platforms, we use the `cargo xtask` pattern — a Rust binary in the workspace that orchestrates the build. Four commands cover the entire development loop:

**`cargo xtask build`** compiles the bootloader and application in the correct order, with the right target triple and feature flags. The developer specifies features (`--features "sr6,usb,trouble"`) and the xtask handles everything else.

**`cargo xtask flash`** builds first, then flashes both binaries to the device via `probe-rs`. It uses `--preverify` to skip flashing if the image hasn't changed — since the bootloader rarely changes, this saves several seconds on most cycles. It also uses `--restore-unwritten` to preserve flash contents outside the written regions, which matters when the bootloader state and profile storage share the same flash chip.

**`cargo xtask run`** does everything `flash` does, then immediately attaches an RTT (Real-Time Transfer) session so `defmt` log output appears in the terminal. This is the most common development command — build, flash, and see logs in one step.

**`cargo xtask attach`** connects RTT to an already-running device without reflashing. Useful when the device is deployed and you just want to read logs.

The xtask pattern is well-established in the Rust ecosystem, but it's especially valuable for embedded projects. Shell scripts break across macOS and Linux, can't easily parse command-line arguments, and tend to accumulate undocumented flags. A Rust binary gets type-checked, tested, and cross-platform behavior for free.

## Nix: One Command to a Working Environment

The development environment is defined in a `flake.nix` that pins every external dependency: the Rust nightly toolchain (via `rust-toolchain.toml`), the `thumbv7em-none-eabihf` cross-compilation target, ARM GCC for linking the nRF52840's startup code, `protoc` for compiling the ICD's protobuf definitions, `libusb` for probe-rs's USB access, and development tools like `cargo-bloat` for binary size analysis and `bacon` for continuous compilation.

`nix develop` (or `direnv allow` with nix-direnv) gives any contributor an identical environment on macOS or Linux. There's no "install these five tools in this order" setup guide. There's no "works on my machine" debugging. A new contributor clones the repo, enters the Nix shell, and `cargo xtask build` works on the first try.

This matters more than it might seem. Embedded toolchains are notoriously fragile — the wrong version of ARM GCC, a missing `rust-src` component, an outdated `probe-rs` — any of these can produce confusing failures. Nix eliminates the entire category. The toolchain is reproducible, and it's pinned to versions known to work together.

The `rust-toolchain.toml` pins the nightly channel and requests `rust-src` (needed for `-Zbuild-std` builds) and `llvm-tools` (for `llvm-objcopy` binary format conversion). Nix reads this file and provisions the matching toolchain automatically.

## The Prelude: Taming Import Complexity

DC Mini's application crate imports from the BSP (resource types, board struct), the ICD (protocol types, endpoint definitions), Embassy's sync primitives (mutexes, channels), the bus manager (handle types), and its own task modules (managers, events). Without structure, every file starts with 15 lines of `use` statements, and adding a new module means figuring out which of six crates provides the type you need.

The prelude module consolidates the commonly-needed imports into a single re-export. Every module in the application opens with `use crate::prelude::*` and gets access to BSP resource types, ICD data types, Embassy sync primitives, logging macros, timer utilities, and the event system — all in one line.

The prelude is deliberately curated, not a blanket re-export of everything. It includes types that genuinely appear across most of the application: the event sender/receiver, the manager types, the resource structs, `Mutex`, `Timer`, `Duration`, `Spawner`. Internal implementation details stay in their own modules.

The ICD crate gets a namespace alias (`pub use dc_mini_icd::{self as icd, *}`) so you can write either `AdsConfig` (via the glob import) or `icd::AdsConfig` (via the alias) depending on whether context makes the type ambiguous. This small detail saves a surprising amount of cognitive overhead when a module works with both driver-level and protocol-level config types.

## Compile-Time Constants and Feature Propagation

Version information is injected at build time via environment variables — `HW_VERSION` and `FW_VERSION` are `env!()` constants baked into the binary. The BLE device information service and USB device descriptor both read from these constants, so version strings are consistent across transports without runtime coordination.

The `defmt` feature flag for structured logging propagates through the entire dependency tree. Every `derive(defmt::Format)` in the codebase is gated behind `#[cfg_attr(feature = "defmt", ...)]`. During development, you build with `defmt` enabled and get rich structured logging via RTT. For production, you drop the feature and save flash space. The application logic is identical either way — the conditional compilation only affects logging output.

This kind of deep feature propagation is tedious to set up initially, but it pays off. A production binary without `defmt` is measurably smaller, and you never accidentally ship debug logging to a deployed device.

## Series Wrap-Up

Over these seven posts, we've walked through DC Mini's firmware architecture:

1. **[Architecture Overview](/posts/dc-mini-part-1-firmware-architecture)** — the three-crate split and async-everywhere design
2. **[Typed Resource Bundles](/posts/dc-mini-part-2-typed-resource-bundles)** — compile-time pin allocation and feature-gated hardware revisions
3. **[The Bus Manager](/posts/dc-mini-part-3-bus-manager)** — power-aware peripheral sharing without a heap
4. **[Event-Driven Orchestration](/posts/dc-mini-part-4-event-driven-orchestration)** — inversion of control with a central event bus
5. **[One Protocol, Two Transports](/posts/dc-mini-part-5-one-protocol-two-transports)** — shared RPC definitions over USB and BLE
6. **[Executors, DFU, and Neopixel](/posts/dc-mini-part-6-executors-dfu-neopixel)** — multi-priority scheduling, watchdog-protected updates, and PWM-driven LEDs
7. **Developer Ergonomics** — xtask, Nix, and the prelude

The common thread is using Rust's type system and zero-cost abstractions to solve problems that traditionally require runtime checks, manual coordination, or external tooling. Embedded Rust is still a young ecosystem, but the patterns are maturing quickly. Building real hardware with it — hardware that's used in sleep research, deployed on subjects overnight, and expected to just work — has been a forcing function for finding out which patterns hold up under pressure.

The firmware is open source at [dcmini-org/dcmini-fw](https://github.com/dcmini-org/dcmini-fw). If any of these patterns are useful for your project, take what you need.
