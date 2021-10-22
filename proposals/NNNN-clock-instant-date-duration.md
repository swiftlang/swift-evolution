# Clock, Instant, Date, and Duration

* Proposal: Swift-NNNN
* Author(s): Philippe Hausler <phausler@apple.com>
* Status: **Pitch**

## Revision history
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
  
## Introduction

The concepts of time can be broken down into three distinct parts:

1. An item to provide a concept of now plus a way to wake up after a given point in time
2. A concept of a point in time
3. A concept of a measurement in time.

These three items are respectively a **clock**, an **instant** and a **duration**. The measurement of time can be used for many types of APIs, all the way from the high levels of a concept of a timeout on a network connection, to the amount of time to sleep a task. Currently, the APIs that take measurement of time types take `NSTimeInterval` (aka `TimeInterval`), `DispatchTimeInterval`, and even types like `timespec`.

## Motivation

To define a standard way of interacting with time, we need to ensure that in the cases where it is important to limit clock measurement to a specific concept, that ability is preserved. For example, if an API can only accept realtime deadlines as instants, that API cannot be passed to a monotonic instant. This specificity needs to be balanced with the ergonomics of being able to use high-level APIs with little encumbrance of needing to know exactly the time type that is needed; in UI, it might not be welcoming to new developers learning Swift to force them to understand the differential between the myriad of clock concepts available for the operating system. Likewise, any implementation must be robust and performant enough to support multiple operating system back ends (Linux, Darwin, Windows, etc.), but also be easy enough to get right for the common use cases. Practically speaking, durations should be a progressive disclosure to instants and clocks.

From a performance standpoint, a distinct requirement is that any duration type (or clock type) must be reasonably performant enough to do tasks like measuring the execution performance of a function, without incurring a large overhead to the execution of the measurement. This means that any type that is expressing a duration should be small, and likely backed by some sort of (or group of) PoD type(s).

Time itself is always measured in a manner that is in reference to a certain frame of analysis. For example, uptime is measured in relative perspective to how long the machine has been booted, whereas wall clock measurements are sourced from a network transaction to update time as a reference to coordinated universal time (UTC). Any instants expressed in terms of boot time versus UTC wall clock time can only be converted in a potentially lossy manner. Wall clock times can always be safely transmitted from one machine to another since the frame of reference is shared, whereas boot time on the other hand is meaningless when transmitted from two machines, but quite meaningful when transmitted from process to process on the same machine.

As it stands today, there are a number of APIs and types to represent clocks, instants, and durations. Foundation, for example, defines instant as `Date`, which is constructed from a wall clock reference point, and `TimeInterval` which is defined as a `Double` representing the number of seconds between two points in time. Dispatch defines `DispatchTime`, `DispatchWallTime`, and `DispatchTimeInterval`; these, respectively, work in relation to a reference of uptime, a wall clock time, and a value of seconds/milliseconds/microseconds/nanoseconds. These obviously are not the only definitions, but when dealing with concurrency, a uniform accessor to all of these concepts is helpful to build the primitives needed for sleep and other temporal concepts.

## Definitions

Time is relative, temporal types doubly so. In this document, there will be some discussion with regards to the categorization of temporal types that readers should be distinctly aware of.

**Absolute Time:** Time that always increments, but suspends while the machine is asleep. The reference point at which this starts is relative to the boot time of the machine so no-two machines would be expected to have the same uptime values.

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

**Uptime:** Darwin and BSD define this as absolute time. Linux, however, defines this as time that does not suspend while asleep but is relative to the boot.

**Wall Clock Time:** Time like reading from a clock. This may be adjusted forwards or backwards for numerous reasons; in this context, it is time that is not specific to a time zone or locale, but measured from an absolute reference date. Network updates may adjust the drift on the clock either backwards or forwards depending on the relativistic drift, clock skew from inaccuracies with the processor, or from hardware power characteristics.

Since there are platform differences in the definition of monotonic time and uptime, for the rest of this proposal it will be in terms of the definition on Darwin and BSD that are referencing monotonic and uptime.

## Detailed Design

### Prior Art

