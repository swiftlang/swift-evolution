# Add sleep(for:) to Clock

* Proposal: [SE-0374](0374-clock-sleep-for.md)
* Authors: [Brandon Williams](https://github.com/mbrandonw), [Stephen Celis](https://github.com/stephencelis)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Active Review (Oct 11 ... 25, 2022)**
* Implementation: [apple/swift#61222](https://github.com/apple/swift/pull/61222)
* Review: ([pitch](https://forums.swift.org/t/pitch-clock-sleep-for/60376)) ([review](https://forums.swift.org/t/se-0374-add-sleep-for-to-clock/60787))


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
feature so that you can use a `ContinuousClock` in production, but some other kind of controllable
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
  /// absolute instant.
  public func sleep(
    for duration: Duration,
    tolerance: Duration? = nil
  ) async throws {
    try await self.sleep(until: self.now.advanced(by: duration), tolerance: tolerance)
  }
}
```

This will allow one to sleep for a duration with a clock rather than sleeping until an instant.

Further, to make the APIs between `clock.sleep` and `Task.sleep` similar, we will also add a `tolerance` argument to `Task.sleep(for:)`:

```swift
/// Suspends the current task for the given duration on a continuous clock.
///
/// If the task is cancelled before the time ends, this function throws 
/// `CancellationError`.
///
/// This function doesn't block the underlying thread.
///
///       try await Task.sleep(for: .seconds(3))
///
/// - Parameter duration: The duration to wait.
public static func sleep(
  for duration: Duration,
  tolerance: C.Instant.Duration? = nil
) async throws {
  try await sleep(until: .now + duration, tolerance: tolerance, clock: .continuous)
}
```

## Detailed design

## Source compatibility, effect on ABI stability, effect on API resilience

As this is an additive change, it should not have any compatibility, stability or resilience 
problems.

## Alternatives considered

We could leave things as is, and not add this method to the standard library, as it is possible for
people to define it themselves.
