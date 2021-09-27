# Improving Sendable Inference

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Andrew Trick](https://github.com/atrick), [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting implementation**

*During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

[SE-0302](0302-concurrent-value-and-concurrent-closures.md) introduced the `Sendable` protocol, including `Sendable` requirements for various language constructs, conformances of various standard library types to `Sendable`, and inference rules for non-public types to implicitly conform to `Sendable`. Experience with `Sendable` has uncovered some issues with its original formulation, which this proposal seeks to address.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/improving-sendable/52377)

## Motivation

A `Sendable` type is one whose values can be copied from one actor or task into another, such that it is safe to concurrently use any operations on both the original value and any of its copies. A type that provides value semantics is `Sendable` because its copies are independent, whereas a type with reference semantics will require some means of synchronization (e.g., a lock) to beme `Sendable`. Actors innately provide this synchronization (so they are always `Sendable`), where classes generally do not.

Much of Swift's concurrency model requires the use of types that conform to `Sendable`, so the model by which types become `Sendable` is important. If it requires too much manual annotation, the Swift ecosystem will take a long time to adopt concurrency and `Sendable`. If there is too much implicit adoption of `Sendable`, some types will be labeled `Sendable` that aren't safe to use in that manner, undercutting the safety benefits of `Sendable` enforcement. This proposal addresses several issues related to `Sendable`:

* The unsafe pointer types should not conform to the `Sendable` protocol.
* The key path types should not conform to the `Sendable` protocol, but key path literals will be of `Sendable` type when appropriate.
* Inference of `Sendable` for non-public types should have a mechanism to be disabled.
* Non-public generic struct and enum types should have conditional `Sendable` conformances inferred for them.
* Completing and maintaining `Sendable` annotations for a module is burdensome.

We'll address each issue in turn.

### Unsafe pointer types should not be `Sendable`

SE-0302 [states]() that the unsafe pointer types conform to `Sendable`:

> `Unsafe(Mutable)(Buffer)Pointer`: these generic types _unconditionally_ conform to the `Sendable` protocol. This means that an unsafe pointer to a non-Sendable value can potentially be used to share such values between concurrency domains. Unsafe pointer types provide fundamentally unsafe access to memory, and the programmer must be trusted to use them correctly; enforcing a strict safety rule for one narrow dimension of their otherwise completely unsafe use seems inconsistent with that design.

The main problem with this reasoning is that unsafe pointers have reference semantics, and therefore should not be be `Sendable` because the role of `Sendable` is to prevent sharing reference-semantic types across actor or task boundaries. Unsafe pointers are unsafe in exactly one way, which is that it is the developer's responsibility to guarantee the lifetime of the memory referenced by the unsafe pointer. This is an intentional and explicit hole in Swift's memory safety story that has been around since the beginning. That "unsafe" should not implicitly extend to use in concurrent code, 

Another problem with making the unsafe pointers `Sendable` is the second-order effect it has on value types that store unsafe pointers. Consider a wrapper struct around a resource:

```swift
struct FileHandle { // implicitly Sendable
  var stored: UnsafeMutablePointer<File>
}
```

The `FileHandle` type will be inferred to be `Sendable` because all of its instance storage is `Sendable`. Even if we accept that an `UnsafeMutablePointer` by itself can be `Sendable ` because the "unsafe" can now apply to concurrency safety as well (as was argued in SE-0302), that same argument does not hold for the `FileHandle` type. Removing the conformance of the unsafe pointer types to `Sendable` eliminates the potential for it to propagate out to otherwise-safe wrappers.

### Key path types should not be `Sendable`

SE-0302 specifies that key path types are `Sendable` and adds checking to key path literals to make it so:

> Key paths themselves conform to the `Sendable` protocol. However, to ensure that it is safe to share key paths, key path literals can only capture values of types that conform to the `Sendable` protocol.

This prohibits existing code that captures non-`Sendable` types, even if that code is never intended to use concurrency.

### Implicit `Sendable` conformances should be disablable

Per SE-0302, non-`public` struct and enum types will implicitly conform to `Sendable` when all of their instance storage conforms to `Sendable`. This inference rule is meant to ease the annotation burden from the introduction of `Sendable`. However, it does not extend to `public` types, as described by SE-0302:

