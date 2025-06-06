# Add `isKnownIdentical` Method for Quick Comparisons to `Equatable`

* Proposal: [SE-NNNN](NNNN-t.md)
* Authors: [Rick van Voorden](https://github.com/vanvoorden), [Karoy Lorentey](https://github.com/lorentey)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: TODO
* Review: ([Pre-Pitch](https://forums.swift.org/t/how-to-check-two-array-instances-for-identity-equality-in-constant-time/78792)), ([Pitch #1](https://forums.swift.org/t/pitch-distinguishable-protocol-for-quick-comparisons/79145))

## Introduction

We propose a new `isKnownIdentical` method to `Equatable` for determining in constant-time if two instances must be equal by-value.

## Motivation

Suppose we have some code that listens to elements from an `AsyncSequence`. Every element received from the `AsyncSequence` is then used to perform some work that scales linearly with the size of the element:

```swift
func doLinearOperation<T>(with element: T) {
  //  perform some operation
  //  scales linearly with T
}

func f1<S>(sequence: S) async throws
where S: AsyncSequence {
  for try await element in sequence {
    doLinearOperation(with: element)
  }
}
```

Suppose we know that `doLinearOperation` only performs important work when `element` is not equal to the last value (here we define “equal” to imply “value equality”). The *first* call to `doLinearOperation` is important, and the *next* calls to `doLinearOperation` are only important if `element` is not equal by-value to the last `element` that was used to perform `doLinearOperation`.

If we know that `Element` conforms to `Equatable`, we can choose to “memoize” our values *before* we perform `doLinearOperation`:

```swift
func f2<S>(sequence: S) async throws
where S: AsyncSequence, S.Element: Equatable {
  var oldElement: S.Element?
  for try await element in sequence {
    if oldElement == element { continue }
    oldElement = element
    doLinearOperation(with: element)
  }
}
```

When our `sequence` produces many elements that are equal by-value, “eagerly” passing that element to `doLinearOperation` performs more work than necessary. Performing a check for value-equality *before* we pass that element to `doLinearOperation` saves us the work from performing `doLinearOperation` more than necessary, but we have now traded performance in a different direction. Because we know that the work performed in `doLinearOperation` scales linearly with the size of the `element`, and we know that the `==` operator *also* scales linearly with the size of the `element`, we now perform *two* linear operations whenever our `sequence` delivers a new `element` that is not equal by-value to the previous input to `doLinearOperation`.

At this point our product engineer has to make a tradeoff: do we “eagerly” perform the call to `doLinearOperation` *without* a preflight check for value equality on the expectation that `sequence` will produce many non-equal values, or do we perform the call to `doLinearOperation` *with* a preflight check for value equality on the expectation that `sequence` will produce many equal values?

There is a third path forward… a “quick” check against elements that returns in constant-time and *guarantees* these instances *must* be equal by value.

## Prior Art

`Swift.String` already ships a public-but-underscored API that returns in constant time:[^1]

```swift
extension String {
  /// Returns a boolean value indicating whether this string is identical to
  /// `other`.
  ///
  /// Two string values are identical if there is no way to distinguish between
  /// them.
  ///
  /// Comparing strings this way includes comparing (normally) hidden
  /// implementation details such as the memory location of any underlying
  /// string storage object. Therefore, identical strings are guaranteed to
  /// compare equal with `==`, but not all equal strings are considered
  /// identical.
  ///
  /// - Performance: O(1)
  @_alwaysEmitIntoClient
  public func _isIdentical(to other: Self) -> Bool {
    self._guts.rawBits == other._guts.rawBits
  }
}
```

We don’t see this API currently being used in standard library, but it’s possible this API is already being used to optimize performance in private frameworks from Apple.

Many more examples of `isIdentical` functions are currently shipping in `Swift-Collections`[^2][^3][^4][^5][^6][^7][^8][^9][^10][^11][^12][^13], `Swift-Markdown`[^14], and `Swift-CowBox`[^15]. We also support `isIdentical` on the upcoming `Span` and `RawSpan` types from Standard Library.[^16]

## Proposed Solution

Many types in Swift and Foundation are “copy-on-write” data structures. These types present as value types, but can leverage a reference to some shared state to optimize for performance. When we copy this value we copy a reference to shared storage. If we perform a mutation on a copy we can preserve value semantics by copying the storage reference to a unique value before we write our mutation: we “copy” on “write”.

This means that many types in Standard Library and Foundation already have some private reference that can be checked in constant-time to determine if two values are identical. Because these types copy before writing, two values that are identical by their shared storage *must* be equal by value.

Suppose our `Equatable` protocol adopts a method that can return in constant time if two instances are identical and must be equal by-value. We can now refactor our operation on `AsyncSequence` to:

```swift
func f3<S>(sequence: S) async throws
where S: AsyncSequence, S.Element: Equatable {
  var oldElement: S.Element?
  for try await element in sequence {
    if oldElement?.isKnownIdentical(to: element) ?? false { continue }
    oldElement = element
    doLinearOperation(with: element)
  }
}
```

What has this done for our performance? We know that `doLinearOperation` performs a linear operation over `element`. We also know that `isKnownIdentical` returns in constant-time. If `isKnownIdentical` returns `true` we skip performing `doLinearOperation`. If `isIdentical` returns `false` or `nil` we perform `doLinearOperation`, but this is now *one* linear operation. We will potentially perform this linear operation *even if* the `element` returned is equal by-value, but since the preflight check to confirm value equality was *itself* a linear operation, we now perform one linear operation instead of two.

## Detailed Design

Here is a new method defined on `Equatable`:

```swift
public protocol Equatable {
  // The original requirement is unchanged.
  static func == (lhs: Self, rhs: Self) -> Bool
  
  // Returns if `self` can be quickly determined to be identical to `other`.
  //
  // - A `nil` result indicates that the type does not implement a fast test for
  //   this condition, and that it only provides the full `==` implementation.
  // - A `true` result indicates that the two values are definitely identical
  //   (for example, they might share their hidden reference to the same
  //   storage representation). By reflexivity, `==` is guaranteed to return
  //   `true` in this case.
  // - A `false` result indicates that the two values aren't identical. Their
  //   contents may or may not still compare equal in this case.
  //
  // Complexity: O(1).
  @available(SwiftStdlib 6.3, *)
  func isKnownIdentical(to other: Self) -> Bool?
}

@available(SwiftStdlib 6.3, *)
extension Equatable {
  @available(SwiftStdlib 6.3, *)
  func isKnownIdentical(to other: Self) -> Bool? { nil }
}
```

We add `isKnownIdentical` to *all* types that adopt `Equatable`, but types that adopt `Equatable` choose to “opt-in” with their own custom implementation of `isKnownIdentical`. By default, all types return `nil` to indicate this type does not have the ability to make any decision about identity equality.

If a type *does* have some ability to quickly test for identity equality, this type can return `true` or `false` from `isKnownIdentical`. Here is an example from `String`:

```swift
extension String {
  func isKnownIdentical(to other: Self) -> Bool? {
    self._isIdentical(to: other)
  }
}
```

Here is an example of a copy-on-write data structure that manages some private `storage` property for structural sharing:

```swift
extension CowBox {
  func isKnownIdentical(to other: Self) -> Bool? {
    self._storage === other._storage
  }
}
```

## Source Compatibility

Adding a new requirement to an existing protocol is source breaking if that new requirement uses `Self` *and* that new requirement is the *first* use of `Self`. Because our existing `==` operator on `Equatable` used `Self`, this proposal is safe for source compatibility.

## Impact on ABI

Adding a new requirement to an existing protocol is ABI breaking if we do not include an unconstrained default implementation. Because we include a default implementation of `isKnownIdentical`, this proposal is safe for ABI compatibility.

## Alternatives Considered

### New `Distinguishable` protocol

The original version of this pitch suggested a new protocol independent of `Equatable`:

```swift
protocol Distinguishable {
  func isKnownIdentical(to other: Self) -> Bool?
}
```

Algorithms from generic contexts that operated on `Distinguishable` could then use `isKnownIdentical` to optimize performance:

```swift
func f4<S>(sequence: S) async throws
where S: AsyncSequence, S.Element: Distinguishable {
  var oldElement: S.Element?
  for try await element in sequence {
    if oldElement?.isKnownIdentical(to: element) ?? false { continue }
    oldElement = element
    doLinearOperation(with: element)
  }
}
```

This is good… but let’s think about what happens if the `element` returned by `sequence` might not *always* be `Distinguishable`. We can assume the `element` will always be `Equatable`, but we have to “code around” `Distinguishable`:

```swift
func f2<S>(sequence: S) async throws
where S: AsyncSequence, S.Element: Equatable {
  var oldElement: S.Element?
  for try await element in sequence {
    if oldElement == element { continue }
    oldElement = element
    doLinearOperation(with: element)
  }
}

func f4<S>(sequence: S) async throws
where S: AsyncSequence, S.Element: Distinguishable {
  var oldElement: S.Element?
  for try await element in sequence {
    if oldElement?.isKnownIdentical(to: element) ?? false { continue }
    oldElement = element
    doLinearOperation(with: element)
  }
}

func f5<S>(sequence: S) async throws
where S: AsyncSequence, S.Element: Distinguishable, S.Element: Equatable {
  var oldElement: S.Element?
  for try await element in sequence {
    if oldElement?.isKnownIdentical(to: element) ?? false { continue }
    oldElement = element
    doLinearOperation(with: element)
  }
}
```

We now need *three* different specializations:
* One for a type that is `Equatable` and not `Distinguishable`.
* One for a type that is `Distinguishable` and not `Equatable`.
* One for a type that is `Equatable` and `Distinguishable`.

A `Distinguishable` protocol would offer a lot of flexibility: product engineers could define types (such as `Span` and `RawSpan`) that have the ability to return a meaningful answer to `isKnownIdentical` without adopting `Equatable`. The trouble is that the price we pay for that extra flexibility is much more extra ceremony to support a new generic context specialization when we expect most engineers want to use `isKnownIdentical` in place of value equality.

### Overload for `===`

Could we “overload” the `===` operator from `AnyObject`? This proposal considers that question to be orthogonal to our goal of exposing identity equality with the `isKnownIdentical` method. We could choose to overload `===`, but this would be a larger “conceptual” and “philosophical” change because the `===` operator is currently meant for `AnyObject` types — not value types like `String` and `Array`.

### Overload for Optionals

When working with `Optional` values we can add the following overload:

```swift
@available(SwiftStdlib 6.3, *)
extension Optional {
  @available(SwiftStdlib 6.3, *)
  public func isKnownIdentical(to other: Self) -> Bool?
  where Wrapped: Equatable {
    switch (self, other) {
    case let (value?, other?):
      return value.isKnownIdentical(to: other)
    case (nil, nil):
      return true
    default:
      return false
    }
  }
}
```

Because this overload needs no `private` or `internal` symbols from Standard Library, we can omit this overload from our proposal. Product engineers that want this overload can choose to implement it for themselves.

### Alternative Semantics

Instead of publishing an `isKnownIdentical` function which implies two types *must* be equal, could we think of things from the opposite direction? Could we publish a `maybeDifferent` function which implies two types *might not* be equal? This then introduces some potential ambiguity for product engineers: to what extent does “maybe different” imply “probably different”? This ambiguity could be settled with extra documentation on the protocol, but `isKnownIdentical` solves that ambiguity up-front. The `isKnownIdentical` function is also consistent with the prior art in this space.

In the same way this proposal exposes a way to quickly check if two `Equatable` values *must* be equal, product engineers might want a way to quickly check if two `Equatable` values *must not* be equal. This is an interesting idea, but this can exist as an independent proposal. We don’t need to block the review of this proposal on a review of `isKnownNotIdentical` semantics.

## Acknowledgments

Thanks [dnadoba](https://forums.swift.org/u/dnadoba) for suggesting the `isKnownIdentical` function should exist on a protocol.

Thanks [Ben_Cohen](https://forums.swift.org/u/Ben_Cohen) for helping to think through and generalize the original use-case and problem-statement.

Thanks [Slava_Pestov](https://forums.swift.org/u/Slava_Pestov) for helping to investigate source-compatibility and ABI implications of a new requirement on an existing protocol.

[^1]: https://github.com/swiftlang/swift/blob/swift-6.1-RELEASE/stdlib/public/core/String.swift#L397-L415
[^2]: https://github.com/apple/swift-collections/blob/1.2.0/Sources/DequeModule/Deque._Storage.swift#L223-L225
[^3]: https://github.com/apple/swift-collections/blob/1.2.0/Sources/HashTreeCollections/HashNode/_HashNode.swift#L78-L80
[^4]: https://github.com/apple/swift-collections/blob/1.2.0/Sources/HashTreeCollections/HashNode/_RawHashNode.swift#L50-L52
[^5]: https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Conformances/BigString%2BEquatable.swift#L14-L16
[^6]: https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigString%2BUnicodeScalarView.swift#L77-L79
[^7]: https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigString%2BUTF8View.swift#L39-L41
[^8]: https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigString%2BUTF16View.swift#L39-L41
[^9]: https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigSubstring.swift#L100-L103
[^10]: https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigSubstring%2BUnicodeScalarView.swift#L94-L97
[^11]: https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigSubstring%2BUTF8View.swift#L64-L67
[^12]: https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/BigString/Views/BigSubstring%2BUTF16View.swift#L87-L90
[^13]: https://github.com/apple/swift-collections/blob/1.2.0/Sources/RopeModule/Rope/Basics/Rope.swift#L68-L70
[^14]: https://github.com/swiftlang/swift-markdown/blob/swift-6.1.1-RELEASE/Sources/Markdown/Base/Markup.swift#L370-L372
[^15]: https://github.com/Swift-CowBox/Swift-CowBox/blob/1.1.0/Sources/CowBox/CowBox.swift#L19-L27
[^16]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md
