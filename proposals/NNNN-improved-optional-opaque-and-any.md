# Improved Syntax for Optionals of Opaque and Existential Types

* Proposal: [SE-NNNN](NNNN-improved-optional-opaque-and-any.md)
* Authors: [Tony Allevato](https://github.com/allevato)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#87115](https://github.com/swiftlang/swift/pull/87115)

## Summary of changes

Allows the types `some P?` and `any P?` to be written, having the same meaning as `(some P)?` and `(any P)?` respectively.

## Motivation

Swift supports opaque types written `some P` and explicit existential types written `any P`, for some protocol `P`. However, due to parsing precedence, combining these types with optional type sugar (`?` and its implicitly unwrapped version `!`) currently requires wrapping the type in parentheses, such as `(some P)?` or `(any P)?`.

Developers frequently attempt to write `some P?` or `any P?` due to familiarity with standard optional syntax (e.g., `Int?`, `String?`). These forms are currently rejected, because they are interpreted as `some (P?)` and `any (P?)`. The constraint following `some` or `any` must be a protocol, which `P?` (that is, `Optional<P>`), is not.

It is unlikely that a future version of Swift would ever define `some/any P?` to have a meaning other than what users would intuitively expect: an `Optional` of an opaque/existential type that conforms to `P`. However, a future version of Swift may **require** explicit `any` for existential types, meaning that there would likely be a proliferation of parentheses wherever optional existentials are used. Therefore, this simpler syntax improves ergonomics and readability.

## Proposed solution

We propose to make `some P?` equivalent to `(some P)?` and `any P?` equivalent to `(any P)?`.

This extends to multiple levels of optionality. For example, `some/any P??` will be equivalent to `(some/any P)??`, for any optionality depth.

Likewise, implicitly unwrapped optionals receive the same treatment wherever they are already supported. This proposal would make `any P!` equivalent to `(any P)!`.

## Detailed design

### Parser

This proposal does **not** change the parsing rules of the language. `some P?` will still be parsed as it is today, producing a `TypeRepr` with the shape `OpaqueResultTypeRepr(OptionalTypeRepr(P))` (and likewise for `any P?`). `TypeRepr`s are defined as the "[r]epresentation of a type as written in source", and we wish to continue honoring that definition.

### Type Checking

When the type checker resolves an opaque or existential type whose constraint is an optional or implicitly unwrapped optional type, it will look through the type sugar to find the actual protocol constraint. As it does so, it will remember the depth of optionality so that the resolved type can be rewrapped correctly.

Special care is needed during name lookup when handling `some` types in function parameter positions. These use a slightly different code path because they are hoisted into the function's generic signature as anonymous type parameters. That is, we need to ensure that `f(_: some P?)` is treated as `f<T: P>(_: T?)` and not the nonsensical `f<T: P?>(_: T)`.

### Fix-its

Compiler fix-its for explicit existential `any` no longer insert parentheses when the existential type is optional or implicitly unwrapped optional. For example, when the following code is compiled with `-enable-experimental-feature ExistentialAny` today:

```swift
let x: P?
```

it generates the following diagnostic and fix-it:

```
warning: use of protocol 'P' as a type must be written 'any P'; this will be an error in a future Swift language mode
    let x: P?
           ^~~~~~~
           (any P)
```

This proposal changes the fix-it replacement to be `any P` rather than `(any P)`.

## Source compatibility

This is a purely additive change to the valid syntax of the language. Code that previously failed to compile (e.g., `some P?`) will now compile with the expected semantics.

Existing code that explicitly uses parentheses (e.g., `(some P)?`) remains valid and semantically identical.

## Effect on ABI stability

This proposal has no effect on ABI stability. The types `some/any P?` and `(some/any P)?`—and thus their manglings—are identical.

## Effect on API resilience

This proposal has no effect on API resilience.

## Alternatives considered

**Do nothing**: We could continue requiring parentheses. However, this remains a common source of frustration for users adopting `some` and `any`.

## Acknowledgments

Thanks to the Swift team for their prior work on opaque and existential types.
