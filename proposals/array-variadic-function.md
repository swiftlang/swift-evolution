# Pass Array [T] to Variadic Function with type T

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Swift Developer](https://github.com/swiftdev)
* Status: **Review**
* Review manager: TBD

## Introduction

In Swift, the values passed to a variadic function are available
within the scope of the function as an array of the type that was passed.

Unfortunately, Swift does not allow you to pass an array of type `[T]` to a function expecting arguments of type `T...`

For example:
```
func a(v: Int...) {
    v is [Int] // true
}

a(1, 2, 3) // Works
a([1, 2, 3]) // error: cannot invoke 'a' with an argument list of type '([Int])'
```

This is not a new request as can be inferred by the following articles:
- Original Radar: [rdar://12134482](rdar://12134482)
- Duplicate Radar: [http://www.openradar.me/17284891](http://www.openradar.me/17284891)
- Swift Bug Report: [https://bugs.swift.org/browse/SR-128](https://bugs.swift.org/browse/SR-128)
- Apple's Response on June 4, 2014: [https://devforums.apple.com/message/974316#974316](https://devforums.apple.com/message/974316#974316)

## Motivation

Within a variadic function, Swift treats the variadic argument as an array.
Therefore, one (wrongly) assumes that an array can be passed to a variadic function.

Unfortunately, to get around this issue, one must overload their function.

For example:
```
// Original
func a(v: String...) {}

// Overloaded
func a(v: [String]) {}
```

## Proposed solution

Special syntax could be passed denoting that the argument being passed is an array. In the references above, others have mentioned the adoption of ruby's [Splat](http://ruby-doc.org/core-2.2.0/doc/syntax/calling_methods_rdoc.html) operator syntax, `*[T]`.


## Detailed design

For a variadic function to accept both arrays of and variable argument, a new syntax should be introduced and prepended to arrays.

Revisiting the example from the [Motivation](#Motivation) section with this newly proposed syntax:

```
func a(v: Int...) {
    v is [Int] // true
}

a(1, 2, 3) // Works
a(*[1, 2, 3]) // Proposed syntax change
```

## Impact on existing code

This change should not negatively affect existing code as it's introducing new functionality to an existing API rather than changing existing behavior.

## Alternatives considered

The alternative is to overload a function as denoted in the [Proposed solution](#Proposed solution) section.
