# Clock Epochs

* Proposal: [SE-NNNN](NNNN-clock-epochs.md)
* Authors: [Philippe Hausler](https://github.com/phausler)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Awaiting implementation**
* Implementation: 
* Review: ([pitch](https://forums.swift.org/t/pitch-suspendingclock-and-continuousclock-epochs/78017))

## Introduction

[SE-0329: Clock, Instant, and Duration](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0329-clock-instant-duration.md) introduced three concrete clock types: `SuspendingClock`, `ContinuousClock`, and `UTCClock`. While not all clocks have a meaningful concept of a reference or zero instant, `SuspendingClock` and `ContinuousClock` do, and having access to it can be useful.

## Motivation

The `Instant` type of a `Clock` represents a moment in time as measured by that clock. `Clock` intentionally imposes very few requirements on `Instant` because different kinds of clocks can have very different characteristics. Just because something does not belong on the generic `Clock` protocol, however, does not mean it shouldn't be exposed in the interface of a concrete clock type.

Many clocks have a concept of a reference instant, also called an "epoch", that has special meaning for the clock. For example, the Unix `gettimeofday` function measures the nominal elapsed time since 00:00 UTC on January 1st, 1970, an instant often called the "Unix epoch". Swift's `SuspendingClock` and `ContinuousClock` are defined using system facilities that similarly measure time relative to an epoch, and while the exact definition of the epoch is system-specific, it is at least consistent for any given system. This means that durations since the epoch can be meaningfully compared within the system, even with code in other processes or written in other languages (as long as it uses the same system facilities).

## Proposed solution

Two new properties will be added, one to `SuspendingClock` and another to `ContinuousClock`. These properties define the system epoch that all `Instant` types for the clock are derived from; practically speaking, this is the "zero" point for these clocks. Since the values may be relative to the particular system they are being used on, their names reflect that they are representative of the system's sense of an epoch and should not be expected to be meaningfully comparable (or serializable) across systems.

## Detailed design

```swift
extension ContinuousClock {
    public var systemEpoch: Instant { get }
}

extension SuspendingClock {
    public var systemEpoch: Instant { get }
}
```

On both Darwin and Linux, the system epochs of these clocks is set at boot time, and so measurements relative to the epoch can used to gather information such as the uptime or active time of a system:

```swift
let clock = ContinousClock()
let uptime = clock.now - clock.systemEpoch
```

Likewise:

```swift
let clock = SuspendingClock()
let activeTime = clock.now - clock.systemEpoch
```

Swift will make an effort to maintain this property on other supported systems when possible. However, it cannot be guaranteed for all systems, such as when the concept of uptime either doesn't apply or is intentionally not exposed to the programming environment for privacy reasons.

## ABI compatibility

This is a purely additive change and provides no direct impact to existing ABI. It only carries the ABI impact of new properties being added to an existing type.

## Alternatives considered

We considered adding a constructor or static member to `SuspendingClock.Instant` and `ContinousClock.Instant` instead of on the clock. However, placing it on the clock itself provides a more discoverable and nameable location.

As proposed, `systemEpoch` is an informal protocol that works across multiple clock implementations. We consider formalizing it as a new protocol, but ultimately we decided not to because no generic function made much sense that would not be better served with generic specialization or explicit clock parameter types.
