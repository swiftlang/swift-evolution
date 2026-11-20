# Observation performance and modeling improvements

* Proposal: [SE-NNNN](NNNN-observation-performance-and-modeling.md)
* Authors: [Philippe Hausler](https://github.com/phausler)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: A complete implementation, with tests and benchmarks, is available as a standalone [package](https://github.com/phausler/Observable).
* Previous Proposals: [SE-0395](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0395-observability.md),
  [SE-0475](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0475-observed.md),
  [SE-0506](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0506-advanced-observation-tracking.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-observation-performance-and-modeling-improvements/89924))

## Introduction

Observation is now the model layer of most new SwiftUI code, and it is increasingly used outside
SwiftUI: in middleware, in synchronization between models, and on constrained targets. That
breadth exposes costs and gaps the original design couldn't anticipate. This proposal addresses
them as one set of additive changes with a single goal: the cost of observation should track what
is actually observed, and the shapes of model people want to write should be observable.

This proposal is in-depth, so here is a summary:

1. **Property indices.** `@Observable` gives each tracked property a small integer and passes it
   to new `ObservationRegistrar` overloads. Mutating a property nobody observes then skips the
   registrar's lock, even when other properties of the same object are observed. These overloads
   back-deploy.
2. **Event resolution.** `@Observable(resolution: .object)` and `@ObservationTracked(group:)` let a
   type choose coarser change events than one per property.
3. **Derived properties.** `@ObservationDerived` declares a property that is computed from other
   observable state, stored, recomputed only when its inputs change, and not treated as changed
   when it recomputes to an equal value.
4. **Persistent listeners.** `ObservationTracking.Listener` is a synchronous observer that is
   re-armed in place. Its `.coalesced` option delivers a burst of N writes once instead of N times.
5. **Noncopyable observable types.** `@Observable` can be applied to a `~Copyable` struct.
6. **Embedded Swift.** Observation builds for Embedded Swift, where key paths are unavailable,
   through registrar entry points that take only a property index.

Most developers meet the first three through the macros: recompiling picks up property indices,
and `@ObservationDerived` and `resolution:` are spelled on the declaration. The registrar entry
points, `ObservationDerivedValue` and `Listener` are for library authors, frameworks and
hand-written observable types.

## Motivation

### Mutating an unobserved property of an observed object can be expensive

Every mutation of an `@Observable` property calls `willSet(_:keyPath:)` and `didSet(_:keyPath:)`.
With only a key path to go on, learning that *nobody* observes the property means forming the key
path (a `swift_getKeyPath` call plus a retain and release), then taking the registrar's lock and
hashing the key path, twice. This is the common case: a SwiftUI model is observed by views that
each read a few properties, while the app mutates many more.

Much of the registrar's cost can be removed without API changes (one allocation per registrar, a
lazily created observer table, a lock-free "never observed" check). Those are implementation
details and not part of this proposal. Measured on an M-series Mac, release builds, as
library-evolution dylibs:

| scenario | Swift 6.4 runtime | runtime-only changes | with property indices |
|---|---|---|---|
| mutate a property of a never-observed object | 34 ns | 23 ns | 23 ns |
| observe one property, then mutate it | 790 ns | 260 ns | 260 ns |
| **mutate an unobserved property of an observed object** | 70–115 ns | 75–115 ns | **19–24 ns** |

Runtime-only changes can't improve the last row. If each mutation also carried a small, stable
integer naming the property, the registrar could keep a per-object bitmask of properties that may
be observed and return after one relaxed atomic load. The macro already knows such an integer: the
property's position among its type's tracked properties.

### Per-property events are sometimes the wrong granularity

Some types are always read as a whole: a color whose components are rendered together, or a
settings record displayed as one unit. For them, per-property tracking registers one entry per
property read and delivers one notification per property written, for no benefit. Installing one
observer that reads every property of an object took 41 µs and 60 allocations with 32 properties,
and 1.6 ms and 2,203 allocations with 2,048. Today a type has no way to say "treat these
properties as one".

