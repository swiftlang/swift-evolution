# Unlock Existentials with Fixed Associated Types

* Proposal: [SE-NNNN](NNNN-unlock-existential-types-for-all-protocols.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis), [Filip Sakel](https://github.com/filip-sakel), [Suyash Srijan](https://github.com/theblixguy)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation: [apple/swift#33767](https://github.com/apple/swift/pull/33767)

## Introduction

Swift allows the use of a protocol as a value type when its *requirements* meet a rather unintuitive list of criteria, among which is the well-known criterion for the absense of associated type requirements, and emits the following error otherwise: "%protocol can only be used as a generic constraint because it has 'Self' or associated type requirements". This proposal aims to *alleviate* this restriction to only impact the ability to invoke certain protocol members (in contrast to eagerly sealing off the entire protocol interface), as well as adjust the specified criteria to reduce the scope of the restriciton.

## Motivation

In Swift, an *existential type* for a given *protocol type* or *protocol composition type* is a formally distinct type that has an equivalent spelling and can hold a value of any conforming type, exposing just the interface(s) of the specified protocol(s) (and superclass). An *existential value* is therefore a value of existential type. The ability to represent an instance of any conforming type enables users and, more importantly, library authors to save on API surface and the considerable amount of boilerplate and difficult-to-maintain code often entailed in the design of ergonomic and exhaustive type-erased wrappers that stand in for a particular existential type. Likewise, existential types can prove incredibly useful in specific use cases that involve dynamicity.

### Heterogenous Collections

Heterogeneous collections inherently involve some sort of dynamicity. Consider this improvised `User` protocol:

```swift
protocol User { 
  associatedtype ID : Hashable 


  var id: ID { get }

  var username: String { get }
} 
```

So, now we want to make business users and regular users that use different types of `ID`s:

```swift
struct BussinessUser : User {
  struct ID : Hashable {
    let organisationName: String

    let organisationId: UUID
  }

  let id: ID

  let username: String
}

struct RegularUser : User {
  // We’ll just use a regular unique identifier for such users.
  let id: UUID

  let username: String
}
```

Great! Now let’s create a list of our users:

```
let userList = [User]() ❌
// Error: Protocol ‘User’ can only be used as a generic 
// constraint because it has Self or associated type requirements.
```

Evidently, the current limitations on existential types prohibit the creation of our `userList`. As a result, we’ll need to create our own, manually-written existential type for `User`, which is a tedious task that requires some level experience.

### Inconsistent Language Semantics

The compiler permits the use of a protocol as a value type **unless** *1) the protocol has an associated type requirement*, or *2) the type of a requirement (method, subscript, or property) contains a reference to `Self` in [non-covariant](https://en.wikipedia.org/wiki/Covariance_and_contravariance_(computer_science)) position*:

```swift
// 'Identifiable' has an associated type requirement.
public protocol Identifiable {
  associatedtype ID: Hashable

  var id: ID { get }
}

// 'Equatable' has a '==' requirement containing a `Self` reference in contravariant parameter position.
public protocol Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool
}
```

The latter condition is well-grounded in terms of the type safety aspect of invoking specific members. Consider the following protocol interface:

```swift
protocol P {
  func foo() -> Self
  
  func bar(_: Self)
}
```

An invocation of a protocol member on an existential value implies the capability to represent the type of that member outside its protocol context. Today, the sole means to representing the dynamic `Self` type of an existential value is type erasure — the substitution of `Self` with a representable supertype, like `P`. On the other hand, type erasure is safe to perform only in [covariant](https://en.wikipedia.org/wiki/Covariance_and_contravariance_(computer_science)) position. For example, calling `foo` on a value of type `P` is safe with its covariant `Self` result type erased to `P`, whereas acting similarly with the contravariant `Self` parameter type in `bar` would expose the opportunity to pass in an argument of non-matching type; hence the condition.

Nonetheless, unlike requirements, protocol extension members cannot afford to retroactively jeopardize the existential availability of the protocol. To handle these, the restriction is forced to take on a more reasonable, on-demand and spot-on manifestation in the form of a member invocation failure:

```swift 
protocol P {}
extension P {
  func method(_: Self) {}
}

func callMethod(p: P) {
  p.method // error: member 'method' cannot be used on value of protocol type 'P'; use a generic constraint instead
}
```

Evidently, an associated type requirement or other unfortunate requirement (such as `bar`) cannot speak for the rest of the interface. Some protocols still have a useful subset of functionality that does not rely on `Self` and associated types at all, or does so in a way that is compatible with existential values.

The case of an associated type requirement that is known to have a predefined implementation reveals another downside to the status quo:

```swift
protocol P {
  associatedtype A
}

protocol Animal: Identifiable where ID == String {}
extension Animal {
  var name: String { id }
}
```

Unfortunately, `Animal` is still "assumed" to have an associated type requirement, which is solely responsible for restraining the existential.

The current semantic inconsistency also discourages authors from refining their existing protocols with other, useful ones in fear of losing existential qualification.

### Library Evolution

Removing the type-level restriction would mean that adding defaulted requirements to a protocol is always both a binary- and source-compatible change, since it would not interfere with existing uses of the protocol.

### Type-erasing Wrappers

For convenience, libraries often vend custom type-erasing wrappers for commonly used protocols. Since the wrapper must evolve in parallel to the protocol, resilience, code size and valuable time required to design, document, and maintain these ergonomic interfaces are all sacrificed. While removing the restriction doesn't define away the need for manual containers, like [`AnySequence`](https://developer.apple.com/documentation/swift/anysequence) and [`AnyHashable`](https://developer.apple.com/documentation/swift/anyhashable), it does allow writing them in a simpler, more easily optmizable, and ABI-compatible way. This is achieved by wrapping the unconstrained existential type instead of falling back on `Any` or boxing a value in a subclass or closure, and using private protocol extensions to wrap requirements that cannot be directly accessed on the existential:

```swift
protocol Foo {
  associatedtype Bar

  func foo(_: Bar) -> Bar
}

private extension Foo {
  // Forward to the foo method in an existential-accessible way, asserting that
  // the '_Bar' generic argument matches the actual 'Bar' associated type of the
  // dynamic value.
  func _fooThunk<_Bar>(_ bar: _Bar) -> _Bar {
    assert(_Bar.self == Bar.self)
    let result = foo(unsafeBitCast(bar, to: Bar.self))
    return unsafeBitCast(result, to: _Bar.self)
  }
}

struct AnyFoo<Bar>: Foo {
  private var _value: Foo

  init<F: Foo>(_ value: F) where F.Bar == Bar {
    self._value = value
  }
  
  func foo(_ bar: Bar) -> Bar {
    return self._value._fooThunk(bar)
  }
}
```

## Proposed Solution

We propose to allow any protocol to be used as a value type and exercise the restriction on individual member invocations uniformly across extension members *and* requirements. Additionally, the defining criteria shall consider the generic signature of the base type to account for predefined or known implementations of associated type requirements. Among other subtle circumstances, this will allow the qualification checking to bypass references to `Self`-rooted associated types when the protocol binds them to a fully concrete type via same-type constraints:

```swift
protocol IntCollection: BidirectionalCollection where Self.Element == Int {}

let array: IntCollection = [3, 1, 4, 1, 5]

print(array.first.unsafelyUnwrapped) // OK, prints "3"
```

### Covariant Associated Type Erasure

With existential types unlocked, the mere existence of an associated type requirement will no longer prevent one from using a member, but references to them *will* for the same reason some `Self` references do today. As alluded to in [Inconsistent Language Semantics](#inconsistent-language-semantics), covariant `Self` references are already getting replaced with the existential base type, making the following example valid today.

```swift
protocol P {
  func foo() -> Self
}

func callFoo(_ p : P) {
  let x = p.foo() // x is of type 'P'
}
```

Because they tend to occur considerably more often than `Self` in API, and for the sake of consistency, we believe that enabling covariant type erasure for associated types as well is a reasonable undertaking in light of the primary focus:

```swift
protocol P {
  associatedtype A: Collection
  func foo() -> A
}

func callFoo(_ p: P) {
  let x = p.foo() // OK, x is of type 'Collection'
}
```
___

This way, a protocol or protocol extension member (method, subscript, or property) may be used with an existential base iff all of the following criteria hold:
* the type of the invoked method or accessor, as viewed in context of the *base type*, must **not** contain references to `Self` or `Self`-based associated types in [non-covariant](https://en.wikipedia.org/wiki/Covariance_and_contravariance_(computer_science)) position.

## Detailed Design

### Availability of Existential Type

Namely, under the new rules, we propose that a compiler-generated existential be offered for protocols and protocol compositions no matter their requirements.

### Availability of Requirements

It's important to note that not all requirements will be available through the existential types. That is, requirements that reference `Self` or any _non-fixed_ associated types in a _non-covariant_ position will _not_ be available through the generated existential type. For instance, consider the following code using the existential of the standard library's [`Equatable`](https://developer.apple.com/documentation/swift/equatable) protocol:

> **Note**: Use of _non-covariant_ is intentional as requirements in both `func a(_: Self)` and `func a() -> [Self]` forms are not available in existential types.

```swift
protocol Equatable {

  static func == (lhs: Self, rhs: Self) -> Bool
  //                   ^~~~       ^~~~
  // Use of 'Self' in a non-covariant position.

}

struct Dog : Equatable { ... }


let ownerName = "Paul" as Equatable ✅

let petName = "Alex" as Equatable ✅

let dog = Dog(named: petName) as Equatable ✅


ownerName == petName ❌
// Error: TBD

ownerName == dog ❌
// Error: TBD
```

> **Rationale**: In the above case, it would be reasonable to assume that `ownerName` and `petName` could be compared, since they're both bound to `String`. However, that would be inaccurate, as they're actually bound to the existential type of `Equatable`. In spite of this, it could, still, be argued that `Equatable`'s `==(lhs:rhs:)` operator could unwrap its boxed `Self` parameters to the unboxed type ( `String` in this case), and thus compare its two `Self` parameters. There are, though, fundental problems with this approach, the most important of which being the fact that two `Self` parameters could be bound to different types, which would introduce undefined behavior. The example of comparing `ownerName` and `dog`, demonstrates this perfectly, as – besides being unsound – it poses the question of how it should be handled, if it were valid.

### Types of Requirements

As for the type that a requirement will be bound to when accessed from an existential type, it should be noted that all requirements that do _not_ reference `Self` or any associated type _will_ retain their type as is. However, requirements that do _not_ meet these criteria will be bound to an existential type of `Self` or the relevant associated type accordingly. For instance:

```swift

protocol User { 

  associatedtype ID : Hashable 


  var id: ID { get }

  var username: String { get } 

}

struct RegularUser : User { ... }


let regularUser = RegularUser(id: UUID(), username: "i❤️Swift")

let userExistential = regularUser as User


userExistential.username ℹ️
// Output: i❤️Swift

type(of: userExistential.username) ℹ️
// Output: String


type(of: userExistential.id) ℹ️
// Output: Hashable
```

Looking at the above, one will notice that the `id` requirement of `User` is available despite being bound to the associated type `ID`; thus, the compiler exposes the existential type of `Hashable` as `id`'s type – since, the associated type is _unknown_ in the eyes of `userExistential`. Of course, `username` – whose type is known to be `String` – retains its type, as seen in the above example.


## Source Compatibility & Effect on ABI Stability

The proposed changes are ABI-additive and source-compatible.

## Effect on API Resilience

Adding defaulted requirements to a protocol will become a source-compatible change.

## Alternatives Considered

TBD

## Future Directions

### Discourage Use of Existential Types When Inappropriate 

It is often that people confuse generic declaration with existential types. For example, many think that the following declarations are identical in functionality:

```swift
protocol Pet {

  var name: String { get }

  var animalName: String { get }  

} 

func call(pet: Pet) {
  print(pet.name)
}

// the above is different from this

func call<SomePet : Pet>(pet: SomePet) {
  print(pet.name)
}
```

The difference is quite significant: the former utilizes `Pet`’s existential type, whereas the latter uses generics.  The difference is important, as existential types are meant for use cases wherein dynamic behavior is required, but to achieve these semantics they pay a performance penalty. On the contrary, generics introduce abstraction at compile time; as a result, the compiler can make optimizations that significantly improve performance. Unfortunately, this mistake is common and the documentation may play a crucial role in that. Namely, when one goes to the swift documentation site, under the protocols section, they’ll be greeted  with a subsection called [‘Protocols as Types`](https://docs.swift.org/swift-book/LanguageGuide/Protocols.html#ID275), which contains this example:

```swift
class Dice {

  let sides: Int

  let generator: RandomNumberGenerator
  // Here, ‘generator’ is bound to the existential
  // type of ‘RandomNumberGenerator’


  init(sides: Int, generator: RandomNumberGenerator) {
    self.sides = sides
    self.generator = generator 
  }


  func roll() -> Int {
    return Int(generator.random() * Double(sides)) + 1
  }

}
```

The authors of this section are not to blame for the inappropriate use of an existential type, as this section was written before [opaque types]() where introduced. However, now it seems that documentation and diagnostics can be improved to mitigate this problem. Therefore, we could encourage the use of opaque result types: 

```swift
let randomNumberGenerator: some  RandomNumberGenerator = …
```

Or offer different diagnostics for the following code:

```swift
struct Dice {

  let generator: some RandomNumberGenerator ❌
  // Error: Property declares an opaque return type,
  // but has no initializer expression from which to infer
  // an underlying type.

  init(sides: Int, generator: some RandomNumberGenerator) { ❌
    // Error: 'some' types are only implemented for the declared 
    // type of properties and subscripts and the return type of functions

    self.sides = sides
    self.generator = generator 
  }

  …

} 
```

Maybe, we could provide a fix-it message that prompts us to use generics:

> Did you mean to use a generic parameter conforming to `RandomNumberGenerator` in struct `Dice`?

As for the second case, such syntax could be made valid in a future proposal, as it is quite unambiguous and could be equivalent to `<NumberGenerator : RandomNumberGenerator>`.

Lastly, the overall documentation could use existential types only when appropriate and note that it's different from generics.


### Simplify the Implementation of Custom Existential Types

Currently, in the standard library there's a custom existential type for `Hashable`, which is called [`AnyHashable`](https://developer.apple.com/documentation/swift/anyhashable). The current implementation of `AnyHashable` is quite complex and unintuitive. However, with the proposed change it could be simplfied and from 306 to 237 lines of code, while having a much simpler mental medal. The important thing to note about `AnyHashable` is that it conforms to the protocol it is an existential of: `Hashable`, which is something that the compiler can't automatically provide. Furthermore, `Equatable` has `Self` requirements in non-covariant positions, which means that such requirements are inaccessible through the existential type. To combat the last limitation, an internal extension to `Equatable` could be added:

```swift
extension Equatable {

  func isEqual<Value>(to otherValue: Value) -> Bool? {
    guard let castedValue = otherValue as? Self else {
     return nil
    }
    
    return self == castedValue
  }
  
}
```

Finally, we'd be able to add our existential type with access to both `Hashable`'s and `Equatable`'s requirements:

```swift
public struct AnyHashable {
  var _base: Hashable

  ...
}
```

Likewise, protocols like SwiftUI's `View` could be rewritten by forwarding their contravariant `Self` requirements to internal instance methods and accessing them from the `View`-conforming `AnyView` existential with the help of the compiler-provided `View` existential – similar to what we could do with `AnyHashable`.


### Strenghten the Generics System

TBD


### Updated Syntax for Compiler-Generated Existential Types

TBD


### Allow Constrainting an Existential Type

TBD


### Allow Extending Existential Types

TBD
