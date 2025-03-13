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
4. Provide tools for developers to treat dependencies as source stable

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

### Migration paths

The following section is outlining the migration paths and tools we propose to
provide for different kinds of projects to adopt the proposed feature. The goal
is to reduce churn across the ecosystem while still allowing us to align the
default behavior of enums. There are many scenarios why these migration paths
must exist such as:

- Projects split up into multiple packages
- Projects build with other tools than Swift PM
- Projects explicitly vendoring packages without wanting to modify the original
  source
- Projects that prefer to deal with source breaks as they come up rather than
  writing source-stable code

#### Semantically versioned packages

Semantically versioned packages are the primary reason for this proposal. The
expected migration path for packages when adopting the proposed feature is one
of the two:

- API stable adoption by turning on the feature and marking all existing public
  enums with `@frozen`
- API breaking adoption by turning on the feature and tagging a new major if the
  public API contains enums

### Projects with multiple non-semantically versioned packages

A common project setup is splitting the code base into multiple packages that
are not semantically versioned. This can either be done by using local packages
or by using _revision locked_ dependencies. The packages in such a setup are
often considered part of the same logical collection of code and would like to
follow the same source stability rules as same module or same package code. We
propose to extend then package manifest to allow overriding the package name
used by a target.

```swift
extension SwiftSetting {
    /// Defines the package name used by the target.
    ///
    /// This setting is passed as the `-package-name` flag
    /// to the compiler. It allows overriding the package name on a
    /// per target basis. The default package name is the package identity.
    ///
    /// - Important: Package names should only be aligned across co-developed and
    ///  co-released packages.
    ///
    /// - Parameters:
    ///   - name: The package name to use.
    ///   - condition: A condition that restricts the application of the build
    /// setting.
    public static func packageName(_ name: String, _ condition: PackageDescription.BuildSettingCondition? = nil) -> PackageDescription.SwiftSetting
}
```

This allows to construct arbitrary package _domains_ across multiple targets
inside a single package or across multiple packages. When adopting the
`ExtensibleEnums` feature across multiple packages the new Swift setting can be
used to continue allowing exhaustive matching.

While this setting allows treating multiple targets as part of the same package.
This setting should only be used across packages when the packages are
both co-developed and co-released.

### Other build systems

Swift PM isn't the only system used to create and build Swift projects. Build
systems and IDEs such as Bazel or Xcode offer support for Swift projects as
well. When using such tools it is common to split a project into multiple
targets/modules. Since those targets/modules are by default not considered to be
part of the package, when adopting the `ExtensibleEnums` feature it would
require to either add an `@unknown default` when switching over enums defined in
other targets/modules or marking all public enums as `@frozen`. Similarly, to
the above to avoid this churn we recommend specifying the `-package-name` flag
to the compiler for all targets/modules that should be considered as part of the
same unit.

### Escape hatch

There might still be cases where developers need to consume a module that is
outside of their control which adopts the `ExtensibleEnums` feature. For such
cases we propose to introduce a flag `--assume-source-stable-package` that
allows assuming modules of a package as source stable. When checking if a switch
needs to be exhaustive we will check if the code is either in the same module,
the same package, or if the defining package is assumed to be source stable.
This flag can be passed multiple times to define a set of assumed-source-stable
packages. 

```swift
// a.swift inside Package A
public enum MyEnum {
    case foo
    case bar
}

// b.swift inside Package B compiled with `--assume-source-stable-package A`

switch myEnum { // No @unknown default case needed
case .foo:
    print("foo")
case .bar:
    print("bar")
}
```

In general, we recommend to avoid using this flag but it provides an important
escape hatch to the ecosystem.

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

### Using `--assume-source-stable-packages` for other diagnostics

During the pitch it was brought up that there are more potential future
use-cases for assuming modules of another package as source stable such as
borrowing from a declaration which distinguishes between a stored property and
one written with a `get`. Such features would also benefit from the
`--assume-source-stable-packages` flag.

## Alternatives considered

### Provide an `@extensible` annotation

We believe that the default behavior in both language dialects should be that
public enumerations are extensible. One of Swift's goals, is safe defaults and
the current non-extensible default in non-resilient modules doesn't achieve that
goal. That's why we propose a new language feature to change the default in a
future Swift language mode.

### Introducing a new annotation instead of using `@frozen`

An initial pitch proposed a new annotation instead of using `@frozen`. The
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
`@preconcurrency` works. Such an annotation seems to work initially when
existing public enumerations are marked as `@preEnumExtensibility` instead of
`@frozen`. It would result in the error about the missing `@unknown default`
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

// Package A adopts ExtensibleEnums feature and marks enum as @preEnumExtensibility
@preEnumExtensibility
public enum Foo {
  case foo
}

// Package B now emits a warning downgraded from an error
switch foo { // warning: Enum might be extended later. Add an @unknown default case.
case .foo: break
}

// Later Package A decides to extend the enum
@preEnumExtensibility
public enum Foo {
  case foo
  case bar
}

// Package B didn't add the @unknown default case yet. So now we we emit a warning and an error
switch foo { // error: Unhandled case bar & warning: Enum might be extended later. Add an @unknown default case.
case .foo: break
}

```