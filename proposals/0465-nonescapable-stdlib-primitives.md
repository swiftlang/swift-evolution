# Standard Library Primitives for Nonescapable Types

* Proposal: [SE-0465](0465-nonescapable-stdlib-primitives.md)
* Authors: [Karoy Lorentey](https://github.com/lorentey)
* Review Manager: [Doug Gregor](https://github.com/douggregor)
* Status: **Accepted**
* Roadmap: [Improving Swift performance predictability: ARC improvements and ownership control][Roadmap]
* Implementation: https://github.com/swiftlang/swift/pull/73258
* Review: ([Review](https://forums.swift.org/t/se-0465-standard-library-primitives-for-nonescapable-types/78310)) ([Pitch](https://forums.swift.org/t/pitch-nonescapable-standard-library-primitives/77253))

[Roadmap]: https://forums.swift.org/t/a-roadmap-for-improving-swift-performance-predictability-arc-improvements-and-ownership-control/54206
[Pitch]: https://forums.swift.org/t/pitch-nonescapable-standard-library-primitives/77253

<small>

Related proposals:

- [SE-0377] `borrowing` and `consuming` parameter ownership modifiers
- [SE-0390] Noncopyable structs and enums
- [SE-0426] `BitwiseCopyable`
- [SE-0427] Noncopyable generics
- [SE-0429] Partial consumption of noncopyable values
- [SE-0432] Borrowing and consuming pattern matching for noncopyable types
- [SE-0437] Noncopyable Standard Library Primitives
- [SE-0446] Nonescapable Types
- [SE-0447] `Span`: Safe Access to Contiguous Storage
- [SE-0452] Integer Generic Parameters
- [SE-0453] `InlineArray`, a fixed-size array
- [SE-0456] Add `Span`-providing Properties to Standard Library Types

</small>

[SE-0370]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0370-pointer-family-initialization-improvements.md
[SE-0377]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0377-parameter-ownership-modifiers.md
[SE-0390]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md
[SE-0426]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0426-bitwise-copyable.md
[SE-0427]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md
[SE-0429]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0429-partial-consumption.md
[SE-0432]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0432-noncopyable-switch.md
[SE-0437]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0437-noncopyable-stdlib-primitives.md
[SE-0446]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md
[SE-0447]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md
[SE-0452]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0452-integer-generic-parameters.md
[SE-0453]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md
[SE-0456]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-stdlib-span-properties.md

### Table of Contents

  * [Introduction](#introduction)
  * [Motivation](#motivation)
  * [Proposed Solution](#proposed-solution)
    * [Nonescapable optionals](#nonescapable-optionals)
    * [Nonescapable Result](#nonescapable-result)
    * [Retrieving the memory layout of nonescapable types](#retrieving-the-memory-layout-of-nonescapable-types)
    * [Lifetime management](#lifetime-management)
    * [Metatype comparisons](#metatype-comparisons)
    * [Object identifiers](#object-identifiers)
    * [Odds and ends](#odds-and-ends)
  * [Detailed Design](#detailed-design)
    * [Inferred lifetime behavior of nonescapable enum types](#inferred-lifetime-behavior-of-nonescapable-enum-types)
    * [Inferred lifetime behavior of Optional's notational conveniences](#inferred-lifetime-behavior-of-optionals-notational-conveniences)
    * [protocol ExpressibleByNilLiteral](#protocol-expressiblebynilliteral)
    * [enum Optional](#enum-optional)
    * [enum Result](#enum-result)
    * [enum MemoryLayout](#enum-memorylayout)
    * [Lifetime Management](#lifetime-management-1)
    * [Metatype equality](#metatype-equality)
    * [struct ObjectIdentifier](#struct-objectidentifier)
    * [ManagedBufferPointer equatability](#managedbufferpointer-equatability)
    * [Making indices universally available on unsafe buffer pointers](#making-indices-universally-available-on-unsafe-buffer-pointers)
    * [Buffer pointer operations on Slice](#buffer-pointer-operations-on-slice)
  * [Source compatibility](#source-compatibility)
  * [ABI compatibility](#abi-compatibility)
    * [Note on protocol generalizations](#note-on-protocol-generalizations)
  * [Alternatives Considered](#alternatives-considered)
  * [Future Work](#future-work)
  * [Acknowledgements](#acknowledgements)

## Introduction

This document proposes to allow `Optional` and `Result` to hold instances of nonescapable types, and continues the work of adding support for noncopyable and nonescapable types throughout the Swift Standard Library.


## Motivation

[SE-0437] started integrating noncopyable types into our Standard Library abstractions, by generalizing existing APIs and introducing new ones. In the time since that proposal, [SE-0446] has introduced nonescapable types to Swift, adding a new direction of generalization.

This proposal continues the work of [SE-0437] by extending some basic constructs to support nonescapable types, where it is already possible to do so. For now, we are focusing on further generalizing a subset of the constructs covered by [SE-0437]: `MemoryLayout`, `Optional`, and `Result` types. Our immediate aim is to unblock the use of nonescapable types, especially in API surfaces. We also smooth out some minor inconsistencies that [SE-0437] has left unresolved.

Like before, our aim is to implement these generalizations with as little disruption as possible. Existing code implicitly assumes copyability and escapability, and it needs to continue working as before.

## Proposed Solution

This proposal is focusing on achieving the following results:

- Allow `Optional` to wrap nonescapable types, itself becoming conditionally escapable.
- Do the same for `Result`, allowing its success case to hold a nonescapable item.
- Generalize `MemoryLayout` to allow querying basic information on the memory layout of nonescapable types.
- Continue generalizing basic lifetime management functions; introduce a new `extendLifetime()` function that avoids a closure argument.
- Allow generating `ObjectIdentifier` instances for noncopyable and/or nonescapable metatypes.
- Allow comparing noncopyable and nonescapable metatypes for equality.

We also propose to fix a handful of minor copyability-related omissions that have been discovered since [SE-0437] was accepted:

- Allow `ManagedBufferPointer` instances to be equatable even when `Element` is noncopyable.
- Make the `Unsafe[Mutable]BufferPointer.indices` property universally available for all `Element` types.
- Generalize select operations on unsafe buffer pointer slices, to restore consistency with the same operations on the buffer pointers themselves.

### Nonescapable optionals

We want `Optional` to support wrapping all Swift types, whether or not they're copyable or escapable. This means that `Optional` needs to become conditionally escapable, depending on the escapability of its `Wrapped` type. 

`Optional` must itself become nonescapable when it is wrapping a nonescapable type, and such optional values need to be subject to precisely the same lifetime constraints as their wrapped item: we cannot allow the act of wrapping a nonescapable value in an optional to allow that value to escape its intended context.

There are many ways to construct optional values in Swift: for example, we can explicitly invoke the factory for the `.some` case, we can rely on Swift's implicit optional promotion rules, or we can invoke the default initializer. We propose to generalize all of these basic/primitive mechanisms to support nonescapable use. For instance, given a non-optional `Span` value, this code exercises these three basic ways of constructing non-nil nonescapable optionals:

```swift
func sample(_ span: Span<Int>) {
  let a = Optional.some(span) // OK, explicit case factory
  let b: Optional = span      // OK, implicit optional promotion
  let c = Optional(span)      // OK, explicit initializer invocation
}
```

`a`, `b`, and `c` hold the same span instance, and their lifetimes are subject to the same constraints as the original span -- they can be used within the context of the `sample` function, but they cannot escape outside of it. (At least not without explicit lifetime dependency annotations, to be introduced in the future.)

Of course, it also needs to be possible to make empty `Optional` values that do not hold anything. We have three basic ways to do that: we can explicitly invoke the factory for the `none` case, we can reach for the special `nil` literal, or (for `var`s) we can rely on implicit optional initialization. This proposal generalizes all three mechanisms to support noncopyable wrapped types:

```swift
func sample(_ span: Span<Int>) {
  var d: Span<Int>? = .none // OK, explicit factory invocation
  var e: Span<Int>? = nil   // OK, nil literal expression
  var f: Span<Int>?         // OK, implicit nil default value
}
```

Empty optionals of nonescapable types are still technically nonescapable, but they aren't inherently constrained to any particular context -- empty optionals are born with "immortal" (or "static") lifetimes, i.e., they have no lifetime dependencies, and so they are allowed to stay around for the entire execution of a Swift program. Nil optionals can be passed to any operation that takes a nonescapable optional, no matter what expectations it may dictate about its lifetime dependencies; they can also be returned from any function that returns a nonescapable optional. (Note though that Swift does not yet provide a stable way to define such functions.)

Of course, we also expect to be able to reassign variables, rebinding them to a new value. Reassignments of local variables are allowed to arbitrarily change lifetime dependencies. There is no expectation that the lifetime dependencies of the new value have any particular relation to the old: local variable reassignments can freely "narrow" or "widen" dependencies, as they see fit.

For instance, the code below initializes an optional variable to an immortal nil value; it then assigns it a new value that has definite lifetime constraints; and finally it turns it back to an immortal nil value:

```swift
func sample(_ span: Span<Int>) {
  var maybe: Span<Int>? = nil // immortal
  maybe = span                // definite lifetime
  maybe = nil                 // immortal again
}
```

(Assigning `span` to `maybe` is not an escape, as the local variable will be destroyed before the function returns, even without the subsequent reassignment.)

This flexibility will not necessarily apply to other kinds of variables, like stored properties in custom nonescapable structs, global variables, or computed properties -- I expect those variables to carry specific lifetime dependencies that cannot vary through reassignment. (For example, a global variable of a nonescapable type may be required to hold immortal values only.) However, for now, we're limiting our reasoning to local variables.

Of course, an optional is of limited use unless we are able to decide whether it contains a value, and (if so) to unwrap it and look at its contents. We need to be able to operate on nonescapable optionals using the familiar basic mechanisms:

 - `switch` and `if case`/`guard case` statements that pattern match over them:

   ```swift
   // Variant 1: Full pattern matching
   func count(of maybeSpan: Span<Int>?) -> Int {
     switch maybeSpan {
       case .none: return 0
       case .some(let span): return span.count
     }
   }
   
   // Variant 2: Pattern matching with optional sugar
   func count(of maybeSpan: Span<Int>?) -> Int {
     switch maybeSpan {
       case nil: return 0
       case let span?: return span.count
     }
   }
   ```

 - The force-unwrapping `!` special form, and its unsafe cousin, the Standard Library's `unsafelyUnwrapped` property.

   ```swift
   func count(of maybeSpan: Span<Int>?) -> Int {
     if case .none = maybeSpan { return 0 }
     return maybeSpan!.count
   }
   ```
   
- The optional chaining special form `?`:

   ```swift
   func count(of maybeSpan: Span<Int>?) -> Int {
     guard let c = maybeSpan?.count else { return 0 }
     return c
   }
   ```

- Optional bindings such as `if let` or `guard let` statements:

   ```swift
   func count(of maybeSpan: Span<Int>?) -> Int {
     guard let span = maybeSpan else { return 0 }
     return span.count
   }
   ```

These variants all work as expected. To avoid escapability violations, unwrapping the nonescapable optional results in a value with precisely the same lifetime dependencies as the original optional value. This applies to all forms of unwrapping, including pattern matching forms that bind copies of associated values to new variables, like `let span` above -- the resulting `span` value always has the same lifetime as the optional it comes from.

The standard `Optional` type has custom support for comparing optional instances against `nil` using the traditional `==` operator, whether or not the wrapped type conforms to `Equatable`. [SE-0437] generalized this mechanism for noncopyable wrapped types, and it is reasonable to extend this to also cover the nonescapable case:

```swift
func count(of maybeSpan: Span<Int>?) -> Int {
  if maybeSpan == nil { return 0 } // OK!
  return maybeSpan!.count
}
```

This core set of functionality makes nonescapable optionals usable, but it does not yet enable the use of more advanced APIs. Eventually, we'd also like to use the standard `Optional.map` function (and similar higher-order functions) to operate on (or to return) nonescapable optional types, as in the example below:

```swift
func sample(_ maybeArray: Array<Int>?) {
  // Assuming `Array.storage` returns a nonescapable `Span`:
  let maybeSpan = maybeArray.map { $0.storage }
  ...
}
```

These operations require precise reasoning about lifetime dependencies though, so they have to wait until we have a stable way to express lifetime annotations on their definitions. We expect lifetime semantics to become an integral part of the signatures of functions dealing with nonescapable entities -- for the simplest cases they can often remain implicit, but for something like `map` above, we'll need to explicitly describe how the lifetime of the function's result relates to the lifetime of the result of the function argument. We need to defer this work until we have the means to express such annotations in the language.

One related omission from the list of generalizations above is the standard nil-coalescing operator `??`. This is currently defined as follows (along with another variant that returns an `Optional`):

```swift
func ?? <T: ~Copyable>(
  optional: consuming T?,
  defaultValue: @autoclosure () throws -> T
) rethrows -> T
```

To generalize this to also allow nonescapable `T` types, we'll need to specify that the returned value's lifetime is tied to the _intersection_ of the lifetime of the left argument and the lifetime of the result of the right argument (a function). We aren't currently able to express that, so this generalization has to be deferred as well until the advent of such a language feature.

### Nonescapable `Result`

We generalize `Result` along the same lines as `Optional`, allowing its `success` case to wrap a nonescapable value. For now, we need to mostly rely on Swift's general enum facilities to operate on nonescapable `Result` values: switch statements, case factories, pattern matching, associated value bindings etc.

Important convenience APIs such as `Result.init(catching:)` or `Result.map` will need to require escapability until we introduce a way to formally specify lifetime dependencies. This is unfortunate, but it still enables intrepid Swift developers to experiment with defining interfaces that take (or perhaps even return!) `Result` values.

However, we are already able to generalize a couple of methods: `get` and the error-mapping utility `mapError`.

```swift
func sample<E: Error>(_ res: Result<Span<Int>, E>) -> Int {
  guard let span = try? res.get() else { return 42 }
  return 3 * span.count + 9
}
```

Like unwrapping an `Optional`, calling `get()` on a nonescapable `Result` returns a value whose lifetime requirements exactly match that of the original `Result` instance -- the act of unwrapping a result cannot allow its content to escape its intended context.

### Retrieving the memory layout of nonescapable types

This proposal generalizes `enum MemoryLayout` to support retrieving information about the layout of nonescapable types:

```swift
print(MemoryLayout<Span<Int>>.size) // ⟹ 16
print(MemoryLayout<Span<Int>>.stride) // ⟹ 16
print(MemoryLayout<Span<Int>>.alignment) // ⟹ 8
```

(Of course, the values returned will vary depending on the target architecture.)

The information returned is going to be of somewhat limited use until we generalize unsafe pointer types to support nonescapable pointees, which this proposal does not include -- but there is no reason to delay this work until then.

To usefully allow pointers to nonescapable types, we'll need to assign precise lifetime semantics to their `pointee` (and pointer dereferencing in general), and we'll most likely also need a way to allow developers to unsafely override the resulting default lifetime semantics. This requires explicit lifetime annotations, and as such, that work is postponed to a future proposal.

### Lifetime management

We once again generalize the `withExtendedLifetime` family of functions, this time to support calling them on nonescapable values.

```swift
let span = someArray.storage
withExtendedLifetime(span) { span in
  // `someArray` is being actively borrowed while this closure is running
}
// At this point, `someArray` may be ready to be mutated
```

We've now run proposals to generalize `withExtendedLifetime` for (1) typed throws, (2) noncopyable inputs and results, and (3) nonescapable inputs. It is getting unwieldy to keep having to tweak these APIs, especially since in actual practice, `withExtendedLifetime` is most often called with an empty closure, to serve as a sort of fence protecting against early destruction. The closure-based design of these interfaces are no longer fitting the real-life practices of Swift developers. These functions were originally designed to be used with a non-empty closure, like in the example below:

```swift
withExtendedLifetime(obj) {
  weak var ref = obj
  foo(ref!)
}
```

In most cases, the formulation we actually recommend these days is to use a defer statement, with the function getting passed an empty closure:

```swift
weak var ref = obj
defer { withExtendedLifetime(obj) {} } // Ugh 😖
foo(ref!)
```

These functions clearly weren't designed to accommodate this widespread practice. To acknowledge and embrace this new style, we propose to introduce a new public Standard Library function that simply extends the lifetime of whatever variable it is given:

```swift
func extendLifetime<T: ~Copyable & ~Escapable>(_ x: borrowing T)
```

This allows `defer` incantations like the one above to be reformulated into a more readable form:

```swift
// Slightly improved reality
weak var ref = obj
defer { extendLifetime(obj) }
foo(ref!)
```

To avoid disrupting working code, this proposal does not deprecate the existing closure-based functions in favor of the new `extendLifetime` operation. (Introducing the new function will still considerably reduce the need for future Swift releases to continue repeatedly generalizing the existing functions -- for example, to allow async use, or to allow nonescapable results.)

### Metatype comparisons

Swift's metatypes do not currently conform to `Equatable`, but the Standard Library still provides top-level `==` and `!=` operators that implement the expected equality relation. Previously, these operators only worked on metatypes of `Copyable` and `Escapable` types; we propose to relax this requirement.

```swift
print(Atomic<Int>.self == Span<Int>.self) // ⟹ false
```

The classic operators support existential metatypes `Any.Type`; the new variants also accept generalized existentials:

```swift
let t1: any (~Copyable & ~Escapable).Type = Atomic<Int>.self
let t2: any (~Copyable & ~Escapable).Type = Span<Int>.self
print(t1 != t2) // ⟹ true
print(t1 == t1) // ⟹ true
```

### Object identifiers

The `ObjectIdentifier` construct is primarily used to generate a Comparable/Hashable value that identifies a class instance. However, it is also able to identify metatypes:

```swift
let id1 = ObjectIdentifier(Int.self)
let id2 = ObjectIdentifier(String.self)
print(id1 == id2) // ⟹ false
```

[SE-0437] did not generalize this initializer; we can now allow it to work with both noncopyable and nonescapable types:

```swift
import Synchronization

let id3 = ObjectIdentifier(Atomic<Int>.self) // OK, noncopyable input type
let id4 = ObjectIdentifier(Span<Int>.self) // OK, nonescapable input type
print(id3 == id4) // ⟹ false
```

The object identifier of a noncopyable/nonescapable type is still a regular copyable and escapable identifier -- for instance, it can be compared against other ids and hashed.

### Odds and ends

[SE-0437] omitted generalizing the `Equatable` conformance of `ManagedBufferPointer`; this proposal allows comparing `ManagedBufferPointer` instances for equality even if their `Element` happens to be noncopyable.

[SE-0437] kept the `indices` property of unsafe buffer pointer types limited to cases where `Element` is copyable. This proposal generalizes `indices` to be also available on buffer pointers of noncopyable elements. (In the time since the original proposal, [SE-0447] has introduced a `Span` type that ships with an unconditional `indices` property, and [SE-0453] followed suit by introducing `InlineArray` with the same property. It makes sense to also provide this interface on buffer pointers, for consistency.) `indices` is useful for iterating through these collection types, especially until we ship a new iteration model that supports noncopyable/nonescapable containers.

Finally, [SE-0437] neglected to generalize any of the buffer pointer operations that [SE-0370] introduced on the standard `Slice` type. In this proposal, we correct this omission by generalizing the handful of operations that can support noncopyable result elements: `moveInitializeMemory(as:fromContentsOf:)`, `bindMemory(to:)`, `withMemoryRebound(to:_:)`, and `assumingMemoryBound(to:)`. `Slice` itself continues to require its `Element` to be copyable (at least for now), preventing the generalization of other operations.

## Detailed Design

Note that Swift provides no way to define the lifetime dependencies of a function's nonescapable result, nor to set lifetime constraints on input parameters.  Until the language gains an official way to express such constraints, the Swift Standard Library will define the APIs generalized in this proposal with unstable syntax that isn't generally available. In this text, we'll be using an illustrative substitute -- the hypothetical `@_lifetime` attribute. We will loosely describe its meaning as we go. 

Note: The `@_lifetime` attribute is not real; it is merely a didactic placeholder. The eventual lifetime annotations proposal may or may not propose syntax along these lines. We expect the Standard Library to immediately switch to whatever syntax Swift eventually embraces, as soon as it becomes available.

### Inferred lifetime behavior of nonescapable enum types 

[SE-0446] has introduced the concept of a nonescapable enum type to Swift. While that proposal did not explicitly spell this out, this inherently included a set of implicit lifetime rules for the principal language features that interact with enum types: enum construction using case factories and pattern matching. To generalize `Optional` and `Result`, we need to understand how these implicit inference rules work for enum types with a single nonescapable associated value.

1. When constructing an enum case with a single nonescapable associated value, the resulting enum value is inferred to carry precisely the same lifetime dependencies as the origional input.
2. Pattern matching over such an enum case exposes the nonescapable associated value, inferring precisely the same lifetime dependencies for it as the original enum.

```swift
enum Foo<T: ~Escapable> {
  case a(T)
  case b
}

func test(_ array: Array<Int>) {
  let span = array.span
  let foo = Foo.a(span) // (1)
  switch foo {
    case .a(let span2): ... // (2)
    case .b: ...
  }
}
```

In statement (1), `foo` is defined to implicitly copy the lifetime dependencies of `span`; neither variable can escape the body of the `test` function. The let binding in the pattern match on `.a` in statement (2) creates `span2` with exactly the same lifetime dependencies as `foo`.

(We do not describe the implicit semantics of enum cases with _multiple_ nonescapable associated values here, as they are relevant to neither `Optional` nor `Result`.)

### Inferred lifetime behavior of `Optional`'s notational conveniences

The `Optional` enum comes with a rich set of notational conveniences that are built directly into the language. This proposal extends these conveniences to work on nonescapable optionals; therefore it inherently needs to introduce new implicit lifetime inference rules, along the same lines as the two existing once we described above:

1. The result of implicit optional promotion of a nonescapable value is a nonescapable optional carrying precisely the same lifetime dependencies as the original input.
2. The force-unwrapping special form `!` and the optional chaining special form `?` both implicitly infer the lifetime dependencies of the wrapped value (if any) by directly copying those of the optional.

### `protocol ExpressibleByNilLiteral`

In order to generalize `Optional`, we need the `ExpressibleByNilLiteral` protocol to support nonescapable conforming types. By definition, the `nil` form needs to behave like a regular, escapable value; accordingly, the required initializer needs to establish "immortal" or "static" lifetime semantics on the resulting instance.

```swift
protocol ExpressibleByNilLiteral: ~Copyable, ~Escapable {
  @_lifetime(immortal) // Illustrative syntax
  init(nilLiteral: ())
}
```

In this illustration, `@_lifetime(immortal)` specifies that the initializer places no constraints on the lifetime of its result. We expect a future proposal to define a stable syntax for expressing such lifetime dependency constraints.

Preexisting types that conform to `ExpressibleByNilLiteral` are all escapable, and escapable values always have immortal lifetimes, by definition. Therefore, initializer implementations in existing conformances already satisfy this new refinement of the initializer requirement -- it only makes a difference in the newly introduced `~Escapable` case.

### `enum Optional`

We generalize `Optional` to allow nonescapable wrapped types in addition to noncopyable ones.

```swift
enum Optional<Wrapped: ~Copyable & ~Escapable>: ~Copyable, ~Escapable {
  case none
  case some(Wrapped)
}

extension Optional: Copyable where Wrapped: Copyable & ~Escapable {}
extension Optional: Escapable where Wrapped: Escapable & ~Copyable {}
extension Optional: BitwiseCopyable where Wrapped: BitwiseCopyable & ~Escapable {}
extension Optional: Sendable where Wrapped: ~Copyable & ~Escapable & Sendable {}
```

To allow the use of the `nil` syntax with nonescapable optional types, we generalize `Optional`'s conformance to `ExpressibleByNilLiteral`:

```swift
extension Optional: ExpressibleByNilLiteral
where Wrapped: ~Copyable & ~Escapable {
  @_lifetime(immortal) // Illustrative syntax
  init(nilLiteral: ())
}
```

As discussed above, `nil` optionals have no lifetime dependencies, and they continue to work like escapable values.

We need to generalize the existing unlabeled initializer to support the nonescapable case. When passed a nonescapable entity, the initializer creates an optional that has precisely the same lifetime dependencies as the original entity. Once again, Swift has not yet provided a stable way to express this dependency; so to define such an initializer, the Standard Library needs to use some unstable mechanism. We use the hypothetical `@_lifetime(copying some)` syntax to do this -- this placeholder notation is intended to reflect that the lifetime dependencies of the result are copied verbatim from the `some` argument.

```swift
extension Optional where Wrapped: ~Copyable & ~Escapable {
  @_lifetime(copying some) // Illustrative syntax
  init(_ some: consuming Wrapped)
}
```

As we've seen, the language also has built-in mechanisms for constructing `Optional` values that avoid invoking this initializer: it implements implicit optional promotions and explicit case factories. When given values of nonescapable types, these methods also _implicitly_ result in the result's lifetime dependencies being copied directly from the original input.

Swift offers many built-in ways for developers to unwrap optional values: we have force unwrapping, optional chaining, pattern matching, optional bindings, etc. Many of these rely on direct compiler support that is already able to properly handle lifetime matters; but the stdlib also includes its own forms of unwrapping, and these require some API changes.

In this proposal, we generalize `take()` to work on nonescapable optionals. It resets `self` to nil and returns its original value with precisely the same lifetime dependency as we started with. The `nil` value it leaves behind is still constrained to the same lifetime -- we do not have a way for a mutating function to affect the lifetime dependencies of its `self` argument.

```swift
extension Optional where Wrapped: ~Copyable & ~Escapable {
  @_lifetime(copying self) // Illustrative syntax
  mutating func take() -> Self
}
```

We are also ready to generalize the `unsafelyUnwrapped` property:

```swift
extension Optional where Wrapped: ~Escapable {
  @_lifetime(copying self) // Illustrative syntax
  var unsafelyUnwrapped: Wrapped { get }
}
```

This property continues to require copyability for now, as supporting noncopyable wrapped types requires the invention of new accessors that hasn't happened yet.

As noted above, we defer generalizing the nil-coalescing operator `??`. We expect to tackle it when it becomes possible to express the lifetime dependency of its result as an intersection of the lifetimes of its left argument and the _result_ of the right argument (an autoclosure). We also do not attempt to generalize similar higher-order API, like `Optional.map` or `.flatMap`.

The Standard Library provides special support for comparing arbitrary optional values against `nil`. We generalize this mechanism to support nonescapable cases:

```swift
extension Optional where Wrapped: ~Copyable & ~Escapable {
  static func ~=(
    lhs: _OptionalNilComparisonType,
    rhs: borrowing Wrapped?
  ) -> Bool
  
  static func ==(
    lhs: borrowing Wrapped?,
    rhs: _OptionalNilComparisonType
  ) -> Bool
  
  static func !=(
    lhs: borrowing Wrapped?,
    rhs: _OptionalNilComparisonType
  ) -> Bool
  
  static func ==(
    lhs: _OptionalNilComparisonType,
    rhs: borrowing Wrapped?
  ) -> Bool
  
  static func !=(
    lhs: _OptionalNilComparisonType,
    rhs: borrowing Wrapped?
  ) -> Bool
}
```

### `enum Result`

For `Result`, this proposal concentrates on merely allowing the success case to contain a nonescapable value. 

```swift
enum Result<Success: ~Copyable & ~Escapable, Failure: Error> {
  case success(Success)
  case failure(Failure)
}

extension Result: Copyable where Success: Copyable & ~Escapable {}
extension Result: Escapable where Success: Escapable & ~Copyable {}
extension Result: Sendable where Success: Sendable & ~Copyable & ~Escapable {}
```

We postpone generalizing most of the higher-order functions that make `Result` convenient to use, as we currently lack the means to reason about lifetime dependencies for such functions. But we are already able to generalize the one function that does not have complicated lifetime semantics: `mapError`.

```swift
extension Result where Success: ~Copyable & ~Escapable {
  @_lifetime(copying self) // Illustrative syntax
  consuming func mapError<NewFailure>(
    _ transform: (Failure) -> NewFailure
  ) -> Result<Success, NewFailure>
}
```

The returned value has the same lifetime constraints as the original `Result` instance.

We can also generalize the convenient `get()` function, which is roughly equivalent to optional unwrapping:

```swift
extension Result where Success: ~Copyable & ~Escapable {
  @_lifetime(copying self) // Illustrative syntax
  consuming func get() throws(Failure) -> Success
}
```

In the non-escapable case, this function returns a value with a lifetime that precisely matches the original `Result`.

### `enum MemoryLayout`

Swift is not yet ready to introduce pointers to nonescapable values -- we currently lack the ability to assign proper lifetime semantics to the addressed items. 

However, a nonescapable type does still have a well-defined memory layout, and it makes sense to allow developers to query the size, stride, and alignment of such instances. This information is associated with the type itself, and it is independent of the lifetime constraints of its instances. Therefore, we can generalize the `MemoryLayout` enumeration to allow its subject to be a nonescapable type:

```swift
enum MemoryLayout<T: ~Copyable & ~Escapable>
: ~BitwiseCopyable, Copyable, Escapable {}

extension MemoryLayout where T: ~Copyable & ~Escapable {
  static var size: Int { get }
  static var stride: Int { get }
  static var alignment: Int { get }
}

extension MemoryLayout where T: ~Copyable & ~Escapable {
  static func size(ofValue value: borrowing T) -> Int
  static func stride(ofValue value: borrowing T) -> Int
  static func alignment(ofValue value: borrowing T) -> Int
}
```

### Lifetime Management

[SE-0437] generalized the `withExtendedLifetime` family of functions to support extending the lifetime of noncopyable entities. This proposal further generalizes these to also allow operating on nonescapable entities:

```swift
func withExtendedLifetime<
  T: ~Copyable & ~Escapable,
  E: Error,
  Result: ~Copyable
>(
  _ x: borrowing T,
  _ body: () throws(E) -> Result
) throws(E) -> Result

func withExtendedLifetime<
  T: ~Copyable & ~Escapable,
  E: Error,
  Result: ~Copyable
>(
  _ x: borrowing T,
  _ body: (borrowing T) throws(E) -> Result
) throws(E) -> Result
```

Note that the `Result` is still required to be escapable.

We also propose the addition of a new function variant that eliminates the closure argument, to better accommodate the current best practice of invoking these functions in `defer` blocks:

```swift
func extendLifetime<T: ~Copyable & ~Escapable>(_ x: borrowing T)
```

### Metatype equality

Swift's metatypes do not conform to `Equatable`, but the Standard Library does implement the `==`/`!=` operators over them:

```swift
func == (t0: Any.Type?, t1: Any.Type?) -> Bool { ... }
func != (t0: Any.Type?, t1: Any.Type?) -> Bool { ... }
```

Note how these are defined on optional metatype existentials, typically relying on implicit optional promotion. We propose to generalize these to support metatypes of noncopyable and/or nonescapable types:

```swift
func == (
  t0: (any (~Copyable & ~Escapable).Type)?,
  t1: (any (~Copyable & ~Escapable).Type)?
) -> Bool { ... }
func != (
  t0: (any (~Copyable & ~Escapable).Type)?,
  t1: (any (~Copyable & ~Escapable).Type)?
) -> Bool { ... }
```

### `struct ObjectIdentifier`

The `ObjectIdentifier` construct is primarily used to generate a `Comparable`/`Hashable` value that identifies a class instance. However, it is also able to generate hashable type identifiers:

```swift
extension ObjectIdentifier {
  init(_ x: Any.Type)
}
```

We propose to generalize this initializer to allow generating identifiers for noncopyable and nonescapable types as well, using generalized metatype existentials:

```swift
extension ObjectIdentifier {
  init(_ x: any (~Copyable & ~Escapable).Type)
}
```

### `ManagedBufferPointer` equatability

The `ManagedBufferPointer` type conforms to `Equatable`; its `==` implementation works by comparing the identity of the class instances it is referencing. [SE-0437] has generalized the type to allow a noncopyable `Element` type, but it did not generalize this specific conformance. This proposal aims to correct this oversight:

```swift
extension ManagedBufferPointer: Equatable where Element: ~Copyable {
  static func ==(
    lhs: ManagedBufferPointer,
    rhs: ManagedBufferPointer
  ) -> Bool
}
```

Managed buffer pointers are pointer types -- as such, they can be compared whether or not they are addressing a buffer of copyable items.

(Note: conformance generalizations like this can cause compatibility issues when newly written code is deployed on older platforms that pre-date the generalization. We do not expect this to be an issue in this case, as the generalization is compatible with the implementations we previously shipped.)

### Making `indices` universally available on unsafe buffer pointers

[SE-0437] kept the `indices` property of unsafe buffer pointer types limited to cases where `Element` is copyable. In the time since that proposal, [SE-0447] has introduced a `Span` type that ships with an unconditional `indices` property, and [SE-0453] followed suit by introducing `InlineArray` with the same property. For consistency, it makes sense to also allow developers to unconditionally access `Unsafe[Mutable]BufferPointer.indices`, whether or not `Element` is copyable.

```swift
extension UnsafeBufferPointer where Element: ~Copyable {
  var indices: Range<Int> { get }
}

extension UnsafeMutableBufferPointer where Element: ~Copyable {
  var indices: Range<Int> { get }
}
```

This allows Swift programmers to iterate over the indices of a buffer pointer with simpler syntax, independent of what `Element` they are addressing:

```swift
for i in buf.indices {
  ...
}
```

We consider `indices` to be slightly more convenient than the equivalent expression `0 ..< buf.count`.

(Of course, we are still planning to introduce direct support for for-in loops over noncopyable/nonescapable containers, which will provide a far more flexible solution. `indices` is merely a stopgap solution to bide us over until we are ready to propose that.)

### Buffer pointer operations on `Slice`

Finally, to address an inconsistency that was left unresolved by [SE-0437], we generalize a handful of buffer pointer operations that are defined on buffer slices. This consists of the following list, originally introduced in [SE-0370]:

- Initializing a slice of a mutable raw buffer pointer by moving items out of a typed mutable buffer pointer:

   ```swift
   extension Slice where Base == UnsafeMutableRawBufferPointer {
     func moveInitializeMemory<T: ~Copyable>(
       as type: T.Type,
       fromContentsOf source: UnsafeMutableBufferPointer<T>
     ) -> UnsafeMutableBufferPointer<T>
   }
   ```

- Binding memory of raw buffer pointer slices:

   ```swift
   extension Slice where Base == UnsafeMutableRawBufferPointer {
     func bindMemory<T: ~Copyable>(
       to type: T.Type
     ) -> UnsafeMutableBufferPointer<T>
   }
   
   extension Slice where Base == UnsafeRawBufferPointer {
     func bindMemory<T: ~Copyable>(
       to type: T.Type
     ) -> UnsafeBufferPointer<T>
   }
   ```

- Temporarily rebinding memory of a (typed or untyped, mutable or immutable) buffer pointer slice for the duration of a function call:

   ```swift
   extension Slice where Base == UnsafeMutableRawBufferPointer {
     func withMemoryRebound<T: ~Copyable, E: Error, Result:    ~Copyable>(
       to type: T.Type,
       _ body: (UnsafeMutableBufferPointer<T>) throws(E) -> Result
     ) throws(E) -> Result
   }
   
   extension Slice where Base == UnsafeRawBufferPointer {
     func withMemoryRebound<T: ~Copyable, E: Error, Result:    ~Copyable>(
       to type: T.Type, 
       _ body: (UnsafeBufferPointer<T>) throws(E) -> Result
     ) throws(E) -> Result
   }
   
   extension Slice {
     func withMemoryRebound<
       T: ~Copyable, E: Error, Result: ~Copyable, Element
     >(
       to type: T.Type,
       _ body: (UnsafeBufferPointer<T>) throws(E) -> Result
     ) throws(E) -> Result
     where Base == UnsafeBufferPointer<Element>
     
     public func withMemoryRebound<
       T: ~Copyable, E: Error, Result: ~Copyable, Element
     >(
       to type: T.Type,
       _ body: (UnsafeMutableBufferPointer<T>) throws(E) -> Result
     ) throws(E) -> Result
     where Base == UnsafeMutableBufferPointer<Element>
   }
   ```

- Finally, converting a slice of a raw buffer pointer into a typed buffer pointer, assuming its memory is already bound to the correct type:

   ```swift
   extension Slice where Base == UnsafeMutableRawBufferPointer {
     func assumingMemoryBound<T: ~Copyable>(
       to type: T.Type
     ) -> UnsafeMutableBufferPointer<T>
   }
   
   extension Slice where Base == UnsafeRawBufferPointer {
     func assumingMemoryBound<T: ~Copyable>(
       to type: T.Type
     ) -> UnsafeBufferPointer<T>
   }
   ```

All of these forward to operations on the underlying base buffer pointer that have already been generalized in [SE-0437]. These changes are simply restoring feature parity between buffer pointer and their slices, where possible. (`Slice` still requires its `Element` to be copyable, which limits generalization of other buffer pointer APIs defined on it.)

These generalizations are limited to copyability for now. We do expect that pointer types (including buffer pointers) will need to be generalized to allow non-escapable pointees; however, we have to postpone that work until we are able to precisely reason about lifetime requirements.

<!--
// FIXME: Sequence.reduce, Sequence.reduce(into:)
// FIXME: Slice<Unsafe[Mutable][Raw]BufferPointer>.withMemoryRebound
// FIXME: [Contiguous]Array[Slice].withUnsafe[Mutable]BufferPointer
// FIXME: [Contiguous]Array[Slice].withUnsafe[Mutable]Bytes
// FIXME: String.withCString, .withUTF8 et al
// FIXME: StaticString.withUTF8Buffer
// FIXME: {Array,String}.init(unsafeUninitializedCapacity:initalizingWith:) (note: this does not need a proposal)
-->

## Source compatibility

Like [SE-0437], this proposal also heavily relies on the assurance that removing the assumption of escapability on these constructs will not break existing code that used to rely on the original, escaping definitions. [SE-0437] has explored a few cases where this may not be the case; these can potentially affect code that relies on substituting standard library API with its own implementations. With the original ungeneralized definitions, such custom reimplementations could have shadowed the originals. However, this may no longer be the case with the generalizations included, and this can lead to ambiguous function invocations.

This proposal mostly touches APIs that were already changed by [SE-0437], and that reduces the likelihood of it causing new issues. That said, it does generalize some previously unchanged interfaces that may provide new opportunities for such shadowing declarations to cause trouble.

Like previously, we do have engineering options to mitigate such issues in case we do encounter them in practice: for example, we can choose to amend Swift's shadowing rules to ignore differences in throwing, noncopyability, and nonescapability, or we can manually patch affected definitions to make the expression checker consider them to be less specific than any custom overloads.

## ABI compatibility

The introduction of support for nonescapable types is (in general) a compile-time matter, with minimal (or even zero) runtime impact. This greatly simplifies the task of generalizing previously shipping types for use in nonescapable contexts. Another simplifying aspect is that while it can be relatively easy for classic Swift code to accidentally copy a value, it tends to be rare for functions to accidentally _escape_ their arguments -- previous versions of a function are less likely to accidentally violate nonescapability than noncopyability.

The implementation of this proposal adopts the same approaches as [SE-0437] to ensure forward and backward compatibility of newly compiled (and existing) binaries, including the Standard Library itself. We expect that code that exercises the new features introduced in this proposal will be able to run on earlier versions of the Swift stdlib -- to the extent that noncopyable and/or nonescapable types are allowed to backdeploy.

[SE-0437] has already arranged ABI compatibility symbols to get exported as needed to support ABI continuity. It has also already reimplemented most of the entry points that this proposal touches, in a way that forces them to get embedded in client binaries. This allows the changes in this proposal to get backdeployed without any additional friction.

Like its precursor, this proposal does assume that the `~Copyable`/`~Escapable` generalization of the `ExpressibleByNilLiteral` protocol will not have an ABI impact on existing conformers of it. However, it goes a step further, by also adding a lifetime annotation on the protocol's initializer requirement; this requires that such annotations must not interfere with backward/forward binary compatibility, either. (E.g., it requires that such lifetime annotations do not get mangled into exported symbol names.)

### Note on protocol generalizations

Like [SE-0437], this proposal mostly avoids generalizing standard protocols, with the sole exception of `ExpressibleByNilLiteral`, which has now been generalized to allow both noncopyable and nonescapable conforming types.

As a general rule, protocol generalizations like that may not be arbitrarily backdeployable -- it seems likely that we'll at least need to support limiting the availability of _conformance_ generalizations, if not generalizations of the protocol itself. In this proposal, we follow [SE-0437] in assuming that this potential issue will not apply to the specific case of `ExpressibleByNilLiteral`, because of its particularly narrow use case. Our experience with [SE-0437] is reinforcing this assumption, but it is still possible there is an ABI back-compatibility issue that we haven't uncovered yet. In the (unlikely, but possible) case we do discover such an issue, we may need to do extra work to patch protocol conformances in earlier stdlibs, or we may decide to limit the use of `nil` with noncopyable/nonescapable optionals to recent enough runtimes.

To illustrate the potential problem, let's consider `Optional`'s conformance to `Equatable`: 

```swift
extension Optional: Equatable where Wrapped: Equatable {
  public static func ==(lhs: Wrapped?, rhs: Wrapped?) -> Bool {
    switch (lhs, rhs) {
    case let (l?, r?): return l == r
    case (nil, nil): return true
    default: return false
    }
  }
}
```

This conformance is currently limited to copyable and escapable cases, and it is using the classic, copying form of the switch statement, with `case let (l?, r?)` semantically making full copies of the two wrapped values. We do intend to soon generalize the `Equatable` protocol to support noncopyable and/or nonescapable conforming types. When that becomes possible, `Optional` will want to immediately embrace this generalization, to allow comparing two noncopyable/nonescapable instances for equality:

```swift
extension Optional: Equatable where Wrapped: Equatable & ~Copyable & ~Escapable {
  public static func ==(lhs: borrowing Wrapped?, rhs: borrowing Wrapped?) -> Bool {
    switch (lhs, rhs) {
    case let (l?, r?): return l == r
    case (nil, nil): return true
    default: return false
    }
  }
}
```

On the surface, this seems like a straightforward change. Unfortunately, switching to `borrowing` arguments changes the semantics of the implementation, converting the original copying switch statement to the borrowing form introduced by [SE-0432]. This new variant avoids copying wrapped values to compare them, enabling the use of this function on noncopyable data. However, the old implementation of `==` did assume (and exercise!) copyability, so the `Equatable` conformance cannot be allowed to dispatch to `==` implementations that shipped in Standard Library releases that predate this generalization. 

To mitigate such problems, we'll either need to retroactively patch/substitute the generic implementations in previously shipping stdlibs, or we need to somehow limit availability of the generalized conformance, without affecting the original copyable/escapable one.

This issue is more pressing for noncopyable cases, as preexisting implementations are far more likely to perform accidental copying than to accidentally escape their arguments.

Our hypothesis is that `ExpressibleByNilLiteral` conformances are generally free of such issues.

## Alternatives Considered

Most of the changes proposed here follow directly from the introduction of nonescapable types. The API generalizations follow the patterns established by [SE-0437], and are largely mechanical in nature. For the most part, the decision points aren't about the precise form of any particular change, but more about what changes we are ready to propose _right now_.

The single exception is the `extendLifetime` function, which is a brand new API; it comes from our experience using (and maintaining) the `withExtendedLifetime` function family.

## Future Work

For the most part, this proposal is concentrating on resolving the first item from [SE-0437]'s wish list (nonescapable `Optional` and `Result`), and it adds minor coherency improvements to the feature set we shipped there.

Most other items listed as future work in that proposal continue to remain on our agenda. The advent of nonescapable types extends this list with additional items, including the following topics:

1. We need to define stable syntax for expressing lifetime dependencies as explicit annotations, and we need to define what semantics we apply by default on functions that do not explicitly specify these.

2. We will need an unsafe mechanism to override lifetime dependencies of nonescapable entities. We also expect to eventually need to allow unsafe bit casting to and from nonescapable types.

3. We will need to allow pointer types to address nonescapable items: `UnsafePointer`, `UnsafeBufferPointer` type families, perhaps `ManagedBuffer`. The primary design task here is to decide what lifetime semantics we want to assign to pointer dereferencing operations, including mutations.

4. Once we have pointers, we will also need to allow the construction of generic containers of nonescapable items, with some Sequence/Collection-like capabilities (iteration, indexing, generic algorithms, etc.). We expect the noncopyable/nonescapable container model to heavily rely on the `Span` type, which we intend to use as the basic unit of iteration, providing direct access to contiguous storage chunks. For containers of nonescapables in particular, this means we'll also need to generalize `Span` to allow it to capture nonescapable elements.

5. We'll want to generalize most of the preexisting standard library protocols to allow nonescapable conforming types and (if possible) associated types. This is in addition to supporting noncopyability. This work will require adding carefully considered lifetime annotations on protocol requirements, while also carefully maintaining seamless forward/backward compatibility with the currently shipping protocol versions. This is expected to take several proposals; in some cases, it may include carefully reworking existing semantic requirements to better match noncopyable/nonescapable use cases. Some protocols may not be generalizable without breaking existing code; in those cases, we may need to resort to replacing or augmenting them with brand-new protocols. However, protocol generalizations for nonescapables are generally expected to be a smoother process than it is for noncopyables.

## Acknowledgements

Many people contributed to the discussions that led to this proposal. We'd like to especially thank the following individuals for their continued, patient and helpful input:

- Alejandro Alonso
- Steve Canon
- Ben Cohen
- Kavon Farvardin
- Doug Gregor
- Joe Groff
- Megan Gupta
- Tim Kientzle
- Guillaume Lessard
- John McCall
- Tony Parker
- Ben Rimmington
- Andrew Trick
- Rauhul Varma
