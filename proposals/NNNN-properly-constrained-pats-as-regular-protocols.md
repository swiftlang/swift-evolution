# Properly Constrained PATs as Regular Protocols

* Proposal: [SE-NNNN](NNNN-properly-constrained-pats-as-regular-protocols.md)
* Authors: [Filip Sakel](https://github.com/filip-sakel), [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

Protocols are a powerful feature of Swift. They are so diverse that they can be divided into two categories: regular protocols and [Protocols with Associated Requirements](https://docs.swift.org/swift-book/LanguageGuide/Generics.html#ID189) (PATs). PATs are special because they reference `Self` or have associated types - hence the name. As a result PATs can not [act as Types](https://docs.swift.org/swift-book/LanguageGuide/Protocols.html#ID275) contrary to their regular counterparts. This is a sensible constraint, however it can sometimes prove unjustifiably inconvenient in cases where the aforementioned associated types are specified. This proposal aims to ease that constraint allowing PAT conforming protocols to behave as regular protocols when all associated types are specified.

## Motivation

Currently any protocol conforming to a PAT becomes one itself as it inherits its associated types. However, some protocols specify these associated types, making this a frustrating limitations. The following example illustrates this problem:

```swift
protocol User: Identifiable where ID == String {
    var username: String { get }
    var displayName: String { get }
}

extension User {
    var id: String { username }
}
```

Many would rightfully assume that `User` could be used as a type, since we specify that the `ID` asscoated type inherited from [`Identifiable`](https://github.com/apple/swift-evolution/blob/master/proposals/0261-identifiable.md) is `String`. 

```swift
let myUser: User = ... // ❌ User is a Protocol with Associated Requirements
```

This is a great inconvenience with not so elegant workarounds:

```swift
protocol AnyUser { ... } // No Identifiable conformance

let myUser: AnyUser = ... // ✅


protocol User: AnyUser, Identifiable where ID == String { ... }

let myOtherUser: User = ... // ❌ Still an error as expected
```

These workarounds, besides producing boilerplate and confusing code, also produce confusing API designs leaving clients to wonder which of the two protocols should be used. In other cases, API authors may decide that adding `Identifiable` isn’t worth the added complexity and leave the `User` protocol with no such conformance whatsoever. 

As a result, a straightforward conformance to simple - yet quite useful - protocols such as `Identifiable` and others becomes a hassle to implement.


## Proposed solution

We propose to simply stop consider User-like protocols PATs and instead treat them as regular protocols. By extension, this will allow them to be used as Types. Thus, making more natural code possible - which fits a goal of Swift of building ["expressive and elegant APIs"](https://forums.swift.org/t/on-the-road-to-swift-6/32862). Furthermore, library authors could start adding useful protocol conformances to their protocols - a task that's currently prohibitively complex.

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
protocol Foo: PAT where A == Foo, B == Int { ... }
```
> **_NOTE:_** Although this might seem confusing at first, allowing this behavior seems more intuitive. Read more in the [Alternatives Considered](#disallow-constraining-an-associated-type-with-the-protocol-itself) section.


### Syntax 

There’s no syntax change. This change is rather semantic, easing existing restrictions regarding the use of protocols as Types.


### Rules for PAT qualification 

Now, a protocol is considered a PAT if it:

1. Includes at least one associated type or a reference to `Self` - which may have been inherited - and
2. if at least one inherited associated type - if there is any - is _not_ specified.


## Source compatibility

There is no source compatibility impact. As previously mentioned this change is purely semantic. In other words, some protocols will lose PAT 
qualification ([because of rule 2](#rules-for-pat-qualification)), which in turn allows for more flexibility for the user. Even in cases like these:
```swift
func foo<A: ToBeNonPAT>(a: A) { ... }
```
there won't be any source breakage, since the above is currently allowed for regular protocols. 


## Effect on ABI stability

TBA

## Effect on API resilience

With this proposal, Library Authors should be more considerate when adding more associated types to their publicly exposed protocols. That's because PAT inheriting protocols would - under this proposal - gain the ability to become regular ones - [under the right circumstances](#rules-for-pat-qualification)).

For instance, if we added another associated type to `Identifiable`, a _hypothetical_ `User` protocol in the Standard Library would become a PAT, causing source breakage for clients and potentially inside the module itself. Moreover, protocols inheriting `Identifiable` outside of the Standard Library would also be burdened by the PAT restrictions aggrevating the problem as a result.

To reflect these new guidelines the 7th rule for 'allowed' changes ([protocol section](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst#protocols)) will be removed. The rule to be changed, states that: 
> A new associatedtype requirement may be added (with the appropriate availability), as long as it has a default implementation.

This rule will be replaced by the following rule and be moved into the 'forbidden' section:
> Adding `associatedtype` requirements (even if they have a default implementation) 


## Alternatives considered

### Do Nothing

The current design is quite problematic - as mentioned in the [Motivation](#motivation) section. Not to mention, it seems like an abnormality in the generics and exitentials system. There has, also, been post after post asking why this feature isn’t yet implemented - or outright proposing it. Fixing this ‘issue’ will strengthen the foundation of the generics systems to allow for [more and exciting future additions](https://forums.swift.org/t/improving-the-ui-of-generics/22814)


### Disallow Constraining an Associated Type with the Protocol Itself

As mentioned in the [What would be a Regular Protocol](#what-would-be-a-regular-protocol?) section, the fifth example demonstrates how a pretty odd case would be handled. If you think about it, though, it’s not that different from constraining an associated type to the protocol containing it - such as [SwiftUI’s ‘View’](https://developer.apple.com/documentation/swiftui/view). Furthermore, protocols such as the following one are currently allowed: 

protocol Foo {
    var foo: Foo { get }
}

All in all, we don’t think it’s for the compiler to warn us when a protocol is _likely_ to fail, but rather when failure is _certain_.

## Future Directions

TBA
