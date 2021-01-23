# Actors

* Proposal: [SE-NNNN](NNNN-actors.md)
* Authors: [John McCall](https://github.com/rjmccall), [Doug Gregor](https://github.com/DougGregor), [Konrad Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Partially available in [recent `main` snapshots](https://swift.org/download/#snapshots) behind the flag `-Xfrontend -enable-experimental-concurrency`

## Table of Contents

   * [Introduction](#introduction)
   * [Motivation](#motivation)
   * [Proposed solution](#proposed-solution)
      * [Actors](#actors-1)
      * [Actor isolation](#actor-isolation)
         * [Actor independence](#actor-independence)
         * [Closures](#closures)
         * [inout parameters](#inout-parameters)
      * [Actor reentrancy](#actor-reentrancy)
         * ["Interleaving" execution with reentrant actors](#interleaving-execution-with-reentrant-actors)
         * [Deadlocks with non-reentrant actors](#deadlocks-with-non-reentrant-actors)
         * [Unnecessary blocking with non-reentrant actors](#unnecessary-blocking-with-non-reentrant-actors)
         * [Existing practice](#existing-practice)
         * [Proposal: Default non-reentrant actors and opt-in reentrancy](#proposal-default-non-reentrant-actors-and-opt-in-reentrancy)
         * [Reentrancy Summary](#reentrancy-summary)
   * [Detailed design](#detailed-design)
      * [Actors](#actors-2)
      * [Actor-independent declarations](#actor-independent-declarations)
      * [Actor isolation checking](#actor-isolation-checking)
         * [Accesses in executable code](#accesses-in-executable-code)
         * [Overrides](#overrides)
         * [Protocol conformance](#protocol-conformance)
      * [Partial applications](#partial-applications)
      * [Reentrancy](#reentrancy)
   * [Source compatibility](#source-compatibility)
   * [Effect on ABI stability](#effect-on-abi-stability)
   * [Effect on API resilience](#effect-on-api-resilience)
   * [Alternatives Considered](#alternatives-considered)
      * [Task-chain reentrancy](#task-chain-reentrancy)
      * [Eliminating inheritance](#eliminating-inheritance)
   * [Revision history](#revision-history)

## Introduction

The [actor model](https://en.wikipedia.org/wiki/Actor_model) involves entities called actors. Each *actor* can perform local computation based on its own state, send messages to other actors, and act on messages received from other actors. Actors run independently, and cannot access the state of other actors, making it a powerful abstraction for managing concurrency in language applications. The actor model has been implemented in a number of programming languages, such as Erlang and Pony, as well as various libraries like Akka (on the JVM) and Orleans (on the .NET CLR).

This proposal introduces a design for *actors* in Swift, providing a model for building concurrent programs that are simple to reason about and are safer from data races. 

Swift-evolution thread: [Pitch #1](https://forums.swift.org/t/concurrency-actors-actor-isolation/41613)

## Motivation

One of the more difficult problems in developing concurrent programs is dealing with [data races](https://en.wikipedia.org/wiki/Race_condition#Data_race). A data race occurs when the same data in memory is accessed by two concurrently-executing threads, at least one of which is writing to that memory. When this happens, the program may behave erratically, including spurious crashes or program errors due to corrupted internal state. 

Data races are notoriously hard to reproduce and debug, because they often depend on two threads getting scheduled in a particular way. 
Tools such as [ThreadSanitizer](https://clang.llvm.org/docs/ThreadSanitizer.html) help, but they are necessarily reactive (as opposed to proactive)--they help find existing bugs, but cannot help prevent them.

Actors provide a model for building concurrent programs that are free of data races. They do so through *data isolation*: each actor protects is own instance data, ensuring that only a single thread will access that data at a given time. Actors shift the way of thinking about concurrency from raw threading to actors and put focus on actors "owning" their local state. This proposal provides a basic isolation model that protects the value-type state of an actor from data races. A full actor isolation model, which protects other state (such as reference types) is handled separately by [Preventing Data Races in the Swift Concurrency Model](https://gist.github.com/DougGregor/10db898093ce33694139d1dcd7da3397).

## Proposed solution

### Actors

This proposal introduces *actors* into Swift. An actor is a form of class that protects access to its mutable state, and is introduced with "actor":

```swift
actor BankAccount {
  private let accountNumber: Int
  private var balance: Double

  init(accountNumber: Int, initialDeposit: Double) {
    self.accountNumber = accountNumber
    self.balance = initialDeposit
  }
}
```

Actors behave like classes in most respects: they can inherit (from other actors), have methods, properties, and subscripts. They can be extended and conform to protocols, be generic, and be used with generics.

The primary difference is that actors protect their state from data races. This is enforced statically by the Swift compiler through a set of limitations on the way in which actors and their members can be used, collectively called *actor isolation*.   

### Actor isolation

Actor isolation is how actors protect their mutable state. For actors, the primary mechanism for this protection is by only allowing their stored instance properties to be accessed directly on `self`. For example, here is a method that attempts to transfer money from one account to another:

```swift
extension BankAccount {
  enum BankError: Error {
    case insufficientFunds
  }
  
  func transfer(amount: Double, to other: BankAccount) throws {
    if amount > balance {
      throw BankError.insufficientFunds
    }

    print("Transferring \(amount) from \(accountNumber) to \(other.accountNumber)")

    balance = balance - amount
    other.balance = other.balance + amount  // error: actor-isolated property 'balance' can only be referenced on 'self'
  }
}
```

If `BankAccount` were a normal class, the `transfer(amount:to:)` method would be well-formed, but would be subject to data races in concurrent code without an external locking mechanism. With actors, the attempt to reference `other.balance` triggers a compiler error, because `balance` may only be referenced on `self`.

As noted in the error message, `balance` is *actor-isolated*, meaning that it can only be accessed directly from within the specific actor it is tied to or "isolated by". In this case, it's the instance of `BankAccount` referenced by `self`. Stored properties, computed instance properties, instance subscripts, and instance methods (like `transfer(amount:to:)`) in an actor are all actor-isolated by default.

On the other hand, the reference to `other.accountNumber` is allowed, because `accountNumber` is immutable (defined by `let`). Once initialized, it is never written, so there can be no data races in accessing it. `accountNumber` is called *actor-independent*, because it can be freely used from any actor. Constants introduced with `let` are actor-independent by default; there is also an attribute `@actorIndependent` (described in the next section on [**Actor independence**](#actor-independence)) to specify that a particular declaration is actor-independent. 

Compile-time actor-isolation checking, as shown above, ensures that code outside of the actor does not interfere with the actor's mutable state. To work with the actor from outside of it, one must always do so with an asynchronous function invocation. Asynchronous function invocations are turned into enqueues of partial tasks representing those invocations to the actor's *queue* (as in, queue of tasks, not `DispatchQueue`). This queue, along with an exclusive task executor (which may be using dispatch queues) bound to the actor, functions as a synchronization boundary between the actor and any of its external callers. For example, if we wanted to make a deposit to a given bank account `account`, we could make a call to a method `deposit(amount:)`, and that call would be placed on the queue. The executor would pull tasks from the queue one-by-one, ensuring an actor is never concurrently running on multiple threads, and would eventually process the deposit.

Based on the above, we can implement a correct version of `transfer(amount:to:)`) that is asynchronous:

```swift
extension BankAccount {
  func transfer(amount: Double, to other: BankAccount) async throws {
    assert(amount > 0)

    if amount > balance {
      throw BankError.insufficientFunds
    }

    print("Transferring \(amount) from \(accountNumber) to \(other.accountNumber)")

    // Safe: this operation is the only one that has access to the actor's local
    // state right now, and there have not been any suspension points between
    // the place where we checked for sufficient funds and here.
    balance = balance - amount
    
    // Safe: the deposit operation is queued on the `other` actor, at which 
    // point it will update the other account's balance.    
    await other.deposit(amount: amount)
  }
}
```

The `deposit(amount:)` operation needs involve the state of a different actor, so it must be invoked asynchronously. This method could itself be implemented as `async`:

```swift
extension BankAccount {
  func deposit(amount: Double) async {
    assert(amount >= 0)
    balance = balance + amount
  }
}
```

However, this method doesn't really need to be `async`: it makes no asynchronous calls (note the lack of `await`). Therefore, it would be better defined as a synchronous function:

```swift
extension BankAccount {
  func deposit(amount: Double) {
    assert(amount >= 0)
    balance = balance + amount
  }
}
```

Synchronous actor functions can be called synchronously on the actor's `self`, but must be called asynchronously from outside of the actor. The `transfer(amount:to:)` function calls it asynchronously (on `other`), while the following function `passGo` calls it synchronously (on the implicit `self`):

```swift
extension BankAccount {
  // Pass go and collect $200
  func passGo() {
    deposit(amount: 200.0)  // synchronous is okay because this implicitly calls `self`
  }
}
```

Any interactions with the actor that involve mutable state (whether reads or writes) must be performed asynchronously. Semantically, an asynchronous call (such as `await other.deposit(amount: amount)`) to an actor is placed on the serial queue for the actor `other`, so that it will execute on that actor. If that actor is busy executing another task, then the caller will be suspended until the actor is available, so that other work can continue. 

> **Rationale**: by only allowing asynchronous calls from outside the actor, we ensure that all synchronous methods are already inside the actor when they are called. This eliminates the need for any queuing or synchronization within the synchronous code, making such code more efficient and simpler to write.


#### Actor independence

Some functions (and closures) that occur lexically within actors are actor-independent, meaning that they can be used from outside of the actor without necessarily requiring an asynchronous call. Immutable instance properties (like `BankAccount.accountNumber`) are one such example. It also possible to specify that a given instance method, property, or subscript is actor-independent with the attribute `@actorIndependent`. This allows us (for example) to define conformance of an actor to a protocol that has synchronous requirements:

```swift
extension BankAccount: Hashable {
  @actorIndependent
  func hash(into hasher: inout Hasher) {
    hasher.combine(accountNumber)
  }  
}

extension BankAccount: CustomStringConvertible {
  @actorIndependent
  var description: String {
    "Bank account #\(accountNumber)"
  }
}
```

There are two important things to note here:

1. Without the `@actorIndependent` attribute, the protocol conformance would be invalid, because an actor-isolated synchronous instance member cannot satisfy a synchronous protocol requirement. The compiler would produce an error such as
```
error: actor-isolated property "description" cannot be used to satisfy a protocol requirement
```
2. The `@actorIndependent` attribute means that the body of the function is treated as being outside the actor. For example, this means that one cannot access mutable actor state:
```swift
extension BankAccount: CustomDebugStringConvertible {
  @actorIndependent
  var debugDescription: String {
    "Bank account #\(accountNumber), balance = \(balance)"  // error: actor-isolated property 'balance' can not be referenced from an '@actorIndependent' context
  }
}
```

Actor independence occurs in a number of other places. All functions declared outside of an actor are actor-independent by nature (there is no actor `self`). Static members of the actor are actor-independent because `self` is not an instance. Within an actor function there are local functions and closures that may be actor-independent. This is important, for example, when one of those functions captures `self` but may be executed concurrently:

```swift
extension BankAccount {
  func endOfMonth(month: Int, year: Int) {
    // Schedule a task to prepare an end-of-month report.
    Task.runDetached { @actorIndependent in
      let transactions = await self.transactions(month: month, year: year)
      let report = Report(accountNumber: self.accountNumber, transactions: transactions)
      await report.email(to: self.accountOwnerEmailAddress)
    }
  }
}
```

The closure in the detached task will be run concurrently with other code on the actor so that the code that prepares the report (which could be compute-intensive) does not run on the serial queue for this actor. Operations on the actor `self`, such as the call to `transactions(month:year:)`, must therefore be asynchronous calls. The `@actorIndependent` will be inferred in some cases; see the section on [closures](#closures).

#### Closures

The restrictions on only allowing asynchronous access to actor-isolated declarations on `self` only work so long as we can ensure that the code in which `self` is valid is executing non-concurrently on the actor. For methods on the actor, this is established by the rules described above: asynchronous function calls are serialized via the actor's queue, and synchronous calls are only allowed when we know that we are already executing (non-concurrently) on the actor.

However, `self` can also be captured by closures. Should those closures have access to actor-isolated state on the captured `self`? Consider an example where we want to close out a bank account and distribute the balance amongst a set of accounts:

```swift
extension BankAccount {
  func close(distributingTo accounts: [BankAccount]) async {
    let transferAmount = balance / accounts.count

    accounts.forEach { account in 
      balance = balance - transferAmount             // is this safe?
      Task.runDetached {
        await account.deposit(amount: transferAmount)
      }  
    }
    
    await thief.deposit(amount: balance)
  }
}
```

The closure is accessing (and modifying) `balance`, which is part of the `self` actor's isolated state. Once the closure is formed and passed off to a function (in this case, `Sequence.forEach`), we no longer have control over when and how the closure is executed. On the other hand, we "know" that `forEach` is a synchronous function that invokes the closure on successive elements in the sequence. It is not concurrent, and the code above would be safe.

If, on the other hand, we used a hypothetical parallel for-each, we would have a data race when the closure executes concurrently on different elements:

```swift
accounts.parallelForEach { account in 
  self.balance = self.balance - transferAmount    // DATA RACE!
  await account.deposit(amount: transferAmount)
}
```

In this proposal, we assume that `forEach`'s closure parameter is *non-concurrent*, meaning that it will be executed serially, and that `parallelForEach`s closure parameter is *concurrent*, meaning that it can be executed concurrently with itself or with other code. For the purposes of this proposal, an escaping closure parameter is considered to be concurrent and a non-escaping closure parameter is considered to be non-concurrent. This is an heuristic that is discussed further and refined in a separate proposal on [Preventing Data Races in the Swift Concurrency Model](https://gist.github.com/DougGregor/10db898093ce33694139d1dcd7da3397).

A *concurrent* closure is inferred to be actor-independent (as if annotated with `@actorIndependent`). Therefore, the `parallelForEach` example would produce the following error:

```
error: actor-isolated property 'balance' is unsafe to reference in code that may execute concurrently
```

On the other hand, the `forEach` example is well-formed, because a non-concurrent closure that captures an actor `self` from an actor-isolated context is also actor-isolated. That allows the closure to access `self.balance` synchronously.

#### inout parameters

Actor-isolated stored properties can be passed into synchronous functions via `inout` parameters, but it is ill-formed to pass them to asynchronous functions via `inout` parameters. For example:

```swift
func modifiesSynchronously(_: inout Double) { }
func modifiesAsynchronously(_: inout Double) async { }

extension BankAccount {
  func wildcardBalance() async {
    modifiesSynchronously(&balance)        // okay
    await modifiesAsynchronously(&balance) // error: actor-isolated property 'balance' cannot be passed 'inout' to an asynchronous function
  }
}  
```

This restriction prevents exclusivity violations where the modification of the actor-isolated `balance` is initiated by passing it as `inout` to a call that is then suspended, and another task executed on the same actor then fails with an exclusivity violation in trying to access `balance` itself.

### Actor reentrancy

One critical point that needs to be discussed is whether actor-isolated functions are [reentrant](https://en.wikipedia.org/wiki/Reentrancy_(computing)). When an actor-isolated function suspends, reentrancy allows other work to execute on the actor before the original actor-isolated function resumes, which we refer to as *interleaving*. Reentrancy eliminates a source of deadlocks, where two actors depend on each other, and offers opportunities for better scheduling of (e.g.) higher-priority tasks. However, it means that actor-isolated state can change across an `await` when an interleaved task mutates that state, making it much harder to reason about the invariants of an actor within an asynchronous actor function.

This section explores the issue of reentrancy with examples that illustrate both the benefits and problems with both reentrant and non-reentrant actors, and settles on the following overall approach:
* Introduce an attribute to specifically control re-entrancy, spelled `@reentrant` and `@reentrant(never)`, which can be used to annotate actors and actor methods.
* Actors default to being `@reentrant`.

#### "Interleaving" execution with reentrant actors

Reentrancy means that execution of asynchronous actor-isolated functions may "interleave" at suspension points, leading to increased complexity in programming with such actors, as every suspension point must be carefully inspected if the code *after* it depends on some invariants that could have changed before it suspended.

Interleaving executions still respect the actor's "single-threaded illusion", i.e., no two functions will ever execute *concurrently* on any given actor. However they may *interleave* at suspension points. In broad terms this means that reentrant actors are *thread-safe* but are not automatically protecting from the "high level" kinds of races that may still occur, potentially invalidating invariants upon which an executing asynchronous function may be relying on. To further clarify the implications of this, let us consider the following actor, which thinks of an idea and then returns it, after telling its friend about it.

```swift
// @reentrant
actor Person {
  let friend: Friend
  
  // actor-isolated opinion
  var opinion: Judgment = .noIdea

  func thinkOfGoodIdea() async -> Decision {
    opinion = .goodIdea                       // <1>
    await friend.tell(opinion, heldBy: self)  // <2>
    return opinion // 🤨                      // <3>
  }

  func thinkOfBadIdea() async -> Decision {
    opinion = .badIdea                       // <4>
    await friend.tell(opinion, heldBy: self) // <5>
    return opinion // 🤨                     // <6>
  }
}
```

In the example above the `Person` can think of a good or bad idea, shares that opinion with a friend, and returns that opinion that it stored. Since the actor is reentrant this code is wrong and will return an arbitrary opinion if the actor begins to think of a few ideas at the same time.

This is exemplified by the following piece of code, exercising the `decisionMaker` actor:

```swift
async let shouldBeGood = person.thinkOfGoodIdea() // runs async
async let shouldBeBad = person.thinkOfBadIdea() // runs async

await shouldBeGood // could be .goodIdea or .badIdea ☠️
await shouldBeBad
```

> This issue is illustrated by using async lets, however also simply manifest by more than one actor calling out to the same decision maker; one invoking `thinkOfGoodIdea` and the other one `thinkOfBadIdea`.

This snippet _may_ result (depending on timing of the resumptions) in the following execution:

```swift
opinion = .goodIdea                // <1>
// suspend: await friend.tell(...) // <2>
opinion = .badIdea                 // | <4> (!)
// suspend: await friend.tell(...) // | <5>
// resume: await friend.tell(...)  // <2>
return opinion                     // <3>
// resume: await friend.tell(...)  // <5>
return opinion                     // <6>
```

But it _may_ also result in the "naively expected" execution, i.e. without interleaving, meaning that the issue will only show up intermittently, like many race conditions in concurrent code.

The potential for interleaved execution at suspension points is the primary reason for the requirement that every suspension point be [marked by `await`](https://github.com/apple/swift-evolution/blob/main/proposals/0296-async-await.md#suspension-points) in the source code, even though `await` itself has no semantic effect. It is an indicator that any shared state might change across the `await`, so one should avoid breaking invariants across an `await`, or otherwise depending on the state "before" to be identical to the state "after".

Generally speaking, the easiest way to avoid breaking invariants across an `await` is to encapsulate state updates in synchronous actor functions. Effectively, synchronous code in an actor provides a [critical section](https://en.wikipedia.org/wiki/Critical_section), whereas an `await` interrupts a critical section. For our example above, we could effect this change by separating "opinion formation" from "telling a friend your opinion". Indeed, telling your friend your opinion might reasonably cause you to change your opinion!

#### Deadlocks with non-reentrant actors

The opposite of reentrant actor functions are "non-reentrant" functions and actors. This means that while an actor is processing an incoming actor function call (message), it will *not* process any other message from its queue until it has completed running this initial function. Essentially, the entire actor is blocked from executing until that task completes.

If we take the example from the previous section and use a non-reentrant actor, it will execute correctly, because no work can be scheduled on the actor until `friend.tell` has completed:

```swift
@reentrant(never)
actor DecisionMaker {
  let friend: DecisionMaker
  var opinion: Judgment = .noIdea

  func thinkOfGoodIdea() async -> Decision {
    opinion = .goodIdea                                   
    await friend.tell(opinion, heldBy: self)
    return opinion // ✅ always .goodIdea
  }

  func thinkOfBadIdea() async -> Decision {
    opinion = .badIdea
    await friend.tell(opinion, heldBy: self)
    return opinion // ✅ always .badIdea
  }
}
```

However, non-entrancy can result in deadlock if a task involves calling back into the actor. For example, let's stretch this example further and have our friend try to convince us to change a bad idea:

```swift
extension DecisionMaker {
  func tell(_ opinion: Judgment, heldBy friend: DecisionMaker) async {
    if opinion == .badIdea {
      await friend.convinceOtherwise(opinion)
    }
  }
}
```

With non-reentrant actors, `thinkOfGoodIdea()` will succeed under this implementation, because `tell` essentially does nothing. However, `thinkOfBadIdea()` will deadlock because the original decision maker (call it `A`) is locked when it calls `tell` on another decision maker (call it `B`). `B` then tries to convince `A` otherwise, but that call cannot execute because `A` is already locked. Hence, the actor itself deadlocks and cannot progress.

> The term "deadlock" used in these discussions refer to actors asynchronously waiting on "each other," or on "future work of self". No thread blocking is necessary to manifest this issue.

In theory, a fully non-reentrant model would also deadlock when calling asynchronous functions on `self`. However, since such calls are statically determinable to be on `self`, they would execute immediately and therefore not block.

Deadlocks with non-reentrant actors can be detected and diagnosed with tools that can identify cyclic call graphs or through various logging/tracing facilities. With such deadlocks, the (asynchronous) call stack, annotated with the actor instances for each actor method, should suffice to debug the problem.

Deadlocked actors would be sitting around as inactive zombies forever. Some runtimes solve deadlocks like this by making every single actor call have a timeout (such timeouts are already useful for distributed actor systems). This would mean that each `await` could potentially `throw`, and that either timeouts or deadlock detection would have to always be enabled. We feel this would be prohibitively expensive, because we envision actors being used in the vast majority of concurrent Swift applications. It would also muddy the waters with respect to cancellation, which is intentionally designed to be explicit and cooperative. Therefore, we feel that the approach of automatically cancelling on deadlocks does not fit well with the direction of Swift Concurrency.

#### Unnecessary blocking with non-reentrant actors

Consider an actor that handles the download of various images and maintains a cache of what it has downloaded to make subsequent accesses faster:

```swift
@reentrant(never)
actor ImageDownloader { 
  var cache: [URL: Image] = [:]

  func getImage(_ url: URL) async -> Image {
    if let cachedImage = cache[url] {
      return cachedImage
    }
    
    let data = await download(url)
    let image = await Image(decoding: data)
    return cache[url, default: image]
  }
}
```

This actor is functionally correct, whether it is re-entrant or not. However, if it is non-reentrant, it will completely serialize the download of images: once a single client asked for an image, all other clients are blocked from starting any requests--even ones that would hit the cache or which ask for images at different URLs---until that first client has had its image fully downloaded and decoded.

With a reentrant actor, multiple clients can fetch images independently, so that (say) they can all be at different stages of downloading and decoding an image. The serialized execution of partial tasks on the actor ensures that the cache itself can never get corrupted. At worst, two clients might ask for the same image URL at the same time, in which there will be some redundant work. 

#### Existing practice

There are a number of existing actor implementations that have 

* Erlang/Elixir ([gen_server](https://medium.com/@eduardbme/erlang-gen-server-never-call-your-public-interface-functions-internally-c17c8f28a1ee)) showcases a simple "loop/deadlock" scenario and how to detect and fix it,
* Akka ([Persistence persist/persistAsync](https://doc.akka.io/docs/akka/current/persistence.html#relaxed-local-consistency-requirements-and-high-throughput-use-cases) is effectively _non-reentrant behavior by default_, and specific APIs are designed to allow programmers to _opt into_ reentrant whenever it would be needed. In the linked documentation `persistAsync` is the re-entrant version of the API, and it is used _very rarely_ in practice. Akka persistence and this API has been used to implement bank transactions and process managers, by relying on the non-reentrancy of `persist()` as a killer feature, making implementations simple to understand and _safe_. Note that Akka is built on top of Scala, which does not provide `async`/`await`. This means that mailbox-processing methods are more synchronous in nature, and rather than block the actor while waiting for a response, they would handle the response as a separate message receipt.
* Orleans ([grains](https://dotnet.github.io/orleans/docs/grains/reentrancy.html)) are also non-reentrant by default, but offer extensive configuration around reentrancy. Grains and specific methods can be marked as being re-entrant, and there is even a dynamic mechanism by which one can implement a run-time predicate to determine whether an invocation can interleave. Orleans is perhaps closest to the Swift approach described here, because it is built on top of a language that provides `async`/`await` (C#). Note that Orleans *ad* a feature called [call-chain reentrancy](https://dotnet.github.io/orleans/docs/grains/reentrancy.html#reentrancy-within-a-call-chain), which we feel is a promising potential direction: we cover it later in this proposal in our section on [task-chain reentrancy](#task-chain-reentrancy).


#### Proposal: Default reentrant actors and opt-in non-reentrancy

As noted previously, we propose that actors be reentrant by default, and provide an attribute (`@reentrant(never)`) to make specific actors or actor-isolated functions non-reentrant.

> **Rationale**: Reentrancy by default all but eliminates the potential for deadlocks. Moreover, it helps ensure that actors can make timely progress within a concurrent system, and that (say) a particular actor does not end up unnecessarily blocked on a long-running asynchronous operation (say, downloading a file). The mechanisms for ensuring safe interleaving, such as using synchronous code when performing mutations and being careful not to break invariants across `await` calls, are already present in the proposal.

#### Reentrancy Summary

Preventing reentrancy complicates the model slightly, as there are cases where deadlocks can happen, however the gained benefit of an actor _truly_ being an a domain in which external calls are linearized and handled one after the other. Thanks to non-reentrant actors we can think of them as collections of small programs (their async functions triggered externally) which are triggered and run to completion, and then handle the next task, which greatly simplifies the mental model when working with those.

So, from a consistency point of view, one might want to prefer non-reentrant actors, but from an high-priority work scheduling in the style of "run this now, at any cost" reentrant actors offer an useful model, preventing data-races, while allowing this interleaved execution which–if one is *very careful*–can be utilized to some benefit.

By offering developers the tools to pick which reentrancy model they need for their specific actor and actor functions, we allow users to pick the safe good default most of the time, and allow opt-ing into the more tricky to get right reentrant mode when developers know they need it. Marking single functions can also be used as a way to break actor deadlocks which could otherwise (rarely) occur if we didn't provide ways for reentrancy at all.

Thanks to structured concurrency and the `Task` primitives, we are able to relax the reentrancy rules such that they do not get in the way of typical pair-wise interactions between actors, but still protect from concurrent incoming requests causing confusing ordering interleaving execution. 

## Detailed design

### Actors

An actor type can be declared with the `actor` keyword:

```
/// Declares a new type BankAccount
actor BankAccount {
  // ...
}
```

Each instance of the actor represents a unique actor. The term "actor" can be used to refer to either an instance or the type; where necessary, one can refer to the "actor instance" or "actor type" to disambiguate.

An actor may only inherit from another actor. A non-actor may only inherit from another non-actor.

> **Rationale**: Actors enforce state isolation, but non-actors do not. If an actor inherits from a non-actor (or vice versa), part of the actor's state would not be covered by the actor-isolation rules, introducing the potential for data races on that state.

As a special exception described in the complementary proposal [Concurrency Interoperability with Objective-C](https://github.com/DougGregor/swift-evolution/blob/concurrency-objc/proposals/NNNN-concurrency-objc.md), an actor may inherit from `NSObject`.

By default, the instance methods, properties, and subscripts of an actor are actor-isolated to the actor instance. This is true even for methods added retroactively on an actor via an extension, like any other Swift type.

```
extension BankAccount {
  func acceptTransfer(amount: Double) async { // actor-isolated
    balance += amount
  }
}  
```

An instance method, computed property, or subscript of an actor may be annotated with `@actorIndependent`.  If so, it (or its accessors) are no longer actor-isolated to the `self` instance of the actor.

By default, the mutable stored properties (declared with `var`) of an actor are actor-isolated to the actor instance. A stored property may be annotated with `@actorIndependent(unsafe)` to remove this restriction. 

### Actor-independent declarations

A declaration may be declared to be actor-independent:

```
@actorIndependent
var count: Int { constantCount + 1 }
```

When used on a declaration, it indicates that the declaration is not actor-isolated to any actor, which allows it to be accessed from anywhere. Moreover, it interrupts the implicit propagation of actor isolation from context, e.g., it can be used on an instance declaration in an actor to make the declaration actor-independent rather than isolated to the actor.

When used on a class, the attribute applies by default to members of the class and extensions thereof.  It also interrupts the ordinary implicit propagation of actor-isolation attributes from the superclass, except as required for overrides.

When used on an extension, the attribute applies by default to members of that extension. It also interrupts the ordinary implicit propagation of actor-isolation attributes from the superclass (if there is one), except as required for overrides.

The attribute is ill-formed when applied to any other declaration.

The `@actorIndependent` attribute can also be applied to a closure. Such a closure will be independent of any actor, even if it captures the `self` from an actor-isolated function.

The `@actorIndependent` attribute has an optional "unsafe" argument.  `@actorIndependent(unsafe)` is treated the same way as `@actorIndependent` from the client's perspective, meaning that it can be used from anywhere. However, the implementation of an `@actorIndependent(unsafe)` entity is allowed to refer to actor-isolated state, which would have been ill-formed under `@actorIndependent`.

### Actor isolation checking

Any given non-local declaration in a program can be classified into one of four actor isolation categories:

* Actor-isolated to a specific instance of an actor:
  - This includes the stored instance properties of an actor as well as computed instance properties, instance methods, and instance subscripts, as demonstrated with the `BankAccount` example.
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

A given declaration (call it the "source") can synchronously access another declaration (call it the "target") in executable code, e.g., by calling a function or accessing a property or subscript. A synchronous invocation requires the actor isolation categories for the source and target to be compatible (defined below). An actor-isolated target function that is not compatible with the source can be accessed asynchronously.

A source and target category pair is compatible if:
* the source and target categories are the same,
* the target category is actor-independent or actor-independent (unsafe),
* the source category is actor-independent (unsafe), or
* the target category is unknown.

The first rule is the most direct: an actor-isolated declaration can synchronously access other declarations within its same actor (e.g., by referring to it on `self`).

The second rule specifies that actor-independent declarations can be used from anywhere because they aren't tied to a particular actor. Actors can provide actor-independent instance methods, but because those functions are not actor-isolated, that cannot read the actor's own mutable state. For example:

```swift
extension BankAccount {
  @actorIndependent
  func steal(amount: Double) {
    balance -= amount  // error: actor-isolated property 'balance' can not be referenced from an '@actorIndependent' context
  }
}  
```

The third rule is an unsafe opt-out that allows a declaration to be treated as actor-independent by its clients, but can do actor-isolation-unsafe operations internally. It is intended to be used sparingly for interoperability with existing synchronization mechanisms, low-level performance tuning, or incremental adoption of actors in existing code bases.

```swift
extension BankAccount {
  @actorIndependent(unsafe)
  func steal(amount: Double) {
    balance -= amount  // data-racy, but permitted due to (unsafe)
  }
}
```

The fourth rule is provided to allow interoperability between actors and existing Swift code. Actor code (which by definition must be new code) can call into existing Swift code with unknown actor isolation. However, code with unknown actor isolation cannot call back into actor-isolated code synchronously, because doing so would violate the isolation guarantees of that actor. This allows incremental adoption of actors into existing code bases, isolating the new actor code while allowing them to interoperate with the rest of the code.

#### Overrides

When a given declaration (the "overriding declaration") overrides another declaration (the "overridden" declaration), the actor isolation of the two declarations is compared. The override is well-formed if:

* the overriding and overridden declarations have the same actor isolation or
* the overriding declaration is actor-independent.

In the absence of an explicitly-specified actor-isolation attribute (i.e, `@actorIndependent`), the overriding declaration will inherit the actor isolation of the overridden declaration.

#### Protocol conformance

When a given declaration (the "witness") satisfies a protocol requirement (the "requirement"), the actor isolation of the two declarations is compared. The protocol requirement can be satisfied by the witness if:

* the witness and requirement have the same actor isolation,
* the requirement is `async`, or
* the witness is actor-independent.

In the absence of an explicitly-specified actor-isolation attribute, a witness that is defined in the same type or extension as the conformance for the requirement's protocol will have its actor isolation inferred from the protocol requirement.

### Partial applications

Partial applications of synchronous actor-isolated functions are only well-formed if they are treated as non-concurrent. For example, given a function like this:

```swift
extension BankAccount {
  func synchronous() { }
}
```

The expression `self.synchronous` is well-formed only if it is the direct argument to a function whose corresponding parameter is non-concurrent. Otherwise, it is ill-formed because the function might be called in a context that is not actor-isolated.

### Reentrancy

The `@reentrant` attribute may be added to any actor-isolated function, actor, or extension of an actor. The attribute has two forms:

* `@reentrant`: Indicates that each potential suspension point within the function bodies covered by the attribute is reentrant.
* `@reentrant(never)`: Indicates that each potential suspension point within the function bodies covered by the attribute is non-reentrant.

A non-reentrant potential suspension point prevents any other asynchronous call from executing on the actor until it has completed. Note that asynchronous calls to non-reentrant async functions directly on `self` are exempted from this check, so an actor can asynchronously call itself without producing a deadlock.

> **Rationale**: Allowing direct calls on `self` eliminates an obvious set of deadlocks, and requires only the same static knowledge as actor-isolation checking for synchronous access to actor-isolated state.

It is an error to have a `@reentrant` attribute on an actor-independent function, non-actor type, or extension of a non-actor type. Only one `@reentrant` attribute may occur on a given declaration. The reentrancy of an actor-isolated declaration is determined by finding a suitable `@reentrant` attribute. The search is as follows:

1. The declaration itself.
2. If the declaration is within an extension, the extension.
3. If the declaration is within a type (or extension thereof), the type definition.

If there is no suitable `@reentrant` attribute, an actor-isolated function is reentrant.

## Source compatibility

This proposal is additive, and should not break source compatibility. The addition of the `actor` contextual keyword to introduce actors is a parser change that does not break existing code, and the other changes are carefully staged so they do not change existing code. Only new code that introduces actors or actor-isolation attributes will be affected.

## Effect on ABI stability

This is purely additive to the ABI.

## Effect on API resilience

Nearly all changes in actor isolation are breaking changes, because the actor isolation rules require consistency between a declaration and its users:

* A class cannot be turned into an actor or vice versa.
* The actor isolation of a public declaration cannot be changed except between `@actorIndependent(unsafe)` and `@actorIndependent`.

## Alternatives Considered

### Task-chain reentrancy

The discussion of reentrant and non-reentrant actors treats reentrancy as a binary choice, where all forms of reentrancy are considered to be equally likely to introduce hard-to-reason-about data races. However, a frequent and usually quite understandable way of interacting between actors which are simply "conversations" between two or more actors in order fo fulfill some initial request. In synchronous code, it's common to have two or more different classes call back into each other with synchronous calls. For example, here is a silly implementation of `isEven` that uses mutual recursion between two classes:

```swift
class OddOddySync {
  let evan: EvenEvanSync!

  func isOdd(_ n: Int) -> Bool {
    if n == 0 { return true }
    return evan.isEven(num - 1)
  }
}

class EvenEvanSync {
  let oddy: OddOddySync!

  func isEven(_ n: Int) -> Bool {
    if n == 0 { return false }
    return oddy.isOdd(num - 1)
  }
}
```

This code is depending on the two methods of these classes to effectively be "reentrant" within the same call stack, because one will call into the other (and vice-versa) as part of the computation. Now, take this example and make it asynchronous using actors:

```swift
actor OddOddy {
  let evan: EvenEvan!

  func isOdd(_ n: Int) async -> Bool {
    if n == 0 { return true }
    return await evan.isEven(num - 1)
  }
}

actor EvenEvan {
  let oddy: OddOddy!

  func isEven(_ n: Int) async -> Bool {
    if n == 0 { return false }
    return await oddy.isOdd(num - 1)
  }
}
```

Under the current proposal, this code will deadlock, because a call from `EvanEvan.isEven` to `OddOddy.isOdd` will then depend on another call to `EvanEvan.isEven`, which cannot proceed until the original call completes. One would need to make these methods reentrant to eliminate the deadlock.

With Swift embracing [Structured Concurrency](https://github.com/DougGregor/swift-evolution/blob/structured-concurrency/proposals/nnnn-structured-concurrency.md) as a core building block of its concurrency story, we may be able to do better than outright banning reentrancy. In Swift, every asynchronous operation is part of a `Task` which encapsulates the general computation taking place, and every asynchronous operation spawned from such task becomes a child task of the current task. Therefore, it is possible to know whether a given asynchronous call is part of the same task hierarchy, which is the rough equivalent to being in the same call stack in synchronous code.

We could introduce a new kind of reentrancy, *task-chain reentrancy*, which allows reentrant calls on behalf of the given task or any of its children. This resolves both the deadlock we encountered in the `Waiter` and `Kitchen` example from the section on [deadlocks](#deadlocks-with-non-reentrant-actors) as well as the mutually-recursive `isEven` example above, while still preventing reentrancy from unrelated tasks. This reentrancy therefore mimics synchronous code more closely, eliminating many deadlocks without allow unrelated interleavings to break the high-level invariants of an actor.

There are a few reasons why we are not currently comfortable including task-chain reentrancy in the proposal:
* The task-based reentrancy approach doesn't seem to have been tried at scale. Orleans documents support for [reentrancy in a call chain](https://dotnet.github.io/orleans/docs/grains/reentrancy.html#reentrancy-within-a-call-chain), but the implementation was fairly limited and it was eventually [removed](https://twitter.com/reubenbond/status/1349725703634251779). From the Orleans experience, it is hard to assess whether the problem is with the idea or the specific implementation.
* We do not yet know of an efficient implementation technique for this approach within the actor runtime.

If we can address the above, task-chain reentrancy can be introduced into the actor model with another spelling of the reentrancy attribute such as `@reentrant(task)`, and may provide a more suitable default than non-reentrant (`@reentrant(never)`).

### Eliminating inheritance

Like classes, actors as proposed allow inheritance. However, actors and classes cannot be co-mingled in an inheritance hierarchy, so there are essentially two different kinds of type hierarchies. It has been [proposed](https://docs.google.com/document/d/14e3p6yBt1kPrakLcEHV4C9mqNBkNibXIZsozdZ6E71c/edit#) that actors should not permit inheritance at all, because doing so would simplify actors: features such as method overriding, initializer inheritance, required and convenience initializers, and inheritance of protocol conformances would not need to be specified, and users would not need to consider them. The [discussion thread](https://forums.swift.org/t/actors-are-reference-types-but-why-classes/42281) on the proposal to eliminate inheritance provides several reasons to keep actor inheritance:

* Actor inheritance makes it easier to port existing class hierarches to get the benefits of actors. Without actor inheritance, such porting will also have to contend with (e.g.) replacing superclasses with protocols and explicitly-specified stored properties at the same time.
* The lack of inheritance in actors won't prevent users from having to understand the complexities of inheritance, because inheritance will still be used pervasively with classes.
* The design and implementation of actors naturally admits inheritance. Actors are fundamentally class-like, the semantics of inheritance follow directly from the need to maintain actor isolation. The implementation of actors is essentially as "special classes", so it supports all of these features out of the box. There is little benefit to the implementation from eliminating the possibility of inheritance of actors.

Overall, we feel that actor inheritance has use cases just like class inheritance does, and the reasons to avoid having inheritance as part of the actor model are driven more by a desire to move Swift away from inheritance than by any practical or implementation problems with inheritance.

## Revision history

* Changes in the second pitch:
  * Added a discussion of the tradeoffs with actor reentrancy, performance, and deadlocks, with various examples, and the addition of new attribute `@reentrant(never)` to disable reentrancy at the actor or function level.
  * Removed global actors; they will be part of a separate document.
  * Separated out the discussion of data races for reference types.
  * Allow asynchronous calls to synchronous actor methods from outside the actor.
  * Removed the `Actor` protocol; we'll tackle customizing actors and executors in a separate proposal.
  * Clarify the role and behavior of actor-independence.
  * Add a section to "Alternatives Considered" that discusses actor inheritance.
  * Replace "actor class" with "actor".

* Original pitch [document](https://github.com/DougGregor/swift-evolution/blob/6fd3903ed348b44496b32a39b40f6b6a538c83ce/proposals/nnnn-actors.md)
