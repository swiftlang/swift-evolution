# Transactional Observation of Values

* Proposal: [OBS-0001](NNNN-observation_values_and_tracking.md)
* Authors: [Philippe Hausler](https://github.com/phausler)
* Review Manager: None
* Status: Draft
* Framework: Observation

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

This proposal adds a straightforward new tool: a closure-initialized `Observed` 
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

Creating an `Observed` asynchronous sequence is straightforward. This example 
creates an asynchronous sequence that yields a value every time the composed 
`name` property is updated:

```swift
let names = Observed { person.name }
```

However if the example was more complex and the `Person` type in the previous 
example had a `var pet: Pet?` property which was also `@Observable` then the 
closure can be written with a more complex expression.

```swift
let greetings = Observed {
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

There a few behaviors that are prerequisites to understanding the requirements
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

let names = Observed { person.firstName + " " + person.lastName }

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

In this case both tasks will get the same values upon the same events. This can 
be achieved without needing an extra buffer since the suspension of each side of 
the iteration are continuations resuming all together upon the accessor's 
execution on the specified isolation. This facilitates subject-like behavior 
such that the values are sent from the isolation for access to the iteration's 
continuation.

Putting this together grants a signature as such:

```swift
public struct Observed<Element: Sendable, Failure: Error>: AsyncSequence, Sendable {
  public init(
    isolation: isolated (any Actor)? = #isolation,
    @_inheritActorContext _ emit: @Sendable @escaping () throws(Failure) -> Element?
  )
}
```

Picking the initializer apart first captures the current isolation of the 
creation of the `Observed` instance. Then it captures a `Sendable` closure that 
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
`Observed` sequence is complete and loops that are currently iterating will 
terminate with that given failure. Subsequent calls then to `next` on those 
iterators will return `nil` - indicating that the iteration is complete. 
Furthermore the `emit` closure also has a nullable result which indicates the 
sequence is finished without failure.

The nullable result indication can then be easily used with weak references to 
`@Observable` instances. This likely will be a common pattern of users of the 
`Observed` async sequence.

```
let names = Observed { [weak person] in 
  person?.name
}
```

This lets the `Observed` async sequence compose a value that represents a 
lifetime bound emission. That the subject is not strongly referenced and can
terminate the sequence when the object is deinitialized.

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
be slightly more refined now with `Observed`. 

If a type is representative of a model and is either transactional in that 
some properties may be linked in their meaning and would be a mistake to read
in a disjoint manner (the tearing example from previous sections), or if the 
model interacts with UI systems it now more so than ever makes sense to use
`@Observable` especially with `Observed` now as an option. Some cases may have 
previously favored exposing those `AsyncSequence` properties and would now 
instead favor allowing the users of those APIs compose things by using `Observed`.
The other side of the spectrum will still exist but now is more strongly 
relegated to types that have independent value streams that are more accurately
described as `AsyncSequence` types being exposed. The suggestion for API authors
is that now with `Observed` favoring `@Observable` perhaps should take more
of a consideration than it previously did.

## Alternatives Considered

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

One consideration that is an addition is to add an unsafe initializer that lets an
isolation be specified manually rather than picking it up from the inferred context.
This is something that if usage cases demand it is possible and worth entertaining.
But that is completely additive and can be bolted on later-on.