# Remove Some Customization Points from the Standard Library's `Collection` Hierarchy

* Proposal: [SE-0232](0232-remove-customization-points.md)
* Author: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Implemented (Swift 5)**
* Implementation: [apple/swift#19995](https://github.com/apple/swift/pull/19995)
* Review: [Discussion thread](https://forums.swift.org/t/se-0232-remove-some-customization-points-from-the-standard-librarys-collection-hierarchy/17265), [Announcement thread](https://forums.swift.org/t/accepted-se-0232-remove-some-customization-points-from-the-standard-librarys-collection-hierarchy/17560)

## Introduction

This proposal removes four customization points from protocols in the
standard library:

- `map`, `filter`, and `forEach` from `Sequence`
- `first`,  `prefix(upTo:)`, `prefix(through:)`, and `suffix(from:)` from `Collection`
- `last` on `BidirectionalCollection`

The default implementations of these symbols will remain, so sequences and
collections will continue to have the same operations available that they
do today.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/pitch-remove-some-customization-points-from-the-std-lib-collection-protocols/16911/)

## Motivation

Customization points are methods that are declared on the protocol, as well as
given default implementations in an extension. This way, when a type provides
its own non-default implementation, this will be dispatched to in a generic
context (e.g. when another method defined in an extension on the protocol calls
the customized method). Without a customization point, the default
implementation is called in the generic context.

This serves broadly two purposes:

1. Allowing for differences in behavior. For example, an "add element" method on
  a set type might exclude duplicates while on a bag it might allow them.

2. Allowing for more efficient implementations. For example, `count` on
  forward-only collections takes O(n) (because without random access, the
  implementation needs to iterate the collection to count it). But some
  collection types might know their `count` even if they aren't random access.
  
Once ABI stability has been declared for a framework, customization points can
never be removed, though they can be added.

Customization points aren't free – they add a small cost at both compile time
and run time. So they should only be added if there is a realistic possibility
that either of the two reasons above apply. 

In the case of the customization points in this proposal, reason 1 does not
apply. In fact it could be considered a serious bug if any type implemented
these features with anything other than the default observable behavior.

It is also hard to find a good use case for reason 2 – whereas slight slowdowns
and code size bloat from the presence of the customization points have been observed.
In some cases (for example `suffix(from:)`), the implementation is so simple that
there is no reasonable alternative implementation.

While it is possible that a resilient type's `forEach` implementation might be able 
to eke out a small performance benefit (for example, to avoid the reference count 
bump of putting `self` into an iterator), it is generally harmful to encourage this
kind of "maybe forEach could be faster" micro-optimization. For example, see
[here](https://github.com/apple/swift/pull/17387), where error control flow was
used in order to break out of the `forEach` early, causing unpleasant
interference for debugging workflows that detected when errors were thrown.

### Future move-only type considerations

In the case of `first` and `last` there is an additional consideration: in the
future, collections of move-only types (including `Array`) will not be able
to reasonably fulfil these requirements.

A collection that contains move-only types will only allow elements to be
either removed and returned (e.g. with `popLast()`), or borrowed (e.g. via
`subscript`).

Returning an optional to represent the first element fits into neither of these
buckets. You cannot write a generic implementation of `first` that fetches the
first move-only element of a collection using a subscript, moves it into an
optional, and then returns that optional.

This means `first` and `last` need to be removed as requirements on the
collection protocols in order to make it possible for collections of move only
types to conform to them.

They would remain on `Collection` via extensions. When move-only types are
introduced, those extensions will be constrained to the collection element
being copyable.

Once the final functionality for move-only types is designed, it may be that
language features will be added that allow for borrowing into an optional,
allowing even collections of move-only types to implement a `first` property.
But it's better to err on the side of caution for now and remove them from
the protocol.

## Proposed solution

Remove these customization points from the `Collection` protocols. The
default implementations will remain. 

## Source compatibility

These are customization points with an existing default implementation, so
there is no effect on source stability.

It is theoretically possible that removing these customization points could
result in a behavior change on types that rely on the dynamic dispatch to add
additional logic. However, this would be an extremely dubious practice e.g.
`MyCollection.first` should really never do anything more than return the first
element.

## Effect on ABI stability

Removing customization points is not an ABI-stable operation. The driver for
this proposal is to do this before declaring ABI stability.

## Effect on API resilience

None

## Alternatives considered

Leave them in. Live with the slight code/performance impact in the case of `map` and `forEach`, and work around the issue when designing move-only types.