### Derived state is recomputed on every read

A computed property of an `@Observable` type is observable for free, because reading it reads the
stored properties it depends on. A `results` property that filters `books` by `query` is one
example. But it is recomputed on every read, by every reader, whether or not `books` or `query`
changed, and chains of derived values multiply this. Caching by hand is error-prone: a cache in an
`@ObservationIgnored` property doesn't know when to invalidate, and one invalidated from `didSet`
on each input recomputes eagerly on every write, even if nobody reads it. What's wanted is the
derived value that other reactive systems provide: computed lazily, kept until something it read
changes, and not propagated when it recomputes to an equal value.

### Synchronous listeners can be quadratic over bursts of writes

A common synchronous observer reads a set of models to take a snapshot and wants to be told
*before* any of it changes. Today it must re-register from its own `onChange` handler. If the app
then writes to N models in a loop, the observer fires N times and each firing reads all N models:
N² reads. Measured with N models, a `willSet` observer that reads all of them, and one write to
each: `withObservationTracking(options: [.willSet])` re-armed in `onChange` took 100 fires, 10 000
reads and 17.2 µs/write at N=100, and 1 600 fires, 2 560 000 reads and 287 µs/write at N=1600.
`withContinuousObservation(options: [.willSet])` fires once and reads N times.

The asynchronous APIs are linear because they run the observer after the burst, on an actor. That
is exactly what a snapshot observer can't accept: the pre-change state is gone. Re-registering is
also allocation-heavy (20–32 allocations per write), and there is no persistent synchronous
observer in public API.

### Observable types must be classes

A registrar needs one identity for observers to register with, and a copy of a struct would share
its registrar with the original. A noncopyable struct doesn't have that problem: it has exactly one
owner, and its registrar moves with it. Noncopyable models suit code that wants unique ownership
and deterministic destruction, but today such code has to give up either noncopyability or
observation.

### Observation is unavailable in Embedded Swift

The registrar is built around key paths, which Embedded Swift doesn't support, so small devices
can't use Observation.

## Proposed solution

### Property indices

`ObservationRegistrar` gains overloads of its four entry points that take a `propertyIndex:`
argument:

```swift
registrar.access(self, keyPath: \.name, propertyIndex: 0)
registrar.withMutation(of: self, keyPath: \.name, propertyIndex: 0) { _name = newValue }
```

`@Observable` numbers each tracked stored property and its accessors call these overloads, so
existing types adopt the fast path by being recompiled. The property index is a **hint**: the key
path remains the property's identity, notifications are delivered exactly as for the key-path-only
entry points, and a wrong, conflicting or out-of-range index costs only the fast path, never
correctness. On older runtimes the overloads call the key-path-only entry points.

### Event resolution

```swift
@Observable(resolution: .object)
final class Color {
  var red = 0.0
  var green = 0.0
  var blue = 0.0
}

@Observable
final class Layout {
  @ObservationTracked(group: 1) var width = 0.0
  @ObservationTracked(group: 1) var height = 0.0
  var title = ""
}
```

In `Color`, every tracked property shares one event. In `Layout`, `width` and `height` share an
event and `title` has its own. An observer that read any property of a shared event is notified
when any of them changes.

### Derived properties

```swift
@Observable final class Library {
  var books: [Book] = []
  var query = ""

  @ObservationDerived var results: [Book] {
    input { (books, query) }
    update { books, query in
      books.filter { $0.title.localizedStandardContains(query) }
    }
  }
}
```

`input` reads what the value depends on and should be cheap. `update` computes the value from what
`input` returned and must be pure. Reading `results`:

* runs neither block if nothing observable has been written since it was last computed;
* otherwise runs `input`, and runs `update` only if something `input` read has changed.