There are a number of cases where these types end up being conflated with calendrical math. It is reasonable to say that the requirements for calendrical math have a distinct requirement of understanding of locales and time zones, and are clearly out of scope of any duration or clock types that might be introduced. That is distinct responsibilities of `Calendar` and `DateComponents`.

#### Go
https://pkg.go.dev/time
https://golang.org/src/time/time.go

Go stores time as a structure of a wall clock reference point (uint64), an 'ext' additional nanoseconds field (int64), and a location (pointer).
Go stores duration as an alias to int64 (nanoseconds).

There is no control over the reference points in Go to specify a given clock; either monotonic or wall clock. The base implementation attempts to encapsulate both monotonic and wall clock values together in Go. For common use case this likely has little to no impact, however it lacks the specificity needed to identify a progressive disclosure of use.

#### Rust
https://doc.rust-lang.org/stable/std/time/struct.Duration.html

Rust stores duration as a u64 seconds and a u32 nanoseconds.
The measurement of time in Rust uses Instant, which seems to use a monotonic clock for most platforms.

#### Kotlin
https://kotlinlang.org/api/latest/jvm/stdlib/kotlin.time/-duration/

Kotlin stores Duration as a Long plus a unit discriminator comprised of either milliseconds or nanoseconds. Kotlin's measurement functions do not return duration (yet?) but instead rely on conversion functions from Long values in milliseconds etc and those currently measurement functions use system uptime to determine reference points.

#### Swift
So given all of that, Swift can take this to another level of both accuracy of intent and ease of use beyond any of the other examples given. Following in the themes of other Swift APIs, we can embrace the concept of progressive disclosure and leverage the existing frameworks that define time concepts.

The given requirements are that we must have a way of expressing the frame of reference of time. This needs to be able to express a concept of now, and a concept of waking up after a given instant has passed. Instants must be able to be compared among each other but are specific to the clock they were obtained. Instants also must be able to be advanced by a given duration or a distance between two instants must be able to emit a duration. Durations must be comparable and also must have some intrinsic unit of time that can suffice for broad application.

It is worth noting that any extensions to Foundation, Dispatch, or other frameworks beyond the Swift standard library and concurrency library are not within the scope of this proposal and are under the prevue of those teams. This may or may not include additional Clock adoptions, additional functions that take the new types and changes in deprecations. Any examples here are listed as illustrations of potential use cases and not to be considered as part of this proposal.

##### Clock

The base protocol for defining a clock requires two primitives; a way to wake up after a given instant, and a way to produce a concept of now. Clocks can also be defined in terms of a potential resolution of access; some clocks may offer resolution at the nanosecond scale, other clocks may offer only microsecond scale. Any values of elapsed time may be considered to be 0 if they are below the minimum resolution.

```swift
public protocol Clock: Sendable {
  associatedtype Instant: InstantProtocol
  
  var now: Instant { get }
  
  func sleep(until deadline: Instant) async throws
  
  var minimumResolution: Duration { get }
  
  func measure(_ work: () async throws -> Void) reasync rethrows -> Duration
}
```

This means that given an instant, it is intrinsically linked to the clock; e.g., a monotonic instant is not meaningfully comparable to a wall clock instant. However, as an ease of use concession, the durations between two instants can be compared. However, doing this across clocks is considered a programmer error, unless handled very carefully. By making the protocol hierarchy just clocks and instants, it means that we can easily express a compact form of a duration that is usable in all cases; particularly for APIs that might adopt Duration as a replacement to an existing type.

The clock minimum resolution will have a default implementation that returns `.nanosecond(1)`. 

Clocks can then be used to measure a given amount of work. This means that clock should have the extensions to allow for the affordance of measuring workloads for metrics, but also measure them for performance benchmarks. In addition to the per clock definitions of measuring a base measurement function using the monotonic clock will also be added.

```swift
public func measure(_ work: () async throws -> Void) reasync rethrows -> Duration
```

This means that making benchmarks is quite easy to do:

```swift
let elapsed = measure {
  someWorkToBenchmark()
}
```

