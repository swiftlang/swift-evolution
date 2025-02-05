# Extensible enums

* Proposal: [SE-NNNN](NNNN-extensible-enums.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin), [Franz Busch](https://github.com/FranzBusch), [Cory Benfield](https://github.com/lukasa)
* Review Manager: TBD
* Status: **Awaiting review**
* Bug: [apple/swift#55110](https://github.com/swiftlang/swift/issues/55110)
* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN)
* Upcoming Feature Flag: `ExtensibleEnums`
* Review: ([pitch](https://forums.swift.org/...))

Previously pitched in:
- https://forums.swift.org/t/extensible-enumerations-for-non-resilient-libraries/35900
- https://forums.swift.org/t/pitch-non-frozen-enumerations/68373

> **Differences to previous proposals**

> This proposal expands on the previous proposals and incorperates the language
> steering groups feedback of exploring language features to solve the
> motivating problem. It also provides a migration path for existing modules.

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
extending them later on. We also propose to enable this new language feature by
default with the next lagnuage mode.

We also propose to introduce two new attributes.
- `@nonExtensible`: For marking an enumeration as not extensible.
- `@extensible`: For marking an enumeration as extensible.

Modules consuming other modules with the language feature enabled will be
required to add an `@unknown default:` case to any switch state for enumerations
that are not marked with `@nonExtensible`.

An example of using the language feature and the keywords is below:

```swift
/// Module A
@extensible // or language feature ExtensibleEnums is enabled
enum MyEnum {
  case foo
  case bar
}

@nonExtensible 
enum MyFinalEnum {
    case justMe
}

/// Module B
switch myEnum { // error: Switch covers known cases, but 'MyEnum' may have additional unknown values, possibly added in future versions
    case .foo: break
    case .bar: break
}

// The below produces no warnings since the enum is marked as nonExtensible
switch myFinalEnum {
    case .justMe: break
}
```

## Detailed design

### Migration path

The proposed new language feature is the first langauge feature that has impact
on the consumers of a module and not the module itself. Enabling the langauge
feature in a non-resilient module with public enumerations is a source breaking
change.

The two proposed annotations `@extensible/@nonExtensible` give developers tools
to opt-in to the new language feature or in the future language mode without
breaking their consumers. This paves a path for a gradual migration. Developers
can mark all of their exisiting public enumerations as `@nonExtensible` and then
turn on the language feature. Similarly, developers can also mark new
enumerations as `@extensible` without turning on the language feature yet.

In a future language mode, individual modules can still be opted in one at a
time into the new language mode and apply the annotations as needed to avoid
source breakages.

When the language feature is turned on and a public enumeration is marked as
`@extensible` it will produce a warning that the annotation isn't required.

In non-resilient modules without the language feature turned on, adding the
`@extensible` attribute to non-public enums will produce a warning since those
enums can only be matched exhaustively.

### Implications on code in the same package

Code inside the same package still needs to exhaustively switch over
enumerations defined in the same package. Switches over enums of the same
package containing an `@unknown default` will produce a compiler warning.

### Impact on resilient modules & `@frozen` attribute

Explicitly enabling the language feature in resilient modules will produce a
compiler warning since that is already the default behaviour. Using the
`@nonExtensible` annotation will lead to a compiler error since users of
resilient modules must use the `@frozen` attribute instead.

Since some modules support compiling in resilient and non-resilient modes,
developers need a way to mark enums as non-extensible for both. `@nonExtensible`
produces an error when compiling with resiliency; hence, developers must use
`@frozen`. To make supporting both modes easier `@frozen` will also work in
non-resilient modules and make enumerations non extensible.

## Source compatibility

- Enabling the language feature `ExtensibleEnums` in a module that contains
public enumerations is a source breaking change unless all existing public
enumerations are marked with `@nonExtensible`
- Adding an `@extensible` annotation to an exisitng public enum is a source
breaking change in modules that have **not** enabled the `ExtensibleEnums`
language features or are compiled with resiliency.
- Changing the annotation from `@nonExtensible/@frozen` to `@extensible` is a
source breaking change. 
- Changing the annotation from `@extensible` to `@nonExtensible/@frozen` is a
source compatible change and will only result in a warning code that used
`@unknown default:` clause. This allows developers to commit to the API of an
enum in a non-source breaking way.

## ABI compatibility
The new attributes do not affect the ABI, as it is a no-op when used in a resilient library.

## Future directions

### `@unkown case`

Enums can be used for errors. Catching and pattern matching enums could add
support for an `@unknown catch` to make pattern matching of typed throws align
with `switch` pattern matching.

### Allow adding additional associated values

Adding additional associated values to an enum can also be seen as extending it
and we agree that this is interesting to explore in the future. However, this
proposal focuses on solving the primary problem of the unusability of public
enumerations in non-resilient modules.

## Alternatives considered

### Only provide the `@extensible` annotation

We believe that the default behaviour in both language dialects should be that
public enumerations are extensible. One of Swift's goals, is safe defaults and
the current non-extensible default in non-resilient modules doesn't achieve that
goal. That's why we propose a new language feature to change the default in a
future Swift language mode.

### Usign `@frozen` and introducing `@nonFrozen`

We considered names such as `@nonFrozen` for `@extensible` and using `@frozen`
for `@nonExtensible`; however, we believe that _frozen_ is a concept that
includes more than exhaustive matching. It is heavily tied to resiliency  and
also has ABI impact. That's why decoupled annotations that only focus on the
extensability is better suited. `@exhaustive/@nonExhaustive` would fit that bill
as well but we believe that `@extensible` better expresses the intention of the
author.
