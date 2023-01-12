# Contiguous Strings

* Proposal: [SE-0247](0247-contiguous-strings.md)
* Author: [Michael Ilseman](https://github.com/milseman)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 5.1)**
* Implementation: [apple/swift#23051](https://github.com/apple/swift/pull/23051)
* Bugs: [apple/swift-corelibs-foundation#3780](https://github.com/apple/swift-corelibs-foundation/issues/3780)

## Introduction

One of the most common API requests from performance-minded users of string is a way to get direct access to the raw underlying code units. Now that [Swift 5 uses UTF-8](https://forums.swift.org/t/string-s-abi-and-utf-8/17676) for its preferred encoding, we can provide this.

“Contiguous strings” are strings that are capable of providing a pointer and length to [validly encoded](https://en.wikipedia.org/wiki/UTF-8#Invalid_byte_sequences) UTF-8 contents in constant time. Contiguous strings include:

* All native Swift string forms
* Lazily bridged Cocoa strings that provide a pointer to contiguous ASCII
* Any “shared string” concept we may add in the future

Noncontiguous strings include:

* Lazily-bridged Cocoa strings that don’t provide a pointer to contiguous ASCII (even if they do have contiguous UTF-16 code units)
* Any “foreign string” concept we may add in the future

Contiguous strings are heavily optimized and more efficient to process than noncontiguous strings. However, noncontiguous string contents don’t have to be copied when imported into Swift, which is profitable for strings which may never be read from, such as imported NSString dictionary keys.

Swift-evolution thread: [Pitch: Contiguous Strings](https://forums.swift.org/t/pitch-contiguous-strings/21206)

## Motivation

In Swift 5.0, `String.UTF8View` supports `withContiguousStorageIfAvailable()`, which succeeds on contiguous strings but returns `nil` on noncontiguous strings. While it’s nice to run a fast algorithm when you can, users are left in the dark if this doesn’t succeed. Even if it’s known to probably succeed, guarding against `nil` and having a valid fall-back path is not ergonomic.

## Proposed solution

We propose adding to String and Substring:

* A way to query if a string is contiguous
* A way to force a string to be contiguous
* A way to run a closure over the raw UTF-8 contents of a string

(For rationale on why StringProtocol was excluded, see “What about StringProtocol?” in Alternatives Considered)

## Detailed design

```swift
extension String {
  /// Returns whether this string is capable of providing access to
  /// validly-encoded UTF-8 contents in contiguous memory in O(1) time.
  ///
  /// Contiguous strings always operate in O(1) time for withUTF8 and always
  /// give a result for String.UTF8View.withContiguousStorageIfAvailable.
  /// Contiguous strings also benefit from fast-paths and better optimizations.
  ///
  public var isContiguousUTF8: Bool { get }

  /// If this string is not contiguous, make it so. If this mutates the string,
  /// it will invalidate any pre-existing indices.
  ///
  /// Complexity: O(n) if non-contiguous, O(1) if already contiguous
  ///
  public mutating func makeContiguousUTF8()

  /// Runs `body` over the content of this string in contiguous memory. If this
  /// string is not contiguous, this will first make it contiguous, which will
  /// also speed up subsequent access. If this mutates the string,
  /// it will invalidate any pre-existing indices.
  ///
  /// Note that it is unsafe to escape the pointer provided to `body`. For
  /// example, strings of up to 15 UTF-8 code units in length may be represented
  /// in a small-string representation, and thus will be spilled into
  /// temporary stack space which is invalid after `withUTF8` finishes
  /// execution.
  ///
  /// Complexity: O(n) if non-contiguous, O(1) if already contiguous
  ///
  public mutating func withUTF8<R>(
    _ body: (UnsafeBufferPointer<UInt8>) throws -> R
  ) rethrows -> R
}

// Contiguous UTF-8 strings
extension Substring {
  /// Returns whether this string is capable of providing access to
  /// validly-encoded UTF-8 contents in contiguous memory in O(1) time.
  ///
  /// Contiguous strings always operate in O(1) time for withUTF8 and always
  /// give a result for String.UTF8View.withContiguousStorageIfAvailable.
  /// Contiguous strings also benefit from fast-paths and better optimizations.
  ///
  public var isContiguousUTF8: Bool { get }

  /// If this string is not contiguous, make it so. If this mutates the
  /// substring, it will invalidate any pre-existing indices.
  ///
  /// Complexity: O(n) if non-contiguous, O(1) if already contiguous
  ///
  public mutating func makeContiguousUTF8()

  /// Runs `body` over the content of this substring in contiguous memory. If
  /// this substring is not contiguous, this will first make it contiguous,
  /// which will also speed up subsequent access. If this mutates the substring,
  /// it will invalidate any pre-existing indices.
  ///
  /// Note that it is unsafe to escape the pointer provided to `body`. For
  /// example, strings of up to 15 UTF-8 code units in length may be represented
  /// in a small-string representation, and thus will be spilled into
  /// temporary stack space which is invalid after `withUTF8` finishes
  /// execution.
  ///
  /// Complexity: O(n) if non-contiguous, O(1) if already contiguous
  ///
  public mutating func withUTF8<R>(
    _ body: (UnsafeBufferPointer<UInt8>) throws -> R
  ) rethrows -> R
}
```

(For rationale as to why `withUTF8` is marked `mutating`, see “Wait, why is `withUTF8` marked as `mutating`?” in Alternatives Considered.)

## Source compatibility

All changes are additive.


## Effect on ABI stability

All changes are additive. ABI-relevant attributes are provided in “Detailed design”.


## Effect on API resilience

The APIs for String and Substring have their implementations exposed, as they are expressed in terms of assumptions and mechanisms already (non-resiliently) present in Swift 5.0.


## Alternatives considered

### Wait, why is `withUTF8` marked as `mutating`?

If the string is noncontiguous, something has to happen to get contiguous UTF-8 contents in memory. We have 3 basic options here:

##### 1. Copy into a new heap allocation, run the closure, then throw it away

This approach takes inspiration from Array’s `withUnsafeBufferPointer`, which runs directly on its contents if it can, otherwise it makes a temporary copy to run over. However, unlike Array, noncontiguous strings are much more common and there are no type-level guarantees of contiguity. For example, Array with a value-type `Element` is always contiguous, so the vast majority of performance sensitive operations over arrays (e.g. `Array<Int>`) can never trigger this allocation.

Because String does not have Array’s guarantee, this approach would harm the ability to reason about the performance characteristics of code. This approach would also keep the string on the slow-path for access after the method is called. If the contents are worth reading, they’re worth ensuring contiguity.

##### 2. Trap if noncontiguous

This would be the ideal API for platforms without Cocoa interoperability (unless/until we introduce noncontiguous foreign strings, at least), as it will always succeed. However, this would be a terrible source of crashes in libraries and applications that forget to exhaustively test their code with noncontiguous strings. This would hit cross-platform packages especially hard.

Even for libraries confined to Cocoa-interoperable platforms, whether an imported NSString is contiguous or not could change version-to-version of the OS, producing difficult to reason about bugs.

##### 3. Fine, make it `mutating`

The proposed compromise makes `withUTF8` mutating, forcing the contents to be bridged if noncontiguous. This has the downside of forcing such strings to be declared `var` rather than `let`, but mitigates the downsides of the other approaches. If the contents are worth reading, they’re worth ensuring contiguity.

##### Or, introduce a separate type, `ContiguousUTF8String`, instead

Introducing a new type would introduce an API schism and further complicate the
nature of StringProtocol. We don't consider the downsides to be worth the upside
of dropping `mutable`.

### What about StringProtocol?

Adding these methods to StringProtocol would allow code to be generic over String and Substring (and in the somewhat unlikely event we add new conformers, those as well). This can be done at any time, but there are some issues with doing this right now.

When it comes to adding these methods on StringProtocol, we have two options:

##### 1. Add it as a protocol extension

This approach would add the functions in an extension, ideally resilient and versioned. Unfortunately, `makeContiguousUTF8()` wouldn’t be implementable, as we cannot reassign self to a concrete type, so we’d have to add some additional requirements to StringProtocol surrounding forming a new contiguous string of the same concrete type.

##### 2. Add it as a requirement with a default implementation

This approach would add it as a customization hook that’s dynamically dispatched to the concrete type’s real implementations. The default implementation would be resilient and versioned and trap if called; any new conformers to StringProtocol would need to be versioned and accommodated here.

Adding new versioned-and-defaulted requirements to a protocol can be done at any point while preserving ABI stability. For now, we’re not sure it’s worth the extra witness table entries at this point. This also hits some of the pain points of option 1: any conformers to StringProtocol must satisfy `makeContiguousUTF8`’s post-condition of ensuring contiguity without changing concrete type.

This can be added in the future.

### Put this on the UTF8View

Contiguous UTF-8 is baked into String's ABI as the fastest representation; this
is about directly exposing that fact to performance-minded users. Other views
will not have this, so we believe it makes sense to put directly on String.
UTF-8 is special for performance and contiguity concerns.

### The Most Viable Alternative

Here's an alternative formulation that avoids `mutating` and
index-invalidation (by using strategy \#1 above).

```swift
extension [Sub]String {
  /// <as above>
  public var isContiguousUTF8: Bool { get }

  /// Produce a contiguous UTF-8 string with the same contents as `self`.
  /// Returns `self` is already contiguous, otherwise returns a new copy.
  ///
  /// Complexity: O(1) if `self` is contiguous UTF-8, otherwise O(n)
  ///
  public var contiguousUTF8: [Sub]String { get }

  /// Runs `body` over the content of this string in contiguous memory. If this
  /// string is not contiguous UTF-8, this will first make a contiguous copy and
  /// run over that.
  ///
  /// Note that it is unsafe to escape the pointer provided to `body`, even if
  /// `self` is contiguous UTF-8. For example, strings of up to 15 UTF-8 code
  /// units in length may be represented in a small-string representation, and
  /// thus will be spilled into temporary stack space which is invalid after
  /// `withUTF8` returns.
  ///
  /// Complexity: O(1) if `self` is contiguous UTF-8, otherwise O(n)
  ///
  public func withUTF8<R>(
    _ body: (UnsafeBufferPointer<UInt8>) throws -> R
  ) rethrows -> R
}
```

This formulation would be preferable for situations where strings are nearly-
always contiguous UTF-8. Also, the computed property is less invasive than a
mutating method as it can be used on the right-hand-side of a let binding.

Choosing between this and the version proposed depends on how users expect to
use it. We're eagerly awaiting feedback during the review.
