---
title: 'DC Mini Part 1: Designing Firmware for a Wearable EEG'
description: 'A look at the architecture behind DC Mini — an open-hardware 16-channel EEG wearable built with Rust, embassy-rs, and a three-crate firmware design.'
pubDate: 2026-01-13
tags: ['rust', 'embedded', 'eeg', 'open-source']
---

[DC Mini](https://github.com/dcmini-org/dcmini-fw) is a miniaturized biopotential amplifier and multisensor suite developed at Johns Hopkins APL. It packs 16 channels of DC-coupled EEG (via dual ADS1299s), a 6-DoF IMU, ambient light sensor, PDM microphone, haptic driver, and power management into a wearable form factor — all driven by an nRF52840.

I'm the sole firmware developer on the project. The firmware is written entirely in Rust, targeting `no_std` on a Cortex-M4F, and built on top of [embassy-rs](https://embassy.dev/) for async/await concurrency. This post walks through the architecture and some of the design decisions that shaped it.

## Three Crates, Clear Boundaries

The firmware is split into three crates that map to distinct responsibilities:

**dc-mini-bsp** — the board support package. It owns every pin mapping and peripheral initialization for a given hardware revision. A `DCMini` struct hands out typed resource bundles (`AdsResources`, `ImuResources`, `SdCardResources`, etc.) so the application layer never touches raw pins. Hardware revisions are gated at compile time with features like `sr6`, so swapping a board revision means changing a flag, not hunting through application code.

**dc-mini-boot** — the bootloader. It manages firmware updates using embassy-boot with a dual-bank strategy: new firmware is staged to external QSPI flash, and a watchdog ensures automatic rollback if the new image fails to boot within five seconds. The bootloader itself is intentionally minimal — around 70 lines.

**dc-mini-app** — the application. This is where sensor tasks, communication protocols, and orchestration logic live. It's the largest crate by far, but it's organized around independent async tasks that communicate through channels and signals.

This separation keeps hardware details out of application logic, makes the bootloader auditable at a glance, and lets the BSP evolve independently as new board revisions come in.

## Async Everywhere with Embassy

Embassy gives us cooperative multitasking through Rust's `async`/`await`, which is a natural fit for a device that's polling multiple sensors, handling button input, managing BLE advertising, and streaming data over USB — all concurrently.

We use a multi-priority executor setup with interrupt-driven task runners at different priority levels. High-priority interrupts handle time-sensitive sensor acquisition, while lower-priority executors handle things like BLE housekeeping and USB RPC serving. This is all zero-allocation — no RTOS, no heap-based task spawning.

## Sharing Buses Without `static mut`

Multiple peripherals (the IMU, ambient light sensor, haptic driver, and power manager) all sit on the same I2C bus. In embedded Rust, sharing a bus safely is a classic pain point.

We solved this with a custom `bus-manager` crate that provides lazy initialization and reference counting for shared peripherals — all without heap allocation. A `BusFactory` trait creates the underlying peripheral on first use and hands out lightweight RAII handles. When all handles have been dropped and the bus is no longer needed, the manager can explicitly tear it down and recover the original pin resources — a power management hook that lets us deconfigure idle peripherals on a battery-powered wearable.

## Event-Driven Orchestration

Rather than a monolithic main loop, the application is built around a central event channel for command and control. Sensor tasks, button handlers, and communication interfaces all emit events into a shared channel, and an `orchestrate` task dispatches them. This keeps individual tasks decoupled — the ADS streaming task doesn't need to know about session recording, and the BLE stack doesn't need to know about haptic feedback.

Sensor data flows through a separate path: typed `PubSubChannel`s with multiple subscribers. EEG samples from the ADS1299 are published as `Arc<Vec<AdsData, 2>>` to a channel with three subscriber slots — one for USB streaming, one for BLE, and one for SD card recording. The `Arc` wrapper gives us zero-copy sharing across async task boundaries without a full allocator. This separation means the command event bus handles low-frequency control flow (button presses, config changes, state transitions) while the data channels handle high-throughput sensor streaming without contention.

## Dual Transport, Single Interface

DC Mini supports both USB and BLE for host communication, and both use the same RPC interface defined in a shared `dc-mini-icd` crate. Endpoints for configuring the ADS, starting/stopping streams, reading battery level, managing sensor profiles, and performing firmware updates are identical regardless of transport.

The RPC layer uses [postcard-rpc](https://github.com/jamesmunns/postcard-rpc) for serialization and [prost](https://github.com/tokio-rs/prost) for protobuf message definitions. This means the host-side tooling (both a Rust client and a Python client) can work interchangeably over USB or BLE without protocol translation.

## Power-Conscious by Design

Wearable firmware has to think about power at every layer. The BSP controls a dedicated 5V enable pin for the analog frontend, LDO rails are configured to specific voltages for the ADS1299, and the NPM1300 power manager handles battery charging with temperature-aware termination. Peripherals are initialized lazily — the bus manager only spins up I2C when something actually needs it, and can tear it down when the last consumer is done.

## Reproducible Builds with Nix

The development environment is defined in a `flake.nix` that pins the Rust nightly toolchain, cross-compilation targets, probe-rs for flashing, and development tools like cargo-bloat and bacon. `nix develop` gives any contributor an identical environment regardless of their host OS. No setup docs to go stale.

## What's Next

DC Mini is actively being used in sleep research — our recent [StARS DCM paper](https://arxiv.org/abs/2506.03442) demonstrates real-time sleep stage decoding from a forehead-mounted EEG patch using this hardware. On the firmware side, there's always more to do: improving power profiling, expanding the BLE protocol, and continuing to refine the sensor pipeline as new hardware revisions come in.

The firmware is open source — take a look at [dcmini-org/dcmini-fw](https://github.com/dcmini-org/dcmini-fw) if you're interested in embedded Rust, async on microcontrollers, or wearable biosensing.

*This is the first in a seven-part series. [Part 2](/posts/dc-mini-part-2-typed-resource-bundles) digs into the BSP's typed resource bundle pattern and how we use Rust's type system to prevent pin misassignment at compile time.*
