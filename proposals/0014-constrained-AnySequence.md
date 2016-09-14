# Constraining `AnySequence.init`

* Proposal: [SE-0014](0014-constrained-AnySequence.md)
* Author: [Max Moiseev](https://github.com/moiseev)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 2.2)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-January/000008.html)
* Bug: [SR-474](https://bugs.swift.org/browse/SR-474)


## Introduction

In order to allow `AnySequence` delegate calls to the underlying sequence,
its initializer should have extra constraints.

[Swift Evolution Discussion](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/000910.html)

## Motivation

At the moment `AnySequence` does not delegate calls to `SequenceType` protocol
methods to the underlying base sequence, which results in dynamic downcasts in
places where this behavior is needed (see default implementations of
`SequenceType.dropFirst` or `SequenceType.prefix`). Besides, and this is even
more important, customized implementations of `SequenceType` methods would be
ignored without delegation.

## Proposed solution

See the implementation in [this PR](https://github.com/apple/swift/pull/220).

In order for this kind of delegation to become possible, `_SequenceBox` needs to
be able to 'wrap' not only the base sequence but also its associated
`SubSequence`. So instead of being declared like this:

~~~~Swift
internal class _SequenceBox<S : SequenceType>
    : _AnySequenceBox<S.Generator.Element> { ... }
~~~~

it would become this:

~~~~Swift
internal class _SequenceBox<
  S : SequenceType
  where
    S.SubSequence : SequenceType,
    S.SubSequence.Generator.Element == S.Generator.Element,
    S.SubSequence.SubSequence == S.SubSequence
> : _AnySequenceBox<S.Generator.Element> { ... }
~~~~

Which, in its turn, will lead to `AnySequence.init` getting a new set of
constraints as follows.

Before the change:

~~~~Swift
public struct AnySequence<Element> : SequenceType {
  public init<
    S: SequenceType
    where
      S.Generator.Element == Element
  >(_ base: S) { ... }
}
~~~~

After the change:

~~~~Swift
public struct AnySequence<Element> : SequenceType {
  public init<
    S: SequenceType
    where
      S.Generator.Element == Element,
      S.SubSequence : SequenceType,
      S.SubSequence.Generator.Element == Element,
      S.SubSequence.SubSequence == S.SubSequence
  >(_ base: S) { ... }
}
~~~~

These constraints, in fact, should be applied to `SequenceType` protocol itself
(although, that is not currently possible), as we expect every `SequenceType`
implementation to satisfy them already. Worth mentioning that technically
`S.SubSequence.SubSequence == S.SubSequence` does not have to be this strict,
as any sequence with the same element type would do, but that is currently not
representable.

## Impact on existing code

New constraints do not affect any built-in types that conform to
`SequenceType` protocol as they are essentially constructed like this
(`SubSequence.SubSequence == SubSequence`). 3rd party collections, if they use
the default `SubSequence` (i.e. `Slice`), should also be fine. Those having
custom `SubSequence`s may stop conforming to the protocol.