> Public non-frozen structs and enums do not get an implicit conformance, because doing so would present a problem for API resilience: the implicit conformance to `Sendable` would become part of the contract with clients of the API, even if it was not intended to be. Moreover, this contract could easily be broken by extending the struct or enum with storage that does not conform to `Sendable`. 

Similar concerns apply within a module, where a type that might appear `Sendable` from its instance storage but is not intended to have `Sendable` semantics. For example, a struct comprised only of `Sendable` types could nontheless have reference semantics:

```swift
enum MyLibrary {
  @TaskLocal
  static var strings: [String] = [...]
}

struct TaskLocalString { // should not be Sendable!
  let index: Int
  
  var string: String { MyLibrary.strings[index] }
}
```

A `TaskLocalString` only stores an `Int`, which implies that it is `Sendable`... even though it's use of task-local storage means that it should not be shared across tasks at all. The available mechanisms to suppress the implicit `Sendable` conformances are all unfortunate: make the type `public` (which disables inference) or add an otherwise-useless stored property of non-`Sendable` type to `TaskLocalString`.

### Generic structs and enums don't infer `Sendable`

Most of the time, `Sendable` inference eliminates boilerplate for types. However, `Sendable` inference is not available to generic types:

```swift
struct Pair<T, U> {
  var first: T
  var second: U
}
```

A non-generic `Pair` comprised of `Sendable` types would be implicitly `Sendable`. However, SE-0302 does not extend implicit `Sendable` conformances to generic types:

> Swift will not implicitly introduce a conditional conformance. It is possible that this could be introduced in a future proposal.

This makes adoption of `Sendable` within a module harder than it needs to be, because one must explicitly write out the conditional conformance:

```swift
extension Pair: Sendable where T: Sendable, U: Sendable { }
```

### Maintaining `Sendable` conformances for a module is hard

A Swift library should provide `Sendable` conformances for each of its public types that provide the appropriate semantics. For an existing Swift library, this requires the library author to audit each type to determine whether it is `Sendable` or not, and add explicit conformances for those types that are `Sendable`. As new types are added to the library, each must be considered to determine whether it is `Sendable`, representing an ongoing annotation burden. This is expected due to the pervasiveness of `Sendable`, but is a problem that there is no good way to distinguish an error of omision (the author forgot to think about `Sendable` when introducing a new type) from a type that has been considered and determined to be non-`Sendable`. This ambiguity makes it harder to rely on `Sendable` in general, because a user of the library cannot easily distinguish between a mistakenly non-`Sendable` type and a deliberately non-`Sendable` one.

## Proposed solution

We propose a number of specific changes and additions to the `Sendable` behavior introduced in SE-0302, each of which will be expanded upon below:

* Remove `Sendable` conformances from the unsafe pointer and key path types
* Infer `Sendable` types for some key path literals
* Introduce a syntax to specify explicitly that a type is non-`Sendable`
* Extend `Sendable` inference to generic types via implicit conditional conformances
* Introduce a compile-time flag that requires all public types to be explicitly annotated as `Sendable` or non-`Sendable`

### Remove problematic `Sendable` conformances

As described above, remove the `Sendable` conformance introduced by SE-0302 for the following types:

* `AutoreleasingUnsafeMutablePointer`
* `OpaquePointer`
* `CVaListPointer`
* `Unsafe(Mutable)?(Raw)?(Buffer)?Pointer`
* `AnyKeyPath`
* `PartialKeyPath`
* `KeyPath`
* `WritableKeyPath`
* `ReferenceWritableKeyPath`

### Infer `Sendable` types for some key path literals

With the various key path types no longer being `Sendable`, key paths would become locked to a single task or actor. However, some key paths could be `Sendable`. Normally, we would reach for conditional conformances to express when some instances of a generic type conform to a protocol and others do not. Here that approach does not work, because the properties that matter for `Sendable` involve captures, which aren't part of the key path type. Rather, they are known at the point where the key path literal is formed, so we can reflect the result in the type of the key path literal by making it a composition of the key path type and `Sendable`, such as `KeyPath<Person, String> & Sendable`. 