If the value is `Equatable` and recomputes to an equal value, derived properties that read it
don't recompute. Observers of `results` are notified when `books` or `query` changes, exactly as
for a computed property.

### Persistent listeners

```swift
var listener = ObservationTracking.Listener(options: [.willSet, .coalesced]) { _ in
  scheduleRender()
}
listener.track { render(model) }
```

A `Listener` is a `~Copyable` handle: dropping it cancels it. Each `track(_:)` replaces what the
listener tracks with what its closure reads. It keeps unchanged registrations, and allocates
nothing when the tracked properties are the same as last time. With `.coalesced`, the listener is
told once before the first change to anything it read, and not again until it tracks again outside
its own handler, so a burst of N writes costs one delivery.

### Noncopyable observable types

```swift
@Observable
struct Counter: ~Copyable {
  var count = 0
  var step = 1
}
```

Its properties are tracked and notified as a class's are, for example when the struct is stored in
a class and read under `withObservationTracking`. No key path can name a property of a noncopyable
type, so the expansion identifies each property by its property index alone, through new registrar
entry points that take only an index. An `Event` therefore can't say which property changed.

### Embedded Swift

The `Observation` module builds for Embedded Swift. There, `ObservationRegistrar`'s only entry
points are the index-only ones, and `@Observable`'s expansion uses them. Everything that doesn't
depend on key paths is available, including `withObservationTracking`, `Listener` and
`@ObservationDerived`.

## Detailed design

### Property indices

#### Registrar entry points

```swift
extension ObservationRegistrar {
  /// - Parameter propertyIndex: A small non-negative integer identifying the property
  ///   within its type. Pass the same value for a given key path every time.
  @_alwaysEmitIntoClient
  public func access<Subject: Observable, Member>(
    _ subject: Subject,
    keyPath: KeyPath<Subject, Member>,
    propertyIndex: Int
  )

  @_alwaysEmitIntoClient
  public func willSet<Subject: Observable, Member>(
    _ subject: Subject,
    keyPath: KeyPath<Subject, Member>,
    propertyIndex: Int
  )

  @_alwaysEmitIntoClient
  public func didSet<Subject: Observable, Member>(
    _ subject: Subject,
    keyPath: KeyPath<Subject, Member>,
    propertyIndex: Int
  )

  @_alwaysEmitIntoClient
  public func withMutation<Subject: Observable, Member, T>(
    of subject: Subject,
    keyPath: KeyPath<Subject, Member>,
    propertyIndex: Int,
    _ mutation: () throws -> T
  ) rethrows -> T
}
```

**Semantics.** Each overload behaves as its key-path-only counterpart: the same observers are
notified, in the same order, with the same key path reported by `Event.matches(_:)`. Observers
registered through either form see mutations made through either. Hand-written key-path-only calls
and macro-generated property index calls can be mixed freely on one type, as can observable
subclasses whose registrars number their indices independently.

**The property index contract.**

* A caller passes the same `propertyIndex` for a given key path every time. Macro-generated code
  does this by construction.
* If a key path is seen with two different indices, the registrar stops using the fast path for it.
* Two different key paths may share an index. That is correct, only slower; event resolution
  relies on it.
* A negative index, or an index of 64 or more, never uses the fast path.

**The fast path.** Each registrar keeps a 64-bit `observedMask`. A clear bit `s` means no `willSet`
or `didSet` observer observes any key path that has been mutated with index `s`; a set bit may be
stale, which only costs the slow path. `willSet`, `didSet` and `withMutation` check the mask with a
relaxed atomic load and, if the bit is clear, return (or just run `mutation`) without taking the
lock.

The mask is written only under the registrar's lock: whenever the set of observers changes, and
when the registrar first learns a key path's index from a tagged mutation. Relaxed ordering
suffices, because a registration racing a mutation is already unordered with it. `access` records
by key path as before; the index isn't needed until a mutation.

