# `Distinguishable` protocol and `isIdentical` Function for Quick Comparisons

* Proposal: [SE-NNNN](NNNN-identical-functions.md)
* Authors: [Rick van Voorden](https://github.com/vanvoorden), [Karoy Lorentey](https://github.com/lorentey)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: TODO
* Review: ([pitch](https://forums.swift.org/t/pitch-distinguishable-protocol-for-quick-comparisons/79145))

## Introduction

I propose a new `Distinguishable` protocol and `isIdentical` function for determining if two instances are distinguishable in constant-time.

## Motivation

Suppose we have some code that listens to values from an `AsyncSequence`. Every value received from the `AsyncSequence` is then used to perform some work that scales linearly with the size of the `Element`:

```swift
func doLinearOperation<T>(with: T) {
  //  perform some operation
  //  scales linearly with T
}

func f1<S>(sequence: S) async throws where S: AsyncSequence {
  for try await element in sequence {
    doLinearOperation(with: element)
  }
}
```

Here we perform a linear operation on *every* value received from `sequence`. How much performance does this use?

Suppose we *know* that the work performed in `doLinearOperation` is only necessary when `element` is not equal (here we define "equal" to be "value equality"). The *first* call to `doLinearOperation` is important, and the *next* calls to `doLinearOperation` are only important if `element` is not equal-by-value to the last `element` that was used to perform `doLinearOperation`.

When we know that `Element` conforms to `Equatable` we can choose to "memoize" our values *before* we perform `doLinearOperation`:

```swift
func f2<S>(sequence: S) async throws where S: AsyncSequence, S.Element: Equatable {
  var oldElement: S.Element?
  for try await element in sequence {
    if oldElement != element {
      oldElement = element
      doLinearOperation(with: element)
    }
  }
}
```

When our `sequence` produces many elements that are equal-by-value, "eagerly" passing that element to `doLinearOperation` performs more work than necessary. Performing a check for value-equality *before* we pass that element to `doLinearOperation` saves us the work from performing more `doLinearOperation` than necessary, but we have now traded performance in a different direction. Because we know that the work performed in `doLinearOperation` scales linearly with the size of the `Element`, and we know that the `==` operator *also* scales linearly with the size of the `Element`, we now perform *two* linear operations whenever our `sequence` delivers a new value that is not equal-by-value to the previous input to `doLinearOperation`.

At this point our product engineer has to make a tradeoff: do we "eagerly" perform the call to `doLinearOperation` *without* a preflight check for value equality on the expectation that `sequence` will produce many non-equal values, or do we perform the call to `doLinearOperation` *with* a preflight check for value equality on the expectation that `sequence` will produce many equal values?

There is a third path forward… a "quick" check against elements that returns in constant-time and *guarantees* these types *must* be equal by value.

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

We don't see this API currently being used in standard library, but it's possible this API is already being used to optimize performance in private frameworks from Apple.

## Proposed Solution

Many types in Swift and Foundation are "copy-on-write" data structures. These types present as value types, but can leverage a reference to some shared state to optimize for performance. When we copy this value we copy a reference to shared storage. If we perform a mutation on a copy we can preserve value semantics by copying the storage reference to a unique value before we write our mutation: we "copy" on "write".

This means that many types in Swift and Foundation already have some private reference that can be checked in constant-time to determine if two values are identical. Because these types copy before writing, if two values are identical by their shared storage *must* be equal by value.

Suppose our `Element` conformed to a `Distinguishable` protocol. This `Element` now adopts a function that can return in constant time if two values are identical and must be equal by-value

We can now refactor our operation on `AsyncSequence` to take advantage of this:

```swift
func f3<S>(sequence: S) async throws where S: AsyncSequence, S.Element: Distinguishable {
  var oldElement: S.Element?
  for try await element in sequence {
    if oldElement.isIdentical(to: element) == false {
      oldElement = element
      doLinearOperation(with: element)
    }
  }
}
```

What has this done for our performance? We know that `doLinearOperation` performs a linear operation over `element`. We also know that `isIdentical` returns in constant-time. If `isIdentical` returns `true` we skip performing `doLinearOperation`. If `isIdentical` returns `false` we perform `doLinearOperation`, but this is now *one* linear operation. We will potentially perform this linear operation *even if* the `element` returned is equal by-value, but since the preflight check to confirm value equality was *itself* a linear operation, we now perform one linear operation instead of two.

## Detailed Design

Here is a new protocol defined in Standard Library:

```swift
@available(SwiftStdlib 6.3, *)
protocol Distinguishable {
  /// - Performance: O(1)
  func isIdentical(to other: Self) -> Bool
}
```

Because `Distinguishable` is similar but orthogonal to value equality, we give infra engineers the ability to define what "identity equality" means for them and the types that adopt `Distinguishable`.

The most common adoptions would be on Standard Library and Foundation types that are copy-on-write values that also conform to `Equatable`. Examples include `Array` and `Dictionary`. If two `Array` instances return `true` for `isIdentical`, then these two `Array` instances *must* be equal by-value.

## Source Compatibility

This code is additive. The protocol definition is guarded by `available`. The adoptions on Standard Library and Foundation types are guarded by `available`.

## Impact on ABI

Introducing a new protocol *and* adopting that protocol on existing types does not have to be ABI breaking. The implication is that we want to "get it right" and settle on all the types that *should* adopt `Distinguishable` because if we ship `Distinguishable` in 6.3 and then decide that an existing type should adopt `Distinguishable` in 6.4 that would break ABI.

Determining exactly what types from Standard Library and Foundation should adopt `Distinguishable` should block the landing of `Distinguishable`, but does not necessarily need to block the design review of `Distinguishable` itself. We can follow up on a design review of `Distinguishable` with an audit of Standard Library and Foundation to agree of what types should adopt `Distinguishable`.

## Future Directions

Engineers outside of Swift and Foundation also ship copy-on-write data structures that conform to `Equatable`. An example is `TreeDictionary` from `swift-collections`. We would like engineers to be able to easily adopt `Distinguishable` on their own types.

## Alternatives Considered

Could we "overload" the `===` operator from `AnyObject`? Because `Distinguishable` makes no promises or assumptions about the nature of the type itself, this proposal recommends keeping the `===` operator only on `AnyObject` types.

Instead of publishing an `isIdentical` function which implies two types *must* be equal, could we think of things from the opposite direction? Could we publish a `maybeDifferent` function which implies two types *might not* be equal? This then introduces some potential ambiguity for product engineers: to what extent does `maybeDifferent` imply "probably different"? This ambiguity could be settled with extra documentation on the protocol, but `isIdentical` solves that ambiguity up-front.

Without breaking ABI, we could add the `isIdentical` function directly to `Equatable`. Because we expect most types that would adopt `Distinguishable` would return `true` to indicate two instances must be equal by-value, there are arguments that this should itself belong in `Equatable`. At this point we have now coupled these two concepts and reduced the flexibility available to product engineers. A "pure" value type might conform to `Equatable` without any underlying reference that can return `true` in constant time to define identity equality in constant time. The "default" behavior on these types would be to always return `false` for `isIdentical`: we can't make any constant-time judgement about any potential value-equality.

## Acknowledgments

Thanks @dnadoba for suggesting this `isIdentical` function should exist on a new protocol.

Thanks @ben_cohen for helping to think through and generalize the original use-case and problem-statement.

Thanks @Slava_Pestov for helping to investigate ABI stability implications of a new protocol.

Thanks @lorentey for shipping the optimization on `Swift.String` that shows us a precedent for this kind of operation.[^1]

[^1]: https://github.com/swiftlang/swift/blob/swift-6.1-RELEASE/stdlib/public/core/String.swift#L397-L415