For example, we can adapt existing DispatchQueue API to take an instant as a deadline given a specific clock, or allow for generalized clocks. This allows for fine grained execution with exactly how the developer intends to have it work.

```swift
extension DispatchQueue {
  func asyncAfter(deadline: UptimeClock.Instant, qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], execute work: @escaping () -> Void)
  func asyncAfter<C: Clock>(deadline: C.Instant, clock: C, qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], execute work: @escaping () -> Void)
}
```

With additions as such, developers can interact similarly to the existing API set, but utilize the new generalized clock concepts. This allows for future expansion of clock concepts by the teams in which it is meaningful without needing to plumb through concepts into Dispatch's implementation.

```swift
DispatchQueue.main.asyncAfter(deadline: .now.advanced(by: .seconds(3)) {
  doSomethingAfterThreeSecondsOfUptime()
}
DispatchQueue.main.asyncAfter(deadline: .now.advanced(by: .seconds(3), clock: .wall) {
  doSomethingAfterThreeSecondsOfWallClock()
}
```

By providing the clock type, developers are empowered to make better choices for exactly the concept of time they want to utilize, but also allowed progressive disclosure to powerful tools to express that time.

##### Instant

As previously stated, instants need to be compared, and might be stored as a key, but only need to define a concept of now, and a way to advance them given a duration. By utilizing a protocol to define an instant, it provides a mechanism in which to use the right storage for the type, but also be type safe with regards to the clock they are intended for. The primary reasoning that instants are useful is that they can be composed.

Given a function with a deadline as an instant, if it calls another function that takes a deadline as an instant, the original can just be passed without mutation to the next function. That means that the instant in which that deadline elapses does not have interference with the pre-existing calls or execution time in-between functions. One common example of this is the timeout associated with url requests; a timeout does not fully encapsulate how the execution deadline occurs; there is a deadline to meet for the connection to be established, data to be sent, and a response to be received; a timeout spanning all of those must then have measurement to account for each step, whereas a deadline is static throughout.


```swift
public protocol InstantProtocol: Comparable, Hashable, Sendable {
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

`InstantProtocol` in addition to the `advance(by:)` and `duration(to:)` methods also has operators to add and subtract durations. However, it does not adhere to `AdditiveArithemtic` since that requires same type addition as well as a "zero"; of which neither make sense generally for defining instants.

This can be used to adapt existing behaviors like `URLRequest` timeout. Which then becomes more composable with other instant concepts than the existing timeout APIs.

```swift
extension URLRequest {
  public init(url: URL, cachePolicy: CachePolicy = .useProtocolCachePolicy, deadline: MonotonicClock.Instant)
}
```

This will be expanded upon further, but `RunLoop` will be modified to now take a type that is an `InstantProtocol` conforming type.

```swift
RunLoop.main.run(until: .now.advanced(by: .seconds(3)))
```

##### Duration

It is reasonable to consider that each clock's instant has it's own "unit" of time measurement. However, that complicates the adoption story and proliferates a practically identical type to solely prevent one potential minor mistake of comparing the duration from the difference of instants from two different clocks. Duration itself should be trivial to express, non-lossy storage, which avoids mathematical ambiguity. On one end of the spectrum is to make isolate monotonic durations different from wall clock durations, on the other is say everything is just a Double. Both have advantages, but both have distinct disadvantages. Making duration a structure that is trivial allows a happy middle ground, but also allows for the potential of incremental adoption.

Meaningful durations can always be expressed in terms of nanoseconds plus a number of seconds, either a duration before a reference point or after. They can be constructed from meaningful human measured (or machine measured precision) but should not account for any calendrical calculations (e.g., a measure of days, months or years distinctly need a calendar to be meaningful). Durations should able to be serialized, compared, and stored as keys, but also should be able to be added and subtracted (and zero is meaningful). They are distinctly NOT `Numeric` due to the aforementioned issue with regards to multiplying two `TimeInterval` variables. That being said, there is utility for ad-hoc division and multiplication to calculate back-offs.

The `Duration` must be able to account for high scale resolution of calculation; the storage will under the hood ensure proper rounding for division (by likely storing higher precision than exposed) and enough range to span the full range of potential reasonable instants. This means that spanning the full range of +/- thousands of years at a non lossy scale can be accomplished by storing the seconds and nanoseconds. 

```swift
public struct Duration: Sendable {
  public var seconds: Int64 { get }
  public var nanoseconds: Int64 { get }
}

