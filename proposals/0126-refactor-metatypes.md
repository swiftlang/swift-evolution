# Refactor Metatypes

* Proposal: [SE-0126](0126-refactor-metatypes-repurpose-t-dot-self-and-mirror.md)
* Authors: [Adrian Zubarev](https://github.com/DevAndArtist), [Anton Zhilin](https://github.com/Anton3), [Brent Royal-Gordon](https://github.com/brentdax)
* Status: **Revision**
* Review manager: [Chris Lattner](http://github.com/lattner)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/83707b0879c83dcde778f8163f5768212736fdc2/proposals/0126-refactor-metatypes-repurpose-t-dot-self-and-mirror.md)

## Introduction

This proposal removes `.Type` and `.Protocol` in favor of two generic-style syntaxes and aligns global `type(of:)` function (SE-0096) to match the changes.

Swift-evolution thread (post Swift 3): 

* [\[Pitch\] Refactor Metatypes](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160926/027341.html)

Older swift-evolution threads: [\[1\]](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160718/025115.html), [\[2\]](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160718/024772.html), [\[3\]](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160704/023818.html)

## Motivation

Every type `T` has an instance, accessible through `T.self`, which represents the type itself. Like all instances in Swift, this "type instance" itself has a type, which is referred to as its "metatype". The metatype of `T` is written `T.Type`. The instance members of the metatype are the same as the static or class members of the type.

Metatypes have subtype relationships which reflect the types they represent. For instance, given these types:

```swift
protocol Proto {}
class Base {}
class Derived: Base, Proto {}
```

`Derived.Type` is a subtype of both `Base.Type` and `Proto.Type` (and `Any.Type`). That means that `Derived.self` can be used anywhere a `Derived.Type`, `Base.Type`, `Proto.Type`, or `Any.Type` is called for.

Unfortunately, this simple picture is complicated by protocols. `Proto.self` is actually of type `Proto.Protocol`, not type `Proto.Type`. This is necessary because the protocol does not, and cannot, conform to itself; it requires conforming types to provide static members, but it doesn't actually provide those members itself. `Proto.Type` still exists, but it is the supertype of all types conforming to the protocol.

Making this worse, a generic type always uses `T.Type` to refer to the type of `T.self`. So when `Proto` is bound to a generic parameter `P`, `P.Type` is the same as `Proto.Protocol`.

This shifting of types is complicated and confusing; we seek to clean up this area.

We also believe that, in the long term, the dot syntax will prevent us from implementing certain future enhancements that might be valuable:

* Moving the implementation of metatypes at least partly into the standard library.
* Adding members available on all type instances for features like read-write reflection or memory layout information.
* Conforming metatypes to protocols like `Hashable` or `CustomStringConvertible`.
* Offering straightforward syntaxes for dynamic features like looking up types by name.

##Proposed solution

We abolish `.Type` and `.Protocol` in favor of two generic-style syntaxes:

* `Type<T>` is the concrete type of `T.self`. A `Type<T>` only ever has one instance, `T.self`; even if `T` has a subtype `U`, `Type<U>` is not a subtype of `Type<T>`.
 
* `AnyType<T>` is the supertype of all `Type`s whose instances are subtypes of `T`, including `T` itself:
  * If `T` is a struct or enum, then `Type<T>` is the only subtype of `AnyType<T>`.
  * If `T` is a class, then `Type<T>` and the `Type`s of all subclasses of `T` are subtypes of `AnyType<T>`.
  * If `T` is a protocol, then the `Type`s of all concrete types conforming to `T` are subtypes of `AnyType<T>`. `Type<T>` is not itself a subtype of `AnyType<T>`, or of any `AnyType` other than `AnyType<Any>`.

* Structural types follow the subtype/supertype relationships of their constituent types. For instance:
  * `Type<(NSString, NSString)>` is a subtype of `AnyType<(NSObject, NSObject)>`
  * Metatypes of functions are a little bit more special ([the subtyping relation on functions flips around for parameter types](https://en.wikipedia.org/wiki/Covariance_and_contravariance_(computer_science))):
  
    * `Type<(Any) -> Void>` is a subtype of `AnyType<(Int) -> Void>` etc.
    * `Type<(Void) -> Int>` is a subtype of `AnyType<(Void) -> Any>`

In this new notation, some of our existing standard library functions would have signatures like:

```swift
func unsafeBitCast<T, U>(_: T, to type: Type<U>) -> U
func ==(t0: AnyType<Any>?, t1: AnyType<Any>?) -> Bool
func type<T>(of instance: T) -> AnyType<T> // SE-0096
```

That last example, `type(of:)`, is rather interesting, because it is actually a magic syntax rather than a function. We propose to align this syntax with `Type` and `AnyType` by correcting the return type to `AnyType<T>`. We believe this is clearer about both the type and meaning of the operation.

```swift
let anInstance: NSObject = NSString()
let aClass: AnyType<NSObject> = type(of: anInstance)

print(aClass) // => NSString
```

#### More details:
* Every static or class member of `T` which can be called on all subtypes is an instance member of `AnyType<T>`. That includes:

  * Static/class properties and methods
  * Required initializers (as methods named `init`)
  * Unbound instance methods

* The `Type<T>` of a concrete type `T` has all of the members required by `AnyType<T>`, plus non-required initializers.

* The `Type<T>` of a protocol `T` includes only unbound instance methods of `T`.

* If `T` conforms to `P`, then `AnyType<T>` is a subtype of `AnyType<P>`, even if `T` is a protocol.

* The type of `AnyType<T>.self` is `Type<AnyType<T>>`.
* The type of `Type<T>.self` is `Type<Type<T>>`, which is not a subtype of any type except `AnyType<Type<T>>`. There is an infinite regress of `Type<...<Type<T>>>`s.

* `AnyType`s are abstract types similar to class-bound protocols; they, too, support identity operations. 

* `Type`s are concrete reference types which have identities just like objects do.

 ```swift
 Int.self === Int.self // true
 Int.self === Any.self // false
 ```
 
<details><summary>**Visual metatype relationship example (not a valid Swift code)**</summary>

```swift
protocol Foo { 
  static func foo() 
  func instanceMethodFoo()
}

protocol Boo : Foo { 
  static func foo()
  static func boo() 
  func instanceMethodFoo()
  func instanceMethodBoo()
}

class A : Foo { 
  static func foo() { ... } 
  func instanceMethodFoo() { ... }
}

class B : A, Boo { 
  static func boo() { ... } 
  func instanceMethodBoo() { ... }
}

/// Swift generates metatypes along the lines of:
///
/// Syntax: `meta protocol AnyType<T>` - only metatypes can conform to these meta protocols
/// Syntax: `final meta class Type<T>` - metatype
/// Note: `CapturedType` represents `Self` of `T` in `AnyType<T>`

// For Any:
meta protocol AnyType<Any> : meta class {
  var `self`: Self { get }
}

final meta class Type<Any> : AnyType<Any> {
  var `self`: Type<Any> { ... }
}

// For Foo:
meta protocol AnyType<Foo> : AnyType<Any> {
  var `self`: Self { get }
  func foo()
  func instanceMethodFoo(_ `self`: CapturedType) -> (Void) -> Void
}

final meta class Type<Foo> : AnyType<Any> {
  var `self`: Type<Foo> { ... }
  func instanceMethodFoo(_ `self`: Foo) -> (Void) -> Void { ... }
}

// For Boo:
meta protocol AnyType<Boo> : AnyType<Foo> {
  var `self`: Self { get }
  func boo()
  func instanceMethodBoo(_ `self`: CapturedType) -> (Void) -> Void
}

final meta class Type<Boo> : AnyType<Any> {
  var `self`: Type<Boo> { ... }
  func instanceMethodFoo(_ `self`: Boo) -> (Void) -> Void { ... } 
  func instanceMethodBoo(_ `self`: Boo) -> (Void) -> Void { ... } 
}

// For A:
meta protocol AnyType<A> : AnyType<Foo> {
  var `self`: Self { get }
  func foo()
  func instanceMethodFoo(_ `self`: CapturedType) -> (Void) -> Void
}

final meta class Type<A> : AnyType<A> {
  var `self`: Type<A> { ... }
  func foo() { ... }
  func instanceMethodFoo(_ `self`: A) -> (Void) -> Void { ... }
}

// For B:
meta protocol AnyType<B> : AnyType<A>, AnyType<Boo> {
  var `self`: Self
  func foo()
  func boo()
  func instanceMethodFoo(_ `self`: CapturedType) -> (Void) -> Void
  func instanceMethodBoo(_ `self`: CapturedType) -> (Void) -> Void
}

final meta class Type<B> : AnyType<B> {
  var `self`: Type<B> { ... }
  func foo() { ... }
  func boo() { ... }
  func instanceMethodFoo(_ `self`: B) -> (Void) -> Void { ... }
  func instanceMethodBoo(_ `self`: B) -> (Void) -> Void { ... }
}
```
</details>

<details><summary>**Some examples**</summary>

```swift
// Types:
protocol Foo {}
protocol Boo : Foo {}
class A : Foo {}
class B : A, Boo {}
struct S : Foo {}

// Metatypes:
let a1: Type<A> = A.self           //=> Okay
let p1: Type<Foo> = Foo.self       //=> Okay
let p2: Type<Boo> = C.self         //=> Error -- `C` is not the same as `Foo`

let any_1: AnyType<Any> = A.self   //=> Okay
let any_2: AnyType<Any> = Foo.self //=> Okay

let a_1: AnyType<A> = A.self       //=> Okay
let p_1: AnyType<Foo> = A.self     //=> Okay
let p_2: AnyType<Foo> = Foo.self   //=> Error -- `Type<Foo>` is not a subtype of `AnyType<Foo>`

// Generic functions:
func dynamic<T>(type: AnyType<Any>, `is` _: Type<T>) -> Bool {
  return type is AnyType<T>
}

func dynamic<T>(type: AnyType<Any>, `as` _: Type<T>) -> AnyType<T>? {
  return type as? AnyType<T>
}

let s1: Type<S> = S.self

dynamic(type: s1, is: Foo.self)    //=> true
dynamic(type: s1, as: Foo.self)    //=> an `Optional<AnyType<Foo>>`
```
</details>

##Future Directions

* We could allow extensions on `Type` and perhaps on `AnyType` to add members or conform them to protocols. This could allow us to remove some standard library hacks, like the non-`Equatable`-related `==` operators for types.

* It may be possible to implement parts of `Type` as a fairly ordinary final class, moving code from the runtime into the standard library.

* We could offer a new global function which would allow type-safe access to classes by name.

	```swift
	func subtype<T : AnyObject>(of type: Type<T>, named: String) -> AnyType<T>? { ... }
	```

* We could offer other reflection and dynamic features on `Type` and `AnyType`.

* We could move the `MemoryLayout` members into `Type` (presumably prefixed), removing the rather artificial `MemoryLayout` enum.

## Source compatibility

This is a source-breaking change that can be automated by a migrator. 

We suggest the following migration process; this can differ from the final migration process implemented by the core team if this proposal will be accepted:

* `Any.Type` is migrated to `AnyType<Any>`.
* If `T.Type` is in function parameter, where `T` is a generic type parameter, then it's migrated to `Type<T>`.
* Every `T.Protocol` will be replaced with `Type<T>`.
* Every `T.Type` in a dynamic cast will be replaced with `AnyType<T>`.
* If static members are called on a metatype instance, then this instance is migrated to `AnyType<T>`.
* Return types of functions are migrated to `AnyType<T>`.
* Variable declarations is migrated to `AnyType<T>`.

## Alternatives considered

Other names for `Type` and `AnyType` were considered:

* Type: SpecificType, Metatype or ExactType.
* AnyType: Subtype, Supertype, Base, BaseType, ExistentialType, ExistentialMetatype or TypeProtocol.
