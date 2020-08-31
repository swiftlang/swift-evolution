# Unlock Existentials with Fixed Associated Types

* Proposal: [SE-NNNN](NNNN-unlock-existentials-with-fixed-associated-types.md)
* Authors: [Filip Sakel](https://github.com/filip-sakel), [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

Today, Swift protocols are divided into two categories: those that _can_ be used as fully-fledged types, and those that `can only be used as generic constraints because they have 'Self' or associated type requirements`. However, in some cases where a protocol inherits and fixes the associated types of another protocol - that doesn't have `Self` requirements, this constraint seems rather unintuitive. This proposal aims to relax this needless constraint allowing such protocols to be used as types.

## Motivation

Currently, any protocol that has associated type requirements is not allowed to be used as a type. That's a sensible constraint; however, considering that the associated types of some protocols are known, this restriction can become quite frustrating: 

```swift
protocol Identifiable {
    associatedtype ID: Hashable
    
    var id: ID { get }
}

protocol User: Identifiable 
    where ID == String {
    
    var username: String { get }
}

extension User {
    var id: String {
        username
    }
}

let myUser: User
// ❌ `User` is not
// usable as a type.
```

Many would rightfully assume that `User` can be used as a type, since the only associated type (`ID`) is known to be `String` via a same-type constraint on the `User` protocol.

One may point out, though, that `myUser` could be bound to `some User`, which would have a similar effects. However, [opaque result types](https://github.com/apple/swift-evolution/blob/master/proposals/0244-opaque-result-types.md) are not existentials. That is, the former allows for hiding type information from the user while the compiler internally retains the underlying type. On the contrary, the latter properly erases type information allowing storage of different types - that conform to a given protocol. What that means, is that should `myUser` be bound to `some User` then initialization would have to be performed at the declaration-site and mutation would be prohibited.

Evidently, this is a great inconvenience with not so elegant workarounds:

```swift
protocol AnyUser { ... } 
// Same as `User` above but
// without `Identifiable` conformance

let myUser: AnyUser
// ✅


protocol User: AnyUser, Identifiable 
    where ID == String { 
    
    var id: String {
        username
    }
}

let myOtherUser: User 
// ❌ Still an error as 
// expected
```

These workarounds, besides producing boilerplate code, also result in confusing API design leaving clients to wonder which of the two protocols should be used. In other cases, API authors may decide that inheriting `Identifiable` isn’t worth the added complexity and leave the `User` protocol with no such feature whatsoever. As a result, a straightforward refinement of simple - yet quite useful - protocols such as `Identifiable` becomes a hassle to implement.

All in all, this behavior seems like an abnormality in the exitentials system. There has, also, been [post](https://forums.swift.org/t/making-a-protocols-associated-type-concrete-via-inheritance/6557) after [post](https://forums.swift.org/t/constrained-associated-type-on-protocol/38770) asking why this feature isn’t yet implemented. Tackling this ‘issue’ will strengthen the foundation of existentials allowing for [exciting future additions](https://forums.swift.org/t/improving-the-ui-of-generics/22814).

## Proposed solution

We propose to simply allow `User`-like protocols to be used as types. Thus, making more natural code possible - which fits a goal of Swift of building ["expressive and elegant APIs"](https://forums.swift.org/t/on-the-road-to-swift-6/32862). Furthermore, library authors will be able to start inheriting useful protocols in their protocols - a task that's currently prohibitively complex.


## Detailed design

Now, a protocol _can_ be used as a type when:
1. the implementations of its associated type requirements — _if_ there are any such requirements — are _fixed_, and when
2. there are _no_ `Self` references in requirements.

#### Examples:

1. Protocol
```swift
protocol AB { 
    associatedtype A
    associatedtype B
}

protocol FixedAB: AB
    where A == String, B == String {}
    
let foo: FixedAB 
// ✅ 
```

2. Protocol Composition
```swift
protocol C { 
    associatedtype C
}

protocol FixedC: C
    where C == String {}

typealias FixedABC = FixedAB & FixedC

let foo: FixedABC 
// ✅ 
```

3. Protocol and Class Composition
```swift
class Class {}

typealias FixedABAndClass = FixedAB & Class

let foo: FixedABAndClass 
// ✅ 
```

Every protocol that is not covered by the [above definition](#which-protocols-would-be-able-to-be-used-as-fully-fledged-types) is, therefore, considered unable to be used as a type.

#### Example:

```swift
protocol ABAndSelf {
    associatedtype A
    associatedtype B
    
    func foo(a: Self)
}

protocol FixedABAndSelf: ABAndSelf
    where A == String, B == String {} 
    
let foo: FixedABAndSelf 
// ❌ Explanation: `Self` cannot 
// be specified; therefore it
// cannot be used as a type.
```


## Source compatibility

This is an additive change with _no_ impact on **source compatibility**.


## Effect on ABI stability

This is an additive change with _no_ impact on **ABI stability**.


## Effect on API resilience

This is an additive change with _no_ impact on **API resilience**.


## Future Directions

### Generalized Existentials 

This proposal is an incremental change that takes Swift a step closure to the end-goal of generalizing existentials. As a result, describing some concepts and terms (such as 'existential') entails the use relevant terminology, which is borrowed from [a recent post by the Core Team](https://forums.swift.org/t/improving-the-ui-of-generics/22814). 

#### Differentiation from Protocols

To alleviate confusion between existentials and protocols it has been proposed that when referring to the former some different way be used. [Some advocate](https://forums.swift.org/t/improving-the-ui-of-generics/22814) for the modifier `any` to serve that purpose: `any Foo`, while [others propose](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md#generalized-existentials) parameterizing `Any`: `Any<Foo>`. Whatever the way of achieving this is, differentiation between the two would be useful as it would - among other reasons - prevent beginners from unknowingly using existentials, which can adversely affect performance. 

#### Existentials for Every Protocol

Currently, existentials are offered only for certain protocols that _don’t_ contain references to `Self` or associated type requirements - hence the differentiation between protocols that are able or unable to be used as types. However, that doesn’t need to be the case. What are currently - or even after this proposal - considered as protocols that are not able to be used as types could also support existentials, further unifying Swift:

```swift
let anyIdentifiable: Any<Identifiable>
```

#### Constraining Existentials

After introducing existentials for all protocols, constraining them seems like the next logical step. Constraining refers to constraining a protocol’s associated types which will, therefore, only be available to protocols that have unspecified associated types. These constraints would probably be the same-type constraint: `where A == B` and the conformance constraint: `where A: B`:

```swift
typealias Foo = Any<
    Identifiable where .ID == String
>

typealias Bar = Any<
    Identifiable where .ID: Comparable 
>
```
    
#### Opening Existentials 

With all the above changes, existentials would still lack an important feature: operations between existentials, such as using `Equatable`’s `==(_:_:)` between its existential types:

```swift
let equatableA = 
    “abc” as Any<Equatable>

let equatableB = 
    12345 as Any<Equatable>

equatableA == equatableB
// ❌ These values can have
// different dynamic types.
```

To solve this problem, [it has been proposed](https://forums.swift.org/t/improving-the-ui-of-generics/22814) that existentials gain the ability to be “opened”: 

```swift
let <E: Equatable> a  = equatableA
// The type of `a` is `E`

if let b = equatableB as? E {
    let result = a == b 
    // ✅ Both are bound to `E`.
}
```
