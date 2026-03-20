---
title: 'DC Mini Part 6: Multi-Priority Executors, DFU, and a PWM Neopixel'
description: 'Interrupt-driven task prioritization with embassy, a watchdog-protected dual-bank bootloader, and driving WS2812 LEDs with DMA — the infrastructure glue of DC Mini.'
pubDate: 2026-02-17
tags: ['rust', 'embedded', 'eeg', 'open-source', 'embassy', 'dfu', 'neopixel']
---

In [Part 5](/posts/dc-mini-part-5-one-protocol-two-transports) we covered how DC Mini serves the same RPC protocol over USB and BLE. This post covers three pieces of infrastructure that tie the system together: multi-priority task execution, firmware updates with automatic rollback, and a custom Neopixel driver.

They're different problems, but they share a design philosophy: use hardware features to avoid software complexity.

## Three-Tier Task Priorities

Embassy's default executor runs all tasks cooperatively at a single priority level. Every task yields at `.await` points, and the executor picks the next ready task. This is fine for many applications, but DC Mini has hard real-time requirements on some paths. When the ADS1299 asserts its data-ready line, the SPI read needs to happen within microseconds — not after the BLE stack finishes processing a connection event or the USB driver completes a bulk transfer.

The solution is multiple executors running at different interrupt priority levels. The nRF52840's nested interrupt controller (NVIC) supports preemption: a higher-priority interrupt can interrupt a lower-priority one mid-execution. Embassy's `InterruptExecutor` leverages this — each executor is driven by a software interrupt (EGU peripheral), and tasks running on a higher-priority executor can preempt tasks on a lower one.

DC Mini uses three tiers:

**High priority (P6)** handles time-sensitive sensor acquisition. When the ADS1299's DRDY fires, the SPI read task runs here and preempts everything else. Jitter on this path directly affects EEG signal quality.

**Medium priority (P7)** handles BLE connection events and other moderate-latency work. These can preempt low-priority tasks but yield to sensor reads.

**Low priority (main thread)** handles everything else — the orchestrator, LED animations, SD card writes, USB RPC serving, and general housekeeping.

Within each tier, tasks are still cooperative — they yield to each other at `.await` points. But across tiers, preemption is automatic via the NVIC. This gives us the benefits of priority-based scheduling without an RTOS, without per-task stacks, and without the memory overhead of thread-based designs.

The trick is using EGU (Event Generator Unit) peripherals as the interrupt source. EGUs are software-triggered interrupts — they exist solely to provide interrupt vectors. There's no actual hardware event being generated. Embassy's `InterruptExecutor` hooks into these vectors and polls its task queue whenever the interrupt fires.

Each tier exposes a `SendSpawner` that's stored in the `AppContext`, so any part of the application can spawn work at the appropriate priority level. A manager that needs to start a high-priority sensor read just grabs the high-priority spawner and calls `must_spawn()`.

## The Bootloader: 70 Lines of Watchdog-Protected DFU

`dc-mini-boot` is intentionally the smallest crate in the workspace. Its job is narrow: check if a new firmware image has been staged in external flash, swap it into the active partition if so, and boot the application. It does this in about 70 lines.

The dual-bank strategy works across two storage regions. New firmware is written to external QSPI flash (2MB) via the DFU endpoints — over USB or BLE, the transport doesn't matter. On the next boot, the bootloader uses `embassy-boot` to copy the staged image from external flash into the active partition in internal flash.

The critical safety mechanism is the watchdog timer. The bootloader starts it with a 5-second timeout before loading the application. If the new firmware boots successfully and calls `mark_booted()` within those 5 seconds, the update is confirmed and the watchdog is reconfigured for normal operation. If the firmware crashes, hangs, or takes too long to initialize, the watchdog resets the chip and the bootloader reverts to the previous image.

