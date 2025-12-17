# Allow trailing comma in comma-separated lists

* Proposal: [SE-0439](0439-trailing-comma-lists.md)
* Author: [Mateus Rodrigues](https://github.com/mateusrodriguesxyz)
* Review Manager: [Xiaodi Wu](https://github.com/xwu)
* Status: **Implemented (Swift 6.1)**
* Implementation: [swiftlang/swift#74522](https://github.com/swiftlang/swift/pull/74522)
* Previous Proposal: [SE-0084](0084-trailing-commas.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-allow-trailing-comma-in-tuples-arguments-and-if-guard-while-conditions/70170)), ([review](https://forums.swift.org/t/se-0439-allow-trailing-comma-in-comma-separated-lists/72876)), ([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0439-allow-trailing-comma-in-comma-separated-lists/73216))
* Previous Revision: ([1](https://github.com/swiftlang/swift-evolution/blob/7864fa20cfb3a43aa6874feedb5aedb8be02da2c/proposals/0439-trailing-comma-lists.md))

## Introduction

This proposal aims to allow the use of trailing commas, currently restricted to array and dictionary literals, in symmetrically delimited comma-separated lists.

## Motivation

### Development Quality of Life Improvement

A trailing comma is an optional comma after the last item in a list of elements:

```swift
let rank = [
  "Player 1",
  "Player 3",
  "Player 2",
]
```

Swift's support for trailing commas in array and dictionary literals makes it as easy to append, remove, reorder, or comment out the last element as any other element.

Other comma-separated lists in the language could also benefit from the flexibility enabled by trailing commas. Consider the function [`split(separator:maxSplits:omittingEmptySubsequences:)`](https://swiftpackageindex.com/apple/swift-algorithms/1.2.0/documentation/algorithms/swift/lazysequenceprotocol/split(separator:maxsplits:omittingemptysubsequences:)-4q4x8) from the [Algorithms](https://github.com/apple/swift-algorithms) package, which has a few parameters with default values.


```swift
let numbers = [1, 2, 0, 3, 4, 0, 0, 5]

let subsequences = numbers.split(
    separator: 0,
//    maxSplits: 1
) ❌ Unexpected ',' separator
```

### The Language Evolved

Back in 2016, a similar [proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0084-trailing-commas.md) with a narrower scope was reviewed and rejected for Swift 3. Since that time, the language has evolved substantially that challenges the basis for rejection. The code style that "puts the terminating right parenthesis on a line following the arguments to that call" has been widely adopted by community, Swift standard library codebase, swift-format, DocC documentation and Xcode. Therefore, not encouraging or endorsing this code style doesn't hold true anymore.

The language has also seen the introduction of [parameter packs](https://github.com/apple/swift-evolution/blob/main/proposals/0393-parameter-packs.md), which enables APIs that are generic over variable numbers of type parameters, and code generation tools like plugins and macros that, with trailing comma support, wouldn't have to worry about a special condition for the last element when generating comma-separated lists.

## Proposed solution

This proposal adds support for trailing commas in symmetrically delimited comma-separated lists, which are the following:

- Tuples and tuple patterns.

    ```swift
    let velocity = (
        1.66007664274403694e-03,
        7.69901118419740425e-03,
        6.90460016972063023e-05,
    )

    let (
        velocityX,
        velocityY,
        velocityZ,
    ) = velocity
    ```

- Parameter and argument lists of initializers, functions, enum associated values, expression macros and attributes.

    ```swift
    func foo(
        input1: Int = 0,
        input2: Int = 0,
    ) { }

    foo(
        input1: 1,
        input2: 1,
    )

    struct S {
        init(
            input1: Int = 0,
            input2: Int = 0,
        ) { }
    }

    enum E {
        case foo(
            input1: Int = 0,
            input2: Int = 0,
        )
    }

    @Foo(
        "input 1",
        "input 2",
        "input 3",
    )
    struct S { }

    #foo(
        "input 1",
        "input 2",
        "input 3",
    )

    struct S {
        #foo(
            "input 1",
            "input 2",
            "input 3",
        )
    }

    ```

- Subscripts, including key path subscripts.

    ```swift
    let value = m[
        x,
        y,
    ]

    let keyPath = \Foo.bar[
        x,
        y,
    ]

    f(\.[
        x,
        y,
    ])
    ```

- Closure capture lists.

    ```swift
    { [
        capturedValue1,
        capturedValue2,
    ] in
    }
    ```

- Generic parameter lists and generic argument lists.

    ```swift
    struct S<
        T1,
        T2,
        T3,
    > { }

    let s = S<
        T1,
        T2,
        T3,
    >()
    ```

- String interpolation.

    ```swift
    let s = "\(1, 2,)"
    ```

## Detailed Design

Trailing commas will be supported in comma-separated lists when symmetric delimiters (including `(...)`, `[...]`, and `<...>`) enable unambiguous parsing.

Note that the requirement for a comma-separated list means that `let x: [Int,] ❌` will not be supported, since a list of types is never supported in that context. Likewise, built-in attributes that don't parse their arguments as a comma-separated list will not support trailing comma, such as `@inline(never,) ❌`.

Note that the requirement for symmetric delimiters means that the following cases will not support trailing comma:

- `if`, `guard` and `while` condition lists.

    ```swift
    if
        condition1,
        condition2, ❌
    { }

    while
        condition1,
        condition2, ❌
    { }

    guard
        condition1,
        condition2, ❌
    else { }
    ```
    
- Enum case label lists.

    ```swift
    enum E {
      case
         a,
         b,
         c, ❌
    }
    ```

- `switch` case labels.

    ```swift
    switch number {
        case
            1,
            2, ❌
        :
            ...
        default:
            ..
    }
    ```
    
- Inheritance clauses.

    ```swift
    struct S:
        P1,
        P2,
        P3, ❌
    { }
    ```

- Generic `where` clauses.

    ```swift
    struct S<
        T1,
        T2,
        T3,
    > where
        T1: P1,
        T2: P2, ❌
    { }
    ```

Trailing commas will be allowed in single-element lists but not in zero-element lists, since the trailing comma is actually attached to the last element. 
Supporting a zero-element list would require supporting _leading_ commas, which isn't what this proposal is about.

```swift
(1,) // OK
(,) ❌ expected value in tuple
```


## Source compatibility

This is a purely additive change with no source compatibility impact.

## Alternatives considered

### Allow trailing comma in all comma-separated lists

Comma-separated lists that are not symmetrically delimited could also benefit from trailing comma support; for example, condition lists, in which reordering is fairly common. 
However, these lists currently rely on the comma after the penultimate element to determine that what comes next is the last element, and some of them present challenges if relying on opening/closing delimiters instead.

At first sight, `{` may seem a reasonable closing delimiter for `if` and `while` condition lists, but conditions can have a `{` themselves.

```swift
if
    condition1,
    condition2,
    { true }(),
{ }
```

This particular case can be handled but, given how complex conditions can be, it's hard to conclude that there's absolutely no corner case where ambiguity can arise in currently valid code.

Inheritance lists and generic `where` clauses can appear in protocol definitions where there's no clear delimiter, making it harder to disambiguate where the list ends.

```swift
protocol Foo {
  associatedtype T:
      P1,
      P2, ❌ Expected type
  ...
}
```

Although some comma-separated lists without symmetric delimiters may have a clear terminator in some cases, this proposal restricts trailing comma support to symmetrically delimited ones where it's clear that the presence of a trailing comma will not cause parsing ambiguity.

### Eliding commas

A different approach to address similar motivations is to allow the comma between two expressions to be elided when they are separated by a newline.

```swift
print(
    "red"
    "green"
    "blue"
)
```
This was even [proposed](https://forums.swift.org/t/se-0257-eliding-commas-from-multiline-expression-lists/22889/188) and returned for revision back in 2019.

The two approaches are not mutually exclusive. There remain unresolved questions about how the language can accommodate elided commas, and adopting this proposal does not prevent that approach from being considered in the future.

## Revision History

- Update to address acceptance decision of restricting trailing comma to lists with symmetric delimiters.

## Acknowledgments

Thanks to Alex Hoppen, Xiaodi Wu and others for their help on the proposal text and implementation.
