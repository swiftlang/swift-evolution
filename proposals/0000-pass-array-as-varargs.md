# `as T...` Syntax to Pass Array Elements as Varargs

* Proposal: [SE-NNNN](NNNN-array-to-varargs-coercion.md)
* Authors: [Owen Voorhees](https://github.com/owenv)
* Review Manager: TBD
* Status: **Pitch**
* Implementation: [apple/swift#25997](https://github.com/apple/swift/pull/25997)

## Introduction

This proposal introduces a new use for the `as` type coercion operator, passing an `Array`'s elements in lieu of variadic arguments. This allows for the manual forwarding of variadic arguments and enables cleaner API interfaces in many cases.


Swift-evolution thread: [Thread](https://forums.swift.org/t/pitch-another-attempt-at-passing-arrays-as-varargs-with-implementation/26718)

Past discussion threads:

* https://forums.swift.org/t/proposal-for-passing-arrays-to-variadic-functions/463/17
* https://forums.swift.org/t/idea-passing-an-array-to-variadic-functions/2240/51
* https://forums.swift.org/t/explicit-array-splat-for-variadic-functions/11326/23
* https://forums.swift.org/t/discussion-variadics-as-an-attribute/5186/6
* https://forums.swift.org/t/variadic-parameters-that-accept-array-inputs/12711/42

## Motivation

Currently, it is not possible to pass an `Array`'s elements to a function as variadic arguments in Swift. As a result, it can be difficult to express some common patterns when working with variadic functions. Notably, when designing APIs with variadic arguments, many developers end up writing two versions, one which takes a variadic argument and another which takes an `Array`.

```swift
func foo(bar: Int...) {
  foo(bar: bar)
}

func foo(bar: [Int]) {
  // Actual Implementation
}
```

This redundancy is especially undesirable because in many cases, the variadic version of the function will be used far more often by clients. Additionally, arguments and default argument values must be kept in sync between the two function declarations, which can be tedious.

Another serious limitation of the language currently is the inability to forward variadic arguments. Because variadic arguments are made available as an `Array` in the function body, there is no way to forward them to another function which accepts variadic arguments (or the same function recursively). If the programmer has access to the source of the function being forwarded to, they can manually add an overload which accepts `Array`s as described above. If they do not control the source, however, they may have to make nontrivial changes to their program logic in order to use the variadic interface.

## Proposed solution

Introduce a new use case for the `as` operator, which can be used to coerce the elements of an `Array` to variadic arguments. The new syntax is spelled `as T...`, and can be used as follows:

```swift
func foo(bar: Int...) { /* ... */ }

foo(bar: 1, 2, 3)
foo(bar: [1, 2, 3] as Int...) // Equivalent
```

The `Array` used with `as T...` need not be an array literal. The following examples would also be considered valid:

```swift
let x: [Int] = /* ... */
foo(bar: x as Int...)                        // Allowed
foo(bar: ([1] + x.map { $0 - 1 }) as Int...) // Also Allowed
```

`as T...` also enables flexible forwarding of variadic arguments. This makes it possible to express something like the following:

```swift
func log(_ args: Any..., isProduction: Bool) {
  if isProduction {
    // ...
  } else {
    print(args as Any...)
  }
}
``` 

## Detailed design

### Syntax Changes

This proposal uses the existing `as` operator to coerce an array's elements to variadic arguments. Variadic types will now be valid when used on the RHS of the operator, where they were disallowed in the past.

### Semantic Restrictions

`as T...` may only be used as the top-level expression of a function or subscript argument. Attempting to use it anywhere else will result in a compile time error. This restriction is equivalent to the one imposed on the use of `&` with inout arguments.

With this change, a variadic argument may accept 0 or more regular argument expressions, or a single `as T...` argument expression. Passing a combination of regular and `as T...` argument expressions to a single variadic argument is not allowed, nor is passing multiple `as T...` expressions. This restriction is put in place to avoid the need for implicit array copy operations at the call site, which would be easy for the programmer to overlook. This limitation can be worked-around by explicitly concatenating arrays within the `as T...` expression.

The `as!` and `as?` operators may not be used when coercing to a variadic type. This restriction is put in place because the coercion of an array to variadic arguments will never fail at runtime. This is intended to prevent users from writing code like the following which combines a coercion to variadic arguments with a checked cast:

```swift
let x: Any = ...
foo(bar: (x as? Int...) ?? /* no way to provide a fallback value */)

```

Instead, users should write something like:

```swift
let x: Any = ...
let y = (x as? [Int]) ?? []
foo(bar: y as Int...)
```

### New Diagnostics

A number of new diagnostics will be introduced to improve the experience of working with `as T...` and variadic arguments. These include:

* New contextual conversion diagnostics for passing an array to a variadic argument which offer to add the `as T...`.

* A diagnostic for passing regular variadic arguments alongside coerced array elements.

* Diagnostics to enforce the restriction that `as T...` only appears as a function or subscript argument.

### Alternate Spellings

The main alternative to the proposed `as T...` syntax is to use a pound-prefixed keyword when passing array elements as varargs. Some of the potential spellings include `#splat`, `#variadic`, `#passVarargs`, `#asVarargs`, `#explode`, and `#arraySplat`.

## Source compatibility

This proposal is purely additive and has no impact on source compatibility.

## Effect on ABI stability

This proposal does not change the ABI of any existing language features. Variadic arguments are already passed as `Array`s in SIL, so no ABI change is necessary to support the new `as T...` syntax.

## Effect on API resilience

This proposal does not introduce any new features which could become part of a public API.

## Alternatives considered

A number of alternatives to this proposal's approach have been pitched over the years:
### Implicitly convert `Array`s when passed to variadic arguments

One possibility which has been brought up in the past is abandoning an explicit 'splat' operator in favor of implicitly converting arrays to variadic arguments where possible. It is unclear how this could be implemented without breaking source compatibility. Consider the following example:

```swift
func f(x: Any...) {}
f(x: [1, 2, 3]) // Ambiguous!
```
In this case, it's ambiguous whether `f(x:)` will receive a single variadic argument of type `[Int]`, or three variadic arguments of type `Int`. This ambiguity arises anytime both the element type `T` and `Array` itself are both convertible to the variadic argument type. It might be possible to introduce default behavior to resolve this ambiguity. However, it would come at the cost of additional complexity, as implicit conversions can be very difficult to reason about. Swift has previously removed similar implicit conversions which could have confusing behavior. It's also worth noting that the standard library's `print` function accepts an `Any...` argument, so this ambiguity would arise fairly often in practice.

It's also unclear how implicit conversions would affect overload ranking, another likely cause of source compatibility breakage.

### Use a leading or trailing `...` instead of `as T...`

Many past conversations around passing arrays as variadic arguments have pitched using a leading or trailing `...` as a 'splat' operator instead of a heavier-weight expression like `as T...`. These operators read clearly at the call site, but they conflict with the existing partial range from/through operators in the language. `as T...` has the advantage of avoiding these conflicts, and it's expected that this feature will not be used pervasively throughout a codebase, which helps justify a more verbose spelling.

### Make T... its own type

Earlier discussions around variadic arguments pitched various approaches to introducing a new, non-`Array` type for variadic arguments, or introducing new attributes to control their behavior. Such changes can no longer be implemented without breaking binary compatibility. If a larger redesign of variadic arguments is desired, it might be possible to introduce it as a new feature while deprecating the old style. However, the array 'splat' feature doesn't justify such a large redesign on its own.

## Acknowledgements

This proposal incorporates many ideas which have been pitched and discussed on the mailing lists and forums over the past several years. Thanks to all who participated in those discussions! I've tried to link as many of the past threads as I could find.

Thanks also to John McCall and Slava Pestov for laying the groundwork in the compiler recently which enables this feature!

