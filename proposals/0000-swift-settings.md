# #SwiftSettings: a macro for enabling compiler flags locally in a specific file

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Michael Gottesman](https://github.com/gottesmm)
* Review Manager: TBD
* Status: Implemented on main behind flag -enable-experimental-feature SwiftSettings
* Vision: [[Prospective Vision] Improving the approachability of data-race safety](https://forums.swift.org/t/prospective-vision-improving-the-approachability-of-data-race-safety/76183)
* Previous Revision: [1](https://github.com/swiftlang/swift-evolution/blob/dbab768bc058c23b7d5b99827680a19443519136/proposals/0000-compiler-settings.md) [2](https://github.com/swiftlang/swift-evolution/blob/3029caa010ee238d8396c1a5014a21b865c5ecb0/proposals/0000-swift-settings.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-compilersettings-a-top-level-statement-for-enabling-compiler-flags-locally-in-a-specific-file/))

## Introduction

We propose introducing a new macro called `#SwiftSettings` that allows for
compiler flags to be enabled on a single file. Initially this will only be used
to support controlling the default isolation. For example:

```swift
#SwiftSettings(
    .defaultIsolation(MainActor.self)
)
```

In the future, we wish to extend this to also include support for controlling
`warningsAsErrors`, `strictConcurrency`, and other flags. See future directions
for more details.

## Motivation

Today Swift contains multiple ways of changing compiler and language behavior
from the command line including specifying the default actor isolation via
[Controlling Default Actor Isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md). Since
these compiler and language behaviors can only be manipulated via the command
line and the compiler compiles one module at a time, users are forced to apply
these flags one module at a time instead of one file at a time. When confronted
with this, users are forced to split the subset of files into a separate module
creating an unnecessary module split. We foresee that this will occur more often
in the future if new features like [Controlling Default Actor Isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)
are accepted by Swift Evolution. Consider the following situations where
unnecessary module splitting would be forced:

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
    .defaultIsolation(MainActor.self)
)
```

By specifying compiler options in such a manner, we are able to avoid the need
for module splitting if a user wishes to change the default isolation only on a
specific file.

As an additional benefit since strongly typed methods are being used instead of
providing a single method that takes a string to specify the command line
parameter code completion can make the compiler options discoverable to the user
in the IDE.

NOTE: Initially we will only support default isolation. In the future, this can
be loosened as appropriate (see future directions).

## Detailed design

We will introduce into the standard library a new declaration macro called
`#SwiftSettings` and a new struct called `SwiftSetting` that `#SwiftSettings`
takes as a variadic parameter:

```swift
@freestanding(declaration)
public macro SwiftSettings(_ settings: SwiftSetting...) = Builtin.SwiftSettingsMacro

public struct SwiftSetting {
  public init() { fatalError("Cannot construct an instance of SwiftSetting") }
}
```

`#SwiftSettings` will expand to an empty string and is used only for its syntax
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

`#SwiftSetting` will only support an explicit opted-in group of command line
flags. This initially will only include default isolation. All such options must
possess the following characteristics to be compatible with `#SwiftSettings`:

* No impact on parsing

* Only modify the program in a manner that can be reflected in a textual interface
  without the need for `#SwiftSettings` to be serialized into a textual
  interface file.

* Does not cause module wide effects that cannot be constrained to a single
  file. An example of such a setting is `enable-library-evolution`.

In the future, more options can be added as appropriate (see future
directions). In order to ensure that any such options also obey the above
restrictions, we expect that any feature that wants to be supported by
`#SwiftSettings` must as part of their swift-evolution process consider the ABI
and source stability impacts of adding support to `#SwiftSettings`. At minimum,
the feature must obey the above requirements.

Each argument can be passed to `#SwiftSettings` exactly once. Otherwise, an
error will be emitted:

```swift
#SwiftSetting(
  .defaultIsolation(MainActor.self),
  .defaultIsolation(nil) // Error!
)

#SwiftSetting(
  .defaultIsolation(MainActor.self) // Error!
)
```

If a command line option is set to different values at the module and file
level, the setting at the file level will take precedence.

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

### Adding support for warningsAsErrors and strictConcurrency to allow for per-file warningsAsErrors based migration of large modules to strict concurrency

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

#### `strictConcurrency`

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

#### `warningsAsErrors`

Support for warningsAsErrors will be added by defining an extension of
`SwiftSetting` in stdlibCore that defines a struct called DiagnosticGroup and a
static function called `warningsAsErrors` that takes a variadic list of
DiagnosticGroup that should be applied:

```swift
extension SwiftSetting {
  public struct DiagnosticGroup {
    public init() { fatalError("Cannot construct a DiagnosticGroup") }
  }

  public static func warningsAsErrors(_ diagnosticGroup: DiagnosticGroup...) -> SwiftSetting { SwiftSetting() }
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

### Adding support for Strict Memory Safety

We could also in the future add support to `#SwiftSettings` for Strict Memory
Safety.

### Adding the ability to opt out of module-level flags like warningsAsErrors

We could add support for turning off features like warningsAsErrors at the file
level. This would involve adding a new `disableWarningsAsErrors` method onto
`SwiftSetting`. This would be useful when only a few files fail warningsAsErrors
and the user wishes to only suppress warningsAsErrors in those specific files in
order to avoid needing to unnnecessarily split a module.

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
would necessarily need to be greater. As an example, we could never allow for 

### Extending SwiftSetting to include parsing options

We could make it so that parsing `#SwiftSetting` is done directly in the parser
when we parse part of the macro grammar. This would work by evaluating the
`#SwiftSetting` from its syntax and performing our pattern matching at parse
time instead of at type checker time. We would then not create an AST for
`#SwiftSetting`. This current proposal is compatible with the parsing approach
since in such a case, `#SwiftSetting` would never show up at AST time.

### Allowing for Experimental Features to opt into `#SwiftSettings`

We could allow for experimental features to opt into `#SwiftSettings` just like
upcoming features can. We think at this point that there are dangers to exposing
support in this manner for experimental features since experimental features
have not gone through the evolution process and through that process proven that
they obey the relevant characteristics required of options for `#SwiftSettings`
support. That being said, it may be reasonable to allow for this when the
compiler is compiled with asserts so that features can test this behavior during
development.

## Acknowledgments

I would like to thank Holly Borla, Doug Gregor, Konrad Malawski and the rest of
Swift Evolution for feedback on this proposal.