extension Duration {
  public static func hours<T: BinaryInteger>(_ seconds: T) -> Duration
  public static func hours(_ seconds: Double) -> Duration
  public static func minutes<T: BinaryInteger>(_ seconds: T) -> Duration
  public static func minutes(_ seconds: Double) -> Duration
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
  public static func / <T: BinaryInteger>(_ lhs: Duration, _ rhs: T) -> Duration
  public static func /= <T: BinaryInteger>(_ lhs: inout Duration, _ rhs: T)
  public static func / (_ lhs: Duration, _ rhs: Duration) -> Double
  public static func * (_ lhs: Duration, _ rhs: Double) -> Duration
  public static func *= (_ lhs: inout Duration, _ rhs: Double)
  public static func * <T: BinaryInteger>(_ lhs: Duration, _ rhs: T) -> Duration
  public static func *= <T: BinaryInteger>(_ lhs: inout Duration, _ rhs: T)
}
```

##### Date

When speaking of temporal types, `Date` has served a distinct and special place in the core of Swift in some really prominent places. A `Date` value encapsulates a single point in time, independent of any particular calendrical system or time zone. `Date` values represent a time interval relative to an absolute reference date. It could easily be considered the canonical representation of a wall clock reference point and is quite suited as a concept to be used as a deadline for wall clock based calculations. In short, as part of this proposal, we intend to give `Date` a new home and move it from Foundation to the standard library. Now this will not include all of the API associated with `Date`, but instead a distinct subset of the API surface area about `Date` that is relevant to representing wall clock time reference points.

```swift
@available(macOS 10.9, iOS 7.0, tvOS 9.0, watchOS 2.0, macCatalyst 13.0, *)
@_originallyDefinedIn(module: "Foundation", macOS /*TBD*/, iOS /*TBD*/, tvOS /*TBD*/, watchOS /*TBD*/, macCatalyst /*TBD*/)
public struct Date {
  public init(converting monotonicInstant: MonotonicClock.Instant)
  public init(converting uptimeInstant: UptimeClock.Instant)
  
  @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
  public static var now : Date { get }
}

extension Date: InstantProtocol {
  public func advanced(by duration: Duration) -> Date
  public func duration(to other: Date) -> Duration
}

extension Date: Codable { }
extension Date: Hashable { }
extension Date: Equatable { }
```

As a _potential_ implementation detail; `Date` currently stores its value as a `Double` of seconds from Jan 1 2001 UTC. This causes floating point drift when the value is further out from that point in time, since we are taking the leap to move `Date` down the stack from Foundation to the standard library this seems like perfect opportunity to address this issue with a more robust storage solution. Instead of storing as a 64 bit `Double` value, it will now be stored as a `Int64` for seconds, and a `UInt32` for nanoseconds normalized where the nanoseconds storage will be no more than 1,000,000,000 nanoseconds (which is 29 bits) and a full range of seconds. This means that the storage size of `Date` will increase from 64 bits to 96 bits, with the benefit that the range of expressible dates will be +/-9,223,372,036,854,775,807.999999999 seconds around Jan 1 1970; which is full nanosecond resolution of a range of 585 billion years +/- a few months worth of leap year days and such - we feel that this range is suitable for any software and can be revisited in a few hundred billion years when it becomes an issue.

To give clarity on the real world impact of changing the storage size of `Date`; Xcode (it was a handy target for me to test) in a reasonably real world scenario created over 10,000 `NSDate` objects and around 3,000 of which were still resident at a quiescence point. Xcode reflects a decently large scale application and the translation from `NSDate` to `Date` does not 100% apply here but it gives a metric for what type of impact that might have in an extreme case; approximately 12kB more memory usage - comparatively to the total memory used this seems quite small, so the system impact should be relatively negligible.

Readers may have noticed that `Date` remains `Codable` at the standard library layer but gains a new storage mechanism. The coding format will remain the same. Since that represents a serialization mechanism that is written to disk and is therefore permanent for document formats. We do not intend for `Date` to break existing document formats and all current serialization will both emit and decode as it would for double values relative to Jan 1 2001 UTC as well as the `DateEncodingStrategy` for JSONSerialization. This does mean that when encoding and decoding `Date` values it may loose small portions of precision, however this is acceptable losses since any format stored as such inherently takes some amount of time to either transmit or write to disk; any sub-second (near nanosecond) precision that may be lost will be vastly out weighed from the write and read times.

The storage change is not a hard requirement; and may be a point in which we might decide is not worth taking.

All remaining APIs on Date will exist still at the Foundation layer for compatibility with existing software.

To be clear, we are not suggesting that Calendar, Locale, or TimeZone be moved down; those transitions are distinctly out of scope of this proposal and are not a goal.

##### WallClock

Wall clocks are useful since they represent a transmittable form of time. Instants can be serialized and sent from one machine to another and the values are meaningful in a foreign context. That transmission can be immediately useful when dealing with concepts like distributed actors; where an actor may be hosted on a remote machine and a deadline for work is sent across from one domain to another. The `WallClock` type will use `Date` as its `Instant` type and provide an extension to access the clock instance as the inferred base type property.

```swift
public struct WallClock {
  public init()
  
