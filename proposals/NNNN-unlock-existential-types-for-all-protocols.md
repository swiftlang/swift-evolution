# Unlock Existentials with Fixed Associated Types

* Proposal: [SE-NNNN](NNNN-unlock-existential-types-for-all-protocols.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis), [Filip Sakel](https://github.com/filip-sakel), [Suyash Srijan](https://github.com/theblixguy)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation: [apple/swift#33767](https://github.com/apple/swift/pull/33767)

## Introduction

Swift allows the use of a protocol as a value type when its *requirements* meet a rather unintuitive list of criteria, among which is the well-known criterion for the absense of associated type requirements, and emits the following error otherwise: "%protocol can only be used as a generic constraint because it has 'Self' or associated type requirements". This proposal aims to *alleviate* the restriction to only impact the ability to invoke certain protocol members (in contrast to sealing off the entire protocol interface), as well as adjust the specified criteria to reduce the scope of the restriciton.

## Motivation

In Swift, an *existential type* for a given *protocol type* or *protocol composition type* is a formally distinct type that has an equivalent spelling and can hold a value of any conforming type, only exposing the interface(s) of the specified protocol(s) (and superclass). The ability to represent an instance of any conforming type enables users and, more importantly, library authors to save on API surface and the considerable amount of boilerplate and difficult-to-maintain code often entailed in the design of ergonomic and exhaustive type-erased wrappers that stand in for a particular existential type. Likewise, existential types can prove incredibly useful in specific use cases that involve dynamicity.

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


### Existential Type Synthesis for Library Authors

For convenience, libraries are often bound to vend custom type-erased wrappers for commonly-used protocols when their existential counterpart is not supported. This comes at the expense of code size, resilience, and valuable time required to design, document, and maintain such code, more so if the protocol is declared in a different library. For instance, [SwiftUI](https://developer.apple.com/documentation/swiftui) heavily relies on the ubiquitous [`View`](https://developer.apple.com/documentation/swiftui/view) protocol with a public interface approximating the following:

```swift
public protocol View {
  static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs

  static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs

  static func _viewListCount(inputs: _ViewListCountInputs) -> Int?


  associatedtype Body : View

  @ViewBuilder var body: Body { get }
}
```

From the interface of `View`, we can infer that SwiftUI uses some hidden, underscore-prefixed requirements internally for rendering. Thus, the associate type `Body` is likely not necessary for drawing; yet, it prevents the compiler from creating an existential type for `View`, forcing the authors to create their own such type: [`AnyView`](https://developer.apple.com/documentation/swiftui/anyview). Furthermore, another notable example is the [`Hashable`](https://developer.apple.com/documentation/swift/hashable) protocol in the Swift standard library. Consequently, this may lead authors to inconvenient workarounds. One such workaround is splitting their protocols into two distinct ones – so as to separate associated types from hidden requirements; unfortunately, this creates a complicated API, which is likely to confuse users. Otherwise, they can do what was discussed above: create a custom existential type; it creates, though, boilerplate, which is clearly undesirable. 


### Inconsistent Language Semantics 

The compiler offers existential types for all protocols except for ones that reference `Self` in a [non-covariant](https://en.wikipedia.org/wiki/Covariance_and_contravariance_(computer_science)) position or/and ones that have associated type requirements. However, that is incohesive as `Self` can be thought of as an associated type on its own, because it's can't be known solely from the context of a protocol; thus, giving `Self` and associated types different rules for synthesis of an existential type seems rather unintuitive. Furthermore, current semantics can promt library authors to avoid refining their protocols with other useful protocols in fear of their refined protocol not qualifying for the automatically generated existential type. Consider the following `Animal` protocol:

```swift
protocol Identifiable {

  associatedtype ID : Hashable


  var id: ID { get }

}


protocol Animal : Identifiable where ID == String {

  var name: String { get }
  
  var speciesName: String { get }
  
  
  var isPet: Bool { get }

}

extension Animal {

  var id: String {
    name
  }

}
```

In the above case, the `Identifiable` inheritence is very useful. Namely, without any cost to the conforming type, `Animnal` can easily refine [`Identifiable`](https://github.com/apple/swift-evolution/blob/main/proposals/0261-identifiable.md) and gain powerful functionality, as a result. For instance, SwiftUI's [`ForEach`](https://developer.apple.com/documentation/swiftui/foreach) view relies on its data source conforming to `Identifiable`, in which case having such a conformance for free on `Animal`-conforming types is very convenient. Lastly, it's also important to note that in the above example the associated type `ID` is fixed to `String`; therefore, the current limitation seems even more unnecessarily restrictive and further exacerbates the confusion surrounding existential types. 


## Proposed Solution

We propose to enable synthesis of existential types for all protocols, in spite of their requirements. Thus, compositions which include protocols that could – before this proposal – not be used as types, will along with these protocols get compiler-generated existential types. Thus code similar to the following will become valid.

```swift
protocol Animal : Identifiable where ID == String {

  ...

}

struct Dog : Animal { ... }

struct Cat : Animal { ... }


let myPets: [Animal] = [
  Dog(named: "Alex"),
  Cat(named: "Leo")
] ✅

myPets.first!.name ℹ️
// Output: Alex
```


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


## Source Compatibility

This is an additive change with _no_ impact on **source compatibility**.


## Effect on ABI Stability

This is an additive change with _no_ impact on **ABI stability**.


## Effect on API Resilience

From now on, adding a defaulted associated type is both a binary- and source-compatible change.


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
