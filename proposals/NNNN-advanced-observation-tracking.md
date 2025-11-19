# Advanced Observation Tracking

* Proposal: [SE-NNNN](NNNN-advanced-observation-tracking.md)
* Authors: [Philippe Hausler](https://github.com/phausler)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

Observation has one primary public entry point for observing the changes to `@Observable` types. This proposal adds two new versions that allow more fine-grained control and advanced behaviors.

## Motivation

Asynchronous observation serves a majority of use cases. However, when interfacing with synchronous systems, there are two major behaviors that the current `Observations` and `withObservationTracking` do not service.

The existing `withObservationTracking` API can only inform observers of events that will occur and may coalesce events that arrive in quick succession. Yet, some typical use cases require immediate and non-coalesced events, such as when two data models need to be synchronized together after a value has been set. The existing sychronization may also need to know when models are no longer available due to deinitialization.

Additionally, some use cases do not have a modern replacement for continuous events without an asynchronous context. This often occurs in more-established, existing UI systems. 

## Proposed solution

Two new mechanisms will be added: 1) an addendum to the existing `withObservationTracking` that accepts options to control when/which changes are observed, and 2) a continuous variant that re-observes automatically after coalesced events.

## Detailed design

Some of these behaviors have been existing and under evaluation by SwiftUI itself, and the API shapes exposed here apply lessons learned from that usage.

The two major, top-level interfaces added are a new `withObservationTracking` method that takes an `options` parameter and a `withContinuousObservation` that provides a callback with behavior similar to the `Observations` API. 

```swift
public func withObservationTracking<Result: ~Copyable, Failure: Error>(
  options: ObservationTracking.Options,
  _ apply: () throws(Failure) -> Result,
  onChange: @escaping @Sendable (borrowing ObservationTracking.Event) -> Void
) throws(Failure) -> Result

public func withContinuousObservation(
  options: ObservationTracking.Options,
  @_inheritActorContext apply: @isolated(any) @Sendable @escaping (borrowing ObservationTracking.Event) -> Void
) -> ObservationTracking.Token
```

The new types are nested in a `ObservationTracking` namespace which prevents potential name conflicts. This is an existing structure used for the internal mecahnisms for observation tracking today; it will be (as a type and no existing methods) promoted from SPI to API.

```swift
public struct ObservationTracking { }
```

The options parameter to the two new functions have 3 non-exclusive variations that specify which kinds of events the observer is interested in. These control when events are passed to the event closure and support the `.willSet`, `.didSet`, or `.deinit` side of events.

If an observation is setup such that it tracks all three, then a mutation of a property will fire two events (a `.willSet` and a `.didSet`) per setting of the property and one event when the observable type that is tracked is deinitialized. 

```swift
extension ObservationTracking {
  public struct Options {
    public init()

    public static var willSet: Options { get }
    public static var didSet: Options { get }
    public static var `deinit`: Options { get }
  }
}

extension ObservationTracking.Options: SetAlgebra { }
extension ObservationTracking.Options: Sendable { }
```

Note: `ObservationTracking.Options` is a near miss of `OptionSet`; since its internals are a private detail, `SetAlgebra` was chosen instead. Altering this would potentially expose implementation details that may not be ABI stable or sustainable for API design.

When an observation closure is invoked there are four potential events that can occur: a `.willSet` or `.didSet` when a property is changed, an `.initial` when the continuous events are setup, or a `.deinit` when an `@Observable` type is deallocated.

Beyond the kind of event, the event can also be matched to a given known key path. This allows for detecting which property changed without violating the access control of types.

Lastly, the `Event` type has an option to cancel the observation, which prevents any further events from being fired. For example, an event triggered on the `.willSet` can cancel the event, and there will not be a subsequent event for the corresponding `.didSet` (provided those are registered as options).

```swift
extension ObservationTracking {
  public struct Event: ~Copyable {
    public struct Kind: Equatable, Sendable {
      public static var initial: Kind { get }
      public static var willSet: Kind { get }
      public static var didSet: Kind { get }
      public static var `deinit`: Kind { get }
    }

    public var kind: Kind { get }

    public func matches(_ keyPath: PartialKeyPath<some Observable>) -> Bool
    public func cancel()
  }
}
```

