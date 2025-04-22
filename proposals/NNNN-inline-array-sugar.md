# `InlineArray` Literal Syntax

* Proposal: [SE-NNNN](0354-inline-array-sugar.md)
* Authors: [Hamish Knight](https://github.com/hamishknight), [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: TBD
* Status: **Awaiting Review**
* Upcoming Feature Flag: `InlineArrayTypeSugar`

## Introduction

We propose the introduction of type sugar for the `InlineArray` type, providing more succinct syntax for declaring an inline array.

## Motivation

[SE-0453] introduced a new type, `InlineArray`, which includes a size parameter as part of its type:

```
let fiveIntegers: InlineArray<5, Int> = .init(repeating: 99)
```

Declaring this type is more cumbersome than its equivalent dyanmicaly-sized array, which has sugar for the type syntax:

```
let fiveIntegers: [Int] = .init(repeating: 99, count: 5)
```

This becomes more pronounced when dealing with multiple dimensions:

```
let fiveByFive: InlineArray<5, InlineArray<5, Int>> = .init(repeating: .init(repeating: 99))
```

## Proposed solution

A new sugared version of the `InlineArray` type is proposed:

```swift
let fiveIntegers: [5 x Int] = .init(repeating: 99)
```

## Detailed design

The new syntax consists of the value for the integer generic paramter and the type of the element generic paramter, separated by `x`.

This will be added to the grammar alongside the current type sugar:

> **Grammar of a type**
> _type → sized-array-type_
>
> **Grammar of a sized array type**
> _sized-array-type → [ expression `x` type ]_

Note that while the grammar allows for any expression, this is currently limited to only integer literals.

The new sugar is equivalent to declaring a type of `InlineArray`, so all rules that can be applied to the generic placeholders for the unsugared version also apply to the sugared version:

```
// Nesting
let fiveByFive: InlineArray<5, InlineArray<5, Int>> = .init(repeating: .init(repeating: 99))
let fiveByFive: [5 x [5 x Int]] = .init(repeating: .init(repeating: 99))

// Inference from context:
let fiveIntegers: [5 x _] = .init(repeating: 99)
let fourBytes: [_ x Int8] = [1,2,3,4]
let fourIntegers: [_ x _] = [1,2,3,4]

// use on rhs
let fiveDoubles = [5 x _](repeating: 1.23)
```

The sugar can also be used in place of the unsugared type wherever it might appear:

```
[5 x Int](repeating: 99)
MemoryLayout<[5 x Int]>.size
unsafeBitCast((1,2,3), to: [3 x Int].self)
```

There must be whitespace on either side of the separator i.e. you cannot write `[5x Int]`. There are no requirements to balance whitespace, `[5     x Int]` is permitted. A new line can appear after the `x` but not before it, as while this is not ambiguous, this aids with the parser recovery logic, leading to better syntax error diagnostics.

## Source Compatibility

Since it is not currently possible to write any form of the proposed syntax in Swift today, this proposal does not alter the meaning of any existing code.

## Impact on ABI

This is purely compile-time sugar for the existing type. It is resolved at compile time, and does not appear in the ABI nor rely on any version of the runtime.

## Future Directions

### Repeated value equivalent

Analogous to arrays, there is an equivalent _value_ sugar for literals of a specific size:

```
// type inferred to be [5 x Int]
let fiveInts = [5 x 99]
// type inferred to be [5 x [5 x Int]]
let fiveByFive = [5 x [5 x 99]]
```

Unlike the sugar for the type, this would also have applicability for existing types:

```
// equivalent to .init(repeating: 99, count: 5)
let dynamic: [Int] = [5 x 99]
```

This is a much bigger design space, potentially requiring a new expressible-by-literal protocol and a way to map the literal to an initializer. As such, it is left for a future proposal.

### Flattened multi-dimensional arrays

For multi-dimensional arrays, `[5 x [5 x Int]]` could be flattened to `[5 x 5 x Int]` without any additional parsing issues. This could be an alternative considered, but is in future directions as it could also be introduced as sugar for the former case at a later date.

## Alternatives Considered

The most obvious alternative here is the choice of separator. Other options include:

- `[5 * Int]`, using the standard ASCII symbol for multiplication.
- `[5 ⨉ Int]`, the Unicode n-ary times operator. This looks nice but is impactical as not keyboard-accessible.
- `[5; Int]` is what Rust uses, but appears to have little association with "times" or "many". Similarly other arbitrary punctuation e.g. `,` or `/` or `#`.
- `[5 of Int]` is more verbose than `x` but could be considered more clear. It has the upside or downside, depending on your preference, of being almost, but not quite, grammatical.
- `:` is of course ruled out as it is used for dictionary literals.

Note that `*` is an existing operator, and may lead to ambiguity in fuure when expressions can be used to determine the size: `[5 * N * Int]`. `x` is clearer in this case: `[5 * N x Int]`. It also avoids parsing ambiguity, as the grammar does not allow two identifiers in succession. But it would be less clear if `x` also appeared as an identifier: `[5 * x x Int]` (which is not yet permitted but may be in future use cases).

Another thing to consider is how that separator looks in the fully inferred version, which tend to start to look a little like ascii diagrams:

```
[_ x _]
[_ * _]
[_; _]
[_ of _]
```

Beyond varying the separator, there may be other dramatically different syntax that moves further from the "like Array sugar, but with a size argument".

The order of size first, then type is determined by the ordering of the unsugared type, and deviating from this for the sugared version is not an option.

In theory, when using integer literals or `_` the whitespace could be omitted (`[5x_]` is unabiguously `[5 x _]`). However, special casing allowing whitespace omission is not desirable.
