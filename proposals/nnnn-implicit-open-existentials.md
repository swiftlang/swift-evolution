# Implicitly Opened Existentials

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting review**

* Implementation: [apple/swift#41183](https://github.com/apple/swift/pull/41183)

## Introduction

Existential types in Swift allow one to store and reason about a value whose specific type is unknown and may change at runtime. The dynamic type of that stored value, which we refer to as the existential's *underlying type*, is known only by the set of protocols it conforms to and, potentially its superclass. While existential types are useful for expressing values of dynamic type, they are necessarily restricted because of their dynamic nature. Recent proposals have made [existential types more explicit](https://github.com/apple/swift-evolution/blob/main/proposals/0335-existential-any.md) to help developers understand this dynamic nature, as well as [making existential types more expressive](https://github.com/apple/swift-evolution/blob/main/proposals/0309-unlock-existential-types-for-all-protocols.md). However, a fundamental issue with existential types remains, that once you have an existential type it is *very* hard to then use any generic operations a value of that type. Developers usually encounter this via the error message "protocol 'P' as a type cannot conform to itself":

```swift
protocol P {
  associatedtype A
  func getA() -> A
}

func takeP<T: P>(_ value: T) { }

func test(p: any P) {
  takeP(p) // error: protocol 'P' as a type cannot conform to itself
}
```

This interaction with the generics system makes existentials a bit of a trap in Swift: it's easy to go from generics to existentials, but once you have an existential it is very hard to go back to using it generically. At worst, you need to go back through many levels of functions, changing their parameters or results from `any P` to being generic over `P`, or writing a custom [type eraser](https://www.swiftbysundell.com/articles/different-flavors-of-type-erasure-in-swift/). 

This proposal addresses this existential trap by allowing one to "open" an existential value, binding a generic parameter to its underlying type. Doing so allows us to call a generic function with an existential value, such that the generic function operations on the underlying value of the existential rather than on the existential box itself, making it possible to get out of the existential trap without major refactoring.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

Swift's existentials are a powerful tool for working with a dynamic set of types dynamically, but their inability to interoperate well with Swift's generics is limiting and often leads developers into an existential "trap" where one has a value of existential type but cannot access necessary generic operations on that value.  Designs that fall into the existential trap aren't necessarily bad designs, but the workarounds needed for them involve a lot of refactoring (e.g., turning everything generic) or building custom type eraser types. These involve advanced language features and techniques, resulting in a significant amount of boilerplate as well as creating a steep learning curve for the language. Smoothing out this interaction between existentials and generics can simplify Swift code and make the language more approachable.

## Proposed solution

To make it easier to move from existentials back to the more strongly-typed generics, we propose to implicitly *open* an existential value when it is passed to a parameter of generic type. In such cases, the generic argument refers to the *underlying* type of the existential value rather than the existential "box". Let's start with a protocol `Costume` that involves `Self` requirements, and write a generic function that checks some property of a costume:

```swift
protocol Costume {
  func withBells() -> Self
  func hasSameAdornments(as other: Self) -> Bool
}

// Okay: generic function to check whether adding bells changes anything
func hasBells<C: Costume>(_ costume: Costume) -> Bool {
  return costume.hasSameAdornments(as: costume.withBells())
}
```

This is fine. However, let's write a function that makes sure every costume has bells for the big finale. We run into problems at the boundary between the array of existential values and our generic function:

```swift
func checkFinaleReadiness(costumes: [any Costume]) -> Bool {
  for costume in costumes {
    if !hasBells(costume) { // error: protocol 'Costume' as a type cannot conform to the protocol itself
      return false
    }
  }
  
  return false
}
```

In the call to `hasBells`, the generic parameter `C` is getting bound to the type `any Costume`, i.e., a box that contains a value of some unknown underlying type. Each instance of that box type might have a different type at runtime, so even though the underlying type conforms to `Costume`, the box does not. That box itself does not conform to `Costume` because it does not meet the requirement for `hasSameAdornments`., i.e., two boxes aren't guaranteed to store the same the same underlying type.

This proposal introduces implicitly opened existentials, which allow one to use a value of existential type (e.g., `any Costume`) where its underlying type can be captured in a generic parameter. For example, the call  `hasBells(costume)` above would succeed, binding the generic parameter `C` to the underlying type of that particular instance of `costume`. Each iteration of the loop could have a different underlying type bound to `C`:

```swift
func checkFinaleReadiness(costumes: [any Costume]) -> Bool {
  for costume in costumes {
    if !hasBells(costume) { // okay with this proposal: C is bound to the type stored inside the 'any' box, known only at runtime
      return false
    }
  }
  
  return true
}
```

Implicitly opening existentials allows one to take a dynamically-typed value and give its underlying type a name by binding it to a generic parameter, effectively moving from a dynamically-typed value to a more statically-typed one. This notion isn't actually new: calling a member of a protocol on a value of existential type implicitly "opens" the `Self` type. In the existing language, one could implement a shim for `hasBells` as a member of a protocol extension:

```swift
extension Costume {
  var hasBellsMember: Bool {
    hasBells(self) 
  }
}

func checkFinaleReadinessMember(costumes: [any Costume]) -> Bool {
  for costume in costumes {
    if !costume.hasBellsMember { // okay today: 'Self' is bound to the type stored inside the 'any' box, known only at runtime
      return false
    }
  }
  
  return true
}
```

In that sense, implicitly opening existentials for calls to generic functions is a generalization of this existing behavior to all generic parameters. It isn't strictly more expressive: as the `hasBellsMember` example shows, one *can* always write a member in a protocol extension to get this opening behavior, and trampoline over to another language feature. This proposal aims to make implicit opening of existentials more uniform and more ergonomic, by making it more general.

Let's consider one last implementation of our "readiness" check, where want to "open code" the check for bells without putting the logic into a separatae generic function `hasBells`:

```swift
func checkFinaleReadinessOpenCoded(costumes: [any Costume]) -> Bool {
  for costume in costumes {
    let costumeWithBells = costume.withBells() // returned type is 'any Costume'
    if !costume.hasSameAdornments(costumeWithBells) { // error: 'any Costume' isn't necessarily the same type as 'any Costume'
      return false
    }
  }
  
  return true
}
```

There are two things to notice here. First, the method `withBells()` returns type `Self`. When calling that method on a value of type `any Costume`, the concrete result type is not known, so it is type-erased to `any Costume` (which becomes the type of `costumeWithBells`). Second, on the next line, the call to `hasSameAdornments` produces a type error because the function expects a value of type `Self`, but there is no statically-typed link between `costume` and `costumeWithBells`: both are of type `any Costume`. Again, implicit opening of existentials can address this issue by allowing a variable specified with a `some` type to refer to the underlying type of the expression that initializes it, e.g.

```swift
func checkFinaleReadinessOpenCoded(costumes: [any Costume]) -> Bool {
  for costume: some Costume in costumes {   // implicit generic parameter binds to underlying type of each costume
    let costumeWithBells = costume.withBells() // returned type is the same 'some Costume' as 'costume'
    if !costume.hasSameAdornments(costumeWithBells) { // okay, 'costume' and 'costumeWithBells' have the same type
      return false
    }
  }
  
  return true
}
```

By generalizing the implicit opening of existentials to arbitrary generic parameters and also variables declared with opaque types (via `some`), this proposal makes it possible to get out of the existential "trap", pulling the dynamic type of the value stored in the existential box out into a static type in the type system.

## Detailed design

Fundamentally, opening an existential means looking into the existential value, producing a unique "name" describing the type of the value that's within that existential, and then operating on that value directly. That "name" needs to be captured somewhere---whether in a generic parameter or an opaque type somewhere---or the opened existential value has to be erased again into another existential value.

This section describes the details of opening an existential and then type-erasing back to an existential. Most of these details of this change should be invisible to the user, and manifest only as the ability to use existentials with generics in places where the code would currently be rejected.

### When can we open an existential?

To open an existential, the argument (or source) must be of existential type (e.g., `any P`) or existential metatype (e.g., `any P.Type`) and must be provided to a parameter (or target) whose type involves a generic parameter that can bind directly to the underlying type of the existential. This means that, for example, we can open an existential when its underlying type would directly bind to a generic parameter:

```swift
protocol P {
  associatedtype A
  
  func getA() -> A
}

func openSimple<T: P>(_ value: T) { }

func testOpenSimple(p: any P) {
  openSimple(p) // okay, opens 'p' and binds 'T' to its underlying type
}
```

It's also possible to open an `inout` parameter. The generic function will operate on the underlying type, and can (e.g.) call `mutating` methods on it, but cannot change its *dynamic* type because it doesn't have access to the existential box:

```swift
func openInOut<T: P>?(_ value: inout T) { }
func testOpenInOut(p: any P) {
  var mutableP: any P = p
  openInOut(&mutableP) // okay, opens to 'mutableP' and binds 'T' to its underlying type
}
```

However, we cannot open when there might be more than one value of existential type or no values at all, because we need to be guaranteed to have a single underlying type to infer. Here are several such examples where the generic parameter is in a structural position:

```swift
func cannotOpen1<T: P>(_ array: [T]) { .. }
func cannotOpen2<T: P>(_ a: T, _ b: T) { ... }
func cannotOpen3<T: P>(_ values: T...) { ... }

struct X<T> { }
func cannotOpen4<T: P>(_ x: X<T>) { }

func cannotOpen5<T: P>(_ x: T, _ a: T.A) { }

func cannotOpen6<T: P>(_ x: T?) { }

func testCannotOpenMultiple(array: [any P], p1: any P, p2: any P, xp: X<any P>, pOpt: (any P)?) {
  cannotOpen1(array)         // each element in the array can have a different underlying type, so we cannot open
  cannotOpen2(p1, p2)        // p1 and p2 can have different underlying types, so there is no consistent binding for 'T'
  cannotOpen3(p1, p2)        // similar to the case above, p1 and p2 have different types, so we cannot open them
  cannotOpen4(xp)            // cannot open the existential in 'X<any P>' there isn't a specific value there.
  cannotOpen5(p1, p2.getA()) // cannot open either argument because 'T' is used in both parameters
  cannotOpen6(pOpt)         // cannot open the existential in '(any P)?' because it might be nil, so there would not be an underlying type
}
```

The case of optionals is somewhat interesting. It's clear that the call `cannotOpen6(pOpt)` cannot work because `pOpt` could be `nil`, in which case there is no type to bind `T` to. We *could* choose to allow opening a non-optional existential argument when the parameter is optional, e.g.,

```swift
cannotOpen6(p1) // we *could* open here, binding T to the underlying type of p1, but choose not to 
```

but this proposal doesn't allow this because it would be odd to allow this call but not the `cannotOpen6(pOpt)` call.

A value of existential metatype can also be opened, with the same limitations as above.

```swift
func openMeta<T: P>(_ type: T.Type) { }

func testOpenMeta(pType: any P.Type) {
  openMeta(pType) // okay, opens 'pType' and binds 'T' to its underlying type
}
```

### Type-erasing resulting values

The result type of a generic function can involve generic parameters and their associated types. For example, here's a generic function that returns the original value and some values of its associated types: 

```swift
protocol Q { 
  associatedtype B: P
  func getB() -> B
}

func decomposeQ<T: Q>(_ value: T) -> (T, T.B, T.B.A) {
  (value, value.getB(), value.getB().getA())
}
```

When calling `decomposeQ` with an existential value, the existential is opened and `T` will bind to its underlying type. `T.B` and `T.B.A` are types derived from that underlying type. Once the call completes, however, the types `T`, `T.B`, and `T.B.A` are *type-erased* to their upper bounds, i.e., the existential type that captures all of their requirements. For example:

```swift
func testDecomposeQ(q: any Q) {
  let (a, b, c) = decomposeQ(q) // a is any Q, b is any P, c is Any
}
```

This is identical to the [covariant erasure of associated types described in SE-0309](https://github.com/apple/swift-evolution/blob/main/proposals/0309-unlock-existential-types-for-all-protocols.md#covariant-erasure-for-associated-types), and the rules specified there apply equally here. We can restate those requirements more generally for an arbitrary generic parameter as:

When binding a generic parameter `T` to an opened existential, `T`, `T` and  `T`-rooted associated types that

- are **not** bound to a concrete type, and
- appear in covariant position within the result type of the generic function

will be type-erased to their upper bounds as per the generic signature of the existential that is used to access the member. The upper bounds can be either a class, protocol, protocol composition, or `Any`, depending on the *presence* and *kind* of generic constraints on the associated type. 

When `T` or a `T`-rooted associated type appears in a non-covariant position in the result type, `T` cannot be bound to the underlying type of an existential value because there would be no way to represent the type-erased result. This is essentially the same property as descibed for the parameter types that prevents opening of existentials, as described above. For example:

```swift
func cannotOpen7<T: P>(_ value: T) -> X<T> { /*...*/ }
```

However, because the return value is permitted a conversion to erase to an existential type, optionals, tuples, and even arrays *are* permitted:

```swift
func openWithCovariantReturn1<T: Q>(_ value: T) -> T.B? { /*...*/ }
func openWithCovariantReturn2<T: Q>(_ value: T) -> [T.B] { /*...*/ }

func covariantReturns(q: any Q){
  let r1 = openWithCovariantReturn1(q)  // okay, 'T' is bound to the underlying type of 'q', resulting type is 'any P'
  let r2 = openWithCovariantReturn2(q)  // okay, 'T' is bound to the underlying type of 'q', resulting type is '[any Q]'
}
```

## Source compatibility

This proposal has two effects on source compatibility. The first is that calls to generic functions that would previously have been ill-formed (e.g., they would fail because `any P` does not conform to `P`) but now become well-formed. For the most part, this makes ill-formed code well-formed, so it doesn't affect existing source code. As with any such change, it's possible that overload resolution that would have succeeded before will now pick a different function. For example:

```swift
protocol P { }

func overloaded1<T: P, U>(_: T, _: U) { } // A
func overloaded1<U>(_: Any, _: U) { }     // B

func changeInResolution(p: any P) {
  overloaded1(p) // used to choose B, will choose A with this proposal
}
```

The second effect on source compatibility involves generic calls that *do* succeed prior to this change by binding the generic parameter to the existential box. For example:

```swift
func acceptsBox<T>(_ value: T) { /* ... */ }

func passBox(p: any P) {
  acceptsBox(p) // currently infers 'T' to be 'any P'
                // with this proposal, infers 'T' to be the underlying type of 'p'
}
```

Given that `acceptsBox` cannot *do* very much with a value of type `T`, since there are no requirements on it, there aren't many ways in which the function could distinguish between the existential box and its underlying value. Adding any requirements on `T` to the generic function (e.g., `where T: P`) makes this code ill-formed prior to this proposal, because `any P` does not conform to `P`. There are some exceptions to this for *self-conforming protocols*, i.e., protocols for which "`any P` does conform to `P`". The only self-conforming protocols currently in Swift are `Error` (as introduced in [SE-0235](https://github.com/apple/swift-evolution/blob/main/proposals/0235-add-result.md#adding-swifterror-self-conformance)) and some `@objc` protocols.

For the cases where binding the generic parameter to the existential box currently succeeds, the semantics change in this proposal to bind to the underlying value is most likely a win: it eliminates an extra level of indirection, because the generic function can work directly on values of the underlying type (requires one level of indirection) rather than working with the box indirectly (requires two levels of indirection). Initial testing of this feature has found that code generally does not change in semantics when opening existentials. The only exception we've encountered is that the Swift standard library uses specific compiler builtins and runtime queries to establish when it is working directly with an existential box; code outside the standard library can't generally perform these queries so is unlikely to be affected.

## Effect on ABI stability

This proposal changes the type system but has no ABI impact whatsoever.

## Effect on API resilience

This proposal changes the use of APIs, but not the APIs themselves, so it doesn't impact API resilience per se.

## Alternatives considered

This proposal opts to open existentials implicitly and locally, type-erasing back to existentials after the immediate call, as a generalization of opening when using a member of an existential value. There are alternative designs that are explicit or open the existential more broadly, with different tradeoffs.

### Explicitly opening existentials

This proposal implicitly opens existentials at a call or when initializing a variable with opaque type. Instead, we could provide an explicit syntax for opening an existential, always requiring one to (e.g.) introduce a new name for the opened type. For example, we could choose to only allow initializing a variable with opaque type, so that code like the following (which is ill-formed today):

```swift
protocol P {
  associatedtype A
}

func takesP<T: P>(_ value: P) { }

func hasExistentialP(p: any P) {
  takesP(p) // error today ('any P' does not conform to 'P'), would be well-formed with implicit opening
}
```

could be written to explicitly open the existential, e.g.,

```swift
func hasExistentialP(p: any P) {
  let openedP: some P = p // allow opening only when creating a binding to 'some P'
  takesP(p)               // error today ('any P' does not conform to 'P'), would still be an error
  takesP(openedP)         // okay
}
```

Because this approach is more explicit than the proposed one, it has less impact on source compatibility: binding property of opaque type to an existential rarely succeeds (because `any P` almost never conforms to `P`). So, this approach is a more conservative one that the proposed approach that nonetheless still makes it possible to get out of the existential trap.

On the other hand, this narrower approach fails to take away the friction when moving from existentials to generics. A programmer who has an existential and wishes to use a generic function would need to learn about opaque result types and their differences with existentials to do so, which is instructive but may steepen the learning curve too early. 

### Value-dependent opening of existentials

Implicit opening in this proposal is always scoped to a particular binding of a specific generic parameter (`T`) and is erased thereafter. For example, this means that two invocations of the same generic function on the same existential value will return values of existential type that are not (statically) known to be equivalent:

```swift
func identity<T: Equatable>(_ value: T) -> T { value }
func testIdentity(p: any Equatable) {
  let p1 = identity(p)   // p1 gets type-erased type 'any Equatable'
  let p2 = identity(p)   // p2 gets type-erased type 'any Equatable'
  if p1 == p2 { ... }    // error: p1 and p2 aren't known to have the same concrete type
  
  let openedP1: some P = identity(p)   // openedP1 has an opaque type binding to the underlying type of the call
  let openedP2: some P = identity(p)   // openedP2 has an opaque type binding to the underlying type of the call
  if openedP1 == openedP2 { ... }      // error: openedP1 and openedP2 aren't known to have the same concrete type
}
```

One could imagine tying the identity of the opened existential type to the *value* of the existential. For example, the two calls to `identity(p)` could produce opaque types that are identical because they are based on the underlying type of the value `p`. This is a form of dependent typing, because the (static) types of some entities are determined by their values. It begins to break down if there is any way in which the value can change, e.g.,

```swift
func identityTricks(p: any Equatable) {
  let openedP1 = identity(p)      // openedP1 has the underlying type of 'p'
  let openedP2 = identity(p)      // openedP2 has the underlying type of 'p'
  if openedP1 == openedP2 { ... } // okay because both values have the underlying type of 'p'
  
  var q = p                          // q has the underlying type of 'p'
  let openedQ1: some P = identity(q) // openedQ1 has the underlying type of 'q' and therefore 'p'
  if openedP1 == openedQ1 { ... }    // okay because both values have the underlying type of 'p'


  if condition {
    q = 17   // different underlying type for 'q'
  }
  
  let openedQ2: some P = identity(q)
  if openedQ1 == openedQ2 { }  // error: openedQ1 has the underlying type of 'p', but
                               // openedQ2 has the underlying type of 'q', which now might be different from 'p'
}
```

This approach is much more complex because it introduces value tracking into the type system (where was this existential value produced?), at which point mutations to variables can affect the static types in the system. 

## Acknowledgments

This proposal builds on the difficult design work of [SE-0309](https://github.com/apple/swift-evolution/blob/main/proposals/0309-unlock-existential-types-for-all-protocols.md), which charted most of the detailed semantics for working with values of existential type and dealing with (e.g.) covariant erasure and the restrictions that must be placed on opening existentials. Moreover, the implementation work from one of SE-0309's authors, [Anthony Latsis](https://github.com/AnthonyLatsis), formed the foundation of the implementation work for this feature, requiring only a small amount of generalization.
