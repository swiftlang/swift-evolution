# Properly Constrained PATs as Regular Protocols

* Proposal: [SE-NNNN](NNNN-properly-constrained-pats-as-regular-protocols.md)
* Authors: [Filip Sakel](https://github.com/filip-sakel), [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

Protocols are a powerful feature of Swift. They are so diverse that they can be divided into two categories: regular protocols and
[Protocols with Associated Requirements](https://docs.swift.org/swift-book/LanguageGuide/Generics.html#ID189) (PATs).
PATs are special because they reference `Self` or have associated types - hence the name. As a result PATs can not 
[act as Types](https://docs.swift.org/swift-book/LanguageGuide/Protocols.html#ID275) contrary to their regular counterparts. This is a sensible constraint,
however it can sometimes prove unjustifiably inconvenient in cases where the aforementioned associated types are specified. This proposal aims to ease that
constraint allowing PAT conforming protocols to behave as regular protocols when all associated types are specified.

## Motivation

Currently any protocol conforming to a PAT becomes one itself as it inherits it’s associated types. However, some protocols specify these associated types,
making this a frustrating limitations. The following example illustrates this problem:

```swift
protocol User: Identifiable where ID == String {
    var username: String { get }
    var displayName: String { get }
}

extension User {
    var id: String { username }
}
```

Many would rightfully assume that `User` could be used as a type, since we specify that the `ID` asscoated type inherited from 
[`Identifiable`](https://github.com/apple/swift-evolution/blob/master/proposals/0261-identifiable.md) is `String`. 

```swift
let myUser: User = ... // ❌ User is a Protocol with Associated Requirements
```

This is a great inconvenience with not so elegant  workarounds:

```swift
protocol AnyUser { ... } // No Identifiable conformance

let myUser: AnyUser = ... // ✅


protocol User: AnyUser, Identifiable where ID == String { ... }

let myOtherUser: User = ... // ❌ Still an error as expected
```

These workarounds, besides producing boilerplate and confusing code, also produce confusing API designs leaving clients to wonder which of the two protocols
should be used. In other cases, API authors may decide that adding `Identifiable` isn’t worth the added complexity and leave the `User` protocol with no
such conformance whatsoever. 

As a result, a straightforward conformance to simple protocols such as `Identifiable` and others becomes a hassle to implement.


## Proposed solution

We propose to simply stop consider User-like protocols PATs and instead treat them as regular protocols. By extension, this will allow them to be used as Types.
Thus, making more natural code possible - which [fits a goal of Swift of creating "expressive and elegant APIs"](https://forums.swift.org/t/on-the-road-to-swift-6/32862). 
Furthermore, library authors could start adding useful protocol conformances to their protocols that currently prohibitively complex.

## Detailed design


### What would be a Regular Protocol?

What would protocols would be able to be used as types (✅) and what wouldn’t (❌)?

1. ✅ Simple Case (like with `User`)
```swift
protocol User: Identifiable where ID == String { ... }
```

2. ❌ Multiple Associated Types; only Some Specified 
```swift
protocol PAT { 
    associatedtype A
    associatedtype B
}

protocol AlsoPAT: PAT where A == String { ... } 
// B is unknown; therefore it’s a PAT
```

3. ✅ Multiple Associated Types; All Specified
```swift
protocol NonPAT: PAT where A == String, B == Int { ... }
```

4. ❌ Protocols Referencing `Self` (currently erroneous)
```swift
protocol PAT: Equatable where Self == String { ... }
❌ This requirement makes Self non-generic
```
> **_NOTE:_** An `Equatable` conforming protocol will still be PAT, because if `Self` is to be constrained then the protocol loses its generic meaning.

5. ✅ Same-Type Constraint 
```swift
protocol Foo: PAT where A == Foo { ... }
```
> **_NOTE:_** Although this might seem confusing at first, allowing this behavior seems more intuitive. Protocols already allow properties typed with 
the protocol itself, therefore we deem this restriction unnecessary. Read more at [Alternatives Considered](#alternatives-considered)


### Syntax 

There’s no syntax change. This change is rather semantic easing existing restrictions regarding the use of protocols as Types.


### Rules for PAT qualification 

Now, a protocol is considered a PAT if it:

1. Includes at least one associated type or a reference to `Self` - which may have been inherited - and
2. if at least one inherited associated type - if there is any - is _not_ specified.


## Source compatibility

There is no source compatibility impact. As previously mentioned this change is purely semantic. In other words, some protocols will lose PAT 
qualification ([because of rule 2](#rules-for-pat-qualification)), which in turn allows for more flexibility from a user's perspective. Even in cases like these:
```swift
func foo<A: ToBeNonPAT>(a: A) { ... }
```
there won't be any source breakage, since the above is currently allowed for regular protocols. 


## Effect on ABI stability

TBA

## Effect on API resilience

With this proposal Library Authors should be more considerate when adding more associated types to their publicly exposed protocols. This is because any PAT can
now be inherited by other regular protocols which specify its associated types. With this proposal, adding another associated type (even with a default type) to 
`Identifiable`, for example, could qualify a hypothetical Standard Library protocol, which after this proposal would be a regular protocol, as a PAT. If 
this protocol, though, were used as a type outside of the Standard Library, source breakage could occur. Moreover, this scenario could happen with a protocol 
outside the Standard Library and still have the same effects. To reflect these new guidelines the 7th 'allowed' change of the 
[protocol section](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst#protocols) in the 
[library evolution document](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst) will be moved to the 'disallowed' changes.


## Alternatives considered

Describe alternative approaches to addressing the same problem, and
why you chose this approach instead.