**Back-deployment.** The overloads are `@_alwaysEmitIntoClient`. Behind an availability check they
call two new `@usableFromInline` runtime entry points, `_willSet(_:propertyIndex:)` and
`_didSet(_:propertyIndex:)`; otherwise they call the key-path-only entry points.

#### Macro changes

`@Observable` assigns indices in declaration order to the tracked stored properties that are direct
members of the type. `@ObservationIgnored` properties are skipped, and a property declared inside
an `#if` block gets no index and uses the key-path-only form. `@ObservationTracked` gains
parameters, which `@Observable` passes:

```swift
@attached(accessor, names: named(init), named(get), named(set), named(_modify))
@attached(peer, names: prefixed(_))
public macro ObservationTracked(
  propertyIndex: Int = -1,
  group: Int? = nil,
  representative: String? = nil
) = #externalMacro(module: "ObservationMacros", type: "ObservationTrackedMacro")
```

`group:` is described under *Event resolution*; `representative:` names the property whose key path
stands for a shared index. A negative `propertyIndex` means "none", and the accessors then use the
key-path-only entry points, so existing hand-written uses are unaffected.

`@Observable` also synthesizes `access(keyPath:propertyIndex:)` and
`withMutation(keyPath:propertyIndex:_:)` members, and the accessors of each property pass its
index. For example, `@ObservationTracked(propertyIndex: 0) var name = ""` has a getter that calls
`access(keyPath: \.name, propertyIndex: 0)` and a setter that calls
`withMutation(keyPath: \.name, propertyIndex: 0)`. Everything else about the expansion is
unchanged. A type that declares its own `access(keyPath:)` or `withMutation(keyPath:_:)` to
intercept observation keeps working: the synthesized index forms forward to the customization and
drop the index.

### Event resolution

```swift
@attached(member, names: named(_$observationRegistrar), named(access), named(withMutation), named(shouldNotifyObservers))
@attached(memberAttribute)
@attached(extension, conformances: Observable)
public macro Observable(resolution: ObservationResolution) =
  #externalMacro(module: "ObservationMacros", type: "ObservableMacro")

public enum ObservationResolution {
  case `default`  // Each tracked property is its own event source.
  case object     // All tracked properties share a single event source.
}
```

`Observable(resolution:)` is a separate declaration rather than a defaulted parameter so that
`@Observable` keeps its original availability. Resolution is implemented entirely in the macro, on
top of property indices:

* With `resolution: .object`, every tracked property gets index 0.
* With `group: n`, the properties of a group get the index of the first of them; ungrouped
  properties keep their own. The value `n` only names the group, and has no relationship to the
  index.
* Properties that share an index also share a key path: each passes the key path of a
  *representative*, the first property of the group. If the group's properties are isolated
  differently, the representative is the first `nonisolated` one; if there is none, the macro
  reports an error.

So `Event.matches(_:)` reports the representative's key path: `matches(\.width)` is true when
`height` changes, and `matches(\.height)` is false. That is the intended trade: precision for fewer
registrations, fewer notifications and lower per-write cost. `resolution:` and `group:` must be
literals.

### Derived properties

#### The macro

```swift
@attached(peer, names: prefixed(_))
@attached(body)
public macro ObservationDerived() =
  #externalMacro(module: "ObservationMacros", type: "ObservationDerivedMacro")
```

`@ObservationDerived` applies to a single instance `var` with a declared type, in a class or a
noncopyable struct. Its body must be exactly `input { ... }` followed by `update { ... }`; anything
else is diagnosed. The macro splices the blocks into a call as closures. The example above expands
to:

```swift
var results: [Book] {
  return _results.compute(input: {
    (books, query)
  }, update: { books, query in
    books.filter { $0.title.localizedStandardContains(query) }
  })
}

private let _results = Observation.ObservationDerivedValue<[Book]>()
```

The type doesn't need to be `@Observable`, but its inputs are tracked only if they are observable.

#### Storage

