# `ConcurrentValue` and `@concurrent` closures


* Proposal: [SE-0168](0168-multi-line-string-literals.md)
* Authors: [Chris Lattner](https://github.com/lattner), [Doug Gregor](https://github.com/douggregor)
* Review Manager: ?
* Status: **Draft**
* Implementation: [Doug's Pull Request](https://github.com/apple/swift/pull/35264)
* Major Contributors: Dave Abrahams, Paul Cantrell, Matthew Johnson, John McCall

## Introduction

The [Swift Concurrency Roadmap](https://forums.swift.org/t/swift-concurrency-roadmap/41611/) was recently announced, and a key goal of that roadmap is to “provide a mechanism for isolating state in concurrent programs to eliminate data races.”  Such a mechanism will be a major progression for widely used programming languages - most of them provide concurrent programming abstractions in a way that subjects programmers to a wide range of bugs, including race conditions, deadlocks and other problems.

This proposal describes an approach to address one of the challenging problems in this space - how to type check value passing between structured concurrency constructs and actors messages. As such, this is a unifying theory that provides some of the underlying type system mechanics that make them both safe and work well together.

This implementation approach involves marker protocols named `ConcurrentValue` and `UnsafeConcurrentValue`, as well as a `@concurrent` attribute that may be applied to functions.

## Motivation

Each actor instance and structured concurrency task in a program represents an “island of single threaded-ness”, which makes them a natural synchronization point that holds a bag of mutable state. These perform computation in parallel with other tasks, but we want the vast majority of code in such a system to be synchronization free -- building on the logical independence of the actor, and using its queue as a synchronization point for its data.

As such, a key question is: “when and how do we allow data to be transferred between concurrency domains?” Such transfers occur in arguments and results of actor method calls and tasks created by structured concurrency, for example.

The Swift Concurrency features aspire to build a safe and powerful programming model.  We want to achieve three things:

1. We want Swift programmers to get a static compiler error when they try to pass across concurrency domains that could introduce unprotected shared mutable state.
2. We want advanced programmers to be able to implement libraries with sophisticated techniques (e.g. a concurrent hash table) that can be used in a safe way by others.
3. We need to embrace the existing world, which contains a lot of code that wasn’t designed with the Swift Concurrency model in mind. We need a smooth and incremental migration story.

Before we jump into the proposed solution, let’s take a look at some common cases that we would like to be able to model along with the opportunities and challenges of each. This will help us reason about the design space we need to cover.


### 💖 Swift + Value Semantics

The first kind of type we need to support are simple values like integers. These can be trivially passed across concurrency domains because they do not contain pointers.

Going beyond this, Swift has a strong emphasis on types with [value semantics](https://en.wikipedia.org/wiki/Value_semantics), which are safe to transfer across concurrent boundaries. Except for classes, Swift’s mechanisms for type composition provide value semantics when their elements do. This includes generic structs, as well as its core collections: for example, `Dictionary&lt;Int, String>` can be directly shared across concurrency domains. Swift’s Copy on Write approach means that collections can be transferred without proactive data copying of their representations -- an extremely powerful fact that I believe will make the Swift concurrency model more efficient than other systems in practice.

However, everything isn’t simple here: the core collections can **not** be safely transferred across concurrency domains when they contain general class references, closures that capture mutable state, and other non-value types. We need a way to differentiate between the cases that are safe to transfer and those that are not.


### Value Semantic Composition

Structs, enums and tuples are the primary mode for composition of values in Swift. These are all safe to transfer across concurrency domain -- so long as the data they contain is itself safe to transfer.


### Higher Order Functional Programming

It is common in Swift and other languages with functional programming roots to use [higher-order programming](https://en.wikipedia.org/wiki/Higher-order_function), where you pass functions to other functions.  Functions in Swift are reference types, but many functions are perfectly safe to pass across concurrency domains - for example, those with an empty capture list, like a global function.

There are many useful reasons why you’d want to send bits of computation between concurrency domains in the form of a function - even trivial algorithms like `parallelMap` need this.  This occurs at larger scale as well -- for example, consider an actor example like this:


```
actor MyContactList { 
  func filteredElements(_ fn: (ContactElement) -> Bool) async
     -> [ContactElement] { … }
}
```

Which could then be used like so:

```
// Closures with no captures are ok!
list = await contactList.filteredElements { $0.firstName != "Max" }

// Capturing a 'searchName' string is ok, because strings are
// ok to pass across concurrency domains.
list = await contactList.filteredElements {
       [searchName] in $0.firstName == searchName
      }
```

We feel that it is important to enable functions to be passed across concurrency domains, but we are also concerned that we should not allow capturing local state _by reference_ in these functions, and we should not allow capturing unsafe things by value.  Both would introduce memory safety problems.


### Immutable Classes

One common and efficient design pattern in concurrent programming is to build immutable data structures - it is perfectly safe to transfer a reference to a class across concurrency domains if the state within it never mutates. This design pattern is extremely efficient (no synchronization beyond ARC is required), can be used to build [advanced data structures](https://en.wikipedia.org/wiki/Persistent_data_structure), and is widely explored by the pure-functional language community.


### Internally Synchronized Reference Types

A common design pattern in concurrent systems is for a class to provide a “thread-safe” API: they protect their state with explicit synchronization (mutexes, atomics, etc). Because the public API to the class is safe to use from multiple concurrency domains, the reference to the class can be directly transferred safely.

References to actor instances themselves are an example of this: they are safe to pass between concurrency domains by passing a pointer, since the mutable state within an actor is implicitly protected by the actor queue.


### “Transferring” Objects Between Concurrency Domains

A fairly common pattern in concurrent systems is for one concurrency domain to build up a data structure containing unsynchronized mutable state, then “hand it off” to a different concurrency domain to use by transferring the raw pointer. This is correct without synchronization if (and only if) the sender stops using the data that it built up - the result is that only the sender or receiver dynamically accesses the mutable state at a time.

There are both safe and unsafe ways to achieve this, e.g. see the discussion about “exotic” type systems in the “Alternatives Considered” section at the end.


### Deep Copying Classes

One safe way to transfer reference types is to make a deep copy of the data structures, ensuring that the source and destination concurrency domains each have their own copy of mutable state. This can be expensive for large structures, but is/was commonly used in some Objective-C frameworks.  General consensus is that this should be _explicit_, not something implicit in the definition of a type.


### Motivation Conclusion

This is just a sampling of patterns, but as we can see, there are a wide range of different concurrent design patterns in widespread use. The design center of Swift around value types and encouraging use of structs is a very powerful and useful starting point, but we need to be able to reason about the complex cases as well - both for communities that want to be able express high performance APIs for a given domain but also because we need to work with legacy code that won’t get rewritten overnight.

As such, it is important to consider approaches that allow library authors to express the intent of their types, it is important for app programmers to be able to work with uncooperative libraries retroactively, and it is also important that we provide safety as well as unsafe escape hatches so we can all just “get stuff done” in the face of an imperfect world that is in a process of transition.

Finally, our goal is for Swift (in general and in this specific case) to be a highly principled system that is sound and easy to use. In 20 years, many new libraries will be built for Swift and its ultimate concurrency model. These libraries will be built around value semantic types, but should also allow expert programmers to deploy state of the art techniques like lock-free algorithms, use immutable types, or whatever other design pattern makes sense for their domain. We want users of these APIs to not have to care how they are implemented internally.


## Proposed Solution + Detailed Design

The high level design of this proposal revolves around a `ConcurrentValue` marker protocol (and an `UnsafeConcurrentValue` refinement), adoption of `ConcurrentValue` by standard library types, and a new `@concurrent` attribute for functions.

Beyond the basic proposal, in the future it could make sense to add a set of adapter types to handle legacy compatibility cases, and first class support for Objective-C frameworks.  These are described in the following section.


### Marker Protocols

This proposal introduces the concept of a “marker” protocol, which indicates that the protocol has some semantic property but is entirely a compile-time notion that does not have any impact at runtime.  Marker protocols have the following restrictions:

*   They cannot have requirements of any kind.
*   They cannot inherit from non-marker protocols.
*   A marker protocol cannot be named as the type in an `is` or as? check (e.g., `x as? ConcurrentValue` is an error).

We think this is a generally useful feature, but believe it should be a compiler-internal feature for this round of proposal.  As such, we explain it and use this concept with the “`@_marker`” attribute syntax below.


### `ConcurrentValue` and `UnsafeConcurrentValue` Protocols

The core of this proposal are two marker protocols defined in the Swift standard library (these protocols have different conformance checking rules):


```
@_marker
protocol ConcurrentValue {}

@_marker
protocol UnsafeConcurrentValue: ConcurrentValue {}
```


It is a good idea for types to conform to the `ConcurrentValue` protocol when they are designed so all of their public API is safe to use across concurrency domains.  This is true for example, when there are no public mutators, if public mutators are implemented with COW, or if they are implemented with internal locking or some other mechanism.  Types may of course have internal implementation details based on local mutation if they have locking or COW as part of their public API.

The compiler rejects any attempts to pass data across concurrency domains, e.g. rejecting cases where the argument or result of an actor message send or structured concurrency call does not conform to the `ConcurrentValue` protocol:


```
actor SomeActor {
  // async functions are usable *within* the actor, so this
  // is ok to declare.
  func doThing(string: NSMutableString) async {...}
}

// ... but they cannot be called by other code not protected
// by the actor's queue:
func f(a: SomeActor, myString: NSMutableString) async {
  // error: 'NSMutableString' may not be passed across actors;
  //        it does not conform to 'ConcurrentValue'
  await a.doThing(string: myString)
}
```

The `ConcurrentValue` protocol models types that are allowed to be safely passed across concurrency domains by copying the value.  This includes value semantic types, references to immutable reference types, internally synchronized reference types, `@concurrent` closures, and potentially other future type system extensions for unique ownership etc.

Note that incorrect conformance to this protocol can introduce bugs in your program (just as an incorrect implementation of `Hashable` can break invariants), which is why the compiler checks conformance (see below).


#### Tuple conformance to `ConcurrentValue`

Swift has [hard coded conformances for tuples](https://github.com/apple/swift-evolution/blob/main/proposals/0283-tuples-are-equatable-comparable-hashable.md) to specific protocols, and this should be extended to `ConcurrentValue`, when the tuples elements all conform to `ConcurrentValue`.


#### Metatype conformance to `ConcurrentValue`

Metatypes (such as` Int.Type`, the type produced by the expression `Int.self`) always conform to `ConcurrentValue`, because they are immutable.


#### `[Unsafe]ConcurrentValue` Conformance Checking for structs and enums

`ConcurrentValue` types are extremely common in Swift and aggregates of them are also safe to transfer across concurrency domains.  As such, the Swift compiler allows direct conformance to `ConcurrentValue` for structs and enums that are compositions of other `ConcurrentValue` types:


```
struct MyPerson : ConcurrentValue { var name: String, age: Int }
struct MyNSPerson { var name: NSMutableString, age: Int }

actor SomeActor {
  // Structs and tuples are ok to send and receive!
  public func doThing(x: MyPerson, y: (Int, Float)) async {..}

  // error if called across actor boundaries: MyNSPerson doesn't conform to ConcurrentValue!
  public func doThing(x: MyNSPerson) async {..}
}
```


While this is convenient, we would like to slightly increase friction of protocol adoption for cases that require more thought.  As such,  the compiler rejects conformance of structs and enums to the `ConcurrentValue` protocol when one of their members (or associated values) does not itself conform to `ConcurrentValue` (or is not known to conform to `ConcurrentValue` through a generic constraint):


```
// error: MyNSPerson cannot conform to ConcurrentValue due to NSMutableString member.
// note: use UnsafeConcurrentValue if you know what you're doing.
struct MyNSPerson : ConcurrentValue {
  var name: NSMutableString
  var age: Int
}

// error: MyPair cannot conform to ConcurrentValue due to 'T' member which may not itself be a ConcurrentValue
// note: see below for use of conditional conformance to model this
struct MyPair<T> : ConcurrentValue {
  var a, b: T
}

// use conditional conformance to model generic types
struct MyCorrectPair<T> {
  var a, b: T
}

extension MyCorrectPair: ConcurrentValue where T: ConcurrentValue { }
```

As mentioned in the compiler diagnostic, any type can override this behavior by conforming to the `UnsafeConcurrentValue` protocol to affect the same result, with a more explicit syntax. Any struct, enum or class may conform to `UnsafeConcurrentValue` (and thus ConcurrentValue) to indicate that they may be safely passed across concurrency domains.

This approach follows the precedent of [SE-0185](https://github.com/apple/swift-evolution/blob/main/proposals/0185-synthesize-equatable-hashable.md), [SE-0266](https://github.com/apple/swift-evolution/blob/main/proposals/0266-synthesized-comparable-for-enumerations.md), and [SE-0283](https://github.com/apple/swift-evolution/blob/main/proposals/0283-tuples-are-equatable-comparable-hashable.md) which uses explicit conformance to direct compiler behavior.  An alternative design would be to make conformance _implicit_ for all types that structurally conform.  Please see “Alternatives Considered” at the end of this proposal for more discussion about this.


#### `[Unsafe]ConcurrentValue` Conformance Checking for classes

Any type may explicitly conform to `UnsafeConcurrentValue` (and thus implicitly conform to `ConcurrentValue`) without compiler checking, including classes.  However, subclassing and resilience makes conformance checking for classes more complicated.  Consider a type like this:


```
// error: classes may not conform to ConcurrentValue
// note: use UnsafeConcurrentValue if you know what you're doing.
class MyClass : ConcurrentValue {
  let state: String
}
```

It would be unsafe for the compiler to allow this, because a subclass could have mutable state.  Furthermore, even final classes can have members added and removed from them in API stable ways due to resilience.  In future work, we could allow classes that are `final` and `@frozen` to conform to `ConcurrentValue` if all of their members and their base class conform to `ConcurrentValue`.  We defer consideration of this to future work to simplify this proposal, get more experience with the model, and understand the needs better.

This behavior discourages incorrect and unsafe sharing of mutable reference semantic state:

```
// error: classes may not conform to ConcurrentValue
// note: use UnsafeConcurrentValue if you know what you're doing.
extension NSMutableString : ConcurrentValue {}
```

While this is a possible bug, Swift doesn’t define away all classes of bugs, and this is a relatively obscure thing to do.  Allowing reference types to conform to `UnsafeConcurrentValue` allows advanced types to work nicely with the concurrency system, e.g. those that are internally synchronized or immutable by definition.

#### Adoption of `ConcurrentValue` by Standard Library Types

It is important for standard library types to be passed across concurrency domains, but they are typically implemented in terms of builtin LLVM types.  As such, standard library types like `Int` and `String` need to conform to `UnsafeConcurrentValue`:

```
extension Int : UnsafeConcurrentValue {}
extension String : UnsafeConcurrentValue {}
// … etc.
```

Similarly, conditional conformances for various collection and optional types can be defined naturally:

```
extension Array : ConcurrentValue where Element : ConcurrentValue {}
```

All actors references are themselves safely modeled as `ConcurrentValue`, so the compiler implicitly treats them as though they conform to `ConcurrentValue`.

Note that `UnsafeMutablePointer` and `UnsafeBufferPointer` are highly debatable - there are good arguments for marking them as `UnsafeConcurrentValue` types, but we believe that it is fine to consider that in a follow-on proposal.

### New `@concurrent` attribute for functions

While the `ConcurrentValue` protocol directly addresses value types and allows classes to opt-in to participation with the concurrency system, function types are also important reference types that cannot currently conform to protocols. Functions in Swift occur in several forms, including global func declarations, nested functions, accessors (getters, setters, subscripts, etc), and closures.  It is useful and important to allow functions to be passed across concurrency domains where possible to allow higher order functional programming techniques in the Swift Concurrency model, for example to allow definition of `parallelMap` and other obvious concurrency constructs.

We propose defining a new attribute on function types named `@concurrent`.   A `@concurrent` function type is safe to transfer across concurrency domains (and thus, it implicitly conforms to the `ConcurrentValue` protocol).  To ensure memory safety, the compiler checks several things about values (e.g. closures and functions) that have `@concurrent` function type:

1. Functions have `@concurrent` function type if their parameter and result types all conform to `ConcurrentValue`, they capture no values (e.g. global functions and closures / nested functions with no captures), and have no `inout` arguments.
2. Closures that have `@concurrent` function type are checked to ensure their parameter and result types all conform to `ConcurrentValue`.  Furthermore, they implicitly capture local values by-value (which are immutable like a `let` value) and require that the captured values conform to `ConcurrentValue`.
3. Nested functions declarations that close over values may be marked with the `@concurrent` attribute (`@concurrent func local() {}`), given them a `@concurrent` function type.  This causes them to obey the same rules as `@concurrent` closures, diagnosing cases where they try to capture non-`ConcurrenValue` values or mutate captured values.
4. Accessors are not currently allowed to participate with the `@concurrent` system as of this proposal.  It would be straight-forward to allow getters to do so in a future proposal if there was demand for this.

The `@concurrent` attribute to function types is orthogonal to the existing `@escaping` attribute, but it works the same way.  `@concurrent` functions are always subtypes of non-`@concurrent` functions, and implicitly downconvert when needed.  Similarly, closure expressions infer the `@concurrent` bit from context just like `@escaping` closures do.

We can revisit the example from the motivation section -- it may be declared like this:


```
actor MyContactList { 
  func filteredElements(_ fn: @concurrent (ContactElement) -> Bool) async -> [ContactElement] { … }
}
```

Which could then be used like so:

```
// Closures with no captures are ok!
list = await contactList.filteredElements { $0.firstName != "Max" }

// Capturing a 'searchName' string is ok, because String conforms
// to ConcurrentValue.  searchName is captured by value implicitly.
list = await contactList.filteredElements { $0.firstName == searchName }

// @concurrent is part of the type, so passing a compatible
// function declaration works as well.
list = await contactList.filteredElements(dynamicPredicate)

// Error: cannot capture NSMutableString in a @concurrent closure!
list = await contactList.filteredElements {
  $0.firstName == nsMutableName
}

// Error: someLocalInt is immutable because it was captured
// by-value in a @concurrent closure!
var someLocalInt = 1
list = await contactList.filteredElements { 
  someLocalInt += 1
  return $0.firstName == searchName 
}
```


The combination of `@concurrent` closures and `ConcurrentValue` types allows type safe concurrency that is library extensible, while still being easy to use and understand.  Both of these concepts are key foundations that actors and structured concurrency builds on top of.


#### Inference of `@concurrent` for Closure Expressions

The inference rule for `@concurrent` attribute for closure expressions is exactly the same as for closure `@escaping` inference.  A closure expression is inferred to be `@concurrent` if:



*   It is used in a context that expects a `@concurrent` function type (e.g. `parallelMap` or `Task.runDetached`).
*   When `@concurrent` is in the closure “in” specification.

Nested functions are also an important consideration, because they can also capture values just like a closure expression.  We propose requiring the `@concurrent` attribute on nested function declarations:


```
func globalFunction(arr: [Int]) {
  var state = 42 

  // Error, 'state' is captured immutably because closure is @concurrent.
  arr.parallelForEach { state += $0 }

  // Ok, function captures 'state' by reference.
  func mutateLocalState1(value: Int) {
    state += value
  }

  // Error: non-@concurrent function isn't convertible to @concurrent function type.
  arr.parallelForEach(mutateLocalState1)

  @concurrent
  func mutateLocalState2(value: Int) {
    // Error: 'state' is captured as a let because of @concurrent
    mutableState += value
  }

  // Ok, mutateLocalState2 is @concurrent.
  arr.parallelForEach(mutateLocalState2)
}
```


This composes cleanly for both structured concurrency and actors.

#### Interaction of Actor self and `@concurrent` closures

Actors are a proposal that is conceptually layered on top of this one, but it is important to be aware of the actor design to make sure that this proposal addresses its needs.  As described above, actor method sends across concurrency boundaries naturally require that arguments and results conform to `ConcurrentValue`, and thus implicitly require that closures passed across such boundaries are `@concurrent`.

One additional detail that needs to be addressed is “when is something a cross actor call?”.  For example, we would like these calls to be synchronous and not require an await:

```
extension SomeActor {
  public func oneSyncFunction(x: Int) {... }
  public func otherSyncFunction() {
    // No await needed: stays in concurrency domain of self actor.
    self.oneSyncFunction(x: 42)
    oneSyncFunction(x: 7)    // Implicit self is fine.
  }
}
```

However, we also need to consider the case when ‘self’ is captured into a closure within an actor method.  For example:

```
extension SomeActor {
  public func thing(arr: [Int]) {
    // This should obviously be allowed!
    a.forEach { self.oneSyncFunction(x: $0) }

    // Error: await required because it hops concurrency domains.
    a.parallelMap { self.oneSyncFunction(x: $0) }

    // Is this ok?
    someHigherOrderFunction {
      self.oneSyncFunction(x: 7)  // ok or not?
    }
  }
}
```

We need the compiler to know whether there is a possible concurrency domain hop or not - if so, an await is required.  Fortunately, this works out through straight-forward composition of the basic type system rules above: It is perfectly safe to use actor `self` in a non-`@concurrent` closure in an actor method, but using it in a `@concurrent` closure is treated as being from a different concurrency domain, and thus requires an `await`.

## Future Work / Follow-on Projects

In addition to the base proposal, there are several follow-on things that could be explored as follow-on proposals.


### Adaptor Types for Legacy Codebases

**NOTE**: This section is NOT considered part of the proposal - it is included just to illustrate aspects of the design.

The proposal above provides good support for composition and Swift types that are updated to support concurrency.  Further, Swift’s support for retroactive conformance of protocols makes it possible for users to work with codebases that haven’t been updated yet.

However, there is an additional important aspect of compatibility with existing frameworks that is important to confront: frameworks are sometimes designed around dense graphs of mutable objects with ad hoc structures.  While it would be nice to “rewrite the world” eventually, practical Swift programmers will need support to “get things done” in the meantime.  By analogy, when Swift first came out, most Objective-C frameworks were not audited for nullability.  We introduced “`ImplicitlyUnwrappedOptional`” to handle the transition period, which gracefully faded from use over the years.

To illustrate how we can do this with Swift concurrency, consider a pattern that is common in Objective-C frameworks: passing an object graph across threads by “transferring” the reference across threads - this is useful but not memory safe!  Programmers will want to be able to express these things as part of their actor APIs within their apps.

This can be achieved by the introduction of a generic helper struct:

```
@propertyWrapper
struct UnsafeTransfer<T: AnyObject> : UnsafeConcurrentValue {
  var wrappedValue: T
  init(wrappedValue: Wrapped) {
    self.wrappedValue = wrappedValue
  }
}
```

For example, `NSMutableDictionary` isn’t safe to pass across concurrency domains, so it isn’t safe to conform to `ConcurrentValue`.  The struct above allows you (as an app programmer) to write an actor API in your application like this:

```
actor MyAppActor {
  // The caller *promises* that it won't use the transferred object.
  public func doStuff(dict: UnsafeTransfer<NSMutableDictionary>) async
}
```

While this isn’t particularly pretty, it is effective at getting things done on the caller side when you need to work with unaudited and unsafe code.  This can also be sugared into a parameter attribute using the recently proposed [extension to property wrappers for arguments](https://forums.swift.org/t/pitch-2-extend-property-wrappers-to-function-and-closure-parameters/40959), allowing a prettier declaration and caller-side syntax:

```
actor MyAppActor {
  // The caller *promises* that it won't use the transferred object.
  public func doStuff(@UnsafeTransfer dict: NSMutableDictionary) async
}
```

### Objective-C Framework Support

**NOTE**: This section is NOT considered part of the proposal - it is included just to illustrate aspects of the design.

Objective-C has established patterns that would make sense to pull into this framework en-masse, e.g. the `[NSCopying protocol](https://developer.apple.com/documentation/foundation/nscopying)` is one important and widely adopted protocol that should be onboarded into this framework.

General consensus is that it is important to make copies explicit in the model, so we can implement an `NSCopied` helper like so:

```
@propertyWrapper
struct NSCopied<Wrapped: NSCopying>: UnsafeConcurrentValue {
  let wrappedValue: Wrapped

  init(wrappedValue: Wrapped) {
    self.wrappedValue = wrappedValue.copy() as! Wrapped
  }
}
```

This would allow individual arguments and results of actor methods to opt-into a copy like this:

```
actor MyAppActor {
  // The string is implicitly copied each time you invoke this.
  public func lookup(@NSCopied name: NSString) -> Int async
}
```

One random note: the Objective-C static type system is not very helpful to us with immutability here: statically typed `NSString`’s may actually be dynamically `NSMutableString`’s due to their subclass relationships.  Because of this, it isn’t safe to assume that values of `NSString` type are dynamically immutable -- they should be implemented to invoke the `copy()` method.

## Source Compatibility

This is fully source compatible with existing code bases - it is a purely additive proposal.  Furthermore, by including this in “Swift Concurrency 1.0,” it eliminates a major source break in “Swift Concurrency 2.0” that would be required to lock down on what is passed across concurrency domains.

## Effect on API resilience

This proposal has no effect on API resilience!

## Alternatives Considered

There are several alternatives that make sense to discuss w.r.t. this proposal.  Here we capture some of the bigger ones.

### Implicit struct/enum Conformance to `ConcurrentValue`

Early in the discussion, a few people objected to the boilerplate “: ConcurrentValue” conformance syntax for types that should “obviously” conform (e.g. a struct with two `Int`s in it):

```
struct MyPerson2 { // Implicitly conforms to ConcurrentValue!
  var name: String, age: Int
}
```

While initially appealing to some, this proposal aligns with strong precedent in the Swift ecosystems (e.g. `Hashable`, `Equatable`, `Codable`, etc) which all require explicit conformance.  We use the following rationale:

*   Consistency with existing protocols is important, and the same boilerplate argument applies to `Hashable`, `Equatable`, etc.  This was discussed during their review.
*   Implicit conformance is a problem for API resilience, because adding a new non-`ConcurrentValue` member to a type would cause it to drop conformance to `ConcurrentValue`.  Adding members to a struct is not meant to be source-breaking by default.
*   Explicit conformances give you a [compiler error eagerly](https://forums.swift.org/t/pitch-protocol-based-actor-isolation/41677/7) if you define a struct with non-concurrent things, encouraging you to think about safety.  With implicit conformances you only get the error when trying to send it across concurrency domains.
*   If we decide that the boilerplate is too heavy, we can always add implicit conformances in the future.  In contrast, starting with implicit conformances and then removing them would be source breaking.
*   Not all struct/enum compositions of `ConcurrentValue` types are themselves concurrency safe ([examples](https://forums.swift.org/t/pitch-2-protocol-based-actor-isolation/42123/6)), so implicit conformance would require a way to disable autosynthesis, making the proposal more complicated.

### Exotic Type System Features

The [Swift Concurrency Roadmap](https://forums.swift.org/t/swift-concurrency-roadmap/41611) mentions that a future iteration of the feature set could introduce new type system features like `mutableIfUnique` classes, and it is easy to imagine that move semantics and unique ownership could get introduced into Swift someday. 

While it is difficult to understand the detailed interaction without knowing the full specification of future proposals, we believe that the checking machinery that enforces `ConcurrentValue` checking is simple and composable.  It should work with any types that are safe to pass across concurrency boundaries.


### Support an explicit copy hook

The [first revision of this proposal](https://docs.google.com/document/d/1OMHZKWq2dego5mXQtWt1fm-yMca2qeOdCl8YlBG1uwg/edit#) allowed types to define custom behavior when they are sent across concurrency domains, through the implementation of an `unsafeSend` protocol requirement.  This increased the complexity of the proposal, admitted undesired functionality (explicitly implemented copy behavior), made the recursive aggregate case more expensive, and would result in larger code size.


### Do Not Enforce Transfers in “Swift Concurrency 1.0”

The [initial proposal for the actor system](https://forums.swift.org/t/concurrency-actors-actor-isolation/41613/) suggests that we launch “Swift Concurrency 1.0” without any enforcement of value transfers across concurrency domains, then later introduce a “Swift Concurrency 2.0” system that locks this down.

That approach has several downsides compared to this proposal:

1. The “Swift Concurrency 1.0” code would miss key memory safety checking - which is the primary stated goal of the Swift Concurrency model.
2. “Swift Concurrency 2.0” will be significantly source incompatible with “Swift Concurrency 1.0” and will put the Swift community through a very difficult and unnecessary migration.  
3. The expressiveness of the new type system is not well explored and it certainly does not cover all of the cases in this proposal -- we will probably require something like this anyway.

The model proposed here is simple and builds on core features of the existing Swift language, so it is best to adopt these checks in the first revision of the proposal.


## Conclusion

This proposal defines a very simple approach for defining types that are safe to transfer across concurrency domains.  It requires minimal compiler/language support that is consistent with existing Swift features, is extensible by users, works with legacy code bases, and provides a simple model that we can feel good about even 20 years from now.

Because the feature is mostly a library feature that builds on existing language support, it is easy to define wrapper types that extend it for domain specific concerns (along the lines of the `NSCopied` example above), and retroactive conformance makes it easy for users to work with older libraries that haven’t been updated to know about the Swift Concurrency model yet.