  public static var now: Date { get }
}

extension WallClock: Clock {
  public typealias Instant = Date

  public var now: Date { get }
  public func sleep(until deadline: Date) async throws
}

extension Clock where Self == WallClock {
  public static var wall: WallClock { get }
}
```

##### MonotonicClock

When instants are for local processing only and need to be high resolution without the encumbrance of suspension while the machine is asleep `MonotonicClock` is the tool for the job. The `MonotonicClock.Instant` type can be initialized with a wall clock instant if that value can be expressed in terms of a relative point to now; knowing the delta between the current time and the specified wall clock instant a conversion to the current monotonic reference point can be made such that conversion (if possible) represents what the value would be in terms of the monotonic clock. Much like the wall clock version the monotonic clock also offers an extension to access the clock instance as the inferred base type property.

```swift
public struct MonotonicClock {
  public init()
  
  public static var now: Instant { get }
}

extension MonotonicClock: Clock {
  public struct Instant {
    public init?(converting wallClockInstant: WallClock.Instant)
    
    public static var now: MonotonicClock.Instant { get }
  }

  public var now: Instant { get }
  public func sleep(until deadline: Instant) async throws
}

extension MonotonicClock.Instant: InstantProtocol {
  func advanced(by duration: Duration) -> MonotonicClock.Instant
  func duration(to other: MonotonicClock.Instant) -> Duration
}

extension Clock where Self == MonotonicClock {
  public static var monotonic: MonotonicClock { get }
}
```

##### UptimeClock

Where local process scoped or cross machine scoped instants are not suitable uptime serves the purpose of a clock that does not increment while the machine is asleep but is a time that is referenced to the boot time of the machine, this allows for the affordance of cross process communication in the scope of that machine. Similar to the other clocks there is an extension to access the clock instance as the inferred base type property.

```swift
public struct UptimeClock: Clock {
  public init()
  
  public static var now: Instant { get }
}

extension UptimeClock: Clock {
  public struct Instant {
    public init?(converting wallClockInstant: WallClock.Instant)
    public static var now: UptimeClock.Instant { get }
  }

  public var now: Instant { get }
  public func sleep(until deadline: Instant) async throws
}

extension UptimeClock.Instant: InstantProtocol {
  func advanced(by duration: Duration) -> UptimeClock.Instant
  func duration(to other: UptimeClock.Instant) -> Duration
}

