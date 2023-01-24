# Remove `+` on `StaticBigInt`

* Proposal: [SE-NNNN](NNNN-formally-remove-bigint-plus.md)
* Author: [Stephen Canon](https://github.com/stephentyrone)
* Review Manager: TBD
* Status: **Pending Review**
* Implementation: [apple/swift#62733](https://github.com/apple/swift/pull/62733)

## Introduction
[SE-0368](https://forums.swift.org/t/se-0368-staticbigint/59421) included the following operation on StaticBigInt:
```
/// Returns the given value unchanged.
public static prefix func + (_ rhs: Self) -> Self
```
This was included so that prefix `+` could be included as a literal prefix in contexts where the type is StaticBigInt, rather than literals of another type, for symmetry with `-`:
```
let signs: [StaticBigInt] = [-1, 0, +1]
```

It turns out that this was a accidental source breaking change, because of examples like the following:
```
let a: Int = 7
let b = +1     // Inferred as `StaticBigInt` because concrete `+` beats
               // the generic one on `AdditiveArithmetic`
let c = a + b  // Error: Cannot convert `b` from `StaticBigInt` to `Int`
```
(Previously, b was given type Int, and this example compiled correctly.)
This was discovered after SE-0368 was accepted and implemented.
In order to restore source compatibility, I removed this operator in https://github.com/apple/swift/pull/62733.

This proposal would formally amend SE-0368 to remove the operation, bringing the accepted state of swift-evolution in-line with the language as implemented.

## Detailed design

Remove the prefix `+` operator on `StaticBigInt`:
```
- /// Returns the given value unchanged.
- public static prefix func + (_ rhs: Self) -> Self {
-   rhs
- }
```

## Source compatibility

Accepting this proposal restores source compatibility in the language as defined by swift-evolution to the pre-SE-0368 state.

## Effect on ABI stability

None.

## Effect on API resilience

None.

## Alternatives considered

We could keep prefix `+` around but implement it in a different fashion.
However, at this point there is little value in doing so.
No existing Swift programs need it, and contexts where it would make an actual difference are few and far between; it will only ever matter when you explicitly want to have values of type `StaticBigInt`, which is rare.
If it turns out that people have significant use cases for this operation in the future, we can consider a proposal to add it via some other mechanism.
