# Nonexhaustive enums

* Proposal: [SE-0487](0487-extensible-enums.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin), [Franz Busch](https://github.com/FranzBusch), [Cory Benfield](https://github.com/lukasa)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Implemented (Swift 6.2.3)**
* Bug: [apple/swift#55110](https://github.com/swiftlang/swift/issues/55110)
* Implementation: [apple/swift#80503](https://github.com/swiftlang/swift/pull/80503)
* Review: ([pitch](https://forums.swift.org/t/pitch-extensible-enums-for-non-resilient-modules/77649)) ([first review](https://forums.swift.org/t/se-0487-extensible-enums/80114)) ([second review](https://forums.swift.org/t/second-review-se-0487-extensible-enums/80837)) ([acceptance](https://forums.swift.org/t/accepted-se-0487-nonexhaustive-enums/81508))

Previously pitched in:

- https://forums.swift.org/t/extensible-enumerations-for-non-resilient-libraries/35900
- https://forums.swift.org/t/pitch-non-frozen-enumerations/68373

Revisions:
- Renamed the attribute to `@nonexhaustive` and `@nonexhaustive(warn)` respectively
- Re-focused this proposal on introducing a new `@extensible` attribute and
  moved the language feature to a future direction
- Introduced a second annotation `@nonExtensible` to allow a migration path into
  both directions
- Added future directions for adding additional associated values
- Removed both the `@extensible` and `@nonExtensible` annotation in favour of
  re-using the existing `@frozen` annotation
- Added the high level goals that this proposal aims to achieve
- Expanded on the proposed migration path for packages with regards to their
  willingness to break API
- Added future directions for exhaustive matching for larger compilation units
- Added alternatives considered section for a hypothetical
  `@preEnumExtensibility`
- Added a section for `swift package diagnose-api-breaking-changes`

## Introduction

This proposal provides developers the capabilities to mark public enums in
non-resilient Swift libraries as extensible. This makes Swift `enum`s vastly
more useful in public API of such libraries.

## Motivation

When Swift was enhanced to add support for ABI-stable libraries that were built with
"library evolution" enabled ("resilient" libraries as we call them in this proposal),
the Swift language had to support these libraries vending enums that might have cases
added to them in a later version. Swift supports exhaustive switching over cases.
When binaries are compiled against a ABI-stable library they need to be able to handle the
addition of a new case by that library later on, without needing to be rebuilt.

Consider the following simple library to your favorite pizza place:

```swift
public enum PizzaFlavor {
    case hawaiian
    case pepperoni
    case cheese
}
```

In the standard "non-resilient" mode, users of the library can write exhaustive switch
statements over the enum `PizzaFlavor`:

```swift
switch pizzaFlavor {
case .hawaiian:
    throw BadFlavorError()
case .pepperoni:
    try validateNoVegetariansEating()
    return .delicious
case .cheese:
    return .delicious
}
```

Swift requires switches to be exhaustive i.e. the must handle every possibility.
If the author of the above switch statement was missing a case (perhaps they forgot
`.hawaiian` is a flavor), the compiler will error, and force the user to either add a
`default:` clause, or to add the missing case.

If later a new case is added to the enum (maybe `.veggieSupreme`), exhaustive switches
over that enum might no longer be exhaustive. This is often _desirable_ within a single
codebase (even one split up into multiple modules). A case is added, and the compiler will
assist in finding all the places where this new case must be handled.

But it presents a problem for authors of both resilient and non-resilient libraries:

- For non-resilient libraries, adding a case is a source-breaking API change: clients
exhaustively switching over the enum will no longer compile. So can only be done with
a major semantic version bump.
- For resilient libraries, even that is not an option. An ABI-stable library cannot allow
a situation where a binary that has not yet been recompiled can no longer rely on its
switches over an enum are exhaustive.

Because of the implications on ABI and the requirement to be able to evolve
libraries with public enumerations in their API, the resilient language dialect introduced
"non-exhaustive enums" in [SE-0192](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0192-non-exhaustive-enums.md).

If the library was compiled with `-enable-library-evolution`, when a user attempts to
exhaustively switch over the `PizzaFlavor` enum the compiler will emit an error
(when in Swift 6 language mode, a warning in prior language modes), requiring users
to add an `@unknown default:` clause:

```swift
switch pizzaFlavor {
case .hawaiian:
    throw BadFlavorError()
case .pepperoni:
    try validateNoVegetariansEating()
    return .delicious
case .cheese:
    return .delicious
@unknown default:
    try validateNoVegetariansEating()
    return .delicious
}
```

The user is forced to specify how cases are handled if they are introduced later. This
allows ABI-stable libraries to add cases without risking undefined behavior in client
binaries that haven't yet been recompiled.

When a resilient library knows that an enumeration will never be extended, the author
can annotate the enum with `@frozen`, which in the case of enums is a guarantee that no
further cases can be added. For example, the `Optional` type in the standard library is
frozen, as no third option beyond `some` and `none` will ever be added. This brings
performance benefits, and also the convenience of not requiring an `@unknown default` case.

`@frozen` is a powerful attribute that can be applied to both structs and enums. It has a
wide ranging number of effects, including exposing their size directly as part of the ABI
and providing direct access to stored properties. However, on enums it happens to
have source-level effects on the behavior of switch statements by clients of a library.
This difference was introduced late in the process of reviewing SE-0192.

Extensibility of enums is also desirable for non-resilient libraries. Without it, there is no
way for a Swift package to be able to evolve a public enumeration without breaking the API.
However, in Swift today it is not possible for the default, "non-resilient" dialect to opt-in
to the extensible enumeration behavior. This is a substantial limitation, and greatly reduces
the utility of enumerations in non-resilient Swift.
 
Over the past years, many packages have run into this limitation when trying to express APIs
using enums. As a non-exhaustive list of problems this can cause:

- Using enumerations to represent `Error`s is inadvisable, as if new errors need
  to be introduced they cannot be added to existing enumerations. This leads to
  a proliferation of `Error` enumerations. "Fake" enumerations can be made using
  `struct`s and `static let`s, but these do not work with the nice `Error`
  pattern-match logic in catch blocks, requiring type casts.
- Using an enumeration to refer to a group of possible ideas without entirely
  exhaustively evaluating the set is potentially dangerous, requiring a
  deprecate-and-replace if any new elements appear.
- Using an enumeration to represent any concept that is inherently extensible is
  tricky. For example, `SwiftNIO` uses an enumeration to represent HTTP status
  codes. If new status codes are added, SwiftNIO needs to either mint new
  enumerations and do a deprecate-and-replace, or it needs to force these new
  status codes through the .custom enum case.

This proposal plans to address these limitations on enumerations in
non-resilient Swift.

## Proposed solution

We propose to introduce a new `@nonexhaustive` attribute that can be applied to
enumerations to mark them as extensible. Such enums will behave the same way as
non-frozen enums from resilient Swift libraries.

An example of using the new attribute is below:

```swift
/// Module A
@nonexhaustive
public enum PizzaFlavor {
    case hawaiian
    case pepperoni
    case cheese
}

/// Module B
switch pizzaFlavor { // error: Switch covers known cases, but 'MyEnum' may have additional unknown values, possibly added in future versions
case .hawaiian:
    throw BadFlavorError()
case .pepperoni:
    try validateNoVegetariansEating()
    return .delicious
case .cheese:
    return .delicious
}
```

### Exhaustive switching inside same module/package

Code inside the same module or package can be thought of as one co-developed
unit of code. Inside the same module or package, switching exhaustively over an
`@nonexhaustive` enum inside will not require an`@unknown default`, and using
one will generate a warning.

### `@nonexhaustive` and `@frozen`

An enum cannot be `@frozen` and `@nonexhaustive` at the same time. Thus, marking an
enum both `@nonexhaustive` and `@frozen` is not allowed and will result in a
compiler error.

### API breaking checker

The behavior of `swift package diagnose-api-breaking-changes` is also updated
to understand the new `@nonexhaustive` attribute.

### Staging in using `@nonexhaustive(warn)`

We also propose adding a new `@nonexhaustive(warn)` attribute that can be used
to mark enumerations as pre-existing to when they became extensible.This is
useful for developers that want to stage in changing an existing non-extensible
enum to be extensible over multiple releases. Below is an example of how this
can be used:

```swift
// Package A
public enum Foo {
  case foo
}

// Package B
switch foo {
case .foo: break
}

// Package A wants to make the existing enum extensible
@nonexhaustive(warn)
public enum Foo {
  case foo
}

// Package B now emits a warning downgraded from an error
switch foo { // warning: Enum might be extended later. Add an @unknown default case.
case .foo: break
}

// Later Package A decides to extend the enum and releases a new major version
@nonexhaustive(warn)
public enum Foo {
  case foo
  case bar
}

// Package B didn't add the @unknown default case yet. So now we we emit a warning and an error
switch foo { // error: Unhandled case bar & warning: Enum might be extended later. Add an @unknown default case.
case .foo: break
}
```

While the `@nonexhaustive(warn)` attribute doesn't solve the need of requiring
a new major when a new case is added it allows developers to stage in changing
an existing non-extensible enum to become extensible in a future release by
surfacing a warning about this upcoming break early.

## Source compatibility

### Resilient modules

- Adding or removing the `@nonexhaustive` attribute has no-effect since it is the default in this language dialect.
- Adding the `@nonexhaustive(warn)` attribute has no-effect since it only downgrades the error to a warning.
- Removing the `@nonexhaustive(warn)` attribute is an API breaking since it upgrades the warning to an error again.

### Non-resilient modules

- Adding the `@nonexhaustive` attribute is an API breaking change.
- Removing the `@nonexhaustive` attribute is an API stable change.
- Adding the `@nonexhaustive(warn)` attribute has no-effect since it only downgrades the error to a warning.
- Removing the `@nonexhaustive(warn)` attribute is an API breaking since it upgrades the warning to an error again.

## ABI compatibility

The new attribute does not affect the ABI of an enum since it is already the
default in resilient modules.

## Future directions

### Aligning the language dialects

In a previous iteration of this proposal, we proposed to add a new language
feature to align the language dialects in a future language mode. The main
motivation behind this is that the current default of non-extensible enums is a
common pitfall and results in tremendous amounts of unnoticed API breaks in the
Swift package ecosystem. We still believe that a future proposal should try
aligning the language dialects. This proposal is focused on providing a first
step to allow extensible enums in non-resilient modules.

Regardless of whether a future language mode changes the default for non-resilient
libraries, a way of staging in this change will be required (similar to how the
`@preconcurency` attribute facilitated incremental adoption of Swift concurrency).

### `@unknown catch`

Enums can be used for errors. Catching and pattern matching enums could add
support for an `@unknown catch` to make pattern matching of typed throws align
with `switch` pattern matching.

### Allow adding additional associated values

Adding additional associated values to an enum can also be seen as extending it
and we agree that this is interesting to explore in the future. However, this
proposal focuses on solving the primary problem of the usability of public
enumerations in non-resilient modules.

### Larger compilation units than packages

During the pitch it was brought up that a common pattern for application
developers is to split an application into multiple smaller packages. Those
packages are versioned together and want to have the same exhaustive matching
behavior as code within a single package. As a future direction, build and
package tooling could allow to define larger compilation units to express this.
Until then developers are encouraged to use `@frozen` attributes on their
enumerations to achieve the same effect.

## Alternatives considered

### Different names for the attribute

We considered different names for the attribute such as `@nonFrozen` or
`@extensible`; however, we felt that `@nonexhaustive` communicates the idea of
an extensible enum more clearly.
