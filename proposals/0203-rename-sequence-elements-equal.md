# Rename Sequence.elementsEqual

* Proposal: [SE-0203](0203-rename-sequence-elements-equal.md)
* Author: [Xiaodi Wu](https://github.com/xwu)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Rejected**
* Implementation: [apple/swift#12884](https://github.com/apple/swift/pull/12884)
* Bugs: [SR-6102](https://bugs.swift.org/browse/SR-6102)
* Review thread: [Swift evolution forum](https://forums.swift.org/t/se-0203-rename-sequence-elementsequal/11482)

## Introduction

The behavior of `Sequence.elementsEqual` is confusing to users given its name. Having surveyed alternative solutions to this problem, it is proposed that the method be renamed to `Sequence.elementsEqualInIterationOrder`.

Swift-evolution thread: [Rename Sequence.elementsEqual](https://forums.swift.org/t/draft-rename-sequence-elementsequal/6821)

## Motivation

[As Ole Begemann describes](https://twitter.com/olebegemann/status/916291785185529857), use of `Sequence.elementsEqual(_:)` can lead to surprising results for two instances of `Set`:

```swift
var set1: Set<Int> = Set(1...5)
var set2: Set<Int> = Set((1...5).reversed())

set1 == set2 // true
set1.elementsEqual(set2) // false
```

In almost all circumstances where a set is compared to another set or a dictionary is compared to another dictionary, users should use `==`, which is order-insensitive, instead of `elementsEqual(_:)`, which is order-sensitive.

[As Michael Ilseman explains](https://forums.swift.org/t/draft-rename-sequence-elementsequal/6821/152):

> We have two forms of equality we're talking about: equality of Sequence and equality of the elements of Sequences in their respective ordering. `==` covers the former, and I'll use the existing (harmful) name of `elementsEqual` for the latter.
>
> `==` conveys substitutability of the two Sequences. This does not necessarily entail anything about their elements, how those elements are ordered, etc., it just means two Sequences are substitutable. `elementsEqual` means that the two Sequences produce substitutable elements. These are different concepts and both are independently useful.
>
> Cases:
>
> 1. Two Sequences are substitutable and produce substitutable elements when iterated. `==` and `elementsEqual` both return true.
>
> Example: Two arrays with the same elements in the same order.
>
> 2. Two Sequences are substitutable, but do not produce substitutable elements when iterated. `==` returns true, while `elementsEqual` returns false.
>
> Example: Two Sets that contain the same elements but in a different order.
>
> Contrived Example: Two Lorem Ipsum generators are the same generator (referentially equal, substitutable for the purposes of my library), but they sample the user’s current battery level (global state) each time they produce text to decide how fancy to make the faux Latin. They’re substitutable, but don’t generate the same sequence.
>
> 3. Two Sequences are not substitutable, but produce substitutable elements when iterated. `==` returns false, while `elementsEqual` returns true.
>
> Example: Consider two sequences that have differing identity. `==` operates on an identity level, `elementsEqual` operates at an element level.
>
> Contrived Example: InfiniteMonkeys and Shakespeare both produce the same sonnet, but they’re not substitutable for my library’s purposes.
>
> 4. Two Sequences are not substitutable and don’t produce substitutable elements when iterated. `==` and `elementsEqual` both return false.
>
> Example: `[1,2,3]` compared to `[4,5,6]`
>
> It is true that situations #2 and #3 are a little harder to grok, but they are what illustrate the subtle difference at hand. I think situation #2 is the most confusing, and has been the primary focus of this thread as Set exists and exhibits it.

## Proposed solution

The method `elementsEqual(_:)` is listed as an ["order-dependent operation"](https://developer.apple.com/documentation/swift/set/order_dependent_operations_on_set) in Apple documentation. However, its name does not suggest that it performs an order-sensitive comparison. (Other "order-dependent operations" incorporate words that clearly suggest order dependence in the name, such as "first," "last," "prefix," "suffix," and so on.)

> These "order-dependent operations" are available for use because `Set` and `Dictionary` conform to `Sequence`. Major changes to the protocol hierarchy for Swift standard library collection types are out of the scope of this proposal, if not out of scope for Swift 5 entirely.

The proposed solution is the result of an iterative process of reasoning, presented here:

The first and most obvious solution is to remove the `elementsEqual(_:)` method altogether in favor of `==`. This prevents its misuse. However, because `elementsEqual(_:)` is a generic method on `Sequence`, we can use it to compare an instance of `UnsafeBufferPointer<Int>` to an instance of `[Int]`. This is a potentially useful and non-redundant feature which would be eliminated if the method is removed altogether.

[A second solution](https://github.com/apple/swift/pull/12318) is to create overloads that forbid the use of `elementsEqual(_:)` method specifically in non-generic code that uses sets or dictionaries. This would certainly prevent misuse in non-generic code. However, it would also forbid legitimate mixed-type comparisons in non-generic code, and it would not prevent misuse in generic code. This solution also creates a difference in the behavior of generic and non-generic code that calls the same method, which is confusing, without solving the problem completely.

A third solution is proposed here. It is predicated on the following observation:

*Another method similar to `elementsEqual(_:)` exists on `Sequence` named `lexicographicallyPrecedes(_:)`. Like `prefix(_:)` and others, it is an order-dependent operation not completely suitable for an unordered collection. However, like `prefix(_:)` and unlike `elementsEqual(_:)`, this fact is called out in the name of the method. Unsurprisingly, like `prefix(_:)` and unlike `elementsEqual(_:)`, there is no evidence that `lexicographicallyPrecedes(_:)` has been a pitfall for users.*

This observation suggests that a major reason for confusion over `elementsEqual(_:)` stems from its name. So, __it is proposed that `elementsEqual(_:)` should be renamed__.

Initially, the suggested name for this method was **`lexicographicallyMatches`**, to parallel `lexicographicallyPrecedes`. This was opposed on two grounds:

* The term __matches__ suggests a connection to pattern matching which does not exist.
* The term __lexicographically__ is unfamiliar to users, is inaccurate in the absence of a total ordering (i.e., where `Sequence.Element` does not conform to `Comparable`), and could erroneously suggest that the receiver and argument could themselves be re-ordered for comparison.

Alternative suggestions used terms such as __pairwise__, __iterative__, __ordered__, or __sequential__. A revised name that aims for call-site clarity while incorporating these suggestions would be **`equalsInIterationOrder`**.

However, the name should reflect the distinction, explained above, between equality of sequences and equality of their elements. It remains important for the renamed method to clarify that it is performing a comparison operation based on `Sequence.Element.==` and not `Sequence.==`. Therefore, incorporating this insight, the proposed name for the method is **`elementsEqualInIterationOrder`**.

## Detailed design

```swift
extension Sequence where Element : Equatable {
  @available(swift, deprecated: 5, renamed: "elementsEqualInIterationOrder(_:)")
  public func elementsEqual<Other : Sequence>(
    _ other: Other
  ) -> Bool where Other.Element == Element {
    return elementsEqualInIterationOrder(other)
  }
  
  public func elementsEqualInIterationOrder<Other : Sequence>(
    _ other: Other
  ) -> Bool where Other.Element == Element {
    // The body of this method is unchanged.
    var iter1 = self.makeIterator()
    var iter2 = other.makeIterator()
    while true {
      switch (iter1.next(), iter2.next()) {
      case let (e1?, e2?):
        if e1 != e2 { return false }
      case (_?, nil), (nil, _?):
        return false
      case (nil, nil):
        return true
      }
    }
  }
}
```

A parallel change will be made with respect to `elementsEqual(_:by:)`; that is, it will be renamed to `elementsEqualInIterationOrder(_:by:)`.

## Source compatibility

Existing code that uses `elementsEqual` will gain a deprecation warning.

## Effect on ABI stability

None.

## Effect on API resilience

This proposal adds new methods to the public API of `Sequence` and conforming types.

## Alternatives considered

It is to be noted that `lexicographicallyPrecedes(_:by:)` and `elementsEqual(_:by:)` are very closely related methods. However, they cannot be unified because they handle sequences of dissimilar count differently.

Along those same lines, the manner in which `lexicographicallyPrecedes(_:)` and `lexicographicallyPrecedes(_:by:)` compare sequences of dissimilar count is described by the term __lexicographical__ ("a" < "aa" < "aaa" < "ab"), in contradistinction to __length-lexicographical__ (__shortlex__) ordering ("a" < "aa" < "ab" < "aaa") or __Kleene–Brouwer__ ordering ("aaa" < "aa" < "ab" < "a"). Though strictly redundant, the name could be modestly clarified by expanding it to `lexicographicallyPrecedesInIterationOrder`; however, the name cannot be shortened to `precedesInIterationOrder` without losing information as to the comparison performed. In the absence of evidence that users are using this method incorrectly, the additional consistency gained by adding "in iteration order" to the name is outweighed by the source-breaking nature of the change and the unwieldy end result.

An entirely different solution to the motivating problem is to have sets internally reorder themselves prior to any order-dependent operations so that iteration order is guaranteed to be the same for sets which compare equal. As a result, `==` and `elementsEqual` would become equivalent when comparing two sets. Few (if any) other order-dependent operations would benefit from such a change, however, as the result of `first` remains arbitrary with or without it. There could potentially be a performance cost imposed on all users of sets, and the resulting benefit would be two functionally equivalent methods, which does not make possible any additional uses for the type.
