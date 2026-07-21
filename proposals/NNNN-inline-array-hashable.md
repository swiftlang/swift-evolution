# InlineArray: Hashable

* Proposal: [SE-NNNN](NNNN-inline-array-hashable.md)
* Authors: Alejandro Alonso and Steve Canon
* Review Manager: TBD
* Status: **Awaiting review**

## Summary of changes

InlineArray conditionally conforms to Equatable and Hashable when Element does.

## Motivation

Not having these conformances is pretty annoying.

## Proposed solution

Add the missing conformances.

## Detailed design

That's it. That's the whole design.

Ok, fine:

- The element hashes are mixed in index order.
- Equality is permitted but not required to early-out (i.e. the implementation
  does not guarantee that `InlineArray.==` is constant time, nor does it
  guarantee not to access any elements after the first mismatch).

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

The actual protocol conformance implementations will back-deploy to the
introduction of InlineArray, allowing users to declare their own retroactive
conformance if needed.

## Future directions

None worth mentioning.

## Alternatives considered

None worth mentioning.
