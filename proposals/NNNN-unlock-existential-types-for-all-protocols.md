# Unlock Existentials for All Protocols

* Proposal: [SE-NNNN](NNNN-unlock-existential-types-for-all-protocols.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis), [Filip Sakel](https://github.com/filip-sakel), [Suyash Srijan](https://github.com/theblixguy)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation: [apple/swift#33767](https://github.com/apple/swift/pull/33767)


### Introduction

Swift currently offers the ability for protocols that meet certain criteria to be used as types. Trying to use an unsupported protocol as a type yields the error `[the protocol] can only be used as a generic constraint because it has 'Self' or associated type requirements`. This proposal aims to relax this artificial constraint imposed on such protocols.


### Motivation

Currently, any protocol that has [non-covariant](https://en.wikipedia.org/wiki/Covariance_and_contravariance_(computer_science)) `Self` references or associated type requirements is not allowed to be used as a type. Initially, this restriction reflected technical limitations (as Joe states [here](https://forums.swift.org/t/lifting-the-self-or-associated-type-constraint-on-existentials/18025)); however, such limitations have now been alleviated. As a result, users are left unable to utilize a powerful feature for certain protocols. That’s evident in a plethora of projects. For instance, the Standard Library has existential types such as [`AnyHashable`](https://developer.apple.com/documentation/swift/anyhashable) and [`AnyCollection`](https://developer.apple.com/documentation/swift/anycollection) and SwiftUI has [`AnyView`](https://developer.apple.com/documentation/swiftui/anyview). 

Generics are most often the best mechanism for type-level abstraction, which relies on the compiler knowing type information during compilation. However, type information is not always a gurantee, which is why the value-level abstraction of existential types is extremely useful in some cases.

One such case is heterogenous collections, which require value-level abstraction to store their elements of various types:

```swift
protocol Identifiable {
  associatedtype ID: Hashable 
    
  var id: ID { get }
}

let invalidIdentifiables: [Identifiable] ❌
// The compiler doesn't currently allow that.
// So, we work around that by creating a
// custom existential type: 'AnyIdentifiable'.


struct AnyIdentifiable { 
  typealias ID = AnyHashable
    
  var id: ID { ... }
}

let myIdentifiables: [AnyIdentifiable] ✅
```

Furthermore, dynamic environments are also known to lack type information. Therefore value-level abstraction can be exploited in cases such as previewing an application, where the application's components are dynamically replaced, in the file system where a file representing an unknown type might be stored, and in server environments, where various types could be exchanged between different computers.

Morover, the availability of an existential type for a given protocol is sometimes quite unintuitive. That is, today, a protocol qualifies for an existential type provided that it lacks any associated type or non-covariant `Self` requirements; however, the associated types of a protocol can be fixed via the same-type constraint. As a result, [post](https://forums.swift.org/t/making-a-protocols-associated-type-concrete-via-inheritance/6557) after [post](https://forums.swift.org/t/constrained-associated-type-on-protocol/38770) has been created asking for this restriction's removal:

```swift
protocol User: Identifiable
  where ID == UUID {
  
  var username: Strng { get }
}
  
let myUsers: [User] ❌
// This is forbidden today
// for no apparent reason.
```

All in all, supporting existential types for all protocols is useful for many situations that involve dynamicity. Not to mention that there are many questions by language users asking about this behavior. Taking everything into consideration, we are confident that addressing this abnormality in the language will build a stronger foundation for [future additions](https://forums.swift.org/t/improving-the-ui-of-generics/22814).


### Proposed Solution

The constraint prohibiting the use of some protocols as types will be lifted. Consequently, boilerplate code in many projects - especially libraries and frameworks - will be significantly reduced.


### Detailed Design 

The compiler will no longer differentiate between protocols that don’t have `Self` or associated type requirements and those that do. However, some restrictions will apply to the use of requirements referencing associated types as seen in the below examples.

#### Examples:

##### Protocol with `Self` and Associated Type Requirements 

```swift
protocol A {
  associatedtype A
    
  var a: A { get }
}

struct S: A { 
  let a: Int = 5
}

let myA: A = S() ✅ 


let a: Any = myA.a ❌
// We don’t know what associated type 
// 'A' is on the existential type of 'A'.


extension A {
  var opaqueA: some Any {
    a 
  }
  // Note that it references 
  // the associated type 'A'.
}

let opaqueA: some Any = myA.opaqueA ❌
// Opaque result type don't 
// type-erase; they just conceal
// the underlying value from the
// user. As a result, the above 
// is not allowed.
```

##### Protocol with Known Associated Types

```swift
protocol A {
  associatedtype A

  var a: A { get }
}

protocol RefinedA: A
  where A == Int {}

struct S: RefinedA { 
  let a: Int = 5
}

let myRefinedA: RefinedA = S() ✅

let intA: Int = myRefinedA.a ✅
// Here we know that the associated
// type 'A' of 'RefinedA' is 'Int'.
```

##### Protocol Composition 

```swift
protocol A {
  associatedtype A

  var a: A { get }
}

protocol RefinedA: A
  where A == Int {}

protocol B {
  associatedtype B

  var b: B { get }
}

struct S: RefinedA & B { 
  let a: Int = 5
  let b: Int = 5
}


let myRefinedAB: RefinedA & B = S() ✅


let a: Int = myRefinedAB.a ✅

let b: some Any = myRefinedAB.b ❌
// We don’t know what type 'B' is
// on the type-erased value 'myRefinedAB'.
```


## Source compatibility

This is an additive change with _no_ impact on **source compatibility**.


## Effect on ABI stability

This is an additive change with _no_ impact on **ABI stability**.


## Effect on API resilience

This is an additive change with _no_ impact on **API resilience**.


### Alternatives Considered

We could leave Swift as is. That, however - as discussed in the Motivation section - produces boilerplate code and a lot of confusion for language users.


### Future Directions

#### Separate Existential Types from Protocols

To alleviate confusion between existential types and protocols it has been proposed that when referring to the former some different way be used. Some advocate for the modifier 'any' to serve that purpose: `any Foo`, while others propose parameterizing 'Any': `Any<Foo>`. Whatever the way of achieving this is, differentiation between the two would be useful as it would - among other reasons - prevent beginners from unknowingly using existential types, which can adversely affect performance.


#### Introduce Constraints for Existential Types

After introducing existential types for all protocols, constraining them seems like the next logical step. Constraining refers to constraining a protocol’s associated types which will, therefore, only be available to protocols that have unspecified associated types. These constraints would probably be the same-type constraint: `where A == B` and the conformance constraint: `where A: B`:

```swift
typealias A = Any<
  Identifiable where .ID == String
>

typealias B = Any<
  Identifiable where .ID: Comparable 
>
```

#### Allow Accessing Associated Types

Currently, accessing associated types through a protocol's existential type is invalid. However, we could ease that constraint by replacing every associated type of the 'base' protocol with its existential type:

```swift
protocol Identifiable {
    assciatedtype ID: Hashable

    var id: ID { get }
}

struct S: Identifiable {
  let id: Int = 5
}

let myIdentifiable: Identifiable = S()

let id: Any<Hashable> = myIdentifiable.id ✅
```

#### Make Existential Types Extensible

Today, no protocol’s existential type can conform to the protocol itself (except for [`@objc` protocols](https://docs.swift.org/swift-book/LanguageGuide/Protocols.html#ID284)). This is quite unintuitive - as is evident by countless questions asking about it. Such a feature could automatically apply to protocols that lack initializers, static requirements and functions with parameters bound to `Self` (as discussed in [related post](https://forums.swift.org/t/allowing-self-conformance-for-protocols/39841)). To handle the cases that do not meet the aforementioned criteria for implicit conformance, the following syntax [has been proposed](https://forums.swift.org/t/improving-the-ui-of-generics/22814):

```swift
extension Any<Hashable>: Hashable {
  …
}
```
Other protocols that _do_ meet these criteria would have existential types that automatically gain conformance to their corresponding protocol. In other words, a type such as `Error` would automatically gain support for conformance to the `Error` protocol.
