# Actors

* Proposal: [SE-NNNN](NNNN-actors.md)
* Authors: [Author 1](https://github.com/swiftdev), [Author 2](https://github.com/swiftdev)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Partial available in [recent `main` snapshots](https://swift.org/download/#snapshots) behind the flag `-Xfrontend -enable-experimental-concurrency`

## Introduction

The [actor model](https://en.wikipedia.org/wiki/Actor_model) involves entities called actors. Each *actor* can perform local computation based on its own state, send messages to other actors, and act on messages received from other actors. Actors run independently, and cannot access the state of other actors, making it a powerful abstraction for managing concurrency in language applications. The actor model has been implemented in a number of programming languages, such as Erlang and Pony, as well as various libraries like Akka (on the JVM) and Orleans (on the .NET CLR).

This proposal introduces a design for _actors_ in Swift, providing a model for building concurrent programs that are simple to reason about and are safe from data races. 

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

One of the more difficult problems in developing concurrent programs is dealing with [data races](https://en.wikipedia.org/wiki/Race_condition#Data_race). A data race occurs when the same data in memory is accessed by two concurrently-executing threads, at least one of which is writing to that memory. When this happens, the program may behave erratically, including spurious crashes or program errors due to corrupted internal state. 

Data races are notoriously hard to reproduce and debug, because they often depend on two threads getting scheduled in a particular way. 
Tools such as [ThreadSanitizer](https://clang.llvm.org/docs/ThreadSanitizer.html) help, but they are necessarily reactive (as opposed to proactive--they help find existing bugs, but cannot help prevent them.

Actors provide a model for building concurrent programs that are free of data races. They do so through *data isolation*: each actor protects is own instance data, ensuring that only a single thread will access that data at a given time. Actors shift the way of thinking about concurrency from raw threading to actors and put focus on actors "owning" their local state.

## Proposed solution

### Actor classes

This proposal introduces *actor classes* into Swift. An actor class is a form of class that protects access to its mutable state. For the most part, an actor class is the same as a class:

```swift
actor class BankAccount {
  private let ownerName: String
  private var balance: Double
}
```

Actor classes protect their mutable state, only allowing it to be accessed directly on `self`. For example, here is a method that attempts to transfer money from one account to another:

```swift
extension BankAccount {
  enum BankError: Error {
    case insufficientFunds
  }
  
  func transfer(amount: Double, to other: BankAccount) throws {
    if amount > balance {
      throw BankError.insufficientFunds
    }

    print("Transferring \(amount) from \(ownerName) to \(other.ownerName)")

    balance = balance - amount
    other.balance = other.balance + amount  // error: actor-isolated property 'balance' can only be referenced on 'self'
  }
}
```

If `BankAccount` were a normal class, the `transfer(amount:to:)` method would be well-formed, but would be subject to data races in concurrent code without an external locking mechanism. With actor classes, the attempt to reference `other.balance` triggers a compiler error, because `balance` may only be referenced on `self`.

As noted in the error message, `balance` is *actor-isolated*, meaning that it can only be accessed from within the specific actor it is tied to or "isolated by". In this case, it's the instance of `BankAccount` referenced by `self`. Stored properties, computed properties, subscripts, and synchronous instance methods (like `transfer(amount:to:)`) in an actor class are all actor-isolated by default.

On the other hand, the reference to `other.ownerName` is allowed, because `ownerName` is immutable (defined by `let`). Once initialized, it is never written, so there can be no data races in accessing it. `ownerName` is called *actor-independent*, because it can be freely used from any actor. Constants introduced with `let` are actor-independent by default; there is also an attribute `@actorIndependent` (described in a later section) to specify that a particular declaration is actor-independent.

> NOTE: The careful reader may here be alerted, that one may store a mutable reference type based object in a `let` property in which case mutating it would be unsafe, under the rules discussed so far. We will discuss in a future section how we will resolve these situations.

Compile-time actor-isolation checking, as shown above, ensures that code outside of the actor does not interfere with the actor's mutable state. 

Asynchronous function invocations are turned into enqueues of partial tasks representing those invocations to the actor's *queue*. This queue--along with an exclusive task `Executor` bound to the actor--functions as a synchronization boundary between the actor and any of its external callers.  

For example, if we wanted to call a method `accumulateInterest(rate: Double, time: Double)` on a given bank account `account`, that call would need to be placed on the queue to be executed by the executor which ensures that tasks are pulled from the queue one-by-one, ensuring an actor never is concurrency running on multiple threads.

Synchronous functions in Swift are not amenable to being placed on a queue to be executed later. Therefore, synchronous instance methods of actor classes are actor-isolated and, therefore, not available from outside the actor instance. For example:

```swift
extension BankAccount {
  func accumulateInterestSynchronously(rate: Double, time: Double) {
    if balance > 0 {
      balance = balance * exp(rate * time)
    }
  }
}

func accumulateMonthlyInterest(accounts: [BankAccount]) {
  for account in accounts {
    account.accumulateInterestSynchronously(rate: 0.005, time: 1.0 / 12.0) // error: actor-isolated instance method 'accumulateInterestSynchronously(rate:time:)' can only be referenced inside the actor
  }
}
```

It should be noted that actor isolation adds a new dimension, separate from access-control, to the decision making process whether or not one is allowed to invoke a specific function on an actor. Specifically, synchronous functions may only be invoked by the specific actor instance itself, and not even by any other instance of the same actor class. 

All interactions with an actor (other than the special cased access to constants) must be performed asynchronously (semantically one may think about this as the actor model's messaging to and from the actor). Thankfully, Swift provides a mechanism perfectly suitable for describing such operations: asynchronous functions which are explained in depth in the [async/await proposal](https://github.com/DougGregor/swift-evolution/blob/async-await/proposals/nnnn-async-await.md). We can make the `accumulateInterest(rate:time:)` instance method `async`, and thereby make it accessible to other actors (as well as non-actor code):

```swift
extension BankAccount {
  func accumulateInterest(rate: Double, time: Double) async {
    if balance > 0 {
      balance = balance * exp(rate * time)
    }
  }
}
```

Now, the call to this method (which now must be adorned with [`await`](https://github.com/DougGregor/swift-evolution/blob/async-await/proposals/nnnn-async-await.md#await-expressions)) is well-formed:

```swift
await account.accumulateInterest(rate: 0.005, time: 1.0 / 12.0)
```

Semantically, the call to `accumulateInterest` is placed on the queue for the actor `account`, so that it will execute on that actor. If that actor is busy executing a task, then the caller will be suspended until the actor is available, so that other work can continue. See the section on [asynchronous calls](https://github.com/DougGregor/swift-evolution/blob/async-await/proposals/nnnn-async-await.md#asynchronous-calls) in the async/await proposal for more detail on the calling sequence.

> **Rationale**: by only allowing asynchronous instance methods of actor classes to be invoked from outside the actor, we ensure that all synchronous methods are already inside the actor when they are called. This eliminates the need for any queuing or synchronization within the synchronous code, making such code more efficient and simpler to write.

### Global actors

Actor classes provide a way to encapsulate state completely, ensuring that code outside the class cannot access its mutable state. However, sometimes the code and mutable state isn't limited to a single class. For example, in order to express the important concepts of "Main Thread" or "UI Thread" in this new Actor focused world we must be able to express and extend state and functions able to run on these specific actors even though they are not really all located in the same class. 

*Global actors* address this by providing a way to annotate arbitrary declarations (properties, subscripts, functions, etc.) as being part of a process-wide singleton actor. A global actor is described by a type that has been annotated with the `@globalActor` attribute:

```swift
@globalActor
struct UIActor {
  /* details below */
}
```

Such types can then be used to annotate particular declarations that are isolated to the actor. For example, a handler for a touch event on a touchscreen device:

```swift
@UIActor
func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) async {
  // ...
}
```

A declaration with an attribute indicating a global actor type is actor-isolated to that global actor. The global actor type has its own queue that is used to perform any access to mutable state that is also actor-isolated with that same global actor.

> Global actors are implicitly singletons, i.e. there is always _one_ instance of a global actor in a given process.
> This is in contrast to `actor classes` which can have none, one or many specific instances exist at any given time. 

### Actor isolation

Any given declaration in a program can be classified into one of four actor isolation categories:

* Actor-isolated to a specific instance of an actor class:
  - This includes the stored instance properties of an actor class as well as computed instance properties, instance methods, and instance subscripts, as demonstrated with the `BankAccount` example.
* Actor-isolated to a specific global actor:
  - This includes any property, function, method, subscript, or initializer that has an attribute referencing a global actor, such as the `touchesEnded(_:with:)` method mentioned above.
* Actor-independent: 
  - The declaration is not actor-isolated to any actor. This includes any property, function, method, subscript, or initializer that has the `@actorIndependent` attribute.
* Unknown: 
  - The declaration is not actor-isolated to any actor, nor has it been explicitly determined that it is actor-independent. Such code might depend on shared mutable state that hasn't been modeled by any actor.

The actor isolation rules are checked when a given declaration (call it the "source") accesses another declaration (call it the "target"), e.g., by calling a function or accessing a property or subscript. If the target is `async`, there is nothing more to check: the call will be scheduled on the target actor's queue.

When the target is not `async`, the actor isolation categories for the source and target must be compatible. A source and target category pair is compatible if:
* the source and target categories are the same,
* the target category is actor-independent, or
* the target category is unknown.

The first rule is the most direct, and the subject of most of the prior discussion: an actor-isolated declaration can access other declarations within its same actor, whether that's an actor instance (on `self`) or global actor (e.g., `@UIActor`).

The second rule introduces the notion of actor-independent declarations, which can be used from anywhere because they aren't tied to a particular actor. Actor classes can provide actor-independent instance methods, but because those functions are not actor-isolated, that cannot read the actor's own mutable state. For example:

```swift
extension BankAccount {
  @actorIndependent
  func greeting() -> String {
    return "Hello, \(ownerName)!"  // okay: ownerName is immutable
  }
  
  @actorIndependent
  func steal(amount: Double) {
    balance -= amount  // error: actor-isolated property 'balance' can not be referenced from an '@actorIndependent' context
  }
}  
```

The third rule is a provided to allow interoperability between actors and existing Swift code. Actor code (which by definition is all new code) can call into existing Swift code with unknown actor isolation. However, code with unknown actor isolation cannot call back into (non-`async`) actor-isolated code, because doing so would violate the isolation guarantees of that actor. 

This allows incremental adoption of actors into existing code bases, isolating the new actor code while allowing them to interoperate with the rest of the code.

## Detailed design

Describe the design of the solution in detail. If it involves new
syntax in the language, show the additions and changes to the Swift
grammar. If it's a new API, show the full API and its documentation
comments detailing what it does. The detail in this section should be
sufficient for someone who is *not* one of the authors to be able to
reasonably implement the feature.

## Source compatibility

Relative to the Swift 3 evolution process, the source compatibility
requirements for Swift 4 are *much* more stringent: we should only
break source compatibility if the Swift 3 constructs were actively
harmful in some way, the volume of affected Swift 3 code is relatively
small, and we can provide source compatibility (in Swift 3
compatibility mode) and migration.

Will existing correct Swift 3 or Swift 4 applications stop compiling
due to this change? Will applications still compile but produce
different behavior than they used to? If "yes" to either of these, is
it possible for the Swift 4 compiler to accept the old syntax in its
Swift 3 compatibility mode? Is it possible to automatically migrate
from the old syntax to the new syntax? Can Swift applications be
written in a common subset that works both with Swift 3 and Swift 4 to
aid in migration?

## Effect on ABI stability

Does the proposal change the ABI of existing language features? The
ABI comprises all aspects of the code generation model and interaction
with the Swift runtime, including such things as calling conventions,
the layout of data types, and the behavior of dynamic features in the
language (reflection, dynamic dispatch, dynamic casting via `as?`,
etc.). Purely syntactic changes rarely change existing ABI. Additive
features may extend the ABI but, unless they extend some fundamental
runtime behavior (such as the aforementioned dynamic features), they
won't change the existing ABI.

Features that don't change the existing ABI are considered out of
scope for [Swift 4 stage 1](README.md). However, additive features
that would reshape the standard library in a way that changes its ABI,
such as [where clauses for associated
types](https://github.com/apple/swift-evolution/blob/master/proposals/0142-associated-types-constraints.md),
can be in scope. If this proposal could be used to improve the
standard library in ways that would affect its ABI, describe them
here.

## Effect on API resilience

API resilience describes the changes one can make to a public API
without breaking its ABI. Does this proposal introduce features that
would become part of a public API? If so, what kinds of changes can be
made without breaking ABI? Can this feature be added/removed without
breaking ABI? For more information about the resilience model, see the
[library evolution
document](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst)
in the Swift repository.

## Alternatives considered

Describe alternative approaches to addressing the same problem, and
why you chose this approach instead.

