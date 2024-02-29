# Noncopyable Generics

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Kavon Farvardin](https://github.com/kavon)
* Upcoming Feature Flag: `NoncopyableGenerics`
<!-- * Review Manager: TBD
* Status: **Awaiting implementation** or **Awaiting review**
* Vision: *if applicable* [Vision Name](https://github.com/apple/swift-evolution/visions/NNNNN.md)
* Roadmap: *if applicable* [Roadmap Name](https://forums.swift.org/...))
* Bug: *if applicable* [apple/swift#NNNNN](https://github.com/apple/swift/issues/NNNNN)
* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Previous Proposal: *if applicable* [SE-XXXX](XXXX-filename.md)
* Previous Revision: *if applicable* [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Review: ([pitch](https://forums.swift.org/...)) -->

<!-- markdown-toc start - Don't edit this section. Run M-x markdown-toc-refresh-toc -->
**Table of Contents**

- [Noncopyable Generics](#noncopyable-generics)
    - [Introduction](#introduction)
    - [Motivation](#motivation)
    - [Proposed Solution](#proposed-solution)
        - [The `Copyable` Protocol](#the-copyable-protocol)
            - [Conforming to `Copyable`](#conforming-to-copyable)
        - [Type parameters](#type-parameters)
        - [Structs and enums](#structs-and-enums)
        - [Classes](#classes)
        - [Protocols](#protocols)
            - [Inheritance](#inheritance)
    - [Detailed Design](#detailed-design)
        - [Conditionally-copyable types](#conditionally-copyable-types)
        - [The top type](#the-top-type)
        - [Existentials](#existentials)
        - [Scoping rule](#scoping-rule)
        - [`AnyObject`](#anyobject)
    - [Impact to existing source code](#impact-to-existing-source-code)
    - [Effect on ABI stability](#effect-on-abi-stability)
    - [Effect on API resilience](#effect-on-api-resilience)
    - [Alternatives Considered](#alternatives-considered)
        - [`NonCopyable` as a Positive Requirement](#noncopyable-as-a-positive-requirement)
        - [`❌Copyable` as a Negative Requirement](#❌copyable-as-a-negative-requirement)
        - [Alternative Spellings](#alternative-spellings)
        - [Inferred Conditional Copyability](#inferred-conditional-copyability)
    - [Future Directions](#future-directions)
        - [`~Escapable`](#escapable)
        - [Non-copyable Classes](#non-copyable-classes)
        - [Dynamic Queries and Runtime Support](#dynamic-queries-and-runtime-support)
    - [Acknowledgments](#acknowledgments)

<!-- markdown-toc end -->

## Introduction

The noncopyable types introduced in [SE-0390: Noncopyable structs and enums](0390-noncopyable-structs-and-enums.md) come with the heavy limitation that such values cannot be substituted for a generic type parameter, erased to an existential, or conform to a protocol.
This proposal extends Swift's type system with syntax and semantics allowing noncopyable types to be used in all of these ways.

## Motivation

SE-0390 laid the groundwork for declaring struct and enum types that cannot be copied.
This ensures correct semantics for types for which it is not meaningful to
have multiple copies:
```swift
// A file descriptor cannot be usefully used from
// multiple places at once, so make it non-copyable
// to prevent such usage.
struct FileDescriptor: ~Copyable { ... }
```

This also provides an alternative to class objects for some use cases.
In particular, the tightly defined lifecycle allows noncopyable structs
to carry deinitializers:
```swift
struct HeapBuffer: ~Copyable {
  init() { ... allocate working storage on heap ... }
  deinit() { ... release storage ... }
}
```

But SE-0390 also made a number of concessions to simplify the initial implementation,
limitations which significantly reduce the usefulness of noncopyable types.

For example, SE-0390 did not allow noncopyable types to be used in generics,
which prevents them from being used with `Optional`,
which prevents you from defining a failable initializer on a noncopyable type:
```swift
struct FileDescriptor: ~Copyable {
  init?(filename: String) { // 🛑 Cannot return Optional<FileDescriptor>
    ...
  }
}
```

Practical use of generics also requires supporting protocol conformances,
since generic parameters gain capabilities when they are constrained to particular protocols:
```swift
// T is capable of being compared with other T's
func max<T: Comparable>(...) { ... }
```

In order to broaden the expressiveness and utility of noncopyable types, then,
language extensions are needed to allow these types to be used in generic parameters,
to conform to protocols, and to be stored in existentials.
This in turn requires a consistent and sound way to relax the fundamental
assumption of copyability that permeates Swift's generics system.

## Proposed Solution

There are three fundamental components to this proposal that together provide a solution for noncopyable generics:

1. The `Copyable` protocol indicates that values of a particular type can be copied
2. This protocol is applied by default to type definitions and generic requirements
3. The `~Copyable` notation can suppress this implicit requirement in specific cases

**Note**: This proposal does not cover adapting the standard library to support noncopyable types.

### The `Copyable` Protocol

`Copyable` is a new protocol that represents types that support copying.
Values in Swift that support copying will now conform to `Copyable`.
Naturally, the set of noncopyable types are exactly those that do _not_ conform to `Copyable`.

When initializing a new variable binding using an existing struct or enum value, semantically the binding is initialized with a copy as long as the value is `Copyable`.
Otherwise, the value is moved into the binding.
See [SE-0390](0390-noncopyable-structs-and-enums.md) for more details about copy/move behaviors and working with noncopyable types.

**Note**: For clarity, the examples in this proposal will detail implicit requirements in comments.
In this example
```swift
func f<T>(_ t: T) /* where T: Copyable */ {}
```
the comment indicates that the requirement `T: Copyable` is an implicit default that will be automatically inferred by the generics system.

In addition, comments with _generic signature_ or _interface type_ may appear next to a type or function, respectively.
These generic signatures will detail all of the requirements or type constraints for generic parameters in scope:
```swift
// signature <Self where Self: Comparable & Copyable>
protocol P: Comparable {}

struct S<T: Equatable> {
  func f() {}  // signature <T where T: Equatable & Copyable>
}
```

#### Conforming to `Copyable`

`Copyable` has no explicit requirements.
Value types like structs and enums conform to `Copyable` when all of their stored properties or associated values conform to `Copyable`.
Reference types like classes and actors can always conform to `Copyable`, because a reference to an object can always be copied, regardless of what is contained in the object.
Metatypes are always copyable as they represent immutable information about a type.
Support for noncopyable tuples and element packs are left to future work.

... #### Extensions: Conditional conformances to `Copyable` can be defined as an extension, but all conditional requirements must involve marker protocols only.

### Type parameters

All generic type parameters default to carrying a `Copyable` conformance constraint:

```swift
struct FileDescriptor: ~Copyable { /* ... */ }

func genericFn<T>(_ t: T) /* where T: Copyable */ {
  return copy t  // OK
}

genericFn(FileDescriptor())  // ERROR: FileDescriptor is not Copyable
genericFn([1, 2]) // OK: Array<Int> is Copyable
```

In [SE-0390](0390-noncopyable-structs-and-enums.md) the prefix `~` syntax was introduced only in the inheritance clause of a nominal type to "suppress" its default `Copyable` conformance.
This proposal completes the picture by defining the semantics of `~Copyable` as _suppressing the default requirements_ for `Copyable` conformance.
Suppressing requirements other than `Copyable` is outside the scope of this proposal.

A generic parameter can have its default `Copyable` requirement suppressed by applying `~Copyable` to the parameter:

```swift
func identity<T: ~Copyable>(_ t: borrowing T) -> T  {
  return copy t  // ERROR: 't' may not be copyable
}

identity(FileDescriptor())  // OK, FileDescriptor is not Copyable
identity([1, 2, 3])  // OK, even though Array<Int> is Copyable
```

> **Key Idea:** Suppressing the `Copyable` requirement by using `T: ~Copyable` does _not_ prevent a `Copyable` type from being substituted for `T`.
> This is the reason why the syntax `~Copyable` is referred to as _suppressing_ `Copyable` rather than _inverting_ or _negating_ it.

As with a concrete noncopyable type, any generic type parameter that does not conform `Copyable` must use one of the ownership modifiers `borrowing`, `consuming`, or `inout`, when it appears as the type of a function's parameter.
For details on these parameter ownership modifiers, see [SE-377](0377-parameter-ownership-modifiers.md).

### Structs and enums

All struct and enum types conform to `Copyable` by default:

```swift
struct DataSet /* : Copyable */ {
  var samples: [Double]
}
```

Similarly, generic type arguments are constrained to be `Copyable` by default.
For example, the generic argument `Element` in this `List`:

```swift
enum List<Element /* : Copyable */> /* : Copyable */ {
  case empty
  indirect case node(Element, List<Element>)
}
```

As in SE-390, a generic struct or enum can use `~Copyable` to suppress the implicit `Copyable` conformance and constraint:

```swift
enum List<Elm: ~Copyable>: ~Copyable { /* ... */ }

// or equivalently:

enum List<Elm>: ~Copyable where Elm: ~Copyable { /* ... */ }
```

Since `Elm` is not required to be `Copyable`, a noncopyable type like `FileDescriptor` can be substituted in `List`, in addition to copyable ones.

### Classes

Classes (including actors) are always `Copyable`,
even if they have noncopyable properties.
This proposal does not provide support for noncopyable classes.
```swift
class FileHandle<File> /* : Copyable where File: Copyable */ {
  var file: File
  // ...
}
```

Generic parameters on classes are `Copyable` by default.
This can be suppressed with `~Copyable` on the type parameter:
```swift
class FileHandle<File: ~Copyable> /* : Copyable */ {
  var file: File
  // ...
}
```

### Protocols

Protocols and their associated types default to implicit `Copyable` conformance requirement:

```swift
// signature <Self where Self: Copyable, Self.T: Copyable>
protocol Foo /* : Copyable */ {
  associatedtype T /* : Copyable */

  borrowing func bar() -> Self
  func buzz(_: T) -> T
  func blarg() -> RequiresCopyable<Self>
}
```

Protocols can suppress the default `Copyable` requirement from `Self` using `~Copyable`:

```swift
// signature <Self where Self.Event: Copyable>
protocol EventLog: ~Copyable {
  associatedtype Event /* : Copyable */
  
  mutating func push(_ event: Event)
  mutating func pop() throws -> Event
}
```

Within `EventLog`, the type `Self` has no conformance requirements at all, but the associated type `Self.Event` is copyable.
Suppressing the `Copyable` conformance requirement on `EventLog` allows copyable and noncopyable types to conform:

```swift
// signature <Self where Self: EventLog, Self: Copyable>
struct ArrayLog<Element>: EventLog /*, Copyable where Element: Copyable */ {
  typealias Event = Element
  var log: [Element]
  // ...
}

// signature <Self where Self: EventLog>
struct UniqueLog<Element>: EventLog, ~Copyable /* where Element: Copyable */ {
  typealias Event = Element
  var log: [Element]
  // ...
}
```

Associated types can additionally use `~Copyable` to suppress their default `Copyable` requirement, meaning a noncopyable type can witness the requirement:

```swift
protocol JobQueue<Job> /* : Copyable */ {
  associatedtype Job: ~Copyable

  func submit(_ job: consuming Job)
}
```

In an unconditional extension of `EventLog`, the type `Self` is not `Copyable` because `~Copyable` was used to suppress its implicit `Copyable` requirement:

... ### TODO: Is this really correct?  Can you extend someone else's protocol?   If so, this would preclude making existing protocols be noncopyable.

```swift
protocol EventLog: ~Copyable {
  associatedtype Event /* : Copyable */
  // ...
}

extension EventLog /* where Self: ~Copyable */ {
  func duplicate() -> Self { 
    return copy self // error: copy of noncopyable value
  } 
}
```

Of course, when the conformer _does_ happen to be copyable, additional functionality can be made available to it using a conditional extension:

```swift
extension EventLog where Self: Copyable {
  func duplicate() -> Self { 
   copy self // OK
  } 
}
```

The same principle applies to `JobQueue`'s associated type `Job` in extensions, where the `Job` is not `Copyable`.

#### Inheritance

A type must restate `~Copyable` even if it only conforms to protocols that are `~Copyable`, because the _absence_ of a requirement is not propagated:

```swift
protocol Token: ~Copyable {}

// signature <Self where Self : Token, Self : Copyable>
protocol ArcadeCoin: Token /* , Copyable */ {}

// signature <Self where Self : Token>
protocol CasinoChip: Token, ~Copyable {}
```

Note that `~Copyable` as a constraint is not viral:
types that conform to a `~Copyable` protocol can themselves be `Copyable`.
Similarly, a protocol that inherits from a noncopyable one can still be `Copyable`.

In contrast, associated type requirements that are inherited from another protocol do preserve `~Copyable`:

```swift
// signature <Self: Copyable>
protocol JobQueue /* : Copyable */ {
  associatedtype Job: ~Copyable
  // ...
}

// signature <Self where Self: Copyable, Self: JobQueue>
protocol FIFOJobQueue<Job>: JobQueue {
  // associatedtype Job: ~Copyable // Because inherited
  func pushBack(_ j: Job) // error: missing ownership specifier for parameter of
                          //        noncopyable type 'Job'
}
```

In the above example, `JobQueue.Job` remains noncopyable in `FIFOJobQueue`.
However, if the associated type requirement is  redeclared in the inheritor, 
the usual rule for `associatedtype` requirements will add an implicit `Copyable` requirement for the redeclaration:

```swift
// signature <Self where Self: JobQueue, Self.Job: Copyable>
protocol LIFOJobQueue<Event>: JobQueue {
  associatedtype Job /* : Copyable */
}
```

## Detailed Design

This section spells out additional details about the proposed extensions.

### Conditionally-copyable types

An aggregate type can only be copyable if all its stored fields are copyable.
A generic type with properties that may or may not be copyable will often want
to conditionally declare copyability.

Since `Copyable` is an additive capability, this must be done by declaring
the base type to not require copyability and then conditionally extending it:
```swift
struct MaybeCopyable<T: ~Copyable>: ~Copyable {
  var t: T
}

extension MaybeCopyable: Copyable where T: Copyable { }
```

### The top type

The type `Any` is no longer the "top" type in the language, which is the type that is a supertype of all types.
The new world order is:

```
              any ~Copyable
                /        \
               /          \
              /            \
    Any == any Copyable   <all noncopyable types>
        |
< all other copyable types >
```

### Existentials

Like type parameters, existentials have an implicit default `Copyable` constraint.
An existential consisting of a composition that includes `~Copyable` will remove this `Copyable` default:

```swift
protocol Pizza: ~Copyable {
  associatedtype Topping: ~Copyable
  func peelOneTopping() -> Topping
}

let t: any Pizza = ... // signature <Self where Self: Copyable, Self: Pizza, Self.Topping: Copyable>
let _: any Copyable = t.peelOneTopping() // signature <Self: Copyable>

let u: any Pizza & ~Copyable = ... // signature <Self: Pizza>
let _: any ~Copyable = u.peelOneTopping() // signature <Self>
```
For associated types within a protocol erased to an existential preserve conformances to a marker protocol like `Copyable`.
So when calling `peelOneTopping` on an `any Pizza`, an `any ~Copyable` value is returned instead of `any Copyable`, which is equivalent to `Any`.

### Scoping rule

A constraint suppression like `~Copyable` can only be applied to a type parameter within the same scope as the constraint:

```swift
struct S<T> { // signature: <T: Copyable>
  func f() where T: ~Copyable // signature: <T>
  // error: cannot suppress constraint 'T: ~Copyable' on generic parameter 'T' defined in outer scope
}
```

The rationale is that an outer generic context, like `S<T>`, already requires that `T` is `Copyable`.
Removing that `Copyable` requirement for the nested generic context `S<T>.f` is useless, as there will never be a noncopyable value substituted for `S<T>`.
The same logic applies to mututally-scoped contexts:

```swift
protocol P {
  // error: cannot suppress constraint 'Self.Alice: ~Copyable' on generic parameter 'Self.Alice' defined in outer scope
  associatedtype Bob where Alice: ~Copyable
  associatedtype Alice where Bob: ~Copyable
  // error: cannot suppress constraint 'Self.Bob: ~Copyable' on generic parameter 'Self.Bob' defined in outer scope
}
```

### `AnyObject`

... ### TODO: can classes be cast to `any ~Copyable`? If so, then it seems fine to
permit an `AnyObject` to be cast to `any ~Copyable`. 

... ### TODO: is this legal? `func f<T>(_ t: T) where T: AnyObject, T: ~Copyable {}` -->

## Impact to existing source code

Since `Copyable` is implicitly assumed for any context that does not explicitly
specify `~Copyable`, this does not change the interpretation of existing code.

## Effect on ABI stability

Adding `~Copyable` to an existing type, function, or generic parameter is generally an ABI-breaking change.
To preserve existing ABI, function and type mangling will encode the lack of `Copyable` conformance rather than its presence.

We are exploring targeted mechanisms that can be used to preserve ABI compatibility when adding `~Copyable` to existing types,
but such mechanisms will require extreme care to use correctly.
In particular, this can allow clients to compile against new versions of a library and then run with an old version.
If the old version attempts to copy a non-copyable value, this will break.

## Effect on API resilience

Adding `~Copyable` to a generic parameter does not generally impact
existing clients that provide implicitly-`Copyable` types for such parameters.
Whether this can be done safely depends on how the particular parameter is used.

... ### TODO FIXME

## Alternatives Considered

### `NonCopyable` as a Positive Requirement

Our proposal above adds `Copyable` to the Swift language as a default property of all types
and a default requirement in all generic contexts.
It then uses `~Copyable` to indicate that this default property and/or requirement should be suppressed.

An alternative approach would instead add `NonCopyable` as a positive requirement.
In essence, `NonCopyable` would be the positive assertion that values of this type will
receive additional scrutiny inside the compiler:
```swift
struct AltS<T: NonCopyable> { ... }
struct AltNC: NonCopyable { ... }
var s3: AltS<AltNC> // OK. AltNC is not copyable
var s4: AltS<Int> // 🛑 Int is not NonCopyable
```

This would make any type `T & NonCopyable` be a subtype of `T`.
In particular, `NonCopyable` itself would be a subtype of `Any`,
which implies that such values can be assigned into an `Any` existential.
But `Any` can be arbitrarily copied, so we cannot allow this.
This applies equally to any other container.

### `❌Copyable` as a Negative Requirement

Another alternative would introduce a syntax (for our purpose here, we'll use `❌Copyable`)
that serves as a negative requirement.
Such a marker in any context would indicate that the `Copyable`
capability _must not_ be present.
This is distinctly different than our proposed `~Copyable` which
indicates that `Copyable` is not required in this context.

... ### TODO FIXME: Why does this break down?
I know that negation is a massive complication for any kind of solver,
but it would be gratifying to have a more substantial reason here.

### Alternative Spellings

Instead of `~Copyable`, we could use any of a variety of other spellings.
As argued immediately above, we need a spelling that indicates
the relaxation of a default copyable requirement.
We feel this is most natural if we name the copyable requirement `Copyable`
and use a sigil to indicate the suppression of that requirement.
We considered `?` and `!` as alternatives,
but felt that `~` best conveyed the intent while avoiding confusion with the
existing uses of `?` and `!` in the language.

### Inferred Conditional Copyability

It would be possible to infer conditional copyability for generic types with
stored properties that might not be copyable.
```swift
struct MaybeCopyable<T: ~Copyable>: ~Copyable {
  var t: T
}

// This could be inferred
extension MaybeCopyable: Copyable where T: Copyable { }
```
But in practice, such inference seems more confusing than helpful.

## Future Directions

### `~Escapable`

The ability to "escape" the current context is another implicit capability
of all current Swift types.
Suppressing this requirement provides an alternative way to control object lifetimes.
A companion proposal will provide details.

### Non-copyable Classes

This proposal supports classes with generic parameters,
but it does not permit classes to be directly marked `~Copyable`.
If supported, such classes could avoid essentially all reference-counting operations,
which could be a significant performance boost in practice.
We expect to explore this in a future proposal.

### Dynamic Queries and Runtime Support

The current implementation does not provide a mechanism to test at runtime whether
a value is copyable.
We expect to explore such support in a future proposal.
```swift
// Possible future extensions...
if MemoryLayout<T>.isCopyable { ... }
if let t = value as? Copyable { ... }
```

## Acknowledgments

Thank you to Joe Groff, Slava Pestov, and Ben Cohen for their feedback throughout the development of this proposal.
