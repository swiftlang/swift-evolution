## Custom Executor updates

### Assert, precondition and assume APIs

All these APIs should be about executors and isolation domains. 

> Note: We don't actually have the "current actor" at all ABI-wise. We only have the current executor, which are unique for default actors, but when sharing executors this is no longer true. This might be problematic for tracing systems etc, but for the current assertions it should be enough...

The custom actor executors pitch proposed we offer those two assertion APIs, and that we do **not** offer any way to "get current executor" publicly. Maybe we'll offer this someday, but for now we don't have a strong reason to expose this and we'd like to push people to model their code using actors, i.e. "an actor on a specific executor", rather than grab executors and use them directly just as something to throw work onto.

The current executors proposal includes the following, and I propose we keep them as-is (or bikeshed names a bit):

```swift
// Precondition

public func preconditionTaskOnExecutor(
  _ executor: some Executor,
  _ message: @autoclosure () -> String = "",
	file: String = #fileID, line: UInt = #line)

public func preconditionTaskIsOnExecutor(
  _ actor: some Actor,
  _ message: @autoclosure () -> String = "",
	file: String = #fileID, line: UInt = #line)

// Assert (if we really want to make less API, we could skip the assert ones, but I think they're useful)

public func assertTaskOnExecutor(
  _ executor: some Executor,
  _ message: @autoclosure () -> String = "",
	file: String = #fileID, line: UInt = #line)

public func assertOnActorExecutor(
  _ actor: some Actor,
  _ message: @autoclosure () -> String = "",
	file: String = #fileID, line: UInt = #line)
```

I propose that we offer those assert/precondition because we can do a better job at error reporting than if we just gave people the `isTaskOnExecutor(some executor)` because we can offer a message like `"Was on executor ... but expected ..."`.

And the `assume...` API, specifically for MainActor right now:

```swift
// Assume

func assumeOnMainActorExecutor<T>(
    _ operation: @MainActor () throws -> T,
    file: StaticString = #fileID, line: UInt = #line
) rethrows -> T

// TODO: We could offer a macro for all kinds of global actors,
//       but we can't "just" implement it without a macro since the `@ACTOR () -> T` we can't abstract over
```

And we only offer the `assume` version that _does_ check (i.e. precondition-style) if we are on the main actor's executot.

> Note: We do not offer any API to "get current executor" explicitly. I personally think steering people towards using actors as isolation domains, and expressing executors as "the ont that actor X is using" is useful enough, and we allow for this.

Do note that users have no way of obtaining the specific "main actor executor" that conforms to SerialExecutor, we only ever expose it as the wrapped `UnownedExecutor`:

```swift
@globalActor public final actor MainActor: GlobalActor {
  public static let shared = MainActor()

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    return UnownedSerialExecutor(Builtin.buildMainActorExecutorRef())
  }

  public static var sharedUnownedExecutor: UnownedSerialExecutor {
    return UnownedSerialExecutor(Builtin.buildMainActorExecutorRef())
  }
}
```

This does mean however that developers can write these assertions:

```swift
func sync() {
  assertOnActorExecutor(MainActor.shared, "I sure hope I'm on the main actor")
}

@MainActor
func test() {
  sync()
}
```

All these APIs are expressed in terms of executors. 

> Naming note: I'd be open to ideas about naming this somehow around "the same mutually exclusive execution context" but the naming gets out of hand pretty quickly, so I stuck with ActorExecutor and Executor :thinking:

Alternatively, we could have them speak about isolation context? Technically `assertSameActorIsolation(some Actor)` would be correct to compare the actors

### "Deep" Executor equality

By default, we assume pointer equality of executors is sufficient and correct.

This exists today, and today is the only thing that users can do really. It is spelled as:

```swift
extension MyCoolExecutor { 
  public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  } 
}
```

This is all good, but we should likely change the spelling a bit (this was also a point made in SE pitch review):

```swift
extension MyCoolExecutor { 
  public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(unique: self) // 5.9, same as the old ordinary:
  } 
}
```

The unique initializer keeps the current semantics of "*if the executor pointers are the same, it is the same executor and exclusive execution context*" fast path.

If executors want to offer the "deep" equality they need to implement the `asUnownedExecutor` as:

```swift
extension MyQueueThatTargetsAnotherQueueExecutor { 
  public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(complexEquality: self) // TODO: unsure about the init name
  } 
}
```

The complex equality one must implement the following protocol requirement (that has a default implementation, because `SerialExecutor` is an existing protocol, so we must provide a default anyway):