`ObservationDerivedValue` is the storage the macro declares. For properties that need their own
accessors, declaring one by hand and calling `compute(input:update:)` from a getter is equivalent.

```swift
public struct ObservationDerivedValue<Value: Sendable>: Sendable, ~Copyable {
  public init()

  /// Returns the stored value, first recomputing it if what it depends on has
  /// changed; a recomputed value equal to the stored one is not a change.
  public func compute<Input>(
    input: () -> Input,
    update: (Input) -> Value
  ) -> Value where Value: Equatable

  /// Returns the stored value, first recomputing it if what it depends on has changed.
  public func compute<Input>(
    input: () -> Input,
    update: (Input) -> Value
  ) -> Value
}
```

Without `Equatable`, every recomputation counts as a change. `ObservationDerivedValue` is
`~Copyable` because a derived value has an identity: a copy would share no state with the
original.

#### Semantics

The runtime keeps a process-wide **epoch**, advanced by a write only if its object has been read by
some `input` in the current epoch, so bursts of unread writes advance it at most once. Each derived
value records the epoch it was last validated in (`visited`) and the epoch its value last changed
in (`mutated`). Reading a derived value:

1. **Clean.** If it has a value and the epoch hasn't advanced since `visited`, it returns the value
   without running either block.
2. **Revalidate.** Otherwise it runs `input`, recording the newest write epoch among the objects
   `input` reads. Reading another derived value counts as reading something written at that
   value's `mutated` epoch.
3. **Recompute.** If anything `input` read is newer than `visited`, it runs `update`. If `Value` is
   `Equatable` and the result equals the stored value, `mutated` is left alone, so dependents don't
   recompute either. Otherwise the result is stored and `mutated` advances.

This makes `update` **lazy** (writes run nothing, and once it has run it doesn't run again until
something in its input changes) and **incremental** (recomputation stops at the first unchanged
value). A diamond or chain recomputes each value at most once per change.

A write to the input of a derived value costs 11–18 ns and runs no `update`. A clean read costs
about 126 ns, mostly its lock. A derived property therefore pays off when `update` costs more than
that or the value is read from several places; a cheap expression is better left as a computed
property.

**Observers.** A read inside `withObservationTracking`, a `Listener`'s `track`, or any other
tracking runs `input` the first time it reads the derived value in that tracking, so that the
tracking records the dependencies. Later reads of the same value in that tracking don't run `input`
again, while the value is valid. `update` runs only if an input changed. Observers of a derived
property are notified when its inputs change, as for a computed property; the property doesn't
itself filter notifications.

**Contract.**

* `input` should be cheap: it runs on every read that isn't clean.
* `update` must be pure, and should read no observable state, since such reads are not inputs.
* Only observable reads are inputs; reads of `@ObservationIgnored` properties, globals or
  non-observable objects never cause a recomputation.
* A derived value that depends on itself, directly or through others, traps.

**Concurrency.** Each derived value has its own lock, held while it runs `input` and `update`.
Reads from several threads are serialized and a recomputation happens once. Locks are only taken
from a value to the values it reads, so lock order follows the acyclic dependency graph.

### Persistent listeners

```swift
extension ObservationTracking {
  public struct Listener: ~Copyable, Sendable {
    public init(
      options: ObservationTracking.Options = .willSet,
      onChange: @escaping @Sendable (ObservationTracking.Event.Kind) -> Void
    )

    /// Calls the C function `onChange` with `context` and `willSetCode` or
    /// `didSetCode`, allocating nothing for the handler. `context` must stay
    /// valid until the listener is cancelled or dropped.
    public init(
      options: ObservationTracking.Options = .willSet,
      context: UnsafeMutableRawPointer?,
      onChange: @convention(c) (UnsafeMutableRawPointer?, Int) -> Void
    )

    public static var willSetCode: Int { get }
    public static var didSetCode: Int { get }

    /// Tracks the observable properties `apply` reads, in place of those the
    /// previous call tracked, and returns what `apply` returns.
    public mutating func track<T: ~Copyable, Failure: Error>(
      _ apply: () throws(Failure) -> T
    ) throws(Failure) -> T

    /// Stops the listener; it is not notified again.
    public consuming func cancel()
  }
}

extension ObservationTracking.Options {
  /// Delivers at most once per arming.
  public static var coalesced: ObservationTracking.Options { get }
}
```

