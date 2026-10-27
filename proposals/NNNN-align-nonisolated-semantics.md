# Align the semantics of `nonisolated`

- Proposal: [SE-NNNN](NNNN-align-nonisolated-semantics.md)
- Authors: [Sima Nerush](https://github.com/simanerush),
  [Holly Borla](https://github.com/hborla),
  [Pavel Yaskevich](https://github.com/xedin)
- Review Manager: TBD
- Status: **Awaiting implementation**
- Vision:
  [Improving the approachability of data-race safety](https://github.com/swiftlang/swift-evolution/blob/main/visions/approachable-concurrency.md)
- Implementation:
- Upcoming Feature Flag: `MyFeatureName`
- Review: ([pitch](https://forums.swift.org/...))

## Summary of changes

This proposal makes an explicit `nonisolated` on a protocol requirement have the same meaning as an unannotated requirement: the absence of isolation. Witnesses no longer infer the `nonisolated` default from such requirements, and get their isolation from their own context instead, as they already do in `MainActor` default isolation modules.

## Motivation

In most positions, `nonisolated` means the absence of isolation. In a module with `nonisolated` default isolation, spelling `nonisolated` on a function is the same as writing nothing at all, and in a module with `MainActor` default isolation, it lets the programmer opt the declaration out of the default.

Since [SE-0449](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0449-nonisolated-for-global-actor-cutoff.md), `nonisolated` can also be written on types, extensions, and protocols, and its meaning is consistent: the declaration isn't isolated. An unannotated type can infer global actor isolation from its conformances, superclass, and property wrappers. Writing `nonisolated` on the type states that the type isn't isolated, so there is nothing left to infer: the type and the members declared in it remain `nonisolated`. Stopping the inference isn't a separate meaning of `nonisolated` on types; it follows from `nonisolated` meaning the absence of isolation:

```swift
@MainActor
protocol Job {
  func run()
}

struct SyncJob: Job { // inferred '@MainActor' from the conformance to 'Job'
  func run() { } // main actor-isolated
}

nonisolated struct PrintJob: Job { // not isolated
  func run() { } // nonisolated
}
```

In each of these positions, `nonisolated` applies to the declaration it's written on, and to the declarations inside it.

Protocol requirements are the only exception. An explicit `nonisolated` on a requirement doesn't just say that the requirement isn't isolated, it also becomes a source of isolation inference: a witness written in the same scope as the conformance infers `nonisolated` from the requirement, overriding the isolation of the conforming type. To get the conforming type's isolation back, the programmer has to override the inferred `nonisolated` by writing the isolation on the witness explicitly.

Consider two protocols whose requirements are both `nonisolated`, one written explicitly and one implicitly:

```swift
protocol Purgeable {
  nonisolated func purge()
}

protocol Clearable {
  func clear()
}

@MainActor
final class ResponseCache: Purgeable {
  var entries: [String] = []

  func purge() {
    entries.removeAll() // error: main actor-isolated property 'entries' can not be mutated from a nonisolated context
  }
}

@MainActor
final class SessionStore: Clearable { // error: conformance of 'SessionStore' to protocol 'Clearable' crosses into main actor-isolated code and can cause data races
  var entries: [String] = []

  func clear() { // note: main actor-isolated instance method 'clear()' cannot satisfy nonisolated requirement
    entries.removeAll()
  }
}
```

`clear()` is main actor-isolated like every other member of `SessionStore`, so the conformance is diagnosed. `purge()`, however, is inferred to be `nonisolated` because of the `nonisolated` keyword on a requirement in a different declaration, and the error shows up in its body instead. Nothing at the declaration of `purge()` indicates that it isn't isolated to the main actor.

The error on `SessionStore` can be resolved by isolating its conformance to `Clearable` to the main actor, which lets the main actor-isolated `clear()` satisfy the requirement. The same doesn't work for `ResponseCache`: `purge()` still infers `nonisolated` from the requirement, regardless of the isolation of the conformance, so isolating the conformance doesn't make `purge()` main actor-isolated:

```swift
@MainActor
final class ResponseCache: @MainActor Purgeable {
  var entries: [String] = []

  func purge() {
    entries.removeAll() // error: main actor-isolated property 'entries' can not be mutated from a nonisolated context
  }
}

@MainActor
final class SessionStore: @MainActor Clearable {
  var entries: [String] = []

  func clear() { // okay, the conformance is main actor-isolated
    entries.removeAll()
  }
}
```

To get the behavior of `SessionStore`, the programmer has to also write `@MainActor` on `purge()` itself.

The inference only applies to witnesses written in the same scope as the conformance, so moving `purge()` into an extension changes its isolation:

```swift
@MainActor
final class ResponseCache: Purgeable { // error: conformance of 'ResponseCache' to protocol 'Purgeable' crosses into main actor-isolated code and can cause data races
  var entries: [String] = []
}

extension ResponseCache {
  func purge() { // main actor-isolated, like the rest of 'ResponseCache'
    entries.removeAll()
  }
}
```

The behavior of explicit `nonisolated` also depends on how the protocol's module was compiled. In a module with `MainActor` default isolation, a protocol whose requirements aren't isolated has to say so explicitly, for example as a `nonisolated protocol`. Witnesses in client modules then infer `nonisolated` from those requirements, while the witnesses for the same protocol declared in a module with `nonisolated` default isolation don't:

```swift
// Module A, compiled with '-default-isolation MainActor'
public nonisolated protocol Purgeable {
  func purge()
}

// Module B, compiled with 'nonisolated' default isolation
public protocol Clearable {
  func clear()
}

// Client module, compiled with 'nonisolated' default isolation
import A
import B

@MainActor
final class ResponseCache: Purgeable {
  func purge() { } // inferred 'nonisolated'
}

@MainActor
final class SessionStore: Clearable {
  func clear() { } // main actor-isolated
}
```

As the code above demonstrates, the same code infers different isolation for its witnesses depending on the module's default isolation, which makes it harder to move code between targets and to reason about it.[^1]

[^1]: This discrepancy was discussed in [Effects of explicit nonisolated on isolation inference](https://forums.swift.org/t/effects-of-explicit-nonisolated-on-isolation-inference/82961).

## Proposed solution

We propose that an explicit `nonisolated` on a protocol requirement mean the absence of isolation in every module, regardless of its default isolation. Witnesses don't infer `nonisolated` from such requirements, and get their isolation from their own context, the same way they do for unannotated requirements.

Under this proposal, `ResponseCache` and `SessionStore` from the motivation section behave the same way. `purge()` and `clear()` are both main actor-isolated, letting the programmer isolate the conformances:

```swift
@MainActor
final class ResponseCache: @MainActor Purgeable {
  var entries: [String] = []

  func purge() { // main actor-isolated
    entries.removeAll() // okay
  }
}

@MainActor
final class SessionStore: @MainActor Clearable {
  var entries: [String] = []

  func clear() { // main actor-isolated
    entries.removeAll() // okay
  }
}
```

## Detailed design

### Explicit `nonisolated` on protocol requirements

Under this proposal, a  witness doesn't infer isolation from a requirement that is explicitly `nonisolated` (including `nonisolated(unsafe)`). It gets its isolation from its context, as it would for an unannotated requirement:

```swift
protocol P {
  nonisolated func f()
}

protocol Q {
  func g()
}

@MainActor
struct S1: P {
  func f() { } // main actor-isolated, previously inferred 'nonisolated'
}

@MainActor
struct S2: Q {
  func g() { } // main actor-isolated
}
```

The rule doesn't depend on where the witness is written, or on the default isolation of the module that declares the protocol:

```swift
@MainActor
struct S3: P { }

extension S3 {
  func f() { } // main actor-isolated, as before
}
```

## Source compatibility

This proposal has no source compatibility impact. The new rules will take effect in a future language mode. In the Swift 6 language mode, and in the Swift 5 language mode with complete concurrency checking, the compiler emits warnings at the affected code sites.

In the future language mode, this proposal changes the isolation of witnesses that are currently inferred to be `nonisolated` from an explicitly `nonisolated` requirement. Such a witness gets the isolation of its surrounding context, so existing code can stop compiling:

* uses of the witness from outside of its isolation domain become errors, and
* the conformance crosses into isolated code, which is an error unless the conformance is isolated.

```swift
// language-version=future

protocol P {
  nonisolated func f()
}

@MainActor
struct S: P { // error: conformance of 'S' to protocol 'P' crosses into main actor-isolated code and can cause data races
  func f() { }
}

nonisolated func test(_ s: S) {
  s.f() // error: call to main actor-isolated instance method 'f()' in a synchronous nonisolated context
}
```

In the Swift 6 language mode, and in the Swift 5 language mode with complete concurrency checking, the compiler warns at each witness whose isolation will change, that is, a witness that infers `nonisolated` from an explicitly `nonisolated` requirement, while its context is isolated:

```swift
// language-version=6, or language-version=5 with -strict-concurrency=complete

protocol P {
  nonisolated func f()
}

@MainActor
struct S: P {
  func f() { } // warning: instance method 'f()' will not infer 'nonisolated' from protocol requirement 'f()' in a future language mode, and will be main actor-isolated
               // note: mark 'f()' 'nonisolated' to keep its current behavior
}

nonisolated func test(_ s: S) {
  s.f() // okay
}
```

The warning is resolved by spelling out the witness's isolation. To keep the current behavior, the programmer marks the witness `nonisolated`, which has the same meaning in every language mode:

```swift
@MainActor
struct S: P {
  nonisolated func f() { } // okay
}
```

Alternatively, the programmer can adopt the new behavior right away by marking the witness `@MainActor`, in which case the conformance and the use in `test(_:)` are diagnosed as they would be in the future language mode.

Because the change is mechanically migratable, it is staged in through an upcoming feature that can be folded into a future language mode.

## ABI compatibility

This proposal doesn't change the ABI of any declaration whose isolation is unchanged. A `public` witness whose inferred isolation changes from `nonisolated` to a global actor changes the API of its module; library authors can write `nonisolated` on such witnesses to keep their current isolation.

## Implications on adoption

Adopting the upcoming feature can change the isolation of witnesses, including `public` ones. Library authors should mark the affected witnesses `nonisolated` explicitly when adopting the feature, so that clients aren't affected. With the witnesses annotated, the feature can be adopted and un-adopted without affecting source or ABI compatibility.

## Future directions


## Alternatives considered

### Infer `nonisolated` from every `nonisolated` requirement

Instead of ignoring an explicit `nonisolated` on a requirement, the compiler could make every `nonisolated` requirement, explicit or implicit, a source of inference for its witnesses. This would also make the two spellings consistent, but it would make every witness of a protocol without isolation `nonisolated`. That would make isolated conformances unusable without explicitly isolating every witness, and it would change the isolation of a large amount of existing code.

### A dedicated spelling for pushing witnesses toward `nonisolated`

A protocol author could be given a new spelling that requests `nonisolated` witnesses, keeping the current inference behind an explicit opt-in. As discussed in [SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md#alternative-to-sendablemetatype-for-suppressing-main-actor-inference), inheriting from `SendableMetatype` already expresses that conformances to a protocol should be `nonisolated`, so this proposal doesn't introduce new syntax.

## Acknowledgments
