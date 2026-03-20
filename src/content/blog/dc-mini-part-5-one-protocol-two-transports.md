---
title: 'DC Mini Part 5: One Protocol, Two Transports'
description: 'How DC Mini defines its RPC interface once and serves it identically over USB and BLE — with code generation for Python and Rust clients.'
pubDate: 2026-02-10
tags: ['rust', 'embedded', 'eeg', 'open-source', 'ble', 'usb', 'rpc']
---

In [Part 4](/posts/dc-mini-part-4-event-driven-orchestration) we saw how tasks communicate through a central event bus. But the device also needs to talk to the *host* — a laptop running a recording application, a Python research script, or a configuration tool. DC Mini supports both USB and Bluetooth Low Energy for this, and both use the exact same protocol definition.

This post covers how we define the protocol once in a shared crate and serve it over two transports without any duplication.

## The Protocol as a Crate

The protocol lives in `dc-mini-icd` — the Interface Control Document. This crate depends on neither the application nor the BSP. It's pure data definitions: endpoint types, topic types, serialization schemas. It compiles for `no_std` (firmware side), `std` (Rust host tooling), or generates Python classes via protobuf codegen.

The protocol is defined declaratively using macros from [`postcard-rpc`](https://github.com/jamesmunns/postcard-rpc):

```rust
endpoints! {
    | EndpointTy              | RequestTy     | ResponseTy    | Path             |
    | AdsStartEndpoint        | ()            | AdsConfig     | "ads/start"      |
    | AdsSetConfigEndpoint    | AdsConfig     | bool          | "ads/set_config" |
    | BatteryGetLevelEndpoint | ()            | BatteryLevel  | "battery/level"  |
    | DfuBeginEndpoint        | DfuBegin      | DfuResult     | "dfu/begin"      |
    // ... ~20 endpoints total
}

topics! {
    | TopicTy                 | MessageTy     | Path          |
    | AdsTopic                | AdsDataFrame  | "ads/data"    |
    | MicTopic                | MicDataFrame  | "mic/data"    |
}
```

Each row generates a zero-sized type that carries its request type, response type, and path as associated types. The compiler enforces that every handler matches the expected signature. Both transports implement against this same table, and both host clients generate their calls from it.

This table *is* the protocol spec. There's no separate documentation to sync, no hand-written serialization code, and no way for USB and BLE to disagree about what `ads/start` returns.

## Bridging Driver Types to Wire Types

Sensor drivers define their own configuration types — the ADS1299 driver has a `SampleRate` enum with variants like `Sps250`, `KSps4`, etc. These need to cross the wire to the host, but we don't want the ICD depending on specific driver crates.

A `define_config_enum!` macro solves this by generating a parallel enum in the ICD with `Serialize`/`Deserialize` derives and bidirectional `From` conversions to the driver's native type. You list the variant names once, and the macro produces both the wire type and the conversion glue.

If someone adds a variant to the driver enum but forgets to update the ICD, the non-exhaustive match in the generated `From` implementation fails at compile time. Schema drift between the driver and the protocol is a compile error, not a runtime bug.

## Protobuf for High-Throughput Data

Simple configuration types use `postcard` — a compact binary format built on `serde` that's well-suited for small RPC payloads. But for high-throughput sensor data frames (16-channel EEG samples at 1 kSps, microphone audio buffers), we use Protocol Buffers via `prost`.

The `build.rs` in the ICD crate compiles `.proto` files and generates Rust structs (used by both the firmware and the Rust host client) and Python classes (used by the research team's scripts). When the `defmt` feature is enabled, it also adds `defmt::Format` derives to the generated Rust types, so sensor data frames can be logged via RTT during development.

One `.proto` file produces code for three targets: the firmware, the Rust host, and the Python host. The schemas can't diverge because they're generated from the same source. When a researcher adds a field to the EEG data frame for their analysis script, the firmware and Rust host get the matching field automatically.

## USB: postcard-rpc Server

On the USB transport, we use `postcard-rpc`'s server framework. A `define_dispatch!` macro wires up each endpoint from the ICD table to a handler function. The framework handles USB bulk transfer framing, `postcard` serialization, and error reporting. Each handler receives the typed request, accesses shared application state through the `AppContext`, and returns the typed response.

The USB server runs two concurrent tasks: one drives the USB peripheral (handling enumeration, control transfers, and bulk endpoints), and the other runs the postcard-rpc dispatch loop. Embassy's async model makes this natural — both tasks yield at their respective await points without blocking each other.

## BLE: GATT Characteristics

BLE doesn't have built-in request/response framing like USB bulk transfers. Instead, we map the protocol to GATT services and characteristics. Each logical service (ADS control, battery, device info, DFU) becomes a GATT service, and each endpoint becomes a characteristic.

The `trouble-host` crate's `#[gatt_server]` macro defines the service structure. When a BLE client writes to the ADS config characteristic, the BLE task deserializes the payload using the same `postcard` format as USB, applies it through the same `AppContext`, and sends the response as a characteristic notification.

The data types — `AdsConfig`, `BatteryLevel`, `DeviceInfo`, `DfuResult` — are identical on both transports. The ICD crate provides them. The transport layer is just plumbing.

## The Host Sees One Device

From the host's perspective, DC Mini looks the same over either transport. The Rust host client crate (`dc-mini-host`) provides both a `UsbClient` and a `BleClient`, wrapped in a `DeviceConnection` enum — the same typed endpoint calls regardless of transport. A Python binding (`dc-mini-host-py`) currently exposes the USB client; the BLE client is implemented in Rust but hasn't been surfaced to Python yet. Because the underlying Rust library already abstracts over both transports, adding `PyBleClient` is a thin wrapper away.

This pays off in practice. During lab work, the Rust tooling can switch seamlessly between USB for high-bandwidth EEG streaming and BLE for untethered recording. The firmware update process works over either transport — slower over BLE due to the lower MTU, but the same protocol. And because the protocol definition is shared, there's no per-transport quirks to debug.

## DFU Over Both Transports

Firmware updates work through the same protocol. The ICD defines a simple state machine: `DfuBegin` with the firmware size, a sequence of `DfuWriteChunk`s with offset and data, and `DfuFinish` to commit. There's also `DfuAbort` for cancellation and `DfuStatus` for progress polling.

The firmware-side DFU handler writes chunks to external QSPI flash regardless of which transport delivered them. On the next reboot, the bootloader (covered in [Part 6](/posts/dc-mini-part-6-executors-dfu-neopixel)) swaps the image. The host doesn't need to know about flash layouts or bootloader mechanics — it just sends chunks and checks status.

## Why This Architecture

The separate ICD crate enforces a discipline that's easy to lose in embedded projects: the protocol is independent of both the transport and the application logic. Adding a new endpoint means adding a row to the table, implementing the handler, and the type system ensures both transports and all host clients stay in sync.

For a research device that's used by firmware engineers, neuroscience researchers writing Python, and clinicians using desktop tools, this consistency is essential. Everyone is talking to the same protocol, just through different doors.

In [Part 6](/posts/dc-mini-part-6-executors-dfu-neopixel), we'll look at the multi-priority executor setup, the bootloader's dual-bank firmware update strategy, and a PWM-based Neopixel driver.
