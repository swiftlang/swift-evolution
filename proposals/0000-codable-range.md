# Add Codable conformance to Range types

* Proposal: [SE-NNNN](NNNN-codable-range.md)
* Authors: [Dale Buckley](https://github.com/dlbuckley)
* Review Manager: TBD
* Implementation: [apple/swift#19532](https://github.com/apple/swift/pull/19532)
* Status: **Awaiting review**

## Introduction

[SE-0167](0167-swift-encoders.md) introduced `Codable` conformance for some types in the standard
library, but not the `Range` family of types. This proposal adds that
conformance.

Swift-evolution thread: [Range conform to Codable](https://forums.swift.org/t/range-conform-to-codable/15552)

## Motivation

`Range` is a very useful type to have conform to `Codable`. A good usage example is a range being sent to/from a client/server to convey a range of time using `Date`, or a safe operating temperature range using `Measurement<UnitTemperature>`.

## Proposed solution

The following Standard Library range types will gain `Codable` conformance
when their `Bound` is also `Codable`:

 * `Range`
 * `ClosedRange`
 * `PartialRangeFrom`
 * `PartialRangeThrough`
 * `PartialRangeUpTo`

## Effect on ABI stability, resilience, and source stability

This is a purely additive change, and so has no impact.

## Alternatives considered

None

