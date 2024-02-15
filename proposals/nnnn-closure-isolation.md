# Closure isolation control

* Proposal: [SE-NNNN](nnnn-closure-isolation.md)
* Authors: [Sophia Poirier](https://github.com/sophiapoirier), [John McCall](https://github.com/rjmccall)
* Review Manager: TBD
* Implementation: On `main` gated behind `-enable-experimental-feature TODO`
* Previous Proposals: [SE-0313](0313-actor-isolation-control.md), [SE-0316](0316-global-actors.md)
* Review: ([pitch](https://forums.swift.org/TODO))

## Introduction

This proposal provides the ability to explicitly specify actor-isolation or non-isolation of a closure, as well as providing a parameter attribute to guarantee that a closure parameter inherits the isolation of the context.

## Motivation

The formal isolation of a closure can be explicitly specified as global actor isolation:

```swift
Task { @MainActor in
  print("global actor isolation")
}
```

Without a global actor isolation annotation, actor-isolation or non-isolation of a closure is inferred but cannot be explicitly specified. This proposal enables closures to be fully explicit about all three types of formal isolation:
* `nonisolated`
* global actor
* specific actor value

Explicit annotation has the benefit of disabling inference rules and the potential that they lead to a formal isolation that is not preferred. For example, there are circumstances where it is beneficial to guarantee that a closure is `nonisolated` therefore knowing that its execution will hop off the current actor. Explicit annotation also offers the ability to identify a mismatch of intention, such as a case where the developer expected `nonisolated` but inference landed on actor-isolated, and the closure is used in an isolated context. With explicit annotation, the developer would receive a diagnostic about a `nonisolated` closure being used in an actor-isolated context which helpfully identifies this mismatch of intention.

## Proposed solution

Enable explicit specification of non-isolation by allowing `nonisolated` to be a specifier on a closure:

```swift
Task { nonisolated in
  print("nonisolated")
}
```

Enable explicit specification of actor-isolation via an isolated parameter in a closure's capture list by using the `isolated` specifier:

```swift
actor A {
  func isolate() {
    Task { [isolated self] in
      print("isolated to 'self'")
    }
  }
}
```

Providing a formal replacement of the experimental parameter attribute `@_inheritActorContext` is needed to resolve another area of ambiguity with closure isolation. Its replacement `@inheritsIsolation` changes the behavior so that it unconditionally and implicitly captures the isolation context (as opposed to currently in actor-isolated contexts it being conditional on whether you capture an isolated parameter or isolated capture or actor-isolated function, but guaranteed if the context is isolated to a global actor or `nonisolated`).

```swift
class Old {
  public init(@_inheritActorContext operation: () async)
}

class New {
  public init(@inheritsIsolation operation: () async)
}

class C {
  var value = 0

  @MainActor
  func staticIsolation() {
    Old {
      value = 1 // closure is MainActor-isolated and therefore okay to access self
    }
    New {
      value = 2 // closure is MainActor-isolated and therefore okay to access self
    }
  }

  func dynamicIsolation(_ actor: isolated any Actor) {
    Old {
      // not isolated to actor without explicit capture
    }
    New {
      // isolated to actor through guaranteed implicit capture
    }
  }
}
```

## Detailed design

An isolated parameter in a capture list must be of actor type, or conform to or imply an actor, potentially optional, and there can only be one isolated parameter captured, following the same rules described in [SE-0313](0313-actor-isolation-control.md#actor-isolated-parameters) for actor-isolated parameters.

Opting out of `@inheritsIsolation` can be achieved by explicitly annotating the closure argument as `nonisolated`.

`@_inheritActorContext` is currently used by the `Task` initializer in the standard library which should be updated to use `@inheritsIsolation` instead.

## Source compatibility

The language changes are additive and therefore have no implications on source compatibility. The change to `Task.init` in the standard library does have the potential to isolate some closures that previously were inferred to be `nonisolated`. Prior behavior in those cases could be restored, if desired, by explicitly declaring the closure as `nonisolated`.

## ABI compatibility

The language change does not add or affect ABI since formal isolation is already part of a closure's type regardless of whether it is explicitly specified. The `Task.init` cahnge does not impact ABI since the function is annotated with `@_alwaysEmitIntoClient` and therefore has no ABI.

## Implications on adoption

none

## Alternatives considered

TODO

## Future directions

TODO
