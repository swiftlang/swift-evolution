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

### Introducing `@isolated` function types

After [SE-338](0338-clarify-execution-non-actor-async.md), an `async` function that has no actor isolation is said to be `nonisolated` and within a distinct isolation domain. That distinct domain has an effect on whether a non-`Sendable` value can be passed to the function. For example, Swift marks the following function call as invalid because it would break the isolation of `ref`:

```swift
@Sendable func inspect(_ r: MutableRef) async { /* ex: creates a concurrent task to update r */ }

actor MyActor {
  var ref: MutableRef = MutableRef()  // MutableRef is not Sendable

  func check() async {
    await inspect(ref) // warning: non-sendable type 'MutableRef' exiting actor-isolated context in call to non-isolated global function 'inspect' cannot cross actor boundary
  }
}
```

When used as a first-class value, the type of `inspect` will be `@Sendable (MutableRef) async -> ()`. If `inspect` were bound in a `let`, we can still accurately determine whether to reject the call based on the type. Since there is no isolation listed in the type signature and it is `async`, it must be `nonisolated`. But as discussed previously, the true isolation of an `actor` instance cannot be represented in a function's type, as it is dependent upon a dynamic value in the program. Without any way to distinguish these kinds of values, type confusions can happen:

```swift
extension MyActor {
  func update(_ ref: MutableRef) { /* ... */}
  
  func confusion(_ g: @Sendable (MutableRef) async -> ()) async {
    let f: (MutableRef) async -> () = self.update
    
    let ref = MutableRef()
    await f(ref) // Want this to be OK,
    await g(ref) // but this to be rejected.
  }
}

func pass(_ a: MyActor) async {
  await a.confusion(inspect)
}
```

In the example above, the call to `g` should raise an error about passing a non-Sendable value from an actor-isolated domain into a non-isolated one. That fact is inferred purely based on the `async` in the type of `g` with no other isolation listed. But if we make that an error, then `f` would also be an error, despite not actually crossing actors! As of today, this example raises no diagnostics in Swift.

To solve this type confusion, a new type-level attribute `@isolated` is proposed to distinguish functions that are isolated to the actor whose context in which the value resides. Here are some of the rules about this attribute:

- A function value with `@isolated` type be produced when a function is used as a first-class value and all of the following apply:
  - The function is isolated to an actor.
  - The isolation of the function matches the context of the first-class use.
  - The function is `@Sendable`.
- An function type that is `@isolated` is mutually exclusive with the following type attributes:
  - `@Sendable`
  - any global-actor
- A function value whose type contains global-actor `@G`, is `@Sendable`, and appears in `G`'s isolation domain can be cast to or from `@isolated`.

> **Rationale:** The purpose of `@isolated` is to track first-class functions that are isolated to the same actor as the context in which the value appears. That is why `@Sendable` must be mutually-exclusive with `@isolated`. We could no longer infer anything about the `@isolated` function once it crosses actors, because the isolation described by the attribute must match its context. That is why it is impossible to cast a `@Sendable` function value to `@isolated`.

To solve the type confusion above, the partial-application `self.update` will always yield a value of type `@isolated (MutableRef) -> ()`, which can then be converted to `@isolated (MutableRef) async -> ()`. The type checker can then correctly distinguish the two calls when performing `Sendable` checking on the argument:

```swift
extension MyActor {
  func update(_ ref: MutableRef) { /* ... */}
  
  func distinction(_ g: @Sendable (MutableRef) async -> ()) async {
    let f: @isolated (MutableRef) async -> () = self.update
    
    let ref = MutableRef()
    await f(ref) // OK because `@isolated`
    await g(ref) // rejected.
  }
}
```

Going further, `@isolated` provides the needed capability to share partially-applied methods across actors, when it is safe to do so:

```swift
func ok(_ y: @Sendable (V) async -> ()) {}
func bad(_ x: @Sendable (MutableRef) async -> ()) {}

extension MyActor {
  func shareThem(_ h: @isolated (V) -> (), _ i: @isolated (MutableRef) -> ()) {
    ok(h) 
    bad(i) // error: cannot cast '@isolated (MutableRef) -> ()' to '@Sendable (MutableRef) async -> ()' because 'MutableRef' is not Sendable.
  }
}
```

Here, we know `h` is isolated to the actor-instance because of `MyActor.shareThem`'s isolation. In fact, the compiler can determine specifically _which instance_ of that type the function `h` must be isolated: it's the implicit (or explicit) parameter `self: isolated MyActor` currently in scope! By the existing rules about `Sendable` values, `h` must have been partially-applied to the exact same instance of `MyActor` as the one representing `self` in `shareThem`. For example, it could not have come from some other instance of `MyActor` because non-Sendable values cannot cross between different instances.

