# resignRemoteID for remote distributed actor references

* Proposal: [SE-0548](0548-resign-remote-id.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: [Doug Gregor](https://github.com/douggregor)
* Status: **Active review (September 3...17, 2026)**
* Implementation: [swiftlang/swift#91610](https://github.com/swiftlang/swift/pull/91610)
* Experimental Feature Flag: `DistributedActorResignRemoteID`
* Review: ([pitch](https://forums.swift.org/t/pitch-resignremoteid-for-remote-distributed-actor-references/89078))([review](https://forums.swift.org/t/se-0548-resignremoteid-for-remote-distributed-actor-references/89365))

## Summary of changes

Distributed actors have their identity managed by an associated `DistributedActorSystem`. Today, the system observes the lifecycle of *local* distributed actor instances through the `assignID(_:)` / `resignID(_:)` pair, and participates in the *creation* of remote references through `resolve(id:as:)`. There is no way to observe when a remote reference has been deinitialized.

We propose to add a single new protocol requirement, `resignRemoteID(_:)`, invoked when a remote distributed actor proxy is deinitialized. 

## Motivation

[SE-0344: Distributed Actor Runtime][se-0344] defines the following lifecycle callbacks on a `DistributedActorSystem`:

- `assignID(_:)`: called when a local distributed actor is being initialized, to obtain an identity for it.
- `actorReady(_:)`: called when a local distributed actor has completed initializing.
- `resignID(_:)`: called when a local distributed actor deinitializes (or initialization fails).
- `resolve(id:as:)`: called when user code invokes `SomeActor.resolve(id:using:)`; returning `nil` tells the runtime to allocate a *remote* reference for this `id`.

The remote-path lifecycle is asymmetric: `resolve(id:as:)` is invoked during creation of remote references, but there is no callback equivalent to `resignID` for those references.

This works for systems where remote references are stateless and do not hold resources, however it has proven to be a problem for systems which wish to keep e.g. connections alive for as long as there exists at least one remote actor reference that is using a specific connection. Optimally, the system would be notified whenever remote references are deallocated, and can then use the IDs to manage if the connection can be already torn down, or not yet.

## Proposed solution

We propose to resolve this by adding a new protocol requirement on `DistributedActorSystem`, that will be invoked when a remote distributed actor reference is deinitialized:

```swift
public protocol DistributedActorSystem {
  // ... existing requirements, including:
  func resignID(_ id: ActorID)

  /// Invoked when a remote distributed actor reference is deinitializing. 
  /// 
  /// The passed in ID, generally, would have been passed to `resolve(id:as:)` earlier
  /// and a remote distributed reference would have been created as a result of that resolve call.
  ///
  /// - SeeAlso: ``resignID(_:)`` which is invoked for local instances.
  func resignRemoteID(_ id: ActorID)
}

extension DistributedActorSystem {
  public func resignRemoteID(_ id: ActorID) {}
}
```

The Swift runtime is updated to invoke `resignRemoteID(_:)` when a remote distributed actor proxy's `deinit` runs. 

The existing `resignID(_:)` continues to be invoked only for *local* instances.

## Detailed design

On an implementation level, the only changes other than introducing the protocol requirement, are actually invoking it from remote distributed actor deinits:

```swift
deinit {
  // if <self is remote reference> {
  //   << actorSystem.resignRemoteID(self.id)  // NEW
  //   << deallocate memory for `id` and `actorSystem` only
  // } else if <self is local instance> {
  //   << run user-declared deinit body
  //   << actorSystem.resignID(self.id)
  //   << deallocate all stored properties
  // }
}
```

The user-declared `deinit` body continues to never run for remote references, and the existing `resignID` path also remains unchanged.

This results in the following lifecycle management:

|              | "Local instance" distributed actor | "Remote reference" distributed actor |
| ------------ | ---------------------------------- | ------------------------------------ |
| Registration | `assignID(_:)` during init         | `resolve(id:as:)` returning `nil`    |
| Ready        | `actorReady(_:)` after init        | N/A                                  |
| Deinit       | `resignID(_:)` at deinit           | `resignRemoteID(_:)` at deinit       |

Since resolve may be called multiple times with the same ID, it is possible that `resignRemoteID` be called multiple times with the same ID as well - once for each remote reference that was created using `resolve`.

The new `resignRemoteID(_:)` is _not_ invoked when the "corresponding" `resolve(id:as:)`:

- has thrown an error (no reference was created).
- returned a local actor (it is not a remote reference, local path applies).

## Source compatibility

Existing `DistributedActorSystem` implementations continue to compile and behave identically.

## ABI compatibility

`DistributedActorSystem` gains one new requirement with a default implementation which is source and ABI compatible for existing implementations.

The new SILGen-emitted call site in a distributed actor's deinit is back-deployment-compatible, and it is possible to deploy newly compiled code to an old runtime which does not have this requirement, the call would simply not be made then.

## Alternatives considered

### Just reuse `resignID` for remote references

The easiest fix would be to change the behavior of `resignID` to be invoked always, including from remote references.

This has two problems:

- The `resignID` method's documentation encouraged developers to *crash* when passed an ID they did not assign, as it would indicate some form of actor system misbehavior. In reality ignoring such values would be completely safe, so the guidance was too conservative, but there may be systems which do crash and would start crashing on a new Swift version if the behavior changed in a new release.
  - In practice this is a small risk, because actor systems we know of can easily be updated to tolerate the "unknown ID" case and continue working.
- It overloads the meaning of "resign" and doesn't pair well with the assign/resign. These methods no longer are a pair, and the resolve-remote path has no "pair" that will be invoked, making implementing the resign more difficult (necessary to track which path to take).



[se-0344]: 0344-distributed-actor-runtime.md
