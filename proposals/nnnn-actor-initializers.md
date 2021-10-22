# Actor Initializers and Deinitializers

* Proposal: [SE-NNNN](NNNN-actor-initializers.md)
* Authors: [Kavon Farvardin](https://github.com/kavon), [John McCall](https://github.com/rjmccall), [Konrad Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Partially implemented in `main`.**
* Previous Discussions:
  * [On Actor Initializers](https://forums.swift.org/t/on-actor-initializers/49001)
  * [Deinit and MainActor](https://forums.swift.org/t/deinit-and-mainactor/50132)

<!-- *During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md) -->

**Table of Contents**

<!-- @import "[TOC]" {cmd="toc" depthFrom=1 depthTo=6 orderedList=false} -->

<!-- code_chunk_output -->

- [Actor Initializers and Deinitializers](#actor-initializers-and-deinitializers)
  - [Introduction](#introduction)
  - [Background](#background)
  - [Motivation](#motivation)
    - [Initializer Races](#initializer-races)
    - [Stored Property Isolation](#stored-property-isolation)
    - [Initializer Delegation](#initializer-delegation)
  - [Proposed solution](#proposed-solution)
    - [Problem 1: Initializer Data Races](#problem-1-initializer-data-races)
      - [Applying the Escaping-use Restriction](#applying-the-escaping-use-restriction)
    - [Problem 2: Stored Property Isolation](#problem-2-stored-property-isolation)
    - [Problem 3: Initializer Delegation](#problem-3-initializer-delegation)
    - [Summary](#summary)
  - [Source compatibility](#source-compatibility)
  - [Alternatives considered](#alternatives-considered)
    - [Deinitializers](#deinitializers)
    - [Flow-sensitive actor isolation](#flow-sensitive-actor-isolation)
    - [Removing the need for `convenience`](#removing-the-need-for-convenience)
  - [Effect on ABI stability](#effect-on-abi-stability)
  - [Effect on API resilience](#effect-on-api-resilience)
  - [Acknowledgments](#acknowledgments)

<!-- /code_chunk_output -->


## Introduction

Actors are a relatively new nominal type in Swift that provides data-race safety for its mutable state.
The protection is achieved by _isolating_ the mutable state of each actor instance to at most one task at a time.
The proposal that introduced actors ([SE-0306](https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md)) is quite large and detailed, but misses some of the subtle aspects of creating and destroying an actor's isolated state.
This proposal aims to shore up the definition of an actor, to clarify *when* the isolation of the data begins and ends for an actor instance, along with *what* can be done inside the body of an actor's `init` and `deinit` declarations.

## Background

To get the most out of this proposal, it is important to review the existing behaviors of initializer and deinitializer declarations in Swift.

As with classes, actors support both synchronous and asynchronous initializers, along with a customizable deinitializer, like so:

```swift
actor Database {
  var rows: [String]

  init() { /* ... */ }
  init(with: [String]) async { /* ... */ }
  deinit { /* ... */ }
}
```

An actor's initializer respects the same fundamental rules surrounding the use of `self` as other nominal types: until `self`'s stored properties have all been initialized to a value, `self` is not a fully-initialized instance.
This concept of values being *fully-initialized* before use is a fundamental invariant in Swift.
To prevent uses of ill-formed, incomplete instances of `self`, the compiler restricts `self` from escaping the initializer until all of its stored properties are initialized:

```swift
actor Database {
  var rows: [String]

  func addDefaultData(_ data: String) { /* ... */ }
  func addEmptyRow() { rows.append(String()) }

  init(with data: String?) {
    if let data = data {
      self.rows = []
      // -- self fully-initialized here --
      addDefaultData(data) // OK
    }
    addEmptyRow() // error: 'self' used in method call 'addEmptyRow' before all stored properties are initialized
  }
}
```

In this example, `self` escapes the initializer through the call to its method `addEmptyRow` (all methods take `self` as an implicit argument). But this call is flagged as an error, because it happens before `self.rows` is initialized _on all paths_ to that statement from the start of the initializer's body. Namely, if `data` is `nil`, then `self.rows` will not be initialized prior to it escaping from the initializer.
Stored properties with default values can be viewed as being initialized immediately after entering the `init`, but prior to executing any of the `init`'s statements.

Determining whether `self` is fully-initialized is a flow-sensitive analysis performed by the compiler. Because it's flow-sensitive, there are multiple points where `self` becomes fully-initialized, and these points are not explicitly marked in the source program. In the example above, there is only one such point, immediately after the rows are assigned to `[]`. Thus, it is permitted to call `addDefaultData` right after that assignment statement within the same block, because all paths leading to the call are guaranteed to have assigned `self.rows` beforehand. Keep in mind that these rules are not unique to actors, as they are enforced in initializers for other types like structs and classes.
 

## Motivation

While there is no existing specification for how actor initialization and deinitialization *should* work, that in itself is not the only motivation for this proposal.
The *de facto* expected behavior, as induced by the existing implementation, is also problematic. In summary, the issues include:

  1. Initializers can exhibit data races due to ambiguous isolation semantics.
  2. Stored properties can have an isolation that differs from the isolation of the type's initializers.
  3. *Minor:* Initializer delegation requires the use of the `convenience` keyword like classes, even though actors do not support inheritance. Is this attribute still needed? If so, what is the isolation of an actor's convenience initializer?

The following subsections will discuss these three high-level problems in more detail.

### Initializer Races

Unlike other synchronous methods of an actor, a synchronous (or "ordinary") `init` is special in that it is treated as being `nonisolated` from the outside, meaning that there is no `await` (or actor hop) required to call the `init`. This is because an `init`'s purpose is to bootstrap a fresh actor-instance, called `self`. Thus, at various points within the `init`'s body, `self` is considered a fully-fledged actor instance whose members must be protected by isolation. The existing implementation of actor initializers does not perform this enforcement, leading to data races with the code appearing in the `init`:

```swift
actor StatsTracker {
  var counter: Int

  init(_ start: Int) {
    self.counter = start
    // -- self fully-initialized here --
    Task.detached { await self.tick() }
    
    // ... do some other work ...
    
    if self.counter != start { // 💥 race
      fatalError("state changed by another thread!")
    }
  }

  func tick() {
    self.counter = self.counter + 1
  }
}
```

This example exhibits a race because `self`, once fully-initialized, is ready to provide isolated access to its members, i.e., it does *not* start in a reserved state. Isolated access is obtained by "hopping" to the executor corresponding to `self` from an asynchronous function. But, because `init` is synchronous, a hop to `self` fundamentally cannot be performed. Thus, once `self` is initialized, the remainder of the `init` is subject to the kind of data race that actors are meant to eliminate.

If the `init` in the previous example were only changed to be `async`, this data race still does not go away. The existing implementation does not perform a hop to `self` in such initializers, even though it now could to prevent races. This is not just a bug that has a straightforward fix, because if an asynchronous actor `init` were isolated to the `@MainActor`: 

```swift
class ConnectionStatusDelegate {
  @MainActor
  func connectionStarting() { /**/ }

  @MainActor
  func connectionEstablished() { /**/ }
}

actor ConnectionManager {
  var status: ConnectionStatusDelegate
  var connectionCount: Int

  @MainActor
  init(_ sts: ConnectionStatusDelegate) async {
    // --- on MainActor --
    self.status = sts
    self.status.connectionStarting()
    self.connectionCount = 0
    // --- self fully-initialized here ---
    
    // ... connect ...
    self.status.connectionEstablished()
  }
}
```

then which executor should be used? Should it be valid to isolate an actor's `init` to a global actor, such as the `@MainActor`, to ensure that the right executor is used for the operations it performs? The example above serves as a possible use case for that capability: being able to perform the initialization while on `@MainActor` so that the `ConnectionStatusDelegate` can be updated without any possibility of suspension (i.e., no `await` needed). 

The existing implementation makes it impossible to write a correct `init` for the example above, because 
the `init` is considered to be entirely isolated to the `@MainActor`. Thus, it's not possible to initialize `self.status` _at all_. It's not possible to `await` and hop to `self`'s executor to perform an assignment to `self.status`, because `self` is not a fully-initialized actor-instance yet!

### Stored Property Isolation

The stored properties of classes, structs, and enums are currently permitted to have global-actor isolation applied to them. But, this creates a problems for both initialization and deinitialization. For example, when users specify a default value for the stored property, those default values are evaluated by the non-delegating initializer of a nominal type:

```swift
@MainActor func getStatus() -> Int { /* ... */ }
@PIDActor func genPID() -> ProcessID { /* ... */ }

class Process {
  @MainActor var status: Int = getStatus()
  @PIDActor var pid: ProcessID = genPID()
  
  init() {} // Problem: what is the isolation of this init?
  
  init() async {} // Problem: no `await` is written to acknowledge
                  // that to initialize `status` and `pid`, an
                  // async call would be required.

  deinit {
    // Problem: how do we release the resources contained
    // in our global-actor isolated stored properties from 
    // a deinit, which can never be actor-isolated?
  }
}
```

In the example above, because `status` and `pid` are isolated to two different global-actors, there's no single actor-isolation that can be specified for the synchronous `init`.
In fact, all non-delegating initializers would need to have the same isolation as all stored properties.
For the asynchronous `init`, the fact that a suspension may occur is not explicit in the program, because no `await` is needed on the right-hand side expression of the property declaration's assignment.
Finally, even if the isolation of the initializers and stored properties matched, the deinit still can _never_ access the stored properties in order to invoke clean-ups routines, without using unsafe lifetime extensions of the actor from the `deinit`.

### Initializer Delegation

All nominal types in Swift, except actors, explicitly support initializer delegation, which is when one initializer calls another one to perform initialization.
For classes, initializer [delegation rules](https://docs.swift.org/swift-book/LanguageGuide/Initialization.html#ID216) are complex due to the presence of inheritance.
So, classes have a required and explicit `convenience` modifier to make, for example, a distinction between initializers that *must* delegate and those that do not.
In contrast, value types do *not* support inheritance, so [the rules](https://docs.swift.org/swift-book/LanguageGuide/Initialization.html#ID215) are much simpler: any `init` can delegate, but if it does, then it must delegate or assign to `self` in all cases:

```swift
struct S {
  var x: Int
  init(_ v: Int) { self.x = v }
  init(b: Bool) {
    if b {
      self.init(1)
    } else {
      self.x = 0 // error: 'self' used before 'self.init' call or assignment to 'self'
    }
  }
}
```

Actors, which are reference types (like a classes), do not support inheritance. But, currently they must use the `convenience` modifier on an initializer to perform any delegation. Is this modifier still needed?

<!-- TODO: look into NSObject-inheriting actors and other funky stuff -->

## Proposed solution

The previous sections described problems with the current state of actor initialization and deinitialization, as listed in the introduction of the Motivation section.
The remainder of this section details the proposed solution to those problems.

### Problem 1: Initializer Data Races

This proposal aims to eliminate data races through the selective application of a usage restriction on `self` in an actor's initializer.
For this discussion, an _escaping use of `self`_ means that a copy of `self` is exposed outside of the actor's initializer, before the initializer has finished.
By rejecting programs with escaping uses of `self`, there is no way to construct the data race described earlier.

> **NOTE:** Preventing `self` from escaping the `init` directly resolves the data race, because it forces the unique reference `self` to stay on the current thread until the completion of the `init`.
Specifically, the only way to create a race is for there to be at least two copies of the reference `self`.
Since a secondary thread can only gain access to a copy of `self` by having it "escape" the `init`, preventing the escape closes the possibility of a race.

An actor's initializer that obeys the escaping-use restriction means that the following are rejected throughout the entire initializer:

- Capturing `self` in a closure.
- Calling a method or computed property on `self`.
- Passing `self` as any kind of argument, whether by-value, `autoclosure`, or `inout`.

The escaping-use restriction is not a new concept in Swift: for all nominal types, a very similar kind of restriction is applied to `self` until it becomes fully-initialized.

#### Applying the Escaping-use Restriction

If an actor's non-delegating initializer is synchronous or isolated to a global-actor, then it must obey the escaping-use restriction.
This leaves only the instance-isolated `async` actor initializer, and all delegating initializers, as being free from this new restriction.

For a synchronous initializer, we cannot reserve the actor's executor by hopping to it from a synchronous context.
Thus, the need for the restriction is clear: the only way to prevent simultaneous access to the actor's state is to prevent another thread from getting a copy of `self`.
In contrast, an instance-isolated `async` initializer _will_ perform that hop immediately after `self` is fully-initialized in the `init`, so no restriction is applied.

For a global-actor isolated initializer, the need for the escaping-use restriction is a bit more subtle.
In Swift's type system, a declaration cannot be isolated to _two_ actors at the same time.
Because the programmer has to opt-in to global-actor isolation, it takes precedence when appearing on the `init` of an actor type and will be respected.
In such cases, protection for the `self` actor instance, after it is fully-initialized, is provided by the escaping-use restriction.
This means that, within an `init` isolated to some global-actor `A`, the stored properties of `self` belonging to a different actor `B` can be accessed *without* synchronization.
Thus, the `ConnectionManager` example from earlier will work as-is, because only stored properties of the actor-instance `self` are accessed.

### Problem 2: Stored Property Isolation

Actor-isolation on a stored property only prevents concurrent access to the storage for the value, and not subsequent accesses.
For example, if `pid` is an actor-isolated stored property, then the access `p.pid.reset()` only protects the access of `pid` from `p`, and not the call to `reset` afterwards.
Thus, for value types (enums and structs), global-actor isolation on stored properties serves virtually no use: mutations of stored properties in value types can never race (due to copy-on-write semantics).

The [Global actors proposal](se316) explicitly excludes actor types from having stored properties that are global-actor isolated.
The only nominal type left in Swift to consider are classes. For a class, the benefit of global-actor isolated stored properties is to prevent races during an access. But, because a `deinit` cannot be made `async`, and it is undefined behavior for a class value's lifetime to extend beyond the invocation of a `deinit`, there would be no way to access the stored property during a `deinit`.

In summary, the most straightforward solution to the problems described earlier is: global-actor isolation should not apply to the stored properties appearing within _any_ nominal type.


### Problem 3: Initializer Delegation

Next, one of the key downsides of the escaping-use restriction is that it becomes impossible to invoke a method in the time *after* `self` is fully-initialized, but *before* a non-delegating `init` returns.
This pattern is important, for example, to organize set-up code that is needed both during initialization and the lifetime of the instance:

```swift
actor A {
  var friends: [A]

  init(withFriends fs: [A]) {
    friends = fs
    self.notifyAll()  // ❌ disallowed by escaping-use restriction.
  }

  @MainActor
  init() {
    friends = ...
    self.notifyAll()  // ❌ disallowed by escaping-use restriction.
  }

  func verify() { ... }
  func notifyAll() { ... }
}
```

Another important observation is that an isolated initializer that performs delegation is not particularly useful.
A delegating initializer that is synchronous would still need to obey the escaping-use restriction, but now they also must first call some other `init` on all paths.
But, _because_ an `init` must be called first on all paths of a delegating `init`, such an initializer has an explicit point where `self` is fully-initialized.
This provides an excellent opportunity to perform _follow-up work_, after `self` is fully-initialized, but before completely returning from initialization.
To do the follow-up work in a delegating init, we must be in a context that is not isolated to the actor instance, because the initialized instance's executor starts in an unreserved state.
In addition, because _all_ initializers are viewed as `nonisolated` from the outside, an entire body of the delegating initializer can be cleanly treated as `nonisolated`!

For ABI compatibility reasons with Swift 5.5, and to make the implicit `nonisolated` semantics clear, this proposal keeps the `convenience` modifier for actor initializers, as a way to mark initializers that _must_ delegate.
If a programmer marks a convenience initializer with `nonisolated`, a warning will be emitted that says it is a redundant modifier, since `convenience` implies `nonisolated`.
Global-actor isolation of a `convenience` init is allowed, and will override the implicit `nonisolated` behavior.
Rewriting the above with this new rule would look like this:

```swift
// NOTE: Task.detached is _not_ an exact substitute for this.
// It is expected that Custom Executors will provide a capability
// that implements this function, which atomically enqueues a paused task
// on the target actor before returning.
func spawnAndEnqueueTask<A: AnyActor>(_ a: A, _ f: () -> Void) { ... }

actor A {
  var friends: [A]

  private init(with fs: [A]) {
    friends = fs
  }

  // Version 1: synchronous delegating initializer
  convenience init() {
    self.init(with: ...)
    // ✅ self can be captured by closure, or passed as argument
    spawnAndEnqueueTask(self) {
      await self.notifyAll()
    }
  }

  // Version 2: asynchronous delegating initializer
  convenience init(withFakeFriends f: Double) async {
    if f < 0 {
      self.init()
    } else {
      self.init(with: manufacturedFriends(count: Int(f)))
      await self.notifyAll()
    }
    await self.verify()
  }

  // Version 3: global-actor isolated inits can also be delegating.
  @MainActor
  convenience init(alt: Void) async {
    self.init(with: ...)
    await self.notifyAll()
  }

  init(bad1: Void) {
    self.init() // ❌ error: only convenience initializers can delegate
  }

  nonisolated init(bad2: Void) {
    self.init() // ❌ error: only convenience initializers can delegate
  }

  // warning: nonisolated on a synchronous non-delegating initializer is redundant
  nonisolated init(bad3: Void) {
    self.friends = []
    self.notifyAll()  // ❌ disallowed by escaping-use restriction.
  }

  nonisolated init(ok: Void) async {
    self.friends = []
    self.notifyAll()  // ❌ disallowed by escaping-use restriction.
  }

  func verify() { ... }
  func notifyAll() { ... }
}
```

An easy way to remember the rules around actor initializers is, if the initializer is just `async`, with no other actor isolation changes, then there is no escaping-use restriction.
Thus, if any one of the following apply to an initializer, it must obey the escaping-use restriction to maintain data-race safety for `self`:

1. not `async`
2. `nonisolated`
3. global-actor isolated 

### Summary

The following table summarizes the capabilities and requirements of actor initializers in this proposal:

| Initializer Kind / Rules  | Has escaping-use restriction  | Delegation  |
|---------------------------|-------------------------------|-------------|
| *Not* isolated to `self`    | Yes                           | No          |
| Isolated to `self` + synchronous | Yes       | No          |
| Isolated to `self` + `async` | No       | No          |
| `convenience` + anything | No                | Yes (required) |

## Source compatibility

The following are known source compatibility breaks with this proposal:

1. The escaping-use restriction.
2. `nonisolated` is ignored for `async` inits.
3. Global-actor isolation on stored properties of a nominal type.

**Breakage 1**

There is no simple way to automatically migrate applications that use `self` in an escaping manner within an actor initializer.
At its core, the simplest migration path is to mark the initializer `async`, but that would introduce `async` requirements on callers. For example, in this code:

```swift
actor C {
  init() {
    self.f() // ❌ now rejected by this proposal
  }

  func f() { /* ... */}
}

func user() {
  let c = C()
}
```

we cannot introduce an `async` version of `init()`, whether it is delegating or not, because the `async` must be propagated to all callers, breaking the API.
Fortunately, Swift concurrency has only been available for a few months, as of September 2021.

To resolve this source incompatibility issue without too much code churn, it is proposed that the escaping-use restriction turns into an error in Swift 6 and later. For earlier versions that support concurrency, only a warning is emitted by the compiler.

**Breakage 2**

In Swift 5.5, if a programmer requests that an `async` initializer be `nonisolated`, the escaping-use restriction is not applied, because isolation to `self` is applied regardless. For example, in this code:

```swift
actor MyActor {
  var x: Int

  nonisolated init(a: Int) async {
    self.x = a
    self.f() // permitted in Swift 5.5
    assert(self.x == a) // guaranteed to always be true
  }

  func f() {
    // create a task to try racing with init(a:)
    Task.detached { await self.mutate() }
  }

  func mutate() { self.x += 1 }
}
```

the `nonisolated` is simply ignored, and isolation is enforced with a hop-to-executor anyway.
Fixing this bug to match the proposal is very simple: remove the `nonisolated`.
Callers of the `init` will not be affected, since no synchronization is needed to enter the `init`, regardless of its isolation.
The compiler will be augmented with a fix-it in this scenario to make upgrading easy.

**Breakage 3**
The removal of global-actor isolation on stored properties imposes some source incompatibility.
For structs and enums, removal of a now invalid global-actor isolation on a stored property 
without a property initializer is not a source break, as it would only generate 
warnings that an `await` is now unnecessary:

```swift
struct S {
  var counter: Int // suppose a fix-it removed @MainActor from this.

  func f() async {
    _ = await self.counter // warning: no 'async' operations occur within 'await' expression
  }
}
```

The behavior of the program changes only in a positive way: a superfluous synchronization is removed.
If the property's initializer requires global-actor isolation to evaluate, then the
programmer will need to move that expression into the type's initializer:

```swift
@MainActor func getNumber() -> Int { 4 }

struct S {
  // 'await' operation cannot occur in a property initializer
  var counter: Int /* = await getNumber() */

  init() async {
    counter = await getNumber() // OK
  }
}
```

This, combined with the rule change for classes, where the synchronization is not superfluous, means that some minor source fixes will be required. A warning about this change will be emitted in when the compiler is operating in Swift 5 mode, because it will become an error in Swift 6.

## Alternatives considered

<!-- Describe alternative approaches to addressing the same problem, and
why you chose this approach instead. -->

This section explains alternate approaches that were ultimately not chosen for this proposal.

### Deinitializers

One workaround for the lack of ability to synchronize with an actor's executor prior to destruction is to wrap the body of the `deinit` in a task.
If this task wrapping is done implicitly, then it breaks the expectation within Swift that all tasks are explicitly created by the programmer.
If the programmer decides to go the route of explicitly spawning a new task upon `deinit`, that decision is better left to the programmer.
It is important to keep in mind that it is undefined behavior in Swift for a reference to `self` to escape a `deinit`, such as through task creation.
Nevertheless, a program that does extend the lifetime of `self` in a `deinit` is not currently rejected by the compiler; and will not be if this proposal is accepted.

### Flow-sensitive actor isolation

The solution in this proposal focuses on having an _explicit_ point at which an actor's `self` transitions to becoming fully-initialized, by leaning on delegating initializers.

If actor-isolation were formulated to change implicitly, after the point at which `self` becomes initialized in an actor, we could combine some of the capabilities of delegating and non-delegating inits.
In particular, accesses to stored properties in an initializer would be conditionally asynchronous, at multiple control-flow sensitive points:

```swift
actor A {
  var x: Int
  var y: Int

  init(with z: Int) {
    self.y = z
    guard z > 0 else {
      self.x = -1
      // `self` fully initialized here
      print(self.x) // ❌ error: must 'await' access to 'x'
      return
    }
    self.x = self.y
    // `self` fully initialized here
    _ = self.y // ❌ error: must await access to 'y'
  }
}
```

This approach was not pursued for a two reasons.
First, it is likely to be confusing to users if the body of an initializer can change its isolation part-way through, at invisible points.
Second, the existing implementation of the compiler is not designed to handle conditional async-ness.
In order to translate the program from an AST to the SIL representation, we need to decide whether an expression is async.
But, the existing control-flow analysis, to determine where `self` becomes fully-initialized, must be run on the SIL representation of the program.
Performing control-flow analysis on an AST representation would be painful and become a maintenance burden.
SIL is a normalized representation that is specifically designed to support such analyses.

### Removing the need for `convenience`

The removal of `convenience` to distinguish delegating initializers *will* create an ABI break.
Currently, the addition or removal of `convenience` on an actor initializer is an ABI-breaking change, as it is with classes, because the emitted symbols and/or name mangling will change.

If we were to disallow `nonisolated`, non-delegating initializers, we could enforce the rule that `nonisolated` means that it must delegate.
But, such semantics would not align with global-actor isolation, which is conceptually the same as `nonisolated` with respect to an initializer: not being isolated to `self`.
In addition, any Swift 5.5 code with `nonisolated` or equivalent on an actor initializer would become ABI and source incompatible with Swift 6.

Thus, is not ultimately worthwhile to try to eliminate `convenience`, since it does provide some benefit: marking initializers that _must_ delegate.
While a `nonisolated` synchronous initializer is mostly useless, the compiler can simple tell programmers to remove the `nonisolated`, because it is meaningless in that case.
Note that `nonisolated` _does_ provide utility for an `async` initializer, since it means that no implicit executor synchronization is performed, while allowing other `async` calls to happen within the initializer.



## Effect on ABI stability

This proposal does not affect ABI stability.

## Effect on API resilience

<!-- API resilience describes the changes one can make to a public API
without breaking its ABI. Does this proposal introduce features that
would become part of a public API? If so, what kinds of changes can be
made without breaking ABI? Can this feature be added/removed without
breaking ABI? For more information about the resilience model, see the
[library evolution
document](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst)
in the Swift repository. -->

Any changes to the isolation of a declaration continues to be an [ABI-breaking change](https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md#effect-on-api-resilience), but a change in what is allowed in the _implementation_ of, say, a `nonisolated` member will not affect API resilience.

## Acknowledgments

Thank you to the members of the Swift Forums for their discussions about this topic, which helped shape this proposal. In particular, we would like to thank anyone who participated in [this thread](https://forums.swift.org/t/on-actor-initializers/49001).

[se316]: https://github.com/apple/swift-evolution/blob/main/proposals/0316-global-actors.md