**Tracking in place.** Per observed object, a registration from the previous `track(_:)` call is
updated in place rather than cancelled and re-created. Registrations of objects no longer read are
cancelled, and the previous call's storage is reused, so re-tracking the same properties allocates
nothing. The listener is notified, with the kinds its options name, until it is cancelled or
dropped.

**Coalescing.** Without `.coalesced`, a listener is notified of every write to anything it tracks.
With it, the listener has an *armed* flag:

* `track(_:)` arms it, and a notification disarms it. Delivery claims the flag under the
  listener's lock, so concurrent writers deliver once.
* A `track(_:)` made from inside the listener's own handler, on the thread running it, refreshes
  what is tracked without re-arming. This lets a handler take a fresh snapshot without re-opening
  the gate for the rest of a burst.
* A `track(_:)` call on any other thread arms it.

The contract is: *a coalesced listener is told at least once before the first change to anything it
read since its last notification.* That is what invalidation- and snapshot-style consumers need. It
is not what a per-property consumer such as undo registration needs, which is why it is opt-in.
Because the flag is keyed to the listener's own tracked reads, the writer's reads don't re-arm it:
a `+=` loop over N models delivers once.

This uses the fixture from *Motivation*. A coalesced `Listener` re-tracked in its handler fires
once with 0 allocations, and its per-write cost stays flat as N grows (180 ns at N=100, 233 ns at
N=1600), against 287 µs per write at N=1600 for the re-armed one-shot observation.

**C handlers.** The `@convention(c)` initializer exists for targets that must not allocate after
start-up, such as Embedded configurations without a heap.

### Noncopyable observable types

#### The `Observable` protocol

```swift
public protocol Observable: ~Copyable { }
```

Every existing generic signature that mentions `Observable`, such as `<Subject: Observable, Member>`
on the registrar's entry points, still implicitly requires `Subject: Copyable`, so none changes
meaning or mangling.

#### Property index-only registrar entry points

```swift
extension ObservationRegistrar {
  public func access(propertyIndex: Int)
  public func willSet(propertyIndex: Int)
  public func didSet(propertyIndex: Int)

  public func withMutation<T, Failure: Error>(
    propertyIndex: Int,
    _ mutation: () throws(Failure) -> T
  ) throws(Failure) -> T
}
```

These are for types that can't form key paths. Here the index isn't a hint but the property's
identity within its registrar:

* A type passes a property's index the same way every time, and properties with the same index are
  the same event source (which is how `group:` and `.object` work for these types).
* A property observed by index and one observed by key path are always different event sources,
  even on one registrar, so a type uses one form per property.
* These mutations name no property: `Event.matches(_:)` is false for them.
* `.deinit` events, `withObservationTracking`, `Listener`, derived values and the `observedMask`
  fast path work as for key-path properties. The fast path is exact from the first registration.

These are the same signatures Embedded Swift uses, so `@Observable` emits a single form for
noncopyable types in every build.

#### Macro changes

`@Observable` accepts a struct whose inheritance clause suppresses `Copyable`; copyable structs,
enums and actors are still diagnosed. For a noncopyable struct the accessors make only index-only
calls. `withMutation` is synthesized as a `mutating` method that passes the struct to its closure
`inout`, since a setter can't otherwise mutate `self` while a method borrows it. For example, the
setter of `count` calls `withMutation(propertyIndex: 0) { $0._count = newValue }`.

