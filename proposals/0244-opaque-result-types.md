# Opaque Result Types

* Proposal: [SE-0244](0244-opaque-result-types.md)
* Authors: [Doug Gregor](https://github.com/DougGregor), [Joe Groff](https://github.com/jckarter)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Returned for revision**
* Implementation: [apple/swift#22072](https://github.com/apple/swift/pull/22072)
* Toolchain: https://github.com/apple/swift/pull/21137#issuecomment-468118328
* Review thread: https://forums.swift.org/t/se-0244-opaque-result-types/21252

## Introduction

This proposal introduces the ability to hide the specific result type of a function from its callers. The result type is described only by its capabilities, for example, to say that a function returns a `Collection` without specifying which specific collection. Clients can use the resulting values freely, but the underlying concrete type is known only to the implementation of the function and need not be spelled out explicitly.

Consider an operation like the following:

```swift
let resultValues = values.lazy.map(transform).filter { $0 != nil }.map { $0! }
```

If we want to encapsulate that code in another method, we're going to have to write out the type of that lazy-map-filter chain, which is rather ugly:

```swift
extension LazyMapCollection {
  public func compactMap<ElementOfResult>(
    _ transform: @escaping (Elements.Element) -> ElementOfResult?
  ) -> LazyMapSequence<LazyFilterSequence<LazyMapSequence<Elements, ElementOfResult?>>, ElementOfResult> {
    return self.map(transform).filter { $0 != nil }.map { $0! }
  }
}
```

The author of `compactMap(_:)` doesn't want to have to figure out that type, and the clients of `compactMap(_:)` don't want to have to reason about it. `compactMap(_:)` is the subject of [SE-0222](https://github.com/apple/swift-evolution/blob/master/proposals/0222-lazy-compactmap-sequence.md), which introduces a new standard library type `LazyCompactMapCollection` for the sole purpose of describing the result type of `compactMap(_:)`:

```swift
extension LazyMapCollection {
  public func compactMap<ElementOfResult>(
    _ transform: @escaping (Element) -> ElementOfResult?
  ) -> LazyCompactMapCollection<Base, ElementOfResult> {
    return LazyCompactMapCollection<Base, ElementOfResult>(/* ... */)
  }
}
```

This is less verbose, but requires the introduction of a new, public type solely to describe the result of this function, increasing the surface area of the standard library and requiring a nontrivial amount of implementation.

Other libraries may want to provide libraries of composable generic components in a similar manner.
A graphics library could provide primitives for shapes:

```swift
protocol Shape {
  func draw(to: Surface)

  func collides<Other: Shape>(with: Other) -> Bool
}

struct Rectangle: Shape { /* ... */ }
struct Circle: Shape { /* ... */ }
```

along with composable transformations to combine and modify primitive shapes:

```swift
struct Union<A: Shape, B: Shape>: Shape {
  var a: A, b: B
  // ...
}

struct Intersect<A: Shape, B: Shape>: Shape {
  var a: A, b: B
  // ...
}

struct Transformed<S: Shape>: Shape {
  var shape: S
  var transform: Matrix3x3
  // ...
}
```

One could compose these transformations by using the existential type `Shape` instead of generic arguments, but doing so would imply more dynamism and runtime overhead than may be desired. By composing generic containers, generic specialization can optimize together the composed operations like it does for `lazy` collections. A game or graphics app may want to define objects in terms of their shapes:

```swift
protocol GameObject {
  // The shape of the object
  associatedtype Shape: Shapes.Shape

  var shape: Shape { get }
}
```

However, this means that implementers of the `GameObject` protocol would now be burdened with writing out long, explicit types for their shapes:

```swift
struct EightPointedStar: GameObject {
  var shape: Union<Rectangle, Transformed<Rectangle>> {
    return Union(Rectangle(), Transformed(Rectangle(), by: .fortyFiveDegrees)
  }
}
```

Opaque result types allow the method to state the capabilities of its result type without tying it down to a concrete type. For example, the above could instead be written:

```swift
struct EightPointedStar: GameObject {
  var shape: some Shape {
    return Union(Rectangle(), Transformed(Rectangle(), by: .fortyFiveDegrees)
  }
}
```

to declare that an `EightPointedStar` has some `Shape` without having to specify exactly what shape that is. The underlying concrete type is hidden, and can even change from one version of the library to the next without breaking those clients, because the actual type identity was never exposed. This allows the library to provide a potentially-more-efficient design without expanding the surface area of the library or burdening implementors of the library's protocols with impractical type compositions.

Swift-evolution thread: [Opaque result types](https://forums.swift.org/t/opaque-result-types/15645)

## Proposed solution

This proposal introduces syntax that can be used to describe an opaque result type for a function. Instead of specifying a specific return type, a function can declare that it returns `some` type that satisfies a set of constraints, such as protocol requirements. This `some` specifier can only be used in the result type of a function, the type of a property, or the element type of a subscript declaration. The return type is backed by some specific concrete type, but that type is only known to the implementation of that function/property/subscript. Everywhere else, the type is opaque, and is described only by its characteristics and originating function/property/subscript. For example, a function can declare that it produces something that's a `MutableCollection` and `RangeReplaceableCollection`:

```swift
func makeMeACollection<T>(with element: T) -> some MutableCollection & RangeReplaceableCollection {
   return [element] // ok: an array of T satisfies all of the requirements
}
```

Following the `some` keyword is a class, protocol, `Any`, `AnyObject`, or composition thereof (joined with `&`). A caller to `makeMeACollection(_:)` can rely on the result type satisfying all of the requirements listed. For example:

```swift
var c = makeMeACollection(with: 17)
c.append(c.first!) // ok: it's a RangeReplaceableCollection
c[c.startIndex] = c.first! // ok: it's a MutableCollection
print(c.reversed()) // ok: all Collection/Sequence operations are available

func foo<C: Collection>(_ : C) { }
foo(c) // ok: C inferred to opaque result type of makeMeACollection()
```

Moreover, opaque result types to be used freely with other generics, e.g., forming a collection of the results:

```swift
var cc = [c]
cc.append(c) // ok: cc's Element == the result type of makeMeACollection
var c2 = makeMeACollection(with: 38)
cc.append(c2) // ok: Element == the result type of makeMeACollection
```

### Type identity

An opaque result type is not considered equivalent to its underlying type by the static type system:

```swift
var intArray = [Int]()
cc.append(intArray) // error: [Int] is not known to equal the result type of makeMeACollection
```

However, as with generic type parameters, one can inspect an opaque type's underlying type at runtime. For example, a conditional cast could determine whether the result of `makeMeACollection` is of a particular type:

```swift
if let arr = makeMeACollection(Int.self) as? [Int] {
  print("It's an [Int], \(arr)\n")
} else {
  print("Guessed wrong")
}
```

In other words, opaque result types are only opaque to the static type system. They don't exist at runtime.

### Implementing a function returning an opaque type

The implementation of a function returning an opaque type must return a value of the same concrete type `T` from each `return` statement, and `T` must meet all of the constraints stated on the opaque type. For example:

```swift
protocol P { }
extension Int : P { }
extension String : P { }

func f1() -> some P {
  return "opaque"
}

func f2(i: Int) -> some P { // ok: both returns produce Int
  if i > 10 { return i }
  return 0
}

func f2(flip: Bool) -> some P {
  if flip { return 17 }
  return "a string" // error: different return types Int and String
}

func f3() -> some P {
  return 3.1419 // error: Double does not conform to P
}

func f4() -> some P {
  let p: P = "hello"
  return p // error: protocol type P does not conform to P
}

func f5() -> some P {
  return f1() // ok: f1() returns an opaque type that conforms to P
}

protocol Initializable { init() }

func f6<T: P & Initializable>(_: T.Type) -> some P {
  return T() // ok: T will always be a concrete type conforming to P
}
```

These rules guarantee that there is a single concrete type produced by any call to the function. The concrete type can depend on the generic type arguments (as in the `f6()` example), but must be consistent across all `return` statements.

Note that recursive calls *are* allowed, and are known to produce a value of the same concrete type, but that the concrete type itself is not known:

```swift
func f7(_ i: Int) -> some P {
  if i == 0 {
    return f7(1) // ok: returning our own opaque result type
  } else if i < 0 {
    let result: Int = f7(-i) // error: opaque result type of f7() is not convertible to Int
    return result
  } else {
    return 0 // ok: grounds the recursion with a concrete type
  }
}
```

Of course, there must be at least one `return` statement that provides a concrete type.

Note that a function cannot call itself recursively in a way that forms a type parameterized on the function's own opaque result type, since this would mean that the opaque type is infinitely recursive:

```swift
struct Wrapper<T: P>: P { var value: T }

func f8(_ i: Int) -> some P {
   // invalid; this binds the opaque result type to Wrapper<return type of f8>,
   // which is Wrapper<Wrapper<return type of f8>>, which is
   // Wrapper<Wrapper<Wrapper<...>>>...
  return Wrapper(f8(i + 1))
}
```

A function with an opaque result type is also required to have a `return` statement even if it does not terminate:

```swift
func f9() -> some P {
  fatalError("not implemented")

  // error: no return statement to get opaque type
}
```

This requirement is necessary because, even though `f9`'s return value cannot be reached, the return type of `f9` can still be propagated by local type inference or generic instantiation in ways that don't require evaluating `f9`, so a type for `f9` must be available:

```swift
let delayedF9 = { f9() } // closure has type () -> return type of f9
```

We can't necessarily default the underlying type to `Never`, since `Never` may not
conform to the constraints of the opaque type. If `Never` does conform, and it
is desired as the underlying return type, that can be written explicitly as a
`return` statement:

```swift
extension Never: P {}
func f9b() -> some P {
  return fatalError("not implemented") // OK, explicitly binds return type to Never
}
```

### Properties and subscripts

Opaque result types can also be used with properties and subscripts:

```swift
struct GameObject {
  var shape: some Shape { /* ... */ }
}
```

For computed properties, the concrete type is determined by the `return` statements in the getter. Opaque result types can also be used in stored properties that have an initializer, in which case the concrete type is the type of the initializer:

```swift
let strings: some Collection = ["hello", "world"]
```

Properties and subscripts of opaque result type can be mutable. For example:

```swift
// Module A
public protocol P {
  mutating func flip()
}

private struct Witness: P {
  mutating func flip() { /* ... */ }
}

public var someP: some P = Witness()

// Module B
import A
someP.flip() // ok: flip is a mutating function called on a variable
```

With a subscript or a computed property, the type of the value provided to the setter (e.g., `newValue`) is determined by the `return` statements in the getter, so the type is consistent and known only to the implementation of the property or subscript. For example:

```swift
protocol P { }
private struct Impl: P { }

public struct Vendor {
  private var storage: [Impl] = [/* ... */]

  public var count: Int {
    return storage.count
  }

  public subscript(index: Int) -> some P {
    get {
      return storage[index]
    }
    set (newValue) {
      storage[index] = newValue
    }
  }
}

var vendor = Vendor()
vendor[0] = vendor[2] // ok: can move elements around
```

### Associated type inference
While one can use type inference to declare variables of the opaque result type of a function, there is no direct way to name the opaque result type:

```swift
func f1() -> some P { /* ... */ }

let vf1 = f1() // type of vf1 is the opaque result type of f1()
```

However, the type inference used to satisfy associated type requirements can deduce an opaque result type as the associated type of the protocol:

```swift
protocol GameObject {
  associatedtype ObjectShape: Shape

  var shape: ObjectShape
}

struct Player: GameObject {
  var shape: some Shape { /* ... */ }

  // infers typealias Shape = opaque result type of Player.shape
}

let pos: Player.ObjectShape // ok: names the opaque result type of S.someValue()
pos = Player().shape // ok: returns the same opaque result type
```

Note that having a name for the opaque result type still doesn't give information about the underlying concrete type. For example, the only way to create an instance of the type `S.SomeType` is by calling `S.someValue()`.

### Opaque result types vs. existentials

On the surface, opaque result types are quite similar to (generalized) existential types: in each case, the specific concrete type is unknown to the static type system, and can be manipulated only through the stated capabilities (e.g., protocol and superclass constraints). There are some similarities between the two features for code where the identity of the return type does not matter. For example:

```swift
protocol P
  func foo()
}

func anyP() -> P { /* ... */ }
func someP() -> some P { /* ... */ }

anyP().foo() // ok
someP().foo() // ok
```

However, the fundamental difference between opaque result types and existentials revolves around type identity. All instances of an opaque result type are guaranteed to have the same type at run time, whereas different instances of an existential type may have different types at run time. It is this aspect of existential types that makes their use so limited in Swift. For example, consider a function that takes two values of (existential) type `Equatable` and tries to compare them:

```swift
protocol Equatable {
  static func ==(lhs: Self, rhs: Self) -> Bool
}

func isEqual(_ x: Equatable, y: Equatable) -> Bool {
  return x == y
}
```

The `==` operator is meant to take two values of the same type and compare them. It's clear how that could work for a call like `isEqual(1, 2)`, because both `x` and `y` store values of type `Int`.

But what about a call `isEqual(1, "one")`? Both `Int` and `String` are `Equatable`, so the call to `isEqual` should be well-formed. However, how would the evaluation of `==` work? There is no operator `==` that works with an `Int` on the left and a `String` on the right, so it would fail at run-time with a type mismatch.

Swift rejects the example with the following diagnostic:

```
error: protocol 'Equatable' can only be used as a generic constraint because it has Self or associated type requirements
```

The generalized existentials proposal dedicates quite a bit of its design space to [ways to check whether two instances of existential type contain the same type at runtime](https://github.com/austinzheng/swift-evolution/blob/az-existentials/proposals/XXXX-enhanced-existentials.md#real-types-to-existentials-associated-types) to cope with this aspect of existential types. Generalized existentials can make it *possible* to cope with values of `Equatable` type, but it can't make it easy. The following is a correct implementation of `isEqual` using generalized existentials:

```swift
func isEqual(_ x: Equatable, y: Equatable) -> Bool {
  if let yAsX = y as? x.Self {
    return x == yAsX
  }

  if let xAsY = x as? y.Self {
    return xAsY == y
  }

  return false
}
```

Note that the user must explicitly cope with the potential for run-time type mismatches, because the Swift language will not implicitly defer type checking to run time.

Existentials also interact poorly with generics, because a value of existential type does not conform to its own protocol. For example:

```swift
protocol P { }

func acceptP<T: P>(_: T) { }
func provideP(_ p: P) {
  acceptP(p) // error: protocol type 'P' cannot conform to 'P' because only
             // concrete types can conform to protocols
}
```

[Hamish](https://stackoverflow.com/users/2976878/hamish) provides a [complete explanation on StackOverflow](https://stackoverflow.com/questions/33112559/protocol-doesnt-conform-to-itself) as to why an existential of type `P` does not conform to the protocol `P`. The following example from that answer demonstrates the point with an initializer requirement:

```swift
protocol P {
  init()
}

struct S: P {}
struct S1: P {}

extension Array where Element: P {
  mutating func appendNew() {
    // If Element is P, we cannot possibly construct a new instance of it, as you cannot
    // construct an instance of a protocol.
    append(Element())
  }
}

var arr: [P] = [S(), S1()]

// error: Using 'P' as a concrete type conforming to protocol 'P' is not supported
arr.appendNew()
```

Hamish notes that:

> We cannot possibly call `appendNew()` on a `[P]`, because `P` (the `Element`) is not a concrete type and therefore cannot be instantiated. It must be called on an array with concrete-typed elements, where that type conforms to `P`.

The major limitations that Swift places on existentials are, fundamentally, because different instances of existential type may have different types at run time. Generalized existentials can lift some restrictions (e.g., they can allow values of type `Equatable` or `Collection` to exist), but they cannot make the potential for run-time type conflicts disappear without weakening the type-safety guarantees provided by the language (e.g., `x == y` for `Equatable` `x` and `y` will still be an error) nor make existentials as powerful as concrete types (existentials still won't conform to their own protocols).

Opaque result types have none of these limitations, because an opaque result type is a name for some fixed-but-hidden concrete type. If a function returns `some Equatable` result type, one can compare the results of successive calls to the function with `==`:

```swift
func getEquatable() -> some Equatable {
  return Int.random(in: 0..<10)
}

let x = getEquatable()
let y = getEquatable()
if x == y { // ok: calls to getEquatable() always return values of the same type
  print("Bingo!")
}
```

Opaque result types *do* conform to the protocols they name, because opaque result types are another name for some concrete type that is guaranteed to conform to those protocols. For example:

```swift
func isEqualGeneric<T: Equatable>(_ lhs: T, _ rhs: T) -> Bool {
  return lhs == rhs
}

let x = getEquatable()
let y = getEquatable()
if isEqual(x, y) { // ok: the opaque result of getEquatable() conforms to Equatable
  print("Bingo!")
}
```

(Generalized) existentials are well-suited for use in heterogeneous collections, or other places where one expects the run-time types of values to vary and there is little need to compare two different values of existential type. However, they don't fit the use cases outlined for opaque result types, which require the types that result from calls to compose well with generics and provide the same capabilities as a concrete type.

## Detailed design

### Grammar of opaque result types

The grammatical production for opaque result types is straightforward:

```
type ::= opaque-type

opaque-type ::= 'some' type
```

The `type` following the `'some'` keyword is semantically restricted to be a class or existential type, meaning it must consist only of `Any`, `AnyObject`, protocols, or base classes, possibly composed using `&`.

### Restrictions on opaque result types

Opaque result types can only be used as the result type of a function, the type of a variable, or the result type of a subscript. The opaque type must be the entire return type of the function, For example, one cannot return an optional opaque result type:

```swift
func f(flip: Bool) -> (some P)? { // error: `some P` is not the entire return type
  // ...
}
```

Opaque result types cannot be used in the requirements of a protocol:

```swift
protocol Q {
  func f() -> some P // error: cannot use opaque result type within a protocol
}
```

Associated types provide a better way to model the same problem, and the requirements can then be satisfied by a function that produces an opaque result type.

Similarly to the restriction on protocols, opaque result types cannot be used for a non-`final` declaration within a class:

```swift
class C {
  func f() -> some P { /* ... */ } // error: cannot use opaque result type with a non-final method
  final func g() -> some P { /* ... */ } // ok
}
```

### Uniqueness of opaque result types

Opaque result types are uniqued based on the function/property/subscript and any generic type arguments. For example:

```swift
func makeOpaque<T>(_: T.Type) -> some Any { /* ... */ }
var x = makeOpaque(Int.self)
x = makeOpaque(Double.self) // error: "opaque" type from makeOpaque<Double> is distinct from makeOpaque<Int>
```

This includes any generic type arguments from outer contexts, e.g.,

```swift
extension Array where Element: Comparable {
  func opaqueSorted() -> some Sequence { /* ... */ }
}

var x = [1, 2, 3]. opaqueSorted()
x = ["a", "b", "c"].opaqueSorted() // error: opaque result types for [Int].opaqueSorted() and [String].opaqueSorted() differ
```

### Implementation strategy

From an implementation standpoint, a client of a function with an opaque result type needs to treat values of that result type like any other resilient value type: its size, alignment, layout, and operations are unknown.

However, when the body of the function is known to the client (e.g., due to inlining or because the client is in the same compilation unit as the function), the compiler's optimizer will have access to the specific concrete type, eliminating the indirection cost of the opaque result type.

## Source compatibility

Opaque result types are purely additive. They can be used as a tool to improve long-term source (and binary) stability, by not exposing the details of a result type to clients.

If opaque result types are retroactively adopted in a library, it would initially break source compatibility (e.g., if types like `EnumeratedSequence`, `FlattenSequence`, and `JoinedSequence` were removed from the public API) but could provide longer-term benefits for both source and ABI stability because fewer details would be exposed to clients. There are some mitigations for source compatibility, e.g., a longer deprecation cycle for the types or overloading the old signature (that returns the named types) with the new signature (that returns an opaque result type).

## Effect on ABI stability

Opaque result types are an ABI-additive feature, so do not in and of themselves impact existing ABI. However, additional runtime support is however needed to support instantiating opaque result types across ABI boundaries, meaning that *a Swift 5.1 runtime will be required to deploy code that uses opaque types in public API*. Also, changing an existing API to make use of opaque result types instead of returning concrete types would be an ABI-breaking change, so one of the source compatibility mitigations mentioned above would also need to be deployed to maintain ABI compatibility with existing binary clients.

## Effect on API resilience

Opaque result types are part of the result type of a function/type of a variable/element type of a subscript. The requirements that describe the opaque result type cannot change without breaking the API/ABI. However, the underlying concrete type *can* change from one version to the next without breaking ABI, because that type is not known to clients of the API.

One notable exception to the above rule is `@inlinable`: an `@inlinable` declaration with an opaque result type requires that the underlying concrete type be `public` or `@usableFromInline`. Moreover, the underlying concrete type *cannot be changed* without breaking backward compatibility, because it's identity has been exposed by inlining the body of the function. That makes opaque result types somewhat less compelling for the `compactMap` example presented in the introduction, because one cannot have `compactMap` be marked `@inlinable` with an opaque result type, and then later change the underlying concrete type to something more efficient.

We could allow an API originally specified using an opaque result type to later evolve to specify the specific result type. The result type itself would have to become visible to clients, and this might affect source compatibility, but (mangled name aside) such a change would be resilient.

## Rust's `impl Trait`

The proposed Swift feature is largely based on Rust's `impl Trait` language feature, described by [Rust RFC 1522](https://github.com/rust-lang/rfcs/blob/master/text/1522-conservative-impl-trait.md) and extended by [Rust RFC 1951](https://github.com/rust-lang/rfcs/blob/master/text/1951-expand-impl-trait.md). There are only a small number of differences between this feature as expressed in Swift vs. Rust's `impl Trait` as described in RFC 1522:

* Swift's need for a stable ABI necessitates translation of opaque result types as resilient types, which is unnecessary in Rust's model, where the concrete type can always be used for code generation.
* Swift's opaque result types are fully opaque, because Swift doesn't have pass-through protocols like Rust's `Send` trait, which simplifies the type checking problem slightly.
* Due to associated type inference, Swift already has a way to "name" an opaque result type in some cases.

## Alternatives considered

The main design question here is the keyword to use to introduce an opaque
return type. This proposal suggests the word `some`, since it has the right connotation by analogy to `Any` which is used to describe dynamically type-erased containers (and has been proposed to be a general way of referring to existential types)--a function that has an opaque return type returns *some* specific type
that conforms to the given constraints, whereas an existential can contain *any* type dynamically at any point in time. There are nonetheless reasonable objections to this keyword:

- `some` is already used in the language as one of the case names for `Optional`; it is rare to need to spell `Optional.some` or `.some` explicitly, but it could nonetheless introduce confusion.
- In spoken language, `some type` and `sum type` sound the same.
- `swift some` could be a difficult term to search for. (However, on Google it currently gives [reasonable results](https://www.google.com/search?client=safari&rls=en&q=swift+some&ie=UTF-8&oe=UTF-8) about Optional in Swift.)

Another obvious candidate is `opaque`, following the title of this very proposal. The word "opaque" is itself an overloaded term with existing meaning in many domains, which is unfortunate:

```swift
protocol Shape {}

func translucentRectangle() -> opaque Shape { /* ... */ }
```

The term "opaque" is also fairly heavily overloaded in the Swift implementation (albeit not so much the source-level programming model). It may be that there is a better term, such as "abstract return types", to refer to this feature in its entirety.

## Future Directions

### Opaque types in structural position

This proposal only allows for the entire return type of a declaration to be
made opaque. It would be reasonable to eventually generalize this to allow
for opaque types to appear structurally, as part of an optional, array, or
other generic type:

```
func collection(or not: Bool) -> (some Collection)? {
  if not { return nil }
  return [1, 2, 3]
}
```

Furthermore, there could conceivably be multiple opaque parts of a compound
return type:

```
func twoCollections() -> (some Collection, some Collection) {
  return ([1, 2, 3], ["one": 1, "two": 2, "three": 3])
}
```

### `where` constraints on associated types of opaque types

This proposal does not yet provide a syntax for specifying constraints on
associated types implied by an opaque type's protocol constraints. This is important for the feature to be useful with many standard library protocols such as `Collection`, since nearly every use case where someone wants to return `some Collection` would also want to specify the type of the `Element`s in that collection. The design of this feature is itself a fairly involved implementation effort and language design discussion, so it makes sense to split it out as a separate proposal. Normally in
Swift these constraints are expressed in `where` clauses; however, this is
not directly possible for opaque types because there is no way to name the
underlying type. This is similar to the spelling problem for [generalized existentials](https://github.com/austinzheng/swift-evolution/blob/az-existentials/proposals/XXXX-enhanced-existentials.md), and we'd want to find a syntax solution that works well for both. Possibilities include:

- Allowing a placeholder like `_` to refer to the unnamed opaque type in the where clause:

    ```swift
    func foo() -> some Collection where _.Element == Int { ... }
    ```

    Possible issues with this approach include:

    - The specification for the opaque type is no longer syntactically self-contained, being spread between the return type of the function and the `where` constraints, which is an implementation and readability challenge.
    - This overloads the `_` token, something Swift has thus far managed to avoid for the most part (and a common complaint about Scala in particular).
    - This only scales to one opaque/existential type. Future extensions of opaque result types could conceivably allow multiple opaque types to be in a declaration.

- Adding a shorthand similar to Rust's `Trait<AssocType = T>` syntax to allow associated constraints to be spelled together with the core protocol type. With opaque types, this could look something like this:

    ```swift
    // same type constraint
    func foo() -> some Collection<.Element == Int> { ... }
    // associated type protocol constraint
    func foo() -> some Collection<.Element: SignedInteger> { ... }
    ```

    This could be a generally useful shorthand syntax for declaring a protocol constraint with associated type constraints, usable in `where` clauses, `some` clauses, and generalized existentials, at the risk of complicating the grammar and introducing More Than One Way To Do It for writing generic constraints.

### Conditional conformances

When a generic function returns an adapter type, it's not uncommon for the adapter to use [conditional conformances](https://github.com/apple/swift-evolution/blob/master/proposals/0143-conditional-conformances.md) to reflect the capabilities of its underlying type parameters. For example, consider the `reversed()` operation:

```swift
extension BidirectionalCollection {
  public func reversed() -> ReversedCollection<Self> {
    return ReversedCollection<Self>(...)
  }
}
```

`ReversedCollection` is always a `BidirectionalCollection`, with a conditional conformance to `RandomAccessCollection`:

```swift
public struct ReversedCollection<C: BidirectionalCollection>: BidirectionalCollection {
  // ...
}

extension ReversedCollection: RandomAccessCollection where C: RandomAccessCollection {
  // ...
}
```

What happens if we hid the `ReversedCollection` adapter type behind an opaque result type?

```swift
extension BidirectionalCollection {
  public func reversed() -> some BidirectionalCollection<.Element == Element> {
    return ReversedCollection<Self>(/* ... */)
  }
}
```

Now, clients that call `reversed()` on a `RandomAccessCollection` would get back something that is only known to be a `BidirectionalCollection`, and there would be no way to treat it as a `RandomAccessCollection`. The library could provide another overload of `reversed()`:

```swift
extension RandomAccessCollection {
  public func reversed() -> some RandomAccessCollection<.Element == Element> {
    return ReversedCollection<Self>(/* ... */)
  }
}
```

However, doing so is messy, and the client would have no way to know that the type returned by the two `reversed()` functions are, in fact, the same. To express the conditional conformance behavior, we could eventually extend the syntax of opaque result types to describe additional capabilities of the resulting type that depend on extended requirements. For example, we could state that the result of `reversed()` is *also* a `RandomAccessCollection` when `Self` is a `RandomAccessCollection`. One possible syntax:

```swift
extension BidirectionalCollection {
  public func reversed()
    -> some BidirectionalCollection<.Element == Element>
    -> some RandomAccessCollection where Self: RandomAccessCollection
  {
    return ReversedCollection<Self>(/* ... */)
  }
}
```

Here, we add a second return type and `where` clause that states additional information about the opaque result type (it is a `RandomAccessCollection`) as well as the requirements under which that capability is available (the `where Self: RandomAccessCollection`). One could have many conditional clauses, e.g.,

```swift
extension BidirectionalCollection {
  public func reversed()
    -> some BidirectionalCollection<.Element == Element>
    -> some RandomAccessCollection where Self: RandomAccessCollection
    -> some MutableCollection where Self: MutableCollection
  {
    return ReversedCollection<Self>(/* ... */)
  }
}
```

Here, the opaque result type conforms to `MutableCollection` when the `Self` type conforms to `MutableCollection`. This conditional result is independent of whether the opaque result type conforms to `RandomAccessCollection`.

Note that Rust [didn't tackle the issue of conditional constraints](https://github.com/rust-lang/rfcs/blob/master/text/1522-conservative-impl-trait.md#compatibility-with-conditional-trait-bounds) in their initial design of `impl Trait` types.

### Opaque type aliases

Opaque result types are tied to a specific declaration. They offer no way to state that two related APIs with opaque result types produce the *same* underlying concrete type. For example, the `LazyCompactMapCollection` type proposed in [SE-0222](https://github.com/apple/swift-evolution/blob/master/proposals/0222-lazy-compactmap-sequence.md) is used to describe four different-but-related APIs: lazy `compactMap`, `filter`, and `map` on various types.

Opaque type aliases would allow us to provide a named type with stated capabilities, for which the underlying implementation type is still hidden from the API and ABI of clients like an opaque result type. For example:

```swift
public typealias LazyCompactMapCollection<Elements, ElementOfResult>
  : some Collection<.Element == ElementOfResult>
  = LazyMapSequence<LazyFilterSequence<LazyMapSequence<Elements, ElementOfResult?>>, ElementOfResult>
```

In this strawman syntax, the opaque result type following the `:` is how clients see `LazyCompactMapCollection`. The underlying concrete type, spelled after the `=`, is visible only to the implementation (see below for more details).

With this feature, multiple APIs could be described as returning a `LazyCompactMapCollection`:

```swift
extension LazyMapCollection {
  public func compactMap<U>(_ transform: @escaping (Element) -> U?) -> LazyCompactMapCollection<Base, U> {
    // ...
 }

  public func filter(_ isIncluded: @escaping (Element) -> Bool) -> LazyCompactMapCollection<Base, Element> {
    // ...
  }
}
```

From the client perspective, both APIs would return the same type, but the specific underlying type would not be known.

```swift
var compactMapOp = values.lazy.map(f).compactMap(g)
if Bool.random() {
  compactMapOp = values.lazy.map(f).filter(h)  // ok: both APIs have the same type
}
```

The underlying concrete type of an opaque type alias would have restricted visibility, its access being the more restrictive of the access level below the type alias's access (e.g., `internal` for a `public` opaque type alias, `private` for an `internal` opaque type alias) and the access levels of any type mentioned in the underlying concrete type. For the opaque type alias `LazyCompactMapCollection` above, this would be the most restrictive of `internal` (one level below `public`) and the types involved in the underlying type (`LazyMapSequence`, `LazyFilterSequence`), all of which are public. Therefore, the access of the underlying concrete type is `internal`.

If, instead, the concrete underlying type of `LazyCompactMapCollection` involved a private type, e.g.,

```swift
private struct LazyCompactMapCollectionImpl<Elements: Collection, ElementOfResult> {
  // ...
}

public typealias LazyCompactMapCollection<Elements, ElementOfResult>
  : some Collection<.Element == ElementOfResult>
  = LazyCompactMapCollectionImpl<Elements, ElementOfResult>
```

then the access of the underlying concrete type would be `private`.

The access of the underlying concrete type only affects the type checking of function bodies. If the function body has access to the underlying concrete type, then the opaque typealias and its underlying concrete type are considered to be equivalent. Extending the example above:

```swift
extension LazyMapCollection {
  public func compactMap<U>(_ transform: @escaping (Element) -> U?) -> LazyCompactMapCollection<Base, U> {
    // ok so long as we are in the same file as the opaque type alias LazyCompactMapCollection,
    // because LazyCompactMapCollectionImpl<Base, U> and
    // LazyCompactMapCollection<Base, U> are known to be identical
    return LazyCompactMapCollectionImpl<Base, U>(elements, transform)
  }
}
```

Opaque type aliases might also offer an alternative solution to the issue with conditional conformance. Instead of annotating the `opaque` result type with all of the possible conditional conformances, we can change `reversed()` to return an opaque type alias `Reversed`, giving us a name for the resulting type:

```swift
public typealias Reversed<Base: BidirectionalCollection>
  : some BidirectionalCollection<.Element == Base.Element>
  = ReversedCollection<Base>
```

Then, we can describe conditional conformances on `Reversed`:

```swift
extension Reversed: RandomAccessCollection where Element == Base.Element { }
```

The conditional conformance must be satisfied by the underlying concrete type (here, `ReversedCollection`), and the extension must be empty: `Reversed` would be the same as `ReversedCollection` at runtime, so one could not add any API to `Reversed` beyond what `ReversedCollection` supports.

### Opaque argument types

The idea of opaque result types could be analogized to argument types, as an alternative shorthand to writing simple generic functions without explicit type arguments. [Rust RFC 1951](https://github.com/rust-lang/rfcs/blob/master/text/1951-expand-impl-trait.md) makes the argument for extending `impl Trait` to arguments in Rust. In Swift, this would mean that:

```swift
func foo(x: some P) { /* ... */ }
```

would be sugar for:

```swift
func foo<T: P>(x: T) { /* ... */ }
```

And a more involved example like this:

```swift
func concatenate<C: Collection, D: Collection>(
  _ x: C,
  _ y: D
) -> some Collection<.Element == C.Element> where C.Element == D.Element {
  return LazyConcat(x, y)
}
```

could be simplified to:

```swift
func concatenate<E>(
  _ x: some Collection<.Element == E>,
  _ y: some Collection<.Element == E>
) -> some Collection<.Element == E> {
  return LazyConcat(x, y)
}
```

Unlike opaque return types, this doesn't add any additional expressivity to the language, but it can make the declarations of many generic functions look simpler and more streamlined, reducing the "angle bracket blindness" caused by the syntactic overhead and indirection that traditional generic argument declaration syntax imposes.
