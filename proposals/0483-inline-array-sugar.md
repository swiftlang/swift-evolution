# `InlineArray` Type Sugar

* Proposal: [SE-0483](0483-inline-array-sugar.md)
* Authors: [Hamish Knight](https://github.com/hamishknight), [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Holly Borla](https://github.com/hborla)
* Status: **Implemented (Swift 6.2)**
* Review: ([pitch](https://forums.swift.org/t/pitch-inlinearray-type-sugar/79142)) ([first review](https://forums.swift.org/t/se-0483-inlinearray-literal-syntax/79643)) ([second review](https://forums.swift.org/t/second-review-se-0483-inlinearray-type-sugar/80337)) ([acceptance](https://forums.swift.org/t/accepted-se-0483-inlinearray-type-sugar/81509))

## Introduction

We propose the introduction of type sugar for the `InlineArray` type, providing more succinct syntax for declaring an inline array.

## Motivation

[SE-0453](/proposals/0453-vector.md) introduced a new type, `InlineArray`, which includes a size parameter as part of its type:

```
let fiveIntegers: InlineArray<5, Int> = .init(repeating: 99)
```

Declaring this type is more cumbersome than its equivalent dynamically-sized array, which has sugar for the type syntax:

```swift
let fiveIntegers: [Int] = .init(repeating: 99, count: 5)
```

This becomes more pronounced when dealing with multiple dimensions:

```swift
let fiveByFive: InlineArray<5, InlineArray<5, Int>> = .init(repeating: .init(repeating: 99))
```

Almost every other language in a similar category to Swift – C, C++, Objective-C, Pascal, Go, Rust, Zig, Java, C# – has a simple syntax for their fixed-size array type. The introduction of a fixed-size array type into Swift should also introduce a shorthand syntax, in keeping with Swift's general approach of low ceremony and concise syntax. Swift further deviates from its peer languages by giving its _dynamic_ array type, `Array` (known in many other languages as `vector`) a sugared form. This can lead to an assumption that `Array` should be used under almost all circumstances, despite it having significant downsides in many uses (see further discussion in alternatives considered).

## Proposed solution

A new sugared version of the `InlineArray` type is proposed:

```swift
let fiveIntegers: [5 of Int] = .init(repeating: 99)
```

The choice of `of` forms something close to a grammatical phrase ("an array of five ints"). A short contextual keyword is also in keeping with Swift's tradition in other areas such as `in` or `let`.

## Detailed design

The new syntax consists of the value for the integer generic parameter and the type of the element generic parameter, separated by `of`.

This will be added to the grammar alongside the current type sugar:

> **Grammar of a type**
> _type → sized-array-type_
>
> **Grammar of a sized array type**
> _sized-array-type → [ expression `of` type ]_

Note that while the grammar allows for any expression, this is currently limited to only integer literals or integer type parameters, as required by the current implementation of `InlineArray`. If that restriction changes, so would the value allowed in the expression in the sugar.

The new sugar is equivalent to declaring a type of `InlineArray`, so all rules that can be applied to the generic placeholders for the unsugared version also apply to the sugared version:

```swift
// Nesting
let fiveByFive: InlineArray<5, InlineArray<5, Int>> = .init(repeating: .init(repeating: 99))
let fiveByFive: [5 of [5 of Int]] = .init(repeating: .init(repeating: 99))

// Inference from context:
let fiveIntegers: [5 of _] = .init(repeating: 99)
let fourBytes: [_ of Int8] = [1,2,3,4]
let fourIntegers: [_ of _] = [1,2,3,4]

// use on rhs
let fiveDoubles = [5 of _](repeating: 1.23)
```

The sugar can also be used in place of the unsugared type wherever it might appear:

```swift
[5 of Int](repeating: 99)
MemoryLayout<[5 of Int]>.size
unsafeBitCast((1,2,3), to: [3 of Int].self)
```

There must be whitespace on either side of the separator; i.e., you cannot write `[5of Int]`. There are no requirements to balance whitespace; `[5      of Int]` is permitted. A new line can appear after the `of` but not before it, as while this is not ambiguous, this aids with the parser recovery logic, leading to better syntax error diagnostics.

## Source Compatibility

Since it is not currently possible to write any form of the proposed syntax in Swift today, this proposal does not alter the meaning of any existing code.

## Impact on ABI

This is purely compile-time sugar for the existing type. It is resolved at compile time and does not appear in the ABI nor rely on any version of the runtime.

## Future Directions

### Repeated value equivalent

Analogous to arrays, there is an equivalent *value* sugar for literals of a specific size:

```swift
// type inferred to be [5 of Int]
let fiveInts = [5 of 99]

// type inferred to be [5 of [5 of Int]]
let fiveByFive = [5 of [5 of 99]]
```

Unlike the sugar for the type, this would also have applicability for existing types:

```swift
// equivalent to .init(repeating: 99, count: 5)
let dynamic: [Int] = [5 of 99]
```

This is a much bigger design space, potentially requiring a new expressible-by-literal protocol and a way to map the literal to an initializer. As such, it is left for a future proposal.

However, the choice of syntax for the type sugar has a significant impact on the viability of this future direction (see alternatives considered). Given the potential benefit of such a value syntax, any choice for the type sugar should consider its future extension to value sugar.

[^expressions]: It could also cause confusion once expressions are allowed for declaring an `InlineArray` i.e. `[5 * 5 * Int]` would be allowed.

### Flattened multi-dimensional arrays

For multi-dimensional arrays, `[5 of [5 of Int]]` could be flattened to `[5 of 5 of Int]` without any additional parsing issues. This could be an alternative considered but is in future directions as it could also be introduced as sugar for the former case at a later date.

## Alternatives Considered

### Indication of the "inline" nature via the sugar.

The naming of `InlineArray` incorporates important information about the nature of the type – that it includes its values inline rather than indirectly via a pointer. This name was chosen over other alternatives such as `FixedSizeArray` because the "inline-ness" was considered the more fundamental property, and so a better driver for the name.

This has led to suggestions that this inline nature is important to include in the sugar was well. However, the current state privileges the position of `Array` as the only array type that is sugared. This implies that `Array` is the right choice in all circumstances, with inline arrays being a rare micro-optimization. This is not the case.

For example, consider a translation of this code from the popular [Ray Tracing in One Weekend](https://raytracing.github.io/books/RayTracingInOneWeekend.html#thevec3class) tutorial:

```cpp
class vec3 {
  public:
    double e[3];

    double x() const { return e[0]; }
    double y() const { return e[1]; }
    double z() const { return e[2]; }
    // etc
}
```

The way in which Swift privileges `[Double]` with sugar strongly implies you should use that in this translation. Doing so would have significant performance downsides:
- Creating new instances of `Vec3` requires a heap allocation, and destroying them require a free operation.
- `Vec3` could no longer be `BitwiseCopyable`, instead requiring a reference counting operation to make a copy.
- Access to a coordinate would require pointer chasing, and a contiguous array of `Vec3` objects would not be guaranteed to exist in contiguous memory.
- Every access to those coordinate accessors would need to check the bounds (because while the author might ensure that the value of `e` will only ever have length 3, the compiler cannot easily know this) and, in the case of mutation, a check for uniqueness of the pointer. `InlineArray<3, Double>` has none of these problems.

Other examples include the use of nested `Array` types i.e. using `[[Double]]` to represent a matrix of known size, which would also have noticeable negative performance impact depending on the use case, compared to using an `InlineArray<InlineArray<Double>>` (or perhaps `[InlineArray<Double>]`) to model the same values. Today, this is possible via custom subscripts that logically represent the inner array within a single `[Double]`, but the introduction of `InlineArray` introduces other potentially more ergonomic options.

In other cases, the "copy on write" nature of `Array` can mislead users into thinking that copies are risk-free, when actually copying an array can lead to "defeating" copy on write in subtle ways that can cause difficult-to-hunt-down performance issues. In all these cases, you need to pick the right one of two options for the performance goals you are trying to achieve.

Swift's choice (deviating from many of its peers) to only have a dynamic array type, and to emphasize the utility of this type through sugar, has led to a shaping of the culture of writing Swift code that favors the sugared dynamic array even when this leads to otherwise-avoidable negative performance impact. This is not intended to make the case that Swift should _not_ have this sugar. Dynamic arrays are widely useful and Swift's readability goals are improved by Swift having a concise syntax for creating them. But writing performant Swift code inevitably involves having an understanding of the underlying performance characteristics of _all_ the types you are using, and syntax or type naming alone cannot solve this.

Of course, all this only matters when you are trying to write code that maximizes performance. But that is a really important use case for Swift. The goal for Swift is a language that is as safe and enjoyable to write as many high-level non-performant languages, but also can achieve peak performance when that is your goal. And the idea is that when you are targeting that level of performance, you don't have to go into "ugly, no longer nice swift" mode to do it, with nice sugared `[Double]` replaced with less pleasant full type name of `InlineArray` – something a user coming from Go or C++ or Rust might find a downgrade. Similarly, attempting to incorporate the word "inline" into the sugar e.g. `[5 inline Int]` creates a worst of both worlds solution that many would find offputting to use, without solving the fundamental issue.

For these reasons, we should be considering `InlineArray` a peer of `Array` (even if the need for it is less common – just not "niche"), and providing a pleasant to use sugar for both types.

### Choice of delimiter

The most obvious alternative here is the choice of separator. Other options include:

- `[5 by Int]` is similar to `of`, but is less applicable to the value syntax (`[5 by 5]` doesn't read as an array of 5 instances of 5), without being clearer for the type syntax.
- `[5 x Int]`, using the ascii letter `x`, as an approximation for multiplication, reflecting common uses such as "a 4x4 vehicle". This was the choice of a previous revision of this proposal.
- `[5 * Int]`, using the standard ASCII symbol for multiplication.
- `[5 ⨉ Int]`, the Unicode n-ary times operator. This looks nice but is impractical as not keyboard-accessible.
- `[5; Int]` is what Rust uses, but appears to have little association with "times" or "many". Similarly other arbitrary punctuation e.g. `,` or `/`. `:` is of course ruled out as it is used for dictionary literals.
- `#` does have an association with counts in some areas such as set theory, but is used as a prefix operator rather than infix i.e. `[#5 Int]`. This is less expected than the infix form, and could also be read as "the fifth `Int`". It is also unclear how this would work with expressions like an array of size `5*5`.
- No delimiter at all i.e. `[5 Int]`. While this might be made to parse, the lack of any separator is found unsettling by some users and is less visually clear, especially once expressions are allowed instead of the `5`.

Note that `*` is an existing operator, and may lead to ambiguity in future when expressions can be used to determine the size: `[5 * N * Int]`. `of` is clearer in this case: `[5 * N of Int]`. It also avoids parsing ambiguity, as the grammar does not allow two identifiers in succession. This becomes more important if the future direction of a value equivalent is pursued. `[2 * 2 * 2]` could be interpreted as `[2, 2, 2, 2]`, `[4, 4,]`, or `[8]`.

Since `of` cannot follow another identifier today, `[of of Int]` is unambiguous,[^type] but would clearly be hard to read. This is likely a hypothetical concern rather than a practical one since `of` is very rare as a variable name. The previous proposal's use of `x` involved a variable name that was more common.

`x` is also less clear when used for the value version: `[5 x 5]` can be parsed unambiguously, but looks similar to five times five, and so visually has the same challenges as with the `*` operator, even if this isn't a problem for the compiler.

[^type]: or even `[of of of]`, since `of` can be a type name, albeit one that defies Swift's naming conventions.

Another thing to consider is how that separator looks in the fully inferred version, which tend to start to look a little like ascii diagrams:

```
[_ of _]
[_ x _]
[_ * _]
[_; _]
```

Of all these, the `of` choice is less susceptible to the ascii art problem.

### Order of size and type

The order of size first, then type is determined by the ordering of the unsugared type, and deviating from this for the sugared version is not an option.

### Whitespace around the delimeter

In theory, when using integer literals or `_` the whitespace could be omitted (`[5x_]` is unambiguously `[5 x _]`). However, special casing allowing whitespace omission is not desirable.

### Choice of brackets

`InlineArray` has a lot in common with tuples – especially in sharing "copy on copy" behavior, unlike regular `Array`. So `(5 of Int)` may be an appropriate alternative to the square brackets, echoing this similarity. However, tuples and `InlineArray`s remain very different types, and it could be misleading to imply that `InlineArray` is "just" a tuple.

Beyond varying the separator, there may be other dramatically different syntax that moves further from the "like Array sugar, but with a size argument". For example, dropping the brackets altogether (i.e. `let a: 5 of Int`). However, these are probably too much of a departure from the current Swift idioms, so likely to cause further confusion without any real upside.
