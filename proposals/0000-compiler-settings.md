# compilerSettings: a top level statement for enabling compiler flags locally in a specific file

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Michael Gottesman](https://github.com/gottesmm)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Vision: [[Prospective Vision] Improving the approachability of data-race safety](https://forums.swift.org/t/prospective-vision-improving-the-approachability-of-data-race-safety/76183)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

We propose introducing a new top level statement called `compilerSettings` that
allows for compiler flags to be enabled on a single file. This can be used to
enable warningsAsError, upcoming features, and default isolation among other
flags. For example:

```swift
compilerSettings [
    .warningAsError(.concurrency),
    .strictConcurrency(.complete),
    .enableUpcomingFeature(.existentialAny),
    .defaultIsolation(MainActor.self),
]
```

## Motivation

Today Swift contains multiple ways of changing compiler and language behavior
from the command line including:

* Enabling experimental and upcoming features.
* Enabling warnings as errors for diagnostic groups.
* Enabling strict concurrency when compiling pre-Swift 6 code.
* Specifying the default actor isolation via [Controlling Default Actor Isolation]().
* Requiring code to use [Strict Memory Safety]().

Since these compiler and language behaviors can only be manipulated via the
command line and the compiler compiles one module at a time, users are forced to
apply these flags one module at a time instead of one file at a time. This
results in several forms of developer friction that we outline below.

### Unnecessary Module Splitting

Since compiler flags can only be applied to entire modules, one cannot apply a
compiler flag to a subset of files of a module. When confronted with this, users
are forced to split the subset of files into a separate module creating an
unnecessary module split. We foresee that this will occur more often in the
future if new features like [Controlling Default Actor Isolation]() and [Strict
MemorySafety]() are accepted by Swift Evolution. Consider the following
situations where unnecessary module splitting would be forced:

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

* Visualize a banking framework that contains both UI elements and functionality
  for directly manipulating the account data of a customer. In such a case the
  code that actually modifies customer data may want to enable strict memory
  safety to increase security. In contrast, strict memory safety is not
  necessary for the UI elements that the framework defines. To support both uses
  cases, a module split must be introduced.

### Preventing per-file based migration of large modules using warningsAsErrors

Swift has taken the position that updating modules for a new language mode or
feature should be accomplished by:

1. Enabling warnings on the entire module by enabling upcoming features from the
   command line.

2. Updating the module incrementally until all of the warnings have been
   eliminated from the module.

3. Updating the language version of the module so from that point on warnings
   will become errors to prevent backsliding.

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

In contrast by allowing for command line flags to be applied one file at a time,
users can update code using a warningsAsErrors based migration path. This
involves instead:

1. Enabling warningsAsErrors for the new feature on the specific file.

2. Fixing all of the errors in the file.

3. Commiting the updated file into main.

Since one is only updating one file at a time and using warningsAsErrors, the
updates can be done incrementally on a per file basis, backsliding cannot occur
in the file, and most importantly main is never in an intermediate, partially
updated state.

## Proposed solution

We propose introducing a new top level statement called `compilerSettings` that
takes a list of enums of type `CompilerSetting`. Each enum case's associated
values represent arguments that would be passed as an argument to the compiler
flag on the command line. The compiler upon parsing a `compilerSettings`
statement updates its internal state to set the appropriate settings before
compiling the rest of the file. An example of such a `compilerSettings`
statement is the following:

```swift
compilerSettings [
    .warningAsError(.concurrency),
    .strictConcurrency(.complete),
    .enableUpcomingFeature(.existentialAny),
    .defaultIsolation(MainActor.self),
]
```

By specifying compiler options in such a manner, we are able to solve all of the
problems above:

1. The programmer can avoid module splitting when they wish to use compiler
   flags only on a specific file.

2. The programmer can specify options on a per file basis instead of only on a
   per module basis allowing for warningsAsError to be used per file instead of
   per module migration to use new features.

As an additional benefit since enums are being used, code completion can make
the compiler options discoverable to the user in the IDE.

## Detailed design

We will update the swift grammar to allow for a new top level statement called
`compilerSettings` that takes a list of expressions:

```text
top-level-statement ::= 'compilerSettings' '[' (expr ',')* expr ','? ']'
```

Each expression passed to `compilerSettings` is an instance of the enum
`CompilerSetting` that specifies a command line option that is to be applied to
the file. `CompilerSetting` will be a resilient enum defined in the standard
library that provides the following API:

```
public enum CompilerSetting {
  case enableUpcomingFeature(UpcomingFeatureCompilerSetting)
  case enableExperimentalFeature(ExperimentalFeatureCompilerSetting)
  case warningAsError(WarningAsErrorCompilerSetting)
  case defaultIsolation(Actor.Type)
  case strictConcurrency(StrictConcurrencyCompilerSetting)
}
```

We purposely make `CompilerSetting` resilient so additional kinds of compiler
settings can be added over time without breaking ABI.

`CompilerSetting` provides an enum case for each command line option and each
case is able to provide associated values to specify arguments that would
normally be passed on the command line to the option. These associated values
can be one of:

* an already existing type (for example `Actor.Type`).

* a custom fixed enum defined as a subtype of `CompilerSetting` (for example
  `StrictConcurrencyCompilerSetting`).

* a custom enum defined as a subtype of `CompilerSetting` that the compiler
  synthesizes cases for depending on internal compiler data (for example
  features for `UpcomingFeatureCompilerSetting`).

We purposely keep all custom types defined for `CompilerSetting` as nested types
within `CompilerSetting` in order to avoid polluting the global namespace. Thus
we would necessarily define in the stdlib all of the custom types as:

```swift
extension CompilerSetting {
  // Cases synthesized by the compiler.
  public enum UpcomingFeatureCompilerSetting { }

  // Cases synthesized by the compiler.
  public enum ExperimentalFeatureCompilerSetting { }

  // Cases synthesized by the compiler.
  public enum WarningsAsErrorsCompilerSetting { }

  // We know ahead of time all of the cases, so this is specified explicitly.
  public enum StrictConcurrency {
    case minimal
    case targeted
    case complete
  }
}
```

In order to ensure that compiler settings are easy to find in the file, we
require that `compilerSettings` be the first statement in the file.

By default command line flags will not be allowed to be passed to
`compilerSettings`. Instead, we will require a compiler flag to explicitly opt
in to being supported by `compilerSettings`. We require that since:

1. Certain compiler flags like `-enable-library-evolution` have effects that can
   not be constrained to a single file since they are inherently module wide
   flags.

2. Other compiler flags whose impacts would necessitate exposing
   `compilerSettings` in textual modules. We view supported `compilerSettings`
   as an anti-goal since appearing in the module header makes enabling
   `compilerSettings` affect the way the module is interpreted by users, while
   we are designing `compilerSettings` to have an impact strictly local to the
   file. NOTE: This does not preclude compiler options that modify the way the
   code in the file is exposed in textual modules by modifying the code's
   representation in the textual module directly.

## Source compatibility

The addition of the `compilerSetting` keyword does not impact parsing of other
constructs since it can only be parsed as part of top level code in a position
where one must have a keyword preventing any ambiguity. Adding the enum
`CompilerSetting` cannot cause a name conflict since the name shadowing rules
added to the compiler for `Result` will also guarantee that any user defined
`CompilerSetting` will take precedence over the `CompilerSetting` type. In such
a situation, the user can spell `CompilerSetting` as `Swift.CompilerSetting` as
needed. All of the nested types within `CompilerSetting` cannot cause any source
compatibility issues since they are namespaced within `CompilerSetting`.

## ABI compatibility

This proposal does not inherently break ABI. But it can break ABI if a command
line option is enabled that causes the generated code's ABI to change.

## Implications on adoption

Adopters of this proposal should be aware that while this feature does not
inherently break ABI, enabling options using `compilerSettings` that break ABI
can result in ABI breakage.

## Future directions

Even though we purposely chose not to reuse `SwiftSetting` from `SwiftPM` (see
Alternatives Considered), we could add a new static method onto `SwiftSetting`
called `SwiftSetting.defineCompilerSetting` or provide an overload for
`SwiftSetting.define` that takes a `CompilerSetting` enum and uses it to pass
flags onto a specific target. This would allow for SwiftPM users to take
advantage of the discoverability provided by using enums in comparison with the
stringly typed APIs that `SwiftSetting` uses today to enable experimental and
upcoming features. This generalized API also would ensure that `SwiftSetting`
does not need to be updated to support more kinds of command line options since
the compiler would be able to "inject" support for such options into
`SwiftPM`. This would most likely require out sub-enum cases to be String enums
so that SwiftPM can just use their string representation.

## Alternatives considered

Instead of using `compilerSettings` and `CompilerSetting`, we could instead use
`swiftSettings` and `SwiftSetting` respectively. The reason why the authors
avoided this is that `swiftSetting` and `SwiftSetting` are currently used by
swiftpm to specify build settings resulting in potential user confusion since
`SwiftSetting` uses stringly typed APIs instead of the more discoverable enum
based APIs above. If instead one attempted to move `SwiftSetting` into the
standard library, one would have to expose many parts of SwiftPM's internal
types into the standard library such as `BuildSettingData`,
`BuildSettingCondition`, `Platform`, `BuildConfiguration`, and more.

## Acknowledgments

TODO
