# Extensible enums

* Proposal: [SE-NNNN](NNNN-extensible-enums.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin), [Franz Busch](https://github.com/FranzBusch), [Cory Benfield](https://github.com/lukasa)
* Review Manager: TBD
* Status: **Awaiting review**
* Bug: [apple/swift#55110](https://github.com/swiftlang/swift/issues/55110)
* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN)
* Upcoming Feature Flag: `ExtensibleEnums`
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

This proposal addresses the long standing behavioural difference of `enum`s in
Swift modules compiled with and without library evolution. This makes Swift
`enum`s vastly more useful in public API of non-resilient Swift libraries.

## Motivation

When Swift was enhanced to add support for "library evolution" mode (henceforth
called "resilient" mode), the Swift project had to make a number of changes to
support a movable scale between "maximally evolveable" and "maximally
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
behaviour of switch statements.

Consider the following simple library to your favourite pizza place:

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
the behaviour in switch statements changes.

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
behaviour for the missing case. The term for this is "exhaustiveness": in the
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
exhaustive switching behaviour are able to opt-into it.

However, in Swift today it is not possible for the default, "non-resilient"
dialect to opt-in to the extensible enumeration behaviour. That is, there is no
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

We propose to introduce a new language feature `ExtensibleEnums` that aligns the
behaviour of enumerations in both language dialects. This will make **public**
enumerations in packages a safe default and leave maintainers the choice of
extending them later on.

In modules with the language feature enabled, developers can use the existing
`@frozen` attribute to mark an enumeration as non-extensible, allowing consumers
of the module to exhaustively switch over the cases. This makes committing to the
API of an enum an active choice for developers.

Modules consuming other modules with the language feature enabled will be forced
to add an `@unknown default:` case to any switch state for enumerations that are
not marked with `@frozen`. Importantly, this only applies to enums that are
imported from other modules that are not in the same package. For enums inside
the same modules of the declaring package switches are still required to be
exhaustive and don't require an `@unknown default:` case.

Since enabling a language feature applies to the whole module at once we also
propose adding a new attribute `@extensible` analogous to `@frozen`. This
attribute allows developers to make a case-by-case decision on each enumeration
if it should be extensible or not by applying one of the two attributes. The
language feature `ExtensibleEnums` can be thought of as implicitly adding
`@extensible` to all enums that are not explicitly marked as `@frozen`.

In resilient modules, the `@extensible` attribute doesn't affect API nor ABI
since the behaviour of enumerations in modules compiled with library evolution
mode are already extensible by default. We believe that extensible enums are the
right default choice in both resilient and non-resilient modules and the new
proposed `@extensible` attribute primiarly exists to give developers a migration
path.

In non-resilient modules, adding the `@extensible` attribute to non-public enums
will produce a warning since those enums can only be matched exhaustively.

## Source compatibility

Enabling the language feature `ExtensibleEnums` in a module that contains public
enumerations is a source breaking change.
Changing the annotation from `@frozen` to `@extensible` is a source breaking
change. 
Changing the annotation from `@extensible` to `@frozen` is a source compatible
change and will only result in a warning code that used `@unknown default:`
clause. This allows developers to commit to the API of an enum in a non-source
breaking way.
Adding an `@extensible` annotation to an exisitng public enum is a source
breaking change in modules that have **not** enabled the `ExtensibleEnums`
language features or are compiled with resiliency.

## Effect on ABI stability

This attribute does not affect the ABI, as it is a no-op when used in a resilient library.

## Effect on API resilience

This proposal only affects API resilience of non-resilient libraries, by enabling more changes to be made without API breakage.

## Future directions

### Enable `ExtensibleEnums` by default in a future language mode

We believe that extensible enums should be default in the language to remove the
common pitfall of using enums in public API and only later on realising that
those can't be extended in an API compatible way. Since this would be a large
source breaking change it must be gated behind a new language mode.

## Alternatives considered

### Only provide the `@extensible` annotation

We believe that the default behaviour in both language dialects should be that
public enumerations are extensible. One of Swift's goals, is safe defaults and
the current non-extensible default in non-resilient modules doesn't achieve that
goal. That's why we propose a new language feature to change the default in a
future Swift language mode.