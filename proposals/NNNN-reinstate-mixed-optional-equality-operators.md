# Reinstate Mixed-`Optional` Equality Operators

* Proposal: [SE-NNNN](NNNN-reinstate-mixed-optional-equality-operators.md)
* Author: [Jacob Bandes-Storch](https://github.com/jtbandes)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

[SE-0121](0121-remove-optional-comparison-operators.md) seeks to remove variants of `<`, `<=`, `>`, and `>=` operators which accept `Optional` parameters.

A separate proposal (not yet merged) seeks to remove implicit coercion of non-Optional to Optional values for operators.

If both proposals are accepted, `(T?, T?)` versions of the operators `==`, `!=`, `===`, and `!==` will still exist. This proposal adds `(T?, T)` and `(T, T?)` versions, so the equality/inequality operators remain usable with any permutation of Optional and non-Optional arguments.

Swift-evolution thread: [Optional comparison operators](http://thread.gmane.org/gmane.comp.lang.swift.evolution/23306)

## Motivation

While the `<`, `<=`, `>`, and `>=` may have surprising results when one parameter is Optional-valued and the other is not (as discussed in SE-0121), the meaning of `==`, `!=`, `===`, and `!==` is very clear.

The possible values of type `T?` are just the possible values of type `T` (each wrapped in `.some(_)`), plus the additional value `nil`. Equality on `T?` is simply defined by:

- for any two non-`nil` values `v` and `w` of type `T`, `.some(v) == .some(w)` if and only if `v == w`.
- for any non-`nil` value `v` of type `T`, `.some(v) != nil`.
- `nil == nil`.

This definition is unambiguous and intuitive (unlike the definitions of `<`/`<=`/`>`/`>=`).

As a simpler example, assuming

```swift
let x: Int?
let y: Int   // non-optional
```

then the "truth table" for `==` and `!=` is:

`x`  | `x == y` | `x != y`
---|----------|----------
`.none` | false | true
`.some(v)` | true iff `v == y` | true iff `v != y`

Note that [variants of `==` and `!=` already exist](https://github.com/apple/swift/blob/2a545eaa1bfd7d058ef491135cca270bc8e4be5f/stdlib/public/core/Optional.swift#L343-L381) which allow comparisons like `x == nil` and `nil != x` when `x` is Optional, *even if the wrapped type is not Equatable*, for convenience.

## Proposed solution

Ensure that all of the following operators are available, with their implementations derived from the primitive Equatable requirement `==<T: Equatable>(T, T)`:

```swift
func == <T: Equatable>(lhs: T?, rhs: T) -> Bool
func == <T: Equatable>(lhs: T, rhs: T?) -> Bool
func == <T: Equatable>(lhs: T?, rhs: T?) -> Bool

func != <T: Equatable>(lhs: T?, rhs: T) -> Bool
func != <T: Equatable>(lhs: T, rhs: T?) -> Bool
func != <T: Equatable>(lhs: T?, rhs: T?) -> Bool
```

(and the [`_OptionalNilComparisonType` versions](https://github.com/apple/swift/blob/2a545eaa1bfd7d058ef491135cca270bc8e4be5f/stdlib/public/core/Optional.swift#L343-L381))

Also ensure that the following operators are available, with their implementations derived from the primitive `===(AnyObject?, AnyObject?)`:

```swift
func === (lhs: AnyObject, rhs: AnyObject) -> Bool
func === (lhs: AnyObject?, rhs: AnyObject) -> Bool
func === (lhs: AnyObject, rhs: AnyObject?) -> Bool

func !== (lhs: AnyObject, rhs: AnyObject) -> Bool
func !== (lhs: AnyObject?, rhs: AnyObject) -> Bool
func !== (lhs: AnyObject, rhs: AnyObject?) -> Bool
```

## Detailed design

Possible implementations of these operators are as follows:

```swift
// Equality
func == <T: Equatable>(lhs: T?, rhs: T?) -> Bool {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        return lhs == rhs  // primitive Equatable operator requirement
    case (nil, nil):
        return true
    default:
        return false
    }
}
func == <T: Equatable>(lhs: T?, rhs: T) -> Bool {
    return lhs == .some(rhs)
}
func == <T: Equatable>(lhs: T, rhs: T?) -> Bool {
    return .some(lhs) == rhs
}
func != <T: Equatable>(lhs: T?, rhs: T) -> Bool {
    return !(lhs == rhs)
}
func != <T: Equatable>(lhs: T, rhs: T?) -> Bool {
    return !(lhs == rhs)
}
func != <T: Equatable>(lhs: T?, rhs: T?) -> Bool {
    return !(lhs == rhs)
}

// Identity
func === (lhs: AnyObject, rhs: AnyObject) -> Bool {
    return .some(lhs) === .some(rhs)  // primitive (AnyObject?, AnyObject?) comparator
}
func === (lhs: AnyObject?, rhs: AnyObject) -> Bool {
    return lhs === .some(rhs)
}
func === (lhs: AnyObject, rhs: AnyObject?) -> Bool {
    return .some(lhs) === rhs
}

func !== (lhs: AnyObject, rhs: AnyObject) -> Bool {
    return !(lhs === rhs)
}
func !== (lhs: AnyObject?, rhs: AnyObject) -> Bool {
    return !(lhs === rhs)
}
func !== (lhs: AnyObject, rhs: AnyObject?) -> Bool {
    return !(lhs === rhs)
}
```

## Impact on existing code

None. The proposal seeks to prevent existing code from being broken by the removal of coercion of operator arguments.

## Alternatives considered

The alternative is to keep only the `(T, T)` and `(T?, T?)` versions of these operators. SE-0121 argues that mixed-optionality operators for `<`/`<=`/`>`/`>=` operators should be removed. Some might say the same argument applies to `==`/`!=`/`===`/`!==`, but I believe the meaning of equality in the context of optionals and mixed-optionals is clear enough, and its results sufficiently unsurprising, that it's worth keeping these variants.