SE-0302 banned the formation of key path literals that capture non-`Sendable` types, to ensure that all key paths were `Sendable`. Instead, we propose that the type of a key path literal be `& Sendable` unless there are any captures of non-`Sendable` type. This solution provides better source compatibility than SE-0302, while ensuring that most key path literals are still considered `Sendable`.

```swift
class SomeClass: Hashable {
  var value: Int
}

class SomeContainer {
  var array: [String]
  var dict: [SomeClass : String]
}

let sc = SomeClass(...)
let i = 0
let keyPath1 = \SomeContainer.array[i]  // okay: type is ReferenceWritableKeyPath<SomeContainer, String> & Sendable
let keyPath2 = \SomeContainer.dict[sc]  // okay: type is ReferenceWritableKeyPath<SomeContainer, String>
```

### Introduce a syntax to specify explicitly that a type is non-`Sendable`

As noted earlier, a non-`public` struct or enum comprised of `Sendable` instance storage will be inferred to conform to `Sendable`. We propose using the existing `@available` syntax with `unavailable` to suppress implicit conformances:

```swift
struct TaskLocalString: @available(*, unavailable) Sendable {
  // ...
}
```

An "unavailable" conformance can only be written on the primary type definition or on an unconstrained extension of that type within the same module as its primary type definition. It can also not be written on a class type whose superclass conforms to the named protocol (either directly or indirectly), and may not be written on a protocol or actor type.

There are two reasons for re-using `@available(*, unavailable)` in this manner. The first is simply that the spelling already exists in the grammar, and states our intention quite clearly---this conformance is not available, ever. Second, the availability syntax generalizes well for conformances that are only available, e.g., for certain versions of a platform. Swift 5.4 introduced the notion of conditionally-available conformances, but avoided adding any specific syntax for them by requiring such conformances to be on a suitably-available extension:

```swift

extension X: P { } // conformance X: P is only available for the above platform versions
```

Swift could expand the `@available` syntax to its full generality for conformances as well, to make the above more explicit:

```swift
extension X: @available(macOS 11.9, iOS 14.0, tvOS 14.0, watchOS 7.0, *) P { }
```

This would allow, for example, conformances expressed on the primary type definition to have specified availability, which is not possible with today's extension-driven syntax. While we don't propose this generalized `@available` for conformances here, we note that our proposed use of `@available(*, unavailable)` strongly implies it as a future direction.

### Extend `Sendable` inference to generic types

A non-`public` struct or enum type is inferred to be `Sendable` when its instance storage is `Sendable`. However, with generic types, the storage might include values whose types are generic parameters (or derived from them), in which case the conformance to `Sendable` will need to be conditional. Consider the following:

```swift
protocol P {
  associatedtype A
}

struct Generic<T: P> {
  var value: T? = nil
  var assocValues: [T.A] = []
}
```

Assuming that the operations on this type don't introduce some kind of behind-the-scenes problem for `Sendable`, the conformance of `Generic` to `Sendable` can be described as follows:

```swift
extension Generic: Sendable where T: Sendable, T.A: Sendable { }
```

When `T` is `Sendable`, the conditional conformance of `Optional` to `Sendable` will be used to make `T?` `Sendable`. Similarly, when `T.P` is `Sendable`, `[T.A]` will also be `Sendable` via conditional conformance. We propose to infer conditional conformances for non-public types by walking the types of all of the instance storage (stored properties for `struct`s, associated values for `enums`s) and collecting the full set of requirements needed to make that instance storage `Sendable`. This is a generalization of the logic of SE-0302, which can only produce unconditional conformances. For `Generic`, it will produce the conditional conformance above; for a non-generic type or a generic type whose instance storage is `Sendable` independent of the generic arguments, it will produce an unconditional conformance. Note that implicit conformances to `Sendable` can be disabled by providing an explicit conformance to `Sendable` (whether conditional or unconditional) or explicitly disabling conformance to `Sendable` with the syntax proposed above.

Also note that, in some cases, the type wll not be `Sendable` because a concrete type---not a type parameter---lacks a suitable `Sendable` conformance. For example:

