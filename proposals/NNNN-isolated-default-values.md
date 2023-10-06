# Isolated default value expressions

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Holly Borla](https://github.com/hborla)
* Review Manager: TBD
* Status: **Awaiting implementation** or **Awaiting review**
* Bug: *if applicable* [apple/swift#58177](https://github.com/apple/swift/issues/58177)
* Implementation: [apple/swift#68794](https://github.com/apple/swift/pull/68794)
* Upcoming Feature Flag: `-enable-upcoming-feature IsolatedDefaultValues`
* Previous Proposal: *if applicable* [SE-XXXX](XXXX-filename.md)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

Default value expressions are permitted for default arguments and default stored property values. There are several issues with the current actor isolation rules for default value expressions: the rules for stored properties admit data races, the rules for default argument values are overly restrictive, and the rules between the different places you can use default value expressions are inconsistent with each other, making the actor isolation model harder to understand. This proposal unifies the actor isolation rules for default value expressions, eliminates data races, and improves expressivity by safely allowing isolation for default values.

## Motivation

The current actor isolation rules for initial values of stored properties admit data races. For example, the following code is currently valid:

```swift
@MainActor func requiresMainActor() -> Int { ... }
@AnotherActor func requiresAnotherActor() -> Int { ... }

class C {
  @MainActor var x1 = requiresMainActor()
  @AnotherActor var x2 = requiresAnotherActor()

  nonisolated init() {} // okay???
}
```

The above code allows any context to initialize an instance of `C()` through a synchronous, non-isolated `init` that synchronously calls both a `@MainActor`-isolated and a `@AnotherActor`-isolated function, violating actor isolation checking and enabling `requiresMainActor()` and `requiresAnotherActor()` to run concurrently with other code on those respective actors.

Similarly, the current actor isolation rules for default argument values do not admit data races, but default argument values are always `nonisolated` which is overly restrictive. This rule prohibits programmers from making `@MainActor`-isolated calls in default argument values of `@MainActor`-isolated functions that are only ever called from the main actor. For example, the following code is not valid even though it is perfectly safe:

```swift
@MainActor class C { ... }

@MainActor func f(c: C = C()) { ... } // error

@MainActor func useFromMainActor() {
  f()
}
```

## Proposed solution

I propose allowing default value expressions to require the caller to meet an isolation requirement in order to use the default value. The isolation requirement is inferred from the default value expression. If the caller does not meet the isolation requirement, then a value must be written explicitly for the argument or the stored property. This rule makes the stored property example above invalid at the point of the `nonisolated` initializer, because the isolation requirement of the default values for the stored properties is not satisfied. This rule also makes the default argument example above valid, because the `@MainActor` isolation requirement for the default argument of `f` is satisfied by the caller.

## Detailed design

### Inference of default value isolation requirements

Default value expressions are always evaluated synchronously. All calls that are made during the evaluation of the expression must also be synchronous. If the callee is isolated, then the default value expression must already be in the same isolation domain in order to make the call synchronously. So, for a given default value expression, the inferred isolation is the required isolation of its subexpressions. For example:

```swift
@MainActor func requiresMainActor() -> Int { ... }

@MainActor func useDefault(value: Int = requiresMainActor()) { ... }
```

In the above code, the default argument for `value` requires `@MainActor` isolation, because the default value calls `requiresMainActor()` which is isolated to `@MainActor`.

A default value expression must only have one required isolation; it is an error for a default value expression to contain multiple callees with different actor isolation. For example:

```swift
@MainActor func requiresMainActor() -> Int { ... }
@AnotherActor func requiresAnotherActor() -> Int { ... }

@MainActor func useDefault(
  value: (Int, Int) = (requiresMainActor(), requiresAnotherActor()) // error!
) {}
```

The above example is invalid because the default argument for `value` requires both `@MainActor` and `@AnotherActor`, but the caller can never satisfy both isolation requirements simultaneously.

#### Closures

Evaluating a closure literal itself can happen in any isolation domain; the actor isolation of a closure only applies when calling the closure. An actor-isolated closure enables the closure body to make calls within that isolation domain synchronously. For a closure literal in a default value expression that is not explicitly annotated with actor isolation, the inferred isolation of the closure is the union of isolation contexts of all callees in the closure body for synchronous calls. For example:

```swift
@MainActor func requiresMainActor() -> Int { ... }

@MainActor func useDefaultClosure(
  closure: () -> Void = {
    requiresMainActor()
  }
) {}
```

The above `useDefaultClosure` function has a default argument value that is a closure literal. The closure body calls a `@MainActor`-isolated function synchronously, therefore the closure itself must be `@MainActor` isolated.

Note that the inferred actor isolation of a closure literal can never be an actor instance based on the following two properties:

1. To be isolated to an actor instance, a closure must either have its own (explicit) isolated parameter or capture an isolated parameter from its enclosing context.
2. Closure literals in default arguments cannot capture values.

### Enforcing default value isolation requirements

#### Default argument values

Isolation requirements for default argument expressions are enforced at the caller. If the caller is not in the required isolation domain, the default argument cannot be used and the argument must be specified explicitly. For example:

```swift
@MainActor func requiresMainActor() -> Int { ... }

@MainActor func useDefault(value: Int = requiresMainActor()) { ... }

@MainActor func mainActorCaller() {
  useDefault() // okay
}

func nonisolatedCaller() async {
  useDefault() // error

  useDefault(value: await requiresMainActor()) // okay
}
```

#### Stored property initial values

Isolation requirements for default initializer expressions for stored properties apply in the body of initializers. If an `init` does not match the isolation of the initializer expression, the initialization of that stored property is not emitted at the beginning of the `init`. Instead, the stored property must be explicitly initialized in the body of the `init`. For example:

```swift
@MainActor func requiresMainActor() -> Int { ... }
@AnotherActor func requiresAnotherActor() -> Int { ... }

class C {
  @MainActor var x1: Int = requiresMainActor()
  @AnotherActor var x2: Int = requiresAnotherActor()

  nonisolated init() {} // error

  nonisolated init(x1: Int, x2: Int) { // okay
    self.x1 = x1
    self.x2 = x2
  }

  @MainActor init(x2: Int) { // okay
    // 'self.x1' gets assigned to the default value 'requiresMainActor()'
    self.x2 = x2
  }
}
```

In the above example, the no-parameter `nonisolated init()` is invalid, because it does not initialize `self.x1` and `self.x2`. Because the default initializer expressions require different actor isolation, those values are not used in the `nonisolated` initializer. The other two initializers are valid.

### Default value isolation in memberwise initializers

For structs, default initializer expressions for stored properties are used as default argument values to the compiler-generated memberwise initializer. In this case, the default argument value shares the same required isolation as the default initializer expression. Because the default values are always evaluated in the caller's context, all the memberwise initializer does is initialize each field, which can always be performed in a `nonisolated` context. In the interest of only applying global actor isolation when it's necessary for the code to run on the global actor, this proposal also changes the isolation of memberwise initializers to be `nonisolated`.

## Source compatibility

The actor isolation rules for initial values of stored properties are stricter than what is currently accepted in Swift 5 mode in order to eliminate data races. The isolation rules for stored properties will be staged in under the `IsolatedDefaultValues` upcoming feature identifier.

## ABI compatibility

This is a change to actor isolation checking with no impact on ABI.

## Implications on adoption

This feature can be freely adopted and un-adopted in source code with no deployment constraints and without affecting source or ABI compatibility.

## Alternatives considered

### Remove isolation from all default initializer expressions

SE-0327 originally proposed changing default initializer expressions for stored properties to always be `nonisolated`, matching the current default argument value rules. However, this change was implemented and later reverted because it impacted a lot of code that followed a common pattern: a `@MainActor`-isolated type with stored properties that have default values that call the initializers of other `@MainActor`-isolated types. In some cases, it's possible to make the initializer of a `@MainActor` type `nonisolated`, but many of these cases do access `@MainActor`-isolated properties and functions in the body of the initializer.

## Acknowledgments

Thank you to Kavon Farvardin for implementing the default initializer expression rules originally proposed by SE-0327 and discovering the usability issues outlined in this proposal. Thank you to John McCall for the observation that memberwise initializers can and should be `nonisolated`.