The event matching function can be used to determine which property was responsible for the event. The following sample tracks both the properties `foo` and `bar`, when `bar` is then changed the onChange event will match that specific keypath. 

```swift
withObservationTracking(options: [.willSet]) {
  print(myObject.foo + myObject.bar)
} onChange: { event in
  if event.matches(\MyObject.foo) {
    print("got a change of foo")
  }
  if event.matches(\MyObject.bar) {
    print("got a change of bar")
  }
}

myObject.bar += 1
```

The sample above is expected to print out that it "got a change of bar" once since it only was registered with the options of willSet. The matching of events happen for either willSet or didSet events, but will not match any cases of deinit events.

The deinit event happens when an object being observed is deinitialized. The following example will trigger a deinit.

```swift

var myObject: MyObject? = MyObject()

withObservationTracking(options: [.deinit]) {
  if let myObject {
    print(myObject.foo + myObject.bar)
  }
} onChange: { event in
  print("got a deinit event")
}

myObject = nil
```

The other form of observation is the continuous version. It is something that can happen for more than one property modification. To that end, an external token needs to be held to ensure that observation continues. Either no longer holding that token or explicitly consuming it via the `cancel` method unregisters that observation and prevents any subsequent callbacks to the observation's closure.

```swift
extension ObservationTracking {
  public struct Token: ~Copyable {
    public consuming func cancel()
  }
}
```

## Behavior & Example Usage

```swift
_ = withObservationTracking(options: [.willSet, .didSet, .deinit]) {
  observable.property
} onChange: { event in
  switch event.kind {
  case .initial: print("initial event")
  case .willSet: print("property will set")
  case .didSet: print("property did set")
  case .deinit: print("an Observable instance deallocated")
  }
}

observable.property += 1 

```

At the invocation of the mutation of the property (the assignment part of the `+= 1`) the following is then printed:

```
property will set
property did set
```

Breaking that down a bit: at the `.willSet` event, the value of the property is not yet materialized/stored in the observable instance. Once the `.didSet` event occurs, that property is materialized into that container. 

Then, when the observable is deallocated, the following is printed:

```
an Observable instance deallocated
```

While any weak reference to the object will be `nil` when a `.deinit` event is received, the object may or may not have been deinitialized yet.

The continuous version works similarly except that it has one major behavioral difference: the closure will be invoked after the event at the next suspension point of the isolating calling context. That means that if `withContinuousObservation` is called in a `@MainActor` isolation, then the closure will always be called on the main actor.

```
@MainActor
final class Controller {
  var view: MyView
  var model: MyObservable
  let synchronization: ObservationTracking.Token

  init(view: MyView, model: MyObservable) {
    synchronization = withContinuousObservation(options: [.willSet]) { [view, model] event in
      view.label.text = model.someStringValue
    }
  }
}
```


## Source compatibility

Since the types are encapsulated in the `ObservationTracking` namespace they provide no interference with existing sources. 

The new methods are clear overloads given new types or entirely new names so there are no issues with source compatibility for either of them.

## ABI compatibility

The only note per ABI impact is the `ObservationTracking.Options`; the internal strucural type of the backing value is subject to change and must be maintained as `SetAlgebra` insted of `OptionSet`.

## Implications on adoption

The primary implications of adoption of this is reduction in code when it comes to the usages of existing systems.

## Future directions

None at this time.

## Alternatives considered

The `withContinuousObservation` could have a default parameter of `.willSet` to mimic the quasi default behavior of `withObservationTracking` - in that the existing non-options version of that function acts in the same manner as the new version passing `.willSet` and no other options (excluding the closure signature being different). Since the closure makes that signature only a near miss this default beahvior was dismissed and the users of the `withContiuousObservation` API then should pass the explicit options as needed.

## Acknowledgments

Special thanks to [Jonathan Flat](https://github.com/jrflat), [Guillaume Lessard](https://github.com/glessard) for editing/review contributions.