```swift
class Ref<T> { } // not Sendable

struct Generic2<T> { // no Sendable conformance at all because Ref<T> is always non-Sendable
  var ref: Ref<T> 
}
```

In such cases, no `Sendable` conformance will be inferred.

### Compiler support to help find all `Sendable` types

As existing Swift code embraces `Sendable`, it can be a chore to audit each and every `public` type to determine whether it should be `Sendable`. A missing `Sendable` conformance in a library makes it harder for clients to use Swift's concurrency model with that library. We propose the addition of a new compiler flag, `-require-explicit-sendable`, that requires each `public` (or `open`) non-protocol type to either be `Sendable` or be marked explicitly non-`Sendable` with the syntax proposed above. The compiler will produce a warning for each type that does not meet these requirements. As an implementation matter, the compiler should provide Fix-Its to help with these conformances. For example, if the `Generic` type from the previous section were `public` and had no `Sendable` conformance , the compiler could provide Fix-Its options to either make it conditionally `Sendable` or to make it explicitly non-`Sendable`.

```swift
public struct Generic<T: P> { // warning: public type `Generic` is neither `Sendable` nor explicitly non-`Sendable`
    // note: add conditional conformance to `Sendable` if this values of this type can be copied across concurrent tasks
    // note: add explicit non-Sendable annotation to suppress this warning
  var value: T? = nil
  var assocValues: [T.A] = []
}
```

With such a flag, a user can conduct an audit of all of the public types for `Sendable`, using Fix-Its to make most of the required source code changes. The flag could either be removed (possibly along with the explicit non-`Sendable` annotations) or left in place to ensure that `Sendable` is considered for future public types.

## Source compatibility

This proposals alters `Sendable` conformances in several ways that can have impact on source compatibility.This proposa is a mix of additions and removals. The additions (e.g., conditional `Sendable` conformances for non-`public` types) aren't likely to break much code, because adding protocol conformances rarely does, and the new compiler flag is opt-in.

The removal of `Sendable` conformances from unsafe pointer types and key path types can certainly break code that depends on those conformances. There are two mitigating factors here that make us feel comfortable doing so at this time. The first mitigating factor is that `Sendable` is only very recently introduced in Swift 5.5, and `Sendable` conformances aren't enforced in the Swift Concurrency model just yet. The second is that the staging in of `Sendable` checking in the compiler implies that missing `Sendable` conformances are treated as warnings, not errors, so there is a smooth transition path for any code that depended on this now-removed conformances.

## Effect on ABI stability

`Sendable` is a marker protocol, which was designed to have zero ABI impact. Therefore, this proposal itself should have no ABI impact, because adding and removing `Sendable` conformances is invisible to the ABI.

## Effect on API resilience

For the most part, this proposal does not introduce any changes that directly affect API resilience. The changes to inference of `Sendable ` are mostly restricted to types that remain within a module (e.g., only non-public generic types can have conditional `Sendable` conformances inferred). This proposal does encourage changes to can impact API resilience, e.g., it introduces a compiler flag to encourage more adoption of `Sendable`, which will have downstream effects on clients, but generally the additional of a `Sendable` conformance does not break code.

The inference of `Sendable` key path literals can change some types of public stored properties, however:

```swift
public struct Point: Sendable {
  var x, y: Double
  
  public static var xKeypath = \Point.x // used to have type WritableKeyPath<Point, Double>
                                        // now has type WritableKeyPath<Point, Double> & Sendable
}
```

APIs affected by this change can either accept the new more-qualified type, or they can explicitly specify the original `WritableKeyPath<Point, Double>` type.

## Alternatives considered

### Syntax for "explicitly non-Sendable"

We've had some feedback already that the availability-based syntax for explicitly non-`Sendable`, `@available(*, unavailable) Sendable`, is verbose and confusing. We could, alternately, introduce a shorter syntax such as `@unavailable Sendable`, where `@unavailable` is general shortcut syntax for `@available(*, unavailable)` that just happens to also work very nicely in conformance specifications:

```swift
struct MyReferenceSemanticType: @unavailable Sendable { ... }
```

but could also be allowed elsewhere

```swift
@unavailable public func myOldAPIThatIsNowGone() { ... }
```
