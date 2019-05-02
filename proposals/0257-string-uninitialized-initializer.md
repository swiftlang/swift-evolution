# Add a String Initializer with Access to Uninitialized Storage

* Proposal: [SE-0257](0257-string-uninitialized-initializer.md)
* Author: [David Smith](https://github.com/Catfish-Man)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#23409](https://github.com/apple/swift/pull/23409)
* Bug: [SR-10288](https://bugs.swift.org/browse/SR-10288)

## Introduction

This proposal suggests a new initializer for `String` that provides access to a String's uninitialized storage buffer.

## Motivation

`String` today is well-suited to interoperability with raw memory buffers when a contiguous buffer is already available, such as when dealing with `malloc`ed C strings. However, there are quite a few situations where no such buffer is available, requiring a temporary one to be allocated and copied into. One example is bridging `NSString` to `String`, which currently uses standard library internals to get good performance when using `CFStringGetBytes`. Another, also from the standard library, is `Int` and `Float`, which currently create temporary stack buffers and do extra copying. We expect libraries like SwiftNIO will also find this useful for dealing with streaming data.

## Proposed solution

Add a new `String` initializer that lets a program work with an uninitialized
buffer.

The new initializer takes a closure that operates on an
`UnsafeMutableBufferPointer` and an `inout` count of initialized elements. This
closure has access to the uninitialized contents of the newly created String's
storage, and returns the number of initialized buffer elements, or 0.

```swift
let myCocoaString = NSString("The quick brown fox jumps over the lazy dog") as CFString
var myString = String(uninitializedCapacity: CFStringGetMaximumSizeForEncoding(myCocoaString, …)) { buffer in
    var initializedCount = 0
    CFStringGetBytes(
    	myCocoaString,
    	buffer,
    	…,
    	&initializedCount
    )
    return initializedCount
}
// myString == "The quick brown fox jumps over the lazy dog"
```

Without this initializer we would have had to heap allocate an `UnsafeMutableBufferPointer`, copy the `NSString` contents into it, and then copy the buffer again as we initialized the `String`.

## Detailed design

```swift
  /// Creates a new String with the specified capacity in UTF-8 code units then
  /// calls the given closure with a buffer covering the String's uninitialized
  /// memory.
  ///
  /// The closure should return the number of initialized code units, 
  /// or 0 if it couldn't initialize the buffer (for example if the 
  /// requested capacity was too small).
  ///
  /// This method replaces ill-formed UTF-8 sequences with the Unicode
  /// replacement character (`"\u{FFFD}"`); This may require resizing
  /// the buffer beyond its original capacity.
  ///
  /// The following examples use this initializer with the contents of two
  /// different `UInt8` arrays---the first with well-formed UTF-8 code unit
  /// sequences and the second with an ill-formed sequence at the end.
  ///
  ///     let validUTF8: [UInt8] = [67, 97, 102, -61, -87, 0]
  ///     let s = String(uninitializedCapacity: validUTF8.count,
  ///                    initializingUTF8With: { ptr in
  ///         ptr.initializeFrom(validUTF8)
  ///         return validUTF8.count
  ///     })
  ///     // Prints "Café"
  ///
  ///     let invalidUTF8: [UInt8] = [67, 97, 102, -61, 0]
  ///     let s = String(uninitializedCapacity: invalidUTF8.count,
  ///                    initializingUTF8With: { ptr in
  ///         ptr.initializeFrom(invalidUTF8)
  ///         return invalidUTF8.count
  ///     })
  ///     // Prints "Caf�"
  ///
  ///     let s = String(uninitializedCapacity: invalidUTF8.count,
  ///                    initializingUTF8With: { ptr in
  ///         ptr.initializeFrom(invalidUTF8)
  ///         return 0
  ///     })
  ///     // Prints ""
  ///
  /// - Parameters:
  ///   - capacity: The number of UTF-8 code units worth of memory to allocate
  ///       for the String.
  ///   - initializer: A closure that initializes elements and sets the count of
  ///       the new String
  ///     - Parameters:
  ///       - buffer: A buffer covering uninitialized memory with room for the
  ///           specified number of UTF-8 code units.
  public init(
    uninitializedCapacity capacity: Int,
    initializingUTF8With initializer: (
      _ buffer: UnsafeMutableBufferPointer<UInt8>,
    ) throws -> Int
  ) rethrows
```

### Specifying a capacity

The initializer takes the specific capacity that a user wants to work with as a
parameter. The buffer passed to the closure has a count that is at least the
same as the specified capacity, even if the ultimate size of the new `String` is larger.

### Guarantees after throwing

Because `UTF8.CodeUnit` is a trivial type, there are no special considerations about the state of the buffer when an error is thrown, unlike `Array`.

## Source compatibility

This is an additive change to the standard library,
so there is no effect on source compatibility.

## Effect on ABI stability

The new initializer will be part of the ABI, and will result in calls to a new @usableFromInline symbol being inlined into client code. Use of the new initializer is gated by @availability though, so there's no back-deployment concern.

## Effect on API resilience

The additional APIs will be a permanent part of the standard library,
and will need to remain public API. 

## Alternatives considered

### Taking an inout count in the initializer rather than returning the new count

Consistency with `Array` (which has to use the inout count for correctness) has some appeal here, but ultimately we decided that the value of consistency lies in allowing skill transfer and in repeated use, and these highly specialized initializers don't really allow for that.

### Returning a `Bool` to indicate success from the closure

Requiring people to either `throw` or check in the caller for an empty `String` return if the initializing closure fails is slightly awkward, but making the initializer failable is at least as awkward, and would be inconsistent with `Array`.

### Validating UTF-8 instead of repairing invalid UTF-8

Matching the behavior of most other `String` initializers here also makes it more ergonomic to use, since it can be non-failable this way.