**Caveat:** It is tempting to believe that all actor-instance isolated functions are `@isolated` because they are `@Sendable`, but one can define an actor-instance isolated method that is not part of that `actor`'s type:

```swift
class PinnedClass {
  func instanceIso(_ a: isolated MyActor) -> V {}
}
```

Here, a partial-application of `PinnedClass.instanceIso` does _not_ yield a `@isolated` method, instead, it will yield a function that is isolated to its unfilled _parameter_, i.e., it will have type `(isolated MyActor) -> V` and is not `@Sendable` because `PinnedClass` is not `Sendable`.

#### Removing `@isolated` from a function's type

The core reason why `@isolated` function types can only be inhabited by `@Sendable` functions is to facilitate their conversion should the function need to cross isolation domains. The removal of `@isolated` is not required to add `@Sendable` and there are safe and useful places where this applies. Consider this:

```swift
func process(_ e: Element, _ f: (Element) -> ()) { /* ... */ }

func crunchNumbers(_ a: MyActor, _ es: [Element], _ cruncher: @isolated (Element) -> ()) {
  for e in es {
    process(e, es, cruncher)
  }
}
```

Here, because arguments passed to `process` do not cross domains, there's no need for it to become `@Sendable`. We can summarize the rules about dropping `@isolated` (_without_ adding `@Sendable`) as:

**Rule for Dropping `@isolated`:**
- If the function is `async`, then its argument and return types must conform to `Sendable`.

Once an attempt is made to pass an `@isolated` method across isolation domains, it must become `@Sendable`. But, there is a subtle complication: `@Sendable` functions are not required to have argument and return types that conform to `Sendable`. Yet, that extra requirement is needed to truly share an `@isolated` method across actors. This follows directly from rules about actor-isolation: whether an argument passed to an actor-isolated function is required to be `Sendable` depends on the isolation of the context in which the call appears. Since we cannot statically reason about the context in which a `@Sendable` function will be invoked, we have the following rule: 

**Rule for Exchanging `@isolated` for `@Sendable`:**
- The function becomes `async`.
- If the function is isolated to a distributed actor, then it also gains `throws`.
- The function's argument and return types must conform to `Sendable`.
- The original function must have been `@Sendable` (always true for `@isolated`)

> **Rationale:** For a normal call to a non-async method of an actor from a different isolation domain, you must `await` as it is implicitly treated as an `async` call (and `throws` for distributed actors) because actors are non-blocking. To maintain isolation principles once isolation information is lost, the argument and return types of an actor-isolated function must also conform to `Sendable`.

### Global-actors and function types

For methods that are isolated to a global-actor, partial applications of those methods can more simply state their exact isolation, rather than using `@isolated`. Thus, a `@Sendable` partially-applied method that is isolated to a global-actor is not _required_ to be `async`. Nor is it required to have `Sendable` input and output types. But, as discussed in the Motivation, there are still situations where losing or dropping the global-actor isolation from a function's type is useful. In addition, there are scenarios where adding a global actor is unsafe or misleading.

#### Dropping global actors from function types

Global-actors can also be dropped from a function's type by first implicitly converting it to `@isolated`, which will ensure the context matches _and_ the function is `@Sendable`. 
But there is one additional scenario where we can drop the global-actor when only the context matches:

**Extra Rule for Dropping Global-actor:**
- The function is _not_ `async`.
- The function is _not_ `@Sendable`.
- The context must be isolated to the same actor.

Here is an example of a type conversion that relies on this Extra Rule:

```swift
@GlobalActor func example(_ f: @GlobalActor (T) -> V) {
  let g = f as (T) -> V
  sameDomain(g)
}
```

Each aspect of this Extra Rule serves an important purpose. First, if the function is `async`, then dropping the global-actor is incorrect, as the Sendability of arguments to the function becomes ambiguous:

```
// Counter-example 1 - `async` can prevent dropping the actor.
@GlobalActor 
func balanceData(withBalancer balancer: @GlobalActor (MutableRef) async -> ()) async {
  // This cast will be rejected because MutableRef is not a Sendable type.
  let unusable = balancer as (MutableRef) async -> ()
  unusable(MutableRef()) // error: cannot pass non-Sendable value 'MutableRef' to nonisolated function.
}
```

For the same reason, the function cannot be `@Sendable`, because adding `async` while dropping the `@GlobalActor` would lead to the same ambiguity. Finally, if we drop the global-actor while in a differing context, then our `example` function above 

