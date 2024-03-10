# Feature name

* Proposal: [SE-NNNN](NNNN-isolated-any-functions.md)
* Authors: [John McCall](https://github.com/rjmccall)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

The actor isolation of a function is an important part of how it's
used.  Swift can reason precisely about the isolation of a specific
function *declaration*, but when functions are passed around as
*values*, Swift's function types are not expressive enough to keep up.
This proposal adds a new kind of function type that carries its function's
actor isolation dynamically.  This solves a variety of expressivity
problems in the language.  It also allows features such as the standard
library's task-creation APIs to be implemented more efficiently and
with stronger semantic guarantees.

## Motivation

The safety of Swift concurrency relies on understanding the isolation
requirements of functions.  The caller of an isolated synchronous
function must run it in an appropriately-isolated context or else the
function will almost certainly introduce data races.

Function declarations and closures in Swift support three different
forms of actor isolation:

- They can be non-isolated, which means somewhat different things
  depending on whether the function is synchronous or asynchronous.
  This can be explicitly expressed with the `nonisolated` modifier,
  but it is also the default if other rules don't apply.

- They can be isolated to a specific [global actor][SE-0316] type.
  This can be explicitly expressed with a global actor attribute
  such as `@MainActor`.  It can also be inferred from context in a
  number of ways, such as if the function is a method of a type with
  that attribute (which itself can be inferred in a number of ways).

- They can be isolated to a specific parameter or captured value.  This
  can be explicitly expressed by declaring a parameter or capture with
  the `isolated` modifier.  This can also be inferred; most importantly,
  all instance methods on an actor type are isolated to their `self`
  parameter unless otherwise specified.

When a function is called directly, Swift's isolation checker can
analyze its isolation precisely and compare that to the isolation of the
calling context.  When a function call is to an opaque value of function
type, however, Swift is limited by what can be expressed in the type
system:

- A function type with no isolation specifiers, such as `() -> Int`,
  represents a non-isolated function.

- A function type with a global actor attribute, such as
  `@MainActor () -> Int`, represents a function that's isolated to that
  global actor.

- A function type with an `isolated` parameter, such as
  `(isolated MyActor) - > Int`, represents a function that's isolated to
  that parameter.

There's a very important case that isn't covered by any of those: a
closure can be isolated to one of its captures.  In the following
example, the closure is isolated to its `self` capture:

```swift
actor WorldModelObject {
  var position: Point3D

  func linearMove(to finalPosition: Point3D, over time: Duration) {
    let originalPosition = self.position
    let motion = finalPosition - originalPosition

    gradually(over: time) { [isolated self] progressProportion in
      self.position = originalPosition + progressProportion * motion
    }
  }
}
```

This example uses an [explicit `isolated` capture](https://forums.swift.org/t/closure-isolation-control/70378) for clarity, but isolated captures
can also happen implicitly with the `Task` initializer:

```swift
extension WorldModelObject {
  func updateLater() {
    Task {
      // This closure doesn't have an explicit isolation specification, and
      // it's being passed to a parameter with the @inheritsIsolation
      // attribute, so it will be inferred to have the same isolation as
      // its containing context.  The containing context is isolated to its
      // `self` parameter, so this closure will have `self` as an implicit
      // isolated capture.
      self.update()
    }
  }
}
```

Partially-applied actor functions, such as `myActor.methodName`, are
in the same boat: the resulting function will be isolated to the
specific value `myActor`.  In none of these cases is there is any way
to exactly represent the function's isolation in its type.[^1]

[^1]: This would be an example of a value-dependent type, which is a
very advanced type system feature that we cannot easily add to Swift.
It is discussed briefly in Future Directions.

This is a very unfortunate limitation, because it actually means that
there's no way for a function to accept a function argument with
arbitrary isolation without completely erasing that isolation.  Swift
does allow functions with arbitrary isolation to be converted to a
non-isolated function type, but this comes with three severe drawbacks.
The first is that the resulting function type must be `async` so that
it can switch to the right isolation internally.  The second is that,
because the function changes isolation internally, it is limited in its
ability to work with non-`Sendable` values because any argument or return
value must cross an isolation boundary.  And the third is that the
isolation is completely dynamically erased: there is no way for the
recipient of the function value to recover what isolation the function
actually wants, which often puts the recipient in the position of doing
unnecesary work.

Here's an example of that last problem.  The `Task` initializer receives
an opaque value of type `() async throws -> ()`.  Because it cannot
dynamically recover the isolation from this value, the initializer has
no choice but to start the task on the global concurrent executor.  If
the function passed to the initializer is actually isolated to an actor,
it will immediately switch to that actor on entry.  This requires
additional synchronization and may require re-suspending the task.
Perhaps more importantly, it means that the order in which tasks are
actually enqueued on the actor is not necessarily the same as the order
in which they were created.  It would be much better --- both semantically
and for performance --- if the initializer could immediately enqueue the
task on the right executor to begin with.

The straightforward solution to these problems is to add a type which
is capable of expressing a function with an arbitrary (but statically
unknown) isolation.  That is what we propose to do.

## Proposed solution

This proposal adds a new attribute that can be placed on function types:

```swift
func gradually(over: Duration, operation: @isolated(any) (Double) -> ())
```

A function value with this type dynamically carries the isolation of
the function that was used to initialize it.

When such a function is called from an arbitrary context, it must be
assumed to always cross an isolation boundary.  This means, among other
things, that the call is effectively asynchronous and must be `await`ed.

```swift
await operation(timePassed / overallDuration)
```

The isolation can be read using the special `isolation` property
of these types:

```swift
func traverse(operation: isolated(any) (Node) -> ()) {
  let isolation = operation.isolation
}
```

The isolation checker knows that the value of this special property
matches the isolation of the function, so calls to the function from
contexts that are isolated to the `isolation` value do not cross
an isolation boundary.

Finally, every task-creation API in the standard library will be updated
to take a `@isolated(any)` function value and synchronously enqueue the
new task on the appropriate executor.

## Detailed design

### Grammar and structural rules

`@isolated(any)` is a new type attribute that can only be applied to
function types.  It is an isolation specification, and it is an error
to combine it with other isolation specifications such as a global
actor attribute or an `isolated` parameter.

`@isolated(any)` is not a *concrete* isolation specification and cannot
be directly applied to a declaration or a closure.  That is, you cannot
declare a function *entity* as having `@isolated(any)` isolation,
because Swift needs to know what the actual isolation is, and
`@isolated(any)` does not provide a rule for that.

To reduce the number of attributes necessary in typical uses,
`@isolated(any)` implies `@Sendable`.  It is generally not useful
to use `@isolated(any)` on a non-`Sendable` function because a
non-`Sendable` function must be isolated to the current concurrent
context.

### Conversions

Let `F` and `G` be function types, and let `F'` and `G'` be the corresponding
function types with any isolation specifier removed (including but not
limited to `@isolated(any)`.  If either `F` or `G` specifies
`@isolated(any)` then a value of type `F` can be converted to type `G`
if a value of type `F'` could be converted to type `G'` *and* the
following conditions apply:

- If `F` and `G` both specify `@isolated(any)`, there are no further
  conditions.  The resulting function is dynamically isolated to the
  same value as the original function.

- If only `G` specifies `@isolated(any)`, then the behavior depends on the
  specified isolation of `F`:

  - If `F` has an `isolated` parameter, the conversion is invalid.
  - Otherwise, the conversion is valid, and the dynamic isolation of
    the resulting function is determined as follows:
    - If the converted value is the result of an expression that is a
      closure expression (including an implicit autoclosure), a function
      reference, or a partial application of a method reference, the
      resulting function is dynamically isolated to the isolation of the
      function or closure.  This looks through non-instrumental differences
      in expression syntax such as parentheses.
    - Otherwise, if `F` is non-isolated, the resulting function is
      dynamically non-isolated.
    - Otherwise, `F` must be isolated to a global actor, and the resulting
      function is dynamically isolated to that global actor.

- If only `F` specifies `@isolated(any)`, then `G` must be an `async` function
  type.  `G` may have any isolation specifier, but it will be ignored and the
  function will run with the isolation of the original value.  The arguments
  and result must be sendable across an isolation boundary.  It is unspecified
  whether the task will dynamically suspend when calling or returning from
  the resulting value.

### Effects of intermediate conversions

In general, all of the isolation semantics and runtime behaviors laid out
here are affected by intermediate conversions to non-`@isolated(any)`
function types.  For example, if you coerce a non-isolated function or
closure to the type `@MainActor () -> ()`, the resulting function will
thereafter be treated as a `MainActor`-isolated function; the fact that
it was originally a non-isolated function is both statically and
dynamically erased.

### Runtime behavior

Calling a `@isolated(any)` function value behaves the same way as a direct
call to a function with that isolation would:

- If the function is `async`, it will run with its formal isolation.  This
  includes leaving isolated contexts if the function is dynamically
  non-isolated, as specified by [SE-0338](https://github.com/apple/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md).

- If the function is synchronous, it will run with its formal isolation
  only if it is dynamically isolated.  If it is dynamically non-isolated,
  it will simply run synchronously in the current context, even if that
  is isolated, just like an ordinary call to a non-isolated synchronous
  function would.

### `isolation` property

Values of `@isolated(any)` function type have a special `isolation`
property.  The property is read-only and has type `(any Actor)?`.  The
value of the property is determined by the dynamic isolation of the
function value:

- If the function is dynamically non-isolated, the value of `isolation`
  is `nil`.
- If the function is dynamically isolated to a global actor type `G`,
  the value of `isolation` is `G.shared`.
- If the function is dynamically isolated to a specific actor reference,
  the value of `isolation` is that actor reference.

### Distributed actors

Function values cannot generally be isolated to a distributed actor
unless the actor is known to be local.  When a distributed actor *is*
local, function values isolated to the actor can be converted to
`@isolated(any)` type as above.  The `isolation` property presents
the distributed actor as an `(any Actor)?` using the same mechanism
as [`#isolation`](https://github.com/apple/swift-evolution/blob/main/proposals/0420-inheritance-of-actor-isolation.md#isolated-distributed-actors).

### Isolation checking

Since the isolation of a dynamically-isolated function value is
statically unknown, calls to it typically cross an isolation barrier.
This means that the call must be `await`ed even if the function is
synchronous, and the arguments and result must satisfy the usual
sendability restrictions for cross-isolation calls.

If `f` is an immutable binding (such as a local `let` or a non-`inout`
parameter) of `@isolated(any)` function type, then a call to `f` does
not cross an isolation barrier if the current context is isolated
to a derivation of the expression `f.isolation`.

A context is isolated to a derivation of a expression `E` if it has an
isolated capture that is initialized to a derivation of `E`.

An expression is a derivation of `E` if:

- it has the exact form of `E`;
- it is a reference to a capture or immutable binding immediately
  initialized with a derivation of `E`; or
- it is a non-optional derivation of `E`.

When analyzing an expression for these rules, certain non-instrumental
differences in expression syntax and behavior must be ignored.  This
and certain other terms in this section are intended to match the
definitions laid out in [SE-0420](https://github.com/apple/swift-evolution/blob/main/proposals/0420-inheritance-of-actor-isolation.md#generalized-isolation-checking).

For example:

```swift
func delay(operation: @isolated(any) () -> ()) {
  let isolation = operation.isolation
  Task { [isolated isolation] in
    print("waking")
    operation() // <-- does not cross an isolation barrier and so is synchronous
    print("finished")
  }
}
```

TODO: Add some way to use `assumeIsolated` to assert that we're currently
isolated to the isolation of an `@isolated(any)` function, such that
calls within that context no longer cross isolation boundaries.
Maybe this could also decompose the function value?

### Adoption in task-creation routines

There are a large number of functions in the standard library that create
tasks:
- `Task.init`
- `Task.detached`
- `TaskGroup.add`
- `ThrowingTaskGroup.add`
- `DiscardingTaskGroup.add`
- `ThrowingDiscardingTaskGroup.add`

This proposal modifies all of these APIs so that the task function has
`@isolated(any)` function type.  These APIs now all synchronously enqueue
the new task directly on the appropriate executor for the task function's
dynamic isolation.

Swift reserves the right to optimize the execution of tasks to avoid
"unnecessary" isolation changes, such as when an isolated `async` function
starts by calling a function with different isolation.  In general, this
includes optimizing where the task initially starts executing.  As an
exception, in order to provide a primitive scheduling operation with
stronger guarantees, Swift will always start a task function on its
appropriate executor for its formal dynamic isolation unless:
- it is non-isolated or
- it comes from a closure expression that is only *implicitly* isolated
  to an actor (that is, it has neither an explicit `isolated` capture
  nor a global actor attribute).

As a result, in the following code, these two tasks are guaranteed
to start executing on the main actor in the order in which they were
created, even if they immediately switch away from the main actor without
having done anything that requires isolation:[^2]

```swift
func process() async {
  Task { @MainActor in
    ...
  }

  // do some work

  Task { @MainActor in
    ...
  }
}
```


[^2]: This sort of guarantee is important when working with a FIFO
"pipeline", which is a common pattern when working with explicit queues.
In a pipeline, code responds to an event by performing work on a series
of queues, like so:

  ```swift
  func handleEvent(event: Event) {}
    queue1.async {
      let x = makeX(event)
      queue2.async {
        let y = makeY(event)
        queue3.async {
          handle(x, y)
        }
      }
    }
  }
  ```

  As long as execution always goes through the exact same sequence of FIFO
  queues, each queue will execute its stage of the overall pipeline in
  the same order as the events were originally received.  This can be a
  difficult property to maintain --- concurrency at any stage will destroy
  it, as will skipping any stages of the pipeline --- but it's not uncommon
  for systems to be architected around it.

## Source compatibility

Most of this proposal is additive.  The exception is the adoption
in the standard library, which changes the types of certain API
parameters.  Calls to these APIs should continue to work, as any
function that could be passed to the current parameter should also
be convertible to an `@isolated(any)` type.  The observed type of
the API will change, however, if anyone does an abstract reference
such as `Task.init`.  Contravariant conversion should allow these
unapplied references to work in any concrete type context that
would accept the current function, but references in other contexts
can lead to source breaks (such as `var fn = Task.init`).  This is
unlikely to be an issue in practice.  More importantly, I believe
Swift has a general policy of declining to guarantee stable types
for unapplied function references in the standard library this way.
Doing so would prevent a wide variety of reasonable code evolution
for the library, such as generalizing the type of a parameter (as
this proposal does) or adding a new defaulted parameter.

## ABI compatibility

This feature does not change the ABI of any existing code.

## Implications on adoption

The basic functionality of `@isolated(any)` function types is
implemented directly in generated code and does not require runtime
support.

Using a type as a generic argument generally requires runtime type
metadata support for the type.  For `@isolated(any)` function types,
that metadata support requires a new Swift runtime.  It will therefore
not possible to use a type such as `[@isolated(any) () -> ()]` when
back-deploying code on a platform with ABI stability.  However,
wrapping the function in a `struct` with a single field will generally
work around this problem.  (It also generally allows the function to
be stored more efficiently.)

The task-creation APIs in the standard library have been implemented
in a way that allows their signatures to be changed without ABI
considerations.  Direct enqueuing on the isolated actor does require
runtime support, but fortunately that support has present in the
concurrency runtime since the first release.  Therefore, there should
not be any back-deployment problems supporting the proposed changes.

Adopters of `@isolated(any)` function types will generally face the
same source-compatibility considerations as this proposal does with
the task-creation APIs: it requires generalizing some parameter types,
which generally should not cause incompatibilities with direct callers
but can introduce problems in the somewhat unlikely case that anyone
is using those function as values.

## Future directions

### Statically-isolated function types

`@isolated(any)` function types are effectively an "existential
erasure" of the isolation of the function, removing the type system's
static knowledge of the isolation while dynamically preserving it.
This is directly analogous to how `Any` erases the type of the value
you store into it: the type system no longer knows statically what
type is stored there, but it's still possible to recover it dynamically.
This analogy is why this proposal uses the keyword `any` in the
attribute name.

Where there's an existential, there's also a generic.  The generic
analogue to `@isolated(any)` would be a type that expressed that it
was isolated to a specific value, like so:

```swift
func delay<A: Actor>(on operationActor: A,
                     operation: @isolated(to: operationActor) () async -> ())
```

This is a kind of value-dependent type.  Value-dependent types add a
lot of complexity to a type system.  Consider how the arguments interact
in the example above: both value and type information from the first
argument flows into the second.  This is not something to do lightly.

It is also likely to be unnecessary.  We believe that `@isolated(any)`
function types are superior from a usability perspective for all the
dominant patterns of higher-order APIs.  The main thing that
`@isolated(to:)` can express in an API signature that `@isolated(any)`
cannot is multiple functions that share a common isolation.  It is
quite uncommon for APIs to take multiple closely-related functions
this way, especially `@Sendable` functions where there's an expected
isolation change from the current context.  When only a single function
is required in an API, `@isolated(any)` allows its isolation to bound
up with it in a single value, which is both more convenient and likely
to have a more performant representation.

But if we do decide to explore in the direction of `@isolated(to:)`,
nothing in this proposal would interfere with it, and in fact they
could support each other well.  Erasing the isolation of an `@isolated(to:)`
function into an `@isolated(any)` type would be straightforward, and
an `@isolated(any)` function could be "opened" into a pair of an
`@isolated(to:)` function and its known isolation.

Even in a world with that feature, we are unlikely to regret having
previously added `@isolated(any)`.

## Alternatives considered

(to be expanded)

## Acknowledgments

I'd like to thank Holly Borla and Konrad Malawski for many long
conversations about the design and implementation of this feature.
