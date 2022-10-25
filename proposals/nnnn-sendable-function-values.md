# Function Values and Sendable

- Proposal: [SE-NNNN](NNNN-filename.md)
- Authors: [Kavon Farvardin](https://github.com/kavon)
- Review Manager: TBD
- Status: **Awaiting implementation**

## Introduction

This proposal is focused on a few corner-cases in the language surrounding functions as values when using concurrency. The goal is to improve flexibility, simplicity, and ergonomics without major changes to Swift.

## Motivation

The partial application of methods and other first-class uses of functions have a few rough [edges](https://forums.swift.org/t/sendable-func-on-sendable-types/60708) when combined with concurrency. For example, today you can create a function-value representing an actor's method by writing an expression that only accesses (but does not call) a method using one of its instances. More precisely, this access is referred to as a "partial application" of a method to one of its (curried) arguments, the object instance. One can think of `StatefulTransformer.transform`'s type signature as being `(isolated StatefulTransformer) -> ((Data) -> Data)` to support partial applications:

```swift
typealias Data = Int

extension StatefulTransformer: AnyActor {   
  func transform(_ x: Data) -> Data { /* ... */ }
         
  func insideIsolationExample() -> [Data] {
    let f: (Data) -> Data = self.transform 
    //                      ^~~~~~~~~~~~~~
    //                      a partial-application of `self` to `transform`
    return [4, 8, 15, 16, 23, 42].map(f)
  }
}
```

Partial-applications of object methods are allowed almost anywhere, but this is no ordinary method. As of today, the partial-application of an actor-isolated method is  _not_ allowed if it appears in a context outside of that actor's isolation:

```swift
extension StatefulTransformer {
	// a nonisolated method trying to partially-apply an isolated method
  nonisolated func outsideIsolationExample() -> [Data] {
    let _: (Data) -> Data = self.transform
    //                      ^~~~~~~~~~~~~~
    // error: actor-isolated instance method 'transform' can not be partially applied
	}
}
```

Part of the need for this limitation is that knowledge of the isolation is effectively erased from the type signature when partially-applying the actor instance. That knowledge is required for non-async isolated methods, as their runtime representation cannot encode isolation enforcement alone. But, the limitation is not a fundamental barrier. It is feasible to create a `@Sendable` version of a partially-applied non-async actor method, by representing it with an `async` function value.

Conceptually, a similar limitation comes up when performing a conversion that removes the `@MainActor` from a function type. Since it is generally unsafe to do so, the compiler emits a warning, such as in this example:

```swift
@MainActor func dropMainActor(_ f: @MainActor (Data) -> Data) -> [Data] {
  return [4, 8, 15, 16, 23, 42].map(f)
  // warning: converting function value of type '@MainActor (Data) -> Data' to '(Data) throws -> Data' loses global actor 'MainActor'
}
```

But not all situations that drop the global-actor from a function value are unsafe. In the example above, the conversion that loses the global-actor happens while already on the same actor. By the same logic as our actor-method example, this should be safe if we do not allow that casted function to later leave the MainActor's isolation.

These and other aspects of how Sendable and actor isolation interact with function values are the focus of this proposal.

## Proposed solution

This section provides a summary of the solutions and changes proposed for Swift. For complete details and caveats, see the Detailed design.

### Inferring `@Sendable` for methods

In [SE-302](0302-concurrent-value-and-concurrent-closures.md), the `@Sendable` attribute was introduced for both closures and named functions/methods. Beyond allowing the function value to cross actor boundaries, the attribute primarily influences the kinds of values that can be captured by the function. But methods of a nominal type cannot capture anything but the object instance itself. Furthermore, a non-local (i.e., a global or static) function cannot capture _anything_, because a reference to a global declaration is not considered a capture of that value. Thus, the proposed simplifications are:

1. the inference of `@Sendable` on all methods of a type that conforms to `Sendable`.
2. the inference of `@Sendable` on all non-local functions.
3. the prohibition of marking a method `@Sendable` if the object type does not conform to `Sendable`.

### Sendable `actor` methods

Since all `actor` types are `Sendable`, their methods will also be considered `@Sendable` as part of the earlier proposed rules. The subtle complication is that, a `@Sendable` function is not required to have argument and return types that conform to `Sendable`. That is a rule about actor-isolation: whether an argument passed to an actor-isolated function is required to be `Sendable` depends on the isolation of the context in which the call appears.

Up until now, the isolation of _the context_ in which a call to an isolated method appears has been statically known, because partial-applications of those methods were not `@Sendable`. Barring major extensions to the language, we cannot statically infer anything about the context in which a `@Sendable` version will eventually be called. As a result, those function values must:

1. Carry `async` and/or `throws` in its type.
2. Have its arguments and return type all conform to `Sendable`.

> **Rationale:** Even for a normal call to a non-async method of an actor from a different isolation domain, you must `await` as it is implicitly treated as an `async` call (and `throws` for distributed actors) because actors are non-blocking. To maintain isolation principles, the argument and return types of an actor-isolated function must also conform to `Sendable`. Thus, these proposed rules for partially-applied methods mirror the ones for the fully-applied case in a `nonisolated` context.

### Introducing `@isolated` function types

After [SE-338](0338-clarify-execution-non-actor-async.md), an `async` function that has no actor isolation is said to be `nonisolated`, which is a distinct isolation domain. That distinct domain has an effect on whether a non-`Sendable` value can be passed to the function. For example, Swift flags the following function call as invalid because it would break the isolation of `ref`:

```swift
func inspect(_ r: MutableRef) async { /* ex: creates a concurrent task to update r */ }

actor MyActor {
  var ref: MutableRef = MutableRef()  // MutableRef is not Sendable

  func check() {
    inspect(ref) // warning: non-sendable type 'MutableRef' exiting actor-isolated context in call to non-isolated global function 'inspect' cannot cross actor boundary
  }
}
```

When used as a first-class value, the type of `inspect` will be `@Sendable (MutableRef) async -> ()`. If `inspect` were passed in as an argument instead, we can still accurately determine whether to reject the call based on the type. Since there is no isolation listed in the type signature, it must be `nonisolated`. But as discussed previously, the true isolation of an `actor` instance cannot be represented in a function's type, as it is dependent upon a dynamic value in the program. Without any way to distinguish these kinds of values, type confusions can happen:

```swift
extension MyActor {
  func update(_ ref: MutableRef) { /* ... */}
  
  func test(_ g: @Sendable (MutableRef) async -> ()) async {
    let f: (MutableRef) async -> () = self.update
    
    let ref = MutableRef()
    await f(ref) // Want this to be OK,
    await g(ref) // but this to be rejected.
  }
}
```

The example above is currently accepted by Swift with no diagnostics about the incorrect sharing of `ref`. Both `f` and `g` have effectively the same type, but only one of their uses is correct. 

To solve this type confusion, a new type-level attribute `@isolated` is proposed to distinguish functions that are isolated to _some_ actor. Here are some of the rules about this attribute:

- An `@isolated` function value is only created after the partial-application of an actor-instance isolated method.
- An `@isolated` function type cannot be both `@isolated` and `@Sendable`.

To solve the type confusion above, the partial-application `self.update` will yield a value of type `@isolated (MutableRef) -> ()`, which can then be converted to `@isolated (MutableRef) async -> ()`.

<!-- TODO: Can I go from @isolated -> Sendable, since we know all actor instances are Sendable? -->
<!-- TODO: @isolated (SomeOtherActor) async -> () is quite easy to visually confuse with (isolated SomeOtherActor) async -> () -->

### Global-actors and function types

Global actors represent isolation that depends on a fixed, well-known instance of an actor. Swift can express the isolation of a function value to a global actor in its type system. As discussed in the Motivation, there are situations where dropping the global actor from a function type is safe and useful. In addition, there are scenarios where adding a global actor is unsafe or misleading.

#### Dropping global actors from function types

For methods that are isolated to a global-actor, partial applications of those methods do not need to erase the isolation from the type. Thus, a `@Sendable` partially-applied method that is isolated to a global-actor is not _required_ to carry `async` in its type. Nor is it required to have `Sendable` input and output types. But, there are still situations where losing or dropping the global-actor isolation from a function's type is useful. The proposed rules for when it's safe to perform such a conversion resemble the actor-instance isolation case:

1. When within a matching isolation domain, it is permitted to simply drop the global-actor if the function type is not `@Sendable`, when any of the following are true:
  - the function is non-async.
  - the function is `async` and the argument and return types are `Sendable`.
2. In all other cases, the global actor in its type is exchanged for becoming `async` and having `Sendable` argument/return types.

Here are a few example type conversion chains that rely on these rules, where all intermediate steps are shown:

```swift
// Example 1 - matching context isolation.
@GlobalActor func ex1(_ a: @Sendable @GlobalActor (T) -> V) {
  let b = a as @GlobalActor (T) -> V  // by subtyping of @Sendable functions
  let c = b as (T) -> V               // because we are in GlobalActor's isolation
  use1(c)
}

// Example 2 - non-matching context isolation.
func ex2(_ x: @Sendable @GlobalActor (T) -> V) {
  let y = x as @Sendable (T) async -> V // only if T: Sendable and V: Sendable
  use2(y)
}

// Example 3 - `async` can prevent dropping the actor in some cases.
@MainActor 
func balanceData(withBalancer balancer: @MainActor (MutableRef) async -> ()) async {
  // This cast will be rejected because MutableRef is not a Sendable type.
  let unusable = balancer as (MutableRef) async -> ()
  unusable(MutableRef()) // error: cannot pass non-Sendable value 'MutableRef' to nonisolated function.
}
```

Example 3 in particular is quite interesting. The cast of `balancer` cannot be allowed because it would produce a function value that is completely unusable. Since `MutableRef` is not a `Sendable` type, there is currently no way for the `MainActor` to pass a value to it. It cannot even be passed to a `nonisolated` context which _could_ pass an argument to it, because the function value itself is also not `@Sendable`.

#### Adding global actors to function types

On the other side, there are some issues with casts that _add_ a global actor to an `async` function type. Consider this function, which attempts to run an `async` function on the `MainActor`:

```swift
@MainActor func callOnMainActor(_ f: @escaping (Data) async -> Data) async -> Data {
  let d = Data()
  let withMainActor: @MainActor (Data) async -> Data = f
  return await withMainActor(d)
}
```

If `Data` is not a `Sendable` type, then the conversion is unsafe and must be prohibited. Otherwise, it would allow non-Sendable values to leave the `MainActor` into a `nonisolated` domain. The only safe conversions of `async` functions that add a global actor are those whose argument and return types are `Sendable`. But then, that conversion serves no purpose: the executor or underlying actor of an `async` function cannot be changed through casts due to [SE-338](0338-clarify-execution-non-actor-async.md).

This proposal aims to clear up this confusion and make it safe by proposing two rules that, when combined with the rest of this proposal, yield an overall safety improvement and simplification of the language:

1. Casts that add a global actor to an `async` function type are prohibited.
2. Writing an `async` function type with a global actor is not permitted if its argument and return types are `Sendable`.

Overall, this simplification says that the only scenario where an `async` function needs to have a global actor in its type signature is when its argument and/or return type is _not_ `Sendable`. Keep in mind that `async` functions _with_ `Sendable` argument/return types are still allowed to be isolated to a global actor. The attribute can simply be dropped from its type whenever it is used as a first-class value. Take this for example:

```swift
extension SendableData: Sendable {}

@MainActor func mainActorFetcher() -> SendableData async { /* ... */ }

func processRequests(withFetcher fetchData: @MainActor () async -> SendableData) async {
  //                                        ^~~~~~~~~~
  // proposed change: the global-actor in this type is not required because SendableData is Sendable

  let next = await fetchData()
}

func doWork() async {
  // this cast to drop the MainActor is now allowed by this proposal,
  // and is only explicitly written here for clarity.
  let obtainer: () async -> SendableData = mainActorFetcher
  await processRequests(withFetcher: obtainer)
}
```

Swift will suggest removing the `@MainActor` in the type of the `withFetcher` parameter, since its argument and return types are `Sendable`. Any function such as `mainActorFetcher` passed to it will be implicitly cast to drop its `@MainActor`.


## Detailed design

In an attempt to leave no stone unturned, we now analyze the most general types of various methods based on the isolation context in which they are referenced. The following code example will serve as a vehicle for this discussion. It defines three nominal types, each one having different kinds of actor isolation, Sendable conformance, and asynchrony:

```swift
actor I { // 'I' stands for actor-instance isolation
  nonisolated func nonIsoTakingNonSendable(_: NonSendableType) -> V
  func isoTakingNonSendable(_: NonSendableType) -> V
  func asyncIsoTakingNonSendable(_: NonSendableType) async -> V
  func isoTakingSendable(_: V) -> V
}

@MainActor
class G { // 'G' stands for global-actor isolated
  nonisolated func nonIsoTakingNonSendable(_: NonSendableType) -> V
  func isoTakingNonSendable(_: NonSendableType) -> V
  func asyncIsoTakingNonSendable(_: NonSendableType) async -> V
  func isoTakingSendable(_: V) -> V
}

class PG { // 'PG' stands for pinned global-actor isolated (i.e., non-Sendable)
  func nonIsoTakingNonSendable(_: NonSendableType) -> V
  @MainActor func isoTakingNonSendable(_: NonSendableType) -> V
  @MainActor func asyncIsoTakingNonSendable(_: NonSendableType) async -> V
  @MainActor func isoTakingSendable(_: V) -> V
}

extension V: Sendable {} // assume V is a Sendable type
```

In the following subsections, we list the most-general type signatures for each
method as a curried function to make clear what the partially-applied type will be.

## References from a differing isolation context

This section details the kinds of partial-applications that will be possible when the an isolation context of the reference differs from the isolation of the method. Without loss of generality, you can think of this section as covering the case of partial-applications that happen within a `nonisolated` context.

Not all isolated methods can be partially-applied in a `nonisolated` context. Consider the isolated methods of an actor-instance that have a non-`Sendable` type in its function signature. The most accurate way to describe the type of these methods would be:

```swift
// invalid types for references originating from a `nonisolated` context.
I.isoTakingNonSendable : @Sendable (isolated A) -> (@Sendable (NonSendableType) async -> V))
I.asyncIsoTakingNonSendable : @Sendable (isolated A) -> (@Sendable (NonSendableType) async -> V))
``` 

But the types above are invalid, because after partial application, the type can be confused with a function that is simply `async` and `nonisolated`. That matters because the argument type is not `Sendable`. The same principle applies to a full-application of these methods, because the argument couldn't be sent across actors.

Next, we have a situation where, even when we _can_ accurately represent the isolation of the function value in its type, because the function value _itself_ is not `@Sendable`, the function is uncallable!

```swift
// accurate types for references originating from a `nonisolated` context, but the functions are unusable!
PG.isoTakingNonSendable      : @Sendable (PG) -> (@MainActor (NonSendableType) -> V)
PG.asyncIsoTakingNonSendable : @Sendable (PG) -> (@MainActor (NonSendableType) async -> V)
```

Because `PG` represents a non-`Sendable` type with global-actor isolated methods, partial applications of these methods are _not_ `@Sendable`, because they always are assumed to capture the object instance. Thus, when references to these methods originate from a `nonisolated` context, we cannot pass the function value to a `@MainActor` context, which is the only context that can pass an argument to it!

Here is the full listing of types if the methods were referenced from a `nonisolated` context:

```swift
I.nonIsoTakingNonSendable   : @Sendable (I) -> (@Sendable (NonSendableType) -> V)
I.isoTakingNonSendable      : ⊥  // not accessible
I.asyncIsoTakingNonSendable : ⊥  // not accessible
I.isoTakingSendable         : @Sendable (isolated I) -> (@Sendable (V) async -> V))

G.nonIsoTakingNonSendable   : @Sendable (G) -> (@Sendable (NonSendableType) -> V)
G.isoTakingNonSendable      : @Sendable (G) -> (@Sendable @MainActor (NonSendableType) async -> V)
G.asyncIsoTakingNonSendable : @Sendable (G) -> (@Sendable @MainActor (NonSendableType) async -> V)
G.isoTakingSendable         : @Sendable (G) -> (@Sendable (V) async -> V)

PG.nonIsoTakingNonSendable   : @Sendable (G) -> ((NonSendableType) -> V)
PG.isoTakingNonSendable      : ⊥  // not accessible
PG.asyncIsoTakingNonSendable : ⊥  // not accessible
PG.isoTakingSendable         : @Sendable (G) -> (@MainActor (V) -> V)
```

The first thing to note is `I.isoTakingSendable`, which despite being declared as a non-`async` function, when it is referenced from a `nonisolated` context, will return an `async` function. If `I` were a distributed actor type, then the returned function would additionally be `throws`.

Furthermore, `G.isoTakingSendable` can return an `async` function that does not carry `@MainActor`, because it is not needed when `V` is `Sendable`. This is in contrast with `PG.isoTakingSendable`, which does not return a `@Sendable` function, thus a non-`async` function carrying the needed isolation is the most general.


## References from a matching isolation context

Prior to this proposal, Swift did allow partial-applications of isolated methods from a matching isolation context.Thus, our goal is to only enhance the generality of those references by making partial applications `@Sendable` when doing so will not introduce a source break. This is possible because a `@Sendable` function is a subtype of a non-`Sendable` function.

Why not keep things uniform and have all partially-applied methods be `@Sendable` if their object instance is `Sendable`? It is not always possible or desirable to make the resulting function `@Sendable`, because that can drastically change the type, i.e., it can become `async` as for the differing isolation case. Otherwise, if those scenarios do not apply, inferring `@Sendable` on the function will not yield a source break thanks to subtyping.

For the methods above, we list the most general types that will be inferred by default:

```swift
I.nonIsoTakingNonSendable   : @Sendable (I) -> (@Sendable (NonSendableType) -> V)
I.isoTakingNonSendable      : @Sendable (I) -> (@isolated (NonSendableType) -> V)
I.asyncIsoTakingNonSendable : @Sendable (I) -> (@isolated (NonSendableType) async -> V)
I.isoTakingSendable         : @Sendable (I) -> (@isolated (V) async -> V))

G.nonIsoTakingNonSendable   : @Sendable (G) -> (@Sendable (NonSendableType) -> V)
G.isoTakingNonSendable      : @Sendable (G) -> (@Sendable @MainActor (NonSendableType) -> V)
G.asyncIsoTakingNonSendable : @Sendable (G) -> (@Sendable @MainActor (NonSendableType) async -> V)
G.isoTakingSendable         : @Sendable (G) -> (@Sendable @MainActor (V) -> V)

PG.nonIsoTakingNonSendable   : @Sendable (PG) -> ((NonSendableType) -> V)
PG.isoTakingNonSendable      : @Sendable (PG) -> (@MainActor (NonSendableType) -> V)
PG.asyncIsoTakingNonSendable : @Sendable (PG) -> (@MainActor (NonSendableType) -> V)
PG.isoTakingSendable         : @Sendable (PG) -> (@MainActor (V) -> V)
```

Casts to make these function values `@Sendable` within its own isolation domain must happen on the expression performing the partial application. For example,

```swift
func doProcessing(_ f: @Sendable @MainActor (NonSendableType) async -> V)) async { /* ... */ }

extension G {
  func process() async {
    await doProcessing(self.isoTakingNonSendable) // OK. conversion will add @Sendable and `async`

    let x = self.isoTakingNonSendable
    await doProcessing(x) // error: cannot cast  
  }
}
```



## Source compatibility



## Effect on ABI stability


## Effect on API resilience

## Alternatives considered

Herein lies some ideas cut or discarded from this proposal.

### Forced discarding of non-Sendable return values.

We could loosen some of the rules about `Sendable` return types in Swift if we
added a rule stating that if the return value is non-Sendable and crosses an
actor's boundary, the value is required to be discarded. For example, this rule
would eliminate any diagnostics in the following examples:

```swift
func foreign() async -> MutableRef { return MutableRef() }

@MainActor func mainFn() async {
  await foreign() // warning: non-sendable type 'MutableRef' returned by call from main actor-isolated context to non-isolated global function 'foreign()' cannot cross actor boundary
}
```

```swift
// Dropping a global actor from an 'async' function, where only the return value
// is non-Sendable, would now be allowed.
@MainActor 
func balanceData(withBalancer balancer: @MainActor () async -> (MutableRef)) async {
  let discardOnly = balancer as () async -> (MutableRef)
  _ = discardOnly()
}
```

## Acknowledgments

This proposal has benefited from discussions with Doug Gregor and John McCall.