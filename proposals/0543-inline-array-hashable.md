# InlineArray: Hashable

* Proposal: [SE-0543](0543-inline-array-hashable.md)
* Authors: [Alejandro Alonso](https://github.com/Azoy), [Steve Canon](https://github.com/stephentyrone)
* Review Manager: [Xiaodi Wu](https://github.com/xwu)
* Status: **Active Review (August 7...17, 2026)**
* Implementation: https://github.com/swiftlang/swift/pull/91004
* Review: ([pitch](https://forums.swift.org/t/conform-inlinearray-to-hashable/88432)) ([review](https://forums.swift.org/t/se-0543-inlinearray-hashable/88843))


## Summary of changes

InlineArray conditionally conforms to Equatable and Hashable when Element does.

## Motivation

Not having these conformances is pretty annoying.

## Proposed solution

Add the missing conformances.

## Detailed design

That's it. That's the whole design.

Ok, fine:

- These conformances implement elementwise equality, not identity.
- Every element of the InlineArray is included in the hash.
- Equality is permitted but not required to early-out (i.e. the implementation
  does not guarantee that `InlineArray.==` is constant time, nor does it
  guarantee not to access any elements after the first mismatch).

Both operations have O(n) complexity.

## Source compatibility

If you wrote your own extension to provide these conformances, you should be
able to delete it with minimal fuss, unless you implemented wildly different
semantics for some reason. That was a bad idea.

We are adding an Equatable conformance to another type. This slightly enlarges
the set of candidates for expressions involving `==` or `!=`, and might result
in needing to break up or disambiguate expressions that are right at the limit
of typechecker performance today.

## ABI compatibility

N/A

## Implications on adoption

The methods implementing the protocol requirements will back-deploy to the
introduction of InlineArray, allowing users to declare their own retroactive
conformance if needed.

## Future directions

None worth mentioning.

## Alternatives considered

Implement identity rather than elementwise equality. This is arguably also a
valid choice, but it's neither interesting nor particularly useful.
