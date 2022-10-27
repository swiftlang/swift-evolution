# Function Values and Sendable

- Proposal: [SE-NNNN](NNNN-filename.md)
- Authors: [Kavon Farvardin](https://github.com/kavon)
- Review Manager: TBD
- Status: **Awaiting implementation**

## Introduction

This proposal is focused on a few corner-cases in the language surrounding functions as values when using concurrency. The goal is to improve flexibility, simplicity, and ergonomics without major changes to Swift.

## Motivation

The partial application of methods and other first-class uses of functions have a few rough edges when combined with concurrency. For example, today you can create a function-value representing an actor's method by writing an expression that only accesses (but does not call) a method using one of its instances. More precisely, this access is referred to as a "partial application" of a method to one of its (curried) arguments, the object instance. One can think of `StatefulTransformer.transform`'s type signature as being `(isolated StatefulTransformer) -> ((Data) -> Data)` to support partial applications:

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

When used as a first-class value, the type of `inspect` will be `@Sendable (MutableRef) async -> ()`. If `inspect` were bound in a `let`, we can still accurately determine whether to reject the call based on the type. But as discussed previously, the true isolation of an `actor` instance cannot be accurately represented in a function's type, as it is dependent upon a dynamic value in the program. Without any way to distinguish these kinds of values, type confusions can happen:

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

In the example above, the call to `g` should raise an error about passing a non-Sendable value from an actor-isolated domain into a non-isolated one. That fact is inferred purely based on the `async` in the type of `g`, which has no other isolation listed. But if we raise that error based on the types, then `f` would also be an error, despite not actually crossing actors! As of today, this example raises no diagnostics in Swift.

To solve this type confusion, a new type-level attribute `@isolated` is proposed to distinguish functions that are isolated to the actor whose context in which the value resides. Any uses of an `@isolated` function will rely on the location in which that value is bound to determine its isolation.

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

Going further, `@isolated` provides the needed capability to share partially-applied methods and isolated closures across actors, when it is safe to do so:

```swift
func okSendable(_ y: @Sendable (V) async -> ()) {}
func badSendable(_ x: @Sendable (MutableRef) async -> ()) {}
func asPlainValueFunc(_ y: (V) -> ()) {}
func asPlainMutableRefFunc(_ y: (MutableRef) -> ()) {}

extension MyActor {
  func shareThem(_ takeValue: @isolated (V) -> (), _ changeRef: @isolated (MutableRef) -> ()) {
    okSendable(takeValue)
    badSendable(changeRef) // error: cannot cast '@isolated (MutableRef) -> ()' to '@Sendable (MutableRef) async -> ()' because 'MutableRef' is not Sendable.
    
    asPlainValueFunc(takeValue)
    asPlainMutableRefFunc(changeRef)
  }

  func packageIt(_ changeRef: @isolated (MutableRef) -> ()) -> (@Sendable () async -> ()) {
    let ref = MutableRef()
    let package: @isolated (MutableRef) -> () = {
      changeRef(ref)
    }
    return package
  }
}
```

Here, we know both `takeValue` and `changeRef` are isolated to the actor-instance because of `MyActor.shareThem`'s isolation. In fact, the compiler can determine specifically _which instance_ of that type the functions must be isolated: it's the implicit parameter `(_ self: isolated MyActor)` currently in scope! The example above shows a number of ways we share first-class isolated functions with contexts that are not isolated to that same actor. Whenever we share an `@isolated` value with a context that is not isolated to the same actor, the `@isolated` attribute must be dropped according to a set of rules.

#### Removing `@isolated` from a function's type

The primary function of `@isolated` is to track function values from their origin point, which is a context isolated to some actor, until it reaches a boundary of that isolation. That is when `@isolated` must be removed. These boundaries are not only cross-actor. A plain function not-otherwise-isolated is considered a boundary:

```swift
func process(_ e: Element, _ f: (Element) -> ()) { /* ... */ }

func crunchNumbers(_ a: isolated MyActor, 
                   _ es: [Element],
                   _ cruncher: @isolated (Element) -> ()) {
  for e in es {
    process(e, es, cruncher)
  }
}
```

Here, because arguments passed to `process` do not cross actors, there's no need for it to become `@Sendable`. Since it is not `@Sendable`, the `cruncher` does not need any additional conversions and the `@isolated` can simply be dropped.

Now, had `cruncher` been `async`, an additional requirement that the `Element` conforms to `Sendable`. The reason is subtle: without specifying the isolation of an `async` function, it can only be inferred to be `nonisolated`, which is a distinct isolation domain. Thus, whenever we drop isolation from an `async` function, we must enforce `Sendable` conformance for the input and output types, _even if_ the function is not `@Sendable`. Thus, we have the following rule:

<!--To make this concrete, here is an example:

```swift
func getFunc() -> (@Sendable (MutableRef) async -> ()) {
  @Sendable func nonIsolatedFn(_ ref: MutableRef) async { /* do evil */ }
  return nonIsolatedFn
}

@MainActor func callIt(_ g: (MutableRef) async -> (), _ ref: MutableRef) async {
  await g(ref)
}

@MainActor func example() async {
  let ref = MutableRef()
  let f: (MutableRef) async -> () = getFunc()
  await callIt(f, ref)
}
```

In this example, we use the subtyping of `@Sendable` functions to strip away knowledge that the `async` function returned by `getFunc` is may be from another isolation domain. Thus, the only isolation we can correctly infer for the function parameter of `callIt` is `nonisolated`, despite it not being `@Sendable`. We can summarize the rules about dropping `@isolated` (_without_ adding `@Sendable`) as:
-->

**Rule for Dropping `@isolated`:**
- If the function is `async`, then its argument and return types must conform to `Sendable`.
- Otherwise, the attribute can be dropped.

Once an attempt is made to pass an `@isolated` method across isolation domains, it must become `@Sendable`. This follows directly from rules about actor-isolation: whether an argument passed to an actor-isolated function is required to be `Sendable` depends on the isolation of the context in which the call appears. Since we cannot statically reason about the context in which a `@Sendable` function will be invoked, we have the following rule:

**Rule for Exchanging `@isolated` for `@Sendable`:**
- The function becomes `async`.
- If the function is isolated to a distributed actor, then it also gains `throws`.
- The function's argument and return types must conform to `Sendable`.

> **Rationale:** For a normal call to a non-async method of an actor from a different isolation domain, you must `await` as it is implicitly treated as an `async` call (and `throws` for distributed actors) because actors are non-blocking. To maintain isolation principles once isolation information is lost, the argument and return types of an actor-isolated function must also conform to `Sendable`.

### Global-actors and function types

For methods that are isolated to a global-actor, partial applications of those methods can more simply state their exact isolation in a way that is independent of the context in which the value resides. A `@Sendable` partially-applied method that is isolated to a global-actor is not _required_ to be `async`. Nor is it required to have `Sendable` input and output types.

But, as discussed in the Motivation, there are still situations where losing or dropping the global-actor isolation from a function's type is useful. In addition, there are scenarios where adding a global actor is unsafe or misleading.

#### Dropping global actors from function types

When there is a desire to drop a global-actor from a function type, then the same exact rules behind dropping `@isolated` apply. That is, whenever the function value qualifies for being converted to an `@isolated` function, and then the rules for dropping or exchanging the `@isolated` are used.

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

### Replace global-actors in function types with `@isolated`.

In a number of ways, it is tempting to think we can replace all global-actor attributes from function types with `@isolated`, but that would greatly limit what can be done with isolated function values. Plus, it's possible to have a type that is _not_ `Sendable` but contains global-actor isolated methods. See the `PG` type in the Detailed Design section for an example.

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

## Acknowledgments

This proposal has benefited from discussions with Doug Gregor and John McCall.
