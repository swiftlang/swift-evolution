# Type inference from default expressions

* Proposal: [SE-0347](0347-type-inference-from-default-exprs.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Accepted**
* Decision Notes: [Rationale](https://forums.swift.org/t/accepted-se-0347-type-inference-from-default-expressions/56558)
* Implementation: [apple/swift#41436](https://github.com/apple/swift/pull/41436)

## Introduction

It's currently impossible to use a default value expression with a generic parameter type to default the argument and its type:

```swift
func compute<C: Collection>(_ values: C = [0, 1, 2]) { ❌
  ...
}
```

An attempt to compile this declaration results in the following compiler error - `default argument value of type '[Int]' cannot be converted to type 'C'` because, under the current semantic rules, the type of a default expression has to work for every possible concrete type replacement of `C` inferred at a call site. There are couple of ways to work around this expressivity limitation, but all of them require overloading which complicates APIs:

```
func compute<C: Collection>(_ values: C) { // original declaration without default
  ...
}

func compute(_ values: [Int] = [0, 1, 2]) { // concretely typed overload of `compute` with default value
  ...
}
```

I propose to allow type inference for generic parameters from concretely-typed default parameter values (referred to as default expressions in the proposal) when the call-site omits an explicit argument. Concretely-typed default expressions would still be rejected by the compiler if generic parameters associated with a defaulted parameter could be inferred _at a call site_ from any other location in a parameter list by an implicit or explicit argument. For example, declaration `func compute<T, U>(_: T = 42, _: U) where U: Collection, U.Element == T` is going to be rejected by the compiler because it's possible to infer a type of `T` from the second argument, but declaration `func compute<T, U>(_: T = 42, _: U = []) where U: Collection, U.Element == Int` is going to be accepted because `T` and `U` are independent.

Under the proposed rules, the original `compute` declaration becomes well formed and doesn't require any additional overloads:

```swift
func compute<C: Collection>(_ values: C = [0, 1, 2]) { ✅
  ...
}
```

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/pitch-type-inference-from-default-expressions/55585)


## Motivation

Interaction between generic parameters and default expressions is confusing when default expression only works for a concrete specialization of a generic parameter. It's possible to spell it in the language (in some circumstances) but requires boiler-plate code and knowledge about nuances of constrained extensions.

For example, let's define a `Flags` protocol and a container type for default set of flags:

```swift
protocol Flags {
  ...
}

struct DefaultFlags : Flags {
  ...
}
```

Now, let's declare a type that accepts a set of flags to act upon during initialization.

```swift
struct Box<F: Flags> {
  init(dimensions: ..., flags: F) {
    ...
  }
}
```


To create a `Box` , the caller would have to pass an instance of type conforming to `Flags` to its initializer call. If the majority of `Box`es doesn’t require any special flags, this makes for subpar API experience, because although there is a `DefaultFlags` type, it’s not currently possible to provide a concretely typed default value for the `flags` parameter, e.g. (`flags: F = DefaultFlags()`). Attempting to do so results in the following error:

```
error: default argument value of type 'DefaultFlags' cannot be converted to type 'F'
```

This happens because even though `DefaultFlags` does conform to protocol `Flags` the default value cannot be used for _every possible_ `F` that can be inferred at a call site, only when `F` is `DefaultFlags`.

To avoid having to pass flags, it's possible to "specialize" the initializer over a concrete type of `F` via combination of conditional extension and overloading.

Let’s start with a direct `where` clause:

```swift
struct Box<F: Flags> {
  init(dimensions: ..., flags: F = DefaultFlags()) where F == DefaultFlags {
    ...
  }
}
```

This `init` declaration results in a loss of memberwise initializers for `Box`.

Another possibility is a constrained extension which makes `F` concrete `DefaultFlags` like so:

```swift
extension Box where F == DefaultFlags {
  init(dimensions: ..., flags: F = DefaultFlags()) {
    ...
  }
}
```

Initialization of `Box` without `flags:` is now well-formed and implicit memberwise initializers are preserved, albeit with `init` now being overloaded, but this approach doesn’t work in situations where generic parameters belong to the member itself.

Let’s consider that there is an operation on our `Box` type that requires passing a different set of flags:

```swift
extension Box {
  func ship<F: ShippingFlags>(_ flags: F) {
    ...
  }
}
```


The aforementioned approach that employs constrained extension doesn’t work in this case because generic parameter `F` is associated with the method `ship` instead of the `Box` type. There is another trick that works in this case - overloading.

 New method would have to have a concrete type for `flags:` like so:

```swift
extension Box {
  func ship(_ flags: DefaultShippingFlags = DefaultShippingFlags()) {
    ...
  }
}
```

This is a usability pitfall - what works for some generic parameters, doesn’t work for others, depending on whether the parameter is declared. This inconsistency sometimes leads to API authors reaching for existential types, potentially without realizing all of the consequences that might entail, because a declaration like this would be accepted by the compiler:

```swift
extension Box {
  func ship(_ flags: any Flags = DefaultShippingFlags()) {
    ...
  }
}
```

 Also, there is no other way to associate default value `flags:` parameter without using existential types for enum declarations:

```swift
enum Box<F: Flags> {
}

extension Box where F == DefaultFlags {
  case flatRate(dimensions: ..., flags: F = DefaultFlags()) ❌ // error: enum 'case' is not allowed outside of an enum
}
```


To summarize, there is a expressivity limitation related to default expressions which could be, only in some circumstances, mitigated via constrained extensions feature, its other issues include:

1. Doesn’t work for generic parameters associated with function, subscript, or case declarations because constrained extensions could only be declared for types  i.e. `init<T: Flags>(..., flags: F = F()) where F == DefaultFlags`  is not allowed.
2. Methods have to be overloaded, which increases API surface of the `Box` , and creates a matrix of overloads if there are more than combination of parameters with default values required i.e. if `dimensions` parameter was to be made generic and defaulted for some box sides.
3. Doesn’t work for `enum` declarations at all because Swift does not support  overloading cases or declaring them in extensions.
4. Requires know-how related to constrained extensions and their ability to bind generic parameters to concrete types.

## Proposed solution

To address the aforementioned short-comings of the language, I propose to support a more concise and intuitive syntax - to allow concretely typed default expressions to be associated with parameters that refer to generic parameters.

```swift
struct Box<F: Flags> {
  init(flags: F = DefaultFlags()) {
    ...
  }
}

Box() // F is inferred to be DefaultFlags
Box(flags: CustomFlags()) // F is inferred to be CustomFlags
```

This syntax could be achieved by amending the type-checking semantics associated with default expressions to allow type inference from them at call sites in cases where such inference doesn’t interfere with explicitly passed arguments.

## Detailed design

Type inference from default expressions would be allowed if:

1. The generic parameter represents either a direct type of a parameter i.e. `<T>(_: T = ...)` or used in a nested position i.e. `<T>(_: [T?] = ...)`
2. The generic parameter is used only in a single location in the parameter list. For example, `<T>(_: T, _: T = ...)`  or `<T>(_: [T]?, _: T? = ...)` are *not* allowed because only an explicit argument is permitted to resolve a type conflict to avoid any surprising behavior related to implicit joining of the types.
    1. Note: A result type is allowed to reference generic parameter types inferable from default expressions to make it possible to use the feature while declaring initializers of generic types or `case`s of generic enums.
3. There are no same-type generic constraints that relate a generic parameter that could be inferred from a default expression with any other parameter that couldn’t be inferred from the same expression. For example, `<T: Collection, U>(_: T = [...], _: U) where T.Element == U` is not allowed because `U` is not associated with defaulted parameter where `T` is used, but `<K: Collection, V>(_: [(K, V?)] = ...) where K.Element == V` is permitted because both generic parameters are associated with one expression.
4. The default expression produces a type that satisfies all of the conformance, layout and other generic requirements placed on each generic parameter it would be used to infer at a call site.


With these semantic updates, both the initializer and `ship` method of the `Box` type could be expressed in a concise and easily understandable way that doesn’t require any constrained extensions or overloading:

```swift
struct Box<F: Flags> {
  init(dimensions: ..., flags: F = DefaultFlags()) {
    ...
  }

  func ship<F: ShippingFlags>(_ flags: F = DefaultShippingFlags()) {
    ...
  }
}
```

`Box` could also be converted to an enum without any loss of expressivity:

```swift
enum Box<D: Dimensions, F: Flags> {
case flatRate(dimensions: D = [...], flags: F = DefaultFlags())
case overnight(dimentions: D = [...], flags: F = DefaultFlags())
...
}
```

At the call site, if the defaulted parameter doesn’t have an argument, the type-checker will form an argument conversion constraint from the default expression type to the parameter type, which guarantees that all of the generic parameter types are always inferred.

```swift
let myBox = Box(dimensions: ...) // F is inferred as DefaultFlags

myBox.ship() // F is inferred as DefaultShippingFlags
```

Note that it is important to establish association between the type of a default expression and a corresponding parameter type not just for inference sake, but to guarantee that there are not generic parameter type clashes with a result type (which is allowed to mention the same generic parameters):

```swift
func compute<T: Collection>(initialValues: T = [0, 1, 2, 3]) -> T {
  // A complex computation that uses initial values
}

let result: Array<Int> = compute() ✅
// Ok both `initialValues` and result type are the same type - `Array<Int>`

let result: Array<Float> = compute() ❌
// This is an error because type of default expression is `Array<Int>` and result
// type is `Array<Float>`
```

## Source compatibility

Proposed changes to default expression handling do not break source compatibility.


## Effect on ABI stability

No ABI impact since this is an additive change to the type-checker.


## Effect on API resilience

All of the resilience rules associated with adding and removing of default expressions are left unchanged, see https://github.com/apple/swift/blob/main/docs/LibraryEvolution.rst#id12 for more details.


## Alternatives considered

[Default generic arguments](https://github.com/apple/swift/blob/main/docs/GenericsManifesto.md#default-generic-arguments) feature mentioned in the Generics Manifesto should not be confused with type inference rules proposed here. Having an ability to default generic arguments alone is not enough to provide a consistent way to use default expressions when generic parameters are involved. The type inference described in this proposal would still be necessary allow default expressions with concrete type to be used when the parameter references a type parameter, and to determine whether the default expression works with a default generic argument type, which means that default generic arguments feature could be considered an enhancement instead of an alternative approach.

A number of similar approaches has been discussed on Swift Forums, one of them being [[Pre-pitch] Conditional default arguments - #4 by Douglas_Gregor - Dis...](https://forums.swift.org/t/pre-pitch-conditional-default-arguments/7122/4) which relies on overloading, constrained extensions, and/or custom attributes and therefore has all of the issues outlined in the Motivation section. Allowing type inference from default expressions in this regard is a much cleaner approach that works for all situations without having to introduce any new syntax or custom attributes.


## Future Directions

This proposal limits use of inferable generic parameters to a single location in a parameter list because all default expressions are type-checked independently. It is possible to lift this restriction and type-check all of the default expressions together which means that if generic parameters is inferable from different default expressions its type is going to be a common type that fits all locations (action of obtaining such a type is called type-join).  It’s not immediately clear whether lifting this restriction would always adhere to the principle of the least surprise for the users, so it would require a separate discussion if this proposal is accepted.

The simplest example that illustrates the problem is `test<T>(a: T = 42, b: T = 4.2)-> T` , this declaration creates a matrix of possible calls each of which could be typed differently:

1. `test()` — T = Double because the only type that fits both `42` and `4.2` is `Double`
2. `test(a: 0.0)`  — T = `Double`
3. `test(b: 0)` — T = `Int`
4. `let _: Int = test()` - fails because `T` cannot be `Int` and `Double` at the same time.
