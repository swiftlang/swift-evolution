# Add overrides taking an UnsafePointer source to non-destructive copying methods on UnsafeMutablePointer

* Proposal: [SE-0076](0076-copying-to-unsafe-mutable-pointer-with-unsafe-pointer-source.md)
* Author: [Janosch Hildebrand](https://github.com/Jnosh)
* Status: **Implemented in Swift 3** ([Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000149.html), [Bug](https://bugs.swift.org/browse/SR-1490))
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

`UnsafeMutablePointer` includes several methods to non-destructively copy elements from memory pointed to by another `UnsafeMutablePointer` instance. I propose adding overloads of these methods to `UnsafeMutablePointer` that allow an `UnsafePointer` source.

Swift-evolution thread: [\[Pitch\] Add overrides with UnsafePointer sources to non-destructive copying methods on UnsafeMutablePointer](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160201/008827.html)

## Motivation

To copy values from memory pointed to by an `UnsafePointer` it is currently necessary to perform a cast to `UnsafeMutablePointer` beforehand:

```swift
let source: UnsafePointer<Int> = ...
let destination: UnsafeMutablePointer<Int> = ...

// Today:
destination.assignFrom(UnsafeMutablePointer(source), count: count)
```

These casts are unnecessary visual noise as non-destructively copying from an `UnsafePointer` source is perfectly safe.
Furthermore, these casts are a source of confusion and increased cognitive load on a reader since any such cast is likely to throw up a red flag at first.

## Proposed solution

In addition to these existing methods on UnsafeMutablePointer:

```swift
func assignBackwardFrom(source: UnsafeMutablePointer<Pointee>, count: Int)
func assignFrom(source: UnsafeMutablePointer<Pointee>, count: Int)
func initializeFrom(source: UnsafeMutablePointer<Pointee>, count: Int)
```

I propose adding the following overloads:
```swift
func assignBackwardFrom(source: UnsafePointer<Pointee>, count: Int)
func assignFrom(source: UnsafePointer<Pointee>, count: Int)
func initializeFrom(source: UnsafePointer<Pointee>, count: Int)
```

This would transform the given example as follows:
```swift
let source: UnsafePointer<Int> = ...
let destination: UnsafeMutablePointer<Int> = ...

// Today:
destination.assignFrom(UnsafeMutablePointer(source), count: count)

// This proposal:
destination.assignFrom(source, count: count)
```

## Detailed design

The following methods are added to `UnsafeMutablePointer`:

```swift
/// Assign from `count` values beginning at source into initialized
/// memory, proceeding from the first element to the last.
public func assignFrom(source: UnsafePointer<Pointee>, count: Int)
  
  
/// Assign from `count` values beginning at `source` into
/// initialized memory, proceeding from the last value to the first.
/// Use this for assigning ranges into later memory that may overlap
/// with the source range.
///
/// - Requires: Either `source` precedes `self` or follows `self + count`.
public func assignBackwardFrom(source: UnsafePointer<Pointee>, count: Int)
  
  
/// Copy `count` values beginning at source into raw memory.
///
/// - Precondition: The memory is not initialized.
///
/// - Requires: `self` and `source` may not overlap.
public func initializeFrom(source: UnsafePointer<Pointee>, count: Int)
```

## Impact on existing code

This proposal is additive and does not impact existing code.

## Alternatives considered

* **Keep the status quo**: I'd argue that they provide enough benefit to justify their existence while only minimally increasing the stdlib surface area, especially by merit of being overloads.

* **Introduce a `PointerProtocol` protocol**: A common protocol could be used to avoid the need for overloads in this case. However, without additional use cases this seems like severe over-engineering for this simple issue. This would also require a lot more design work, performance considerations, etc...

* **Leverage implicit conversions**: The implicit conversions from `UnsafeMutablePointer` to `UnsafePointer` could be leveraged to work around the need for overloads by dropping the existing methods taking `UnsafeMutablePointer` source arguments. Adding explicit overloads seems a better solution than depending on compiler magic and is clearer from a documentation and auto-completion perspective.