```swift
  /// If this executor has complex equality semantics, and the runtime needs to compare
  /// two executors, it will first attempt the usual pointer-based equality check,
  /// and if it fails it will compare the types of both executors, if they are the same,
  /// it will finally invoke this method, in an attempt to let the executor itself decide
  /// if this and the `other` executor represent the same serial, exclusive, isolation context.
  ///
  /// This method must be implemented with great care, as wrongly returning `true` would allow
  /// code from a different execution context (e.g. thread) to execute code which was intended
  /// to be isolated by another actor.
  ///
  /// This check is not used when performing executor switching.
  ///
  /// This check is used when performing `assertOnSerialExecutor`, `preconditionOnSerialExecutor`,
  /// `assumeMainActorExecutor` and similar APIs which assert about the same "exclusive execution context".
  ///
  /// - Parameter other:
  /// - Returns: true, if `this` and the `other` executor actually are mutually exclusive, and it is safe from a concurrency perspective, to execute code assuming one on the other.
  @available(SwiftStdlib 5.9, *)
  func isSameExclusiveExecutionContext(other: Self) -> Bool
}

@available(SwiftStdlib 5.9, *)
extension SerialExecutor {
  func isSameExclusiveExecutionContext(other: Self) -> Bool {
    self === other
  }
}
```

For example, a dispatch queue based executor could implement this as follows:

```swift
// how a dispatch queue based custom executor could use this:

  func isSameExclusiveExecutionContext(other: Self) -> Bool {
    // pseudo-code
    self.targetQueue == other.targetQueue
  }
```

So even if two actors (`A` and `B`) are set up with different dispatch queue executors (`QA` and `QB`) but both target the same queue, dispatch could implement the `isSameExclusiveExecutionContext` method in such way that it returns true, based on the "target queue" information.

For reference, an executor is stored like this in the Swift runtime, as an `ExecutorRef`:

```swift
class ExecutorRef {
  HeapObject *Identity; // Not necessarily Swift reference-countable
  uintptr_t Implementation; // where we store our extra bit about "needs complexEquality"
  
  // We future-proof the ABI here by masking the low bits off the
  // implementation pointer before using it as a witness table.
  enum: uintptr_t {
    WitnessTableMask = ~uintptr_t(alignof(void*) - 1) // 3 bits
  };
}
```



The following explains how equality for the `assert`/`precondition` and `assume...ActorExecutor` is implemented.

We look at the type of the executor (the bit we store in the ExecutorRef, specifically in the Implementation / witness table field), and if both are:

- **unique**, today's semantics ("**ordinary**"), may be thought of as "**root**" 
  - creation:
    - using today's `UnownedSerialExecutor.init(ordinary:)` 
    - or a potentially new name for it `init(unique:)`
  - comparison:
    - compare the two executors pointers directly
      - return the result
  - notes:
    - Default actors
      - always have `Identity != 0` and `Implementation == 0`
      - thus comparing their Identity gives us the expected result; as every default actor is its own isolation domain
- **complexEquality**, maybe a good name would be "`cooperativeEquality`"?), may be throught of as "**inner**" (i.e. it is not just a root)
  - creation:
    - `UnownedSerialExecutor` creation sets bit in the `ExecutorRef` 
  - comparison:
    - If both executors are complexEquality, we **compare** the two executor **Identity** directly
      - if true, return (fast-path, same as the unique ones)
    - obtain and **compare** the **type** of both executors:
      -  `swift_getObjectType(executor1.Identity) == swift_getObjectType(executor2.Identity)`
      - if false, return
      - TODO: John mentioned a "compare the witness tables" but I didn't entirely follow about implementation, how we'd do that.
    - invoke the **executor implemented comparison** the `executor1.isSameExclusiveExecutionContext(executor2)`
      - TODO: We could make this `SerialExecutor.isSameExclusiveExecutionContext(executor1, executor2)` I think, but implementation wise not doing a static func was easier so for starters I did the simpler shape.
      - return



These checks are likely **NOT** enough to avoid switching, note from Rokhini:

> “Mutual exclusion context equality” in `swift_task_switch()` is most likely **not sufficient** for determining that we can safely just run code inline instead of executor switching for dispatch queues cause dispatch isn’t holding all of the correct locks in place, other work might have built up behind the queue, etc. 

## Proposal

1. We introduce the assert, precondition, assume APIs right now, along with the most basic existing custom actor executor API
   1. Aimed for Rainbow (SwiftData depends on it)
2. We follow up with the "**complexEquality**" additions
   1. if we make it for Rainbow, cool, if not, also okey
   2. it's just a caveat on these "queue targeting other queue" situations, which we'll improve later
3. Next, we continue towards the **switching support** in executors
   1. Unlikely to be in this release, but we started discussing the API shape which is good
   2. If we didn't do 2) by then, we can likely propose 2) and 3) together.