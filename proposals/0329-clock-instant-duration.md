# Clock, Instant, and Duration

* Proposal: [SE-0329](0329-clock-instant-duration.md)
* Author: [Philippe Hausler](https://github.com/phausler)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Implemented (Swift 5.7)**
* Implementation: [apple/swift#40609](https://github.com/apple/swift/pull/40609)
* Review: ([first review](https://forums.swift.org/t/se-0329-clock-instant-date-and-duration/53309)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0329-clock-instant-date-and-duration/53635)) ([second review](https://forums.swift.org/t/se-0329-second-review-clock-instant-and-duration/54509)) ([third review](https://forums.swift.org/t/se-0329-third-review-clock-instant-and-duration/54727)) ([acceptance](https://forums.swift.org/t/accepted-se-0329-clock-instant-and-duration/55324))

<details>
<summary><b>Revision history</b></summary>

* **v1** Initial pre-pitch
* **v1.1** Refinement to clock, deadline and duration types
  * Expanded to include a Deadline type
  * Posed a Clock defined type protocol grouping instead of Duration based protocol grouping (Clock -> Deadline -> Duration rather than Duration + Clock)
* **v1.2**
  * Removed the DurationProtocol concept to aide ease of use and simplify implementations
  * Introduced WallClock.Duration as the lowered Date type
* **v1.3**
  * Rename Deadline to Instant since that makes a bit more sense generally (especially for Date)
  * Add the requirement of a referencePoint to ClockProtocol
* **v1.4**
  * Move the concept of `now` to the protocol requirement for clocks as an instance method
  * Move the `duration(from:to:)` to an instance method on `InstantProtocol`
  * Add a number of really useful operators
  * Concrete clock types now have `.now` on their `Instant` types
  * Added an example ManualClock
* **v1.4.1**
  * Clarify the concrete clock types to show their conformances
* **v1.4.2**
  * Move the measurement function to clock itself to prevent conflicts with existing APIs
* **v1.4.3**
  * Re-added hours and minutes construction
  * added a base requirement for `ClockProtocol` to require a `minimumResolution`
* **v1.4.4**
  * Rename `ClockProtocol` to `Clock` to better adhere to naming guidelines
  * Adjusted measurement to have both a required method (plus default implementation) as well as a free floating function for standardized measurement.
* **v2.0**
  * Remove `Date` lowering
  * Remove `WallClock`
  * Add tolerances
  * Remove `.hours` and `.minutes`
  * Proposal reorganization
  * Added `DurationProtocol` and per instant interval association
  * Rename Monotonic and Uptime clocks to Continuous and Suspending to avoid platform ambiguity and perhaps add more clarity of uses.
* **v2.1**
  * Refined `DurationProtocol` to only use `Int` instead of `BinaryInteger` for arithmetic.
  * Added some additional alternatives considered for `DurationProtocol` and naming associated with it.
  * Renamed the associated type on `InstantProtocol` to be `Duration`.
  * Added back in task based sleep methods. Added a shorthand for sleeping tasks given a Duration.
* **v3.0**
  * Moved `measure` into a category from a protocol requirement
  * Renamed the `nanoseconds` and `seconds` property of `Duration` to `nanosecondsPortion` and `secondsPortion` to indicate their fractional composition to types like `timespec`
* **v3.1**
  * Adjust the portion accessors to one singular `components` based accessor and add an initializer for raw value construction from components.
* **v3.2**
  * Add `Duration` as an associated type requirement of `Clock`, so that it can be marked as the primary associated type.

</details>

## Introduction

The concepts of time can be broken down into three distinct parts:

1. An item to provide a concept of now plus a way to wake up after a given point in time
2. A concept of a point in time
3. A concept of a measurement of elapsed time.

These three items are respectively a **clock**, an **instant** and a **duration**. The measurement of time can be used for many types of APIs, all the way from the high levels of a concept of a timeout on a network connection, to the amount of time to sleep a task. Currently, the APIs that take measurement of time types take `NSTimeInterval` (aka `TimeInterval`), `DispatchTimeInterval`, and even types like `timespec`.

## Motivation

To define a standard way of interacting with time, we need to ensure that in the cases where it is important to limit clock measurement to a specific concept, that ability is preserved. For example, if an API can only accept realtime deadlines as instants, that API cannot be passed to a monotonic instant. This specificity needs to be balanced with the ergonomics of being able to use high-level APIs with little encumbrance of needing to know exactly the time type that is needed; in UI, it might not be welcoming to new developers learning Swift to force them to understand the differential between the myriad of clock concepts available for the operating system. Likewise, any implementation must be robust and performant enough to support multiple operating system back ends (Linux, Darwin, Windows, etc.), but also be easy enough to get right for the common use cases. Practically speaking, durations should be a progressive disclosure to instants and clocks.

From a performance standpoint, a distinct requirement is that any duration type (or clock type) must be reasonably performant enough to do tasks like measuring the execution performance of a function, without incurring a large overhead to the execution of the measurement. This means that any type that is expressing a duration should be small, and likely backed by some sort of (or group of) PoD type(s).

Time itself is always measured in a manner that is in reference to a certain frame of analysis. For example, uptime is measured in relative perspective to how long the machine has been booted, whereas other clocks may be relative to a specific epoch. Any instants expressed in terms of a specific reference point may be converted in potentially a lossy manner whereas others may not be convertible at all; so these conversions cannot be uniformly expressed as a general protocol requirement.

The primary motivation for clocks is to offer a way to schedule work to be done at a later time. Instants are intended to serve a temporal reference point for that scheduling. Durations are specifically designed to be a high precision integral time representing an elapsed duration between two points in time.

As it stands today, there are a number of APIs and types to represent clocks, instants, and durations. Foundation, for example, defines instant as `Date`, which is constructed from a UTC reference point using an epoch of Jan 1 2001, and `TimeInterval` which is defined as a `Double` representing the number of seconds between two points in time. Dispatch defines `DispatchTime`, `DispatchWallTime`, and `DispatchTimeInterval`; these, respectively, work in relation to a reference of uptime, a wall clock time, and a value of seconds/milliseconds/microseconds/nanoseconds. These obviously are not the only definitions, but when dealing with concurrency, a uniform accessor to all of these concepts is helpful to build the primitives needed for sleep and other temporal concepts.

## Prior Art

This proposal focuses on time as used for scheduling work in a process. The most useful clocks for this purpose are simple and local ones that calculate the time since the machine running the process was started. Time can also be expressed in human terms by using calendars, like "April 1, 2021" in the Gregorian calendar. To align with the different responsibilities of the standard library and Foundation, we aim to leave the definition of calendars and the math related to moving between dates in a calendar to Foundation's `Calendar`, `DateComponents`, `TimeZone` and `Date` types.

For brevity three other languages were chosen to represent an analysis of how time is handled for other languages; Go, Rust, Kotlin. These by no means are the only examples in other languages. Python and C++ also have notable implementations that share some similarities with the proposed implementation.

### Go
https://pkg.go.dev/time
https://golang.org/src/time/time.go

Go stores time as a structure of a wall clock reference point (uint64), an 'ext' additional nanoseconds field (int64), and a location (pointer).
Go stores duration as an alias to int64 (nanoseconds).

There is no control over the reference points in Go to specify a given clock; either monotonic or wall clock. The base implementation attempts to encapsulate both monotonic and wall clock values together in Go. For common use case this likely has little to no impact, however it lacks the specificity needed to identify a progressive disclosure of use.

### Rust
https://doc.rust-lang.org/stable/std/time/struct.Duration.html

Rust stores duration as a u64 seconds and a u32 nanoseconds.
The measurement of time in Rust uses Instant, which seems to use a monotonic clock for most platforms.

### Kotlin
https://kotlinlang.org/api/latest/jvm/stdlib/kotlin.time/-duration/

Kotlin stores Duration as a Long plus a unit discriminator comprised of either milliseconds or nanoseconds. Kotlin's measurement functions do not return duration (yet?) but instead rely on conversion functions from Long values in milliseconds etc and those currently measurement functions use system uptime to determine reference points.

## Detailed Design

Swift can take this to another level of both accuracy of intent and ease of use beyond any of the other examples given. Following in the themes of other Swift APIs, we can embrace the concept of progressive disclosure and leverage the existing frameworks that define time concepts.

The given requirements are that we must have a way of expressing the frame of reference of time. This needs to be able to express a concept of now, and a concept of waking up after a given instant has passed. Instants must be able to be compared among each other but are specific to the clock they were obtained. Instants also must be able to be advanced by a given duration or a distance between two instants must be able to emit a duration. Durations must be comparable and also must have some intrinsic unit of time that can suffice for broad application.

### Clock

The base protocol for defining a clock requires two primitives; a way to wake up after a given instant, and a way to produce a concept of now. Clocks can also be defined in terms of a potential resolution of access; some clocks may offer resolution at the nanosecond scale, other clocks may offer only microsecond scale. Any values of elapsed time may be considered to be 0 if they are below the minimum resolution.

```swift
public protocol Clock: Sendable {
  associatedtype Duration: DurationProtocol
  associatedtype Instant: InstantProtocol where Instant.Duration == Duration
  
  var now: Instant { get }
  
  func sleep(until deadline: Instant, tolerance: Instant.Duration?) async throws 

  var minResolution: Instant.Duration { get }
}

extension Clock {
  func measure(_ work: () async throws -> Void) reasync rethrows -> Instant.Duration
}
```

This means that given an instant, it is intrinsically linked to the clock; e.g., a specific clock's instant is not meaningfully comparable to all other clock instants. However, as an ease of use concession, the duration between two instants can be compared. However, doing this across clocks is potentially considered a programmer error, unless handled very carefully. By making the protocol hierarchy just clocks and instants, it means that we can easily express a compact form of a duration that is usable in all cases; particularly for APIs that might adopt Duration as a replacement to an existing type.

The clock minimum resolution will have a default implementation that returns `.nanosecond(1)`. This property serves to inform users of a clock the potential minimum granularity of what to invocations to now may return but also indicate the minimum variance between two instants that are significant. Practically speaking, this becomes relevant when measuring work - execution of a small work load may be executed in under the minimum resolution and not provide accurate information. 

Clocks can then be used to measure a given amount of work. This means that clock should have the extensions to allow for the affordance of measuring workloads for metrics, but also measure them for performance benchmarks. This means that making benchmarks is quite easy to do:

```swift
let elapsed = someClock.measure {
  someWorkToBenchmark()
}
```

The primary use for a clock beyond vending `now` is to wake up after a given deadline. This affords the possibility to schedule work to be done after that given instant. Wake-ups for scheduled work can incur power implications. Specifically waking up the CPU too often can cause undue power drain. By indicating a tolerance to the deadline it allows the underlying scheduling mechanisms from the kernel to potentially offer a slightly adjusted deadline to wake up by which means that work along with other work being scheduled can be grouped together for more power efficient execution. Not specifying a tolerance infers to the implementor of the clock that the tolerance is up to the implementation details of that clock to choose an appropriate value. The tolerance is a maximum duration after deadline by which the system may delay sleep by.

```
func delayedHello() async throws {
  try await someClock.sleep(until: .now.advanced(by: .seconds(3))
  print("hello delayed world")
}
```

In the above example a clock is slept until 3 seconds from the instant it was called and then prints. The sleep function should throw if the task was cancelled while the sleep function is suspended. In this example the tolerance value is defaulted to nil by the clock and left as a "dealers choice" of how much tolerance may be applied to the deadline. 

### Instant

As previously stated, instants need to be compared, and might be stored as a key, but only need to define a concept of now, and a way to advance them given a duration. By utilizing a protocol to define an instant, it provides a mechanism in which to use the right storage for the type, but also be type safe with regards to the clock they are intended for. 

The primary reasoning that instants are useful is that they can be composed. Given a function with a deadline as an instant, if it calls another function that takes a deadline as an instant, the original can just be passed without mutation to the next function. That means that the instant in which that deadline elapses does not have interference with the pre-existing calls or execution time in-between functions. One common example of this is the timeout associated with url requests; a timeout does not fully encapsulate how the execution deadline occurs; there is a deadline to meet for the connection to be established, data to be sent, and a response to be received; a timeout spanning all of those must then have measurement to account for each step, whereas a deadline is static throughout.

```swift
public protocol InstantProtocol: Comparable, Hashable, Sendable {
  associatedtype Duration: DurationProtocol
  func advanced(by duration: Duration) -> Self
  func duration(to other: Self) -> Duration
}

extension InstantProtocol {
  public static func + (_ lhs: Self, _ rhs: Duration) -> Self
  public static func - (_ lhs: Self, _ rhs: Duration) -> Self
  
  public static func += (_ lhs: inout Self, _ rhs: Duration)
  public static func -= (_ lhs: inout Self, _ rhs: Duration)
  
  public static func - (_ lhs: Self, _ rhs: Self) -> Duration
}
```

`InstantProtocol`, in addition to the `advance(by:)` and `duration(to:)` methods, has operators to add and subtract durations. However, it does not adhere to `AdditiveArithmetic`. That protocol would require adding two instant values together  and defining a zero value (which comes from the clock, and cannot be statically know for all `InstantProtocol` types). Furthermore, InstantProtocol does not require `Strideable` because that requires the stride to be `SignedNumeric` which means that `Duration` would be required to be multiplied by another `Duration` which is inappropriate for two durations. 

If at such time that `Strideable` no longer requires `SignedNumeric` strides, or that `SignedNumeric` no longer requires the multiplication of self; this or adopting types should be considered for adjustment.

### DurationProtocol

Specific clocks may have concepts of durations that may express durations outside of temporal concepts. For example a clock tied to the GPU may express durations as a number of frames, whereas a manual clock may express them as steps. Most clocks however will express their duration type as a `Duration` represented by an integral measuring seconds/nanoseconds etc. We feel that it is not an incredibly common task to implement a clock and using the extended name of `Swift.Duration` is reasonable to expect and does not impact normal interactions with clocks. This duration has a few basic requirements; it must be comparable, and able to be added (similar to the concept previously stated with `InstantProtocol` they cannot be `Stridable` since it would mean that two `DurationProtocol` adopting types would then be allowed to be multiplied together).

```swift
public protocol DurationProtocol: Comparable, AdditiveArithmetic, Sendable {
  static func / (_ lhs: Self, _ rhs: Int) -> Self
  static func /= (_ lhs: inout Self, _ rhs: Int)
  static func * (_ lhs: Self, _ rhs: Int) -> Self
  static func *= (_ lhs: inout Self, _ rhs: Int)
  
  static func / (_ lhs: Self, _ rhs: Self) -> Double
}
```

In order to ensure efficient calculations for durations there must be a few additional methods beyond just additive arithmetic that types conforming to `DurationProtocol` must implement - these are the division and multiplication by binary integers and a division creating a double value.  This provides the most minimal set of functions to accomplish concepts like the scheduling of a timer, or back-off algorithms. This protocol definition is very close to a concept of `VectorSpace`; if at such time that a more refined protocol definition for a composition of `Comparable` and `AdditiveArithmetic` comes to be - this protocol should be considered as part of any potential improvement in that area.

The naming of `DurationProtocol` was chosen because we feel that the canonical definition of durations is a temporal duration. All clocks being proposed here have an interval type of `Swift.Duration`; but other more specialized clocks may offer duration types that provide their own custom durations.

### Duration

Meaningful durations can always be expressed in terms of nanoseconds plus a number of seconds, either a duration before a reference point or after. They can be constructed from meaningful human measured (or machine measured precision) but should not account for any calendrical calculations (e.g., a measure of days, months or years distinctly need a calendar to be meaningful). Durations should able to be serialized, compared, and stored as keys, but also should be able to be added and subtracted (and zero is meaningful). They are distinctly NOT `Numeric` due to the aforementioned issue with regards to multiplying two `TimeInterval` variables. That being said, there is utility for ad-hoc division and multiplication to calculate back-offs.

The `Duration` must be able to account for high scale resolution of calculation; the storage will under the hood ensure proper rounding for division (by likely storing higher precision than exposed) and enough range to span the full range of potential reasonable instants. This means that spanning the full range of +/- thousands of years at a non lossy scale can be accomplished by storing the seconds and nanoseconds. Not all systems will need that full range, however in order to properly represent nanosecond precision across the full range of times expressed in the operating systems that Swift works on a full 128 bit storage is needed to represent these values. That in turn necessitates exposing the conversion to existing types as breaking the duration into two components. These components of a duration are exposed for interoperability with existing APIs such as `timespec` as a seconds portion and an attoseconds portion (used to ensure full precision is not lost). If the Swift language gains a signed integer type that can support 128 bits of storage then `Duration` should be considered to replace the components accessor and initializer with a direct access and initialization to that stored attoseconds value.

```swift
public struct Duration: Sendable {
  public var components: (seconds: Int64, attoseconds: Int64) { get }
  public init(secondsComponent: Int64, attosecondsComponent: Int64)
}


extension Duration {
  public static func seconds<T: BinaryInteger>(_ seconds: T) -> Duration
  public static func seconds(_ seconds: Double) -> Duration
  public static func milliseconds<T: BinaryInteger>(_ milliseconds: T) -> Duration
  public static func milliseconds(_ milliseconds: Double) -> Duration
  public static func microseconds<T: BinaryInteger>(_ microseconds: T) -> Duration
  public static func microseconds(_ microseconds: Double) -> Duration
  public static func nanoseconds<T: BinaryInteger>(_ value: T) -> Duration
}

extension Duration: Codable { }
extension Duration: Hashable { }
extension Duration: Equatable { }
extension Duration: Comparable { }
extension Duration: AdditiveArithmetic { }

extension Duration {
  public static func / (_ lhs: Duration, _ rhs: Double) -> Duration
  public static func /= (_ lhs: inout Duration, _ rhs: Double)
  public static func / (_ lhs: Duration, _ rhs: Int) -> Duration
  public static func /= (_ lhs: inout Duration, _ rhs: Int)
  public static func / (_ lhs: Duration, _ rhs: Duration) -> Double
  public static func * (_ lhs: Duration, _ rhs: Double) -> Duration
  public static func *= (_ lhs: inout Duration, _ rhs: Double)
  public static func * (_ lhs: Duration, _ rhs: Int) -> Duration
  public static func *= (_ lhs: inout Duration, _ rhs: Int)
}

extension Duration: DurationProtocol { }
```

### ContinuousClock

When instants are for local processing only and need to be high resolution without the encumbrance of suspension while the machine is asleep, `ContinuousClock` is the tool for the job. On Darwin platforms this refers to time derived from the monotonic clock, for linux platforms this is in reference to the uptime clock; being that those two are the closest in behavioral meaning. This clock also offers an extension to access the clock instance as the inferred base type property.

```swift
public struct ContinuousClock {
  public init()
  
  public static var now: Instant { get }
}

extension ContinuousClock: Clock {
  public struct Instant {
    public static var now: ContinuousClock.Instant { get }
  }

  public var now: Instant { get }
  public var minimumResolution: Duration { get }
  public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws
}

extension ContinuousClock.Instant: InstantProtocol {
  public func advanced(by duration: Duration) -> ContinuousClock.Instant
  public func duration(to other: ContinuousClock.Instant) -> Duration
}

extension Clock where Self == ContinuousClock {
  public static var continuous: ContinuousClock { get }
}
```

### SuspendingClock

Where local process scoped or cross machine scoped instants are not suitable: uptime serves the purpose of a clock that does not increment while the machine is asleep but is a time that is referenced to the boot time of the machine. This allows for the affordance of cross process communication in the scope of that machine. Similar to the other clocks there is an extension to access the clock instance as the inferred base type property. For Darwin based platforms this is derived from the uptime clock whereas for linux based platforms this is derived from the monotonic clock since those most closely represent the concept for not incrementing while the machine is asleep.

```swift
public struct SuspendingClock {
  public init()
  
  public static var now: Instant { get }
}

extension SuspendingClock: Clock {
  public struct Instant {
    public static var now: SuspendingClock.Instant { get }
  }

  public var minimumResolution: Duration { get }
  public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws
}

extension SuspendingClock.Instant: InstantProtocol {
  public func advanced(by duration: Duration) -> SuspendingClock.Instant
  public func duration(to other: SuspendingClock.Instant) -> Duration
}

extension Clock where Self == SuspendingClock {
  public static var suspending: SuspendingClock { get }
}
```

### Clocks Outside of the Standard Library

In previous iterations of this proposal we offered a concept of a WallClock, however, after some compelling feedback we feel that this type may not be the most generally useful without the context of calendrical calculations. Since Foundation is the home of these types of calculations we feel that a clock based upon UTC more suitably belongs in that layer. This clock will adjust the fire time based upon the current UTC time; this means that that if a bit of work is scheduled by a specific time of day made by calculation via `Calendar` this clock can wake up from the sleep when the system time hits that deadline.

Foundation will provide a type `UTCClock` that encompasses this behavior and use `Date` as the instant type. Additionally Foundation will provide conversions to and from `Date` to the other instant types in this proposal. 

```swift
public struct UTCClock {
  public init()
  
  public static var now: Date { get }
}

extension UTCClock: Clock {
  public var minimumResolution: Duration { get }
  public func sleep(until deadline: Date, tolerance: Duration? = nil) async throws
}

extension Date {
  public func leapSeconds(to other: Date) -> Duration
  public init(_ instant: ContinuousClock.Instant)
  public init(_ instant: SuspendingClock.Instant)
}

extension ContinuousClock.Instant {
  public init?(_ instant: Date)
}

extension SuspendingClock.Instant {
  public init?(_ instant: Date)
}

extension Date: InstantProtocol {
  public func advanced(by duration: Duration) -> Date
  public func duration(to other: Date) -> Duration
}

extension Clock where Self == UTCClock {
  public static var utc: UTCClock { get }
}
```

The `UTCClock` will allow for a method in which to wake up after a deadline defined by a `Date`. The implementation of `Date` transacts upon the number of seconds since Jan 1 2001 as defined by the system clock so any network time (or manual) updates may shift that point of now either forward or backward depending on the skew the system clock may undergo. The value being stored is not dependent upon timezone, daylight savings, or calendrical representation but the current NTP updates do represent any applied leap seconds that may have occurred. In light of this particular edge case that previously was not exposed, `Date` will now offer a new method to determine the leap second duration that may have elapsed between a given data and another date. This provides a method in which to account for these leap seconds in a historical sense. Similar to timezone databases the leap seconds will be updated (if there is any additional planned leap seconds) along with software updates. 

Previous revisions of this proposal moved `Date` to the standard library along with a new wall clock that uses it. After feedback from the community, we now believe the utility of this clock is very specialized and more closely related to the calendar types in Foundation. Therefore, `Date` will remain in Foundation alongside them.

`Date` is best used as the storage for point in time to be interpreted using a `Calendar`, `TimeZone`, and with formatting functions for display to people. A survey of the existing `Date` API in the macOS and iOS SDKs shows this to already be the case for the vast majority of properties and functions that use it. The discussion around the appropriateness of the `Date` name was mostly focused on its uses in *non*-calendrical contexts. We hope this combination of `Date` and `UTCClock` will help reinforce the relationship between those types and add clarity to when it should be used.

This approach preserves compatibility with those APIs while still providing the capability to use `Date` for scheduling in the rare cases that it is needed.

### Task

The existing `Task` API has methods in which to sleep. These existing methods do not have any specified behavior of sleeping; however under the hood it uses a continuous clock on Darwin and a suspending clock on Linux. 

The existing API for sleeping will be deprecated, and the existing deprecation will be updated accordingly to point to the new APIs.

```swift
extension Task {
  @available(*, deprecated, renamed: "Task.sleep(for:)")
  public static func sleep(_ duration: UInt64) async
  
  @available(*, deprecated, renamed: "Task.sleep(for:)")
  public static func sleep(nanoseconds duration: UInt64) async throws
  
  public static func sleep(for: Duration) async throws
  
  public static func sleep<C: Clock>(until deadline: C.Instant, tolerance: C.Instant.Duration? = nil, clock: C) async throws
}
```

### Example Custom Clock

One example for adopting `Clock` is a manual clock. This could be a useful item for testing (but not currently part of this proposal as an API to add). It allows for the manual advancement of time in a deterministic manner. The general intent is to allow the manual clock type to be advanced from one thread and the sleep function can then be used to act as if it was a standard clock in generic APIs.

```swift
public final class ManualClock: Clock, @unchecked Sendable {
  public struct Instant: InstantProtocol {
    var offset: Duration = .zero
    
    public func advanced(by duration: Duration) -> ManualClock.Instant {
      Instant(offset: offset + duration)
    }
    
    public func duration(to other: ManualClock.Instant) -> Duration {
      other.offset - offset
    }
    
    public static func < (_ lhs: ManualClock.Instant, _ rhs: ManualClock.Instant) -> Bool {
      lhs.offset < rhs.offset
    }
  }
  
  struct WakeUp {
    var when: Instant
    var continuation: UnsafeContinuation<Void, Never>
  }
  
  public private(set) var now = Instant()
  
  // General storage for the sleep points we want to wake-up for
  // this could be optimized to be a more efficient data structure
  // as well as enforced for generation stability for ordering
  var wakeUps = [WakeUp]()
  
  // adjusting now or the wake-ups can be done from different threads/tasks
  // so they need to be treated as critical mutations
  let lock = os_unfair_lock_t.allocate(capacity: 1)
  
  deinit {
    lock.deallocate()
  }
  
  public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
    // Enqueue a pending wake-up into the list such that when
    return await withUnsafeContinuation {
      if deadline <= now {
        $0.resume()
      } else {
        os_unfair_lock_lock(lock)
        wakeUps.append(WakeUp(when: deadline, continuation: $0))
        os_unfair_lock_unlock(lock)
      }
    }
  }
  
  public func advance(by amount: Duration) {
    // step the now forward and gather all of the pending
    // wake-ups that are in need of execution
    os_unfair_lock_lock(lock)
    now += amount
    var toService = [WakeUp]()
    for index in (0..<(wakeUps.count)).reversed() {
      let wakeUp = wakeUps[index]
      if wakeUp.when <= now {
        toService.insert(wakeUp, at: 0)
        wakeUps.remove(at: index)
      }
    }
    os_unfair_lock_unlock(lock)
    
    // make sure to service them outside of the lock
    toService.sort { lhs, rhs -> Bool in
      lhs.when < rhs.when
    }
    for item in toService {
      item.continuation.resume()
    }
  }
}
```

## Existing Application Code

This proposal is purely additive and has no direct impact to existing application code.

## Impact on ABI

The proposed implementation will introduce three runtime functions; a way of obtaining time, a way of sleeping given a standard clock, and a way of obtaining the minimum resolution given a standard clock. 

## Alternatives Considered

### Singular Instant Representation

It was considered to have a singular type to represent monotonic, uptime, and wall clock instants similar to Go. However this approach causes a problem with comparability; an instant may be greater in one respect but less or equal in some other respect. In order to properly adhere to `Comparable` as a requisite to `InstantProtocol` we feel that combining the instants into one unified type is not ideal.

### Inverted Protocol Hierarchy

Another exploration was to have an inverted scheme of instant and clock however this means that the generic signatures of functions that use specific clocks or instants become much more difficult to write.

### Lowering of Date/UTCClock

Originally the proposal included a concept of lowering `Date` to the standard library in addition to altering its storage from `Double` to a `Duration`. There were strong objections on a few fronts with this move which ultimately had convincing merit. The primary objection was to the name `Date`; given that there was no additional contextual API within the standard library or concurrency library this meant that `Date` could easily get confused with the concept of a calendrical date (which that type definitively is not). Additionally it was rightfully brought up that `Date` is missing concepts of leap seconds (which has since been accepted and proposed as an alteration to Foundation) because we see the utility of that as an additional functionality to `Date`. 

Also in the original revisions of the proposal we had a concept of `WallClock`. After much discussion we feel that the name wall clock is misleading since the type really represents a clock based on UTC (once `Date` has a historical accounting of leap seconds). But furthermore, we feel that the general utility of scheduling via a UTC clock is not a common task and that a vast majority of clocks for scheduling are really things that transact either via a clock that time passes while the machine is asleep or a clock that time does not pass while the machine is asleep. That accounting means that we feel that the right home for `UTCClock` is in a higher level framework for that specialized task along side the calendrical calculation APIs; which is Foundation.

### DurationProtocol Generalized Arithmetics and Protocol Definition

It was considered to have a more general form of the arithmetics for `DurationProtocol`. This poses a potential pitfall for adopters that may inadvertently implement some truncation of values. Since most values passed around that are integral types are spelled as `Int` it means that this interface is better served as just using multiplication and division via `Int`. In that vein; it was also considered to use `Double` instead, this however does not work nicely for types that define durations like "steps" or "frames"; e.g. things that are not distinctly divisible beyond 1 unit. It is still under the domain of that `DurationProtocol` adopting type to define that behavior and how it rounds or asserts etc.

Similarly to the arithmetics; it was also considered to have the associated type to `InstantProtocol` as just a glob of protocols `Comparable & AdditiveArithmetic & Sendable`, however this lacks the capability of fast-paths for things like back-offs (ala Zeno's algorithm) or debounce, or timer coalescing. Some of them could be re-written in terms of loops of addition, however it would likely result in hot-looping over missed intervals in some cases, or in others not even being able to implement them (e.g. division for back-offs).

### Clock and Task Sleep Tolerance Optionality

It was raised that the hint from IDEs such as Xcode for the `.none` autocomplete do exist and those nomenclatures are perhaps misleading for the `tolerance` parameter to the sleep functions. We agree that this is perhaps a less than ideal name to expose as an autocomplete, however it was decided that code using `.none` instead of not passing a parameter or passing `nil` is stylistically problematic and left-overs from earlier versions of swift. It was concluded that the solutions in this space should be applicable to any other method that has an optional parameter and not just `Clock` and `Task`; moreover it seems like this is perhaps a bug in Xcode's autocomplete than an issue with the API as proposed since the `ContinuousClock`, `SuspendingClock` and `UTCClock` being proposed are most meaningful of the lack of a parameter value than to introduce any sort of enumeration mirroring `Optional` without any sort of direct type passing capability. In short - a more general solution should be approached with this problem and the optional duration type should remain.

### Alternative Names

There have been a number of names that have been considered during this proposal (these are a few highlights):

The protocol `Clock` has been considered to be named:
* `ClockProtocol` - The protocol suffix was considered superfluous and a violation of the naming guidelines.

The protocol `InstantProtocol` has been considered to be named:
* `ReferencePoint` - This ended up being too vague and did not capture the concept of time
* `Deadline`/`DeadlineProtocol` - Not all instant types are actually deadlines, so the nomenclature became confusing.
* The associated type of `InstantProtocol.Duration` was considered for a few other names; `TimeSpan` and `Interval`. These names lack symmetry; `Clock` has an `Instant` which is an `InstantProtocol`, `InstantProtocol` has a `Duration` which is a `DurationProtocol`.

The protocol `DurationProtocol` has been considered to be named:
* Not having it has been considered but ultimately rejected to ensure flexibility of the API for other clock types that transact in concept like "frames" or "steps".

The clock `ContinuousClock` has been considered to be named:
* `MonotonicClock` - Unfortunately Darwin and Linux differ on the definition of monotonic. 
* `UniformClock` - This does not disambiguate the behavioral difference between this clock and the `SuspendingClock` since both are uniform in their incrementing while the machine is not asleep.

The clock `SuspendingClock` has been considered to be named:
* `UptimeClock` - Just as `MonotonicClock` has ambiguity with regards to Linux and Darwin behaviors.
* `AbsoluteClock` - Very vague when not immediately steeped in mach-isms.
* `ExecutionClock` - The name more infers the concept of `CLOCK_PROCESS_CPUTIME_ID` than `CLOCK_UPTIME_RAW` (on Darwin).
* `DiscontinuousClock` - Has its roots in the mathematical concept of discontinuous functions but perhaps is not immediately obvious that it is the clock that does not advance while the machine is asleep

The type `Duration` has been considered to be named:
* `Interval` - This is quite ambiguous and could refer to numerous other concepts other than time.
* The `nanosecondsPortion` and `secondsPortion` were considered to be named `nanoseconds` and `seconds` however those names posed ambiguity of rounding; naming them with the term portion infers their fractional composition rather than just a rounded/truncated value. 

The type `Date` has been considered to be named:
* `Timestamp` - A decent alternative but still comes at a slight ambiguity with regards to being tied to a calendar. Also has string like connotations (with how it is used in logs)
* `Timepoint`/`TimePoint` - A reasonable alternative with less ambiguity but ultimately not compelling enough to churn thousands of APIs that already exist (just counting the ones included in the iOS and macOS SDKs, not to mention the other use sites that may exist). 
* `WallClock.Instant`/`UTCClock.Instant` - This is a very wordy way of spelling the same idea as `Date` represents today.

The `Task.sleep(for:tolerance:clock:)` API has been considered to be named:
* `Task.sleep(_:tolerance:clock:)` - even though this is still grammatically correct and omits potentially a needless word of "for", having this extra word still reads well but also offers a better fix-it for migration from deprecated APIs. That migration was considered worth it to keep the "for".

## Appendix

Time is relative, temporal types doubly so. In this document, there will be some discussion with regards to the categorization of temporal types that readers should be distinctly aware of.

**Calendar:** A human locale based system in which to measure time.

**Clock:** The mechanism in which to measure time, and understand how that time flows.

**Continuous Time:** Time that always increments but does not stop incrementing while the system is asleep. This is useful to consider as a stopwatch style time; the reference point at which this starts and are most definitely different per machine.

**Date:** A Date value encapsulates a single point in time, independent of any particular calendrical system or time zone. Date values represent a time interval relative to an absolute reference date.

**Deadline:** In common parlance, it is a limit defined as an instant in time: a narrow field of time by which an objective must be accomplished.

**Duration:** A measurement of how much time has elapsed between two deadlines or reference points.

**Instant:** A precise moment in time.

**Monotonic Time:** Darwin and BSD define this as continuous time. Linux, however, defines this as a time that always increments, but does stop incrementing while the system is asleep.

**Network Update Time:** A value of wall clock time that is transmitted via ntp; used to synchronize the wall clocks of machines connected to a network.

**Temporal:** Related to the concept of time.

**Time Zone:** An arbitrary political defined system in which to normalize time in a quasi-geospatial delineation intended to keep the apex of the solar day around 12:00.

**Tolerance:** The duration around a given point in time is accepted as accurate.

**Uptime:** Darwin and BSD define this as absolute time suspending when asleep. Linux, however, defines this as time that does not suspend while asleep but is relative to the boot.

**Wall Clock Time:** Time like reading from a clock. This may be adjusted forwards or backwards for numerous reasons; in this context, it is time that is not specific to a time zone or locale, but measured from an absolute reference date. Network updates may adjust the drift on the clock either backwards or forwards depending on the relativistic drift, clock skew from inaccuracies with the processor, or from hardware power characteristics.
