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

> This proposal expands on the previous proposals and incorporates the language
> steering groups feedback of exploring language features to solve the
> motivating problem. It also reuses the existing `@frozen` and documents a
> migration path for existing modules.

Revisions:
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

This proposal addresses the long standing behavioral difference of `enum`s in
Swift modules compiled with and without library evolution. This makes Swift
`enum`s vastly more useful in public API of non-resilient Swift libraries.

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

With the following proposed solution we want to achieve the following goals:
1. Align the differences between the two language dialects in a future language
   mode
2. Provide developers a path to opt-in to the new behavior before the new
   language mode so they can start declaring **new** extensible enumerations
3. Provide a migration path to the new behavior without forcing new SemVer
   majors

We propose to introduce a new language feature `ExtensibleEnums` that aligns the
behavior of enumerations in both language dialects. This will make **public**
enumerations in packages a safe default and leave maintainers the choice of
extending them later on. This language feature will become enabled by default in
the next language mode.

Modules consuming other modules with the language feature enabled will be
required to add an `@unknown default:`.

An example of using the language feature and the keywords is below:

```swift
/// Module A
public enum PizzaFlavor {
    case hawaiian
    case pepperoni
    case cheese
}

/// Module B
switch pizzaFlavor {  // error: Switch covers known cases, but 'MyEnum' may have additional unknown values, possibly added in future versions
case .hawaiian:
    throw BadFlavorError()
case .pepperoni:
    try validateNoVegetariansEating()
    return .delicious
case .cheese:
    return .delicious
}
```

Additionally, we propose to re-use the existing `@frozen` annotation to allow
developers to mark enumerations as non-extensible in non-resilient modules
similar to how it works in resilient modules already.

```swift
/// Module A
@frozen
public enum PizzaFlavor {
    case hawaiian
    case pepperoni
    case cheese
}

/// Module B
// The below doesn't require an `@unknown default` since PizzaFlavor is marked as frozen
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

Turning on the new language feature will be a semantically breaking change for
consumers of their module; hence, requiring a new SemVer major release of the
containing package. Some packages can release a new major and adopt the new
language feature right away; however, the ecosystem also contains packages that
try to avoid breaking API if at all possible. Such packages are often at the
very bottom of the dependency graph e.g. `swift-collections` or `swift-nio`. If
any of such packages releases a new major version it would effectively split the
ecosystem until all packages have adopted the new major. 

Packages that want to avoid breaking their API can use the new language feature
and the `@frozen` attribute in combination to unlock to possibility to declare
**new extensible** public enumerations but stay committed to the non-extensible
API of the already existing public enumerations. This is achieved by marking all
existing public enumerations with `@frozen` before turning on the language
feature.

### Implications on code in the same package

Code inside the same package still needs to exhaustively switch over
enumerations defined in the same package when the language feature is enabled.
Switches over enums of the same package containing an `@unknown default` will
produce a compiler warning.

### API breaking checker

The behavior of `swift package diagnose-api-breaking-changes` is also updated
to understand if the language feature is enabled and only diagnose new enum
cases as a breaking change in non-frozen enumerations.

## Source compatibility

- Enabling the language feature `ExtensibleEnums` in a module compiled without
resiliency that contains public enumerations is a source breaking change unless
all existing public enumerations are marked with `@frozen`
- Disabling the language feature `ExtensibleEnums` in a module compiled without
resiliency is a source compatible change since it implicitly marks all
enumerations as `@frozen`
- Adding a `@frozen` annotation to an existing public enumeration is a source
  compatible change

## ABI compatibility

The new language feature dos not affect the ABI, as it is already how modules
compiled with resiliency behave.

## Future directions

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

### Swift PM allowing multiple conflicting major versions in a single dependency graph

To reduce the impact of an API break on the larger ecosystem Swift PM could
allow multiple conflicting major versions of the same dependency in a single
dependency graph. This would allow a package to adopt the new language feature,
break their existing, and release a new major while having minimal impact on
the larger ecosystem.

## Alternatives considered

### Provide an `@extensible` annotation

We believe that the default behavior in both language dialects should be that
public enumerations are extensible. One of Swift's goals, is safe defaults and
the current non-extensible default in non-resilient modules doesn't achieve that
goal. That's why we propose a new language feature to change the default in a
future Swift language mode.

### Introducing a new annotation instead of using `@frozen`

An initial pitch proposed an new annotation instead of using `@frozen. The
problem with that approach was coming up with a reasonable behavior of how the
new annotation works in resilient modules and what the difference to `@frozen`
is. Feedback during this and previous pitches was that `@frozen` has more
implications than just the non-extensibility of enumerations but also impact on
ABI. We understand the feedback but still believe it is better to re-use the
same annotation and clearly document the additional behavior when used in
resilient modules.

### Introduce a `@preEnumExtensibility` annotation

We considered introducing an annotation that allows developers to mark
enumerations as pre-existing to the new language feature similar to how
`@preconcurrency` works. The problem with such an annotation is how the compiler
would handle this in consuming modules. It could either downgrade the warning
for the missing `@unknown default` case or implicitly synthesize one. However,
the only reasonable behavior for synthesized `@unknown default` case is to
`fatalError`. Furthermore, such an attribute becomes even more problematic to
handle when the module then extends the annotated enum; thus, making it possible
to hit the `@unknown default` case during runtime leading to potentially hitting
the `fatalError`.