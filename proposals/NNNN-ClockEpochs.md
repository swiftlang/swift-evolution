# Clock Epochs

* Proposal: [SE-NNNN](NNNN-ClockEpochs.md)
* Authors: [Philippe Hausler](https://github.com/phausler)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: 

* Previous Proposal: *if applicable* [SE-0329](0329-clock-instant-duration.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-suspendingclock-and-continuousclock-epochs/78017))

## Introduction

[The proposal for Clock, Instant and Duration](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0329-clock-instant-duration.md) brought in two primary clock types: `SuspendingClock` and `ContinuousClock`. These both have a concept of a reference point for their `Instant` types.

## Motivation

Not all clocks have a starting point, however in these cases they do. Generally, it cannot required for a clock's instant definition to have a start or the start may not be a fixed point. However it can be useful that a given instant can be constructed to determine the elapsed duration from the starting point of that clock if it does have it.

## Proposed solution

Two new properties will be added, one to `SuspendingClock` and another to `ContinuousClock`. Both of these properties will be the epoch for which all `Instant` types are derived from; practically speaking this is the "zero" point for these clocks. Since the values may be relative to the particular system they are being used on (albeit many may implement them literally as zero) they are named in accordance to reflect that they are designed to be representative of the system's sense of an epoch and should not be expected to be serializable across systems.

## Detailed design

```swift
extension ContinousClock {
    public var systemEpoch: Instant { get }
}

extension SuspendingClock {
    public var systemEpoch: Instant { get }
}
```

These can be used to gather information like for example the uptime of a system, or the active time of a system;

```swift
let clock = ContinousClock()
let uptime = clock.now - clock.systemEpoch
```

Or likewise;

```swift
let clock = SuspendingClock()
let activeTime = clock.now - clock.systemEpoch
```

## ABI compatibility

This is a purely additive change and provides no direct impact to existing ABI. It only carries the ABI impact of new properties being added to an existing type.

## Alternatives considered

It was considered to add a constructor or static member to the `SuspendingClock.Instant` and `ContinousClock.Instant` however the home on the clock itself provides a more discoverable and nameable location.

It is suggested that this be used as an informal protocol for other clocks. It was considered as an additional protocol but that was ultimately rejected because no generic function made much sense that would not be better served with generic specialization or explicit clock parameter types.