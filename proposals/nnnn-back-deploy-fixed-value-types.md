# Back-deployment for fixed-layout value types

* Proposal: [SE-NNNN](nnnn-back-deploy-fixed-value-types.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: <https://github.com/swiftlang/swift/pull/93430>
* Experimental Feature Flag: `BackDeployFrozenValueTypes`
* Review: ([pitch](https://forums.swift.org/t/pitch-back-deployment-for-fixed-layout-value-types-3571/90446))

## Summary of changes

[SE-0376](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0376-function-back-deployment.md) introduced the `@backDeployed(before:)` attribute to enable the back-deployment of functions. This proposal extends the `@backDeployed(before:)` attribute to a narrowly-defined set of types: `struct` and `enum` types that are `@frozen` and have fixed layouts.

## Motivation

The motivation of this proposal exactly follows that of SE-0376: `@backDeployed(before:)` makes it possible for new APIs to become available in earlier OS versions for platforms that provide ABI stability with library evolution, which brings the benefits of new Swift standard library features to more programs. SE-0376 was limited to back-deploying functions because that's all that the implementation could support at the time. Back-deploying types is mentioned as a [future direction](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0376-function-back-deployment.md#back-deployment-for-other-kinds-of-declarations), although it was unclear at the time whether they could be implemented. It's still desirable to back-deploy types, especially those like [`Span`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md), [`Ref`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0519-ref-mutableref-types.md), and [`Cell`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0556-cell.md).

## Proposed solution

This proposal extends `@backDeployed(before:)` to a very limited set of types: `struct` and `enum` types (whether generic or not) that are `@frozen` and whose layouts are known statically (e.g., because they only depend on other `@frozen`) types. While this is very restrictive, it applies to a significant number of important types in the standard library:

- Span family:
  - `Span`
  - `RawSpan`
  - `MutableSpan`
  - `MutableRawSpan`
  - `OutputSpan`
  - `OutputRawSpan`
  - `ByteOrder`
- Ref family
  - `Ref` (only back-deployable to Swift 6.2-era runtimes)
  - `MutableRef`
- Cell family (still under review)
  - `Cell`
  - `ConstCell`
  - `Volatile`
- `UInt128` and `Int128`
- Unique (non-copyable) types
  - `UniqueArray`
  - `UniqueBox`
- Synchronization
  - `Mutex`
  - `Disconnected`
- Concurrency
  - `Continuation`
  - `TaskID`

There is an additional limitation on conformances for back-deployed types. Specifically, a conformance for a back-deployed type must meet one of the following constraints:

* the conformance has availability at or after when the type was introduced, or
* the protocol is not a resilient protocol, or
* the protocol is in the same module as the type.

This means that if `UniqueArray` is back-deployed, one can make it conform to your own protocol, or a protocol from a non-resilient library (e.g., anything built from a Swift package or as part of the program). However, one could not make it retroactively conform to another type from the standard library without given the conformance new-enough availability:

```swift
// error: conformance of back-deployed type 'Point' to protocol 'CustomStringConvertible' must not be
// available before <version where UniqueArray was introduced>
extension UniqueArray: @retroactive CustomStringConvertible { ... }
```

## Source compatibility

This proposal is a pure extension of an existing attribute, so it has no source-compatibility impact on existing code. 

For the handful of types in the standard library that were back-deployed via the `libswiftCompatibilitySpan.dylib` approach (i.e., `(Mutable)(Raw)Span` and `Output(Raw)Span`), adopting this attribute could end up rejecting some previously-accepted code due to the rules of protocol conformances. The following protocol conformance would previously have been accepted, but will be rejected with this proposal and it's adoption for `Span`:

```swift
extension Span: @retroactive CustomStringConvertible { ... }
```

## ABI compatibility

A resilient type that meets the requirements of this proposal that shipped in a given OS version X.Y can adopt `@backDeployed(before: OS X.Y)` and provide earlier availability. This is an ABI-compatible change. Existing clients that make use of the type on OS version >= X.Y will continue to work the same way they always have. Clients that use the type on an earlier OS version will have a copy of the type's metadata emitted statically into them.

## Alternatives considered

### Continue using embedded shared libraries for back-deployment

Prior implementations of back deployment for types or runtime behavior have required a shared library to be embedded in applications running on older OS versions. For example, Swift Concurrency back-deployment bundled `libswift_Concurrency.dylib`, while the `Span` family's back-deployment bundled `libswiftCompatibilitySpan.dylib`. This approach is technically very complicated, and does not work well for standalone binaries such as command-line applications. However, it does allow for back-deploying essentially anything that can be made to work on an older OS version.

The proposed `@backDeployed(before:)` extension is more limited but far easier to deploy: it only affects how code is generated, and everything the program needs to run on an older OS is part of the same binary. There is a higher cost to code size (due to redundant type and conformance metadata) as well, although the types we actually wish to back deploy tend to be very simple.

## Acknowledgments

The critical insight about using the foreign metadata and witness table uniquing mechanism in existing Swift runtimes came from a discussion with Allan Shortlidge. Prior to that, we had not found a way to enable any back-deployment of types without embedding shared libraries in a program or modifing the Swift runtime.
