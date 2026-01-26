# Transactional Observation of Values

* Proposal: [SE-0475](0475-observed.md)
* Authors: [Philippe Hausler](https://github.com/phausler)
* Review Manager: [Freddy Kellison-Linn](https://github.com/Jumhyn)
* Status: **Implemented (Swift 6.2)**
* Implementation: https://github.com/swiftlang/swift/pull/79817
* Review: ([pitch](https://forums.swift.org/t/pitch-transactional-observation-of-values/78315)) ([review](https://forums.swift.org/t/se-0475-transactional-observation-of-values/79224)) ([acceptance](https://forums.swift.org/t/accepted-se-0475-transactional-observation-of-values/80389))

## Introduction

Observation was introduced to add the ability to observe changes in graphs of 
objects. The initial tools for observation afforded seamless integration into 
SwiftUI, however aiding SwiftUI is not the only intent of the module - it is 
more general than that. This proposal describes a new safe, ergonomic and 
composable way to observe changes to models using an AsyncSequence, starting 
transactions at the first willSet and then emitting a value upon that 
transaction end at the first point of consistency by interoperating with 
Swift Concurrency.

## Motivation

Observation was designed to allow future support for providing an `AsyncSequence` 
of values, as described in the initial [Observability proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0395-observability.md). 
This follow-up proposal offers tools for enabling asynchronous sequences of 
values, allowing non-SwiftUI systems to have the same level of "just-the-right-amount-of-magic" 
as when using SwiftUI.

Numerous frameworks in the Darwin SDKs provide APIs for accessing an 
`AsyncSequence` of values emitted from changes to a property on a given model 
type. For example, DockKit provides `trackingStates` and Group Activities 
provides `localParticipantStates`. These are much like other APIs that provide 
`AsyncSequence` from a model type; they hand crafted to provide events from when
that object changes. These manual implementations are not trivial and require 
careful book-keeping to get right. In addition, library and application code 
faces the same burden to use this pattern for observing changes. Each of these 
uses would benefit from having a centralized and easy mechanism to implement 
this kind of sequence. 

Observation was built to let developers avoid the complexity inherent when 
making sure the UI is updated upon value changes. For developers using SwiftUI 
and the `@Observable` macro to mark their types, this principle is already 
realized; directly using values over time should mirror this ease of use, 
providing the same level of power and flexibility. That model of tracking changes
by a graph allows for perhaps the most compelling part of Observation; it 
can track changes by utilizing naturally written Swift code that is written just 
like the logic of other plain functions. In practice that means that any solution
will also follow that same concept even for disjoint graphs that do not share 
connections. The solution will allow for iterating changed values for applications
that do not use UI as seamlessly as those that do.

## Proposed solution

This proposal adds a straightforward new tool: a closure-initialized `Observations` 
type that acts as a sequence of closure-returned values, emitting new values 
when something within that closure changes.

This new type makes it easy to write asynchronous sequences to track changes 
but also ensures that access is safe with respect to concurrency. 

The simple `Person` type declared here will be used for examples in the 
remainder of this proposal:

```swift
@Observable
final class Person {
  var firstName: String
  var lastName: String
 
  var name: String { firstName + " " + lastName } 

  init(firstName: String, lastName: String) { 
    self.firstName = firstName
    self.lastName = lastName 
  }
}
```

Creating an `Observations` asynchronous sequence is straightforward. This example 
creates an asynchronous sequence that yields a value every time the composed 
`name` property is updated:

```swift
let names = Observations { person.name }
```

However if the example was more complex and the `Person` type in the previous 
example had a `var pet: Pet?` property which was also `@Observable` then the 
closure can be written with a more complex expression.

```swift
let greetings = Observations {
  if let pet = person.pet {
    return "Hello \(person.name) and \(pet.name)"
  } else {
    return "Hello \(person.name)"
  }
}
```

In that example it would track both the assignment of a new pet and then consequently
that pet's name.

## Detailed design

There are a few behaviors that are prerequisites to understanding the requirements
of the actual design. These two key behaviors are how the model handles tearing
and how the model handles sharing.

Tearing is where a value that is expected to be assigned as a singular 
transactional operation can potentially be observed in an intermediate and 
inconsistent state. The example `Person` type shows this when a `firstName` is 
set and then the `lastName` is set. If the observation was triggered just on the 
trailing edge (the `didSet` operation) then an assignment to both properties 
would garner an event for both properties and potentially get an inconsistent
value emitted from `name`. Swift has a mechanism for expressing the grouping of
changes together: isolation. When an actor or an isolated type is modified it is 
expected (enforced by the language itself) to be in a consistent state at the 
next suspension point. This means that if we can utilize the isolation that is 
safe for the type then the suspensions on that isolation should result in safe 
(and non torn values). This means that the implementation must be transactional
upon that suspension; starting the transaction on the first trigger of a leading 
edge (the `willSet`) and then completing the transaction on the next suspension 
of that isolation.

The simple example of tearing would work as the following:

```swift
let person = Person(firstName: "", lastName: "")
// willSet \.firstName - start a transaction
person.firstName = "Jane"
// didSet \.firstName
// willSet \.lastName - the transaction is still dirty
person.lastName = "Appleseed"
// didSet \.lastName
// the next suspension the `name` property will be valid
```

Suspensions are any point where a task can be calling out to something where 
they `await`. Swift concurrency enforces safety around these by making sure that 
isolation is respected. Any time a function has a suspension point data 
associated with the type must be ready to be read by the definitions of actor 
isolation. In the previous example of the `Person` instance the `firstName` and 
`lastName` properties are mutated together in the same isolation, that means 
that no other access in that isolation can read those values when they are torn
without the type being `Sendable` (able to be read from multiple isolations).
That means that in the case of a non-`Sendable` type the access must be 
constrained to an isolation, and in the `Sendable` cases the mutation is guarded
by some sort of mechanism like a lock, In either case it means that the next 
time one can read a safe value is on that same isolation of the safe access to
start with and that happens on that isolations next suspension.

Observing at the next suspension point means that we can also address the second
issue too; sharing. The expectation of observing a property from a type as an
AsyncSequence is that multiple iterations of the same sequence from multiple 
tasks will emit the same values at the same iteration points. The following code
is expected to emit the same values in both tasks.

```swift

let names = Observations { person.firstName + " " + person.lastName }

Task.detached {
  for await name in names {
    print("Task1: \(name)")
  }
}

Task.detached {
  for await name in names {
    print("Task2: \(name)")
  }
}
```

In this case both tasks will get consistently safe accessed values. This can 
be achieved without needing an extra buffer since the suspension of each side of 
the iteration are continuations resuming all together upon the accessor's 
execution on the specified isolation. This facilitates subject-like behavior 
such that the values are sent from the isolation for access to the iteration's 
continuation.

The previous initialization using the closure is a sequence of values of the computed
properties as a `String`. This has no sense of termination locally within the 
construction. Making the return value of that closure be a lifted `Optional` suffers 
the potential conflation of a terminal value and a value that just happens to be nil.
This means that there is a need for a second construction mechanism that offers a
way of expressing that the `Observations` sequence iteration will run until finished.

For the example if `Person` then has a new optional field of `homePage` which 
is an optional URL it then means that the construction can disambiguate
by returning the iteration as the `next` value or the `finished` value.

```
@Observable
final class Person {
  var firstName: String
  var lastName: String
  var homePage: URL?

  var name: String { firstName + " " + lastName } 

  init(firstName: String, lastName: String) { 
    self.firstName = firstName
    self.lastName = lastName 
  }
}

let hosts = Observations.untilFinished { [weak person] in
  if let person {
    .next(person.homePage?.host)
  } else {
    .finished
  }
}
```

Putting this together grants a signature as such:

```swift
public struct Observations<Element: Sendable, Failure: Error>: AsyncSequence, Sendable {
  public init(
    @_inheritActorContext _ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Element
  )

  public enum Iteration: Sendable {
    case next(Element)
    case finished
  }

  public static func untilFinished(
    @_inheritActorContext _ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Iteration
  ) -> Observations<Element, Failure>
}
```

Picking the initializer apart first captures the current isolation of the 
creation of the `Observations` instance. Then it captures a `Sendable` closure that 
inherits that current isolation. This means that the closure may only execute on
the captured isolation. That closure is run to determine which properties are 
accessed by using Observation's `withObservationTracking`. So any access to a 
tracked property of an `@Observable` type will compose for the determination of 
which properties to track. 

The closure is not run immediately it is run asynchronously upon the first call 
to the iterator's `next` method. This establishes the first tracking state for 
Observation by invoking the closure inside a `withObservationTracking` on the 
implicitly specified isolation. Then upon the first `willSet` it will enqueue on
to the isolation a new execution of the closure and finishing the transaction to 
prime for the next call to the iterator's `next` method.

The closure has two other features that are important for common usage; firstly 
the closure is typed-throws such that any access to that emission closure will
potentially throw an error if the developer specifies. This allows for complex 
composition of potentially failable systems. Any thrown error will mean that the
`Observations` sequence is complete and loops that are currently iterating will 
terminate with that given failure. Subsequent calls then to `next` on those 
iterators will return `nil` - indicating that the iteration is complete. 

The type `Observations` will conform to `AsyncSequence`. This means that it
adheres to the cancellation behavior of other `AsyncSequence` types; if the task
is cancelled then the iterator will return nil, and any time it becomes 
terminal for any reason that sequence will remain terminal and continue returning nil. 
Termination by cancellation however is independent for each instance. 

## Behavioral Notes

There are a number of scenarios of iteration that can occur. These can range from production rate to iteration rate differentials to isolation differentials to concurrent iterations. Enumerating all possible combinations is of course not possible but the following explanations should illustrate some key usages. `Observations` does not make unsafe code somehow safe - the concepts of isolation protection or exclusive access are expected to be brought to the table by the types involved. It does however require the enforcements via Swift Concurrency particularly around the marking of the types and closures being required to be `Sendable`. The following examples will only illustrate well behaved types and avoid fully unsafe behavior that would lead to crashes because the types being used are circumventing that language safety.

The most trivial case is where a single produce and single consumer are active. In this case they both are isolated to the same isolation domain. For ease of reading; this example is limited to the `@MainActor` but could just as accurately be represented in some other actor isolation.

```swift
@MainActor
func iterate(_ names: Observations<String, Never>) async {
  for await name in names {
    print(name)
  }
}

@MainActor
func example() async throws {
  let person = Person(firstName: "", lastName: "")

  // note #2
  let names = Observations {
    person.name
  }

  Task {
    await iterate(names)
  }
  
  for i in 0..<5 {
    person.firstName = "\(i)"
    person.lastName = "\(i)"
    try await Task.sleep(for: .seconds(0.1)) // note #1
  }
}

try await example()

```

The result of the observation will print the following output.

```
0 0
1 1
2 2
3 3
4 4
```

The values are by the virtue of the suspension at `note #1` are all emitted, the first name and last name are conjoined because they are both mutated before the suspension. The type `Person` does not need to be `Sendable` because `note #2` is implicitly picking up the `@MainActor` isolation of the enclosing isolation context. That isolation means that the person is always safe to access in that scope.

Next is the case where the mutation of the properties out-paces the iteration. Again the example is isolated to the same domain.

```swift
@MainActor
func iterate(_ names: Observations<String, Never>) async {
  for await name in names {
    print(name)
    try? await Task.sleep(for: .seconds(0.095))
  }
}

@MainActor
func example() async throws {
  let person = Person(firstName: "", lastName: "")

  // @MainActor is captured here as the isolation
  let names = Observations {
    person.name
  }

  Task {
    await iterate(names)
  }
  
  for i in 0..<5 {
    person.firstName = "\(i)"
    person.lastName = "\(i)"
    try await Task.sleep(for: .seconds(0.1))
  }
}

try await example()

```

The result of the observation may print the following output, but the primary property is that the values are conjoined to the same consistent view. It is expected that some values may not be represented during the iteration because the transaction has not yet been handled by the iteration. 

```
0 0
1 1
2 2
3 3
```

The last value is never observed because the program ends before it would be. If the program did not terminate then another value would be observed.

Observations can be used across boundaries of concurrency. This is where the iteration is done on a different isolation than the mutations. The types however are accessed always in the isolation that the creation of the Observations closure is executed. This means that if the `Observations` instance is created on the main actor then the subsequent calls to the closure will be done on the main actor.

```swift
@globalActor
actor ExcplicitlyAnotherActor: GlobalActor {
  static let shared = ExcplicitlyAnotherActor()
}

@ExcplicitlyAnotherActor
func iterate(_ names: Observations<String, Never>) async {
  for await name in names {
    print(name)
  }
}

@MainActor
func example() async throws {
  let person = Person(firstName: "", lastName: "")

  // @MainActor is captured here as the isolation
  let names = Observations {
    person.name
  }

  Task.detached {
    await iterate(names)
  }
  
  for i in 0..<5 {
    person.firstName = "\(i)"
    person.lastName = "\(i)"
    try await Task.sleep(for: .seconds(0.1))
  }
}

```

The values still will be conjoined as expected for their changes, however just like the out-paced case there is a potential in which an alteration may slip between the isolations and only a subsequent value is represented during the iteration. However since is particular example has no lengthy execution (greater than 0.1 seconds) it means that it does not get out paced by production and returns all values.

```
0 0
1 1
2 2
3 3
4 4
```

If the `iterate` function was altered to have a similar `sleep` call that exceeded the production then it would result in similar behavior of the previous producer/consumer rate case.

The next behavioral illustration is the value distribution behaviors; this is where two or more copies of an `Observations` are iterated concurrently.

```swift

@MainActor
func iterate1(_ names: Observations<String, Never>) async {
  for await name in names {
    print("A", name)
  }
}


@MainActor
func iterate2(_ names: Observations<String, Never>) async {
  for await name in names {
    print("B", name)
  }
}

@MainActor
func example() async throws {
  let person = Person(firstName: "", lastName: "")

  // @MainActor is captured here as the isolation
  let names = Observations {
    person.name
  }

  Task.detached {
    await iterate1(names)
  }
  
  Task.detached {
    await iterate2(names)
  }
  
  for i in 0..<5 {
    person.firstName = "\(i)"
    person.lastName = "\(i)"
    try await Task.sleep(for: .seconds(0.1))
  }
}

try await example()
```

This situation commonly comes up when the asynchronous sequence is stored as a property of a type. By vending these as a shared instance to a singular source of truth it can provide both a consistent view and reduce overhead for design considerations. However when the sequences are then combined with other isolations the previous caveats come in to play.

```
A 0 0
B 0 0
B 1 1
A 1 1
A 2 2
B 2 2
A 3 3
B 3 3
B 4 4
A 4 4
```

The same rate commentary applies here as before but an additional wrinkle is that the delivery between the A and B sides is non-determinstic (in some cases it can deliver as A then B and other cases B then A).

There is one additional clarification of expected behaviors - the iterators should have an initial state to determine if that specific iterator is active yet or not. This means that upon the first call to next the value will be obtained by calling into the isolation of the constructing closure to "prime the pump" for observation and obtain a first value. This can be encapsulated into an exaggerated test example as the following:

```swift

@MainActor
func example() async {
  let person = Person(firstName: "0", lastName: "0")
  
  // @MainActor is captured here as the isolation
  let names = Observations {
    person.name
  }
  Task {
    try await Task.sleep(for: .seconds(2))
    person.firstName = "1"
    person.lastName = "1"
    
  }
  Task {
    for await name in names {
      print("A = \(name)")
    }
  }
  Task {
    for await name in names {
      print("B = \(name)")
    }
  }
  try? await Task.sleep(for: .seconds(10))
}

await example()
```

Which results in the following output:

```
A = 0 0
B = 0 0
B = 1 1
A = 1 1
```

This ensures the first value is produced such that every sequence will always be primed with a value and will eventually come to a mutual consistency to the values no matter the isolation.

## Effect on ABI stability & API resilience

This provides no alteration to existing APIs and is purely additive. However it 
does have a few points of interest about future source compatibility; namely
the initializer does ferry the inherited actor context as a parameter and if 
in the future Swift develops a mechanism to infer this without a user
overridable parameter then there may be a source breaking ambiguity that would
need to be disambiguated.

## Notes to API authors

This proposal does not change the fact that the spectrum of APIs may range from 
favoring `AsyncSequence` properties to purely `@Observable` models. They both
have their place. However the calculus of determining the best exposition may
be slightly more refined now with `Observations`. 

If a type is representative of a model and is either transactional in that 
some properties may be linked in their meaning and would be a mistake to read
in a disjoint manner (the tearing example from previous sections), or if the 
model interacts with UI systems it now more so than ever makes sense to use
`@Observable` especially with `Observations` now as an option. Some cases may have 
previously favored exposing those `AsyncSequence` properties and would now 
instead favor allowing the users of those APIs compose things by using `Observations`.
The other side of the spectrum will still exist but now is more strongly 
relegated to types that have independent value streams that are more accurately
described as `AsyncSequence` types being exposed. The suggestion for API authors
is that now with `Observations` favoring `@Observable` perhaps should take more
of a consideration than it previously did.

## Alternatives Considered

Both initialization mechanisms could potentially be collapsed into an optional,
however that creates potential ambiguity of valid nil elements versus termination.

There have been many iterations of this feature so far but these are some of the 
highlights of alternative mechanisms that were considered.

Just expose a closure with `didSet`: This misses the mark with regards to concurrency
safety but also faces a large problem with regards to transactionality. This would also 
be out sync with the expected behavior of existing observation uses like SwiftUI.
The one benefit of that approach is that each setter call would have a corresponding 
callback and would be more simple to implement with the existing infrastructure. It 
was ultimately rejected because that would fall prey to the issue of tearing and 
the general form of composition was not as ergonomic as other solutions.

Expose an AsyncSequence based on `didSet`: This also falls to the same issues with the
closure approach except is perhaps slightly more ergonomic to compose. This was also 
rejected due to the tearing problem stated in the proposal.

Expose an AsyncSequence property extension based on `KeyPath`: This could be adapted
to the `willSet` and perhaps transactional models, but faces problems when attempting
to use `KeyPath` across concurrency domains (since by default they are not Sendable).
The implementation of that approach would require considerable improvement to handling
of `KeyPath` and concurrency (which may be an optimization path that could be considered
in the future if the API merits it). As it stands however the `KeyPath` approach in 
comparison to the closure initializer is considerably less easy to compose.

The closure type passed to the initializer does not absolutely require @Sendable in the 
cases where the initialization occurs in an isolated context, if the initializer had a 
parameter of an isolation that was non-nullable this could be achieved for that restriction
however up-coming changes to Swift's Concurrency will make this approach less appealing.
If this route would be taken it would restrict the potential advanced uses cases where
the construction would be in an explicitly non-isolated context.

A name of `Observed` was considered, however that type name led to some objections that
rightfully claimed it was a bit odd as a name since it is bending the "nouning" of names
pretty strongly. This lead to the alternate name `Observations` which strongly leans
into the plurality of the name indicating that it is more than one observation - lending
to the sequence nature.

It was seriously considered during the feedback to remove the initializer methods and only 
have construction by two global functions named `observe` and `observeUntilFinished` 
that would act as the current initializer methods. Since the types must still be returned 
to allow for storing that return into a property it does not offer a distinct advantage.
