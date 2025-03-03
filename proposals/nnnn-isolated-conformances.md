# Global-actor isolated conformances

* Proposal: [SE-NNNN](NNNN-isolated-conformances.md)

* Authors: [Doug Gregor](https://github.com/DougGregor)

* Review Manager: TBD

* Status: **Awaiting review**

* Vision: [Improving the approachability of data-race safety](https://github.com/swiftlang/swift-evolution/blob/main/visions/approachable-concurrency.md)

* Implementation: On `main` with the experimental features `IsolatedConformances` and `StrictSendableMetatypes`.
* Review: ([pitch](https://forums.swift.org/t/pre-pitch-isolated-conformances/77726))



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

This proposal introduces the notion of an *isolated conformance*, which is a conformance that can only be used within the isolation domain of the type. For the code above, the conformance to `Equatable` can be specified as `isolated` as follows:

```swift
@MainActor
class MyModelType: isolated Equatable {
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

This proposal introduces the notion of an `isolated` conformance of a global-actor-isolated type to a protocol. Isolated conformances are conformances whose use is restricted to the same global actor as the conforming type. This is the same effective restriction as the `nonisolated`/`assumeIsolated` pattern above, but enforced statically by the compiler and without any boilerplate. The following defines an isolated conformance of `MyModelType` to `Equatable`:

```swift
@MainActor
class MyModelType: isolated Equatable {
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

This `parallelContains` function can send values of type `Element` to another isolation domain, and from there call the `Equatable.==` function. If the conformance to `Equatable` is isolated, this would violate the data race safety guarantees. Therefore, this proposal specifies that an isolation conformance cannot be used in conjunction with a `Sendable` conformance:

```swift
@MainActor
func parallelHasMatching(_ value: MyModelType, in modelValues: [MyModelType]) -> Bool {
  // error: isolated conformance of 'MyModelType' to 'Equatable' cannot be used to 
  // satisfy conformance requirement for a `Sendable` type parameter 'Element'.
  return modelValues.parallelContains(value)
}
```

Providing full data-race safety with isolated conformances also requires us to reason about the sendability of a *metatype*, because sending the metatype to another isolation domain can carry protocol conformances with it. For example, the following code could introduce a data race if the conformance of `T` to `GlobalLookup` were `isolated`, despite not having a `Sendable` constraint:

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

To prevent such problems in generic code, this proposal restricts the ability to send metatypes of type parameters (e.g., `T.Type`) across isolation domains. The above code, which is accepted in Swift 6 today, would be rejected by the proposed changes here with an error message like:

```swift
error: capture of non-sendable type 'T.Type' in closure
```

A function like `hasNamed` can express the need for a `Sendable` metatype by introducing a requirement `T: SendableMetatype` (to make the metatype `Sendable`), e.g.,

```swift
func hasNamed<T: GlobalLookup & SenableMetatype>(_: T.Type, name: String) async -> Bool {
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



When conforming an actor-isolated type to a protocol, one cannot satisfy a nonisolated protocol requirement with an actor-isolated declaration. This can make actor-isolated types particularly hard to use with most protocols. For example:

```swift
protocol P {
  func f()
}

@MainActor class C: P { 
   func f() { } // error: main actor isolated function 'f' cannot satisfy nonisolated requirement 'f' of protocol P
}
```

This error is necessary to maintain data-race safety: if an instance of `C` ended up being used as a `P` outside of the main actor, a call to `P.f` (which is non-isolated) would end up invoking `C.f` off of the main actor, introducing a data race.

The current solution is to make each function `nonisolated`, then use `assumeIsolated` to dynamically check that the the function was only called from the main actor, like this:

```swift
@MainActor class C: P { 
   nonisolated func f() { 
     MainActor.assumeIsolated {
       // do main-actor things
     }
   }
}
```

This does provide *dynamic* data-race safety, but requires a lot of boilerplate and does not provide good static data-race safety.

This proposal introduces the notion of an *isolated* conformance, which is a conformance that can only be used within the stated isolation domain. An isolated conformance lifts the restriction that only non-isolated functions can satisfy protocol requirements:

```swift
@MainActor class C: isolated P { 
   func f() { } // @MainActor-isolated, which is okay because the conformance to P is @MainActor-isolated
}
```

One can only use an isolated conformance within the isolation domain, but never outside of it, so it's guaranteed that any call through `P.f` to `C.f` is only possible in code that's already correctly isolated. For example, this would allow using generic functions with actor-isolated types from inside the main actor:

```swift
nonisolated func callPF<T: P>(_ value: T) {
  t.f()
}

@MainActor func callPFC(c: C) {
  callPF(c) // okay, uses isolated conformance C: P entirely within the @MainActor isolation domain
}

nonisolated func callPFCIncorrectly(c: C) {
  callPF(c) // error: uses isolated conformance C: P outside the @MainActor isolation domain
}
```

## Detailed design

The proposed solution describes the basic shape of isolated conformances and how they interact with the type system. This section goes into more detail on the data-race safety issues that arise from the introduction of isolated conformances into the language. Then it details three rules that, together, ensure freedom from data race safety issues in the presence of isolated conformances:

1. An isolated conformance can only be used within its isolation domain.
2. When an isolated conformance is used to satisfy a generic constraint `T: P`, the generic signature must not include either of the following constraints: `T: Sendable` or `T.Type: Sendable`. 
3. A value using a conformance isolated to a given global actor is within the same region as that global actor.

### Data-race safety issues

An isolated conformance must only be used within its actor's isolation domain. Here are a few examples that demonstrate the kinds of problems that need to be addressed by a design for isolated conformances to ensure that this property holds.

First, forming an isolated conformance outside of its isolation domain creates immediate problems. For example:

```swift
protocol Q {
  static func g() { }
}

extension C: isolated Q {
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

Here, `sendMe` ends up calling `C.f()` from outside the main actor. The combination of an isolated conformance and a `Sendable` requirement on the same type underlies this issue. To address the problem, we can prohibit the use of an isolation conformance if the corresponding type parameter (e.g, `T` in the example above) also has a `Sendable` requirement.

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

Metatypes introduce yet another issue:

```swift
nonisolated func callQGElsewhere<T: Q>(_: T.Type) {
  Task.detached {
    T.g()
  }
}

func metatypeProblem() {
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

### Rule 1: Isolated conformance can only be introduced within its isolation domain

Rule (1) is straightforward: the conformance can only be used within a context that is also isolated to the same global actor. This applies to any use of a conformance anywhere in the language. For example:

```swift
@MainActor struct S: isolated P { }

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
```

### Rule 2: Isolated conformances can only be abstracted away for non-`Sendable` types

Rule (2) ensures that when information about an isolated conformance is abstracted away by the type system, the type parameter requiring the conformance cannot leave the isolation domain. For values of the type parameter (call it `T`), it is sufficient to establish that it does *not* conform to `Sendable`, i.e.,  the constraint`T: Sendable` is not part of the generic signature. Some examples:

```swift
func acceptsSendableP<T: Sendable & P>(_ value: T) { }
func acceptsAny<T>(_ value: T) { }
func acceptsSendable<T: Sendable>(_ value: T) { }

@MainActor func passIsolated(s: S) {
  acceptsP(s)         // okay: the type parameter 'T' requires P but not Sendable
  acceptsSendableP(s) // error: the type parameter 'T' requires Sendable
  acceptsAny(s)       // okay: no isolated conformance
  acceptsSendable(s)  // okay: no isolated conformance
}
```

The same checking occurs when the type parameter is hidden, for example when dealing with `any` or `some` types:

```swift
@MainActor func isolatedAnyGood(s: S) {
  let a: any P = s   // okay: the 'any P' cannot leave the isolation domain
}

@MainActor func isolatedAnyBad(s: S) {
  let a: any Sendable & P = s   // error: the (hidden) type parameter for the 'any' is Sendable
}

@MainActor func returnIsolatedSomeGood(s: S) -> some P {
  return s   // okay: the 'any P' cannot leave the isolation domain
}

@MainActor func returnIsolatedSomeBad(s: S) -> some Sendable & P {
  return s   // error: the (hidden) type parameter for the 'any' is Sendable
}
```

As noted in the earlier discussion of data-race safety issues, protecting against values being sent to another isolation domain is insufficient, because passing the *metatype* of the type can also carry the isolated conformances with it. Recall the example from earlier:

```swift
protocol Q {
  static func g() { }
}

nonisolated func callQGElsewhere<T: Q>(_: T.Type) {
  Task.detached {
    T.g()
  }
}
```

If the conformance provided for `T: Q` is isolated to a global actor, the call `T.g()` from another isolation domain will break data race safety. This could be diagnosed in the implementation of `callQGElsewhere` if `T.Type` were not guaranteed to be `Sendable`. This sets up a contradiction with SE-0302, which introduced the notion of `Sendable` and specifies that [all metatypes are `Sendable`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md#metatype-conformance-to-sendable). 

We can borrow from the approach taken by [non-copyable](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md) and [non-escapable](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md) types, where we introduce the notion of a suppressed constraint to allow generics to operate with a set of capabilities that is more limited than "normal" types. For example, we could introduce a constraint of the form `T: ~SendableMetatype` to make the metatype of `T` not `Sendable` within a given generic function. If we applied this constraint to `callQGElsewhere`, we would get a compile-time error:

```swift
nonisolated func callQGElsewhere_restricted<T: Q>(_: T.Type) where T: ~SendableMetatype {
  Task.detached {
    T.g() // error: capture of non-Sendable metatype T.Type in concurrently-executed closure
  }
}
```

With this notion, we could amend rule (2) to prohibit using an isolated protocol conformance for a requirement `T: Q` when the generic signature contains either the requirement `T: Sendable` or `T: SendableMetatype`. This closes the data race safety hole with isolated conformances being carried through metatypes.

Unfortunately, this means that isolated conformances won't work with any existing generic code, because all generic code in existence today assumes that all metatypes are `Sendable`. Most of that code could be updated with requirements of the form `T.Type: ~Sendable` and without other changes, but it would require an ecosystem-wide change in support of a somewhat niche feature.

Therefore, this proposal suggests that we change the meaning of existing generic code to *not* be able to assume that a given metatype depending on a generic parameter is `Sendable`. Essentially, it will be as-if `T: ~SendableMetatype` has been applied to every generic parameter `T`. This will have the effect of rejecting the implementation of `callQGElsewhere`. After such a change to the language, the signature of `callQGElsewhere` could be updated by adding the requirement `T.Type: Sendable`. 

Note that, any time a value of type `T` crosses an isolation boundary, it's metatype is accessible via   [`type(of:)`](https://developer.apple.com/documentation/swift/type(of:)), so it also crosses the isolation boundary. This provides us with an inference rule that can help lessen the impact of this source compatibility break: if a generic signature contains a requirement `T: Sendable`, then we can infer the requirement `T: SendableMetatype`. Doing so involves specifying that `Sendable` refines a new marker protocol, `SendableMetatype`:

```swift
/*@marker*/ protocol SendableMetatype { }
/*@marker*/ protocol Metatype: SendableMetatype { }
```

With this inference, a generic function like this will still continue to work even after the proposed language change:

```swift
func doSomethingElsewhere<T: Sendable & P>(_ value: T) {
  Task.detached {
    value.f() // okay
  }
}
```

The source compatibility break required to enforce rule (2) is therefore limited to generic code that:

1. Passes a metatype of some generic type `T` across isolation domains;
2. Has a requirement on `T` that is not a marker protocol (e.g, `BitwiseCopyable`) or suppression (`~Escapable`);
3. Does not have a corresponding constraint `T: Sendable`; and
4. Is compiled with strict concurrency enabled (either as Swift 6 or with warnings).

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

## Source compatibility

As discussed in the section on rule (2), this proposal introduces a source compatbility break for code that is using strict concurrency and passes metatypes of non-`Sendable` type parameters across isolation domains. The overall amount of such code is expected to be small, because it's likely to be rare that the metatypes of generic types cross isolation boundaries but values of those types do not.

Initial testing of an implementation of this proposal found very little code that relied on `Sendable` metatypes where the corresponding type was not also `Sendable`. Therefore, this proposal suggests to accept this as a source-breaking change with strict concurrency (as a warning in Swift 5, error in Swift 6) rather than staging the change through an upcoming feature or alternative language mode.

## ABI compatibility

Isolated conformances can be introduced into the Swift ABI without any breaking changes, by extending the existing runtime metadata for protocol conformances. All existing (non-isolated) protocol conformances can work with newer Swift runtimes, and isolated protocol conformances will be usable with older Swift runtimes as well. There is no technical requirement to restrict isolated conformances to newer Swift runtimes.

However, there is one likely behavioral difference with isolated conformances between newer and older runtimes. In newer Swift runtimes, the functions that evaluate `as?` casts will check of an isolated conformance and validate that the code is running on the proper executor before the cast succeeds. Older Swift runtimes that don't know about isolated conformances will allow the cast to succeed even outside of the isolation domain of the conformance, which can lead to different behavior that potentially involves data races.

## Future Directions

### Actor-instance isolated conformances

Actor-instance isolated conformances are considerably more difficult than global-actor isolated conformances, because the conformance needs to be associated with a specific instance of that actor. Even enforcing rule (1) is nonobvious. The following code illustrates some of the issues:

```swift
actor A: isolated P {
  func f() { } // implements P.f()
}

func instanceActors(a1: isolated A, a2: A) {
  let anyP1: any P = a1     // okay: uses isolated conformance 'A: P' only on a1, to which this function is isolated
  let anyP2: any P = a2     // error: uses isolated conformance 'A: P' on a2, which is not 
  
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

It's possible that these problems can be addressed by relying more heavily on region-based isolation akin to rule (3). This can be revisited in the future if the need justifies the additional complexity.

### Allow non-isolated types to have isolated conformances

It would be possible to allow non-isolated types have isolated conformances. For example, a type that is not isolated to any domain but implements a handful of functions in a specific global isolated domain, e.g.:

```swift
protocol P {
  func onEvent(_ event: Event)
}

class X: @MainActor isolated P {
  @MainActor func onEvent(_ event: Event) { 
    // ...
  }
}
```

There is a syntax choice to be made here: the bare `isolated` keyword used throughout the proposal optimizes for the expected-to-be-common case where the type is isolated, which effectively forces the conformance to be isolated, and avoids having to restate the isolation. In this case where conformance is isolated but the type is not, the `isolated` keyword is insufficient: we need to state the global actor in some manner. One path forward would be to annotate the conformance with just the global actor, e.g.,

```swift
extension X: @MainActor P {
  @MainActor func onEvent(_ event: Event) { ... }
}
```

This could be in addition to the `isolated P` syntax (providing the generalization), such that `isolated P` is syntactic sugar for "the global actor of the type". Or it could be the only syntax provided, and `isolated P`  might only come back if actor-instance isolated conformances (from the prior section) happen.

### Infer `isolated` on conformances for types that infer `@MainActor`

If Swift gains a setting to infer `@MainActor` on various declarations within a module, we should consider inferring `isolated` on conformances for types that have had their actor isolation inferred. This should make single-threaded code easier to write, because protocol conformances will "just work" so long as the conformances themselves aren't referenced outside of the main actor.

## Alternatives considered

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