This means a bad firmware update can never brick the device. The worst case is a reboot cycle: bad image boots, watchdog fires, bootloader reverts, good image boots. The device recovers without human intervention — important for a research device that might be deployed on a sleeping subject.

The bootloader also installs a hard fault handler that triggers an immediate system reset rather than hanging. Combined with the watchdog, any crash during early boot — null pointer dereference, stack overflow, unaligned access — results in recovery rather than a brick.

## mark_booted(): The Critical First Act

The very first thing the application does — before initializing sensors, before starting the BLE stack, before configuring power management — is confirm the boot. It temporarily initializes the QSPI flash and NVMC, calls `mark_booted()`, and then drops both peripherals.

The scoped initialization is deliberate. QSPI and NVMC are needed for `mark_booted()`, but they're also needed later for other purposes: QSPI for DFU staging, NVMC for persistent configuration storage. By initializing them in a block scope and dropping them immediately, the peripherals are freed for their runtime users.

There's a subtlety here: the DFU subsystem and the profile manager both use NVMC, but they write to non-overlapping flash regions. The bootloader state lives at `0x6000..0x7000`, while profile storage lives at `0xFE000..0x100000`. The hardware serializes writes to the same flash controller, so there's no conflict — but it's worth documenting because it's the kind of assumption that would be dangerous to violate silently.

The `WatchdogFlash` wrapper used by the bootloader automatically feeds the watchdog during flash erase and write operations. Flash operations on the nRF52840 can take tens of milliseconds per page — long enough to trip a 5-second watchdog if you're erasing a large region. The wrapper feeds the watchdog between pages, preventing spurious resets during legitimate flash operations.

## WS2812 Neopixel via PWM + DMA

DC Mini has a single WS2812 RGB LED for status indication — breathing patterns for different states, color changes for events. The WS2812 protocol requires precise bit timing: 400ns pulses for '0' bits, 800ns pulses for '1' bits, with a 1.25µs frame period and a 50µs reset.

Bit-banging this from software is fragile on a system with multiple interrupt priorities. A high-priority sensor read could preempt the LED driver mid-bit, stretching a 400ns pulse to 600ns and corrupting the data. Some projects disable interrupts during WS2812 writes, but that's unacceptable when you need microsecond-accurate EEG acquisition.

The `ws2812-nrf-pwm` crate solves this by driving the data line from the PWM peripheral with DMA. Each bit of LED data becomes one PWM cycle: a '0' bit is a short duty cycle (6 out of 20 ticks at 16MHz), a '1' bit is a long duty cycle (13 out of 20 ticks). The entire color payload — 24 bits per pixel in GRB order — is laid out as a buffer of PWM duty-cycle values, and the DMA engine clocks them out.

Once the DMA transfer starts, the CPU is completely uninvolved. The waveform is generated by hardware regardless of what the CPU is doing — it can be servicing a sensor interrupt, processing a BLE event, or sitting in a wait-for-interrupt state. The timing is immune to software jitter.

The crate implements the `SmartLedsWriteAsync` trait from the `smart-leds` ecosystem, so it's a drop-in replacement for any other LED driver. The Neopixel task just converts application state (recording, idle, error, powering down) into colors and writes them through the async interface.

## Hardware Solutions to Software Problems

These three components serve different layers of the system, but they share an approach: offload timing-critical work to hardware.

The multi-priority executor uses the NVIC to provide preemptive scheduling without an RTOS. The bootloader uses the watchdog timer to guarantee rollback without complex health-check logic or recovery partitions. The Neopixel driver uses PWM + DMA to generate microsecond-precision waveforms without disabling interrupts.

Each one replaces a software problem — priority inversion, bricked devices, timing jitter — with a hardware mechanism that's simpler and more reliable. Embedded systems have these peripherals available; it's worth learning to use them.

In [Part 7](/posts/dc-mini-part-7-developer-ergonomics), we'll cover the developer experience: xtask for build orchestration, Nix for reproducible environments, and the prelude pattern for managing imports.
