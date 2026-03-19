---
title: 'DC Mini Part 4: Event-Driven Orchestration with derive(From)'
description: 'How DC Mini uses a central event bus and inversion of control to keep async sensor tasks decoupled — and why adding a new sensor is just a match arm.'
pubDate: 2026-02-03
tags: ['rust', 'embedded', 'eeg', 'open-source', 'async', 'embassy']
---

In [Part 3](/blog/dc-mini-part-3-bus-manager) we built a bus manager for shared peripherals. Now we need to coordinate the tasks that use them. DC Mini has a lot going on simultaneously: streaming EEG from dual ADS1299s, polling an IMU, managing BLE connections, handling button presses, recording to an SD card, and driving a status LED. Each of these is an independent async task, but they need to interact — a double button press should trigger a manual event marker in the EEG recording, a long hold should power down the device, and a BLE config write should reconfigure the analog frontend.

This post covers our event-driven orchestration pattern — a simple but effective approach that keeps tasks decoupled while making the system's behavior trivially auditable.

## Why Not a Monolithic Main Loop?

The classic embedded approach is a big `loop` with interleaved state machine logic: check if the ADC has data ready, check if a button was pressed, check if there's a BLE event, update the LED, repeat. This works for simple firmware, but it creates implicit coupling. The button handler needs to import the ADS module to trigger recording. The BLE stack needs to know about the haptic driver to provide feedback on connection. Every new feature reaches into every other feature.

The alternative — having tasks call each other directly through function pointers or trait objects — trades compile-time coupling for runtime complexity and makes the control flow harder to trace.

## A Central Event Bus

DC Mini takes a different approach: every subsystem communicates through a single typed event channel. Each subsystem defines its own event enum (`AdsEvent`, `ImuEvent`, `ButtonPress`, `HapticEvent`, etc.), and a top-level `Event` enum wraps them all:

```rust
#[derive(Debug, From)]
pub enum Event {
    AdsEvent(AdsEvent),
    ApdsEvent(ApdsEvent),
    SessionEvent(SessionEvent),
    ButtonPress(ButtonPress),
    ImuEvent(ImuEvent),
    MicEvent(MicEvent),
    HapticEvent(HapticEvent),
    PowerEvent(PowerEvent),
    DfuEvent(DfuEvent),
}
```

The key ingredient is `#[derive(From)]` from the `derive_more` crate. This generates `From<AdsEvent> for Event`, `From<ButtonPress> for Event`, and so on for every variant. Any task that holds an `EventSender` can emit a domain-specific event with `.into()`, without importing or knowing about the central `Event` type. The button task sends `ButtonPress::Double.into()`. The BLE task sends `AdsEvent::ConfigChanged.into()`. The conversion is zero-cost — no allocation, no dynamic dispatch, just an enum variant wrapping.

## The Orchestrator

A single `orchestrate` task sits at the other end of the channel. It receives events and dispatches them to the appropriate manager via a `match` statement. This is the entire control flow of the application — you can read it top to bottom and understand what happens for every possible input.

The orchestrator is where cross-cutting behavior becomes explicit. A double button press dispatches to `AdsManager::handle_event(AdsEvent::ManualRecord)` — this mapping is visible in one place, not buried in button debouncing code that somehow imports the ADS module. A long button hold sends a power-off event to the Neopixel. A DFU event gets logged. The relationships between subsystems are all right here, in one match expression.

Each manager owns its own complexity internally. `AdsManager` can manage streaming state, configure the SPI bus, and coordinate with the data pipeline. The orchestrator doesn't care about any of that — it just dispatches the event and moves on.

## Adding a New Sensor Is Mechanical

When we added the PDM microphone, the changes were:

1. Define `MicEvent` in the mic task module
2. Add `MicEvent(MicEvent)` to the `Event` enum (the `derive(From)` does the rest)
3. Create a `MicManager` with a `handle_event()` method
4. Add one parameter and one match arm to the orchestrator

No existing code changed. No cross-cutting concerns to audit. The orchestrator grew by two lines. This is the payoff of inversion of control — subsystems don't call each other, they emit events and the orchestrator decides what happens.

## The Channel

The event channel is Embassy's `Channel` — a bounded async MPMC channel backed by a statically-allocated buffer. The sender is cloneable and gets distributed to every task that needs to emit events. The single receiver goes to the orchestrator.

The capacity is set to 10 events. If the channel fills up, senders `.await` until there's room. In practice this hasn't been an issue — events are small (just enum variants), and the orchestrator processes them faster than they arrive. But it's worth knowing the back-pressure exists: a handler that blocks for too long will eventually stall event producers.

## The AppContext: Shared State Without Global Mutables

Tasks often need more than their own resources. They need to read sensor configurations from flash, spawn subtasks at specific priorities, or emit events back into the channel. DC Mini bundles this shared state into an `AppContext` struct that holds the three executor spawners (high, medium, low priority), the event sender, a profile manager for persistent configuration, and runtime state like battery voltage and recording status.

The `AppContext` lives in a `StaticCell<Mutex<...>>` and is shared by reference across all managers. When a manager needs to save a configuration change, it locks the context, writes to flash through the profile manager, and then emits a `ConfigChanged` event through the sender. The configuration change propagates through the same event channel — the orchestrator dispatches it to the relevant manager, which reconfigures the hardware. The system is self-consistent: configuration flows through the same path as every other state change.

## Events vs. Data Streams

It's worth noting what the event bus *doesn't* carry: sensor data. EEG samples, IMU readings, and microphone audio flow through a separate system of `PubSubChannel`s — broadcast channels where a single producer publishes to multiple subscribers. The ADS task publishes `Arc<Vec<AdsData, 2>>` to a channel with three slots: USB streaming, BLE streaming, and SD card recording. Each consumer subscribes independently and processes data at its own pace.

This separation is deliberate. The event bus handles low-frequency control flow — button presses, config changes, state transitions — where sequential dispatch is fine. Sensor data arrives at 250-16,000 samples per second and needs to fan out to multiple consumers simultaneously. Mixing them into one channel would either starve control events behind a wall of samples, or force the data pipeline through a bottleneck it doesn't need.

## Trade-Offs

This pattern isn't universal. The single orchestrator processes events sequentially, so a slow handler delays everything behind it. In practice, handlers should delegate heavy work (like spawning a streaming task) rather than doing it inline. The bounded channel means senders can back-pressure, which is actually desirable — it's natural flow control, but it could be surprising if you're not expecting it.

The biggest constraint is that all event types must be known at compile time. You can't dynamically register new event sources at runtime. For a wearable with a fixed set of peripherals, this is a feature — it gives you exhaustive `match` checking and zero dynamic dispatch. But it does mean every new event type requires touching the enum definition and the orchestrator.

For DC Mini, these trade-offs are the right ones. The firmware has a fixed, known set of sensors and actuators. The event flow is predictable and auditable. And the cognitive load of working in the codebase is dramatically lower than it would be with direct inter-task coupling — you can understand any subsystem in isolation, and you can understand the full system behavior by reading one match statement.

In [Part 5](/blog/dc-mini-part-5-one-protocol-two-transports), we'll look at how the same RPC protocol definition serves both USB and BLE without duplication.
