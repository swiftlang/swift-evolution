# Actors

* Proposal: [SE-NNNN](NNNN-actors.md)
* Authors: [John McCall](https://github.com/rjmccall), [Doug Gregor](https://github.com/DougGregor), [Konrad Malawski](https://github.com/ktoso), [Chris Lattner](https://github.com/lattner)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Partially available in [recent `main` snapshots](https://swift.org/download/#snapshots) behind the flag `-Xfrontend -enable-experimental-concurrency`

## Table of Contents

* [Introduction](#introduction)
* [Motivation](#motivation)
* [Proposed solution](#proposed-solution)
   * [Actors](#actors-1)
   * [Actor isolation](#actor-isolation)
      * [Isolated parameters](#isolated-parameters)
      * [Nonisolated declarations](#nonisolated-declarations)
      * [Closures](#closures)
      * [inout parameters](#inout-parameters)
   * [Cross-actor references and ConcurrentValue types](#cross-actor-references-and-concurrentvalue-types)
   * [Actor reentrancy](#actor-reentrancy)
      * ["Interleaving" execution with reentrant actors](#interleaving-execution-with-reentrant-actors)
      * [Deadlocks with non-reentrant actors](#deadlocks-with-non-reentrant-actors)
      * [Unnecessary blocking with non-reentrant actors](#unnecessary-blocking-with-non-reentrant-actors)
      * [Existing practice](#existing-practice)
      * [Reentrancy Summary](#reentrancy-summary)
* [Detailed design](#detailed-design)
   * [Actors](#actors-2)
   * [Isolated parameters](#isolated-parameters-1)
   * [Non-isolated declarations](#non-isolated-declarations)
   * [Actor isolation checking](#actor-isolation-checking)
      * [References and actor isolation](#references-and-actor-isolation)
      * [Overrides](#overrides)
      * [Protocol conformance](#protocol-conformance)
   * [Partial applications](#partial-applications)
   * [Actor interoperability with Objective-C](#actor-interoperability-with-objective-c)
* [Source compatibility](#source-compatibility)
* [Effect on ABI stability](#effect-on-abi-stability)
* [Effect on API resilience](#effect-on-api-resilience)
* [Alternatives Considered](#alternatives-considered)
   * [Non-reentrancy](#non-reentrancy)
   * [Task-chain reentrancy](#task-chain-reentrancy)
   * [Eliminating inheritance](#eliminating-inheritance)
* [Revision history](#revision-history)

## Introduction

The [actor model](https://en.wikipedia.org/wiki/Actor_model) involves entities called actors. Each *actor* can perform local computation based on its own state, send messages to other actors, and act on messages received from other actors. Actors run independently, and cannot access the state of other actors, making it a powerful abstraction for managing concurrency in language applications. The actor model has been implemented in a number of programming languages, such as Erlang and Pony, as well as various libraries like Akka (on the JVM) and Orleans (on the .NET CLR).

This proposal introduces a design for *actors* in Swift, providing a model for building concurrent programs that are simple to reason about and are safer from data races. 

Swift-evolution thread: [Pitch #1](https://forums.swift.org/t/concurrency-actors-actor-isolation/41613), [Pitch #2](https://forums.swift.org/t/pitch-2-actors/44094), [Pitch #3](https://forums.swift.org/t/pitch-3-actors/44470).

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

If `BankAccount` were a normal class, the `transfer(amount:to:)` method would be well-formed, but would be subject to data races in concurrent code without an external locking mechanism. 

With actors, the attempt to reference `other.balance` triggers a compiler error, because `balance` may only be referenced on `self`. The error messages notes that `balance` is *actor-isolated*, meaning that it can only be accessed directly from within the specific actor it is tied to or "isolated by". In this case, it's the instance of `BankAccount` referenced by `self`. All declarations on an instance of an actor, including stored and computed instance properties (like `balance`), instance methods (like `transfer(amount:to:)`), and instance subscripts, are all actor-isolated by default. Actor-isolated declarations can freely refer to other actor-isolated declarations on the same actor instance (on `self`).

A reference to an actor-isolated declaration from outside that actor is call a *cross-actor reference*. Such references are permissible in one of two ways. First, a cross-actor reference to immutable state is allowed because, once initialized, that state can never be modified (either from inside the actor or outside it), so there are no data races by definition. The reference to `other.accountNumber` is allowed based on this rule, because `accountNumber` is declared via a `let` and has value-semantic type `Int`.

The second form of permissible cross-actor reference is one that is performed with an asynchronous function invocation. Such asynchronous function invocations are turned into "messages" requesting that the actor execute the corresponding task when it can safely do so. These messages are stored in the actor's "mailbox", and the caller initiating the asynchronous function invocation may be suspended until the actor is able to process the corresponding message in its mailbox. An actor processes the messages its mailbox sequentially, so that a given actor will never have two concurrently-executing tasks running actor-isolated code. This ensures that there are no data races on actor-isolated mutable state, because there is no concurrency in any code that can access actor-isolated state. For example, if we wanted to make a deposit to a given bank account `account`, we could make a call to a method `deposit(amount:)` on another actor, and that call would become a message placed in the actor's mailbox and the caller would suspend. When that actor processes messages, it will eventually process the message corresponding to the deposit, executing that call within the actor's isolation domain when no other code is executing in that actor's isolation domain.

> **Implementation note**: At an implementation level, the messages are partial tasks (described by the [Structured Concurrency][sc] proposal) for the asynchronous call, and each actor instance contains its own serial executor (also in the [Structured Concurrency][sc] proposal). The serial executor is responsible for running the partial tasks sequentially. This is conceptually similar to a serial [`DispatchQueue`](https://developer.apple.com/documentation/dispatch/dispatchqueue), but the actual implementation in the actor runtime uses a lighter-weight implementation that takes advantage of Swift's `async` functions.

Compile-time actor-isolation checking determines which references to actor-isolated declarations are cross-actor references, and ensures that such references use one of the two permissible mechanisms described above. This ensures that code outside of the actor does not interfere with the actor's mutable state.

Based on the above, we can implement a correct version of `transfer(amount:to:)`) that is asynchronous:

```swift
extension BankAccount {
  func transfer(amount: Double, to other: BankAccount) async throws {
    assert(amount > 0)

    if amount > balance {
      throw BankError.insufficientFunds
    }

    print("Transferring \(amount) from \(accountNumber) to \(other.accountNumber)")

    // Safe: this operation is the only one that has access to the actor's isolated
    // state right now, and there have not been any suspension points between
    // the place where we checked for sufficient funds and here.
    balance = balance - amount
    
    // Safe: the deposit operation is placed in the `other` actor's mailbox; when
    // that actor retrieves the operation from its mailbox to execute it, the
    // other account's balance will get updated.
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

Synchronous actor functions can be called synchronously on the actor's `self` (or `super`), but cross-actor references to this method require an asynchronous call. The `transfer(amount:to:)` function calls it asynchronously (on `other`), while the following function `passGo` calls it synchronously (on the implicit `self`):

```swift
actor MonopolyAccount : BankAccount {
  // Pass go and collect $200
  func passGo() {
    super.deposit(amount: 200.0)  // synchronous is okay because `self` is isolated and therefore so is `super`
  }
}
```

Cross-actor references to an actor property are permitted as an asynchronous call so long as they are read-only accesses:


```swift
func checkBalance(account: BankAccount) {
  print(await account.balance)   // okay
  await account.balance = 1000.0 // error: cross-actor property mutations are not permitted
}
```

#### Actor-isolated parameters

The `self` parameter of an actor function is special in that it is within the actor's isolation domain, so it can access properties and synchronous functions on the actor. The same capabilities can be afforded to a different parameter by marking it as `isolated`. For example, this allows us to express an operation that runs a closure on an actor:

```swift
extension BankAccount {
  func runOnActor<R>(body: (isolated BankAccount) async -> R) -> R {
    body(self) // okay: self is actor-isolated
  }
}

func investWildly(account: BankAccount, amount: Double) async {
  await account.runOnActor { account in
    account.balance -= amount                    // okay: account is actor-isolated
    let winnings = await gamble(amount: amount)
    account.balance += winnings
  }
}
``` 

It also allows actor functions to be extracted into global or local functions, so code can be refactored without breaking actor isolation. Due to `isolated` parameters, the `self` parameter of an actor function is actually not that special: it merely defaults to `isolated` because of the context in which it is declared. For example, type of `BankAccount.deposit(amount:)`, defined above, is a curried function that involves an isolated `self`:

```swift
let fn = BankAccount.deposit(amount:) // type is (isolated BankAccount) -> (Double) -> Void
```

This means that any actor function can be turned into a global function, with the same restrictions now applying to one of its other parameters:

```swift
func deposit(amount: Double, in account: isolated BankAccount) {
  account.balance += amount  // okay: account is isolated
}

func f(account1: BankAccount, account2: isolated BankAccount) {
  deposit(amount: 100, in: account1) // error: account1 is not isolated
  deposit(amount: 100, in: account2) // okay: account2 is isolated
}
```

Note that there is no mechanism that would permit two actors to be isolated at the same time, because one has to "leave" one actor's isolation domain to enter the isolation domain of another actor. Therefore, we prohibit the definition of a function with more than one isolated parameter:

```swift
func transfer(amount: Double, from fromAccount: isolated BankAccount, to toAccount: isolated BankAccount) { // error: only one parameter in a function can be isolated
  // ...
}
```

#### Nonisolated declarations

As noted above, instance declarations defined within actors have an `isolated` parameter `self` by default. However, the modifier `nonisolated` on an actor instance declaration makes the `self` parameter non-isolated. This allows us (for example) to define conformance of an actor to a protocol that has synchronous requirements, which would otherwise cause actor isolation checking to produce an error, or to introduce (synchronous) actor operations that are computed based on immutable actor state. For example:

```swift
extension BankAccount: Hashable {
  nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(accountNumber) 
  }  
}

extension BankAccount: CustomStringConvertible {
  nonisolated var description: String {
    "Bank account #\(accountNumber)"
  }
}

let fn = BankAccount.hash(into:) // type is (BankAccount) -> (inout Hasher) -> Void
```

There are two important things to note here:

1. Without the `nonisolated` modifier, the protocol conformance would be invalid, because an actor-isolated synchronous instance member cannot satisfy a synchronous protocol requirement. The compiler would produce an error such as
```
error: actor-isolated property "description" cannot be used to satisfy a protocol requirement
```
2. The `nonisolated` modifier means that the `self` parameter is not consider to reference an isoalted actor. This makes references to declarations on `self` cross-actor references, so actor isolation checking will prevent them from being used:
```swift
extension BankAccount: CustomDebugStringConvertible {
  nonisolated var debugDescription: String {
    "Bank account #\(accountNumber), balance = \(balance)"  // error: actor-isolated property 'balance' can not be referenced from a non-isolated context
  }
}
```

Most functions are not isolated to a particular actor. For example, all functions declared outside of an actor are not actor isolated by nature (there is no actor `self` and they have no other `isolated` parameters). Static members of the actor are not actor-isolated because `self` is not an instance. Within an actor-isolated function there are local functions and closures that may or may not be actor-isolated; the rules are described in the following section. 

#### Closures

The restrictions on cross-actor references only work so long as we can ensure that the code that might execute concurrently with actor-isolated code is considered to be non-isolated. For example, consider a function that schedules report generation at the end of the month:

```swift
extension BankAccount {
  func endOfMonth(month: Int, year: Int) {
    // Schedule a task to prepare an end-of-month report.
    Task.runDetached {
      let transactions = await self.transactions(month: month, year: year)
      let report = Report(accountNumber: self.accountNumber, transactions: transactions)
      await report.email(to: self.accountOwnerEmailAddress)
    }
  }
}
```

A task created with `Task.runDetached` runs concurrently with all other code. If the closure passed to `Task.runDetached` were to be actor-isolated, we would introduce a data race on access to shared mutable state on `BankAccount`. Actors prevent this data race by specifying that a `@concurrent` closure (described in [`ConcurrentValue` and `@concurrent` closures][se302], and used in the definition of `Task.runDetached` in the [Structured Concurrency][sc] proposal) is always non-isolated. Therefore, it is required to use asynchronous calls to any actor-isolated declarations.

It is often useful for closures within an actor-isolated function to themselves be actor-isolated, and it is safe from data races so long as the closure itself cannot be executed concurrently with the actor-isolated context in which it occurs. For example, using a sequence algorithm like `forEach` is free from data races because the closure will only be called serially:

```swift
extension BankAccount {
  func close(distributingTo accounts: [BankAccount]) async {
    let transferAmount = balance / accounts.count

    accounts.forEach { account in                        // okay, captured self in closure is actor-isolated
      balance = balance - transferAmount            
      await account.deposit(amount: transferAmount)
    }
    
    await thief.deposit(amount: balance)
  }
}
```

However, not all closure-accepting functions are as well-behaved as the sequence algorithms are. For example, any existing code that provides a completion-handler-based API is problematic:

```swift
// not-yet-ported code, possibly from a library
extension BankSession {
  func downloadTransactions(accountNumber: Int, since: Date, completionHandler: @escaping ([Transactions], [Date]) -> Void) { ... }
}

extension BankAccount {
  func updateTransactions() {
    session.downloadTransactions(accountNumber: accountNumber, since: lastUpdatedDate) { (newTransactions, newLastUpdatedDate) in  // problem if this were actor-isolated
      self.transactions.append(contentsOf: newTransactions)
      self.lastUpdateDate = newLastUpdatedDate
    }
  }
}
```

Here, `BankSession.downloadTransactions` is using a completion handler to deliver its results. That completion handler will be called at some later time, but the caller has no knowledge of the actor, so the completion handler can be executed concurrently with actor-isolated code, which would cause a data race. This proposal makes the closure non-isolated in this case, so the references to `self.transactions` and `self.lastUpdateDate` will be flagged as an error by actor isolation checking:

```
error: actor-isolated property 'transactions' can not be referenced by non-isolated closure
error: actor-isolated property 'lastUpdateDate' can not be referenced by non-isolated closure
```

The specific rule determining whether a closure captures an `isolated` parameter as actor-isolated checks two properties:
* If the closure is `@concurrent` or is nested within a `@concurrent` closure or local function, it is non-isolated, or
* If the closure is `@escaping` or is nested within an `@escaping` closure or a local function, it is non-isolated.

For the examples above:

* The closure passed to `runDetached` captures `self` as non-isolated because it requires a `@concurrent` function to be passed to it.
* The closure passed to `downloadTransactions` captures `self` as non-isolated because it requires an `@escaping` function.
* The closure passed to `forEach` captures `self` as isolated because it takes a non-concurrent, non-escaping function.

> **Rationale**: In theory, `@escaping` is completely orthogonal from `@concurrent`. However, in practice nearly all `@escaping` closures in Swift code today are executed concurrently via mechanisms that predate Swift Concurrency. In time, those escaping functions that are executed concurrently will be annotated with `@concurrent` as well as `@escaping`. However, until that happens, `@escaping` non-`@concurrent` functions will be a major hole in the safety model, allowing data races on actor-isolated state. The rule that prevents `isolated` parameter capture in an `@escaping` closure could be lifted in a future version of Swift, where limitations on concurrent execution are more widely enforced.

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

> **Rationale**: this restriction prevents exclusivity violations where the modification of the actor-isolated `balance` is initiated by passing it as `inout` to a call that is then suspended, and another task executed on the same actor then attempts to access `balance`. Such an access would then result in an exclusivity violation that will terminate the program. While the `inout` restriction is not required for memory safety (because errors will be detected at runtime), the default re-entrancy of actors makes it very easy to introduce non-deterministic exclusivity violations. Therefore, we introduce this restriction to eliminate that class of problems that where a race would trigger an exclusivity violation.

### Cross-actor references and `ConcurrentValue` types

A separate proposal introduces the [`ConcurrentValue` protocol][se302]. Values of types that conform to the `ConcurrentValue` protocol are safe to share across concurrently-executing code. There are various kinds of types that work well this way: value-semantic types like `Int` and `String`, value-semantic collections of such types like `[String]` or `[Int: String]`, immutable classes, and so on.

Actors protect their shared mutable state, so actor instances can be freely shared across concurrently-executing code, and the actor itself will internally maintain synchronization. Therefore, every actor type implicitly conforms to the `ConcurrentValue` protocol.

All cross-actor references are, necessarily, working with values of types that are being shared across different concurrently-executed code. For example, let's say that our `BankAccount` includes a list of owners, where each owner is modeled by a `Person` class:

```swift
class Person {
  var name: String
  let birthDate: Date
}

actor BankAccount {
  // ...
  var owners: [Person]

  func primaryOwner() -> Person? { return owners.first }
}
```

The `primaryOwner` function can be called asynchronously from another actor, and then the `Person` instance can be modified from anywhere:

```swift
if let primary = await account.primaryOwner() {
  primary.name = "The Honorable " + primary.name  // problem: concurrent mutation of actor-isolated state
}
```

Even non-mutating access is problematic, because the person's `name` could be modified from within the actor at the same time as the original call is trying to access it. To prevent this potential for concurrent mutation of actor-isolated state, all cross-actor references can only involve types that conform to `ConcurrentValue`. For a cross-actor asynchronous call, the argument and result types must conform to `ConcurrentValue`. For a cross-actor reference to an immutable property, the property type must conform to `ConcurrentValue`. By insisting that all cross-actor references only use `ConcurrentValue` types, we can ensure that no references to shared mutable state flow into or out of the actor's isolation domain. The compiler will produce a diagnostic for such issues. For example, the call to `account.primaryOwner()` about would produce an error like the following:

```
error: cannot call function returning non-concurrent-value type 'Person?' across actors
```

Note that the `primaryOwner()` function as defined above can still be used with actor-isolated code. For example, we can define a function to get the name of the primary owner, like this:

```swift
extension BankAccount {
  func primaryOwnerName() -> String? {
    return primaryOwner()?.name
  }
}
```

The `primaryOwnerName()` function is safe to asynchronously call across actors because `String` (and therefore `String?`) conforms to `ConcurrentValue`.

### Actor reentrancy

Actor-isolated functions are [reentrant](https://en.wikipedia.org/wiki/Reentrancy_(computing)). When an actor-isolated function suspends, reentrancy allows other work to execute on the actor before the original actor-isolated function resumes, which we refer to as *interleaving*. Reentrancy eliminates a source of deadlocks, where two actors depend on each other, can improve overall performance by not unnecessarily blocking work on actors, and offers opportunities for better scheduling of (e.g.) higher-priority tasks. However, it means that actor-isolated state can change across an `await` when an interleaved task mutates that state, meaning that developers must be sure not to break invariants across an await. In general, this is the [reason for requiring `await`](https://github.com/apple/swift-evolution/blob/main/proposals/0296-async-await.md#suspension-points) on asynchronous calls, because various state (e.g., global state) can change when a call suspends.

This section explores the issue of reentrancy with examples that illustrate both the benefits and problems with both reentrant and non-reentrant actors, and settles on re-entrant actors. Alternatives Considered provides potential future directions to provide more control of re-entrancy, including [non-reentrant actors](#non-reentrancy) and [task-chain reentrancy](#task-chain-reentrancy).

#### "Interleaving" execution with reentrant actors

Reentrancy means that execution of asynchronous actor-isolated functions may "interleave" at suspension points, leading to increased complexity in programming with such actors, as every suspension point must be carefully inspected if the code *after* it depends on some invariants that could have changed before it suspended.

Interleaving executions still respect the actor's "single-threaded illusion", i.e., no two functions will ever execute *concurrently* on any given actor. However they may *interleave* at suspension points. In broad terms this means that reentrant actors are *thread-safe* but are not automatically protecting from the "high level" kinds of races that may still occur, potentially invalidating invariants upon which an executing asynchronous function may be relying on. To further clarify the implications of this, let us consider the following actor, which thinks of an idea and then returns it, after telling its friend about it.

```swift
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

The opposite of reentrant actor functions are "non-reentrant" functions and actors. This means that while an actor is processing an incoming actor function call (message), it will *not* process any other message from its mailbox until it has completed running this initial function. Essentially, the entire actor is blocked from executing until that task completes.

If we take the example from the previous section and use a non-reentrant actor, it will execute correctly, because no work can be scheduled on the actor until `friend.tell` has completed:

```swift
// assume non-reentrant
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

Deadlocks with non-reentrant actors could be detected with runtime tools that detect cyclic call graphs once they've occurred, much like tools exist to find reference cycles in data structures at runtime. However, such deadlocks cannot generally be identified statically (e.g., with the compiler or static analysis), because call graphs require whole-program knowledge and can change dynamically depending on the data provided to the program.

Deadlocked actors would be sitting around as inactive zombies forever. Some runtimes solve deadlocks like this by making every single actor call have a timeout (such timeouts are already useful for distributed actor systems). This would mean that each `await` could potentially `throw`, and that either timeouts or deadlock detection would have to always be enabled. We feel this would be prohibitively expensive, because we envision actors being used in the vast majority of concurrent Swift applications. It would also muddy the waters with respect to cancellation, which is intentionally designed to be explicit and cooperative. Therefore, we feel that the approach of automatically cancelling on deadlocks does not fit well with the direction of Swift Concurrency.

#### Unnecessary blocking with non-reentrant actors

Consider an actor that handles the download of various images and maintains a cache of what it has downloaded to make subsequent accesses faster:

```swift
// assume non-reentrant
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

There are a number of existing actor implementations that have considered the notion or reentrancy:

* Erlang/Elixir ([gen_server](https://medium.com/@eduardbme/erlang-gen-server-never-call-your-public-interface-functions-internally-c17c8f28a1ee)) showcases a simple "loop/deadlock" scenario and how to detect and fix it,
* Akka ([Persistence persist/persistAsync](https://doc.akka.io/docs/akka/current/persistence.html#relaxed-local-consistency-requirements-and-high-throughput-use-cases) is effectively _non-reentrant behavior by default_, and specific APIs are designed to allow programmers to _opt into_ reentrant whenever it would be needed. In the linked documentation `persistAsync` is the re-entrant version of the API, and it is used _very rarely_ in practice. Akka persistence and this API has been used to implement bank transactions and process managers, by relying on the non-reentrancy of `persist()` as a killer feature, making implementations simple to understand and _safe_. Note that Akka is built on top of Scala, which does not provide `async`/`await`. This means that mailbox-processing methods are more synchronous in nature, and rather than block the actor while waiting for a response, they would handle the response as a separate message receipt.
* Orleans ([grains](https://dotnet.github.io/orleans/docs/grains/reentrancy.html)) are also non-reentrant by default, but offer extensive configuration around reentrancy. Grains and specific methods can be marked as being re-entrant, and there is even a dynamic mechanism by which one can implement a run-time predicate to determine whether an invocation can interleave. Orleans is perhaps closest to the Swift approach described here, because it is built on top of a language that provides `async`/`await` (C#). Note that Orleans *had* a feature called [call-chain reentrancy](https://dotnet.github.io/orleans/docs/grains/reentrancy.html#reentrancy-within-a-call-chain), which we feel is a promising potential direction: we cover it later in this proposal in our section on [task-chain reentrancy](#task-chain-reentrancy).

#### Reentrancy Summary

This proposal provides only reentrant actors. However, the [Alternatives Considered](#alternatives-considered) section describes potential future design directions that could add opt-in non-reentrancy.

> **Rationale**: Reentrancy by default all but eliminates the potential for deadlocks. Moreover, it helps ensure that actors can make timely progress within a concurrent system, and that a particular actor does not end up unnecessarily blocked on a long-running asynchronous operation (say, downloading a file). The mechanisms for ensuring safe interleaving, such as using synchronous code when performing mutations and being careful not to break invariants across `await` calls, are already present in the proposal.

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

An actor may only inherit from another actor (or `NSObject`; see the section on Objective-C interoperability below). A non-actor may only inherit from another non-actor.

> **Rationale**: Actors enforce state isolation, but non-actors do not. If an actor inherits from a non-actor (or vice versa), part of the actor's state would not be covered by the actor-isolation rules, introducing the potential for data races on that state.

By default, the instance methods, properties, and subscripts of an actor have an isolated `self` parameter. This is true even for methods added retroactively on an actor via an extension, like any other Swift type.

```
extension BankAccount {
  func acceptTransfer(amount: Double) async { // actor-isolated
    balance += amount
  }
}  
```

Actors are similar to classes in all respects independent of isolation: actor types can have `static` and `class` methods, properties, and subscripts. All of the attributes that apply to classes apply to actors in much the same way, except where those semantics conflict with actor isolation. An actor type satisfies an `AnyObject` requirement.

### Non-isolated declarations

An instance method, computed property, or subscript of an actor may be annotated with `nonisolated`.  When a declaration is `nonisolated`, it (or its accessors) have a `self` parameter that is not `isolated`.

A declaration may be declared to be non-isolated:

```
nonisolated var count: Int { constantCount + 1 }
```

Declarations marked as `nonisolated` can be used from outside the actor's isolation domain.

By default, the mutable instance stored properties (declared with `var`) of an actor are actor-isolated to the actor instance. A stored instance property may be annotated with `nonisolated(unsafe)` to remove this restriction.

> **Rationale**: `nonisolated(unsafe)` allows specific stored instance properties to opt out of actor isolation checking, allowing careful developers to implement their own synchronization mechanisms.

### Actor isolation checking

Any given declaration in a program is either isolated to a specific actor or is non-isolated.

An actor-isolated declaration can be the stored instance properties of an actor as well as any function that has an `isolated` parameter, which includes computed instance properties, instance methods, and instance subscripts of an actor. 

Declarations that are not isolated to an actor are called non-isolated.

The actor isolation rules are checked in a number of places, where two different declarations need to be compared to determine if their usage together maintains actor isolation. There are several such places:
* When the definition of one declaration (e.g., the body of a function) references another declaration, e.g., calling a function, accessing a property, or evaluating a subscript.
* When one declaration overrides another.
* When one declaration satisfies a protocol requirement.

We'll describe each scenario in detail.

#### References and actor isolation

A given declaration (call it the "source") can synchronously reference another declaration (call it the "target"), e.g., by calling a function or accessing a property or subscript. A synchronous invocation requires the actor isolation categories for the source and target to be compatible (defined below). An actor-isolated target function or target property getter that is not compatible with the source can be accessed asynchronously.

A source and target category pair is compatible if:
* the source and target categories are the same, or
* the target category is non-isolated.

The first rule is the most direct: an isolated parameter (e.g., `self` or any other parameter marked as `isolated`) can synchronously access any member its type (e.g., a mutable instance property) that is isolated to the same actor. The argument that corresponds to an `isolated` parameter must itself be `isolated`.

The second rule specifies that non-isolated declarations can be used from anywhere because they aren't tied to a particular actor. Actors can provide non-isolated instance methods, but because those functions are not actor-isolated, that cannot read the actor's own mutable state. For example:

```swift
extension BankAccount {
  nonisolated func steal(amount: Double) {
    balance -= amount  // error: actor-isolated property 'balance' can not be referenced on non-isolated parameter 'self'
  }
}  
```

#### Overrides

When a given declaration (the "overriding declaration") overrides another declaration (the "overridden" declaration), the actor isolation of the two declarations is compared. The override is well-formed if:

* the overriding and overridden declarations have the same actor isolation or
* the overriding declaration is non-isolated.

In the absence of an explicitly-specified actor-isolation modifier (i.e, `nonisolated`), the overriding declaration will inherit the actor isolation of the overridden declaration.

#### Protocol conformance

When a given declaration (the "witness") satisfies a protocol requirement (the "requirement"), the protocol requirement can be satisfied by the witness if:

* The requirement is `async`, or
* the witness is non-isolated.



### Partial applications

A partial applications of a function with an `isolated` parameter is only permitted when the expression is a direct argument whose corresponding parameter is non-escaping and non-concurrent. For example:

```swift
func runLater<T>(_ operation: @escaping () -> T) -> T { ... }

actor A {
  func f(_: Int) -> Double { ... }
  func g() -> Double { ... }
  
  func useAF(array: [Int]) {
    array.map(self.f)                     // okay
    Task.runDetached(operation: self.g)   // error: self.g has non-concurrent type () -> Double that cannot be converted to a @concurrent function type
    runLater(self.g)                      // error: self.g has escaping function type () -> Double
  }
}
```

These restrictions follow from the actor isolation rules for the "desugaring" of partial applications to closures. The two erroneous cases above fall out from the fact that the `self` parameter would be captured as non-isolated in a closure that performs the call, so access to the actor-isolated function `g` would have to be asynchronous. Here are the "desugared" forms of the partial applications:


```swift
extension A {
  func useAFDesugared(a: A, array: [Int]) {
    array.map { f($0) } )      // okay
    Task.runDetached { g() }   // error: self is non-isolated, so call to `g` cannot be synchronous
    runLater { g() }           // error: self is non-isolated, so the call to `g` cannot be synchronous
  }
}
```

### Key paths

A key path cannot involve a reference to an actor-isolated declaration:

```swift
actor A {
  var storage: Int
}

let kp = \A.storage  // error: key path would permit access to actor-isolated storage
```

> **Rationale**: Allowing the formation of a key path that references an actor-isolated property or subscript would permit accesses to the actor's protected state from outside of the actor isolation domain.

### Actor interoperability with Objective-C

As a special exception to the rule that an actor can only inherit from another actor, an actor can inherit from `NSObject`. This allows actors to themselves be declared `@objc`, and implicitly provides conformance to `NSObjectProtocol`:

```swift
@objc actor MyActor: NSObject { ... }
```

A member of an actor can only be `@objc` if it is either `async` or is not isolated to the actor. Synchronous code that is within the actor's isolation domain can only be invoked on `self` (in Swift). Objective-C does not have knowledge of actor isolation, so these members are not permitted to be exposed to Objective-C. For example:

```swift
@objc actor MyActor: NSObject {
    @objc func synchronous() { } // error: part of actor's isolation domain
    @objc func asynchronous() async { } // okay: asynchronous, exposed to Objective-C as a method that accepts a completion handler
    @objc nonisolated func notIsolated() { } // okay: non-isolated
}
```

## Source compatibility

This proposal is mostly additive, and should not break source compatibility. The `actor` contextual keyword to introduce actors is a parser change that does not break existing code, and the other changes are carefully staged so they do not change existing code. Only new code that introduces actors or actor-isolation attributes will be affected.

## Effect on ABI stability

This is purely additive to the ABI. Actor isolation itself is a static notion that is not part of the ABI.

## Effect on API resilience

Nearly all changes in actor isolation are breaking changes, because the actor isolation rules require consistency between a declaration and its users:

* A class cannot be turned into an actor or vice versa.
* The actor isolation of a public declaration cannot be changed except between `nonisolated(unsafe)` and `nonisolated`.

## Alternatives Considered

### Non-reentrancy

We could introduce a `@reentrant` attribute may be added to any actor-isolated function, actor, or extension of an actor to describe how it is reentrant. The attribute would have several forms:

* `@reentrant`: Indicates that each potential suspension point within the function bodies covered by the attribute is reentrant.
* `@reentrant(never)`: Indicates that each potential suspension point within the function bodies covered by the attribute is non-reentrant.

A non-reentrant potential suspension point prevents any other asynchronous call from executing on the actor until it has completed. Note that asynchronous calls to non-reentrant async functions directly on `self` are exempted from this check, so an actor can asynchronously call itself without producing a deadlock.

> **Rationale**: Allowing direct calls on `self` eliminates an obvious set of deadlocks, and requires only the same static knowledge as actor-isolation checking for synchronous access to actor-isolated state.

It is an error to have a `@reentrant` attribute on a non-isolated function, non-actor type, or extension of a non-actor type. Only one `@reentrant` attribute may occur on a given declaration. The reentrancy of an actor-isolated non-type declaration is determined by finding a suitable `@reentrant` attribute. The search is as follows:

1. The declaration itself.
2. If the declaration is a non-type member of an extension, the extension.
3. If the declaration is a non-type member of a type (or extension thereof), the type definition.

If there is no suitable `@reentrant` attribute, an actor-isolated declaration is reentrant.

Here's an example illustrating how the `@reentrant` attribute can be applied at various points:

```swift
actor Stage {
  @reentrant(never) func f() async { ... }    // not reentrant
  func g() async { ... }                      // reentrant
}

@reentrant(never)
extension Stage {
  func h() async { ... }                      // not reentrant
  @reentrant func i() async { ... }           // reentrant

  actor InnerChild {                          // reentrant, not affected by enclosing extension
    func j() async { ... }                    // reentrant
  }

  nonisolated func k() async { .. }     // okay, reentrancy is uninteresting
  nonisolated @reentrant func l() async { .. } // error: @reentrant on non-actor-isolated
}

@reentrant func m() async { ... } // error: @reentrant on non-actor-isolated
```

The attribute approach is not the only possible design here. At an implementation level, the actual blocking will be handled at each asynchronous call site. Instead of an attribute that affects potentially many asynchronous calls, we could introduce a different form of `await` that does the blocking, e.g.,

```swift
await(blocking) friend.tell(opinion, heldBy: self)
```

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
@reentrant(never)
actor OddOddy {
  let evan: EvenEvan!

  func isOdd(_ n: Int) async -> Bool {
    if n == 0 { return true }
    return await evan.isEven(num - 1)
  }
}

@reentrant(never)
actor EvenEvan {
  let oddy: OddOddy!

  func isEven(_ n: Int) async -> Bool {
    if n == 0 { return false }
    return await oddy.isOdd(num - 1)
  }
}
```

Under `@reentrant(never)`, this code will deadlock, because a call from `EvanEvan.isEven` to `OddOddy.isOdd` will then depend on another call to `EvanEvan.isEven`, which cannot proceed until the original call completes. One would need to make these methods to be reentrant to eliminate the deadlock.

With Swift embracing [Structured Concurrency][sc] as a core building block of its concurrency story, we may be able to do better than outright banning reentrancy. In Swift, every asynchronous operation is part of a `Task` which encapsulates the general computation taking place, and every asynchronous operation spawned from such task becomes a child task of the current task. Therefore, it is possible to know whether a given asynchronous call is part of the same task hierarchy, which is the rough equivalent to being in the same call stack in synchronous code.

We could introduce a new kind of reentrancy, *task-chain reentrancy*, which allows reentrant calls on behalf of the given task or any of its children. This resolves both the deadlock we encountered in the `convinceOtherwise` example from the section on [deadlocks](#deadlocks-with-non-reentrant-actors) as well as the mutually-recursive `isEven` example above, while still preventing reentrancy from unrelated tasks. This reentrancy therefore mimics synchronous code more closely, eliminating many deadlocks without allowing unrelated interleavings to break the high-level invariants of an actor.

There are a few reasons why we are not currently comfortale including task-chain reentrancy in the proposal:
* The task-based reentrancy approach doesn't seem to have been tried at scale. Orleans documents support for [reentrancy in a call chain](https://dotnet.github.io/orleans/docs/grains/reentrancy.html#reentrancy-within-a-call-chain), but the implementation was fairly limited and it was eventually [removed](https://twitter.com/reubenbond/status/1349725703634251779). From the Orleans experience, it is hard to assess whether the problem is with the idea or the specific implementation.
* We do not yet know of an efficient implementation technique for this approach within the actor runtime.

If we can address the above, task-chain reentrancy can be introduced into the actor model with another spelling of the reentrancy attribute such as `@reentrant(task)`, and may provide the best default.

### Eliminating inheritance

Like classes, actors as proposed allow inheritance. However, actors and classes cannot be co-mingled in an inheritance hierarchy, so there are essentially two different kinds of type hierarchies. It has been [proposed](https://docs.google.com/document/d/14e3p6yBt1kPrakLcEHV4C9mqNBkNibXIZsozdZ6E71c/edit#) that actors should not permit inheritance at all, because doing so would simplify actors: features such as method overriding, initializer inheritance, required and convenience initializers, and inheritance of protocol conformances would not need to be specified, and users would not need to consider them. The [discussion thread](https://forums.swift.org/t/actors-are-reference-types-but-why-classes/42281) on the proposal to eliminate inheritance provides several reasons to keep actor inheritance:

* Actor inheritance makes it easier to port existing class hierarchies to get the benefits of actors. Without actor inheritance, such porting will also have to contend with (e.g.) replacing superclasses with protocols and explicitly-specified stored properties at the same time.
* The lack of inheritance in actors won't prevent users from having to understand the complexities of inheritance, because inheritance will still be used pervasively with classes.
* The design and implementation of actors naturally admits inheritance. Actors are fundamentally class-like, the semantics of inheritance follow directly from the need to maintain actor isolation. The implementation of actors is essentially as "special classes", so it supports all of these features out of the box. There is little benefit to the implementation from eliminating the possibility of inheritance of actors.

Actor inheritance has similar use cases to class inheritance. If we take a textbook example with `Person` and `Employee` classes, all the same reasoning applies to actors:

```swift
actor Person {
  var name: String
  var birthdate: Date
  // lots of other attributes
}

actor Employee: Person {
  var badgeNumber: Int
}
```

This implementation will behave as one would expect for inheritance (every `Employee` is-a `Person`). The inheriting actor type also extends the actor-isolation domain of the actor type it inherits, so (for example) it is safe for a method of `Employee` to refer to `self.birthdate`. Given that there are no implementation reasons to disallow inheritance, and the reasons for inheritance of classes apply equally to actors, we retain inheritance for actor types.

## Revision history

* Changes in the fourth pitch:
  * Allow cross-actor references to actor properties, so long as they are reads (not writes or `inout` references)
  * Added `isolated` parameters, to generalize the previously-special behavior of `self` in an actor and make the semantics of `nonisolated` more clear.
  * Limit `nonisolated(unsafe)` to stored instance properties. The prior definition was far too broad.
  * Clarify that `super` is isolated if `self` is.
  * Prohibit references to actor-isolated declarations in key paths.
  * Clarify the behavior of partial applications.
* Changes in the third pitch:
  * Narrow the proposal down to only support re-entrant actors. Capture several potential non-reentrant designs in the Alternatives Considered as possible future extensions.
  * Replaced `@actorIndependent` attribute with a `nonisolated` modifier, which follows the approach of `nonmutating` and ties in better with the "actor isolation" terminology (thank you to Xiaodi Wu for the suggestion).
  * Replaced "queue" terminology with the more traditional "mailbox" terminology, to try to help alleviate confusion with Dispatch queues.
  * Introduced "cross-actor reference" terminology and the requirement that cross-actor references always traffic in `ConcurrentValue` types.
  * Reference `@concurrent` function types from their separate proposal.
  * Moved Objective-C interoperability into its own section.
  * Clarify the "class-like" behaviors of actor types, such as satisfying an `AnyObject` conformance.
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


[sc]: https://github.com/DougGregor/swift-evolution/blob/structured-concurrency/proposals/nnnn-structured-concurrency.md
[se302]: https://github.com/apple/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md
