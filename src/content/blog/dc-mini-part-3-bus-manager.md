---
title: 'DC Mini Part 3: The Bus Manager — Power-Aware Peripheral Sharing Without Alloc'
description: 'Building a generic bus lifecycle manager in no_std Rust that lazily initializes, reference-counts, and tears down shared peripherals — all without a heap.'
pubDate: 2026-01-27
tags: ['rust', 'embedded', 'eeg', 'open-source', 'no_std']
---

In [Part 2](/posts/dc-mini-part-2-typed-resource-bundles) we saw how DC Mini's BSP bundles pins into typed resource structs. But some peripherals need to be shared. The IMU, ambient light sensor, haptic driver, and power manager all sit on the same I2C bus. Four independent async tasks need concurrent access to one physical peripheral — and in a wearable, we want the ability to power it down when nobody's using it.

This post covers the `bus-manager` crate, which provides lazy initialization, atomic reference counting, and explicit teardown for shared bus peripherals — all in `no_std` without a heap allocator.

## Why Not Use What Exists?

The embedded Rust ecosystem has established solutions for bus sharing. `shared-bus` provides `RefCell`-based interior mutability, and `embedded-hal-bus` offers `I2cDevice`/`SpiDevice` wrappers for concurrent access through mutex-protected references.

Both solve the access problem, but neither solves the *lifecycle* problem. Once you create the bus, it lives forever. There's no way to tear it down, recover the underlying pin resources, and power off the physical peripheral. For a wearable running on a small battery, this matters. If no sensor is actively using I2C, the TWIM controller is still configured, still drawing current, and still holding its pins.

We needed three things the existing crates don't provide: lazy creation (don't configure the bus until someone needs it), explicit teardown (recover resources when everyone's done), and resilient initialization (if bus creation fails, don't lose the pin resources).

## The Factory Pattern

The core abstraction is a `BusFactory` trait with four associated types: the `Bus` being shared, the `Resources` needed to create it, a `Destructor` token for recovering resources after teardown, and an `Error` type.

The critical design decision is in the method signatures. `create()` takes ownership of resources and returns the bus plus a destructor token — but on failure, it returns the error *and the original resources*. This means a failed initialization doesn't permanently consume the pins. The caller can log the error and try again later.

`recover()` takes the destructor token and reconstructs the original resources. For DC Mini's I2C bus, this uses `steal()` to reconstruct the peripheral handles — safe because the bus manager guarantees no live references exist when `recover()` is called.

## A Three-Phase State Machine

The `BusManager` struct tracks the bus through three states: `Idle` (resources available, bus not configured), `Active` (bus configured, handles can be issued), and `Poisoned` (unrecoverable error, should never be reached in normal operation).

The bus itself is stored in a `GroundedCell` — a sound abstraction over `MaybeUninit` from the `grounded` crate. It provides a place to write the bus into without heap allocation, and it's safe to read from as long as you uphold the initialization invariant. The state machine enforces this: the cell is only read when in the `Active` phase, and it's only written or dropped under the mutex.

A `Mutex` protects phase transitions, while an `AtomicUsize` tracks the count of live handles. These are deliberately separate. The mutex is only held during state transitions (creation and teardown), not during normal bus access. This means acquiring a handle on an already-active bus is just an atomic increment — no lock contention on the hot path.

## RAII Handles

When a task calls `acquire()`, the manager checks the current phase. If `Idle`, it runs the factory under the mutex, writes the bus into the `GroundedCell`, transitions to `Active`, and returns a handle. If already `Active`, it just bumps the atomic counter and returns a handle immediately.

The `BusHandle` implements `Deref` to the underlying bus, so callers use it transparently — they see a reference to the I2C bus and work with it through Embassy's `I2cDevice` wrapper as usual. When the handle is dropped, it atomically decrements the user count.

The key safety invariant is simple: a live handle implies `users > 0`, and the manager refuses to tear down the bus while `users > 0`. Therefore, the bus is guaranteed to exist for the lifetime of any handle. The handle stores a raw pointer internally, but the lifetime of that pointer is bounded by this invariant.

## Powering Down

When the last consumer is done, the orchestrator can call `try_release()`. This locks the state mutex, checks that the user count is zero, drops the bus in place, calls `recover()` on the destructor token, and transitions back to `Idle` with the original resources restored.

If handles still exist, `try_release()` returns `Err(InUse(n))` with the current count — the caller knows to wait. This is safe by construction: you can't accidentally tear down a bus while someone is mid-transaction.

The recovered resources can be used to recreate the bus later with another `acquire()` call. The full lifecycle — `Idle → Active → Idle → Active` — works for any number of cycles. This is the power management hook: when the last sensor task finishes with I2C, the system can deconfigure the TWIM controller and stop driving the SDA/SCL pins.

## In Practice

For DC Mini's I2C bus, the `Twim1Factory` implementation creates a `Mutex<CriticalSectionRawMutex, twim::Twim<'static>>` from the BSP's `Twim1BusResources`. The bus type is itself a mutex-wrapped peripheral — this lets multiple `I2cDevice` wrappers share it with per-transaction locking, while the bus manager controls the overall lifecycle.

In `main()`, it comes together in three lines:

```rust
let i2c_bus_manager = I2C_BUS_MANAGER.init(
    I2cBusManager::new(board.twim1_bus_resources)
);
let handle = i2c_bus_manager.acquire().await.unwrap();
let npm1300 = NPM1300::new(I2cDevice::new(handle.bus()), Delay);
```

The app-level type aliases (`I2cBusManager`, `I2cBusHandle`) hide the generic parameters. Consumer code doesn't know about `GroundedCell` or `AtomicUsize` — it just acquires a handle and talks to the bus.

## Memory Ordering

One detail worth mentioning: the atomic operations use carefully chosen memory orderings. Stores and decrements use `Release` to ensure bus writes are visible before handles are used, and that all handle operations complete before the decrement is visible to `try_release()`. The user-count check in `try_release()` uses `Acquire` to synchronize with all prior handle drops. The diagnostic `user_count()` method uses `Relaxed` because it's just a best-effort read with no synchronization requirement.

Getting these wrong wouldn't cause data races in the traditional sense (the bus is behind a mutex for actual transactions), but it could cause `try_release()` to see a stale user count and tear down the bus too early. Memory ordering in embedded Rust is less discussed than it should be — there's no operating system providing implicit synchronization barriers.

## What This Enables

The bus manager pattern gives us capabilities that typical embedded bus sharing doesn't. Lazy initialization means the bus isn't created until something needs it — on a device that might boot in a low-power mode without active sensors, this avoids unnecessary peripheral configuration. Power-aware teardown means the bus can be deconfigured when all consumers are done, saving current draw on a battery-powered wearable. And resilient creation means a transient failure (sensor not responding during probe, DMA buffer unavailable) doesn't permanently lose the pin resources.

All without a heap allocator, and with the safety guarantees Rust is known for.

In [Part 4](/posts/dc-mini-part-4-event-driven-orchestration), we'll see how the tasks that use these buses communicate through an event-driven orchestration layer.
