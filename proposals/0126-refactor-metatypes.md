# Refactor Metatypes

* Proposal: [SE-0126](0126-refactor-metatypes-repurpose-t-dot-self-and-mirror.md)
* Authors: [Adrian Zubarev](https://github.com/DevAndArtist), [Anton Zhilin](https://github.com/Anton3), [Brent Royal-Gordon](https://github.com/brentdax)
* Status: **Revision**
* Review manager: [Chris Lattner](http://github.com/lattner)
* Revision: 2
* Previous Revisions: [1](https://github.com/apple/swift-evolution/blob/83707b0879c83dcde778f8163f5768212736fdc2/proposals/0126-refactor-metatypes-repurpose-t-dot-self-and-mirror.md)

## Introduction

This proposal removes `.Type` and `.Protocol` in favor of two generic-style syntaxes and aligns global `type(of:)` function (SE-0096) to match the changes.

Swift-evolution threads: 

* [\[Revision\] \[Pitch\] Rename `T.Type`](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160718/025115.html)
* [\[Review\] SE-0126: Refactor Metatypes, repurpose T[dot]self and Mirror]()
* [\[Proposal\] Refactor Metatypes, repurpose T[dot]self and Mirror](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160718/024772.html) 
* [\[Discussion\] Seal `T.Type` into `Type<T>`](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160704/023818.html)

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

* `Type<T>` is the concrete type of `T.self`. A `Type<T>` can only ever accept that one specific type, not any of its subtypes. If `T` is a protocol `P`, than the only supertype for `Type<P>` is `Subtype<Any>`. To be crystal clear here, `Type<P>` is not a subtype of `Subtype<P>`.

* `Subtype<T>` is the supertype of all `Type`s whose instances are subtypes of `T`. If `T` is a class, `Subtype<T>` would accept a `Type` for any of its subclasses. If `T` is a protocol, `Subtype<T>` would accept a `Type` for any conforming concrete type.

In this new notation, some of our existing standard library functions would have signatures like:

```swift
func unsafeBitCast<T, U>(_: T, to type: Type<U>) -> U
func sizeof<T>(_: Type<T>) -> Int
func ==(t0: Subtype<Any>?, t1: Subtype<Any>?) -> Bool
func type<T>(of: T) -> Subtype<T> // SE-0096
```

That last example, `type(of:)`, is rather interesting, because it is actually a magic syntax rather than a function. We propose to align this syntax with `Type` and `Subtype` by renaming it to `Subtype(of:)`. We believe this is clearer about both the type and meaning of the operation.

```swift
let instance: NSObject = NSString()
let class: Subtype<NSObject> = Subtype(of: instance)

print(class) // => NSString
```

<details><summary>**Example: visual metatype relationship**</summary>

Types:

```swift
protocol P     { static func foo() }
protocol R : P { static func boo() }
class A : P    { static func foo() { ... } }
class B : A, R { static func boo() { ... } }
```

`Subtype` relationship (not a valid Swift code):

```swift
Subtype<Any> {
  var self: Self { get }
}

Subtype<P> : Subtype<Any> {
  func foo() 
}

Subtype<R> : Subtype<P> { 
  func boo() 
}

Subtype<A> : Subtype<P> { }

Subtype<B> : Subtype<A>, Subtype<R> { }
```

`Type` relationship (not a valid Swift code):

```swift
// `Type` of a protocol is blind
Type<P> : Subtype<Any> { } 

// `Type` of a protocol is blind
Type<R> : Subtype<Any> { } 

Type<A> : Subtype<A> { }

Type<B> : Subtype<B> { }
```

Example:

```swift
let a1: Type<A> = A.self    // Okay
let p1: Type<P> = P.self    // Okay
let p2: Type<P> = C.self    // Error -- `C` is not the same as `P`

let any_1: Subtype<Any> = A.self // Okay
let any_2: Subtype<Any> = P.self // Okay

let a_1: Subtype<A> = A.self     // Okay
let p_1: Subtype<P> = A.self     // Okay
let p_2: Subtype<P> = P.self     // Error -- `Type<P>` is not a subtype of `Subtype<P>`
```

</details>

<details><summary>**Example: generic functions**</summary>

```swift
func dynamic<T>(type: Subtype<Any>, is _: Type<T>) -> Bool {
  return type is Subtype<T>
}

func dynamic<T>(type: Subtype<Any>, as _: Type<T>) -> Subtype<T>? {
  return type as? Subtype<T>
}

protocol Proto {}
struct Struct: Proto {}

let s1: Type<Struct> = Struct.self

dynamic(type: s1, is: Proto.self) //=> true
dynamic(type: s1, as: Proto.self) //=> an `Optional<Subtype<Proto>>`
```

</details>

##Future Directions

* We could allow extensions on `Type` and perhaps on `Subtype` to add members or conform them to protocols. This could allow us to remove some standard library hacks, like the non-`Equatable`-related `==` operators for types.

* It may be possible to implement parts of `Type` as a fairly ordinary final class, moving code from the runtime into the standard library.

* We could offer a `Subtype(ofType: Type<T>, named: String)` pseudo-initializer which would allow type-safe access to classes by name.

* We could offer other reflection and dynamic features on `Type` and `Subtype`.

* We could move the `MemoryLayout` members into `Type` (presumably prefixed), removing the rather artificial `MemoryLayout` enum.

* Along with other generics enhancements, there may be a use for a `Subprotocol<T>` syntax for any protocol requiring conformance to protocol `T`.

## Impact on existing code

This is a source-breaking change that can be automated by a migrator. 

We suggest the following migration process; this can differ from the final migration process implemented by the core team if this proposal will be accepted:

* `Any.Type` is migrated to `Subtype<Any>`.
* If `T.Type` is in function parameter, where `T` is a generic type parameter, then it's migrated to `Type<T>`.
* Every `T.Protocol` will be replaced with `Type<T>`.
* Every `T.Type` in a dynamic cast will be replaced with `Subtype<T>`.
* If static members are called on a metatype instance, then this instance is migrated to `Subtype<T>`.
* Return types of functions are migrated to `Subtype<T>`.
* Variable declarations is migrated to `Subtype<T>`.

## Alternatives considered

Other names for `Type` and `Subtype` were considered:

* Type: SpecificType, Metatype or ExactType.
* Subtype: Supertype, Base, BaseType, ExistentialType or TypeProtocol.

Alternatively the pseudo initializer `Subtype(of:)` could remain as a global function:

```swift
public func subtype<T>(of instance: T) -> Subtype<T>
```
