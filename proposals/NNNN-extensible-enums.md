# Extensible enums

* Proposal: [SE-NNNN](NNNN-extensible-enums.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin), [Franz Busch](https://github.com/FranzBusch), [Cory Benfield](https://github.com/lukasa)
* Review Manager: TBD
* Status: **Awaiting review**
* Bug: [apple/swift#55110](https://github.com/swiftlang/swift/issues/55110)
* Implementation: [apple/swift#79580](https://github.com/swiftlang/swift/pull/79580)
* Upcoming Feature Flag: `ExtensibleEnums`
* Review: ([pitch](https://forums.swift.org/t/pitch-extensible-enums-for-non-resilient-modules/77649))

Previously pitched in:
- https://forums.swift.org/t/extensible-enumerations-for-non-resilient-libraries/35900
- https://forums.swift.org/t/pitch-non-frozen-enumerations/68373

Revisions:
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

When Swift was enhanced to add support for "library evolution" mode (henceforth
called "resilient" mode), the Swift project had to make a number of changes to
support a movable scale between "maximally evolvable" and "maximally
performant". This is because it is necessary for an ABI stable library to be
able to add new features and API surface without breaking pre-existing compiled
binaries. While by-and-large this was done without introducing feature
mismatches between the "resilient" and default "non-resilient" language
dialects, the `@frozen` attribute when applied to enumerations managed to
introduce a difference. This difference was introduced late in the process of
evolving SE-0192, and this proposal would aim to address it.

`@frozen` is a very powerful attribute. It can be applied to both structures and
enumerations. It has a wide ranging number of effects, including exposing their
size directly as part of the ABI and providing direct access to stored
properties. However, on enumerations it happens to also exert effects on the
behavior of switch statements.

Consider the following simple library to your favorite pizza place:

```swift
public enum PizzaFlavor {
    case hawaiian
    case pepperoni
    case cheese
}

public func bakePizza(flavor: PizzaFlavor)
```

Depending on whether the library is compiled with library evolution mode
enabled, what the caller can do with the `PizzaFlavor` enum varies. Specifically,
the behavior in switch statements changes.

In the _standard_, "non-resilient" mode, users of the library can write
exhaustive switch statements over the enum `PizzaFlavor`:

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

This code will happily compile. If the author of the above switch statement was
missing a case (perhaps they forgot `.hawaiian` is a flavor), the compiler will
error, and force the user to either add a `default:` clause, or to express a
behavior for the missing case. The term for this is "exhaustiveness": in the
default "non-resilient" dialect, the Swift compiler will ensure that all switch
statements over enumerations cover every case that is present.

There is a downside to this mode. If the library wants to add a new flavour
(maybe `.veggieSupreme`), they are in a bind. If any user anywhere has written
an exhaustive switch over `PizzaFlavor`, adding this flavor will be an API and
ABI breaking change, as the compiler will error due to the missing case
statement for the new enum case.

Because of the implications on ABI and the requirement to be able to evolve
libraries with public enumerations in their API, the resilient language dialect
behaves differently. If the library was compiled with `enable-library-evolution`
turned on, when a user attempts to exhaustively switch over the `PizzaFlavor`
enum the compiler will emit a warning, encouraging users to add an `@unknown
default:` clause. Thus, to avoid the warning the user would be forced to
consider how new enumeration cases should be treated. They may arrive at
something like this:

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

When a resilient library knows that an enumeration will not be extended, and
wants to improve the performance of using it, the author can annotate the enum
with `@frozen`. This annotation has a wide range of effects, but one of its
effects is to enable callers to perform exhaustive switches over the frozen
enumeration. Thus, resilient library authors that are interested in the
exhaustive switching behavior are able to opt-into it.

However, in Swift today it is not possible for the default, "non-resilient"
dialect to opt-in to the extensible enumeration behavior. That is, there is no
way for a Swift package to be able to evolve a public enumeration without
breaking the API. This is a substantial limitation, and greatly reduces the
utility of enumerations in non-resilient Swift. Over the past years, many
packages ran into this limitation when trying to express APIs using enums. As a
non-exhaustive list of problems this can cause:

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

We propose to introduce a new `@extensible` attribute that can be applied to
enumerations to mark them as extensible. Such enums will behave the same way as
non-frozen enums from resilient Swift libraries.

An example of using the new attribute is below:

```swift
/// Module A
@extensible
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
unit of code. Switching over an `@extensible` enum inside the same module or
package will require exhaustive matching to avoid unnecessary `@unknown default`
cases.

### `@extensible` and `@frozen`

An enum cannot be `@frozen` and `@extensible` at the same time. Thus, marking an
enum both `@extensible` and `@frozen` is not allowed and will result in a
compiler error.

### API breaking checker

The behavior of `swift package diagnose-api-breaking-changes` is also updated
to understand the new `@extensible` attribute.

## Source compatibility

### Resilient modules

- Adding or removing the `@extensible` attribute has no-effect since it is the default in this language dialect.

### Non-resilient modules

- Adding the `@extensible` attribute to a public enumeration is an API breaking change.
- Removing the `@extensible` attribute from a public enumeration is an API stable change.

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

### `@unknown case`

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

### Introduce a `@preEnumExtensibility` annotation

We considered introducing an annotation that allows developers to mark
enumerations as pre-existing to the `@extensible` annotation similar to how
`@preconcurrency` works. Such an annotation seems to work initially when
existing public enumerations are marked as `@preEnumExtensibility` instead of
`@extensible`. It would result in the error about the missing `@unknown default`
case to be downgraded as a warning. However, such an annotation still doesn't
allow new cases to be added since there is no safe default at runtime when
encountering an unknown case. Below is an example how such an annotation would
work and why it doesn't allow existing public enums to become extensible.

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
@preEnumExtensibility @extensible
public enum Foo {
  case foo
}

// Package B now emits a warning downgraded from an error
switch foo { // warning: Enum might be extended later. Add an @unknown default case.
case .foo: break
}

// Later Package A decides to extend the enum
@preEnumExtensibility  @extensible
public enum Foo {
  case foo
  case bar
}

// Package B didn't add the @unknown default case yet. So now we we emit a warning and an error
switch foo { // error: Unhandled case bar & warning: Enum might be extended later. Add an @unknown default case.
case .foo: break
}
```