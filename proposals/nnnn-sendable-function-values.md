# Function Values and Sendable

- Proposal: [SE-NNNN](/Applications/Joplin.app/Contents/Resources/app.asar/NNNN-filename.md "NNNN-filename.md")
- Authors: [Kavon Farvardin](https://github.com/kavon)
- Review Manager: TBD
- Status: **Awaiting implementation**

## Introduction

This proposal is focused on a few corner-cases in the language when using functions as values. It aims to expand the ways you can use functions as values when using concurrency. The goal is to improve flexibility and ergonomics without major changes to Swift.

## Motivation

The partial application of methods and other first-class uses of functions have a few rough [edges](https://forums.swift.org/t/sendable-func-on-sendable-types/60708) when combined with concurrency. For example, today you can create a function-value representing an actor's method by writing an expression that only accesses (but does not call) a method using one of its instances. More precisely, this access is referred to as a "partial application" of a method to one of its (implicit) arguments, the object instance:

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

Part of the reason for this limitation is that knowledge of the isolation is effectively erased from the type when partially-applying the actor instance. That knowledge is required for non-async isolated methods, as their runtime representation cannot encode isolation enforcement alone. But, it is possible to create a `@Sendable` version of a partially-applied non-async actor method, by representing it with an `async` function value.

Conceptually, a similar limitation comes up when performing a conversion that removes the `@MainActor` from a function type. Since it is generally unsafe to do so, the compiler emits a warning, such as in this example:

```swift
@MainActor func dropMainActor(_ f: @MainActor (Data) -> Data) -> [Data] {
  return [4, 8, 15, 16, 23, 42].map(f)
  // warning: converting function value of type '@MainActor (Data) -> Data' to '(Data) throws -> Data' loses global actor 'MainActor'
}
```

But not all situations that drop the global-actor from a function value are unsafe. In the example above, the "erasing" cast happens while on the same actor. By the same logic as our actor-method example, this should be safe if we do not allow that casted function to later leave the actor's isolation.

These and other aspects of how Sendable and actor isolation interact with funciton values the focus of this proposal.

## Proposed solution

This section provides a summary of the solutions and changes proposed for Swift. For complete details and caveats, see the Detailed design.

### Inferring `@Sendable` for methods

In SE-302, the `@Sendable` attribute was introduced for both closures and named functions/methods. Beyond changing the type of the function, the attribute only influences the kinds of values that can be captured by the function. But when methods of a nominal type are used in a first-class way, they cannot capture anything but the object instance itself. Furthermore, a non-local (i.e., a global or static) function cannot capture _anything_, because a reference to a global variable is not considered a capture of that variable. Thus, the proposed changes are:

1. the inference of `@Sendable` on all methods of a type that conforms to `Sendable`.
2. the inference of `@Sendable` on all non-local functions.
3. the prohibition of marking a method `@Sendable` if the object type does not conform to `Sendable`.

### Sendable `actor` methods

Since all `actor` types are `Sendable`, their methods will also be considered `@Sendable` as part of the earlier proposed rules. But additional rules are needed to maintain invariants about actors. When you call a non-async method of an actor from a different isolation domain, you must `await` it because it is implicitly treated as an `async` call (and `throws` for distributed actors) to avoid blocking. In addition, the input and return values of an actor-isolated function must conform to `Sendable` if the call appears in a different isolation domain.

The challenge is that, once partially-applied to an `actor` method, the object instance to which the method is isolated is not visible in the function type. Barring major extensions to the language, we have to assume the isolation of the context in which the partially-applied method will be fully-applied is unknown. Thus, a `@Sendable` function value representing a method isolated to an actor instance must:

1. Carry `async` and/or `throws` in its type.
2. Have its arguments and return type all conform to `Sendable`.

These are the same rules that would be in effect if the method were fully-applied in a `nonisolated` context.

### Dropping global-actors from function types

For methods that are isolated to a global-actor, partial applications of those methods does not erase the isolation from the type, because its isolation depends on a fixed, well-known instance of an actor. Thus, a `@Sendable` partially-applied method that is isolated to a global-actor is not _required_ to be an `async` function. But, there are still situations where losing or dropping the global-actor isolation from a function's type is useful, as discussed in the Motivation. The proposed rules for when it's safe to perform the conversion resemble the actor-instance isolation case:

1. When within a matching isolation domain, it is permitted to drop the global-actor if the function value is _not_ `@Sendable`.
2. In all other cases, dropping the global actor may add `async`, just as for actor-instance isolated methods.

Here are a few example conversion chains:

```
// Circumstance 1 - matching context isolation.
{ @GlobalActor in
  @Sendable @GlobalActor (T) -> V  
    ==> @GlobalActor (T) -> V   (by subtyping)
    ==> (T) -> V                (by this proposal)
}

// Circumstance 2
@Sendable @GlobalActor (T) -> V
  ==> @Sendable (T) async -> V  (if T is Sendable and V is Sendable)
```


---

## Detailed design



Notice that `dropMainActor` itself is isolated to the `MainActor`, so the non-async call to `map` is guaranteed to run in the `MainActor` 's isolation domain. That's guaranteed because `f` is neither `@Sendable` nor `@escaping` , so the `map` function could not hand-off `f` to any other isolation domain.

> **NOTE:** In theory, the parameter to `map` not being `@Sendable` could be reason enough to allow this cast. But, as of _today_ we require it to also be non-escaping so that the value does not get smuggled into a different isolation domain via global storage.

Consider `withoutActuallyEscaping` because it adds a runtime check to ensure it didn't actually escape. This can be used to make sure, say, `map` doesn't truly escape it. If we know `map` was compiled in strict checking / Swift 6 mode, we don't need it, but otherwise we need that to guarantee it's OK. 

We know eventually that writing to a global or static is going to require the value to be Sendable in some way (follow-up).

---

**TODO:** maybe the `@Sendable` on methods is totally useless, since methods can't capture anything from the type's enclosing scope. This also means global functions don't need it, but local functions do (since they can capture locals).

**Rule 0a:** An object method can be marked with `@Sendable` if the method is not isolated to an actor and the instance type conforms to `Sendable`.

As a result, the type of the method becomes `@Sendable (T) -> (@Sendable (A) -> R)`, that is, the unapplied method itself is `@Sendable`, and so too is the result of partially-applying the method to an instance.

**Rule 0b:** An actor-isolated method cannot be marked with `@Sendable` because it is implicitly `@Sendable` based on whether the reference appears inside or outside of the actor's isolation:
1. When inside the actor's isolation, by default the reference is not `Sendable` unless there is demand for it to be `@Sendable` (i.e., a type coercion).
2. When outside the actor's isolation, the reference always yields a `Sendable` function.

The reasoning for the distinction between Rule 0a and Rule 0b is that actor isolation already provides a guarantee that any captured values are `Sendable` , otherwise they wouldn't be accessible to the method. Next, the reason for a distinction upon referencing an actor-isolated method based on the context is that the type can greatly differ, based on whether the method is `async` or not. For example, if an actor-isolated method is `async`, then one can always treat it as `@Sendable` , relying on the subtyping rule for contexts where `@Sendable` is not needed. But if the actor method were non-async, then depending on whether it is `Sendable`, its type might need to be `async` (or `throws` for distributed actors).
 
**TODO: example**

---


**Rule 1:** When partially-applying an object instance to one of its methods, the resulting function can be coerced to be `@Sendable`  if the instance conforms to `Sendable`.

This follows directly from the existing rule that a closure is `Sendable` if its captures are let-bound and `Sendable`. But, this rule cannot stand on its own:

**Rule 2a:** If a partially-applied method is chosen to be coerced to `@Sendable` **and the method is isolated to an `actor` instance**, then the resulting function type is `async` (and `throws` if isolated to a distributed actor) and its argument and return types must conform to `Sendable`.

Take note that Rule 2a only applies to `actor` instance isolation. The rule's requirements follow from the idea that partial-application of an instance of `actor A` to a function with a parameter `isolated A` effectively eliminates any trace of the actor type itself. But importantly, the isolation is *not* removed. This erasure from the type is required for actor instances, because each instance is a unique actor. But because the resulting function must be `Sendable`, it will be possible to invoke it from *any* context. Thus:

1.  The function must have the internal ability to gain actor isolation at runtime from any isolation context, so it must be `async` (and possibly `throws`).
2.  Because we cannot track where the function will be ultimately invoked, we don't know what context is sending or recieving values from this partially-applied actor method, so its argument and return types must be `Sendable`.

As of today, partially-applying an `actor`-instance isolated method is only allowed within a context with matching isolation:

```swift
class Pinned { var x: Int = 0 } // a non-sendable type
protocol P: Sendable { func f() }
final class C: Sendable { func f() {} }
actor A { 
    private var pinned: Pinned = Pinned()

    func f() -> C { return C() }
    func asyncF() async -> C { return C() }
    func getPinned() -> Pinned { return pinned }

    /////////////
    // These partial-applications can only appear within these isolated methods,
    // and the resulting function value cannot be cast to Sendable. Thus these
    // methods are only callable from a context already isolated the actor.
    func currentlyAllowed_1() -> (() -> C) {
      return self.f
    }
    func currentlyAllowed_2() -> (() async -> Pinned) {
      return self.getPinned
    }

    /////////////
    // With Rule 2a, the following partial-applications can now appear anywhere.
    // The closures can also be cast to Sendable. The diagnostics below are
    // what the compiler currently raises.
    nonisolated func byRule2a_ex1() -> (@Sendable () async -> C) {
      let x = self.f
          return x // without this return to coerce it, `x` would have type `() -> C`
    }
    func byRule2a_ex2() -> (@Sendable () async -> C) {
      let x = self.asyncF
          return x // without this return coercing it, `x` would have type `() async -> C`
    }

    // Pinned is not Sendable, so this conversion is still not allowed.
    nonisolated func disallowed_ex3() -> (@Sendable () async -> Pinned) {
           return self.getPinned
    }
    
         // The type checker cannot determine the provenance of `f` to inspect its captures, 
       // so this conversion is still not allowed.
       func disallowed_ex4(_ f: () async -> C) -> (@Sendable () async -> C) {
      return f
    }
}
```

**Rule 2b:** If a partially-applied method is chosen to be coerced to `@Sendable` **and the method has global-actor isolation**, then the resulting function type carries isolation to that global actor.

**Rule 3:** If a partially-applied actor-isolated method is **not** coerced to `@Sendable`, then resulting function type is computed based on the isolation of the context in which the partial application happens:

1.  The resulting function is `async` if an `await` would be required to invoke it from that context.
2.  The function's argument and return types must be `Sendable` if invoking it from that context would cross actors.

As of today, partial applications of actor-isolated methods outside of the same actor's isolation are not allowed at all.

* * *

**Rule 4a:** Conversions that drop a global-actor from the type of an `async` function value is permitted in any context.

This is already permitted by SE-N, but we restate it differently here to contrast with the next rule:

**Rule 4b (rdar://94462333):** Dropping some global-actor `G` from the type of a **non-`async`** and **non-`@Sendable`** function is permitted if the conversion happens in a context isolated to `G` .

For example, in the context of a statement isolated to global-actor `GlobalActor`, this conversion is allowed:

```swift
{ @GlobalActor () in // some context isolated to the global actor...

  @GlobalActor (T) -> V  ==>  (T) -> V
  
}
```

because the function is not `@Sendable` and thus cannot leave the isolation of `GlobalActor`.

**Rule 4c (rdar://94462333):** Dropping some global-actor `G` from the type of a **non-`async`** and **`@Sendable`** function is permitted in the following circumstances:

1.  Rule 4b can be applied if also dropping the `@Sendable` is possible.
2.  Otherwise, the function will also become `async` and its arguments and return type must conform to `Sendable`

A Sendable function can always be used in a place where Sendable is not required, so circumstance (1) is a reminder that if Sendability is also not required, then the function can remain non-`async` if Rule 4b applies.

Otherwise, the rationale behind circumstance (2) mirrors that of Rule 2a. Conceptually, dropping a global actor from a function's' type is exactly the same situation as partially-applying an actor instance to an `isolated` parameter, in that it's erasing actor information from the type, but *preserving* the isolation in a different way. Isolation is always enforced and never removed.

Here are a few example conversions:

```
// Circumstance 1
@Sendable @GlobalActor (T) -> V  
  ==> @GlobalActor (T) -> V   (if not required to be @Sendable)
  ==> (T) -> V                (by Rule 4b)

// Circumstance 2
@Sendable @GlobalActor (T) -> V
  ==> @Sendable (T) async -> V  (if T is Sendable and V is Sendable)
```

**Rule 5:**

(still trying to figure out what to do about the casts that add global actor to async funcs)

```swift
@MainActor func mainActorAsync() async {}
func voidAsync() async -> Void {}
func pinnedAsync() async -> Pinned {}

func banned() {
  // expected-error @+1 {{cannot convert value of type 'MainActor' to specified type 'SomeOtherActor'}}
  let _: @SomeOtherActor () async -> Void = mainActorAsync // arbitrarily not allowed?
}

@MainActor func chk() async {
  let _: @MainActor () async -> Void = voidAsync     // OK cause return type is Sendable

  // expected-warning @+1 {{non-sendable type 'Pinned' returned by call from main actor-isolated context to non-isolated global function 'pinnedAsync()' cannot cross actor boundary}}
  let _: @MainActor () async -> Pinned = pinnedAsync // not OK cause return type is non-Sendable
}
```



## Old Version



Prior to this proposal, there was only one narrow circumstance under which the partial-application of an isolated `actor` method is permitted: the partial-application occurs within a context that is isolated to the same actor instance being partially-applied.

In terms of our examples from earlier, that happens for `insideIsolationExample` because it is isolated to the actor `self`, and `self` is being partially-applied to `transform`. Conceptually, the type signature of `StatefulTransformer.transform` is `(isolated StatefulTransformer) -> ((Data) -> Data)`. Once partially applied to an instance of the type, the `isolated` instance parameter will be consumed and leave behind a resulting function `(Data) -> Data`. Thus, _because_ the isolation is not tracked in the resulting function's type, that function cannot be `Sendable`, i.e., be allowed to leave the actor's isolation domain. Otherwise, a caller from a non-isolated context will not know whether to `await` the call in order to obtain the isolation required. With this understanding in mind, the key idea behind the proposed solution becomes clear: 

> When consuming or removing the isolation in a function's type, its resulting type is required to reflect the actor's requirements in all isolation contexts where it can be fully applied.


For example, partially-applying an actor instance to one of its non-async methods can yield an async function:

```swift
extension StatefulTransformer {
  nonisolated func outsideIsolationProposed() -> [Data] {
    let h = self.transform
    return [4, 8, 15, 16, 23, 42].asyncMap(h)
	}
}
```

In this example, `h` has the type `@Sendable (Data) async -> Data`. The demand for `h` to be `Sendable` comes in part from `asyncMap`, which requires a `Sendable` closure. Despite `transform` being a non-async function, `self.transform` yields an `async` function because an `await` may be required to gain isolation of the underlying actor. In addition,     

But the other reason why it must be `Sendable`   

But it's important to note that anytime we partially-apply a method, the `self` argument will be consumed. Conceptually, the complete signature of `StatefulTransformer.transform` is `(isolated StatefulTransformer) -> ((Data) -> Data)`. Once partially applied, the isolated parameter will have been consumed. Thus, the isolation is also dropped from the type. This is why it's not Sendable. etc.

Left off here
------------



Thus, it is not safe to share the resulting function value with another actor.

Note that the complete type signature for our example actor method is:

```swift
StatefulTransformer.transform : ()
```

Together, these two properties ensure that the resulting function value cannot *leave* the actor in which it is isolated. For example, if we try to perform the partial-application outside of the instance's isolation, the compiler rejects it:

```swift
extension Array where Self.Element: Sendable {
  func asyncMap<T>(_ transform: @Sendable (Self.Element) async throws -> T) async rethrows -> [T]
      where T: Sendable { /* ... */}
}

extension StatefulTransformer {
    nonisolated func outsideIsolationExample() async -> [Data] {
    let _: (Data) -> Data = self.transform
    //                      ^~~~~~~~~~~~~~
    // error: actor-isolated instance method 'transform' can not be partially applied
        
    let g: @Sendable (Data) async -> Data = { await self.transform($0) }
    // OK
        
    return await [4, 8, 15, 16, 23, 42].asyncMap(g)
  }
}
```

Yet, because `self` is `Sendable`, it is OK to fully-apply `self.transform` inside of a `@Sendable` closure as a workaround. There is no reason for this distinction.


----

Prior to this proposal, there was only one narrow circumstance under which the partial-application of an isolated `actor` method is permitted: the partial-application occurs within a context that is isolated to the same actor instance being partially-applied.

In terms of our examples from earlier, that happens for `insideIsolationExample` because it is isolated to the actor `self`, and `self` is being partially-applied to `transform`. Conceptually, the type signature of `StatefulTransformer.transform` is `(isolated StatefulTransformer) -> ((Data) -> Data)`. Once partially applied to an instance of the type, the `isolated` instance parameter will be consumed and leave behind a resulting function `(Data) -> Data`. Thus, _because_ the isolation is not tracked in the resulting function's type, that function cannot be `Sendable`, i.e., be allowed to leave the actor's isolation domain. Otherwise, a caller from a non-isolated context will not know whether to `await` the call in order to obtain the isolation required. With this understanding in mind, the key idea behind the proposed solution becomes clear: 

> When consuming or removing the isolation in a function's type, its resulting type is required to reflect the actor's requirements in all isolation contexts where it can be fully applied.


For example, partially-applying an actor instance to one of its non-async methods can yield an async function:

```swift
extension StatefulTransformer {
  nonisolated func outsideIsolationProposed() -> [Data] {
    let h = self.transform
    return [4, 8, 15, 16, 23, 42].asyncMap(h)
	}
}
```

In this example, `h` has the type `@Sendable (Data) async -> Data`. The demand for `h` to be `Sendable` comes in part from `asyncMap`, which requires a `Sendable` closure. Despite `transform` being a non-async function, `self.transform` yields an `async` function because an `await` may be required to gain isolation of the underlying actor. In addition,     

But the other reason why it must be `Sendable`   

But it's important to note that anytime we partially-apply a method, the `self` argument will be consumed. Conceptually, the complete signature of `StatefulTransformer.transform` is `(isolated StatefulTransformer) -> ((Data) -> Data)`. Once partially applied, the isolated parameter will have been consumed. Thus, the isolation is also dropped from the type. This is why it's not Sendable. etc.

Left off here
------------



Thus, it is not safe to share the resulting function value with another actor.

Note that the complete type signature for our example actor method is:

```swift
StatefulTransformer.transform : ()
```

Together, these two properties ensure that the resulting function value cannot *leave* the actor in which it is isolated. For example, if we try to perform the partial-application outside of the instance's isolation, the compiler rejects it:

```swift
extension Array where Self.Element: Sendable {
  func asyncMap<T>(_ transform: @Sendable (Self.Element) async throws -> T) async rethrows -> [T]
      where T: Sendable { /* ... */}
}

extension StatefulTransformer {
    nonisolated func outsideIsolationExample() async -> [Data] {
    let _: (Data) -> Data = self.transform
    //                      ^~~~~~~~~~~~~~
    // error: actor-isolated instance method 'transform' can not be partially applied
        
    let g: @Sendable (Data) async -> Data = { await self.transform($0) }
    // OK
        
    return await [4, 8, 15, 16, 23, 42].asyncMap(g)
  }
}
```

Yet, because `self` is `Sendable`, it is OK to fully-apply `self.transform` inside of a `@Sendable` closure as a workaround. There is no reason for this distinction.


----



## Source compatibility

How much of Swift <= 5.7 is going to break?

## Effect on ABI stability

The ABI comprises all aspects of how code is generated for the
language, how that code interacts with other code that has been
compiled separately, and how that code interacts with the Swift
runtime library. It includes the basic rules of the language ABI,
such as calling conventions, the layout of data types, and the
behavior of dynamic features in the language like reflection,
dynamic dispatch, and dynamic casting. It also includes applications
of those basic rules to ABI-exposed declarations, such as the `public`
functions and types of ABI-stable libraries like the Swift standard
library.

Many language proposals have no direct impact on the ABI. For
example, a proposal to add the `typealias` declaration to Swift
would have no effect on the ABI because type aliases are not
represented dynamically and uses of them in code can be
straightforwardly translated into uses of the aliased type.
Proposals like this can simply state in this section that they
have no impact on the ABI. However, if *using* the feature in code
that must maintain a stable ABI can have a surprising ABI impact,
for example by changing a function signature to be different from
how it would be without using the feature, that should be discussed
in this section.

Because Swift has a stable ABI on some platforms, proposals are
generally not acceptable if they would require changes to the ABI
of existing language features or declarations. Proposals must be
designed to avoid the need for this.

For example, Swift could not accept a proposal for a feature which,
in order to work, would require parameters of certain (existing)
types to always be passed as owned values, because parameters are
not always passed as owned values in the ABI. This feature could
be fixed by only enabling it for parameters marked a special new way.
Adding that marking to an existing function parameter would change
the ABI of that specific function, which programmers can make good,
context-aware decisions about: adding the marking to an existing
function with a stable ABI would not be acceptable, but adding it
to a new function or to a function with no stable ABI restrictions
would be fine.

Proposals that change the ABI may be acceptable if they can be thought
of as merely *adding* to the ABI, such as by adding new kinds of
declarations, adding new modifiers or attributes, or adding new types
or methods to the Swift standard library. The key principle is
that the ABI must not change for code that does not use the new
feature. On platforms with stable ABIs, uses of such features will
by default require a new release of the platform in order to work,
and so their use in code that may deploy to older releases will have
to be availability-guarded. If this limitation applies to any part
of this proposal, that should be discussed in this section.

Adding a function to the standard library does not always require
an addition to the ABI if it can be implemented using existing
functions. Library maintainers may be able to help you with this
during the code review of your implementation. Adding a type or
protocol currently always requires an addition to the ABI.

If a feature does require additions to the ABI, platforms with
stable ABIs may sometimes be able to back-deploy those additions
to existing releases of the platform. This is not always possible,
and in any case, it is outside the scope of the evolution process.
Proposals should usually discuss ABI stability concerns as if
it was not possible to back-deploy the necessary ABI additions.

## Effect on API resilience

API resilience describes the changes one can make to a public API
without breaking its ABI. Does this proposal introduce features that
would become part of a public API? If so, what kinds of changes can be
made without breaking ABI? Can this feature be added/removed without
breaking ABI? For more information about the resilience model, see the
[library evolution<br>document](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst)
in the Swift repository.

## Alternatives considered

Describe alternative approaches to addressing the same problem, and
why you chose this approach instead.

## Acknowledgments

If significant changes or improvements suggested by members of the
community were incorporated into the proposal as it developed, take a
moment here to thank them for their contributions. Swift evolution is a
collaborative process, and everyone's input should receive recognition!
