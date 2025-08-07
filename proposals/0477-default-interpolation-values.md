# Default Value in String Interpolations

* Proposal: [SE-0477](0477-default-interpolation-values.md)
* Authors: [Nate Cook](https://github.com/natecook1000)
* Review Manager: [Xiaodi Wu](https://github.com/xwu)
* Status: **Implemented (Swift 6.2)**
* Implementation: [swiftlang/swift#80547](https://github.com/swiftlang/swift/pull/80547)
* Review: ([pitch](https://forums.swift.org/t/pitch-default-values-for-string-interpolations/69381)) ([review](https://forums.swift.org/t/se-0477-default-value-in-string-interpolations/79302)) ([acceptance](https://forums.swift.org/t/accepted-with-modification-se-0477-default-value-in-string-interpolations/79609))

## Introduction

A new string interpolation syntax for providing a default string
when interpolating an optional value.

## Motivation

String interpolations are a streamlined and powerful way to include values within a string literal.
When one of those values is optional, however,
interpolating is not so simple;
in many cases, a developer must fall back to unpalatable code
or output that exposes type information.

For example,
placing an optional string in an interpolation
yields an important warning and two suggested fixes,
only one of which is ideal:

```swift
let name: String? = nil
print("Hello, \(name)!")
// warning: string interpolation produces a debug description for an optional value; did you mean to make this explicit?
// print("Hello, \(name)!")
//                 ^~~~
// note: use 'String(describing:)' to silence this warning
// print("Hello, \(name)!")
//                 ^~~~
//                 String(describing:  )
// note: provide a default value to avoid this warning
// print("Hello, \(name)!")
//                 ^~~~
//                      ?? <#default value#>

```

The first suggestion, adding `String(describing:)`,
silences the warning but includes `nil` in the output of the string —
maybe okay for a quick shell script,
but not really appropriate result for anything user-facing.

The second suggestion is good,
allowing us to provide whatever default string we'd like:

```swift
let name: String? = nil
print("Hello, \(name ?? "new friend")!")
```

However, the nil-coalescing operator (`??`)
only works with values of the same type as the optional value,
making it awkward or impossible to use when providing a default for non-string types.
In this example, the `age` value is an optional `Int`,
and there isn't a suitable integer to use when it's `nil`:

```swift
let age: Int? = nil
print("Your age: \(age)")
// warning, etc....
```

To provide a default string when `age` is missing,
we have to write some gnarly code,
or split out the missing case altogether:

```swift
let age: Int? = nil
// Optional.map
print("Your age: \(age.map { "\($0)" } ?? "missing")")
// Ternary expression
print("Your age: \(age != nil ? "\(age!)" : "missing")")
// if-let statement
if let age {
    print("Your age: \(age)")
} else {
    print("Your age: missing")
}
```

## Proposed solution

The standard library should add a string interpolation overload
that lets you write the intended default as a string,
no matter what the type of value:

```swift
let age: Int? = nil
print("Your age: \(age, default: "missing")")
// Prints "Your age: missing"
```

This addition will improve the clarity of code that uses string interpolations
and encourage developers to provide sensible defaults
instead of letting `nil` leak into string output.

## Detailed design

The implementation of this new interpolation overload looks like this,
added as an extension to the `DefaultStringInterpolation` type:

```swift
extension DefaultStringInterpolation {
    mutating func appendInterpolation<T>(
        _ value: T?,
        default: @autoclosure () -> String
    ) {
        if let value {
            self.appendInterpolation(value)
        } else {
            self.appendInterpolation(`default`())
        }
    }
}
```

The new interpolation's `default:` parameter name
matches the one in the `Dictionary` subscript that has a similar purpose.

You can try this out yourself by copy/pasting the snippet above into a project or playground,
or by experimenting with [this Swift Fiddle](https://swiftfiddle.com/nxttprythnfbvlm4hwjyt2jbjm).

## Source compatibility

This proposal adds one new API to the standard library,
which should not be source-breaking for any existing projects.
If a project or a dependency has added a similar overload,
it will take precedence over the new standard library API.

## ABI compatibility

This proposal is purely an extension of the ABI of the
standard library and does not change any existing features.

## Implications on adoption

The new API will be included in a new version of the Swift runtime,
and is marked as backward deployable.

## Future directions

There are [some cases][reflecting] where a `String(reflecting:)` conversion
is more appropriate than the `String(describing:)` normally used via string interpolation.
Additional string interpolation overloads could make it easier to use that alternative conversion,
and to provide a default when working with optional values.

[reflecting]: https://forums.swift.org/t/pitch-default-values-for-string-interpolations/69381/58

## Alternatives considered

**An interpolation like `"\(describing: value)"`**   
This alternative would provide a shorthand for the first suggested fix,
using `String(describing:)`.
Unlike the solution proposed,
this kind of interpolation doesn't make it clear that you're working with an optional value,
so you could end up silently including `nil` in output without expecting it
(which is the original reason for the compiler warnings).

**Extend `StringInterpolationProtocol` instead**   
The proposed new interpolation works with _any_ optional value,
but some types only accept a limited or constrained set of types interpolations.
If the new `\(_, default:)` interpolation proves to be a useful pattern,
other types can add it as appropriate.

