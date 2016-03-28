# Add `find` method to `SequenceType`

* Proposal: [SE-0032](https://github.com/apple/swift-evolution/blob/master/proposals/0032-sequencetype-find.md)
* Author(s): [Kevin Ballard](https://github.com/kballard)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Add a new extension method to `SequenceType` called `find()` that returns the
found element.

Swift-evolution thread: [Proposal: Add function SequenceType.find()](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151228/004814.html)

## Motivation

It's often useful to find the first element of a sequence that passes some given
predicate. For `CollectionType`s you can call `indexOf()` and pass the resulting
index back into the `subscript`, but this is a bit awkward. For `SequenceType`s,
there's no easy way to do this besides a manual loop that doesn't require
filtering the entire sequence and producing an array.

I have seen people write code like `seq.lazy.filter(predicate).first`, but this
doesn't actually work lazily because `.first` is only a method on
`CollectionType`, which means the call to `filter()` ends up resolving to the
`SequenceType.filter()` that returns an Array instead of to
`LazySequenceType.filter()` that returns a lazy sequence. Users typically aren't
aware of this, which means they end up doing a lot more work than expected.

## Proposed solution

Extend `SequenceType` with a method called `find()` that takes a predicate and
returns an optional value of the first element that passes the predicate, if
any.

## Detailed design

Add the following extension to `SequenceType`:

```swift
extension SequenceType {
  /// Returns the first element where `predicate` returns `true`, or `nil`
  /// if such value is not found.
  public func find(@noescape predicate: (Self.Generator.Element) throws -> Bool) rethrows -> Self.Generator.Element? {
    for elt in self {
      if try predicate(elt) {
	return elt
      }
    }
    return nil
  }
}
```

## Impact on existing code

None, this feature is purely additive.

In theory, we might provide an automatic conversion from
`seq.filter(predicate).first` or `seq.lazy.filter(predicate).first` to
`seq.find(predicate)`, although the existing code would continue to compile just
fine.

## Alternatives considered

None
