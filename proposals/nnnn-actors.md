# Actors

* Proposal: [SE-NNNN](NNNN-actors.md)
* Authors: [John McCall](https://github.com/rjmccall), [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Partial available in [recent `main` snapshots](https://swift.org/download/#snapshots) behind the flag `-Xfrontend -enable-experimental-concurrency`

## Introduction

The [actor model](https://en.wikipedia.org/wiki/Actor_model) involves entities called actors. Each *actor* can perform local computation based on its own state, send messages to other actors, and act on messages received from other actors. Actors run independently, and cannot access the state of other actors, making it a powerful abstraction for managing concurrency in language applications. The actor model has been implemented in a number of programming languages, such as Erlang and Pony, as well as various libraries like Akka (on the JVM) and Orleans (on the .NET CLR).

This proposal introduces a design for *actors* in Swift, providing a model for building concurrent programs that are simple to reason about and are safe from data races. 

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

One of the more difficult problems in developing concurrent programs is dealing with [data races](https://en.wikipedia.org/wiki/Race_condition#Data_race). A data race occurs when the same data in memory is accessed by two concurrently-executing threads, at least one of which is writing to that memory. When this happens, the program may behave erratically, including spurious crashes or program errors due to corrupted internal state. 

Data races are notoriously hard to reproduce and debug, because they often depend on two threads getting scheduled in a particular way. 
Tools such as [ThreadSanitizer](https://clang.llvm.org/docs/ThreadSanitizer.html) help, but they are necessarily reactive (as opposed to proactive)--they help find existing bugs, but cannot help prevent them.

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

> **Note**: Constants defined by `let` are only truly immutable when the type is a value type or some kind of immutable reference type. A `let` that refers to a mutable reference type (such as a non-actor class type) would be unsafe based on the rules discussed so far. These issues are discussed in a later section on "Reference types".

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

All interactions with an actor (other than the special cased access to constants) must be performed asynchronously (semantically one may think about this as the actor model's messaging to and from the actor). Asynchronous functions provide a mechanism that is suitable for describing such operations, and are explained in depth in the complementary [async/await proposal](https://github.com/DougGregor/swift-evolution/blob/async-await/proposals/nnnn-async-await.md). We can make the `accumulateInterest(rate:time:)` instance method `async`, and thereby make it accessible to other actors (as well as non-actor code):

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
func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
  // ...
}
```

A declaration with an attribute indicating a global actor type is actor-isolated to that global actor. The global actor type has its own queue that is used to perform any access to mutable state that is also actor-isolated with that same global actor.

Global actors are implicitly singletons, i.e. there is always _one_ instance of a global actor in a given process. This is in contrast to `actor classes` which can have none, one or many specific instances exist at any given time.

## Detailed design

### Actor classes

A class can be declared as an actor class using the `actor` modifier:

```
/// Declares a new type BankAccount
actor class BankAccount {
  // ...
}
```

Each instance of the actor type represents a unique actor.

An actor class may only inherit from another actor class. A non-actor class may not inherit from an actor class.

> **Rationale**: Actor classes enforce state isolation, but non-actor classes do not. If an actor class inherits from a non-actor class (or vice-versa), part of the actor's state would not be covered by the actor-isolation rules, introducing the potential for data races on that state.

As a special exception described in the complementary proposal [Concurrency Interoperability with Objective-C](https://github.com/DougGregor/swift-evolution/blob/concurrency-objc/proposals/NNNN-concurrency-objc.md), an actor class may inherit from `NSObject`.

By default, the instance methods, properties, and subscripts of an actor type are actor-isolated to the actor instance. This is true even for methods added retroactively on an actor type via an extension, like any other Swift type.

```
extension BankAccount {
  func acceptTransfer(amount: Double) async { // actor-isolated
    balance += amount
  }
}  
```

An instance method, computed property, or subscript of an actor class may be annotated with `@actorIndependent` or a global actor attribute.  If so, it (or its accessors) are no longer actor-isolated to the `self` instance of the actor.

By default, the mutable stored properties (declared with `var`) of an actor class actor-isolated to the actor instance. A stored property may be annotated with `@actorIndependent(unsafe)` to remove this restriction. 

### Actor protocol

All actor classes conform to a protocol `Actor`:

```swift
protocol Actor: AnyObject {
  func enqueue(partialTask: PartialAsyncTask)
}
```

The `enqueue(partialTask:)` operation is a low-level operation used to queue work for the actor to execute. `PartialAsyncTask` represents a unit of work to execute. It effectively has a single synchronous function, `run()`, which should be called synchronously within the actor's context. Only the compiler can produce new `PartialAsyncTasks`. To explicitly enqueue work on an actor, use the `run` method:

```swift
extension Actor {
  // Run the given async function on this actor.
  //
  // Precondition: the function is not constrained to a different actor;
  //   if it is not constrained to any actor at all, it will still run on
  //   behalf of `self`
  func run<T>(operation: () async throws -> T) async rethrows -> T
}
```

The `enqueue(partialTask:)` requirement is special in that it can only be provided in the primary actor class declaration (not an extension), and cannot be `final`. If `enqueue(partialTask:)` is not explicitly provided, the Swift compiler will provide a default implementation for the actor, with its own (hidden) queue.

> **Rationale**: This design strikes a balance between efficiency for the default actor implementation and extensibility to allow alternative actor implementations.   By forcing the method to be part of the main actor class, the compiler can ensure a common low-level implementation for actor classes that permits them to be passed as a single pointer and treated uniformly by the runtime.

Non-`actor` classes can conform to the `Actor` protocol, and are not subject to the restrictions above. This allows existing classes to work with some `Actor`-specific APIs, but does not bring any of the advantages of actor classes (e.g., actor isolation) to them.

### Global actors

A global actor can be declared by creating a new custom attribute type with `@globalActor`:

```swift
@globalActor
struct UIActor {
  static let shared = SomeActorInstance()
}
```

The type must provide a static `shared` property that provides the singleton actor instance, on which any work associated with the global actor will be enqueued. There are otherwise no requirements placed on the type itself.

The custom attribute type may be generic.  The custom attribute is called a global actor attribute.  A global actor attribute is never parameterized.  Two global actor attributes identify the same global actor if they identify the same type.

Global actor attributes apply to declarations as follows:

* A declaration cannot have multiple have global actor attributes.  The rules below say that, in some cases, a global actor attribute is propagated from one declaration to another.  If the rules say that an attribute “propagates by default”, then no propagation is performed if the destination declaration has an explicit global actor attribute.  If the rules say that attribute “propagates mandatorily”, then it is an error if the destination declaration has an explicit global actor attribute that does not identify the same actor.  Regardless, it is an error if global actor attributes that do not identify the same actor are propagated to the same declaration.

* A function, property, subscript, or initializer declared with a global actor attribute becomes actor-isolated to the given global actor.

 ```swift
 @UIActor func drawAHouse(graphics: CGGraphics) {
     // ...
 }
 ```

* Local variables and constants cannot be marked with a global actor attribute. 

* A type declared with a global actor attribute propagates the attribute to all methods, properties, subscripts, and extensions of the type by default.

* An extension declared with a global actor attribute propagates the attribute to all the members of the extension by default.

* A protocol declared with a global actor attribute propagates the attribute to its conforming types by default.

* A protocol requirement declared with a global actor attribute propagates the attribute to its witnesses mandatorily if they are declared in the same module as the conformance. 

* A class declared with a global actor attribute propagates the attribute to its subclasses mandatorily.

* An overridden declaration propagates its global actor attribute (if any) to its overrides mandatorily.  Other forms of propagation do not apply to overrides.  It is an error if a declaration with a global actor attribute overrides a declaration without an attribute.

* An actor class cannot have a global actor attribute.  Stored instance properties of actor classes cannot have global actor attributes.  Other members of an actor class can have global actor attributes; such members are actor-isolated to the global actor, not the actor instance.

* A deinit cannot have a global actor attribute and is never a target for propagation.

The effect of these rules is to make it easy for a few classes and protocols to be annotated as being part of a global actor (e.g., the `@UIActor`), and for code that interoperates with those (subclassing the classes, conforming to the protocols) to not need explicit annotations.

### Actor-independent declarations

A declaration may be declared to be actor-independent:

```
@actorIndependent
var count: Int { constantCount + 1 }
```

When used on a declaration, it indicates that the declaration is not actor-isolated to any actor, which allows it to be accessed from anywhere. Moreover, it interrupts the implicit propagation of actor isolation from context, e.g., it can be used on an instance declaration in an actor class to make the declaration actor-independent rather than isolated to the actor.

When used on a class, the attribute applies by default to members of the class and extensions thereof.  It also interrupts the ordinary implicit propagation of actor-isolation attributes from the superclass, except as required for overrides.

The attribute is ill-formed when applied to any other declaration.  It is ill-formed if combined with an explicit global actor attribute.

The `@actorIndependent` attribute has an optional "unsafe" argument.  `@actorIndependent(unsafe)` differs from `@actorIndependent` only in the implementation of the declaration. Specifically, it allows the implementation to refer to actor-isolated state, which would be ill-formed under `@actorIndependent`.

### Actor isolation checking

Any given non-local declaration in a program can be classified into one of five actor isolation categories:

* Actor-isolated to a specific instance of an actor class:
  - This includes the stored instance properties of an actor class as well as computed instance properties, instance methods, and instance subscripts, as demonstrated with the `BankAccount` example.
* Actor-isolated to a specific global actor:
  - This includes any property, function, method, subscript, or initializer that has an attribute referencing a global actor, such as the `touchesEnded(_:with:)` method mentioned above.
* Actor-independent: 
  - The declaration is not actor-isolated to any actor. This includes any property, function, method, subscript, or initializer that has the `@actorIndependent` attribute.
* Actor-independent (unsafe): 
  - The declaration is not actor-isolated to any actor. This includes any property, function, method, subscript, or initializer that has the `@actorIndependent(unsafe)` attribute.
  - The declaration's definition is not subject to actor isolation checking.
* Unknown: 
  - The declaration is not actor-isolated to any actor, nor has it been explicitly determined that it is actor-independent. Such code might depend on shared mutable state that hasn't been modeled by any actor.

The actor isolation rules are checked in a number of places, where two different declarations need to be compared to determine if their usage together maintains actor isolation. There are several such places:
* When the definition of one declaration (e.g., the body of a function) accesses another declaration in executuable code, e.g., calling a function, accessing a property, or evaluating a subscript.
* When one declaration overrides another.
* When one declaration satisfies a protocol requirement.

We'll describe each scenario in detail.

#### Accesses in executable code

A given declaration (call it the "source") can access another declaration (call it the "target") in executable code, e.g., by calling a function or accessing a property or subscript. If the target is `async`, there is nothing more to check: the call will be scheduled on the target actor's queue, so the access is well-formed.

When the target is not `async`, the actor isolation categories for the source and target must be compatible. A source and target category pair is compatible if:
* the source and target categories are the same,
* the target category is actor-independent or actor-independent (unsafe),
* the source category is actor-independent (unsafe), or
* the target category is unknown.

The first rule is the most direct: an actor-isolated declaration can access other declarations within its same actor, whether that's an actor instance (on `self`) or global actor (e.g., `@UIActor`).

The second rule specifies that actor-independent declarations can be used from anywhere because they aren't tied to a particular actor. Actor classes can provide actor-independent instance methods, but because those functions are not actor-isolated, that cannot read the actor's own mutable state. For example:

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

The third rule is an unsafe opt-out that allows a declaration to be treated as actor-independent by its clients, but can do actor-isolation-unsafe operations internally. It is intended to be used sparingly for interoperability with existing  synchronization mechanisms or low-level performance tuning.

```swift
extension BankAccount {
  @actorIndependent(unsafe)
  func steal(amount: Double) {
    balance -= amount  // data-racy, but permitted due to (unsafe)
  }
}
```

The fourth rule is provided to allow interoperability between actors and existing Swift code. Actor code (which by definition is all new code) can call into existing Swift code with unknown actor isolation. However, code with unknown actor isolation cannot call back into (non-`async`) actor-isolated code, because doing so would violate the isolation guarantees of that actor. This allows incremental adoption of actors into existing code bases, isolating the new actor code while allowing them to interoperate with the rest of the code.

#### Overrides

When a given declaration (the "overriding declaration") overrides another declaration (the "overridden" declaration), the actor isolation of the two declarations is compared. The override is well-formed if:

* the overriding and overridden declarations have the same actor isolation or
* the overriding declaration is actor-independent.

In the absence of an explicitly-specified actor-isolation attribute (i.e, a global actor attribute or `@actorIndependent`), the overriding declaration will inherit the actor isolation of the overridden declaration.

#### Protocol conformance

When a given declaration (the "witness") satisfies a protocol requirement (the "requirement"), the actor isolation of the two declarations is compared. The protocol requirement can be satisfied by the witness if:

* the witness and requirement have the same actor isolation,
* the witness and requirement are `async` and the requirement has unknown actor isolation, or
* the witness is actor-independent and the requirement has unknown actor isolation.

The last case is particularly important to allow actor classes to conform to existing protocols, which will have synchronous requirements. For example, say that we want to make our `BankAccount` actor class conform to `CustomStringConvertible`:

```swift
extension BankAccount: CustomStringConvertible {
  var description: String {       // error: actor-isolated property "description" cannot be used to satisfy a protocol requirement
    "Bank account of \"\(ownerName)\""
  }
}
```

One can use `@actorIndependent` on such declarations to allow them to satisfy synchronous protocol requirements:

```swift
extension BankAccount: CustomStringConvertible {
  @actorIndependent
  var description: String {
    "Bank account of \"\(ownerName)\""
  }
}
```

In the absence of an explicitly-specified actor-isolation attribute, a witness that is defined in the same type or extension as the conformance for the requirement's protocol will have its actor isolation inferred from the protocol requirement.

## Source compatibility

This proposal is additive, and should not break source compatibility. The addition of the `actor` contextual keyword to introduce actor classes is a parser change that does not break existing code, and the other changes are carefully staged so they do not change existing code. Only new code that introduces actor classes or actor-isolation attributes will be affected.

## Effect on ABI stability

This is purely additive to the ABI.

## Effect on API resilience

Nearly all changes in actor isolation are breaking changes, because the actor isolation rules require consistency between a declaration and its users:

* A class cannot be turned into an actor class or vice versa.
* The actor isolation of a public declaration cannot be changed except between `@actorIndependent(unsafe)` and `@actorIndependent`.


