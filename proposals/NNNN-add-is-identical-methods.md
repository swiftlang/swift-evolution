# Add `isIdentical` Methods for Quick Comparisons to Concrete Types

* Proposal: [SE-NNNN](NNNN-add-is-identical-methods.md)
* Authors: [Rick van Voorden](https://github.com/vanvoorden), [Karoy Lorentey](https://github.com/lorentey)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: ([String, Substring](https://github.com/swiftlang/swift/pull/82055)), ([Array, ArraySlice, ContiguousArray](https://github.com/swiftlang/swift/pull/82438)), ([Dictionary, Set](https://github.com/swiftlang/swift/pull/82439))
* Review: ([Pre-Pitch](https://forums.swift.org/t/how-to-check-two-array-instances-for-identity-equality-in-constant-time/78792)), ([Pitch #1](https://forums.swift.org/t/pitch-distinguishable-protocol-for-quick-comparisons/79145)), ([Pitch #2](https://forums.swift.org/t/pitch-2-add-isidentical-methods-for-quick-comparisons-to-concrete-types/80496))

## Introduction

We propose new `isIdentical` instance methods to concrete types for determining in constant-time if two instances must be equal by-value.

## Motivation

Suppose we have some code that listens to strings from an `AsyncSequence`. Every string received from the `AsyncSequence` is then used to perform some work that scales linearly with the size of the string:

```swift
func doLinearOperation(with string: String) {
  //  perform some operation
  //  scales linearly with string
}

func f1<S>(sequence: S) async throws
where S: AsyncSequence, S.Element == String {
  for try await string in sequence {
    doLinearOperation(with: string)
  }
}
```

Suppose we know that `doLinearOperation` only performs important work when `string` is not equal to the last value (here we define “equal” to imply “value equality”). The *first* call to `doLinearOperation` is important, and the *next* calls to `doLinearOperation` are only important if `string` is not equal by-value to the last `string` that was used to perform `doLinearOperation`.

Since we know that `String` conforms to `Equatable`, we can choose to “memoize” our values *before* we perform `doLinearOperation`:

```swift
func f2<S>(sequence: S) async throws
where S: AsyncSequence, S.Element == String {
  var oldString: String?
  for try await string in sequence {
    if oldString == string { continue }
    oldString = string
    doLinearOperation(with: string)
  }
}
```

When our `sequence` produces many strings that are equal by-value, “eagerly” passing that string to `doLinearOperation` performs more work than necessary. Performing a check for value-equality *before* we pass that string to `doLinearOperation` saves us the work from performing `doLinearOperation` more than necessary, but we have now traded performance in a different direction. Because we know that the work performed in `doLinearOperation` scales linearly with the size of the `string`, and we know that the `==` operator *also* scales linearly with the size of the `string`, we now perform *two* linear operations whenever our `sequence` delivers a new `string` that is not equal by-value to the previous input to `doLinearOperation`.

At this point our product engineer has to make a tradeoff: do we “eagerly” perform the call to `doLinearOperation` *without* a preflight check for value equality on the expectation that `sequence` will produce many non-equal values, or do we perform the call to `doLinearOperation` *with* a preflight check for value equality on the expectation that `sequence` will produce many equal values?

There is a third path forward… a “quick” check against `String` values that returns in constant-time and *guarantees* these instances *must* be equal by value. We can add a similar check to additional concrete types from Standard Library.

## Prior Art

`String` already ships a public-but-underscored API that returns in constant time.[^1]

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

Many types in Standard Library are “copy-on-write” data structures. These types present as value types, but can leverage a reference to some shared state to optimize for performance. When we copy this value we copy a reference to shared storage. If we perform a mutation on a copy we can preserve value semantics by copying the storage reference to a unique value before we write our mutation: we “copy” on “write”.

This means that many types in Standard Library already have some private reference that can be checked in constant-time to determine if two values are identical. Because these types copy before writing, two values that are identical by their shared storage *must* be equal by value.

Suppose our `_isIdentical` method from `String` was no longer underscored. We could now refactor our operation on `AsyncSequence` to:

```swift
func f3<S>(sequence: S) async throws
where S: AsyncSequence, S.Element == String {
  var oldString: String?
  for try await string in sequence {
    if oldString?.isIdentical(to: string) ?? false { continue }
    oldString = string
    doLinearOperation(with: string)
  }
}
```

What has this done for our performance? We know that `doLinearOperation` performs a linear operation over `string`. We also know that `isIdentical` returns in constant-time. If `isIdentical` returns `true` we skip performing `doLinearOperation`. If `isIdentical` returns `false` we perform `doLinearOperation`, but this is now *one* linear operation. We will potentially perform this linear operation *even if* the `element` returned is equal by-value, but since the preflight check to confirm value equality was *itself* a linear operation, we now perform one linear operation instead of two.

## Detailed Design

Here is a new method defined on `String`:

```swift
@available(SwiftStdlib 6.3, *)
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
  /// - Complexity: O(1)
  @available(SwiftStdlib 6.3, *)
  public func isIdentical(to other: Self) -> Bool { ... }
}
```

We propose adding `isIdentical` methods to the following concrete types from Standard Library:
* String
* Substring
* Array
* ArraySlice
* ContiguousArray
* Dictionary
* Set

The methods follow the same pattern from `String`. Every `isIdentical` method is an instance method that takes one parameter of the same type and returns a `Bool` value in constant-time indicating two instances must be equal by value. Here is an example on `Array`:

```swift
@available(SwiftStdlib 6.3, *)
extension Array {
  /// Returns a boolean value indicating whether this array is identical to
  /// `other`.
  ///
  /// Two array values are identical if there is no way to distinguish between
  /// them.
  ///
  /// Comparing arrays this way includes comparing (normally) hidden
  /// implementation details such as the memory location of any underlying
  /// array storage object. Therefore, identical arrays are guaranteed to
  /// compare equal with `==`, but not all equal arrays are considered
  /// identical.
  ///
  /// - Complexity: O(1)
  @available(SwiftStdlib 6.3, *)
  public func isIdentical(to other: Self) -> Bool { ... }
}
```

## Source Compatibility

This proposal is additive and source-compatible with existing code.

## Impact on ABI

This proposal is additive and ABI-compatible with existing code.

## Future Directions

Any Standard Library types that are copy-on-write values that also conform to `Equatable` would be good candidates to add `isIdentical` functions.

## Alternatives Considered

### Overload for `===`

Could we “overload” the `===` operator from `AnyObject`? This proposal considers that question to be orthogonal to our goal of exposing identity equality with the `isIdentical` instances methods. We could choose to overload `===`, but this would be a larger “conceptual” and “philosophical” change because the `===` operator is currently meant for `AnyObject` types — not value types like `String` and `Array`.

### Overload for Optionals

When working with `Optional` string values we can add the following overload:

```swift
@available(SwiftStdlib 6.3, *)
extension Optional {
  @available(SwiftStdlib 6.3, *)
  public func isIdentical(to other: Self) -> Bool
  where Wrapped == String {
    switch (self, other) {
    case let (value?, other?):
      return value.isIdentical(to: other)
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

Instead of publishing an `isIdentical` function which implies two types *must* be equal, could we think of things from the opposite direction? Could we publish a `maybeDifferent` function which implies two types *might not* be equal? This then introduces some potential ambiguity for product engineers: to what extent does “maybe different” imply “probably different”? This ambiguity could be settled with extra documentation on the protocol, but `isIdentical` solves that ambiguity up-front. The `isIdentical` function is also consistent with the prior art in this space.

In the same way this proposal exposes a way to quickly check if two `String` values *must* be equal, product engineers might want a way to quickly check if two `String` values *must not* be equal. This is an interesting idea, but this can exist as an independent proposal. We don’t need to block the review of this proposal on a review of `isNotIdentical` semantics.

## Acknowledgments

Thanks [Ben_Cohen](https://forums.swift.org/u/Ben_Cohen) for helping to think through and generalize the original use-case and problem-statement.

[^1]: https://github.com/swiftlang/swift/blob/swift-6.1.2-RELEASE/stdlib/public/core/String.swift#L397-L415
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
