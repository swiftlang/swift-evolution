# Add sleep(for:) to Clock

* Proposal: [SE-NNNN](NNNN-clock-sleep-for.md)
* Authors: [Brandon Williams](https://github.com/mbrandonw), [Stephen Celis](https://github.com/stephencelis)
* Review Manager: TBD
* Status: **Draft implementation**
* Implementation: [apple/swift#61222](https://github.com/apple/swift/pull/61222)


## Introduction

The `Clock` protocol introduced in Swift 5.7 provides a way to suspend until a future instant, but 
does not provide a way to sleep for a duration. This differs from the static `sleep` methods on
`Task`, which provide both a way to sleep until an instant or for a duration.

This imbalance in APIs might be reason enough to add a `sleep(for:)` method to all clocks, but the
real problem occurs when dealing with `Clock` existentials. Because the `Instant` associated type
is fully erased, and only the `Duration` is preserved via the primary associated type, any API
that deals with instants is inaccessible to an existential. This means one cannot invoke 
`sleep(until:)` on an existential clock, and hence you can't really do anything with an existential
clock.

Swift-evolution thread: https://forums.swift.org/t/pitch-clock-sleep-for/60376

## Motivation

Existentials provide a convenient way to inject dependencies into features so that you can use one
kind of dependency in production, and another kind in tests. The most prototypical version of this
is API clients. When you run your feature in production you want the API client to make real life
network requests, but when run in tests you may want it to just return some mock data.

Due to the current design of `Clock`, it is not possible to inject a clock existential into a 
feature so that you can use a `Continuous` clock in production, but some other kind of controllable
clock in tests.

For example, suppose you have an observable object for the logic of some feature that wants to show
a welcoming message after waiting 5 seconds. That might look like this:

```swift
class FeatureModel: ObservableObject {
  @Published var message: String?
  func onAppear() async {
    do {
      try await Task.sleep(until: .now.advanced(by: .seconds(5)))
      self.message = "Welcome!"
    } catch {}
  }
}
```

If you wrote a test for this, your test suite would have no choice but to wait for 5 real life
seconds to pass before it could make an assertion:

```swift
let model = FeatureModel()

XCTAssertEqual(model.message, nil)
await model.onAppear() // Waits for 5 seconds
XCTAssertEqual(model.message, "Welcome!")
```

This affects people who don't even write tests. If you put your feature into an Xcode preview, then
you would have to wait for 5 full seconds to pass before you get to see the welcome message. That
means you can't quickly iterate on the styling of that message.

The solution to these problems is to not reach out to the global, uncontrollable `Task.sleep`, and
instead inject a clock into the feature. And that is typically done using an existential, but
unfortunately that does not work:

```swift
class FeatureModel: ObservableObject {
  @Published var message: String?
  let clock: any Clock<Duration>

  func onAppear() async {
    do {
      try await self.clock.sleep(until: self.clock.now.advanced(by: .seconds(5))) // 🛑
      self.message = "Welcome!"
    } catch {}
  }
}
```

One cannot invoke `sleep(until:)` on a clock existential because the `Instant` has been fully 
erased, and so there is no way to access `.now` and advance it.

For similar reasons, one cannot invoke `Task.sleep(until:clock:)` with a clock existential:

```swift
try await Task.sleep(until: self.clock.now.advanced(by: .seconds(5)), clock: self.clock) // 🛑
```

What we need instead is the `sleep(for:)` method on clocks that allow you to sleep for a duration
rather than sleeping until an instant:

```swift
class FeatureModel: ObservableObject {
  @Published var message: String?
  let clock: any Clock<Duration>

  func onAppear() async {
    do {
      try await self.clock.sleep(for: .seconds(5)) // ✅
      self.message = "Welcome!"
    } catch {}
  }
}
```

Without a `sleep(for:)` method on clocks, one cannot use a clock existential in the feature, and
that forces you to introduce a generic:

```swift
class FeatureModel<C: Clock<Duration>>: ObservableObject {
  @Published var message: String?
  let clock: C

  func onAppear() async {
    do {
      try await self.clock.sleep(until: self.clock.now.advanced(by: .seconds(5)))
      self.message = "Welcome!"
    } catch {}
  }
}
```

But this is problematic. This will force any code that touches `FeatureModel` to also introduce a
generic if you want that code to be testable and controllable. And it's strange that the class
is statically announcing its dependence on a clock when its mostly just an internal detail of the
class.

By adding a `sleep(for:)` method to `Clock` we can fix all of these problems, and give Swift users
the ability to control time-based asynchrony in their applications.

## Proposed solution

A single extension method will be added to the `Clock` protocol:

```swift
extension Clock {
  /// Suspends for the given duration.
  ///
  /// Prefer to use the `sleep(until:tolerance:)` method on `Clock` if you have access to an 
  // absolute instant. 
  public func sleep(
    for duration: Duration,
    tolerance: Duration? = nil
  ) async throws {
    try await self.sleep(until: self.now.advanced(by: duration), tolerance: tolerance)
  }
}
```

<!-- We should make sure that we talk in the documentation about why this kind of method should only be used as a convenience API and why the primary API should traffic in absolute clock values. But with that said, I absolutely agree that it's pretty much always going to be useful to have this kind of convenience alongside that primary API, and so this proposal seems like a nice addition. -->

This will allow one to sleep for a duration with a clock rather than sleeping until an instant.

## Detailed design

## Source compatibility, effect on ABI stability, effect on API resilience

As this is an additive change, it should not have any compatibility, stability or resilience 
problems. The only potential problem would be if someone has already run into this shortcoming
and decided to define their own `sleep(for:)` method on clocks.

## Alternatives considered

We could leave things as is, and not add this method to the standard library, as it is possible for
people to define it themselves.
