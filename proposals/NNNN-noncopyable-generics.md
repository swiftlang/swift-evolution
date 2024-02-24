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

## Table of Contents
- [Noncopyable Generics](#noncopyable-generics)
  - [Table of Contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Motivation](#motivation)
  - [Proposed Solution](#proposed-solution)
    - [Reading Note](#reading-note)
    - [Copying and `Copyable`](#copying-and-copyable)
      - [Conformance](#conformance)
    - [Type parameters](#type-parameters)
    - [Structs and enums](#structs-and-enums)
      - [Automatic synthesis of conditional `Copyable` conformance](#automatic-synthesis-of-conditional-copyable-conformance)
    - [Classes](#classes)
    - [Protocols](#protocols)
      - [Inheritance](#inheritance)
   - [Detailed Design](#detailed-design)
    - [The top type](#the-top-type)
    - [Existentials](#existentials)
    - [Scoping rule](#scoping-rule)
  - [Acknowledgments](#acknowledgments)


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

For example, if noncopyable types cannot be used in generics,
then they cannot be used with `Optional`,
which prevents you from defining failable initializers:
```swift
struct FileDescriptor: ~Copyable {
  init?(filename: String) { // 🛑 Cannot return Optional<FileDescriptor>
    ...
  }
}
```

Practical use of generics also requires supporting protocol conformances,
since generic parameters are often constrained to particular protocols:
```swift
func max<T: Comparable>(...) { ... }
```

In order to broaden the expressiveness and utility of noncopyable types, then,
we need a sound way to allow these types to be used in generic parameters,
to conform to protocols, and to be stored in existentials.
This in turn requires a consistent and sound way to relax the fundamental
assumption of copyability that permeates Swift's generics system.

## Proposed Solution

There are three fundamental components to this proposal that together provide a solution for noncopyable generics:

1. The `Copyable` protocol indicates that values of a particular type can be copied
2. This protocol is applied by default to type definitions and generic requirements
3. The `~Copyable` notation can suppress this implicit requirement in specific cases

**Note**: Several other issues will need to be addressed before we can adapt the bulk of the standard library to support noncopyable types.
We are exploring possible approaches and hope to have a concrete proposal in the near future.
This expansion of the generics system is an obvious prerequisite for any such effort.

### Copying and `Copyable`

Swift's semantics and programmer's expectations of program values is that, by default, they can be copied.
The type `Copyable` is a new marker protocol that represents types that support copying.
All kinds of values in Swift that have supported copying will now conform to `Copyable`.
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
// signature <Self where Self: Comparable>
protocol P: Comparable {}

struct S<T: Equatable> {
  func f() {}  // signature <T where T: Equatable>
}
```

#### Conformance

Being a marker protocol, `Copyable` has no explicit requirements.
Value types like structs and enums conform to `Copyable` only if all of their stored properties or associated values conform to `Copyable`.
Reference types like classes and actors can always conform to `Copyable`, because a reference to an object can always be copied, regardless of what is contained in the object.
Metatypes are always copyable as they only represent information about a type.
Support for noncopyable tuples and element packs are left to future work.

... #### Extensions: Conditional conformances to `Copyable` can be defined as an extension, but all conditional requirements must involve marker protocols only.


... #### Dynamic queries: TODO: Can we make `MemoryLayout<T>.isCopyable` work? What is needed here?

### Type parameters

All generic type parameters default to carrying a `Copyable` conformance constraint:

```swift
struct FileDescriptor: ~Copyable { /* ... */ }

// signature <T where T: Copyable>
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
// signature <T>
func identity<T: ~Copyable>(_ t: borrowing T) -> T  {
  return copy t  // ERROR: 't' is noncopyable
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

#### Automatic synthesis of conditional `Copyable` conformance
Often a type parameter is added to a nominal type because values of that generic type will be stored somewhere within the parameterized nominal type.
Because of `Copyable`'s containment rule, that implies the parameterized type itself is commonly noncopyable if any of its type parameters is noncopyable.
This observation is one of the guiding principles behind the rules in this section.

Using `~Copyable` on any type parameter of a struct or enum, without specifying the copying behavior for the parameterized type itself, will automatically synthesize a conditional conformance to `Copyable`:

```swift
// A conditionally-copyable pair.
struct Pair<Elm: ~Copyable> {
  // signature <Elm>
  func exchangeFirst(_ new: consuming Elm) -> Elm? { /* ... */ }
}
/* extension Pair: Copyable where Elm: Copyable {} */

struct RequiresCopyable<T> {}

typealias Err = RequiresCopyable<Pair<FileDescriptor>>
// error: type 'Pair<FileDescriptor>' does not conform to protocol 'Copyable'

typealias Ok = RequiresCopyable<Pair<Int>>

// A conditionally-copyable factory.
struct Factory<Product: ~Copyable, Token: ~Copyable, Policy> {
  var seed = 0

  // signature <Product, Token, Policy where Policy : Copyable>
  mutating func produce(_ payment: consuming Token) -> Product { /* ... */ }
}
/* extension Factory: Copyable where Product: Copyable, Token: Copyable {} */
```

Notice that despite this `Factory` not storing any noncopyable data, it does not have an implicit unconditional `Copyable` conformance because one of its type parameters has suppressed its default `Copyable` constraint.
Instead, a conditional conformance was synthesized to make `Factory` copyable once those type parameters are `Copyable`.
To override this behavior, `Factory` should _explicitly_ state that it conforms to `Copyable`.

... ### TODO: add justification for relying on interface rather than storage / implementation details.
Will need to contrast this with Sendable, which does it via implementation details implicitly.

The synthesis procedure generates the `where` clause of the conditional `Copyable` conformance by enumerating _all_ of the type parameters and requiring each one to be `Copyable`.
It does not matter whether the parameter is used in the storage of the `Factory` struct.

It is an error if the parameterized type contains some noncopyable type other than one of its parameters.
In such a case, the `~Copyable` becomes required on the parameterized type:

```swift
struct TaggedFile<Tag: ~Copyable> {
  //                             ^
  //                             note: add ': ~Copyable' here
  let tag: Tag
  let fd: FileDescriptor // error: stored property 'fd' of 'Copyable'-conforming 
                        //         generic struct 'TaggedFile' has noncopyable
                        //         type 'FileDescriptor'
}
```

Control over the conformance synthesis behavior can be achieved in a few ways.
First, explicitly write a conformance to `Copyable` to make the type unconditionally copyable, while keeping the type parameter itself noncopyable:

```swift
struct AlwaysCopyableFactory<Product: ~Copyable, Token: ~Copyable>: Copyable {
  // signature <Product>
  func produce(_ payment: consuming Token) -> Product { /* ... */ }
}
```

Next, to disable the conditional conformance synthesis _and_ suppress the implicit `Copyable`, use `~Copyable` on the type instead:

```swift
struct ExplicitFactory<Product: ~Copyable, Token: ~Copyable>: ~Copyable {
  // signature <Product>
  func produce(_ payment: consuming Token) -> Product { /* ... */ }
}
```

After applying `~Copyable` to `ExplicitFactory` itself, it is possible to specify a custom conditional conformance to `Copyable` if desired:

```swift
extension ExplicitFactory: Copyable where Product: Copyable {}
```

This design is meant to strike a balance between brevity in the most common case (implicit conditional `Copyable` conformance) and expressivity (full control when explicit).

### Classes

Classes (including actors) and all of their generic parameters default to being `Copyable`:

```swift
class FileHandle<File> /* : Copyable where File: Copyable */ {
  var file: File
  // ...
}
```

To allow a class to contain a generic noncopyable value, use the inverse `~Copyable` on the type parameter:

```swift
class FileHandle<File: ~Copyable> /* : Copyable */ {
  var file: File
  // ...
}
```

Classes can contain noncopyable storage without themselves becoming noncopyable, i.e., the containment rule does not apply to classes.
As a result, a class does _not_ become conditionally copyable when one of its type parameters has the inverse `~Copyable`.
Support for noncopyable classes is left to future work.

### Protocols

Protocols and their associated types default to carrying an implicit `Copyable` conformance requirement:

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
The removal of the `Copyable` conformance requirement on `EventLog` allows copyable and noncopyable types to conform:

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

```swift
protocol EventLog: ~Copyable {
  associatedtype Event /* : Copyable */
  // ...
}

extension EventLog {
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

When inheriting a protocol that has suppressed its implicit Copyable constraint via `~Copyable`, that removal does _not_ carry-over to inheritors.
That means a type must restate `~Copyable` even if it inherits only from protocols using `~Copyable`, because the _absence_ of a requirement is not propagated:

```swift
protocol Token: ~Copyable {}

// signature <Self where Self : Token, Self : Copyable>
protocol ArcadeCoin: Token /* , Copyable */ {}

// signature <Self where Self : Token>
protocol CasinoChip: Token, ~Copyable {}
```

A key takeaway from the example above is that `~Copyable` as a constraint is not viral:
a protocol that has no `Copyable` constraint does _not_ mean its conformers cannot have the `Copyable` capability.
As a corollary, a protocol that inherits from a noncopyable one can still be `Copyable`.

Associated type requirements that are inherited from another protocol are taken as-is:

```swift
// signature <Self: Copyable>
protocol JobQueue /* : Copyable */ {
  associatedtype Job: ~Copyable
  // ...
}

// signature <Self where Self: Copyable, Self: JobQueue>
protocol FIFOJobQueue<Job>: JobQueue {
  func pushBack(_ j: Job) // error: missing ownership specifier for parameter of
                          //        noncopyable type 'Job'
}
```

In the above example, `JobQueue.Job` remains noncopyable in `FIFOJobQueue`.
The exception is if an associated type requirement with the same name is  redeclared in the inheritor.
In that case, the usual rule for `associatedtype` requirements will add an implicit `Copyable` requirement for the redeclaration:

```swift
// signature <Self where Self: JobQueue, Self.Job: Copyable>
protocol LIFOJobQueue<Event>: JobQueue {
  associatedtype Job /* : Copyable */
}
```

## Detailed Design

This section spells out additional details about the proposed extensions.

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

In other words, new top type is `any ~Copyable`.

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

## Effect on ABI stability

... ### TODO

## Effect on API resilience

... ### TODO

## Alternatives Considered

### `NonCopyable` as a Positive Requirement

Our proposal above adds `Copyable` to the Swift language as a default property of all types
and a default requirement in all generic contexts.
It then uses `~Copyable` to indicate that this default property and/or requirement should be suppressed.

In particular, this means that a `Copyable` type can be substituted for any generic argument
with a `~Copyable` annotation.
```
struct S<T: ~Copyable> { ... }
struct NC: ~Copyable { ... }

var s1: S<NC>  // OK.  NC is not Copyable
var s2: S<Int>  // OK.  Int is copyable
```
If you read `~Copyable` as "does not require Copyable",
then the two uses above can be seen to be consistent.

... ### TODO FIXME: Above is probably redundant with the rest of the proposal.
Reconsider it after the rest of the proposal is updated.

An alternative approach would instead add `NonCopyable` as a positive requirement.
In essence, `NonCopyable` would be the positive assertion that values of this type will
receive additional scrutiny inside the compiler:
```
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

## Future Directions

### `~Escapable`

The ability to "escape" the current context is another implicit capability
of all current Swift types.
Suppressing this requirement provides an alternative way to control object lifetimes.
A companion proposal will provide details.

### Non-copyable Classes

This proposal supports classes with generic parameters,
but it does not permit classes to be directly marked `~Copyable`.
Such classes could avoid essentially all reference-counting operations,
which could be a significant performance boost in practice.
We expect to explore this in a future proposal.

### Dynamic Queries and Runtime Support

The current implementation does not provide a mechanism to test at runtime whether
a value is copyable.
We expect to explore such support in a future proposal.

## Acknowledgments

Thank you to Joe Groff, Slava Pestov, and Ben Cohen for their feedback throughout the development of this proposal.
