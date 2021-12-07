# On Actors and Initialization

* Proposal: [SE-0327](0327-actor-initializers.md)
* Authors: [Kavon Farvardin](https://github.com/kavon), [John McCall](https://github.com/rjmccall), [Konrad Malawski](https://github.com/ktoso)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Returned for revision**
* Previous Discussions:
  * [On Actor Initializers](https://forums.swift.org/t/on-actor-initializers/49001)
  * [Deinit and MainActor](https://forums.swift.org/t/deinit-and-mainactor/50132)
  * [First review](https://forums.swift.org/t/se-0327-on-actors-and-initialization/53053)
  * [Result of first review](https://forums.swift.org/t/returned-for-revision-se-0327-on-actors-and-initialization/53447)
* Implementation: **Partially implemented in `main`.**

**Table of Contents**

- [On Actors and Initialization](#on-actors-and-initialization)
  - [Introduction](#introduction)
  - [Motivation](#motivation)
    - [Overly restrictive non-async initializers](#overly-restrictive-non-async-initializers)
    - [Data-races in deinitializers](#data-races-in-deinitializers)
    - [Stored Property Isolation](#stored-property-isolation)
    - [Initializer Delegation](#initializer-delegation)
  - [Proposed functionality](#proposed-functionality)
    - [Non-delegating Initializers](#non-delegating-initializers)
      - [Flow-sensitive Actor Isolation](#flow-sensitive-actor-isolation)
        - [Initializers with `isolated self`](#initializers-with-isolated-self)
        - [Initializers with `nonisolated self`](#initializers-with-nonisolated-self)
      - [Global-actor isolated classes](#global-actor-isolated-classes)
    - [Delegating Initializers](#delegating-initializers)
      - [Syntactic Form](#syntactic-form)
      - [Isolation](#isolation)
    - [Sendability](#sendability)
    - [Deinitializers](#deinitializers)
    - [Global-actor isolation and instance members](#global-actor-isolation-and-instance-members)
      - [Removing Redundant Isolation](#removing-redundant-isolation)
  - [Source compatibility](#source-compatibility)
  - [Alternatives considered](#alternatives-considered)
    - [Introducing `nonisolation` after `self` is fully-initialized](#introducing-nonisolation-after-self-is-fully-initialized)
    - [Permitting `await` for property access in `nonisolated self` initializers](#permitting-await-for-property-access-in-nonisolated-self-initializers)
    - [Async Actor Deinitializers](#async-actor-deinitializers)
  - [Effect on ABI stability](#effect-on-abi-stability)
  - [Effect on API resilience](#effect-on-api-resilience)
  - [Acknowledgments](#acknowledgments)

## Introduction

Actors are a relatively new nominal type in Swift that provides data-race safety for its mutable state.
The protection is achieved by _isolating_ the mutable state of each actor instance to at most one task at a time.
The proposal that introduced actors ([SE-0306](0306-actors.md)) is quite large and detailed, but misses some of the subtle aspects of creating and destroying an actor's isolated state.
This proposal aims to shore up the definition of an actor, to clarify *when* the isolation of the data begins and ends for an actor instance, along with *what* can be done inside the body of an actor's `init` and `deinit` declarations.

## Motivation

While there is no existing specification for how actor initialization and deinitialization *should* work, that in itself is not the only motivation for this proposal.
The *de facto* expected behavior, as induced by the existing implementation in Swift 5.5, is also problematic. In summary, the issues include:

  1. Non-async initializers are overly strict about what can be done with `self`.
  2. Actor deinitializers can exhibit data races.
  3. Global-actor isolation for stored properties cannot always be respected during initialization.
  4. Initializer delegation requires the use of the `convenience` keyword like classes, even though actors do not support inheritance.

It's important to keep in mind that these is not an exhaustive list. In particular, global-actor constrained classes that are defined in Swift are effectively actors themselves, so many of the same protections should apply to them, too.

The following subsections will discuss these these high-level problems in more detail.

### Overly restrictive non-async initializers

An actor's executor serves as the arbiter for data-race free access to the actor's stored properties, analogous to a lock. A task can access the actor's isolated state if it is running on the actor's executor. The process of gaining access to an executor can only be done asynchronously from a task, as blocking a thread to wait for access is against the ethos of Swift Concurrency. This is why invoking a non-`async` method of an actor instance, from outside of the actor's isolation domain, requires an `await` to mark the possible suspension. The process of gaining access to an actor's executor will be referred to as "hopping" onto the executor throughout this proposal.

Non-async initializers, and all deinitializers, of an actor fundamentally cannot perform a hop to the actor instance's executor, which would protect its state from concurrent access by other tasks. Without performing such a hop, a race between a new task and the code appearing in an `init` can be easily constructed:

```swift
actor Clicker {
  var count: Int
  func click() { self.count += 1 }

  init(bad: Void) {
    self.count = 0
    Task { await self.click() }
    self.click()

    print(self.count) // 💥 Might print 1 or 2!
  }
}
```

To prevent the race above in `init(bad:)`, Swift 5.5 imposed a restriction on what can be done with `self` in a non-async initializer. In particular, having `self` escape in a closure capture, or be passed (implicitly) in the method call to `click`, triggers a warning that such uses of `self` will be an error in Swift 6. But, these restrictions are overly broad, because they would also reject initializers that are race-free, such as `init(ok:)`:

```swift
actor Clicker {
  var count: Int
  func click() { self.count += 1 }
  nonisolated func announce() { print("performing a click!") }

  init(ok: Void) {
    self.count = 0
    Task { await self.click() }
    self.announce() // rejected in Swift 5.5, but is race-free.
  }
}
```

Leveraging the actor isolation model, we know `announce` cannot touch the stored property `count` to observe that `click` happened concurrently with the initializer. That's because `announce` is not isolated to the actor instance. In fact, a race can only happen in the initializer if an access to `count` appears after the creation of the task. This proposal aims to generalize that idea into something we refer to _flow-sensitive isolation_, which uses [data-flow analysis](https://en.wikipedia.org/wiki/Data-flow_analysis) to prove statically that non-async initializers of an actor are race-free.

### Data-races in deinitializers

While non-async initializers gained restrictions to prevent data races in Swift 5.5, deinitializers did not. Yet, `deinit`s can still exhibit data races and illegal lifetime extensions of `self` that live longer than the `deinit`'s invocation. One kind of data race in a `deinit` is conceptually the same as the one described earlier for non-async initializers:

```swift
actor Clicker {
  var count: Int = 0

  func click(_ times: n) {
    for _ in 0<..n {
      self.count += 1 
    }
  }

  deinit {
    let current = count
    
    Task { await self.click(1000000) } // This might keep `self` alive after the `deinit` too!

    assert(current == count)    // 💥 Might fail due to data-race!
  }
}
```

There is another more subtle scenario in the `deinit` of global-actor isolated classes (GAICs). A GAIC is similar to an actor that shares its persistent executor with other instances. When an actor or GAIC's executor is not exclusively owned by the type's instance, then it is not safe to access a non-Sendable stored property from the `deinit`:

```swift
class NonSendableAhmed { 
  var state: Int = 0
}

@MainActor
class Maria {
  let friend: NonSendableAhmed

  init() {
    self.friend = NonSendableAhmed()
  }

  init(sharingFriendOf otherMaria: Maria) {
    // While the friend is non-Sendable, this initializer and
    // and the otherMaria are isolated to the MainActor. That is,
    // they share the same executor. So, it's OK for the non-Sendable value
    // to cross between otherMaria and self.
    self.friend = otherMaria.friend
  }

  deinit {
    friend.state += 1   // 💥 the deinit is not isolated to the MainActor,
                        // so this mutation can happen concurrently with other
                        // accesses to the same underlying instance of 
                        // NonSendableAhmed.
  }
}

func example() async {
  let m1 = await Maria()
  let m2 = await Maria(sharingFriendOf: m1)
  doSomething(m1, m2)
}
```

In the example above, access to isolated and non-Sendable stored properties of `Maria` from the `deinit` is not safe, as it can introduce a data race. That's because a `deinit` (and its callers) cannot hop to the `MainActor`'s executor in order to guarantee safe access, like an isolated method could. If the `friend` were `Sendable`, then there is no problem.

Also, the reference count of `self` upon entering the `deinit` is zero. So, it is undefined behavior for that `self` instance to then escape the `deinit`, living beyond the lifetime of the `deinit`. This is a problem for ordinary classes, too, leading to [random crashes](https://bugs.swift.org/browse/SR-6942). Since lifetime extension issues in an actor's `deinit` is a general problem, we defer a solution to that for a future proposal.
<!-- For actors, this is additionally problematic, because the task living beyond the lifetime of the `deinit` may be awaiting access to the actor's executor, when the executor has been asked to shutdown. -->

### Stored Property Isolation

The stored properties of classes, structs, and enums are currently permitted to have global-actor isolation applied to them independently. But, this creates problems for both initialization and deinitialization. For example, when users specify a default value for the stored property, those default values are evaluated by the non-delegating initializer of a nominal type:

```swift
@MainActor func getStatus() -> Int { /* ... */ }
@PIDActor func genPID() -> ProcessID { /* ... */ }

class Process {
  @MainActor var status: Int = getStatus()
  @PIDActor var pid: ProcessID = genPID()
  
  init() {} // Problem: what is the isolation of this init?
}
```

In the example above, because `status` and `pid` are isolated to two different global-actors, there's no single actor-isolation that can be specified for the non-async `init`.
This means that `getStatus` and `genPID` are being called without acquiring actor isolation!
<!-- In fact, all non-delegating initializers would need to have the same isolation as all stored properties. -->
<!-- Even if the isolation of the initializers and stored properties matched, the `deinit` still can _never_ access the stored properties in order to invoke clean-up routines, *etc*, without using illegal lifetime extensions of the actor instance from the `deinit`. -->

### Initializer Delegation

All nominal types in Swift support initializer delegation, which is when one initializer calls another one to perform initialization.
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

Actors, which are reference types (like a classes), do not support inheritance. But, the proposal for actors did not specify whether `convenience` is required or not in order to have a delegating initializer. Swift 5.5 requires the use of a `convenience` modifier to mark actor initializers that perform delegation for no good reason.




















## Proposed functionality

The previous sections described problems with the current state of initialization and deinitialization in Swift.
The remainder of this section aims to fix those problems while defining how actor and global-actor isolated class (GAIC) initializers and deinitializers differ from those belonging to an ordinary class. While doing so, this proposal will highlight how the problems above are resolved.

### Non-delegating Initializers

A non-delegating initializer of an actor or a global-actor isolated class (GAIC), is one where all of the the stored properties of the actor must be initialized.

#### Flow-sensitive Actor Isolation

The focus of this section is exclusively on non-delegating initializers for `actor` types, not GAICs.
In Swift 5.5, an actor's initializer that obeys the _escaping-use restriction_ means that the following are rejected throughout the entire initializer:

- Capturing `self` in a closure.
- Calling a method or computed property on `self`.
- Passing `self` as any kind of argument, whether by-value, `autoclosure`, or `inout`.

But, those rules are an over-approximation of the restrictions needed to prevent the races described earlier. This proposal removes the escaping-use restriction for initializers. Instead, we propose a simpler set of rules as follows:

  - An initializer has a `nonisolated self` reference if it is:
     - non-async
     - or global-actor isolated
     - or `nonisolated`
- Asynchronous actor initializers have an `isolated self` reference.

The remainder of this section discusses how these new rules work for each of the two categories of non-delegating initializers.

##### Initializers with `isolated self`

For an asynchronous initializer, a hop to the actor's executor, which is a suspension point, will be performed immediately after `self` becomes fully-initialized in order to ascribe the isolation to `self`. Choosing this location for performing the executor hop preserves the concept of `self` being isolated throughout the entire async initializer. There are many possible points in an initializer where these suspensions can happen, and they all involve _some_ initializing store. Consider this example of `Bob`:

```swift
actor Bob {
  var x: Int
  var y: Int = 2
  func f() {}
  init(_ cond: Bool) async {
    if cond {
      self.x = 1 // initializing store
    }
    self.x = 2 // initializing store

    f() // this is ok, since we're on the executor here.
  }
}
```

The problem with trying to explicitly mark the suspension points in `Bob.init` is that they are not easy for programmers to track, nor are they consistent enough to stay the same under simple refactorings. Adding or removing a default value for a stored property, or changing the number of stored properties, can greatly influence where the hops may occur. Consider this slightly modified example from before:

```swift
actor EvolvedBob {
  var x: Int
  var y: Int
  func f() {}
  init(_ cond: Bool) async {
    if cond {
      self.x = 1
    }
    self.x = 2 
    self.y = 2 // initializing store

    f() // this is ok, since we're on the executor here.
  }
}
```

Relative to `Bob`, the only change made to `EvolvedBob` is that its default value for `y` was converted into an unconditional store in the body of the initializer. From an observational point of view, `Bob.init` and `EvolvedBob.init` are identical. But from an implementation perspective, the suspension points for performing an executor hop differ dramatically. If those points required some sort of annotation in Swift, such as with `await`, then the reason why those suspension points moved is hard to explain to programmers.

In summary, we propose to _implicitly_ perform suspensions to hop to the actors executor once `self` is initialized, instead of having programmers mark those points explicitly, for the following reasons:
1. The finding and continually updating the suspension points is annoying for programmers.
2. The reason _why_ some simple stores to a property can trigger a suspension is an implementation detail that is hard to explain to programmers.
3. The benefits of marking these suspensions is very low. The reference to `self` is known to be unique by the time the suspension  will happen, so it is impossible to create an [actor reentrancy](https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md#actor-reentrancy) situation.
4. There is [already precedent](https://github.com/apple/swift-evolution/blob/main/proposals/0317-async-let.md#requiring-an-awaiton-any-execution-path-that-waits-for-an-async-let) in the language for performing implicit suspensions, namely for `async let`, when the language feature requiring suspensions is hard for programmers to determine.

The net effect of these implicit executor-hops is that, for programmers, an `async` initializer does not appear to have any additional rules added to it! That is, programmers can simply view the initializer as being isolated throughout, like any ordinary `async` method would be! The flow-sensitive points where the hop is inserted into the initializer can be safely ignored as an implementation detail for all but the most rare situations. For example:

```swift
actor OddActor {
  var x: Int
  init() async {
    let name = Thread.current.name
    self.x = 0 // initializing store
    assert(name == Thread.current.name) // may fail
  }
}
```

Note that the callers of `OddActor.init` cannot assume that the callee hasn't performed a suspension, just as with any `async` method, because an `await` is required to enter the initializer. Thus, this ability to observe an unmarked suspension is extremely limited.

**In-depth discussions**

The remainder of this subsection covers some technical details that are not required to understand this proposal and may be safely skipped.

**Compiler Implementation Notes:** Identifying the assignment that fully-initializes `self` _does_ require a non-trivial data-flow analysis. Such an analysis is not feasible to do early in the compiler, during type checking. Does acceptance of this proposal mean that the actor-isolation checker, which is run as part of type-checking, will require additional analysis or significant changes? Nope! We can rely on existing restrictions on uses of `self`, prior to initialization, to exclude all places where `self` could be considered only `nonisolated`:

```swift
func isolatedFunc(_ a: isolated Alice) {}

actor Alice {
  var x: Int
  var y: Task<Void, Never>

  nonisolated func nonisolatedMethod() {}
  func isolatedMethod() {}

  init() async {
    self.x = self.nonisolatedMethod() // error: illegal use of `self` before initialization.
    self.y = Task { self.isolatedMethod() } // error: illegal capture of `self` before initialization
    Task { 
      self.isolatedMethod() // no await needed, since `self` is isolated.
    }
    self.isolatedMethod() // OK
    isolatedFunc(self) // OK
  }
}
```

This means that the actor-isolation checker, run prior to converting the program to SIL, can uniformly view the parameter `self` as having type `isolated Self` for the async initializer above. Later in SIL, the defined-before-use verification (i.e., "definite initialization") will find and emit the errors above. As a bonus, that same analysis can be leveraged to find the initializing assignment and introduce the suspension to hop to the actor's executor.

**Data-race Safety:** In terms of correctness, the proposed `isolated self` initializers are race-free because a hop to the actor's executor happens immediately after the initializing store to `self`, but before the next statement begins executing. Gaining access to the executor at this exact point prevents races, because escaping `self` to another task is only possible _after_ that point. In the `Alice` example above, we can see this in action, where the rejected assignment to `self.y` is due to an illegal capture of `self`.

**Only one suspension is performed:** It is possible to construct an initializer with control-flow that crosses an implicit suspension points multiple times, as seen in `Bob` above and loops such as:

```swift
actor LoopyBob {
  var x: Int
  init(_ counter: Int) async {
    var i = 0
    repeat {
      self.x = 0 // initializing store
      i += 1
    } while i < counter
  }
}
```

Once gaining access to an executor by crossing the first suspension point, crossing another suspension point does not change the executor, nor will that actually perform a suspension. Avoiding these unnecessary executor hops is an optimization that is done throughout Swift (e.g., self-recursive `async` and `isolated` functions).



##### Initializers with `nonisolated self`

The category of actor initializers that have a `nonisolated self` contain those which are non-async, or have an isolation that differs from being isolated to `self`. Unlike its methods, an actor's non-async initializer does _not_ require an `await` to be invoked, because there is no actor-instance to synchronize with. In addition, an initializer with a `nonisolated self` can access the instance's stored properties without synchronization, when it is safe to do so.

Accesses to the stored properties of `self` is required to bootstrap an instance of an actor. Such accesses are considered to be a weaker form of isolation that relies on having exclusive access to the reference `self`. If `self` escapes the initializer, such uniqueness can no-longer be guaranteed without time-consuming analysis. Thus, the isolation of `self` decays (or changes) to `nonisolated` during any use of `self` that is not a direct stored-property access.  That change happens once on a given control-flow path and persists through the end of the initializer. Here are some example uses of `self` within an initializer that cause it to decay to a `nonisolated` reference:

1. Passing `self` as an argument in a procedure call. This includes:
  - Invoking a method of `self`.
  - Accessing a computed property of `self`.
2. Capturing `self` in a closure.
3. Storing `self` to memory.

Consider the following example that helps demonstrate how this isolation decay works:

```swift
class NotSendableString { /* ... */ }
class Address: Sendable { /* ... */ }
func greetCharlie(_ charlie: Charlie) {}

actor Charlie {
  var score: Int
  let fixedNonSendable: NotSendableString
  let fixedSendable: Address
  var me: Self? = nil

  func incrementScore() { self.score += 1 }
  nonisolated func nonisolatedMethod() {}

  init(_ initialScore: Int) {
    self.score = initialScore
    self.fixedNonSendable = NotSendableString("Charlie")
    self.fixedSendable = NotSendableString("123 Main St.")

    if score > 50 {
      nonisolatedMethod() // a nonisolated use of `self`
      greetCharlie(self)  // a nonisolated use of `self`
      self.me = self      // a nonisolated use of `self`
    } else if score < 50 {
      score = 50
    }
 
    assert(score >= 50) // ❌ error: cannot access mutable isolated storage after `nonisolated` use of `self`

    _ = self.fixedNonSendable // ❌ error: cannot access non-Sendable property after `nonisolated` use of `self`
    _ = self.fixedSendable

    Task { await self.incrementScore() } // a nonisolated use of `self`
  }
}
```

The central piece of this example is the `if-else` statement chain, which introduces multiple control-flow paths in the initializer. In the body of one of the first conditional block, several different `nonisolated` uses of `self` appear. In the other conditional cases (the `else-if`'s block and the implicitly empty `else`), it is still OK for reads and writes of `score` to appear. But, once control-flow meets-up after the `if-else` statement at the `assert`, `self` is considered `nonisolated` because one of the blocks that can reach that point introduces non-isolation. 

As a consequence, the only stored properties that are accessible after `self` becomes `nonisolated` are let-bound properties whose type is `Sendable`.
The diagnostics emitted for illegal accesses to other stored properties will point to one of the earlier uses of `self` that caused the isolation to change. The sense of "earlier" here is in terms of control-flow and not in terms of where the statements appear in the program. To see how this can happen in practice, consider this alternative definition of `Charlie.init` that uses `defer`:

```swift
init(hasADefer: Void) {
  self.score = 0
  defer { 
    print(self.score) // error: cannot access mutable isolated storage after `nonisolated` use of `self`
  }
  Task { await self.incrementScore() } // note: a nonisolated use of `self`
}
```

Here, we defer the printing of `self.score` until the end of the initializer. But, because `self` is captured in a closure before the `defer` is executed, that read of `self.score` is not always safe from data-races, so it is flagged as an error. Another scenario where an illegal property access can visually precede the decaying use is for loops:

```swift
init(hasALoop: Void) {
  self.score = 0
  for i in 0..<10 {
    self.score += i     // error: cannot access mutable isolated storage after `nonisolated` use of `self`
    greetCharlie(self)  // note: a nonisolated use of `self`
  }
}
```

In this for-loop example, we must still flag the mutation of `self.score` in a loop as an error, because it is only safe on the first loop iteration. On subsequent loop iterations, it will not be safe because `self` may be concurrently accessed after being escaped in a procedure call.

**In-depth discussions**

The remainder of this subsection covers some technical details that are not required to understand this proposal and may be safely skipped.

**Limitations of Static Analysis**
Not all loops iterate more than once, or even at all. The Swift compiler will be free to reject programs that may never exhibit a race dynamically, based on the static assumption that loops can iterate more than once and conditional blocks can be executed. To make this more concrete, consider these two silly loops:

```swift
init(hasASillyLoop1: Void) {
  self.score = 0
  while false {
    self.score += i     // error: cannot access isolated storage after `nonisolated` use of `self`
    greetCharlie(self)  // note: a nonisolated use of `self`
  }
}

init(hasASillyLoop2: Void) {
  self.score = 0
  repeat {
    self.score += i     // error: cannot access isolated storage after `nonisolated` use of `self`
    greetCharlie(self)  // note: a nonisolated use of `self`
  } while false
}
```

In both loops above, it is clear to the programmer that no race will happen, because control-flow will not dynamically reach the statement incrementing `score` _after_ passing `self` in a procedure call. For these trivial examples, the compiler _may_ be able to prove that these loops do not execute more than once, but that is not guaranteed due to the [limitations of static analysis](https://en.wikipedia.org/wiki/Halting_problem).

**Property Observers**
In Swift, writes to a stored property can trigger a property observer to fire.
Property observers, i.e., `didSet` and `willSet` can be attached to a stored property and have access to `self`:

```swift
actor Observed {
  func mutate() { self.x += 1 }
  var x: Int {
    didSet {
      print("hello!")
      Task { await self.mutate() }
    }
  }

  init() {
    // none of these invokes the `didSet`, so `self` does not become
    // `nonisolated` from these assignments:
    self.x = 1
    self.x = 2
    self.x = 3
  }
}
```

But, such observers are _not_ invoked when assigning to a stored property within an initializer.
Thus, non-isolation within an initializer cannot be introduced by an access to a stored property. The program above should be accepted as it is free of data races.

**Data-race Safety**

In effect, the concept of isolation decay prevents data-races by disallowing access to stored properties once the compiler can no-longer prove that the reference to `self` will not be concurrently accessed. For efficiency reasons, the compiler might not perform interprocedural analysis to prove that passing `self` to another function is safe from concurrent access by another task. Interprocedural analysis is inherently limited due to the nature of modules in Swift (i.e., separate compilation). Immediately after `self` has escaped the initializer, the treatment of `self` in the initializer changes to match the unacquired status of the actor's executor.

#### Global-actor isolated classes

A non-isolated initializer of a global-actor isolated class (GAIC) is in the same situation as a non-async actor initializer, in that it must bootstrap the instance without the executor's protection. Thus, we can construct a data-race just like before:

```swift
@MainActor
class RequiresFlowIsolation<T>
  where T: Sendable, T: Equatable {

  var item: T

  func mutateItem() { /* ... */ }
  
   nonisolated init(with t: T) {
    self.item = t
    Task { await self.mutateItem() }
    self.item = t   // 💥 races with the task!
  }
}
```

to demonstrate a problem. To solve it, we propose to apply flow-sensitive actor isolation to the initializers of GAICs that are marked as non-isolated.

For isolated initializers, GAICs have the ability to gain actor-isolation prior to calling the initializer itself. That's because its executor is a static instance, existing prior to even allocating uninitialized memory for a GAIC object. Thus, all isolated initializers of a GAIC require callers to `await` to gain access to the right executor. For isolated initializers of GAICs, there is no danger of race, regardless of the isolation of its members:

```swift
@MainActor
class ProtectedByExecutor<T: Equatable> {
  var item: T

  func mutateItem() { /* ... */ }
  
  init(with t: T) {
    self.item = t
    Task { self.mutateItem() }  // ✅ we're on the executor when creating this task.
    assert(self.item == t) // ✅ always true, since we hold the executor here.
  }
}
```

The class in the example above is free from a race, even in its non-async initializer, because the executor is acquired prior to entering that initializer and is held throughout. All other classes, which are not GAICs, have some holes in actor isolation. Those classes rely on `Sendable` restrictions to help prevent data races.


### Delegating Initializers

This section defines the syntactic form and rules about delegating initializers for `actor` types and global-actor isolated classes (GAICs).

#### Syntactic Form

While `actor`s are a reference type, their delegating initializers will follow the same basic rules that exist for value types, namely:

1. If an initializer body contains a call to some `self.init`, then it's a delegating initializer. No `convenience` keyword is required.
2. For delegating initializers, `self.init` must always be called on all paths, before `self` can be used.

The reason for this difference between `actor` and `class` types is that `actor`s do not support inheritance, so they can shed the complexity of `class` initializer delegation. GAICs use the same syntactic form as ordinary classes to define delegating initializers.

#### Isolation

Much like their non-delegating counterparts, an actor's delegating initializer either has an `isolated self` or a `nonisolated self` reference. The decision procedure for categorizing these initializers are the same, too: non-async delegating initializers have a `nonisolated self`, *etc*.

But, the delegating initializers of an actor have simpler isolation semantics, because they are not required to initialize the instance's stored properties. Thus, instead of using flow-sensitive actor isolation, delegating initializers have a uniform isolation for `self`, much like an ordinary function.

### Sendability

The delegating initializers of an `actor`, and all initializers of a GAIC, follow the same rules about Sendable arguments as other functions. Namely, if the function is isolated, then cross-actor calls require that the arguments conform to the `Sendable` protocol.

All non-delegating initializers of an actor, regardless of any flow-sensitive isolation applied to `self`, are considered "isolated" from the `Sendable` point-of-view. That's because these initializers are permitted to access the actor's isolated stored properties during bootstrapping.

As a result of these two rules, a delegating initializer with an `isolated self` can pass non-`Sendable` arguments when delegating to another initializer. Here are some examples to illustrate:

```swift
class NotSendableType { /* ... */ }

actor George {
  var ns: NonSendableType

  init(anyNonDelegating ns: NonSendableType) { 
    self.ns = ns
  }

  init(delegatingSync ns: NonSendableType) {
    self.init(anyNonDelegating: ns) // ❌ error: cannot pass non-Sendable value across actors
    self.ns = ns // ❌ error: cannot mutate isolated property from nonisolated context
  }

  init(delegatingAsync ns: NonSendableType) async {
    self.init(anyNonDelegating: ns) // ✅ OK
    self.ns = ns // ✅ OK
  }

  nonisolated init(delegatingNonIsoAsync ns: NonSendableType) async {
    self.init(anyNonDelegating: ns) // ❌ error: cannot pass non-Sendable value across actors
    self.ns = ns // ❌ error: cannot mutate isolated property from nonisolated context
  }
}

func someUnrelatedCaller(ns: NonSendableType) async {
  _ = George(anyNonDelegating: ns) // ❌ error: cannot pass non-Sendable value across actors
  _ = George(delegatingSync: ns) // ✅ OK

  _ = await George(delegatingAsync: ns) // ❌ error: cannot pass non-Sendable value across actors
  _ = await George(delegatingNonIsoAsync: ns) // ✅ OK
}
```

### Deinitializers

In Swift 5.5, two different kinds of data races with an actor or global-actor isolated class (GAIC) can be created within a `deinit`, as shown in an earlier section. The first one involves a reference to `self` being shared with another task, and the second one with actors having shared executors.

To solve the first kind of race, we propose having the same flow-sensitive actor isolation rules discussed earlier for a `nonisolated self` apply to an actor's `deinit`. A `deinit` falls under the `nonisolated self` category, because it is effectively a non-async, non-delegating initializer whose purpose is to clean-up or tear-down, instead of bootstrap. In particular, a `deinit` starts with a unique reference to `self`, so the rules for decaying to a `nonisolated self` match up perfectly. This solution will apply to the `deinit` of both actor types and GAICs.

To solve the second race, we propose that a `deinit` can only access the stored properties of `self` that are `Sendable`. This means that, even when `self` is a unique reference and has not decayed to being `nonisolated`, only the `Sendable` stored properties of an actor or GAIC can be accessed. This restriction is not needed for an `init`, because the initializer has known call-sites that are checked for isolation and `Sendable` arguments. The lack of knowledge about when and where a `deinit` will be invoked is why `deinit`s must carry this extra burden. In effect, non-`Sendable` actor-isolated state can only be deinitialized by an actor by invoking that state's `deinit`.

Here is an example to help illustrate the new rules for `deinit`:

```swift
actor A {
  let immutableSendable = SendableType()
  var mutableSendable = SendableType()
  let nonSendable = NonSendableType()

  init() {
    _ = self.immutableSendable  // ✅ ok
    _ = self.mutableSendable    // ✅ ok
    _ = self.nonSendable        // ✅ ok

    f(self) // trigger a decay to `nonisolated self`

    _ = self.immutableSendable  // ✅ ok
    _ = self.mutableSendable    // ❌ error: must be immutable
    _ = self.nonSendable        // ❌ error: must be sendable
  }


  deinit {
    _ = self.immutableSendable  // ✅ ok
    _ = self.mutableSendable    // ✅ ok
    _ = self.nonSendable        // ❌ error: must be sendable

    f(self) // trigger a decay to `nonisolated self`

    _ = self.immutableSendable  // ✅ ok
    _ = self.mutableSendable    // ❌ error: must be immutable
    _ = self.nonSendable        // ❌ error: must be sendable
  }
}
```

In the above, the only difference between the `init` and the `deinit` is that the `deinit` can only access `Sendable` properties, whereas the `init` can access non-`Sendable` properties prior to the isolation decay.


### Global-actor isolation and instance members

The main problem with global-actor isolation on the stored properties of a nominal type is that an impossible isolation requirement can be constructed. The isolation needed for a type's non-delegating initializers is the union of all isolation applied to its stored properties that *specifically* have a default value. It must be valid to meld together the expressions for each of the default values and place them into an initializer. If there is more than one unique global-actor required among those expressions, then the initializer cannot be defined.

We propose solving this problem in a way that adds only one simple rule to remember, so that it does not induce any extra exceptions and corner-cases: 

>If a nominal type's stored-property member has its own, independent global-actor isolation annotation, then that stored property cannot have an explicit default value.

As a consequence, if programmers want to have default values for their stored properties, to take advantage of conciseness, then they must place the annotation on the entire type:

```swift
class ProtectedPairBad {
  @BlueActor var hello = someFn() // ❌ error: default value not permitted
  @BlueActor var goodbye = someFn() // ❌ error: default value not permitted
}

@BlueActor
class ProtectedPairGood {
  var hello = someFn()    // ✅ ok
  var goodbye = someFn()  // ✅ ok
}
```

This rule is subjective and an over-approximation of the required solution, but it is simple to remember. That is, for the example above, the compiler *could* accept `ProtectedPairBad` with some simple analysis of the isolation applied to the stored properties. But, that would make the rules about whether a stored-property member can have an explicit default value more difficult to explain and remember.


#### Removing Redundant Isolation

Global-actor isolation on a stored property provides safe concurrent access to the storage occupied by that stored property in the type's instances.
For example, if `pid` is an actor-isolated stored property without an observer, then the access `p.pid.reset()` only protects the memory read of `pid` from `p`, and not the call to `reset` afterwards.

Thus, for value types (enums and structs), global-actor isolation on stored properties fundamentally serves no use: mutations of the storage occupied by the stored property in a value type are concurrency-safe by default, thanks to copy-on-write semantics. The only exception to this is when the stored property has an observer, i.e., `didSet` and/or `willSet`. In those cases, the global-actor isolation on the property extends to those observers. Thus, we propose barring stored properties of a value type from having global-actor isolation, _unless_ if it has an attached observer.

The [global actors](0316-global-actors.md) proposal explicitly excludes actor types from having stored properties that are global-actor isolated. But in Swift 5.5, that is not enforced by the compiler. We feel that the rule should be enforced, i.e., the storage of an actor should uniformly be isolated to the actor instance. One reason for this rule is that it eliminates the possibility of [false sharing](https://en.wikipedia.org/wiki/False_sharing) among threads. That is, with the rule in force, only one thread will access the memory occupied by an actor instance at any given time.


## Source compatibility
There are some changes in this proposal that are backwards compatible or easy to migrate:

- The set of `init` declarations accepted by the compiler in Swift 5.5 (without emitted warnings) is a strict subset of the ones that will be permitted if this proposal is accepted, i.e., flow-sensitive isolation broadens the set of permitted programs.
- Appearances of `convenience` on an actor's initializer can be ignored and/or have a fix-it emitted.
- Appearances of superfluous global-actor isolation annotations on ordinary stored properties (say, in value types) can be ignored and/or have a fix-it emitted.

But, there are others which will cause a non-trivial source break to patch holes in the concurrency model, for example:

- The set of `deinit`s accepted by the compiler for actors and GAICs will be narrowed.
- GAICs will have data-race protections applied to their non-isolated `init`s, which slightly narrows the set of acceptable `init` declarations.
- Global-actor isolation on stored-property members of an actor type are prohibited.
- Stored-property members that are still permitted to have global-actor isolation applied to them cannot have a default value.

Note that these changes to GAICs will only apply to classes defined in Swift. Classes imported from Objective-C with MainActor-isolation applied will be assumed to not have data races.


## Alternatives considered

This section explains alternate approaches that were ultimately not chosen for this proposal.

### Introducing `nonisolation` after `self` is fully-initialized

It is tempting to say that, to avoid introducing another concept into the language, `nonisolation` should begin at the point where `self` becomes fully-initialized. But, because control-flow can cross from a scope where `self` is fully-initialized, to another scope where `self` _might_ be fully-initialized, this rule is not enough to determine whether an initializer has a race. Here are two examples of initializers where this simplistic rule breaks down:

```swift
actor CounterExampleActor {
  var x: Int
  
  func mutate() { self.x += 1 }
  
  nonisolated func f() { 
    Task { await self.mutate() }
  }

  init(ex1 cond: Bool) {
    if cond {
      self.x = 0
      f()
    }
    self.x = 1 // if cond is true, this might race!
  }

  init(ex2 max: Int) {
    var i = 0
    repeat {
      self.x = i // after first loop iteration, this might race!
      f()
      i += 1
    } while i < max
  }
}
```

In Swift, `self` can be freely used, _immediately_ after becoming fully-initialized. Thus, if we tie `nonisolation` to whether `self` is fully-initialized _at each use_, both initializers above should be accepted, even though they permit data races: `f` can escape `self` into a task that mutates the actor, yet the initializer will continue after returning from `f` with unsynchronized access to its stored properties.

With the flow-sensitive isolation rules in this proposal, both property accesses above that can race are rejected because of a flow-isolation error. The source of `nonisolation` would be identified as the calls to `f()`, so that programmers can correct their code. 

Now, consider what would happen if the calls to `f` above were removed. With the proposed isolation rules, the programs would now be accepted because they are safe: there is no source of `nonisolation`. If we had said that `nonisolation` _always_ starts immediately after `self` is fully-initialized, and _persists until the end of the initializer_, then even without the calls to `f`, the initializers above would be would be needlessly rejected.


### Permitting `await` for property access in `nonisolated self` initializers

In an `nonisolated self` initializer, we reject stored property accesses after the first non-isolated use. For a non-async initializer, there is no alternative to rejecting the program, since one cannot hop to the actor's executor in that context. But an `async` initializer that is not isolated to `self` _could_ perform that hop:

```swift
class SomeClass {}
actor AwkwardActor {
  var x: SomeClass
  nonisolated func f() { /* ... */ }

  nonisolated init() async {
    self.x = SomeClass()
    let a = self.x
    f()
    let b = await self.x // warning: accessing non-Sendable type `SomeClass` across actors
    print(a + b)
  }
}
```

From an implementation perspective, it _is_ feasible to support the program above, where property accesses can become `async` expressions based on flow-sensitive isolation. But, this proposal currently takes the subjective position that such code should be rejected. The expressiveness gained by supporting such a flow-sensitive `async` property access is not worth the confusion they might create:

For programmers who simply _read_ this valid code in a project, the `await` might look unnecessary or otherwise unnecessarily challenge their understanding of isolation. But, this specific kind of `nonisolated self` _and_ `async` initializer would be the only place where one could demonstrate to _readers_ that isolation can change mid-function. This is in contrast to a non-async `nonisolated self` initializer, for whom those property accesses are rejected for the same isolation-change reason. The subtle difference is that, unless the programmer is writing or modifying an `isolated self` actor initializer, they are not exposed to flow-sensitive isolation.


### Async Actor Deinitializers

One idea for working around the inability to synchronize from a `deinit` with the actor-instance's executor prior to destruction is to wrap the body of the `deinit` in a task. This would in effect allow the necessarily non-async `deinit` to act as though it were `async` in its body.

The primary danger here is that it is currently undefined behavior in Swift for a reference to `self` to escape a `deinit` and persist after the `deinit` has completed, which must be possible if the `deinit` were asynchronous. The only other option would be to have `deinit` be blocking, but Swift concurrency is designed to avoid blocking.

## Effect on ABI stability

This proposal does not affect ABI stability.

## Effect on API resilience

This proposal does not affect API resilience.

## Acknowledgments

Thank you to the members of the Swift Forums for their time spent reading this proposal and its prior versions, along with posting their thoughts on the forums.
