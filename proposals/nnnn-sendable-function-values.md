# Isolated Function Values and Sendable

- Proposal: [SE-NNNN](NNNN-filename.md)
- Authors: [Kavon Farvardin](https://github.com/kavon)
- Review Manager: TBD
- Status: **Awaiting implemention**
<!--
- Status: **Partially implemented in `main`**
  - [x] Drop global-actors when safe ([#62153](https://github.com/apple/swift/pull/62153))
  - [ ] Ban `@Sendable` methods in non-Sendable types
-->

## Introduction

This proposal is focused on a few corner-cases in the language surrounding functions as values when using concurrency. The goal is to improve flexibility, simplicity, and ergonomics without major changes to Swift.

## Motivation

The partial application of methods and other first-class uses of functions have a few rough edges when combined with concurrency. 

For example, today you can create a function-value representing an actor's method by writing an expression that only accesses (but does not call) a method using one of its instances. More precisely, this access is referred to as a "partial application" of a method to one of its (curried) arguments, the object instance:

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

Partial-applications of object methods are allowed almost anywhere, but this is no ordinary method; it has actor-isolation. As of today, the partial-application of an actor-isolated method is  _not_ allowed if it appears in a context outside of that actor's isolation:

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

Part of the need for this limitation is that knowledge of the actor instance's isolation is effectively erased from the type signature when partially-applying the instance. A more advanced type system could possibly represent actor-instance isolated function types (see Alternatives considered), but there are simpler ways to lift that restriction.

Conceptually, a similar limitation comes up when there is a desire to perform a conversion that _removes_ the `@MainActor` from a function type that already has it. Since it is generally unsafe to do so, the compiler emits a warning, such as in this example:

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

In [SE-302](0302-concurrent-value-and-concurrent-closures.md), the `@Sendable` attribute was introduced for both closures and named functions/methods. For a function, the attribute primarily influences the kinds of values that can be captured by the function. But methods of a nominal type do not capture anything but the object instance itself. Semantically, a method can be thought of as being represented by the following functions:

```swift

// this pseudo-code declaration:
type NominalType {
  func method(ArgType) -> ReturnType { /* body of method */ }
}

// can desugar to these two global functions:

func NominalType_method_partiallyAppliedTo(_ obj: NominalType) -> ((ArgType) -> ReturnType) {
  let inner = { [obj] (_ arg1: ArgType) -> ReturnType in
      return NominalType_method(obj, arg1)
  }
  return inner
}

func NominalType_method(_ self: NominalType, _ arg1: ArgType) -> ReturnType {
  /* body of method */
}
```

Thus, the only way a partially-applied method is be `@Sendable` is if the `inner` closure were `@Sendable`, which is true if and only if the nominal type conforms to `Sendable`.

Furthermore, a non-local (i.e., a global or static) function cannot capture _anything_, because a reference to a global declaration is not considered a capture of that value. So, when referencing a method _without_ partially applying it via the expression `NominalType.method`, that function can be considered `@Sendable` regardless of the nominal type's conformance to `Sendable`:

```
// example:
// f here should be considered @Sendable, but currently is not.
let f: @Sendable (NominalType) -> ((ArgType) -> ReturnType) = NominalType.method
let obj = NominalType()
let g = f(obj)
```

To summarize, here are the proposed changes:

1. the inference of `@Sendable` for unapplied references to methods of a type.
2. the inference of `@Sendable` for partially-applied methods of a type, if that type conforms to `Sendable`.
3. the inference of `@Sendable` for when referencing non-local functions.
4. prohibition of marking methods `@Sendable` when the type they belong to is not `@Sendable`.
5. deprecation of explicitly marking the functions in (1-3) with the `@Sendable` attribute, as it is now automatically determined.

<!-- TODO: directing users to remove it will cause an ABI break if done naively! how should we handle that? I guess we can emit aliases for all symbols when back-deploying to Swift 5, but if it's only Swift 6 those symbols can go away?

What's lost here is an odd capability: if a library wants the type to privately conform to Sendable, and only selectively allow some methods to be @Sendable. For example:

```
public final class Gizmo {
  public func reset() {}
  @Sendable public func applier() {}
}

private extension SomeType: Sendable {}
```

I guess this lets API authors express that a Gizmo can only be used as an applier from
different actors, but can only be reset from the isolation context in which it was formed. Of course this requires their users to jump through
hoops to apply the method first and then share that function value.

Not sure why someone would want to do this, since the existance of `applier`
indirectly tells you its Sendable, just not according to the type system.
 -->

<!-- NOTE: concrete example of a race because of the hole addressed by (3).
This code emits no diagnostics with `-strict-concurrency=complete`:
```
class NominalType {
  var x = 0
  @Sendable func method() { 
    x += 1
  }
}
let obj = NominalType()
let g: @Sendable () -> Void = obj.method
Task.detached { g() }
g()
```
-->

### Partial-applications of actor-instance isolated methods

After [SE-338](0338-clarify-execution-non-actor-async.md), an `async` function that has no actor isolation is said to be `nonisolated` and within a distinct isolation domain. That distinct domain has an effect on whether a non-`Sendable` value can be passed to the function. For example, Swift marks the following function call as invalid because it would break the isolation of `ref`:

```swift
@Sendable func modifyElsewhere(_ r: MutableRef) async { 
  r.mutate()
}

actor MyActor {
  var ref: MutableRef = MutableRef()  // MutableRef is not Sendable

  func check() async {
    ref.mutate()
    await modifyElsewhere(ref) // warning: non-sendable type 'MutableRef' exiting actor-isolated context in call to non-isolated global function 'modifyElsewhere' cannot cross actor boundary
  }
}
```

The isolation is broken here, because while awaiting the call to `modifyElsewhere`, another task can enter `MyActor.check` and mutate the `ref`. That's because `modifyElsewhere` runs on a seperate executor.

When used as a first-class value, the type of `modifyElsewhere` will be `@Sendable (MutableRef) async -> ()`. But as discussed previously, the true isolation of an `actor` instance cannot currently be described in a function's type, as it is dependent upon a dynamic value in the program. Without any way to distinguish these kinds of values, type confusions can happen:

```swift
extension MyActor {
  func update(_ ref: MutableRef) { ref.mutate() }
  
  func confusion(_ g: @Sendable (MutableRef) async -> ()) async {
    let f: (MutableRef) async -> () = self.update
    
    let ref = MutableRef()
    await f(ref) // Want this to be OK,
    await g(ref) // but this to be rejected.
  }
}

func pass(_ a: MyActor) async {
  await a.confusion(modifyElsewhere)
}
```

In the example above, the call to `g` should raise an error about passing a non-Sendable value from an actor-isolated domain into a non-isolated one. That fact can only be inferred based on the `async` in the type of parameter `g`, which has no other isolation listed. But if we raise that error based on the types alone, then the call to `f` would also be an error, despite not actually crossing actors! As of today, the example above raises no diagnostics in Swift, despite having a race.

>**Proposed Solution:** Partial-applications of actor-instance isolated functions are only permitted if the method's argument and return types all conform to `Sendable`.

The proposed solution adds a safety check when producing a first-class function value from an actor-instance isolated method. The check is the same one that would be performed if that method were called from a non-isolated context. By performing this check when producing partial applications of the method, we ensure that no matter where the function is eventually called, it is will be used safely.

One benefit of this solution is that it is now safe pass these partial-applications around. That is, we can lift the current restriction that partial-applications of actor-instance isolated methods only appear within isolated contexts. Since all actor types are `Sendable`, these partial-applications are also `@Sendable` functions.

To summarize, here are the proposed changes for actor-instance isolated methods:

1. their partial-applications are only permitted if the input and return types all conform to `Sendable`.
2. their partial-applications can appear in any isolation context.
3. their partial-applications result in `async` functions (with `throws` if it is a distributed actor) that are `@Sendable`.

<!-- Side-effect: we can remove this weird warning, though I don't know if it's just a bug or what:

But, Swift does raise a diagnostic if we reference `modifyElsewhere` within an actor-instance isolated context, even if we never call it:

```
extension MyActor {
  func justBindIt() async {
    let h: @Sendable (MutableRef) async -> () = modifyElsewhere
    //                                          ^~~~~~~~~~~~~~~
    // warning: non-sendable type 'MutableRef' exiting actor-isolated context in call to non-isolated global function 'modifyElsewhere' cannot cross actor boundary
    await recieveFunc(h)
  }
}

func recieveFunc(_ h: @Sendable (MutableRef) async -> ()) async {}
```
-->


### Global-actors and function types

For methods that are isolated to a global-actor, partial applications of those methods can carry their underlying isolation in the resulting function. But, as discussed in the Motivation, there are still situations where losing or dropping the global-actor isolation from a function's type is useful. In addition, there are scenarios where adding a global actor is unsafe or misleading.

#### Dropping global actors from function types

When there is a need to convert a function's type from one which has a global-actor in it, to one that does not, then we can do so safely in various circumstances. In the general case, it's only safe to perform the conversion if:

1. The function's type becomes `async`.
2. The function's argument and return types must conform to `Sendable`.

> **Rationale:** This is no different than the conundrum for partial-applications of actor-instance isolated methods. By removing the isolation from the type, we must apply the same rules to ensure the function can be called anywhere.

But, we can do better for global-actors  if the resulting function's type will also drop `@Sendable` (or does not have it), then we can be more flexible

If the context in which the conversion appears is _not_ isolated to `G`, then the conversion is unsafe: it removes 

bahhhhh <!-- stopped here -->

<!--
But there is just one additional scenario where we can safely drop the global-actor in a situation where the function value _cannot_ be converted to `@isolated`:

**Extra Rule for Dropping Global-actor:**
- The context must be isolated to the same actor.
- The function is _not_ `async`.
- The function is _not_ `@Sendable`.

Here is an example of a type conversion that relies on this Extra Rule:

```swift
@GlobalActor func example(_ f: @GlobalActor (T) -> V) {
  let g = f as (T) -> V
  sameDomain(g)
}
```

Each aspect of this Extra Rule serves an important purpose. First, the value must already be in the same isolation domain as the global-actor being dropped, otherwise we could not guarantee the isolation. Next, if the function is `async`, then dropping the global-actor is incorrect, because the resulting type would be inferred to be `nonisolated`. Finally, the function cannot be `@Sendable` or else it could transit into a different domain, where non-Sendable values could be smuggled in or out.
-->

<!--
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
-->

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
2. Given an `async` function type where its argument and return types are `Sendable`, writing a global-actor on the type is considered redundant.

Keep in mind that `async` functions with `Sendable` argument/return types are still allowed to be isolated to a global actor. The isolation attribute can simply be dropped from its type whenever it is desired. Take this for example:

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

Swift will suggest removing the `@MainActor` in the type of the `withFetcher` parameter, since its argument and return types are `Sendable`. Any function such as `mainActorFetcher` passed to it will be implicitly cast to drop its `@MainActor`, despite not being in a context isolated to that actor (i.e., `@isolated` does not apply).

<!--
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

But the types above are invalid, because after partial application, the type can be confused with a function that is simply `async` and `nonisolated`. This is the same rule as the one for exchanging `@isolated` for `@Sendable`, but during the reference. to the function.

Next, we have a situation where, even when we _can_ accurately represent the isolation of the function value in its type, because the function value _itself_ is not `@Sendable`, the function is uncallable!

```swift
// accurate types for references originating from a `nonisolated` context, but the functions are unusable!
PG.isoTakingNonSendable      : @Sendable (PG) -> (@MainActor (NonSendableType) -> V)
PG.asyncIsoTakingNonSendable : @Sendable (PG) -> (@MainActor (NonSendableType) async -> V)
```

Because `PG` represents a non-`Sendable` type with global-actor isolated methods, partial applications of these methods are _not_ `@Sendable`, because they always are assumed to capture the object instance. That instance is not `Sendable` and originates from an arbitrary isolation context. Thus, when references to these methods originate from a `nonisolated` context, we cannot pass the function value to a `@MainActor` context, which is the only context that can pass an argument to it!

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

Prior to this proposal, Swift did allow partial-applications of isolated methods from a matching isolation context. Thus, our goal is to only enhance the generality of those references while preserving all prior uses that were safe. We achieve this in-part through the `@isolated` attribute.

Here is the list of types that will be inferred when the method is referenced in a context that has matching isolation:

```swift
I.nonIsoTakingNonSendable   : @Sendable (I) -> (@Sendable (NonSendableType) -> V)
I.isoTakingNonSendable      : @Sendable (isolated I) -> (@isolated (NonSendableType) -> V)
I.asyncIsoTakingNonSendable : @Sendable (isolated I) -> (@isolated (NonSendableType) async -> V)
I.isoTakingSendable         : @Sendable (isolated I) -> (@isolated (V) async -> V))

G.nonIsoTakingNonSendable   : @Sendable (G) -> (@Sendable (NonSendableType) -> V)
G.isoTakingNonSendable      : @Sendable (isolated G) -> (@isolated (NonSendableType) -> V)
G.asyncIsoTakingNonSendable : @Sendable (isolated G) -> (@isolated (NonSendableType) async -> V)
G.isoTakingSendable         : @Sendable (isolated G) -> (@isolated (V) -> V)

PG.nonIsoTakingNonSendable   : @Sendable (PG) -> ((NonSendableType) -> V)
PG.isoTakingNonSendable      : @Sendable (PG) -> (@MainActor (NonSendableType) -> V)
PG.asyncIsoTakingNonSendable : @Sendable (PG) -> (@MainActor (NonSendableType) -> V)
PG.isoTakingSendable         : @Sendable (PG) -> (@MainActor (V) -> V)
```

TODO: this is wrong, it's actually OK to capture in a partial application because `Sendable` was already enforced on the caller. It's OK to capture non-Sendable values as long as the isolation matches:

```swift
@MainActor func getPlusOneMethod(_ instance: NonSendableType) -> (@Sendable @MainActor () -> ()) {
  return {
    instance.x += 1
  }
}
```

Casts to make these function values `@Sendable` within its own isolation domain are possible by the rules for exchanging `@isolated`. These exchanges will automatically happen if the value passed across actors, or if there is an explicit coercion to `@Sendable`.

-->

## Source compatibility

This proposal highlights at least one source break for the type confusion between `async` functions. This will need to become an error diagnostic eventually, but will start as a warning until Swift 6 to provide time for fixes. The rules about dropping a global actor from function types as being redundant will at most be a warning about the redundancy with a fix-it to delete the global actor.

## Effect on ABI stability

None.

## Effect on API resilience

None.

## Alternatives considered

Herein lies some ideas cut, discarded, or deferred from this proposal.

### Forced discarding of non-Sendable return values.

We could loosen some of the rules about `Sendable` return types in Swift if we
added a rule stating that if the return value is non-Sendable and crosses an
actor's boundary, the value is required to be discarded. For example, this rule
would eliminate diagnostics in the following situations:

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
  // This would remain banned unless we had forced-discarding.
  let discardOnly = balancer as () async -> (MutableRef) 
  _ = await discardOnly()
}

class StatusRef { var status = 0 }

// awaiting the completion of a Task with a non-Sendable result would become possible.
@MainActor func example(_ t: Task<StatusRef, Never>) async {
  // warning: non-sendable type 'Result<StatusRef, Never>' in asynchronous access from main actor-isolated context to non-isolated property 'result' cannot cross actor boundary
  _ = await t.result
}
```

### Introduce a way to track actor-instance isolation in function types

This idea was cut because it's a rather sophisticated type system enrichment that has a low expressivity-to-complexity ratio. Nevertheless, here it is:

A new type-level attribute `@isolated` is proposed to distinguish functions that are isolated to the actor whose context in which the value resides. Any uses of an `@isolated` function will rely on the location in which that value is bound to determine its isolation.

Let's see how this can be helpful for our example. The partial-application `self.update` will now yield a value of type `@isolated (MutableRef) -> ()`, which can then be converted to `@isolated (MutableRef) async -> ()` by the usual subtyping rules. Now the type checker can then correctly distinguish the two calls when performing `Sendable` checking on the argument:

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

Notice that `g` is bound as a parameter of `distinction`, which is isolated to the actor instance. That means the `@isolated` in `g`'s type refers to the actor instance in that method. When checking whether it is safe to pass `ref`, we now know `f` is safe and `g` is not. We could also store an `@isolated` function in the instance's isolated storage, like this:

```swift
actor Responder {
  private var takeAction : @isolated (Request) -> Response

  func denyAll(_ r: Request) -> Response { /* ... */ }

  func changeState() {
    // ...
    takeAction = denyAll
  }
  
  func handle(_ r: Request) -> Response {
    return takeAction(r)
  }

  func handleAll(_ rs: [Request]) -> Response {
    return rs.map(takeAction)
  }
}
```

Because the declaration `takeAction` is isolated and itself serves as the location of a value of type `@isolated`, any values stored there have the same isolation as the declaration. The rules about `@isolated` are as follows:

- The isolation of a value of type `@isolated` matches the isolation of the declaration in which it resides. A value bound to an identifier is said to _reside_ in the context of that binding, otherwise, an expression producing a value resides in the context that evaluates the expression.
- A function value with `@isolated` type is produced when a function is used as a first-class value and all of the following apply:
  - The function is isolated to an actor.
  - The isolation of the function matches the evaluation context of the first-class use.
- An function type that is `@isolated` is mutually exclusive with the following type attributes:
  - `@Sendable`
  - any global-actor
- A function value whose type contains global-actor `@G`, and appears in `G`'s isolation domain can be cast to or from `@isolated`.
- An `@isolated` type cannot appear on a binding that is not in an isolated context.
- An `@isolated` value cannot cross isolation domains without performing that removes the attribute.

> **Rationale:** The purpose of `@isolated` is to track first-class functions that are isolated to the same actor as the context in which the value appears. It ensures the function has never left the isolation. That is why `@Sendable` must be mutually-exclusive with `@isolated`. Once an `@isolated` function tries to leave the isolation domain, it must lose the `@isolated` attribute and cannot gain it back.

**Rule for Dropping `@isolated`:**
- If the function is `async`, then its argument and return types must conform to `Sendable`.
- Otherwise, the attribute can be dropped.

Once an attempt is made to pass an `@isolated` method across isolation domains, it must become `@Sendable`. This follows directly from rules about actor-isolation: whether an argument passed to an actor-isolated function is required to be `Sendable` depends on the isolation of the context in which the call appears. Since we cannot statically reason about the context in which a `@Sendable` function will be invoked, we have the following rule:

**Rule for Exchanging `@isolated` for `@Sendable`:**
- The function becomes `async`.
- If the function is isolated to a distributed actor, then it also gains `throws`.
- The function's argument and return types must conform to `Sendable`.

> **Rationale:** For a normal call to a non-async method of an actor from a different isolation domain, you must `await` as it is implicitly treated as an `async` call (and `throws` for distributed actors) because actors are non-blocking. To maintain isolation principles once isolation information is lost, the argument and return types of an actor-isolated function must also conform to `Sendable`.

## Changelog

- After [Pitch 1](https://forums.swift.org/t/pitch-isolated-function-values-and-sendable/61046):
  - Moved discussion of `@isolated` function types to Alternatives considered.

## Acknowledgments

This proposal has benefited from discussions with Doug Gregor and John McCall.
