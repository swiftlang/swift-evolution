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
- `Duration`
- Unique (non-copyable) types
  - `UniqueArray`
  - `UniqueBox`
- Synchronization
  - `Mutex`
  - `Disconnected`
- Concurrency
  - `Continuation`
  - `TaskID`

## Source compatibility

This proposal is a pure extension of an existing attribute, so it has no source-compatibility impact on existing code. Any types in the standard library that are back-deployed using this feature will now be available in prior releases, which will have no effect on existing code.

## ABI compatibility

A resilient type that meets the requirements of this proposal that shipped in a given OS version X.Y can adopt `@backDeployed(before: OS X.Y)` and provide earlier availability. This is an ABI-compatible change. Existing clients that make use of the type on OS version >= X.Y will continue to work the same way they always have. Clients that use the type on an earlier OS version will have a copy of the type's metadata emitted statically into them.

## Alternatives considered

### Continue using embedded shared libraries for back-deployment

Prior implementations of back deployment for types or runtime behavior have required a shared library to be embedded in applications running on older OS versions. For example, Swift Concurrency back-deployment bundled `libswift_Concurrency.dylib`, while the `Span` family's back-deployment bundled `libswiftCompatibilitySpan.dylib`. This approach is technically very complicated, and does not work well for standalone binaries such as command-line applications. However, it does allow for back-deploying essentially anything that can be made to work on an older OS version.

The proposed `@backDeployed(before:)` extension is more limited but far easier to deploy: it only affects how code is generated, and everything the program needs to run on an older OS is part of the same binary. There is a higher cost to code size (due to redundant type and conformance metadata) as well, although the types we actually wish to back deploy tend to be very simple.

## Acknowledgments

The critical insight about using the foreign metadata and witness table uniquing mechanism in existing Swift runtimes came from a discussion with Allan Shortlidge. Prior to that, we had not found a way to enable any back-deployment of types without embedding shared libraries in a program or modifing the Swift runtime.
