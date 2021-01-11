# Actors

* Proposal: [SE-NNNN](NNNN-actors.md)
* Authors: [John McCall](https://github.com/rjmccall), [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Partial available in [recent `main` snapshots](https://swift.org/download/#snapshots) behind the flag `-Xfrontend -enable-experimental-concurrency`

## Introduction

The [actor model](https://en.wikipedia.org/wiki/Actor_model) involves entities called actors. Each *actor* can perform local computation based on its own state, send messages to other actors, and act on messages received from other actors. Actors run independently, and cannot access the state of other actors, making it a powerful abstraction for managing concurrency in language applications. The actor model has been implemented in a number of programming languages, such as Erlang and Pony, as well as various libraries like Akka (on the JVM) and Orleans (on the .NET CLR).

This proposal introduces a design for *actors* in Swift, providing a model for building concurrent programs that are simple to reason about and are safer from data races.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

One of the more difficult problems in developing concurrent programs is dealing with [data races](https://en.wikipedia.org/wiki/Race_condition#Data_race). A data race occurs when the same data in memory is accessed by two concurrently-executing threads, at least one of which is writing to that memory. When this happens, the program may behave erratically, including spurious crashes or program errors due to corrupted internal state. 

Data races are notoriously hard to reproduce and debug, because they often depend on two threads getting scheduled in a particular way. 
Tools such as [ThreadSanitizer](https://clang.llvm.org/docs/ThreadSanitizer.html) help, but they are necessarily reactive (as opposed to proactive)--they help find existing bugs, but cannot help prevent them.

Actors provide a model for building concurrent programs that are free of data races. They do so through *data isolation*: each actor protects is own instance data, ensuring that only a single thread will access that data at a given time. Actors shift the way of thinking about concurrency from raw threading to actors and put focus on actors "owning" their local state. This proposal provides a basic isolation model that protects the value-type state of an actor from data races. A full actor isolation model, which protects other state (such as reference types) is left as future work.

## Proposed solution

### Actor classes

This proposal introduces *actor classes* into Swift. An actor class is a form of class that protects access to its mutable state, and is introduced with "actor class":

```swift
actor class BankAccount {
  private let ownerName: String
  private var balance: Double
}
```

Actor classes behave like classes in most respects: they can inherit (from other actor classes), have methods, properties, and subscripts. They can be extended and conform to protocols, be generic, and be used with generics.

The primary difference is that actor classes protect their state from data races. This is enforced statically by the Swift compiler through a set of limitations on the way in which actors and their members can be used, collectively called *actor isolation*.   

### Actor isolation

Actor isolation is how actors protect their mutable state. For actor classes, the primary mechanism for this protection is by only allowing their stored instance properties to be accessed directly on `self`. For example, here is a method that attempts to transfer money from one account to another:

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

On the other hand, the reference to `other.ownerName` is allowed, because `ownerName` is immutable (defined by `let`). Once initialized, it is never written, so there can be no data races in accessing it. `ownerName` is called *actor-independent*, because it can be freely used from any actor. Constants introduced with `let` are actor-independent by default; there is also an attribute `@actorIndependent` (described in [**Actor-independent declarations**](#actor-independent-declarations)) to specify that a particular declaration is actor-independent.

> **Note**: Constants defined by `let` are only truly immutable when the type is a value type or some kind of immutable reference type. A `let` that refers to a mutable reference type (such as a non-actor class type) would be unsafe based on the rules discussed so far. These issues are discussed later in [**Escaping reference types**](#escaping-reference-types).

Compile-time actor-isolation checking, as shown above, ensures that code outside of the actor does not interfere with the actor's mutable state. 

Asynchronous function invocations are turned into enqueues of partial tasks representing those invocations to the actor's *queue*. This queue—along with an exclusive task executor bound to the actor—functions as a synchronization boundary between the actor and any of its external callers. For example, if we wanted to make a deposit to a given bank account `account`, we could make a call to a method `deposit(amount:)`, and that call would be placed on the queue. The executor would pull tasks from the queue one-by-one, ensuring an actor never is concurrently running on multiple threads, and would eventually process the deposit.

Synchronous functions in Swift are not amenable to being placed on a queue to be executed later. Therefore, synchronous instance methods of actor classes are actor-isolated and, therefore, not available from outside the actor instance. For example:

```swift
extension BankAccount {
  func depositSynchronously(amount: Double) {
    assert(amount >= 0)
    balance = balance + amount
  }
}

func printMoney(accounts: [BankAccount], amount: Double) {
  for account in accounts {
    account.depositSynchronously(amount: amount) // error: actor-isolated instance method 'depositSynchronously(amount:)' can only be referenced inside the actor
  }
}
```

It should be noted that actor isolation adds a new dimension, separate from access control, to the decision making process whether or not one is allowed to invoke a specific function on an actor. Specifically, synchronous functions may only be invoked by the specific actor instance itself, and not even by any other instance of the same actor class. 

All interactions with an actor (other than the special-cased access to constants) must be performed asynchronously (semantically, one may think about this as the actor model's messaging to and from the actor). Asynchronous functions provide a mechanism that is suitable for describing such operations, and are explained in depth in the complementary [async/await proposal](https://github.com/DougGregor/swift-evolution/blob/async-await/proposals/nnnn-async-await.md). We can make the `deposit(amount:)` instance method `async`, and thereby make it accessible to other actors (as well as non-actor code):

```swift
extension BankAccount {
  func deposit(amount: Double) async {
    assert(amount >= 0)
    balance = balance + amount
  }
}
```

Now, the call to this method (which now must be adorned with [`await`](https://github.com/DougGregor/swift-evolution/blob/async-await/proposals/nnnn-async-await.md#await-expressions)) is well-formed:

```swift
await account.deposit(amount: amount)
```

Semantically, the call to `deposit(amount:)` is placed on the queue for the actor `account`, so that it will execute on that actor. If that actor is busy executing a task, then the caller will be suspended until the actor is available, so that other work can continue. See the section on [asynchronous calls](https://github.com/DougGregor/swift-evolution/blob/async-await/proposals/nnnn-async-await.md#asynchronous-calls) in the async/await proposal for more detail on the calling sequence.

> **Rationale**: by only allowing asynchronous instance methods of actor classes to be invoked from outside the actor, we ensure that all synchronous methods are already inside the actor when they are called. This eliminates the need for any queuing or synchronization within the synchronous code, making such code more efficient and simpler to write.

We can now properly implement a transfer of funds from one account to another:

```swift
extension BankAccount {
  func transfer(amount: Double, to other: BankAccount) async throws {
    assert(amount > 0)
    
    if amount > balance {
      throw BankError.insufficientFunds
    }

    print("Transferring \(amount) from \(ownerName) to \(other.ownerName)")

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

### Actor reentrancy (discussion)

One critical point that needs to be discussed and fleshed out is whether actors are [reentrant](https://en.wikipedia.org/wiki/Reentrancy_(computing)) by default or not.

The notion of reentrancy allows the actor runtime to claim the complete elimination of deadlocks, offers opportunity for scheduling optimization techniques where a "high priority task" _must_ be executed as soon as possible, however at the cost of _interleaving_ with any other actor-isolated function's execution any other asynchronous function declared on this actor. This imposes a large mental burden on developers, as every single actor function currently has to be implemented keeping reentrancy in mind, which effectively fails on delivering the promise of pain-free concurrency for the majority of use-cases.

Currently, this proposal takes the aggressive approach of assuming _all_ actors are reentrant and not providing ways to opt out of this behavior. This section aims to highlight issues, benefits and tradeoffs with this approach as well as non-reentrancy in general. The goal of discussing these reentrancy issues, is to arrive at a design that is developer friendly, non-surprising, and delivers more completely on Swift's promise of _safe_ and _pain-free_ concurrency by default thanks to the use of actors.

#### Reentrant actors: "Interleaving" execution

Reentrancy means that execution of asynchronous actor-isolated functions may "interleave" at suspension points, leading to increased complexity in programming with such actors, as every suspension point must be carefully inspected if the code _after_ it depends on some invariants that could have changed before it suspended.

Interleaving executions still respect the actor's "single-threaded illusion"–i.e. no two functions will ever execute *concurrently* on any given actor–however they may _interleave_ at suspension points. In broad terms this means that reentrant actors are _thread-safe_ but are not automatically protecting from the "high level" kinds of races that may still occur, potentially invalidating invariants upon which an executing asynchronous function may be relying on.

> Empirically: we know that both an non-reentrant and reentrant awaiting and actors are useful, however both semantics must be available to developers in order to use actors as a means of isolating state from "concurrent" (in the meaning of interleaved) modification.

To further clarify the implications of this, let us consider the following actor, which thinks of an idea and then returns it, after telling its friend about it.

```swift
// reentrant actor
actor class Person {
  let friend: Friend
  
  // actor-isolated opinion
  var opinion: Judgement = .noIdea

  func thinkOfGoodIdea() async -> Decision {
    opinion = .goodIdea                     // <1>
    await friend.tell(opinion)              // <2>
    return opinion // 🤨                    // <3>
  }

  func thinkOfBadIdea() async -> Decision {
    opinion = .badIdea                     // <4>
    await friend.tell(opinion)             // <5>
    return opinion // 🤨                   // <6>
  }
}
```

> Reentrant code is notoriously difficult to program with–one is protected from low level data-races, however the higher level semantic races may still happen. In the examples shown, the states are small enough that they are simple to fit in one's hear so they do not appear as tricky, however in the real world races can be dauntingly hard to debug.

In the example above the `Person` can think of a good or bad idea, shares that opinion with a friend, and returns that opinion that it stored. Since the actor is reentrant this code is **wrong** and will return an _arbitrary opinion_ if the actor begins to think of a few ideas at the same time.

This is exemplified by the following piece of code, exercising the `decisionMaker` actor:

```swift
async let shouldBeGood = person.thinkOfGoodIdea() // runs async
async let shouldBeBad = person.thinkOfBadIdea() // runs async

await shouldBeGood // could be .goodIdea or .badIdea ☠️
await shouldBeBad
```

> This issue is illustrated by using async lets, however also simply manifest by more than 1 actor calling out to the same decision maker; one invoking `thinkOfGoodIdea` and the other one `thinkOfBadIdea`, a reentrant actor is not protecting us from such race conditions, making the programming model unnecessarily hard to reason about.

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

But it _may_ also result in the "naively expected" execution, i.e. without interleaving, making the problem even trickier, because as with normal race conditions in concurrent code -- the issue will only show up when exercised in more real usage patterns, rather than early on in unit testing.

With this example we have showcased that reentrant actors, by design, do not prevent "high-level" race conditions. They only prevent "low-level" data-races, as in: concurrent access to some variable they protect etc.

Please note that the example here a simple single variable state, yet already it can catch people off guard because how similar it looks to synchronous code. The problem is greatly exaggerated in real applications where actors are used to isolate and protect complex state transitions. Because actors effectively can only communicate through async calls to other parts of the system, a typical actor function will not have one or two suspension points but many of them - leading to exponential growth of the possible states an actor function may observe during it's execution.

> Existing actor implementations err on the side of non-reentrant actors by default, allowing for reentrancy to be optionally opted-into.
>
> - Erlang/Elixir ([gen_server](https://medium.com/@eduardbme/erlang-gen-server-never-call-your-public-interface-functions-internally-c17c8f28a1ee)) - showcases a simple "loop/deadlock" scenario and how to detect and fix it,
> - Orleans ([Grains](https://dotnet.github.io/orleans/docs/grains/reentrancy.html)) offer extensive declarative configuration around reentrancy, it is also the closest to the Swift actors model,
> - Akka ([Persistence persist/persistAsync](https://doc.akka.io/docs/akka/current/persistence.html#relaxed-local-consistency-requirements-and-high-throughput-use-cases) does not have async/await support because Scala's lack of it so the general problem does not show up as painfully as in languages with it, however it effectively is _non-reentrant behavior by default_, and specific APIs are designed to allow programmers to _opt into_ reentrant whenever it would be needed. In the linked documentation `persistAsync` is the re-entrant version of the API, and it is used _very rarely_ in practice. Akka persistence and this API has been used to implement bank transactions and process managers, by relying on the non-reentrancy of `persist()` as a killer feature, making implementations simple to understand and _safe_.

#### Non-reentrant actors: Deadlocks

The opposite of reentrant actor functions are "non-reentrant" functions and actors. This means that while an actor is processing an incoming actor function call (message), it will _not_ process any other message from its queue until it has completed running this initial function.

In Swift's actor model, calling actor-isolated functions on `self` would be still allowed and not deadlock the actor, however if a cyclic call from A to B could only be fulfilled by A completing a request from B, we would end up with a deadlock. Generally though, such call cycles are uncommon, and when they happen, they can be diagnosed easily either in debugging of call graphs (if/when we would gain tooling for such), or by inspecting the calls made by actors by using [(swift distributed) tracing](https://github.com/apple/swift-distributed-tracing)) libraries.

If look at the example from the previous section, but now assume that actors are non-reentrant, it is _trivially correct_ and behaves just like a newcomer to actor model and async/await would expect it to behave in the first place:

```swift
// *non-reentrant* actor
actor class DecisionMaker {
  let friend: Friend
  var opinion: Judgement = .noIdea

  func thinkOfGoodIdea() async -> Decision {
    opinion = .goodIdea                                   
    _ = await consultWith(friend, myOpinion: opinion)
    return opinion // ✅ always .goodIdea
  }

  func thinkOfBadIdea() async -> Decision {
    opinion = .badIdea
    _ = await tell(friend, myOpinion: opinion)
    return opinion // ✅ always .badIdea
  }
}
```

This allows programmers to really embrace the "as if single threaded, normal function" programming mindset when using (non-reentrant) actors. This benefit comes at a cost however: the potential for deadlocks.

> The term "deadlock" used in these discussions refer to actors asynchronously waiting on "each other," or on "future work of self". No thread blocking is necessary to manifest this issue.
>
> In theory the Swift runtime may still keep special reentrant functions on actors to "kill" unresponsive ones.

Deadlocks can, in the naïve non-reentrant model, can appear in the following situations:

- **dependency loops**
  - description: actor `A` requesting (and awaiting) on a call to `B`, and `B` then calling (and awaiting) on something from `A` directly (or indirectly)
  - solution: such loops are possible to detect and crash on with tracing systems or debugging systems in general, and are usually easy to resolve once the call-chain is diagnosed
- **awaiting on future work** (performed by self)
  - description: is a form of the loop case, however can happen in some more surprising cases, say spawning a detached task that calls into self
  - solution: this again is possible to diagnose with tracing and debugging tools

To illustrate the issue a bit more, let us consider this example:

```swift
// naïvely non-reentrant
actor class Kitchen {
  func order(order: MealOrder, from waiter: Waiter) async -> Confirmation {
    await waiter.areYouSure() // deadlock ☠️
  }
}

// naïvely non-reentrant
actor class Waiter {
  let kitchen: Kitchen
  func order(order: MealOrder) async -> Confirmation {
    await kitchen.order(order: order, waiter: self)
  }
}
```

In this example the deadlock is relatively simple to spot and diagnose. Perhaps such simple cases we could even diagnose statically someday. It may happen however that deadlocks are not easy to diagnose, in which case tracing and other diagnostic systems could help.

Deadlocked actors would be sitting around as inactive zombies forever, because normal swift async calls do not include timeouts.

Some runtimes solve this by making *every single actor call have a timeout*. This would mean that each await could potentially throw, and that either timeouts or deadlock detection would have to always be enabled - which would be prohibitively expensive since we envision actors being used in the vast majority of concurrent Swift applications. It would also muddy the waters with respect to cancellation, which intentionally is designed to be explicit and cooperative, and as checking timeouts/deadlines is a form of cancellation, this is _not_ something we are going to support transparently, thus actor calls neither may assume this. 

It is easy to point out a small mistake in actors spanning a few lines of code, however programming complex actors with reentrancy can be quite a challenge. In this specific example, the solution–in hindsight–is simple, we should store the opinion in a function local variable, or in other words, any state the actor needs to to complete an execution "atomically" it must copy into local function scope. This can be hard to remember and manage consistently.

> Depending on one's viewpoint, one could actually claim that deadlocks are better (!), than interleaving because they can be reliably detected and explained by tools, can be detected in fuzz tests (no need to know what the correct result is for a random input), and can be fixed more consistently.

#### Reentrancy and async lets

Swift also offers the `async let` declaration style, allowing for expressing structured bounded number of asynchronous child tasks being performed concurrently.

In order to check our assumptions, let us also write some code using `async let` and see how reentrancy does or does not come into play here:

```swift
actor class Friend {
  func howMuchDoYouNeed() async -> Amount { ... }
  func send(cash: Amount) async { ... }
}

actor class Wallet {
  let friend: Friend = ... 
  
  var amount: Amount = ... 
  func checkCash() async -> Amount { ... }
  
  func lendFriendSomeCash() async  {
    async let requested = friend.howMuchDoYouNeed() 
    async let debt = checkDebt()
    async let cash = checkCash()
    let available = await cash - debt.amount
    
    if await requested <= available { 
      amount -= requested
      await friend.send(cash: requested) // ✅        
    }  
  }

  func loseWallet() async { 
    amount = 0
  }
}
```

This example composes well; Calls to an actor's `self` are allowed to pass through as usual, and _replies_ from other actors are also accepted. What can _not_ happen with non-reentrant actors is the `loseWallet()` function being randomly triggered while we are attempting to lend our friend some cash -- this would have been an external call into the actor, which our non-reentrancy rule would prevent.

So even such snippet (under non-reentrancy rules):


```swift
await wallet.lendFriendSomeCash()
await wallet.loseWallet() 
```

would be correct. Even if our friend takes 10 minutes to reply to `howMuchDoYouNeed`, we are being patient with them and wait with processing the next _external_ message (that will cause us to lose our wallet), until after we are done lending our friend some cash.

Under reentrant rules, the above code could be unsafe, changing our wallet's balance to zero right before we are about to decrement it (!).

#### Proposal: Default non-reentrant actors and opt-in reentrancy

We could amend our model with the following changes:

- actors are **non-**reentrant by default
  - external calls from other actors are performed "one by one," they cannot automatically "jump in front of the queue"
- actors which want all their functions to be able to interleave each other, may annotate their definition using `@reentrant` assumes all of it's functions are `@reentrant`

> Alternate spelling proposals follow below the example.

The rationale to make actors non-reentrant by default is clear: it is what feels natural and what actually enables "write as if synchronous code in an actor, and it just works" style of programming.

However, there are valid and important cases where we _do_ want to enable reentrant calls - e.g. a high priority message changing how we are processing a long running task inside an actor:

```swift
actor class ImageDownloader { 
  var bestImages: [Image]
  var currentBest: Image?

  @reentrant // ✅ may be invoked at any point in time 
  func downloadAndPickBest(n: Int, urls: [URL]) async -> [Image] {
    for url in urls {
      let image = await download(url)
      bestImages.append(image)
      let ranking = await rank(image) 
      if ranking.isBest { 
        bestImage = image  
      }
      // ... more things to compute only the "best n" etc...
    }

    return images
  }
  
  func currentBest() async -> Image { 
    currentBest
  } 
}
```

The above illustrates a popular use-case for reentrant calls: read only calls. They can be used to observe progress, request a "best effort" answer while better answers are being processed still, or one can invoke a cancel function to cancel some ongoing work inside an actor from another one.

Optionally, we could consider an `@interleave(readOnly)` or annotation that allows for adding "read only" queries to actors, even for actors which otherwise are non-reentrant. In the above example we could then annotate `concurrentBest` as such, and even if the other functions are not `@reentrant` such read-only function could interleave them. We _could_ extend the model to `@interleave(unsafe)` if we really needed to open up that backdoor, but we suggest to leave this out on purpose. 

The issue and solutions to it are not new, and have been successfully proven in [Orleans's take on the subject](https://dotnet.github.io/orleans/docs/grains/reentrancy.html). The reason we compare to Orleans here is because it's model is fairly similar to Swift's with regards to modeling actors as reference types that express messages and interactions using async/await.

#### Proposal: Structured concurrency / Task-chain - aware reentrant actors

In addition to the above semantics and fine grained control over reentrancy, we can do better than that, thanks to Swift's built in notion of structured concurrency with tasks and child tasks.

Assuming the non-reentrant actors as just discussed, it is still important to recognize that a frequent and usually quite understandable way of interacting between actors which are simply "conversations" between two or more actors in order fo fulfil some initial request.

Thanks to Swift embracing [Structured Concurrency](https://github.com/DougGregor/swift-evolution/blob/structured-concurrency/proposals/nnnn-structured-concurrency.md) as a core building block of it's concurrency story, we are in good position to do _better_ than just outright banning reentrancy. In Swift, every asynchronous operation is part of a `Task` which encapsulates the general computation taking place, and every asynchronous operation spawned from such task becomes a child Task of the current task. Synchronous calls do not change the current task (in a way, one can think of Tasks as similar to Threads, however they are not directly mapped to one another). Using this core capability in Swift's concurrency model, we are able to make actor calls *task-chain aware* and *allow* such calls to be reentrant.

This resolves both the deadlock we encountered in the `Waiter` and `Kitchen` example in the previous section, and even enables implementing mutually recursive actors. In the following–world's silliest isEven implementation, we can see two actors performing either is even/odd checks, and mutually calling out to each other, because of the structured nature of tasks, and task awareness of the actor runtime, such calls would _not (!)_ deadlock under the task-aware runtime: 

```swift
// WARNING: Don't actually implement an isOdd/isEven check like this, 
//          it involves multiple executor hops and is therefore very sub-optimal.
public actor class OddOddy { 
  let evan: EvenEvan!
  
  func isOdd(n: Int) async -> Bool {
    if n == 0 { return true }
    return await evan.isEven(num - 1)
  }
}

actor class EvenEvan {
  let oddy: OddOddy!

  func isEven(n: Int) async -> Bool {
    if n == 0 { return false }
    return await oddy.isOdd(num - 1)
  }
}
```

Semantically, this can be seen as similar in capability as reentrant locking, however with no actual locking or blocking involved.

This behavior could be again configurable, if e.g. it definitely is not what the developer intended we could configure this when spawning the actor or by specific properties within or annotations on the actor type.

#### Reentrancy Summary

Preventing reentrancy complicates the model slightly, as there are cases where deadlocks can happen, however the gained benefit of an actor _truly_ being an a domain in which external calls are linearized and handled one after the other. Thanks to non-reentrant actors we can think of them as collections of small programs (their async functions triggered externally) which are triggered and run to completion, and then handle the next task, which greatly simplifies the mental model when working with those.

So, from a consistency point of view, one might want to prefer non-reentrant actors, but from an high-priority work scheduling in the style of "run this now, at any cost" reentrant actors offer an useful model, preventing data-races, while allowing this interleaved execution which–if one is *very careful*–can be utilized to some benefit.

By offering developers the tools to pick which reentrancy model they need for their specific actor and actor functions, we allow users to pick the safe good default most of the time, and allow opt-ing into the more tricky to get right reentrant mode when developers know they need it. Marking single functions can also be used as a way to break actor deadlocks which could otherwise (rarely) occur if we didn't provide ways for reentrancy at all.

Thanks to structured concurrency and the `Task` primitives, we are able to relax the reentrancy rules such that they do not get in the way of typical pair-wise interactions between actors, but still protect from concurrent incoming requests causing confusing ordering interleaving execution. 

#### Closures and local functions

The restrictions on only allowing access to (non-`async`) actor-isolated declarations on `self` only work so long as we can ensure that the code in which `self` is valid is executing non-concurrently on the actor. For methods on the actor class, this is established by the rules described above: `async` function calls are serialized via the actor's queue, and non-`async` calls are only allowed when we know that we are already executing (non-concurrently) on the actor.

However, `self` can also be captured by closures and local functions. Should those closures and local functions have access to actor-isolated state on the captured `self`? Consider an example where we want to close out a bank account and distribute the balance amongst a set of accounts:

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
    
    thief.deposit(amount: balance)
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

In this proposal, a closure that is non-escaping is considered to be isolated within the actor, while a closure that is escaping is considered to be outside of the actor. This is based on a notion of when closures can be executed concurrently: to execute a particular closure on a different thread, one will have to escape the closure out of its current thread to run it on another thread. The rules that prevent a non-escaping closure from escaping therefore also prevent them from being executed concurrently. 

Based on the above, `parallelForEach` would need its closure parameter will be `@escaping`. The first example (with `forEach`) is well-formed, because the closure is actor-isolated and can access `self.balance`. The second example (with `parallelForEach`) will be rejected with an error:

```
error: actor-isolated property 'balance' is unsafe to reference in code that may execute concurrently
```

Note that the same restrictions apply to partial applications of non-`async` actor-isolated functions. Given a function like this:

```swift
extension BankAccount {
  func synchronous() { }
}
```

The expression `self.synchronous` is well-formed only if it is the direct argument to a function whose corresponding parameter is non-escaping. Otherwise, it is ill-formed because it could escape outside of the actor's context.

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

#### Escaping reference types

The rules concerning actor isolation ensure that accesses to an actor class's stored properties cannot occur concurrently, eliminating data races unless unsafe code has subverted the model. 

However, the actor isolation rules presented in this proposal are only sufficient for *value types*. With a value type, any copy of the value produces a completely independent instance. Modifications to that independent instance cannot affect the original, and vice versa. Therefore, one can pass a copy of an actor-isolated stored property to another actor, or even write it into a global variable, and the actor will maintain its isolation because the copy is distinct.

Reference types break the isolation model, because mutations to a "copy" of a value of reference type can affect the original, and vice versa. Let's introduce another stored property into our bank account to describe recent transactions, and make `Transaction` a reference type (a class):

```swift
class Transaction { 
  var amount: Double
  var dateOccurred: Date
}

actor class BankAccount {
  // ...
  private var transactions: [Transaction]
}
```

The `transactions` stored property is actor-isolated, so it cannot be modified directly. Moreover, arrays are themselves value types when they contain value types. But the transactions stored in the array are reference types. The moment one of the instances of `Transaction`  from the `transactions` array *escapes* the actor's context, data isolation is lost. For example, here's a function that retrieves the most recent transaction:

```swift
extension BankAccount {
  func mostRecentTransaction() async -> Transaction? {   // UNSAFE! Transaction is a reference type
    return transactions.min { $0.dateOccurred > $1.dateOccurred } 
  }
}
```

A client of this API gets a reference to the transaction inside the given bank account, e.g.,

```swift
guard let transaction = await account.mostRecentTransaction() else {
  return
}
```

At this point, the client can both modify the actor-isolated state by directly modifying the fields of `transaction`, as well as see any changes that the actor has made to the transaction. These operations may execute concurrently with code running on the actor, causing race conditions. 

Not all examples of "escaping" reference types are quite as straightforward as this one. Reference types can be stored within structs, enums, and in collections such as arrays and dictionaries, so cannot look only at whether the type or its generic arguments are a `class`. The reference type might also be hidden in code not visible to the user, e.g.,

```swift
public struct LooksLikeAValueType {
  private var transaction: Transaction  // not semantically a value type
}
```

Generics further complicate the matter: some types, like the standard library collections, act like value types when their generic arguments are value types. An actor class might be generic, in which case its ability to maintain isolation depends on its generic argument:

```swift
actor class GenericActor<T> {
  private var array: [T]
  func first() async -> T? { 
    return array.first
  }
}
```

With this type, `GenericActor<Int>` maintains actor isolation but `GenericActor<Transaction>` does not.

There are solutions to these problems. However, the scope of the solutions is large enough that they deserve their own separate proposals. Therefore, **this proposal only provides basic actor isolation for data race safety with value types**.

### Global actors

What we’ve described as actor isolation is one part of a larger problem of data isolation.  It is important that all memory be protected from data races, not just memory directly associated with an instance of an actor class. Global actors allow code and state anywhere to be actor-isolated to a specific singleton actor. This extends the actor isolation rules out to annotated global variables, global functions, and members of any type or extension thereof. For example, global actors allow the important concepts of "Main Thread" or "UI Thread" to be expressed in terms of actors without having to capture everything into a single class. 

*Global actors* provide a way to annotate arbitrary declarations (properties, subscripts, functions, etc.) as being part of a process-wide singleton actor. A global actor is described by a type that has been annotated with the `@globalActor` attribute:

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

Global actors are implicitly singletons, i.e. there is always _one_ instance of a global actor in a given process. This is in contrast to `actor classes`, of which there can be no instances, one instance, or many instances in a given process at any given time.


## Detailed design

### Actor classes

A class can be declared as an actor class using the `actor` modifier:

```
/// Declares a new type BankAccount
actor class BankAccount {
  // ...
}
```

Each instance of the actor class represents a unique actor.

An actor class may only inherit from another actor class. A non-actor class may only inherit from another non-actor class.

> **Rationale**: Actor classes enforce state isolation, but non-actor classes do not. If an actor class inherits from a non-actor class (or vice versa), part of the actor's state would not be covered by the actor-isolation rules, introducing the potential for data races on that state.

As a special exception described in the complementary proposal [Concurrency Interoperability with Objective-C](https://github.com/DougGregor/swift-evolution/blob/concurrency-objc/proposals/NNNN-concurrency-objc.md), an actor class may inherit from `NSObject`.

By default, the instance methods, properties, and subscripts of an actor class are actor-isolated to the actor instance. This is true even for methods added retroactively on an actor class via an extension, like any other Swift type.

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

All actor classes conform to a new protocol `Actor`:

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

* A declaration cannot have multiple global actor attributes.  The rules below say that, in some cases, a global actor attribute is propagated from one declaration to another.  If the rules say that an attribute “propagates by default”, then no propagation is performed if the destination declaration has an explicit global actor attribute.  If the rules say that attribute “propagates mandatorily”, then it is an error if the destination declaration has an explicit global actor attribute that does not identify the same actor.  Regardless, it is an error if global actor attributes that do not identify the same actor are propagated to the same declaration.

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

The `@actorIndependent` attribute has an optional "unsafe" argument.  `@actorIndependent(unsafe)` is treated the same way as `@actorIndependent` from the client's perspective, meaning that it can be used from anywhere. However, the implementation of an `@actorIndependent(unsafe)` entity is allowed to refer to actor-isolated state, which would have been ill-formed under `@actorIndependent`.

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

