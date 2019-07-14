# Prefix `*` Varargs 'Splat' Operator for Arrays

* Proposal: [SE-NNNN](NNNN-array-to-varargs-coercion.md)
* Authors: [Owen Voorhees](https://github.com/owenv)
* Review Manager: TBD
* Status: **Pitch**
* Implementation: [apple/swift#25997](https://github.com/apple/swift/pull/25997)

## Introduction

This proposal introduces a new prefix `*` operator which is used to pass an `Array`'s elements in lieu of variadic arguments. This allows for the manual forwarding of variadic arguments and enables cleaner API interfaces in many cases.


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

This problem also appears when overriding a method which accepts a variadic argument. Consider the following example:

```swift
class A {
  func foo(bar: Int...) { /* ... */ }
}

class B: A {
  override func foo(bar: Int...) {
    // No way to call super.foo(bar:) with bar
  }
}
```

## Proposed solution

Introduce a new prefix `*` operator, which can be used to pass the elements of an `Array` as variadic arguments. The operator may be used as follows:

```swift
func foo(bar: Int...) { /* ... */ }

foo(bar: 1, 2, 3)
foo(bar: *[1, 2, 3]) // Equivalent
```

The `Array` passed as variadic arguments need not be an array literal. The following examples would also be considered valid:

```swift
let x: [Int] = /* ... */
foo(bar: *x)                        // Allowed
foo(bar: *([1] + x.map { $0 - 1 })) // Also Allowed
```

The new operator also enables flexible forwarding of variadic arguments. This makes it possible to express something like the following:

```swift
func log(_ args: Any..., isProduction: Bool) {
  if isProduction {
    // ...
  } else {
    print(*args)
  }
}
``` 

It also makes it possible to call `super` when overriding methods which accept variadic arguments:

```swift
class A {
  func foo(bar: Int...) { /* ... */ }
}

class B: A {
  override func foo(bar: Int...) {
    super.foo(bar: *bar)
    // Custom behavior
  }
}
```

## Detailed design

### Operator

This proposal introduces a new operator to the standard library, prefix `*`. The operator's implementation will be internal to the compiler, but it can be thought of as effectively having the following signature:
```swift
prefix operator *

prefix func *<T>(_: [T]) -> T...
``` 

Aside from having a compiler defined implementation, prefix `*` will otherwise type check as a traditional, standard library defined operator.

### Semantic Restrictions

Array splatting using `*` may only appear as the top-level expression of a function or subscript argument. Attempting to use it anywhere else will result in a compile time error. This restriction is equivalent to the one imposed on the use of `&` with inout arguments.

With this change, a variadic argument may accept 0 or more regular argument expressions, or a single splatted `Array`. Passing a combination of regular and splatted argument expressions to a single variadic argument is not allowed, nor is passing multiple splatted expressions. This restriction is put in place to avoid the need for implicit array copy operations at the call site, which would otherwise be easy for the programmer to overlook. This limitation can be worked-around by explicitly concatenating arrays before applying the operator.
## Source compatibility

This proposal is purely additive and does not impact source compatibility. The future directions section discusses how this feature can be introduced without placing unnecessary source compatibility restrictions on future features like tuple splat and variadic generics.

## Effect on ABI stability

This proposal does not change the ABI of any existing language features. Variadic arguments are already passed as `Array`s in SIL, so no ABI change is necessary to support the new `*` operator.

## Effect on API resilience

This proposal does not introduce any new features which could become part of a public API.

## Alternatives considered

A number of alternatives to this proposal's approach have been pitched over the years:

### Alternate Spellings

A number of alternate spellings for this feature have been suggested:

##### Prefix/Postfix `...`

The existing `...` operator has been brought up frequently as a candidate for a 'spread' operator due to its similarity to the existing `T...` syntax for declaring variadic arguments. However, overloading this operator would introduce a couple of issues.

First, `...` can currently be used as either a prefix or postfix operator to construct a range given any `Comparable` argument. `Array` does not conform to `Comparable`, so it would be possible to disambiguate these two use cases today. However, it would mean `Array` could never gain a conditional conformance to `Comparable` in the future which performed lexicographic comparison. If the newly introduced operator was extended to also perform tuple splatting as part of a future proposal, overloading `...` would also mean that tuples might not be able to gain `Comparable` conformances, an oft-requested feature.

If `...` was reused as a splat operator, it would also be one of the only operators in the standard library with multiple distinct sets of semantics. Previous discussions have expressed regret that the infix `+` operator has two different meanings in Swift, addition and string concatenation. Even when operator usage is never ambiguous, this overloading of an operator's meaning and semantics is generally undesirable, and has impeded past efforts to improve operator resolution. Because there are a number of pitched alternatives to `...` which do not have this issue, it's worth considering those operators first, all else being equal.

##### `as ...` as Shorthand for `as T...`, or as a Standalone Sigil

A previous draft of this proposal used the syntax `as T...` to expand an `Array` into variadic arguments. This approach was abandoned because it unnecessarily restates the array element type, and does not naturally extend to heterogenous collections like tuples and generic parameter packs which may eventually want to adopt similar splatting syntax.

One solution to this problem which was brought up is using `as ...` as a shorthand for `as T...`. However, this is inconsistent with existing uses for the `as` operator, which does not currently allow writing `as ?` as shorthand for `as Optional`, `as []` as shorthand for `as Array`, or `as [:]` instead of `as Dictionary`. Additionally, it's unclear how it would extend to heterogenous collections in a natural way when considering future language features.

`as ...` syntax has also been proposed which treats `...` as a sigil instead of a type. This usage clashes with the the existing role of `as`, which always has a type on the RHS today. 

##### A Pound-Prefixed Keyword Like `#variadic` or `#explode`

Another alternative to `*`, or any other operator, is to introduce a new pound-prefixed keyword to perform array splatting, with syntax like the following:
```swift
f(#variadic([1,2,3]))
```
This syntax has many of the same advantages as introducing a new operator for splatting. However, the syntax is more verbose, to the point where it may harm readability and ergonomics in contexts where the feature is used frequently. Past discussions have been overwhelmingly in favor of using an operator instead.

---

Prefix `*` was ultimately chosen as the proposed spelling for a few reasons:

- It has no existing meaning in Swift today, reducing source compatibility concerns if the operator is extended to apply to tuples or generic parameter packs in the future.
- There is existing precedent for using `*` as a splat operator in languages like Python and Ruby.
- `*` has been brought up in the past as a potential tuple splat operator. Using it for arrays and other splat operations as well would be consistent with those future designs.
- ... can keep its existing, single meaning as a range operator in expression contexts.

The main downside of adopting prefix `*` is it may impede future efforts to use the operator for pointer manipulation, as described under _Future Directions_.

### Implicitly convert `Array`s when passed to variadic arguments

One possibility which has been brought up in the past is abandoning an explicit 'splat' operator in favor of implicitly converting arrays to variadic arguments where possible. It is unclear how this could be implemented without breaking source compatibility. Consider the following example:

```swift
func f(x: Any...) {}
f(x: [1, 2, 3]) // Ambiguous!
```
In this case, it's ambiguous whether `f(x:)` will receive a single variadic argument of type `[Int]`, or three variadic arguments of type `Int`. This ambiguity arises anytime both the element type `T` and `Array` itself are both convertible to the variadic argument type. It might be possible to introduce default behavior to resolve this ambiguity. However, it would come at the cost of additional complexity, as implicit conversions can be very difficult to reason about. Swift has previously removed similar implicit conversions which could have confusing behavior (See [SE-29](https://github.com/apple/swift-evolution/blob/master/proposals/0029-remove-implicit-tuple-splat.md) and [SE-72](https://github.com/apple/swift-evolution/blob/master/proposals/0072-eliminate-implicit-bridging-conversions.md)). It's also worth noting that the standard library's `print` function accepts an `Any...` argument, so this ambiguity would arise fairly often in practice.

It's also unclear how implicit conversions would affect overload ranking, another likely cause of source compatibility breakage.

## Future Directions

### Pointer Manipulation Using `*`

In the past, it's been suggested that the prefix `*` operator might be used at some point in the future as a way of reducing boilerplate when writing pointer-manipulation code. This use case was noted in the alternatives considered of [SE-29](https://github.com/apple/swift-evolution/blob/master/proposals/0029-remove-implicit-tuple-splat.md), which recommended that, "'prefix-star' should be left unused for now in case we want to use it to refer to memory-related operations in the future." If prefix `*` was adopted as the 'splat' operator, it would preclude some pointer-manipulation use cases. 

### Tuple Splat

Explicit tuple splat has been discussed as a desirable feature to have ever since [SE-29](https://github.com/apple/swift-evolution/blob/master/proposals/0029-remove-implicit-tuple-splat.md) removed implicit tuple splat from the language. At the time, prefix `*` was put forward as a possible explicit tuple splat operator. 

Using `*` as both an array splat operator and a tuple splat operator in the future would provide a unified syntax for this concept. Because prefix `*` is being introduced as a new operator in this proposal, it could be applied to tuples in the future without raising any source compatibility concerns. Unlike `...`, there would be no potential issues with allowing tuples to conform to `Comparable` at some point in the future.

Unlike the previously proposed `as T...` syntax, the use of a splat operator lends itself naturally to use cases involving heterogenous collections like tuples.

### Variadic Generics

**Note**	: This section references terminology and ideas from both the [Generics Manifesto](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md) and Andrea Tomarelli's [Variadic Generics](https://github.com/technicated/swift-evolution/blob/83940f8/proposals/XXXX-variadic-generics.md) proposal draft.

Variadic generics are another future feature likely to interact with splatting syntax when working with generic parameter packs. At this time, it's unclear whether parameter packs will be implemented as 'variadic tuples' or some new kind of structural type in Swift's type system. Therefore, both scenarios should be considered to ensure the new `*` operator can be extended to support them if desired.

If variadic generics were implemented using variadic tuples, the `*` splat operator could be extended to work with them in the natural way as described above. Similarly, `*` could be applied to a new generic parameter pack structural type, if one existed, with few source compatibility concerns.

In the past, some variadic generics pitches have suggested adding an implicit forwarding mechanism when working with parameter packs. Such a feature would allow users to use dot syntax, subscripts, operators, etc. which are commonly applicable to elements of the pack on the pack itself. In that case, `*` would need to have special semantics so that it always applied to the parameter pack itself, and not its component parts. 

Unlike array and tuple splat, it's also possible generic parameter pack 'expansion' would be allowed in contexts other than argument locations, as a way of transforming a parameter pack into a tuple. This might mean the parameter pack 'overload' of `*` would have fewer static restrictions compared to the array and tuple 'overloads'. While this mismatch is unfortunate, it's an acceptable tradeoff which enables a unified syntax for splatting operations in Swift.

## Acknowledgements

This proposal incorporates many ideas which have been pitched and discussed on the mailing lists and forums over the past several years. Thanks to all who participated in those discussions! I've tried to link as many of the past threads as I could find.

Thanks also to John McCall and Slava Pestov for laying the groundwork in the compiler recently which enables this feature!