TODO: wait wouldn't our example basically lead to a totally unusable function too??

---

```swift
// Example 1a - matching context, initially @Sendable, _not_ required to be @Sendable.
@GlobalActor func ex1a(_ x: @Sendable @GlobalActor (T) -> V, 
                       _ a: @Sendable @GlobalActor (T) async -> V) {
  let y = x as @isolated (T) -> V // because we are in GlobalActor's isolation and it is @Sendable
  let z = y as (T) -> V

  let b = a as @isolated (T) async -> V // because we are in GlobalActor's isolation and it is @Sendable
  let c = b as (T) async -> V           // only if T: Sendable and V: Sendable

  sameDomain(z, c)
}

// Example 1b - matching context, initially @Sendable, required to be @Sendable.
@GlobalActor func ex1b(_ x: @Sendable @GlobalActor (T) -> V, 
                       _ a: @Sendable @GlobalActor (T) async -> V) async {
  let y = x as @Sendable (T) async -> V    // only if T: Sendable and V: Sendable

  let b = a as @Sendable (T) async -> V    // only if T: Sendable and V: Sendable
  
  await differentDomain(y, b)
}

// Exception for global-actors - matching context and not @Sendable can still drop the global actor, if
// the value is n
func ex2a(_ x: @Sendable @GlobalActor (T) -> V, 
          _ a: @Sendable @GlobalActor (T) async -> V) {
  let y = (T) -> V

  use2(y)
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

Why not keep things uniform and have all partially-applied methods be `@Sendable` if their object instance is `Sendable`? It is not always possible or desirable to make the resulting function `@Sendable`, because that can drastically change the type.

For the methods above, we list the most general types that will be inferred by default in a context that has matching isolation:

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

Casts to make these function values `@Sendable` within its own isolation domain are possible. The casts must happen on the expression performing the partial application. For example, you must coerce the type of the partial application to be `@Sendable` before it is bound to a variable:

```swift
func doProcessing(_ f: @Sendable (NonSendableType) async -> V)) async { /* ... */ }

extension G {
  func process() async {
    await doProcessing(self.isoTakingNonSendable) // OK. will be automatically coerced.

    let x = self.isoTakingNonSendable
    await doProcessing(x) // error: cannot cast '@isolated (NonSendableType) -> V' to '@Sendable (NonSendableType) async -> V'
  }
}
```

<!-- TODO: it might actually be feasible to allow a bunch of these casts now that we have @isolated. We can't support this:

@isolated (NonSendableType) async -> V  ==>  @Sendable (NonSendableType) async -> V

but we could support this:

@isolated (V) async -> V  ==>  @Sendable (V) async -> V

 -->


## Source compatibility

This proposal highlights at least one source break for the type confusion between `async` functions. This will need to become an error diagnostic eventually, but will start as a warning until Swift 6 to provide time for fixes. The rules about dropping a global actor from function types as being redundant will at most be a warning about the redundancy with a fix-it to delete the global actor.

## Effect on ABI stability

None.

## Effect on API resilience

None.

## Alternatives considered

Herein lies some ideas cut, discarded, or deferred from this proposal.

### Replace global-actors in function types with `@isolated`.

In a number of ways, it is tempting to 

### Forced discarding of non-Sendable return values.

We could loosen some of the rules about `Sendable` return types in Swift if we
added a rule stating that if the return value is non-Sendable and crosses an
actor's boundary, the value is required to be discarded. For example, this rule
would eliminate any diagnostics in the following situations:

```swift
func foreign() async -> MutableRef { return MutableRef() }

// Invoking `foreign` from a different actor would be possible:
@MainActor func mainFn() async {
  await foreign() // warning: non-sendable type 'MutableRef' returned by call from main actor-isolated context to non-isolated global function 'foreign()' cannot cross actor boundary
}

// Dropping a global actor from an 'async' function, where only the return value
// is non-Sendable, would now be allowed.
@MainActor 
func balanceData(withBalancer balancer: @MainActor () async -> (MutableRef)) async {
  let discardOnly = balancer as () async -> (MutableRef)
  _ = discardOnly()
}

class StatusRef { var status = 0 }

// awaiting the completion of a Task with a non-Sendable result would become possible.
@MainActor func example(_ t: Task<StatusRef, Never>) async {
  // warning: non-sendable type 'Result<StatusRef, Never>' in asynchronous access from main actor-isolated context to non-isolated property 'result' cannot cross actor boundary
  _ = await t.result
}
```

## Acknowledgments

This proposal has benefited from discussions with Doug Gregor and John McCall.