`@ObservationDerived` may also be used in a noncopyable struct, where the noncopyable
`ObservationDerivedValue` is stored inline.

#### Using noncopyable observable types

* The closures of `withObservationTracking` and `Listener.track(_:)` don't escape, so they can
  borrow a noncopyable value directly.
* Escaping closures, such as those of `Observations`, `withContinuousObservation` and `Task`, can't
  capture a noncopyable local; such a model lives in a class, actor or global.
* Tracked stored properties must be copyable; mark a noncopyable stored property
  `@ObservationIgnored`.
* Without key paths, a type can't customize observation with its own `access(keyPath:)` or
  `withMutation(keyPath:_:)`.

### Embedded Swift

Under Embedded Swift, `ObservationRegistrar` has no key-path entry points. Its only entry points
are the index-only ones above, and observers are keyed by index directly. The accessors that
`@Observable` generates for a class contain both forms, selected with `#if $Embedded`; those for a
noncopyable struct use the index-only form in every build. A property with no index (because it is
declared in an `#if`) can't be tracked without a key path, so it is an error under Embedded and in
a noncopyable struct, rather than silently untracked.

What depends on key paths or runtime features Embedded lacks is unavailable there:
`Event.matches(_:)`, the `ObservationRegistrar: Codable` conformance, and the key-path entry
points. Everything else works as elsewhere.

## Source compatibility

All of the changes are additive.

* The new registrar overloads require the `propertyIndex:` label, so no existing call resolves
  differently.
* `@ObservationTracked`'s new parameters are defaulted, and `@Observable(resolution:)` is a new
  overload alongside `@Observable()`.
* The synthesized `access(keyPath:propertyIndex:)` and `withMutation(keyPath:propertyIndex:_:)` are
  added only when the type doesn't declare members with those signatures.
* `ObservationResolution` and `ObservationDerivedValue` are new top-level names in a module that
  SwiftUI re-exports; both carry the `Observation` prefix to stay out of the way of other modules.
* Suppressing `Copyable` on `Observable` is source-compatible: existing generic parameters and
  extensions keep their implicit `Copyable` requirement. Code opts into noncopyable observables by
  writing `~Copyable`.

The one exception is a development toolchain used with an older SDK, whose `@ObservationTracked`
doesn't accept `propertyIndex:` and fails with "argument passed to macro expansion that takes no
arguments". Toolchains and SDKs released together are unaffected. This is the main compatibility
cost of the proposal.

## ABI compatibility

This proposal is purely additive: no existing symbol is removed or changes meaning, and the
exported symbols are a strict superset of the current SDK's.

* The key-path overloads that take `propertyIndex:` are `@_alwaysEmitIntoClient` and add no public
  symbols. The runtime gains two `@usableFromInline` symbols, `_willSet(_:propertyIndex:)` and
  `_didSet(_:propertyIndex:)`.
* `ObservationResolution`, `ObservationDerivedValue`, `ObservationTracking.Listener` and
  `ObservationTracking.Options.coalesced` are new symbols with appropriate availability.
* The index-only entry points are four new symbols. They can't be emitted into the client, because
  without a key path there is no older entry point to fall back to.
* Macros have no ABI, and suppressing `Copyable` on `Observable` changes no symbol.

Existing binaries keep calling the key-path-only entry points and behave as before.

## Implications on adoption

* `@Observable` types adopt property indices by recompiling; code deployed to older OS versions
  keeps working with unchanged performance. Hand-written types can adopt property indices by
  switching to the index-taking overloads, and un-adopting is source- and ABI-compatible.
* Libraries that expose `@Observable` types don't change their own ABI by adopting: the
  synthesized members are `internal` and indices never cross a module boundary.
* `@ObservationDerived`, `@Observable(resolution:)`, `Listener` and noncopyable observable types
  require the new runtime. The expansion for a noncopyable struct calls the index-only entry points
  unconditionally, so a module deploying to older runtimes must mark such a type `@available`.
