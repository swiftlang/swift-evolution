# Global-actor isolated conformances

* Proposal: [SE-0470](0470-isolated-conformances.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: [Xiaodi Wu](https://github.com/xwu)
* Status: **Implemented (Swift 6.2)**
* Vision: [Improving the approachability of data-race safety](https://github.com/swiftlang/swift-evolution/blob/main/visions/approachable-concurrency.md)
* Implementation: On `main` with the experimental features `IsolatedConformances` and `StrictSendableMetatypes`.
* Upcoming Feature Flag: `InferIsolatedConformances`
* Review: ([pitch](https://forums.swift.org/t/pre-pitch-isolated-conformances/77726)) ([review](https://forums.swift.org/t/se-0470-global-actor-isolated-conformances/78704)) ([acceptance](https://forums.swift.org/t/accepted-se-0470-global-actor-isolated-conformances/79189)) ([amendment pitch](https://forums.swift.org/t/pitch-amend-se-0466-se-0470-to-improve-isolation-inference/79854)) ([amendment review](https://forums.swift.org/t/amendment-se-0470-global-actor-isolated-conformances/80999)) ([amendment acceptance](https://forums.swift.org/t/amendment-accepted-se-0470-global-actor-isolated-conformances/81144))

## Introduction

Types isolated to a global actor (such as `@MainActor`) are useful for representing data that can only ever be used from a single concurrency context. They occur both in single-threaded programs where all code is expected to run on the main actor as well as larger applications where interaction with the UI occurs through the main actor. Unfortunately, such types are unable to conform to most protocols due to isolation mismatches:

```swift
@MainActor
class MyModelType: Equatable {
  var name: String

  init(name: String) {
    self.name = name
  }

  // error: main-actor-isolated static function '==' cannot satisfy non-isolated requirement 'Equatable.=='
  static func ==(lhs: MyModelType, rhs: MyModelType) -> Bool { 
    lhs.name == rhs.name
  }
}
```

This proposal introduces the notion of an *isolated conformance*, which is a conformance that can only be used within the isolation domain of the type. For the code above, the conformance to `Equatable` can be specified as being isolated to the main actor as follows:

```swift
@MainActor
class MyModelType: @MainActor Equatable {
  // unchanged from the above ...
}
```

This allows `MyModelType` to provide a conformance to `Equatable` that works like every other conformance, except that it can only be used from the main actor.

## Motivation

Types isolated to the global actor are common in single-threaded programs and UI applications, among others, but their inability to conform to protocols without workarounds means that they cannot integrate with any Swift code using generics, cutting them off from interacting with many libraries. The workarounds themselves can be onerous: each operation that is used to satisfy a protocol requirement must be marked as `nonisolated`, e.g.,

```swift
  nonisolated static func ==(lhs: MyModelType, rhs: MyModelType) -> Bool { 
    lhs.name == rhs.name
  }
```

However, this is incompatible with using types or data on the main actor, and results in an error:

```swift
 3 | @MainActor
 4 | class MyModelType: Equatable {
 5 |   var name: String
   |       `- note: property declared here
 6 | 
 7 |   init(name: String) {
   :
10 | 
11 |   nonisolated static func ==(lhs: MyModelType, rhs: MyModelType) -> Bool {
12 |     lhs.name == rhs.name
   |                     `- error: main actor-isolated property 'name' can not be referenced from a nonisolated context
13 |   }
14 | }
```

We can work around this issue by assuming that this function will only ever be called on the main actor using [`MainActor.assumeIsolated`](https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:)):

```swift
  nonisolated static func ==(lhs: MyModelType, rhs: MyModelType) -> Bool {
    MainActor.assumeIsolated {
      lhs.name == rhs.name
    }
  }
```

This is effectively saying that `MyModelType` will only ever be considered `Equatable` on the main actor. Violating this assumption will result in a run-time error detected when `==` is called from outside the main actor. There are two problems with this approach. First, it's dynamically enforcing data-race safety for something that seems like it should be statically verifiable (but can't easily be expressed). Second, this same `nonisolated`/`assumeIsolated` pattern has to be replicated for every function that satisfies a protocol requirement, creating a lot of boilerplate.

## Proposed solution

This proposal introduces the notion of an *isolated conformance*. Isolated conformances are conformances whose use is restricted to a particular global actor. This is the same effective restriction as the `nonisolated`/`assumeIsolated` pattern above, but enforced statically by the compiler and without any boilerplate. The following defines a main-actor-isolated conformance of `MyModelType` to `Equatable`:

```swift
@MainActor
class MyModelType: @MainActor Equatable {
  var name: String

  init(name: String) {
    self.name = name
  }

  static func ==(lhs: MyModelType, rhs: MyModelType) -> Bool { 
    lhs.name == rhs.name
  }
}
```

Any attempt to use this conformance outside of the main actor will result in a compiler error:

```swift
/*nonisolated*/ func hasMatching(_ value: MyModelType, in modelValues: [MyModelType]) -> Bool {
  // error: cannot use main-actor-isolated conformance of 'MyModelType' to 'Equatable' in
  // non-isolated function.
  return modelValues.contains(value)
}
```

Additionally, we need to make sure that generic code cannot take the conformance and send it to another isolation domain. The [`Sequence.contains`](https://developer.apple.com/documentation/swift/sequence/contains(_:)) operation above clearly won't do that, but one could imagine a similar operation that uses concurrency to attempt the search in parallel:

```swift
extension Sequence {
  func parallelContains(_ element: Element) -> Bool where Element: Equatable & Sendable {
    // ...
  }
}
```

This `parallelContains` function can send values of type `Element` to another isolation domain, and from there call the `Equatable.==` function. If the conformance to `Equatable` is isolated, this would violate the data race safety guarantees. Therefore, this proposal specifies that an isolated conformance cannot be used in conjunction with a `Sendable` conformance:

```swift
@MainActor
func parallelHasMatching(_ value: MyModelType, in modelValues: [MyModelType]) -> Bool {
  // error: isolated conformance of 'MyModelType' to 'Equatable' cannot be used to 
  // satisfy conformance requirement for a `Sendable` type parameter 'Element'.
  return modelValues.parallelContains(value)
}
```

The corresponding restriction needs to be in place within generic functions, ensuring that they don't leak (potentially) isolated conformances across isolation boundaries. For example, the following code could introduce a data race if the conformance of `T` to `GlobalLookup` were isolated:

```swift
protocol GlobalLookup {
  static func lookupByName(_ name: String) -> Self?
}

func hasNamed<T: GlobalLookup>(_: T.Type, name: String) async -> Bool {
   return await Task.detached {
     return T.lookupByName(name) != nil
   }.value
}
```

Here, the type `T` itself is not `Sendable`, but because *all* metatypes are `Sendable` it is considered safe to use `T` from another isolation domain within the generic function. The use of `T`'s conformance to `GlobalLookup` within that other isolation domain introduces a data-race problem if the conformance were isolated. To prevent such problems in generic code, this proposal introduces a notion of *non-sendable metatypes*. Specifically, if a type parameter `T` does not conform to either `Sendable` or to a new protocol, `SendableMetatype`, then its metatype, `T.Type`, is not considered `Sendable` and cannot cross isolation boundaries. The above code, which is accepted in Swift 6 today, would be rejected by the proposed changes here with an error message like:

```swift
error: cannot capture non-sendable type 'T.Type' in 'sending' closure
```

A function like `hasNamed` can indicate that its type parameter `T`'s requires non-isolated conformance by introducing a requirement `T: SendableMetatype`, e.g.,

```swift
func hasNamed<T: GlobalLookup & SendableMetatype>(_: T.Type, name: String) async -> Bool {
   return await Task.detached {
     return T.lookupByName(name) != nil
   }.value
}
```

As with `Sendable`, an isolated conformance cannot be combined with a `SendableMetatype` constraint:

```swift
extension MyModelType: isolated GlobalLookup {
  static func lookupByName(_ name: String) -> Self? { ... }
}

// error: isolated conformance of 'MyModelType' to 'MyModelType' cannot be used to 
// satisfy conformance requirement for a `SendableMetatype` type parameter 'T'.
if hasNamed(MyModelType.self, "root") { ... }
```

Note that `Sendable` inherits from `SendableMetatype`, so any type `T` with a `Sendable` requirement also implies a requirement `T: SendableMetatype`.

Protocol conformances can also be discovered dynamically with the `as?` and `is` operators. For example, one could try to produce an `any Equatable` from a value of unknown type in any isolation domain:

```swift
func tryEquatable(_ lhs: Any, rhs: Any) -> Bool {
  if let eLHS = lhs as? any Equatable {
	  // use Equatable.==
  } else {
    return false
  }
}
```

The `Any` value could contain `MyModelType`, in which case the conformance to `Equatable` will be isolated. In such cases, the `as?` operation will check whether the code is running on the executor associated with the conformance's isolation. If so, the cast can succeed; otherwise, the case will fail (and produce `nil`).

## Detailed design

The proposed solution describes the basic shape of isolated conformances and how they interact with the type system. This section goes into more detail on the data-race safety issues that arise from the introduction of isolated conformances into the language. Then it details three rules that, together, ensure freedom from data race safety issues in the presence of isolated conformances:

1. An isolated conformance can only be used within its isolation domain.
2. When an isolated conformance is used to satisfy a generic constraint `T: P`, the generic signature must not include either of the following constraints: `T: Sendable` or `T: SendableMetatype`. 
3. A value using a conformance isolated to a given global actor is within the same region as that global actor.

### Data-race safety issues

An isolated conformance must only be used within its actor's isolation domain. Here are a few examples that demonstrate the kinds of problems that need to be addressed by a design for isolated conformances to ensure that this property holds.

First, using an isolated conformance outside of its isolation domain creates immediate problems. For example:

```swift
protocol Q {
  static func g() { }
}

extension C: @MainActor Q {
  @MainActor static func g() { }
}

nonisolated func callQG() {
  let qType: Q.Type = C.self
  qType.g()            // problem: called @MainActor function from nonisolated code
}
```

Here, a call to `C.g()` would have been rejected because it's calling a `@MainActor` function from non-isolated code and cannot `await`. However, if we're allowed to use the isolated conformance of `C: Q`, we would subvert the checking because `Q.g()` is non-isolated.

We can address this specific issue by prohibiting the use of an isolated conformance from outside its isolation domain, i.e., the use of `C: Q` to convert `C.Type` to `Q.Type` in a non-`@MainActor` function would be an error.

However, this is not sufficient to ensure that this conformance `C: P` will only be used from the main actor. Consider a function like this:

```swift
@MainActor func badReturn(c: C) -> any Sendable & P { // okay so far
  c    // uses C: P from the main actor context (okay)
       // uses C: Sendable (okay)
}

@MainActor func useBadReturn(c: C) {
  let anyP = badReturn(c: c)
  Task.detached {
    anyP.f() // PROBLEM: C.f is called from off the main actor
  }
}
```

Here, the conformance `C: P` is used from within a `@MainActor` function, but a value that stores the conformance (in the `any Sendable & P`) is returned that no longer carries the isolation restriction. The caller is free to copy that value to another isolation domain, and will end up calling `@MainActor` code from outside the main actor.

The issue is not limited to return values. For example, a generic parameter might escape to another isolation domain:

```swift
@MainActor func sendMe<T: Sendable & P>(_ value: T) {
  Task.detached { 
    value.f() 
  }
}

extension C: @unchecked Sendable { }

@MainActor func doSend(c: C) {
	sendMe(c) // uses C: P from the main actor context
            // uses C: Sendable
}
```

Here, `sendMe` ends up calling `C.f()` from outside the main actor. The combination of an isolated conformance and a `Sendable` requirement on the same type underlies this issue. To address the problem, we can prohibit the use of an isolated conformance if the corresponding type parameter (e.g, `T` in the example above) also has a `Sendable` requirement.

However, that doesn't address all issues, because region isolation permits sending non-`Sendable` values:

```swift
@MainActor func badSendingReturn() -> sending any P { // okay so far
  C()  // uses C: P from the main actor context (okay)
       // returned value is in its own region
}

@MainActor func useBadSendingReturn(c: C) {
  let anyP = badSendingReturn()
  Task.detached {
    anyP.f() // PROBLEM: C.f is called from off the main actor
  }
}
```

There are similar examples for `sending` parameters, but they're not conceptually different from the return case. This particular issue can be addressed by treating a value that depends on an isolated conformance as being within the region as the actor it's isolated to. So a newly-created value of type `C` is in its own region, but if it's type-erased to an `any P`, its region is merged with the region for the main actor. This would make the return expression in `badSendingReturn` ill-formed, because the returned value is not in its own region.

Conformances can cross isolation boundaries even if no values cross the boundary:

```swift
nonisolated func callQGElsewhere<T: Q>(_: T.Type) {
  Task.detached {
    T.g()
  }
}

@MainActor func isolationWithStatics() {
  callQGElsewhere(C.self)
}
```

Here, the generic type `T` is used from another isolation domain inside `callQGElsewhere`. When the isolated conformance of `C: Q` is provided to this function, it opens up a data-race safety hole because `C.g()` ends up getting called through generic code. Addressing this problem either means ensuring that there are no operations on the metatype that go through a potentially-isolated protocol conformance or that the metatype is itself does not leave the isolation domain.

One last issue concerns dynamic casting. Generic code can query a conformance at runtime with a dynamic cast like this:

```swift
nonisolated func f(_ value: Any) {
  if let p = value as? any P {
    p.f()
  }
}
```

If the provided `value` is an instance of `C` , and this code is invoked off the main actor, allowing it to enter the `if` branch would introduce a data race. Therefore, dynamic casting will have to determine when the conformance it depends on is isolated to an actor and check whether the code is running on the executor for that actor.

Additionally, a dynamic cast that involves a `Sendable` or `SendableMetatype` constraint should not accept an isolated conformance even if the code is running on that global actor, e.g.,

```swift
  if let p = value as? any Sendable & P { // never allows an isolated conformance to P
    p.f()
  }
```

### Rule 1: Isolated conformance can only be used within its isolation domain

Rule (1) is straightforward: the conformance can only be used within a context that is also isolated to the same global actor. This applies to any use of a conformance anywhere in the language. For example:

```swift
struct S: @MainActor P { }

struct WrapsP<T: P>: P {
  var value: T

  init(_ value: T) { self.value = value }
}

func badFunc() -> WrapsP<S> { } // error: non-@MainActor-isolated function uses @MainActor-isolated conformance `S: P`

func badFunc2() -> any P {
  S() // error: non-@MainActor-isolated function uses @MainActor-isolated conformance `S: P`
}

func acceptsP<T: P>(_ value: T) { }

func badFunc3() {
  acceptsP(S()) // error: non-@MainActor-isolated function uses @MainActor-isolated conformance `S: P`
}

protocol P2 {
  associatedtype A: P
}

struct S2: P2 {    // error: conformance of S2: P2 depends on @MainActor-isolated conformance `S: P`
                   // note: fix by making conformance of S2: P2 also @MainActor-isolated
  typealias A = S
}

protocol HasName {
  var name: String { get }
}

@MainActor class Named: @MainActor HasName {
  var name: String
  // ...
}

@MainActor
func useName() {
    let named = Named()
    Task.detached {
        named[keyPath: \HasName.name] // error: uses main-actor isolated conformance Named: P
                                      // outside of the main actor
    }
}
```

Note that the types can have different isolation from their conformances. For example, an `actor` or non-isolated type can have a `@MainActor` conformance:

```swift
actor MyActor: @MainActor P {
  // okay, so long as the declarations satisfying the requirements to P are
  // @MainActor or nonisolated
}

/*nonisolated*/ struct MyStruct: @MainActor P {
  // okay, so long as the declarations satisfying the requirements to P are
  // @MainActor or nonisolated  
}
```

### Rule 2: Isolated conformances can only be abstracted away for non-`SendableMetatype` types

Rule (2) ensures that when information about an isolated conformance is abstracted away by the generics system, the conformance cannot leave its original isolation domain. This requires a way to determine when a given generic function is permitted to pass a conformance it receives across isolation domains. Consider the example above where a generic function uses one of its conformances in different isolation domain:

```swift
protocol Q {
  static func g() { }
}

nonisolated func callQGElsewhere<T: Q>(_: T.Type) {
  Task.detached {
    T.g() // use of the conformance T: Q in a different isolation domain
  }
}

extension C: @MainActor Q { ... }

@MainActor func isolationWithStatics() {
  callQGElsewhere(C.self) // passing an isolated conformance
}
```

The above code must be rejected to prevent a data race. There are two options for diagnosing this data race:

1. Reject the definition of `callQGElsewhere` because it is using the conformance from a different isolation domain.
2. Reject the call to `callQGElsewhere` because it does not support isolated conformances.

This proposal takes option (1): we assume that generic code accepts isolated conformances unless it has indicated otherwise with a `SendableMetatype` constraint. Since most generic code doesn't deal with concurrency at all, it will be unaffected. And generic code that does make use of concurrency should already have `Sendable` constraints (which imply `SendableMetatype` constraints) that indicate that it will not work with isolated conformances. 

The specific requirement for option (1) is enforced both in the caller to a generic function and in the implementation of that function. The caller can use an isolated conformance to satisfy a conformance requirement `T: P` so long as the generic function does not also contain a requirement `T: SendableMetatype`. This prevents isolated conformances to be used in conjunction with types that can cross isolation domains, preventing the data race from being introduced at the call site. Here are some examples of this rule:

```swift
func acceptsSendableMetatypeP<T: SendableMetatype & P>(_ value: T) { }
func acceptsAny<T>(_ value: T) { }
func acceptsSendableMetatype<T: SendableMetatype>(_ value: T) { }

@MainActor func passIsolated(s: S) {
  acceptsP(s)                 // okay: the type parameter 'T' requires P but not SendableMetatype
  acceptsSendableMetatypeP(s) // error: the type parameter 'T' requires SendableMetatype
  acceptsAny(s)               // okay: no isolated conformance
  acceptsSendableMetatype(s)  // okay: no isolated conformance
}
```

The same checking occurs when the type parameter is hidden, for example when dealing with `any` or `some` types:

```swift
@MainActor func isolatedAnyGood(s: S) {
  let a: any P = s   // okay: the 'any P' cannot leave the isolation domain
}

@MainActor func isolatedAnyBad(s: S) {
  let a: any SendableMetatype & P = s   // error: the (hidden) type parameter for the 'any' is SendableMetatype
}

@MainActor func returnIsolatedSomeGood(s: S) -> some P {
  return s   // okay: the 'any P' cannot leave the isolation domain
}

@MainActor func returnIsolatedSomeBad(s: S) -> some SendableMetatype & P {
  return s   // error: the (hidden) type parameter for the 'any' is Sendable
}
```

Within the implementation, we ensure that a conformance that could be isolated cannot cross an isolation boundary. This is done by making the a metatype `T.Type` `Sendable` only when there existing a constraint `T: SendableMetatype`. Therefore, the following program is ill-formed:

```swift
protocol Q {
  static func g() { }
}

nonisolated func callQGElsewhere<T: Q>(_: T.Type) {
  Task.detached {
    T.g() // error: non-sendable metatype of `T` captured in 'sending' closure 
  }
}
```

To correct this function, add a constraint `T: SendableMetatype`, which allows the function to send the metatype (along with its conformances) across isolation domains. As described above, it also prevents the caller from providing an isolated conformance to satisfy the `T: Q` requirement, preventing the data race.

`SendableMetatype` is a new marker protocol that captures the idea that values of the metatype of `T` (i.e., `T.Type`) will cross isolation domains and can take conformances with them. It is less restrictive than a `Sendable` requirement, which specifies that *values* of a type can be sent across isolation boundaries. All concrete types (structs, enums, classes, actors) conform to `SendableMetatype` implicitly, so fixing `callQGElsewhere` will not affect any non-generic code:

```swift
nonisolated func callQGElsewhere<T: Q & SendableMetatype>(_: T.Type) {
  Task.detached {
    T.g()
  }
}

struct MyTypeThatConformsToQ: Q { ... }
callQGElsewhere(MyTypeThatConformsToQ()) // still works
```

The `Sendable` protocol inherits from the new `SendableMetatype` protocol:

```swift
/*@marker*/ protocol SendableMetatype { }
/*@marker*/ protocol Sendable: SendableMetatype { }
```

This means that a requirement `T: Sendable` implies `T: SendableMetatype`, so a generic function that uses concurrency along with `Sendable` requirements, like this::

```swift
func doSomethingElsewhere<T: Sendable & P>(_ value: T) {
  Task.detached {
    value.f() // okay
  }
}
```

will continue to work with the stricter model for generic functions in this proposal.

The proposed change for generic functions does have an impact on source compatibility, where functions like `callQGElsewhere` will be rejected. However, the source break is limited to generic code that:

1. Passes the metatype `T.Type` of a generic parameter `T` across isolation boundaries;
2. Does not have a corresponding constraint `T: Sendable` requirement; and
3. Is compiled with strict concurrency enabled (either as Swift 6 or with warnings).

Experiments with the prototype implementation of this feature uncovered very little code that was affected by this change. The benefit to introducing this source break is that the vast majority of existing generic code will work unmodified with isolated conformances, or (if it's using concurrency) correctly reject the use of isolated conformances in their callers.

### Rule 3: Isolated conformances are in their global actor's region

With [region-based isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md), values of non-`Sendable` type can be transferred to another isolation domain when it can be proven that they are in their own "region" of code that separate from all other regions. Isolated conformances are considered to be within the region of their global actor, so any value formed that involves an isolated conformance will have its region merged with that of the isolated conformance. For example:

```swift
@MainActor func acceptSending(_ value: sending any P) { }

@MainActor func passSending() {
  let c1 = C()         // in its own region
  let ap1: any P = c1  // merges region of c1 with region of the conformance of C: P (MainActor)
  acceptSending(ap1)   // error: argument to sending parameter is within the MainActor region
  
  let c2 = C()         // in its own region
  let wp2 = WrapsP(c2) // merges region of c2 with region of the conformance of C: P (MainActor)
  acceptSending(c)     // error: argument to sending parameter is within the MainActor region
}
```

### Inferring global actor isolation for global-actor-isolated types

Types that are isolated to a global actor are very likely to want to have their conformances to be isolated to that global actor. This is especially true because the members of global-actor isolated types are implicitly isolated to that global actor, so obvious-looking code is rejected:

```swift
@MainActor
class MyModelType: P {
  func f() { } // error: implements P.f, is implicitly @MainActor
               // but conformance to P is not isolated
}
```

With this proposal, the fix is to mark the conformance as `@MainActor`:

```swift
@MainActor
class MyModelType: @MainActor P { 
  func f() { } // okay: implements P.f, is implicitly @MainActor
}
```

However, the inference rule feels uneven: why is the `@MainActor` in one place inferred but not in the other? 

In the future, we'd like to extend the global actor inference rule for global-actor isolated types to also infer global actor isolated on their conformances. This makes the obvious code above also correct:

```swift
@MainActor
class MyModelType: /*inferred @MainActor*/ P { 
  func f() { } // implements P.f, is implicitly @MainActor
}
```

If this inference is not desired, one can use `nonisolated` on the conformances:

```swift
@MainActor
class MyModelType: nonisolated Q {
  nonisolated static func g() { } // implements Q.g, is non-isolated
}
```

There are two additional inference rules that imply `nonisolated` on a conformance of a global-actor-isolated type:

* If the protocol inherits from `SendableMetatype` (including indirectly, e.g., from `Sendable`), then the isolated conformance could never be used, so it is inferred to be `nonisolated`.
* If all of the declarations used to satisfy protocol requirements are `nonisolated`, the conformance will be assumed to be `nonisolated`. The conformance of `MyModelType` to `Q` would be inferred to be `nonisolated` because the static method `g` used to satisfy `Q.g` is `nonisolated.`

This proposed change is source-breaking in the cases where a conformance is currently `nonisolated`, the rules above would not infer `nonisolated`, and the conformance crosses isolation domains. There, conformance isolation inference is  staged in via an upcoming feature (`InferIsolatedConformances`) that can be folded into a future language mode. Fortunately, it is mechanically migratable: existing code migrating to `InferIsolatedConformances` could introduce `nonisolated` for each conformance of a global-actor-isolated type.

### Infer `@MainActor` conformances

[SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md) provides the ability to specify that a given module will infer `@MainActor` on any code that hasn't explicitly stated isolated (or non-isolation, via `nonisolated`). In a module that infers `@MainActor`, the upcoming feature `InferIsolatedConformances` (from the prior section) should also be enabled. This means that types will get main-actor isolation and also have their conformances main-actor isolated, extending the "mostly single-threaded" view of SE-0466 to interactions with generic code:

```swift
/*implicit @MainActor*/
class MyClass: /*implicit @MainActor*/P { ... }
```

## Source compatibility

As discussed in the section on rule (2), this proposal introduces a source compatibility break for code that is using strict concurrency and passes uses conformances of non-`Sendable` type parameters in other isolation domains. The overall amount of such code is expected to be small, because it's likely to be rare that the conformances of generic types cross isolation boundaries but values of those types do not.

Initial testing of an implementation of this proposal found very little code that relied on `Sendable` metatypes where the corresponding type was not also `Sendable`. Therefore, this proposal suggests to accept this as a source-breaking change with strict concurrency (as a warning in Swift 5, error in Swift 6) rather than staging the change through an upcoming feature or alternative language mode.

## ABI compatibility

Isolated conformances can be introduced into the Swift ABI without any breaking changes, by extending the existing runtime metadata for protocol conformances. All existing (non-isolated) protocol conformances can work with newer Swift runtimes, and isolated protocol conformances will be usable with older Swift runtimes as well. There is no technical requirement to restrict isolated conformances to newer Swift runtimes.

However, there is one likely behavioral difference with isolated conformances between newer and older runtimes. In newer Swift runtimes, the functions that evaluate `as?` casts will check of an isolated conformance and validate that the code is running on the proper executor before the cast succeeds. Older Swift runtimes that don't know about isolated conformances will allow the cast to succeed even outside of the isolation domain of the conformance, which can lead to different behavior that potentially involves data races. It should be possible to provide (optional) warnings when running on newer Swift runtimes when a cast fails due to isolated conformances but would incorrectly succeed on older platforms.

## Future Directions

### Actor-instance isolated conformances

Actor-instance isolated conformances are considerably more difficult than global-actor isolated conformances, because the conformance needs to be associated with a specific instance of that actor. Even enforcing rule (1) is nonobvious. As with `isolated` parameters, we could spell actor-instance isolation to a protocol `P` with `isolated P`. The semantics would need to be similar to what follows:

```swift
actor A: isolated P {
  func f() { } // implements P.f()
}

func instanceActors(a1: isolated A, a2: A) {
  let anyP1: any P = a1     // okay: uses isolated conformance 'A: P' only on a1, to which this function is isolated
  let anyP2: any P = a2     // error: uses isolated conformance 'A: P' on a2, which is not the actor to which this function is isolated 
  
  let a3 = a1
  let anyP3: any P = a3     // okay? requires dataflow analysis to determine that a3 and
                            // a1 are in the isolation domain of this function
  
  let wrappedA1: WrapsP<A>   // error? isolated conformance 'A: P' used without being
                             // anchored to the actor instance a1
  var wrappedA2: WrapsP<A> = .init(a1) // okay? isolated conformance 'A: P' is used with a1
  wrappedA2.value = a3       // error: isolated conformance 'A: P' used in the type is
                             // in a different isolation domain than 'a1'
}
```

It's possible that these problems can be addressed by relying more heavily on region-based isolation akin to rule (3). This can be revisited in the future if the need justifies the additional complexity and we find a suitable implementation strategy.

## Alternatives considered

### "Non-Sendable" terminology instead of isolated conformances

Isolated conformances are a lot like non-`Sendable` types, in that they can be freely used within the isolation domain in which they are created, but can't necessarily cross isolation domain boundaries. We could consider using "sendable" terminology instead of "isolation" terminology, e.g., all existing conformances are "Sendable" conformances (you can freely share them across isolation domain boundaries) and these new conformances are "non-Sendable" conformances. Trying to send such a conformance across an isolation domain boundary is, of course, an error.

However, the "sendable" analogy breaks down or causes awkwardness in a few places:

* Values of non-`Sendable` type can be sent across isolation domain boundaries due to [region-based isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md), but the same cannot be said of isolated conformances, so they are more non-Sendable than most non-Sendable things.

* Global-actor-isolated types are usually `Sendable`, but their conformances would generally need to be non-`Sendable`.

* Usually things are non-`Sendable` but have to be explicitly opt-in to being `Sendable`, whereas conformances would be the opposite.

* Diagnostics for invalid conformance declarations that could be addressed with isolated conformances are necessarily described in terms of isolation, e.g.,
  ````
  error: main-actor isolated method 'f' cannot satisfy non-isolated requirement `f` of protocol P
  ````

  It wouldn't make sense to recast that diagnostic in terms of "sendable", and would also be odd for the fix to an isolation-related error message to be "add non-Sendable."

* There is no established spelling for "not Sendable" that would work well on a conformance.

### Isolated conformance requirements

This proposal introduces the notion of isolated conformances, which can satisfy a conformance requirement only when the corresponding type isn't `Sendable`. There is no way for a generic function to express that some protocol requirements are intended to allow isolated conformances while others are not. That could be made explicit, for example by allowing requirements of the form `T: isolated P` (which would work with both isolated and non-isolated conformances) and `T: nonisolated P` (which only allows non-isolated conformances). One could combine these in a given generic signature:

```swift
func mixedConformances<T: Sendable & isolated P & nonisolated Identifiable>(_ x: [T]) {
  for item in x {
    item.foo() // Can use requirements of P
    print(x.id) // Can use requirements of Identifiable
  }

  Task.detached {
    for item in x {
      item.foo() // error: cannot capture isolated conformance of 'T' to 'P' in a closure in a different isolation domain
      print(x.id) // okay: conformance to Identifable is nonisolated
    }
  }
}
```

This is a generalization of the proposed rules that makes more explicit when conformances can cross isolation domains within generic code, as well as allowing mixing of isolated and non-isolated conformances as in the example. One can explain this proposal's rule involving `SendableMetatype` requirements and isolated conformances in terms of (non)-isolated requirements. For a given conformance requirement `T: P` :

* If `T: SendableMetatype`, `T: P` is interpreted as `T: nonisolated P`.
* If not `T: SendableMetatype`, `T: P` is interepreted as `T: isolated P`.

The main down side of this alternative is the additional complexity it introduces into generic requirements. It should be possible to introduce this approach later if it proves to be necessary, by treating it as a generalization of the existing rules in this proposal.

### Require `nonisolated` rather than inferring it

Under the upcoming feature `InferIsolatedConformances`, this proposal infers `nonisolated` for conformances when all of the declarations that satisfy requirements of a protocol are themselves `nonisolated`. For example:

```swift
nonisolated protocol Q {
  static func create() -> Self
}

@MainActor struct MyType: /*infers nonisolated*/ Q {
  nonisolated static func create() -> MyType { ... }
}
```

This inference is important for providing source compatibility with and without `InferIsolatedConformances`, and is especially useful useful when combined with default main-actor isolation ([SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)), where many more types will become main-actor isolated. Experience with using these features together also identified some macros (such as [`@Observable`](https://developer.apple.com/documentation/observation/observable())) that produced `nonisolated` members for a protocol conformances, but had not yet been updated to mark the conformance as `nonisolated`. Macro-generated code is much harder for users to update when a source-compatibility issue arises, which makes `nonisolated` conformance inference particularly important for source compatibility.

However, this inference rule has downsides. It means one needs to examine a protocol and how a type conforms to that protocol to determine whether the conformance might be `nonisolated`, which can be a lot of work for the developer reading the code as well as the compiler.  It can also change over time: for example, a default implementation of a protocol requirement will likely be `nonisolated`, but a user-written one within a main-actor-isolated type would be `@MainActor` and, therefore, make the conformance `@MainActor`.

One alternative would be to introduce this inference rule for source compatibility, but treat it as a temporary measure to be disabled again in some future language mode. Introducing the inference rule in this proposal does not foreclose on that possibility: if we find that the `nonisolated` conformance inference rule here is harmful to readability, a separate proposal can deprecate it in a future language mode, providing a suitable migration timeframe.

## Revision history

* Changes in amendment review:
  * If the protocol inherits from `SendableMetatype` (including indirectly, e.g., from `Sendable`), then the isolated conformance could never be used, so it is inferred to be `nonisolated`.
  * If all of the declarations used to satisfy protocol requirements are `nonisolated`, the conformance will be assumed to be `nonisolated`.
* Changes in review:
  * Within a generic function, use sendability of metatypes of generic parameters as the basis for checking, rather than treating specific conformances as potentially isolated. This model is easier to reason about and fits better with `SendableMetatype`, and was used in earlier drafts of this proposal.
