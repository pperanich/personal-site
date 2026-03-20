---
title: "DC Mini Part 2: Typed Resource Bundles and the BSP Pattern"
description: "How DC Mini uses Rust's type system to enforce pin allocation at compile time, preventing an entire class of embedded bugs."
pubDate: 2026-01-20
tags: ['rust', 'embedded', 'eeg', 'open-source', 'embassy']
---

In [Part 1](/posts/dc-mini-part-1-firmware-architecture) I gave an overview of DC Mini's three-crate firmware architecture. This post digs into the BSP (board support package) layer — specifically, how we use Rust's type system to make pin misassignment a compile-time error rather than a runtime mystery.

## The Problem: Peripheral Soup

When you initialize an nRF52840 with Embassy, you get back a struct containing every peripheral on the chip — dozens of GPIO pins, SPI and I2C controllers, timers, PWM channels, and more. The naive approach is to pass these raw peripherals directly into your application code and wire them up where needed.

This works for a blinky demo, but DC Mini has dual ADS1299 analog frontends on SPI3, an ICM-45605 IMU and DRV260x haptic driver sharing I2C, a QSPI external flash, an SD card on a separate SPI bus, a PDM microphone, and a Neopixel status LED on a PWM channel. Scatter raw pin assignments across the application and you end up with the embedded equivalent of magic numbers — `P0_14` shows up in a sensor init, and you have to trace back to the schematic to figure out whether that's MISO or DRDY.

Worse, nothing stops you from accidentally passing the IMU's interrupt pin to the ADS driver. It's the wrong pin, but it's the right *type* — just another GPIO. The firmware compiles, flashes, and silently doesn't work.

## Pins with Purpose

The BSP solves this by defining typed structs that group related pins into logical bundles:

```rust
pub struct AdsResources {
    pub pwdn:  Peri<'static, peripherals::P0_24>,
    pub reset: Peri<'static, peripherals::P0_17>,
    pub start: Peri<'static, peripherals::P0_15>,
    pub cs1:   Peri<'static, peripherals::P0_16>,
    pub cs2:   Peri<'static, peripherals::P0_18>,
    pub drdy:  Peri<'static, peripherals::P0_28>,
}
```

`AdsResources` contains exactly the six pins needed for the dual ADS1299 frontend. `Twim1BusResources` bundles the I2C controller with its SDA and SCL lines. `MicResources` wraps the PDM peripheral with its clock and data pins.

Each field is typed to a *specific* pin — not a generic GPIO, but `Peri<'static, P0_28>`. You physically cannot pass the wrong pin because the types won't match. This is zero-cost: the pin types are zero-sized, so the struct is effectively a compile-time manifest of the wiring.

## One Struct, One Source of Truth

All resource bundles flow through a single `DCMini` struct that represents the entire board. Its constructor calls `embassy_nrf::init()` once and distributes every peripheral into the appropriate bundle. This is the only place in the codebase where raw pin numbers appear.

The application code in `main()` receives a `DCMini`, destructures it, and hands resource bundles to the subsystems that need them. The ADS manager gets `AdsResources` and `Spi3BusResources`. The IMU manager gets `ImuResources` and access to the I2C bus manager. The microphone task gets `MicResources`. Nobody gets more than they need, and nobody can touch pins they shouldn't.

This makes code review straightforward. When a new board revision changes a pin assignment, the diff is a single file — the board module. Application code is untouched.

## Initialization Sequences Belong to Resources

Resource bundles aren't just storage containers — they carry initialization logic. The ADS1299 requires a specific power-on and reset sequence with precise nanosecond timing before you can communicate with it over SPI. Rather than expecting every caller to know this ritual, the `AdsResources` struct has a `configure()` method that performs the full sequence and returns a ready-to-use `PoweredAdsFrontend`.

The method takes `&mut self` and uses Embassy's `reborrow()` to hand out sub-borrows of each pin to the driver. The caller can't skip the initialization or get the timing wrong — they get back an initialized `PoweredAdsFrontend` or nothing. Similarly, `MicResources::configure()` sets up the PDM peripheral with the right clock and data pins, and `ExternalFlashResources::configure()` handles the QSPI initialization including the status register dance that the flash chip requires.

This pattern pushes hardware knowledge down into the BSP where it belongs. The application layer works with initialized drivers, not raw peripherals.

## Hardware Revisions as Feature Flags

DC Mini has gone through several board revisions, and the pin mappings change between them. The BSP handles this with Cargo feature flags — `sr6` selects the current revision's board module at compile time.

Each revision is a separate module under `board/` that defines the same set of resource structs with the same fields, but different pin assignments. The application code doesn't use conditional compilation — it just sees `DCMini` and its bundles. Switching to a new board revision means changing one feature flag in the build command, not auditing the entire codebase for hardcoded pin numbers.

## Compile-Time Transport Selection

The same feature-flag approach extends to communication transports. The `DCMini` struct conditionally includes a `BleControllerBuilder` when the `trouble` feature is enabled, and a `UsbDriverBuilder` when `usb` is enabled. In `main()`, transport tasks are spawned behind `#[cfg(feature = "...")]` gates.

This means the linker only includes the code for transports you actually build. A USB-only firmware doesn't carry BLE stack code, and vice versa. The `trouble` and `critical-section` features are enforced as mutually exclusive with a `compile_error!` — a compile-time guard that prevents known-incompatible configurations from even building.

## What This Gets Us

The typed resource bundle pattern prevents three categories of bugs entirely:

**Pin misassignment** — using the wrong GPIO for a peripheral. The types don't match, so it won't compile. This catches wiring bugs before they ever reach hardware.

**Double-use** — accidentally assigning the same pin to two peripherals. Embassy's `Peri` type is move-only. Once you hand a pin to a resource bundle, it's consumed. The second user won't have access.

**Initialization ordering** — forgetting the required power-on sequence or reset timing for a peripheral. The `configure()` methods encapsulate these sequences. You get back an initialized driver or nothing.

These aren't theoretical wins. On a board with 40+ GPIO pins and 8 different peripherals, wiring bugs are the most common class of "it compiles but doesn't work" issues. Moving them to compile time saves hours of oscilloscope debugging.

Next up in [Part 3](/posts/dc-mini-part-3-bus-manager), we'll look at how the bus manager crate builds on this foundation to share I2C and SPI buses across async tasks with automatic lifecycle management.
