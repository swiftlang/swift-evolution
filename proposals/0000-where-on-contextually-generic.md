# `where` clauses on contextually generic declarations

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: **Ongoing Discussion**
* Implementation: [apple/swift#23489](https://github.com/apple/swift/pull/23489)

## Introduction

This proposal is about lifting the restriction on attaching `where` clauses to declarations that themselves
do not introduce new generic parameters, but inherit the surrounding generic environment. Simply put, this means you no longer have to worry about the `'where' clause cannot be attached` error inside a generic context.

```swift
struct Box<Wrapped> {
    func sequence() -> [Box<Wrapped.Element>] where Wrapped: Sequence { ... }
}

```

> Only declarations that already support genericity and being constrained via a conditional
> extension fall under this enhancement. Properties and hitherto unsupported constraint kinds are out
> of scope for the proposal. For instance, the following remains an error:
> ```swift
> protocol P {
>     // error: Instance method requirement 'foo(arg:)' cannot add constraint 'Self: Equatable' on 'Self'
>     func foo() where Self: Equatable  
> }
> ```

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/where-clauses-on-contextually-generic-declaractions/22449)

## Motivation

Today, `where` clauses on contextually generic declarations are expressed indirectly by placing them inside conditional extensions. Unless constraints are identical, every such declaration requires a separate extension.
This dependence on extensions can be an obstacle to grouping semantically related APIs, stacking up constraints and,
sometimes, the legibility of heavily generic interfaces. 

It is reasonable to expect a `where` clause to work anywhere a constraint can be meaningfully imposed, meaning both of these structuring styles should be available to the user:

```swift
struct Foo<T> // 'Foo' can be any kind of nominal type declaration. For a protocol, 'T' would be an associatedtype. 

extension Foo where T: Sequence, T.Element: Equatable {
    func slowFoo() { ... }
}
extension Foo where T: Sequence, T.Element: Hashable {
    func optimizedFoo() { ... }
}
extension Foo where T: Sequence, T.Element == Character {
    func specialCaseFoo() { ... }
}

extension Foo where T: Sequence, T.Element: Equatable {
    func slowFoo() { ... }

    func optimizedFoo() where T.Element: Hashable { ... }

    func specialCaseFoo() where T.Element == Character { ... }
}
```
A step towards "untying" generic parameter lists and `where` clauses is an obvious and farsighted improvement to the generics
system with numerous future applications, including [opaque types](https://github.com/apple/swift-evolution/blob/master/proposals/0244-opaque-result-types.md), [generalized
existentials](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md#generalized-existentials) and constrained protocol requirements. 

## Source compatibility and ABI stability

This is an additive change with no impact on the ABI and existing code.

## Effect on API resilience

For public declarations in resilient libraries, switching between a constrained extension and a «direct» `where` clause
will not be a source-breaking change, but it most likely will break the ABI due to subtle mangling differences.
