# Change IteratorType post-nil guarantee

* Proposal: [SE-0052](0052-iterator-post-nil-guarantee.md)
* Author: [Patrick Pijnappel](https://github.com/PatrickPijnappel)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000135.html)
* Implementation: [apple/swift#1702](https://github.com/apple/swift/pull/1702)

## Introduction

Currently, the documentation for `IteratorType.next()` has the precondition
that when calling `next()`, no preceding call to `next()` should have returned
`nil`, and in fact encourages implementations to raise a `preconditionFailure()`
for violations of this requirement. However, all current 27 `IteratorType`
implementations in the standard library return `nil` indefinitely. Many users
are likely unaware of the precondition, expecting all iterators to return
`nil` indefinitely and writing code that might rely on this assumption. Such
code will usually run fine, until someone does in fact pass in an iterator not
repeating `nil` (it's a silent corner case).

Swift-evolution thread: [\[Proposal\] Change guarantee for GeneratorType.next() to always return nil past end](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160229/011699.html)

## Motivation

While not overwhelmingly common, it is relatively easy to write code based on the
assumption `nil` will be returned indefinitely:

``` swift
// Example based on standard library code (Sequence.swift)
while let element = iterator.next() {
  if condition(element) {
    foo(element) // call foo on first element satisfying condition
    break
  }
}
while let element = iterator.next() {
  bar(element) // call bar on remaining elements
}

// Another example
switch (iterator.next(), iterator.next()) {
// ...
}
```

Even though this can be trivially rewritten to not rely on post-`nil` behavior,
the user won't perform this rewrite if they are unaware of the precondition. In
their testing the code will work fine, and likely will in almost every case,
except when passing the rare iterator that doesn't repeat `nil`.

## Proposed solution

Bring the guarantee in line with the common expectation, and require iterators
to return `nil` indefinitely.

The rest of this section will compare the current guarantee (post-`nil` unspecified)
with the proposed guarantee (post-`nil` always `nil`) on a few different areas.

### Safety
In both cases, there is someone that could make a mistake with post-`nil` behavior:
- **Current:** Callers could be unaware that iterators don't always keep returning `nil`.
- **Proposed:** Implementors of custom iterators could be unaware they should keep returning `nil`.

Both cases are silent, i.e. they don't show with most usage. However the mistake is less likely in the proposed case:
- Iterators returning `nil` indefinitely is probably what most people expect, especially since all iterators in the standard library do this (and likely many custom iterators as well).
- Implementors are probably more likely than callers to check the API contract.

Some have argued that it's risky to rely on people adhering to the API contract, an argument that can be made for either case:
a) "Writing an iterator that doesn't repeat `nil` is risky as the caller might not adhere to the API contract, so just make all iterators repeat `nil` anyway."
b) "Writing code that relies on the iterator repeating `nil` is risky as the implementor might not adhere to the API contract, so just track state and branch in that code anyway."
This however kind of defeats the purpose of having an API contract.

### Frequency
In both cases, sometimes code needs to track extra state and branch:
- **Current:** Callers sometimes need to track a bool and branch. The standard library currently has 3 occurrences of this being necessary ([#1](https://github.com/apple/swift/blob/master/stdlib/public/core/Sequence.swift#L435), [#2](https://github.com/apple/swift/blob/master/stdlib/public/core/Unicode.swift#L128), [#3](https://github.com/apple/swift/blob/master/stdlib/public/core/Unicode.swift#L373)).
- **Proposed:** Iterator implementations sometimes need to track a bool and branch. The standard library currently has no occurrences of this being necessary. If [SE-0045](0045-scan-takewhile-dropwhile.md) is accepted, it will introduce the first case (out of 30 iterators), `TakeWhileIterator`.

### Performance considerations
In both cases, the extra state and branching that is sometimes needed has potential for performance implications. Though performance is not the *key* concern, iterators are often used in tight loops and can affect very commonly used algorithms. The original rationale for introducing the precondition was in fact because of concerns it might add storage and performance burden to some implementations of `IteratorType`. However in light of implementation experience, it appears including the guarantee would likely be beneficial for performance:

- **Current:** Callers sometimes need to track a bool and branch, which can usually not be optimized away. This can be somewhat significant, for example UTF-8 decoding would be ~25% faster on ASCII input with the proposed guarantee (see [here](https://gist.github.com/PatrickPijnappel/3241bba66acab9c8913f)).
- **Proposed:** Iterator implementations sometimes need to track a bool and branch, which can usually be optimized away when not needed by the caller (e.g. in a `for in` loop). Note that when post-`nil` behavior is relied upon, the caller would have had to track state and branch already if the iterator didn't.

## Detailed design

Original guarantee:

``` swift
/// Advance to the next element and return it, or `nil` if no next
/// element exists.
///
/// - Precondition: `next()` has not been applied to a copy of `self`
///   since the copy was made, and no preceding call to `self.next()`
///   has returned `nil`.  Specific implementations of this protocol		
///   are encouraged to respond to violations of this requirement by		
///   calling `preconditionFailure("...")`.
```

Proposed guarantee:

``` swift
/// Advance to the next element and return it, or `nil` if no next element
/// exists.  Once `nil` has been returned, all subsequent calls return `nil`.
///
/// - Precondition: `next()` has not been applied to a copy of `self`
///   since the copy was made.
```

## Impact on existing code

All `IteratorType` implementations in the standard library already comply with
the new guarantee. It is likely most existing custom iterators will as well,
however some might be rendered in violation of their guarantee by the change.

## Alternatives considered

- Add a `FuseIterator` type to the standard library that can wrap any iterator
to make it return `nil` indefinitely (constructed using `.fuse()`), and leave
the guarantee for `next()` as is. This however doesn't really solve most problems
described in this proposal and adds a rarely used type to the standard library.

- Require `IteratorType` to not crash but keep the return value up to specific
implementations. This allows them to use it for other behavior e.g. repeating
the sequence after `nil` is returned. This however retains most of the problems
of the original guaranteee described in this proposal.
