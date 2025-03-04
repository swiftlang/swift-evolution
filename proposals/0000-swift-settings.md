# #SwiftSettings: a macro for enabling compiler flags locally in a specific file

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Michael Gottesman](https://github.com/gottesmm)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Vision: [[Prospective Vision] Improving the approachability of data-race safety](https://forums.swift.org/t/prospective-vision-improving-the-approachability-of-data-race-safety/76183)
* Previous Revision: [1](https://github.com/swiftlang/swift-evolution/blob/dbab768bc058c23b7d5b99827680a19443519136/proposals/0000-compiler-settings.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-compilersettings-a-top-level-statement-for-enabling-compiler-flags-locally-in-a-specific-file/))

## Introduction

We propose introducing a new macro called `#SwiftSettings` that allows for
compiler flags to be enabled on a single file. This can be used to enable
warningsAsError, strict concurrency, and default isolation. For example:

```swift
#SwiftSettings(
    .warningsAsErrors(.concurrency),
    .strictConcurrency(.complete),
    .defaultIsolation(MainActor.self)
)
```

## Motivation

Today Swift contains multiple ways of changing compiler and language behavior
from the command line including:

* Enabling warnings as errors for diagnostic groups.
* Enabling strict concurrency when compiling pre-Swift 6 code.
* Specifying the default actor isolation via [Controlling Default Actor Isolation]().

Since these compiler and language behaviors can only be manipulated via the
command line and the compiler compiles one module at a time, users are forced to
apply these flags one module at a time instead of one file at a time. This
results in several forms of developer friction that we outline below.

### Unnecessary Module Splitting

Since compiler flags can only be applied to entire modules, one cannot apply a
compiler flag to a subset of files of a module. When confronted with this, users
are forced to split the subset of files into a separate module creating an
unnecessary module split. We foresee that this will occur more often in the
future if new features like [Controlling Default Actor Isolation]() are accepted
by Swift Evolution. Consider the following situations where unnecessary module
splitting would be forced:

* Consider a framework that by default uses `nonisolated` isolation, but wants
  to expose a set of UI elements for users of the framework. In such a case, it
  is reasonable to expect the author to want to make those specific files
  containing UI elements to have a default isolation of `@MainActor` instead of
  nonisolated. Without this feature one must introduce an additional module to
  contain the UI elements for the framework when semantically there is really
  only one framework.

* Imagine an app that has enabled `@MainActor` isolation by default since it
  contains mostly UI elements but that wishes to implement helper abstractions
  that interact with a database on a background task. This helper code is
  naturally expressed as having a default isolation of nonisolated implying that
  one must either split the database helpers into a separate module or must mark
  most declarations in the database code with nonisolated by hand.

### Preventing per-file based warningsAsErrors migration of large modules to strict concurrency

Swift has taken the position that updating modules for strict concurrency should
be accomplished by:

1. Enabling strict concurrency on the entire module causing the compiler to emit
   warnings.

2. Updating the module incrementally until all of the warnings have been
   eliminated from the module.

3. Updating the language version of the module to swift 6 so from that point on
   warnings will become errors to prevent backsliding.

This creates developer friction when applied to large modules, since the size of
the module makes it difficult to eliminate all of the warnings at once. This
results in either the module being updated over time on main during which main
is left in an intermediate, partially updated state or the module being updated
on a branch that is merged once all updates have been completed. In the former
case, it is easy to introduce new warnings as new code is added to the codebase
since only warnings are being used. In the later case, the branch must be kept
up to date in the face of changes being made to the codebase on main, forcing
one to continually need to update the branch to resolve merge conflicts against
main.

In contrast by allowing for strict concurrency to be applied one file at a time,
users can update code using a warningsAsErrors based migration path. This
involves instead:

1. Enabling strict concurrency and warningsAsErrors for strict concurrency on
   the specific file.

2. Fixing all of the errors in the file.

3. Commiting the updated file into main.

Since one is only updating one file at a time and using warningsAsErrors, the
updates can be done incrementally on a per file basis, backsliding cannot occur
in the file, and most importantly main is never in an intermediate, partially
updated state. We think that this approach will make it significantly easier for
larger modules to be migrated to strict concurrency.

## Proposed solution

We propose introducing a new macro called `#SwiftSettings` that takes a list of
structs of type `SwiftSetting`. `SwiftSetting` will possess a static method for
each command line argument that it supports. Any parameters that would be passed
on the command line are passed as parameters to the static method. The compiler
upon parsing a `#SwiftSettings` macro updates its internal state to set the
appropriate settings before compiling the rest of the file. An example of such a
`#SwiftSettings` invocation is the following:

```swift
#SwiftSettings(
    .warningsAsErrors(.concurrency),
    .strictConcurrency(.complete),
    .defaultIsolation(MainActor.self)
)
```

By specifying compiler options in such a manner, we are able to solve all of the
problems above:

1. The programmer can avoid module splitting when they wish to use compiler
   flags only on a specific file.

2. The programmer can specify strict concurrency on a per file basis instead of
   only on a per module basis allowing for warningsAsError to be used per file
   instead of per module migration to use new features.

As an additional benefit since strongly typed methods are being used instead of
providing a single method that takes a string to specify the command line
parameter code completion can make the compiler options discoverable to the user
in the IDE.

NOTE: By default, only a few specified command line options will be
supported. In the future, this can be loosened as appropriate (see future
directions).

## Detailed design

We will introduce into the standard library a new declaration macro called
`#SwiftSettings` and a new struct called `SwiftSetting` that `#SwiftSettings`
takes as a parameter:

```swift
@freestanding(declaration)
public macro SwiftSettings(_ settings: SwiftSetting...) = Builtin.SwiftSettingsMacro

public struct SwiftSetting {
  public init() { fatalError("Cannot construct an instance of SwiftSetting") }
}
```

`#SwiftSettings` will expand to an empty string and is used only for syntactic
and documentation in the IDE.

`SwiftSetting` is a resilient struct that cannot be constructed without a
runtime error and is only used for the purposes of specifying command line
arguments to a `#SwiftSettings` macro. Support for individual command line
options is added to `SwiftSetting` by defining a static method on `SwiftSetting`
in an extension. By using static methods and extensions in this manner, we are
able to make `SwiftSetting` extensible without requiring the standard library to
be updated whenever a new options is added since the extension can be defined in
other modules. As an example, we add support for `defaultIsolation` via an
extension in the Concurrency module as follows:

```swift
extension SwiftSetting {
  public static func defaultIsolation(_ isolation: Actor.Type?) -> SwiftSetting { SwiftSetting() }
}
```

Since this extension is in the `Concurrency` module, we are able to use
`Actor.Type?` to specify the default isolation to be used which would not be
possible if defaultIsolation was defined in the standard library since `Actor`
is defined in Concurrency,

Each static method on `SwiftSetting` is expecting to return a `SwiftSetting`
struct. The actual value returned is not important since this code will not be
executed.

By default, `#SwiftSetting` will only support an explicit group of command line
flags. These are:

* strict-concurrency
* warnings-as-errors
* default isolation.

These options are compatible with `#SwiftSettings` since they possess the
following three characteristics:

* Impact parsing

* Emit additional warnings and errors

* Modify the program in a manner that can be reflected in a textual interface
  without the need for `#SwiftSettings` to be serialized into a textual
  interface file.

* Are not options that cause module wide effects that cannot be constrained to a
  single file. An example of such a setting is `enable-library-evolution`.

In the future, more options can be added as appropriate (see future
directions). In order to ensure that any such options also obey the above
restrictions, we expect that any feature that wants to be supported by
`#SwiftSettings` must as part of their swift-evolution process consider the ABI
and source stability impacts of adding support to `#SwiftSettings`. At minimum,
the feature must obey the above requirements.

If a command line option is set to different values at the module and file
level, the setting at the file level will take precedence.

Beyond adding support for `defaultIsolation` in Concurrency, we will also add
support for strict concurrency and warningsAsErrors.

Support for strict concurrency will be added by defining an extension of
`SwiftSetting` in `Concurrency` that contains an enum that specifies the cases
that strict concurrency can take and a static method called `strictConcurrency`
that takes that enum:

```swift
extension SwiftSetting {
  public enum StrictConcurrencySetting {
    case Minimal
    case Targeted
    case Complete
  }

  public static func strictConcurrency(_ setting: StrictConcurrencySetting) -> SwiftSetting { ... }
}
```

Support for warningsAsErrors will be added by defining an extension of
`SwiftSetting` in stdlibCore that defines a struct called DiagnosticGroup and a
static function called `warningsAsErrors`:

```swift
extension SwiftSetting {
  public struct DiagnosticGroup {
    public init() { fatalError("Cannot construct a DiagnosticGroup") }
  }

  public static func warningsAsErrors(_ diagnosticGroup: DiagnosticGroup) -> SwiftSetting { ... }
}
```

`DiagnosticGroup` is similar to `SwiftSetting` in that it is a resilient struct
that cannot be constructed without a runtime error and provides static
properties for each of the DiagnosticGroup cases that are supported by it:

```swift
// In StdlibCore
extension SwiftSetting.DiagnosticGroup {
  static var deprecatedDeclarations: SwiftSetting.DiagnosticGroup { ... }
}

// In Concurrency
extension SwiftSetting.DiagnosticGroup {
  static var concurrency: SwiftSetting.DiagnosticGroup { ... }
  static var preconcurrencyImport: SwiftSetting.DiagnosticGroup { ... }
}
```

Thus one can specify that concurrency warnings should be errors by writing:

```swift
#SwiftSettings(
  .warningsAsErrors(.concurrency)
)
```

## Source compatibility

The addition of the `#SwiftSettings` and `SwiftSetting` cannot impact the
parsing of other constructs since the name shadowing rules in the compiler will
ensure that any local macros or types that shadow those names will take
precedence. If the user wishes to still use `#SwiftSettings`, the user can spell
the macro as `#Swift.SwiftSettings` as needed.

Importantly this means that `#SwiftSettings` if used in the swiftpm code base or
in `Package.swift` files would always need to be namespaced. The authors think
that this is an acceptable trade-off since:

* The `swiftpm` codebase is one project out of many and can just namespace as
  appropriate.
* `Package.swift` files really shouldn't need `#SwiftSettings` since they are
  very self contained APIs.

## ABI compatibility

This proposal does not inherently break ABI. But it can break ABI if a command
line option is enabled that causes the generated code's ABI to change. As part
of enabling an option, one must consider such implications.

## Implications on adoption

Adopters of this proposal should be aware that while this feature does not
inherently break ABI, enabling options using `#SwiftSettings` that break ABI can
result in ABI breakage.

## Future directions

### Adding support for Upcoming Features

We could add support for Upcoming Features to `#SwiftSettings`. By default all
upcoming features would _NOT_ be supported by `#SwiftSettings`. Instead,
Upcoming Features would need to opt-in specifically to `#SwiftSettings`
support. In order to opt-in, the upcoming feature would need to specify in its
swift-evolution proposal any ABI, API, or source stability issues arising from
having `#SwiftSettings` support. The authors expect that if we were to support
this, we would introduce a enum based API:

```swift
extension SwiftSetting {
  public enum UpcomingFeature { ... }

  public static func enableUpcomingFeature(_ feature: UpcomingFeature) -> SwiftSetting { ... }
}
```

and would either require supported upcoming features to be explicitly written
into the `UpcomingFeature` enum or use a compiler code generation approach. If
the compiler code generation approach was used, we would populate
`UpcomingFeature` with all known cases from the compiler dynamically at compile
time and use availability to disable the cases associated with features that do
not support `SwiftSettings`. The nice thing about the latter approach is that
all features can be found in the IDE.

### Adding new APIs to SwiftPM that take SwiftSetting

Even though we purposely chose not to reuse `SwiftSetting` from `SwiftPM` (see
Alternatives Considered), we could add a new overload to `SwiftSetting.define`
that takes a `Swift.SwiftSetting` struct and uses it to pass flags onto a
specific target. This would allow for SwiftPM users to take advantage of the
discoverability provided by specifying compiler flags using strongly typed APIs
instead of the stringly typed APIs that `SwiftSetting` uses today. This
generalized API also would ensure that `SwiftSetting` does not need to be
updated to support more kinds of command line options since the compiler would
be able to "inject" support for such options into `SwiftPM`. This would require
us to allow for `SwiftSettings` structs to be constructed and provide state
within them that `SwiftPM` can process to determine the relevant behavior. Since
`SwiftSetting` is a resilient struct, we can in the future add this support
without breaking ABI or API.

NOTE: Since the `SwiftPM` API would specify in its signature that it takes a
`Swift.SwiftSetting`, the user will still be able to take advantage of the type
checker to avoid needing to prefix any calls to static methods on
`Swift.SwiftSetting`.

## Alternatives considered

### Using a bespoke syntax instead of a macro

Instead of using a macro, we considered using a bespoke syntax called
`compilerSettings` that looked as follows:

```swift
compilerSettings [
  .warningsAsErrors(.concurrency),
  .strictConcurrency(.complete),
  .defaultIsolation(MainActor.self)
]
```

We decided not to go with this approach since:

* We would be introducing an additional unneeded bespoke syntax to the language.
* Macros are already recognized by users as a manner to change compiler behavior
  at compile time.

### Reusing `SwiftSetting` from SwiftPM

Instead of using our own `SwiftSetting` struct, we could reuse parts of
`SwiftPM`. The authors upon investigating this approach noticed that If one
attempted to move SwiftPM's `SwiftSetting` into the standard library, one would
have to expose many parts of SwiftPM's internal types into the standard library
such as `BuildSettingData`, `BuildSettingCondition`, `Platform`,
`BuildConfiguration`, and more.

### Using a "fake" syntatic macro instead of a real macro

Instead of using a real macro, we could use a bespoke "fake" macro. This would
involve the compiler providing custom parsing for `#SwiftSettings`. The compiler
would then explicitly pattern match against the syntax for the various command
line options so the struct `SwiftSetting` would not be required.

The reason why we decided not to go with this approach is that:

1. It prevents the ability to perform lookup at point in the IDE and introduces
   more bespoke code into the compiler to support this feature.
2. It would prevent the introduction of new SwiftPM APIs in the future that take
   a `Swift.SwiftSetting`.

### "import feature" syntax

We could also use an "import" syntax to enable features like Python and
Scala. We decided to not follow this approach since `#` is a manner in swift of
saying "compile time".

### Typealias syntax

We could also use a typealiased based syntax. But this would only be able to be
used to specify the current global actor and would not let us add additional
features such as controlling strict concurrency or warnings as errors.

### Adding the ability to push/pop compiler settings

We do not think that it makes sense to implement the ability to push/pop
compiler settings since we are attempting to specifically support compiler
settings that semantically can have file wide implications. If we wanted to
support push/pop of compiler settings it would involve different trade-offs and
restrictions on what settings would be able to be used since the restrictions
would necessarily need to be greater.

## Acknowledgments

TODO