extension Clock where Self == UptimeClock {
  public static var uptime: UptimeClock { get }
}
```

##### Example Custom Clock

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
  
  public func sleep(until deadline: Instant) async throws {
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

## Impact on Existing Code

### Existing APIs

Task will have a more distinct `sleep` function where a clock can be specified.

```swift
extension Task where Success == Never, Failure == Never {
  public static func sleep<C: Clock>(until deadline: C.Instant, clock: C) async throws
}
```

Or, in the case where an ease of use is preferred over a raw nanoseconds; we will add a connivence API exposing a monotonic duration to sleep for.

```swift
extension Task where Success == Never, Failure == Never {
  public static func sleep(for duration: Duration) async throws
}
```

The `DispatchQueue` implementation can support three types of fundamental clock types; monotonic, wall, and uptime. This might be able to be expressed as overloads to the instant types and avoid ambiguity by specifying a clock.

```swift
extension DispatchQueue {
  public func asyncAfter(deadline: MonotonicClock.Instant, qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], execute work: @escaping @convention(block) () -> Void)
  public func asyncAfter(deadline: WallClock.Instant, qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], execute work: @escaping @convention(block) () -> Void)
  public func asyncAfter(deadline: UptimeClock.Instant, qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], execute work: @escaping @convention(block) () -> Void)
}
```

### Existing Application Code

This proposal is purely additive and has no direct impact to existing application code.

## Impact on ABI

The proposed implementation will introduce two runtime functions; a way of obtaining time and a way of sleeping given a standard clock. Date when lowered will not immediately be frozen, however as a future direction we plan on making the type frozen for performance reasons; (it is mentioned in the evolution manifesto)[https://github.com/apple/swift/blob/main/docs/LibraryEvolutionManifesto.md#limitations] that a concept of a frozen as of a certain version will be a future direction available to evolution. We feel that this is an appropriate use case and should be revisited when that is available.

## Alternatives Considered

It has been considered to move Date down into the standard library to encompass a wall + monotonic concept like Go, but this was not viewed as extensible enough to capture all potential clock sources. Additionally this approach breaks the concept of comparability which is a key requirement for any `InstantProtocol`.

It has been considered to leave the Duration type to be a structure and shared among all clocks. This exposes the potential error in which two durations could be interchanged that are measuring two different things. From an opinionated type system perspective a `MonotonicClock.Duration` measures monotonic seconds and a `WallClock.Duration` measures wall clock seconds which are two different unit systems. This point is debatable and can be changed with the caveat that developers may write inappropriate code.

It has been considered to attempt to make Duration into a protocol form to restrict the concepts of measurement to only be compared in the clock scope they were defined by but that proves to be quite cumbersome for implementations and dramatically reduces the ease of use for APIs that might want to use interval types.

A concrete type expressing Deadlines could be introduced however adding that defeats the progressive disclosure of the existing types and poses a compatibility problem with existing APIs. Effectively it would make functions that currently take Date instead need to take `Deadline<WallClock>` which seems anti-thematic to tight integration with existing APIs.

It has been considered that Date should account for leap seconds, however after much consideration this is viewed as perhaps too disruptive to the storage and serialization of Date and that it is better suited to leverage calendrical calculations such as those in Foundation to account for leap seconds since that falls in line more so with DateComponents than Date.

As an alternative to moving Date to the standard library we have considered other strategies such as introducing a new type with a name that connotes better the concept of a date being defined as a point in time devoid of a calendar. However this ends up having a multi-level fall out. The large swath of APIs that are both in existing Swift exports of frameworks and SDKs that exist today have a use cases that use the same definition - that means that introducing a new type that serves the same purpose then becomes a quandary of "which type should I use". As a point of reference the SDK for macOS has approximately 1000 occurrences of the type NSDate which is bridged to Date, we feel that changing this would lead to needless churn for developers for no clear advantage especially since we can reform the storage to be more accurate. This is a topic that has been debated at length and we feel that the overall benefits for the reduction of churn at the magnitude of impact out weigh the marginal gains of a different name that may carry the same level of nomenclature ambiguity.

It was considered to make Foundation.TimeInterval to be implicitly converted to Duration; however it was determined that this is better suited as a potential future direction for importer adjustments instead since that type would potentially cause systemic problems with overloads based on the aliasing behavior of TimeInterval.