* Replacing a computed property with `@ObservationDerived`, or back, doesn't change a type's API.

## Future directions

**Parameterized derived values.** A derived *function*, `@ObservationDerived func row(at:)`, would
cache one value per argument.

**Generic noncopyable observable types.** For a generic struct with `~Copyable` type parameters,
the generated conformance doesn't suppress `Copyable` on those parameters. Propagating it is a
macro change.

**Observable actors.** The same index-only strategy could be applied to actors. This needs more
research into its long-term implications for isolation and concurrency.

## Alternatives considered

### Property indices

**Runtime-only improvements.** These are being made anyway and need no review, but they can't help
an unobserved property of an *observed* object, because the key path is all the registrar has. That
case dominates for SwiftUI models.

**Index only, no key path.** The registrar couldn't turn an index back into a key path, which
breaks `Event.matches(_:)`, matching hand-written key-path calls, and the fallback on older
runtimes.

**Trust the index.** Using the index directly as the table index is faster when right, but it
silently mis-notifies when a hand-written call passes a different index or two registrars number a
key path differently. Checking identity costs one pointer comparison.

**`@backDeployed` overloads.** These behave the same but add four public symbols instead of two
internal ones.

**Avoiding the toolchain/SDK coupling.** An accessor macro can't see its sibling members to count
them, and no mechanism lets the macro emit the index in a form an older SDK ignores:
`#if canImport(Observation, _version:)` doesn't apply to SDK-provided modules.

**A synthesized index-to-key-path map.** The map can only return `PartialKeyPath<Subject>`, while
older runtimes accept only `KeyPath<Subject, Member>`, so the fallback needs a dynamic cast. That
costs 56–57 ns per mutation on older runtimes, against 32–33 ns for today's expansion.

### Event resolution

**Each property passes its own key path with a shared index.** This keeps `Event.matches(_:)`
exact, but observers are identified by key path, so a group would still register one entry per
property read.

**No runtime type.** Something like `@Observable(objectResolution: true)` would add no symbols and
be usable when deploying to older runtimes. `ObservationResolution` leaves room for more
resolutions and reads better at the use site.

### Derived properties

**The name.** `@ObservationCached` described the mechanism rather than the guarantee and suggested
eviction or manual invalidation. `@ObservationMemoized` is precise but less approachable, and
`@ObservationComputed` would be confused with computed properties. *Derived state* is the term
SwiftUI developers and other reactive systems already use. A bare `@Derived` would occupy a general
name in every module that imports SwiftUI.

**A single block.** It would have to run the whole computation to find its dependencies on every
read that isn't clean. The `input`/`update` split makes revalidation cheap and lets `update` be
skipped.

**A notifying property.** Notifying its own observers requires computing eagerly at `willSet` time
on every input write, whether or not anyone reads it. That defeats laziness and makes bursts
quadratic.

**A process-wide lock, or none.** A lock per value lets unrelated values compute concurrently and
keeps Observation's promise that observable types can be used from any thread.

### Persistent listeners

**A global "something was read" gate.** This is sound only when every listener hears every change.
With selective delivery, one listener's delivery could hide a change from another, and the gate
re-opens whenever the writer reads, keeping a `+=` loop quadratic.

**Coalescing in `withObservationTracking`.** A one-shot observation is torn down when it fires, so
it can't remember that it has been told.

### Noncopyable observable types

**Copyable structs.** Copies would share a registrar, so mutating either would notify observers of
both. Giving each copy a fresh registrar would silently drop observers on every implicit copy.

**Waiting for key paths to noncopyable types.** That is a language change of its own; the
index-only entry points don't preclude adopting key paths later.

**Identifying the struct by address.** A noncopyable value can move. Its registrar storage, which
moves with it, is the stable identity.

## Acknowledgments

Special thanks to Stefan Xenos for inspiring the implementation changes and for the algorithmic
adjustments behind them.
