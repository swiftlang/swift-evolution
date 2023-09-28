# Improved control over closure actor isolation

* Proposal: [SE-NNNN](NNNN-improved-actor-isolation-control-for-closures.md)
* Authors: [John McCall](https://github.com/rjmccall)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: TBD
* Review: ([pitch](https://forums.swift.org/...))

**This is a draft design which has not been implemented.  It's very
possible that some of the ideas in it simply do not work.**

[SE-0306]: https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md#actor-isolation
[SE-0313]: https://github.com/apple/swift-evolution/blob/main/proposals/0313-actor-isolation-control.md
[SE-0316]: https://github.com/apple/swift-evolution/blob/main/proposals/0316-global-actors.md
[SE-0338]: https://github.com/apple/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md

## Introduction

The formal actor isolation of a function is often crucially important
in Swift's concurrency design.  However, the current features Swift
provides for controlling it are sometimes inadequate.  This proposal
adds several related features to give programmers and API designers
more control over isolation, especially for closure expressions.

## Motivation

In Swift's [actors design][SE-0306], every function body in a Swift
program has a static *actor isolation*: there is an optional actor
that the function body is statically known to be running on.  By
default, this isolation is determined by the context of the function
body; for example, an instance method on an `actor` is isolated to
`self`.  [SE-0313] gave programmers some powerful tools for taking
explicit control over actor isolation.  Unfortunately, there are some
gaps in what can be done with those tools.

The first gap is that there's no way to explicitly specify the
isolation of a closure[^1].  For example, suppose that a programmer
wants to create a `Task` that does some work with a specific actor:

[^1]: unless the programmer is able to change the closure signature
to take an `isolated` parameter, but this usually isn't possible

```swift
struct Widget {
  let model: WidgetModel // an actor

  func writeback() {
    Task {
      // This closure is statically non-isolated, so the accesses to
      // the model below are cross-actor references: they must be
      // marked with `await` and will not run atomically.

      guard model.stillActive else { return }
      model.update(newValue: self)
    }
  }
}
```

It'd be nice if the programmer could just say that this closure was
statically isolated to `model`, but there's no way to do that.

The second gap is closely related: there's no way to explicitly
declare a closure to be *non*-isolated.  For example, if the `Task`
initializer is used with a closure expression, that closure will
inherits the isolation of the surrounding context by default.  Often
this is desirable, but if it isn't, there's no way to turn it off[^2].

[^2]: without using `Task.detached`, which has other semantics that
may be undesired in some situations, like not inheriting priority and
task-local storage

The third gap is that it's awkward to propagate actor isolation from
one context to another.  SE-0313 allows you to declare a function with
an `isolated` parameter, but the programmer has to explicitly pass
that argument.  There's no way to write a function that just inherits
the actor isolation of its caller.  This is especially a problem when
combined with [SE-0338], which made non-isolated `async` functions
leave the current actor during their execution, because it makes it
impossible to write certain kinds of `async` utility function.

For example, consider a generalization of the `map` operation to
support an asynchronous transform function:

```swift
extension Collection {
  func sequentialMap<R>(transform: (Element) async -> R) async -> [R] {
    var results: [R] = []
    for elt in self {
      // Note that this is not a *parallel* map: the function is
      // called sequentially for each element.
      results.append(await transform(elt))
    }
    return results
  }
}
```

It would be useful if this could be called from an actor-isolated
context and passed a transform isolated to that same actor.  This is
allowed, but it has restrictions and behavior that may be surprising
because `sequentialMap` is not statically isolated to that actor.
First, the transform function is being passed between different actor
isolations, which requires it to be `@Sendable`, so it cannot capture
any non-`Sendable` local state.  Second, the collection and elements
are being passed between different actor isolations, so those types
must also be `Sendable`.  Finally, the formal execution model under
SE-0338 means that `sequentialMap` will try to switch off of the
current actor, so the performance of this code may suffer if the
optimizer isn't able to eliminate these unnecessary switches.

To fix this, `sequentialMap` must be declared to have the actor as
its static isolation.  This can be done by giving `sequentialMap`
an `isolated` parameter:

```swift
extension Collection {
  func sequentialMap<R>(actor: isolated any Actor,
                        transform: (Element) async -> R) async -> [R]
}
```

But now the caller must provide this argument explicitly.  Worse,
`sequentialMap` now *must* be passed an actor, even if it doesn't
need to be isolated.

The final gap that we consider in this proposal is the behavior
of the `Task` initializer.  As mentioned above, when a function
calls the `Task` initializer with a closure expression, that
closure defaults to having the same static actor isolation as
the original function.  There is currently no official way to get
this effect outside the standard library.

## Proposed solution

This proposal closes all four of these gaps with four separate but
related features.

First, the `isolated` keyword can be used in a closure's capture list
to indicate that closure is statically isolated to that actor.  For
example:

```swift
actor Counter {
  var count = 0

  func incrementLater() {
    timer.callMeMaybe { // takes an escaping closure
      [isolated self] in

      // The closure is now isolated to self, so this is accepted
      // and doesn't require any `await`s.
      count += 1
    }
  }
}
```

Second, the `nonisolated` keyword can be used in the attributes list
of a closure to explicitly declare the closure as non-isolated.  For
example:

```swift
extension Counter {
  func taskWithCount(operation: (Int) async -> ()) {
    let value = count
    count += 1
    Task {
      // Becauses it's passed to the `Task` initializer, this closure would
      // normally be statically isolated to `self`, which in this case is
      // unnecessary.  The optimizer can eliminate that here, but we can
      // now guarantee that by statically specifying that the closure is
      // non-isolated.
      nonisolated in

      await operation(value)
    }
  }
}
```

Third, there is new special default argument expression,
`#isolation`, which expands to the static actor isolation of the
caller.  This can be used for any parameter, but when the parameter
is specifically declared `isolated`, this has the effect of
implicitly propagating the static isolation of the caller to the
callee.

```swift
extension Collection {
  func sequentialMap<R>(isolated isolation: (any Actor)? = #isolation,
                        transform: (Element) async -> R) async -> [R] {
    ...
  }
}
```

Finally, there is a new attribute, `@inheritsActorIsolation`, which
can be placed on a parameter to duplicate the behavior of the `Task`
initializer.

## Detailed design

### Optional isolation

It is a core goal of `isolated` parameters and captures to allow
polymorphism over actor isolation.  Actor isolation includes the
ability to be non-isolated, and so these features must be generalized
to support isolation to values of optional type.  The existing
type-checking rule for `isolated` parameters can be summarized as
"the type must be convertible to `any Actor`; the new rule can be
summarized as "the type must be convertible to `(any Actor)?`.

If a function is isolated to a value of optional type, and the value
is dynamically `nil`, then the function is executed as if it were
non-isolated.  Otherwise, it is executed as if it were isolated to
the unwrapped value.

When Swift determines whether two contexts have the same isolation,
it ignores implicit type conversions on isolated parameters and
captures, including promoting to an optional type.  For example, when
checking the call to `runIsolated` in the following code, `runIsolated`
is known to have the same isolation as `callFoo`:

```swift
func runIsolated(on: isolated (any Actor)?) {}

actor A {
  func run() {
    runIsolated(on: self)
  }
}

```

If a function is isolated to a value of optional type (`optA` in
the examples below), certain standard unwrappings of the value
are also known to be isolated:
- applying the optional-chaining operator to the value (e.g. `optA?`),
- applying the optional-forcing operator to the value (e.g. `optA!`), and
- references to `let` bindings formed from the value (e.g.
  `if let a = optA` or `guard let a = optA`).
For example, if a function is isolated to `optA: A?`, then the method
call `optA?.run()` is known to not cross an isolation boundary.

### Global actors

Polymorphism over actor isolation also needs to work for
[global actors][SE-0316].  However, the core model of global actor
isolation is based on attributes and type identity, not values.
The `GlobalActor` protocol requires global actor types to provide a
`static` property named `shared`, which encourages these types to
use a singleton pattern where there's at most one instance of the type
per process; however, this is neither enforced nor even semantically
required by SE-0316.  This unfortunately creates a situation where e.g.
actor isolation checking cannot treat a function that's known to be
isolated to an instance of `MainActor` as actually being `@MainActor`,
because in theory there could be a second instance of the `MainActor`
class in the program that isn't the one returned by `MainActor.shared`.
This is necessary when dealing with normal `actor` types but somewhat
tiresomely pedantic for global actors.

We propose that global actors be semantically limited to be singleton.
For now, this is an unenforced burden on implementors of global actors
(a low burden in practice because programmers rarely define new global
actors).  This permits Swift to assume that functions isolated to a
non-optional value of a global actor type are actually isolated to
the global actor exactly as if they were annotated with the attribute.

For example, in this example, the call to `runIsolated` is known to be
isolated to a value of `MyGlobalActor`, which is an actor that is assumed
to be globally singleton and therefore equivalent to the global actor
attribute on `foo()`:

```swift
@MyGlobalActor func foo() {
  runIsolated(on: MyGlobalActor.shared)
}
```

(This particular case does not require the singleton-type assumption;
Swift could do the same reasoning based on the use of the `static`
property.  However, there are more complex cases where actor values
are propagated around generically that do need the assumption.)

FIXME: as written, this rule suggests that this kind of value
isolation should turn around and impact the type system, which is
a difficult change that could also have ABI implications.

### Isolation controls for closures

The grammar of closure expressions is modified to allow the `nonisolated`
context-sensitive keyword alongside the `attributes`:

```
closure-expression → '{' attributes? closure-modifiers? closure-signature? statements? '}'
closure-modifiers → closure-modifier closure-modifiers?
closure-modifier → actor-isolation-modifier
```

Note that this follows the precedent of requiring `@` attributes to be
written before any other modifiers.

The grammar of a closure expression's capture list is modified to
allow the `isolated` keyword:

```
capture-list-item → capture-specifiers identifier 
capture-list-item → capture-specifiers identifier = expression 
capture-list-item → capture-specifiers self-expression
capture-specifiers → 'isolated'? capture-strength-specifier?
```

A closure expression is ill-formed if it has multiple isolation
specifications, i.e. one of:
- a global actor attribute, 
- an `actor-isolation-modifier` (currently always `nonisolated`),
- an `isolated` capture, or
- an `isolated` parameter, including by contextual typing.

Otherwise an explicit isolation specification takes precedence over any
of the standard rules for determining the static actor isolation of a
closure expression.  If a closure is `nonisolated`, it is non-isolated.
If a closure has an `isolated` capture, it is statically isolated to
the captured value, exactly as if it had an `isolated` parameter and
the capture expression was used as the argument.

An `isolated` capture cannot be `weak` because the dynamic nature of
weak references means the closure cannot be proven to share isolation
with other contexts, which introduces novel challenges for the
implementation.  This limitation could be removed in the future by
forcing isolation checking to be conservative in many places.  Whether
that would actually prove useful requires further investigation.

### `#isolation` default argument

The expression `#isolation` is allowed only as a default argument
expression, much like `#lineNumber`.  There are no declaration-side
restrictions on the type of the parameter, but specific uses of the
default argument may be ill-formed if the isolation reference
expression (see below) can't be converted to the parameter type.

The isolation reference expression depends on the static isolation
of the caller:
- If the caller is non-isolated, the expression is `nil`
  (`nil as (any Actor)?` if the parameter type is not optional).
- If the caller is isolated to a global actor `G`, the expression
  is `G.shared`.
- Otherwise, the expression is a reference to the caller's
  `isolated` parameter or capture.

### `@inheritsActorIsolation`

The attribute `@inheritsActorIsolation` can be placed on a parameter
declaration of a function, initializer, or subscript.  The attribute
is ill-formed if the type of the parameter is not a (possibly
optional) function type or has an `isolated` parameter.

If the corresponding argument to a parameter with
`@inheritsActorIsolation` in a direct use of the declaration is a
closure expression that does not include an isolation specification,
then the static isolation of the closure is the same as the static
isolation of the calling context *unless* the calling context is
isolated to a value of a non-global-actor type that is either not
captured or captured `weak` by the closure (in which case the closure
is not isolated).  (This rule is the same as is used by the `Task`
initializer.)

## Source compatibility

This proposal is principally additive in nature and should not
affect the compilation of a significant amount of existing code.
There are two exceptions:

- First, the proposal clarifies the behavior of isolation inference
  when the isolated actor is only weakly captured.  Swift currently
  treats the closure as isolated but does not generate reasonable
  code for the weak capture (FIXME: elaborate).  This could change
  behavior in some cases.

- Second, the proposal specifies that functions isolated to an
  instance of a global actor type are to be treated as isolated to
  the global actor.  This could change how such functions are
  type-checked, but this is unlikely to have significant impact
  on existing Swift code because it would require the use of
  `isolated` parameters specifically with a concrete global actor
  type, which has no effect in current code.

For these reasons, we believe that these source incompatibilities
are acceptable.

## ABI compatibility

This proposal does not affect the ABI.  The features added here
are declaration-driven and translate in terms of existing concepts
that are not reflected at runtime or ABI details such as symbol
mangling.

## Implications on adoption

It should be possible to adopt this feature immediately; it does
not depend on new library or runtime features.

Library adopters should be cautious about adding
`@inheritsActorIsolation` on existing API because it could affect
the inferred isolation of closures in their clients.  Uses of the
unofficial `@_inheritsActorContext` attribute can be safely replaced
with this new attribute, however, as the behavior is identical.

## Future directions

### Dynamically-isolated function types

Currently, function types in Swift can directly express two kinds of
static isolation: they can be non-isolated, or they can have global
actor isolation.  When a function with some other isolation needs to
be stored as an opaque value, there are two options available:

- If the function is isolated to the *current* actor, it can be
  given a non-`Sendable` function type.  This works because the
  value then cannot escape the actor at all and so can be assumed
  to only be called from a context with the appropriate isolation.
  However, this is only useful in narrow situations and generally
  does not help in the places where we want to be polymorphic about
  isolation.

- Otherwise, the function can be given a non-isolated `async` function
  type.  The function simply switches to the appropriate actor as
  an internal implementation detail.

This second solution is form of *type erasure*, and it is generally
very powerful.  However, it has three severe disadvantages.  The
first disadvantage is that the function is forced to become `async`,
even if it does not internally suspend for any reason except that
switch; this changes calling conventions and may make it harder to
fit the function into existing systems.  The second disadvantage is
that the function always does the executor switch internally, and
the caller has no ability to set things up to use the best executor
for the function in the first place.  The last disadvantage is
closely related: because there is always an internal switch between
contexts, there is no way to safely pass non-`Sendable` data to and
from the function.

These problems are all solved by only *statically* erasing the
isolation but still allowing it to be dynamically recovered.  This
is the key idea of dynamically-isolated function types: they are
"thicker" types that dynamically carry the actor isolation of the
function in every value.  This actor isolation can then be extracted
and used.

For example, while this proposal suggests that the `sequentialMap`
function could be written to use the `#isolation` default argument,
perhaps a better approach would be to take the transform as
a dynamically-isolated function value, then declare that
`sequentialMap` has the same isolation as that function.
This would have the same effect when passing a transform that's
isolated to the *current* actor, but consider what happens when
the transform is isolated to a *different* actor: instead of
running the body of `sequentialMap` on the current actor and
then switching back and forth with the transform's actor on every
iteration, the entire call to `sequentialMap` becomes a cohesive
operation on the transform's actor.

On a more basic level, the `Task` initializer could take the initial
function of the task as a dynamically-isolated function value
and then always start the function on the right executor,
without requiring any static optimization.

### Statically-isolated function types

In some situations, it would be useful to statically constrain
the isolation of a function type to a specific value.  For
example, the `async` method on a serial `DispatchQueue` takes
a closure that is naturally isolated to `self`.  This could
potentially be expressed as a statically-isolated function type,
which could be written as something like:

```swift
extension SerialDispatchQueue {
  func async(operation: @isolated(self) () -> ())
}
```

(Note that this example is unfortunately complicated by the fact that
`DispatchQueue` is an executor and not an actor.  To express this
usefully in terms of actor isolation, Swift would need other features
to draw the connection back to an actor and its isolated state.)

Statically-isolated function types are capable of giving a precise
static type to functions that would otherwise need their static
isolation to be type-erased.  As discussed in the section on
dynamically-isolated function types, there are functions whose
static isolation cannot be expressed in the type system.

The type of a function
that's isolated to a specific value must statically "erase" that
isolation: the function must either have a dynamically-isolated
function type (above) or a non-isolated `async` function type.  In
either case, our static knowledge of the function's isolated is lost.

As a general rule, preserving static information in the type system
gives both the programmer and the implementation more power and
flexibility.  For example, with statically-isolated function types,
Swift could understand that a first-class function value was
constrained to the current actor and therefore safely allow it to
be called with a non-`Sendable` argument.  It also does not require
any of the runtime overhead that dynamically-isolated function types
would entail.

The biggest problem with this as a future direction is that it is
very complicated to implement.  Statically-isolated function types
would add a restricted form of dynamical value dependence to Swift's
static type system, which is a major step in foundational complexity
for any language, requiring serious reconsideration of many basic
ideas in the implementation.

It is also unclear that there aren't simpler ways of achieving many
of the things that could be achieved with statically-isolated
function types.  For example, the specific problem of an actor
keeping function values that are isolated to the actor can be
solved with non-`Sendable` function types, which cannot escape
the actor and therefore must be executed with appropriate actor
isolation.

It would be possible to add statically-isolated function types at
an arbitrarily-later release.  This would have the downside that
Swift would not be infer a statically-isolated function type for
an existing function or closure without breaking source
compatibility.  However, this is already true, because it is
already possible to write functions and closures with isolation
that cannot be precisely typed today.

It is useful to consider statically-isolated function types and what
they would enable for Swift's function isolation system, but they
are likely to remain out of scope for the foreseeable future.

## Alternatives considered

(to be fleshed out)

## Acknowledgments

I'd like to especially thank Konrad Malawski, Doug Gregor, and
Holly Borla for their help in developing the ideas in this proposal.
