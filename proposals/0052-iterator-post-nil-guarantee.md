# Change IteratorType post-nil guarantee

* Proposal: [SE-0052](https://github.com/apple/swift-evolution/blob/master/proposals/0052-iterator-post-nil-guarantee.md)
* Author(s): [Patrick Pijnappel](https://github.com/PatrickPijnappel)
* Status: **Awaiting review**
* Review manager: TBD

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

Swift-evolution thread: [\[Proposal\] Change guarantee for GeneratorType.next() to always return nil past end](http://thread.gmane.org/gmane.comp.lang.swift.evolution/8519)

Pull-request: [#1702](https://github.com/apple/swift/pull/1702)

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

Requiring `nil` to be returned indefinitely does require the implementors of
custom `IteratorType` conformances to respect this, but this is likely already
the expectation for most users. Most iterators already get this as a natural
consequence of their implementation (as is the case with all current standard
library iterators), but otherwise they can simply track a `done` flag to do so.
It should be noted that this requirement would also affect closures passed to
`AnyIterator`.

### Performance considerations
The original rationale for introducing the precondition was because of concerns
it might add storage and performance burden to some implementations of
`IteratorType` (see [here](http://article.gmane.org/gmane.comp.lang.swift.evolution/8532)).

However, in light of implementation experience, there are a few observations we
can make:
- These cases are rare. The standard library currently has no iterators that
require extra state or branches to return `nil` indefinitely. The iterator for
the proposed `takeWhile()` ([SE-0045](https://github.com/apple/swift-evolution/blob/master/proposals/0045-scan-takewhile-dropwhile.md))
would be the first occurance in the standard library.
- Even in such cases, in the common case the calling code doesn't rely on
post-`nil` behavior (e.g. `for in`, `map`, etc.) this extra storage and
branching can usually optimized away.
- Not having the post-`nil` guarantee can sometimes add storage and performance
burden for the caller instead, e.g. when an iterator somehow buffers it's
underlying iterator. This in contrast can usually not be optimized away. For
example, the standard library's UTF-8/UTF-16 decoding has 4 instead of 3 branches
per character for ASCII because of this.

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

- Require `IteratorType` to not crash but keep the return value up to specific
implementations. This allows them to use it for other behavior e.g. repeating
the sequence after `nil` is returned. This however retains most of the problems
of the original guaranteee described in this proposal.
