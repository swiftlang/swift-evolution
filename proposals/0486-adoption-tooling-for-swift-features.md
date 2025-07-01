# Migration tooling for Swift features

* Proposal: [SE-0486](0486-adoption-tooling-for-swift-features.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis), [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: [Franz Busch](https://github.com/FranzBusch)
* Status: **Implemented (Swift 6.2)**
* Implementation: https://github.com/swiftlang/swift-package-manager/pull/8613
* Review: [Pitch](https://forums.swift.org/t/pitch-adoption-tooling-for-upcoming-features/77936), [Review](https://forums.swift.org/t/se-0486-migration-tooling-for-swift-features/80121)

## Introduction

Swift 5.8 introduced [upcoming features][SE-0362], which enabled piecemeal
adoption of individual source-incompatible changes that are included in a
language mode.
Many upcoming features have a mechanical migration, meaning the compiler can
determine the exact source changes necessary to allow the code to compile under
the upcoming feature while preserving the behavior of the code.
This proposal seeks to improve the experience of enabling individual Swift
features by providing an integrated mechanism for producing these source code
modifications automatically.

## Motivation

It is the responsibility of project maintainers to preserve source (and binary)
compatibility both internally and for library clients when enabling an upcoming
feature, which can be difficult or tedious without having tools to help detect
possibly inadvertent changes or perform monotonous migration shenanigans for
you.
*Our* responsibility is to make that an easier task for everybody.

### User intent

A primary limiting factor in how proactively and accurately the compiler can
assist developers with adopting a feature is a lack of comprehension of user
intent.
Is the developer expecting guidance on adopting an improvement?
All the compiler knows to do when a feature is enabled is to compile code
accordingly.
If an upcoming feature supplants an existing grammatical construct or
invalidates an existing behavior, the language rules alone suffice because
Swift can consistently infer the irrefutable need to diagnose certain code
patterns just by spotting them.

Needless to say, not all upcoming features fall under these criteria (and not
all features are source-breaking in the first place).
Consider [`DisableOutwardActorInference`][SE-0401], which changes actor
isolation inference rules with respect to wrapped properties.
There is no way for the programmer to specify that they'd like compiler fix-its
to make the existing actor isolation inference explicit.
If they enable the upcoming feature, their code will simply behave differently.
This was a point of debate in the review of [SE-0401], and the Language
Steering Group concluded that automatic migration tooling is the right way to
address this particular workflow, as
[noted in the acceptance notes][SE-0401-acceptance]:

> the Language Steering Group believes that separate migration tooling to
> help programmers audit code whose behavior will change under Swift 6 mode
> would be beneficial for all upcoming features that can change behavior
> without necessarily emitting errors.

### Automation

Many existing and prospective upcoming features account for simple and reliable
migration paths to facilitate adoption:

* [`NonfrozenEnumExhaustivity`][SE-0192]: Restore exhaustivity with
  `@unknown default:`.
* [`ConciseMagicFile`][SE-0274]: `#file` → `#filePath`.
* [`ForwardTrailingClosures`][SE-0286]: Disambiguate argument matching by
  de-trailing closures and/or inlining default arguments.
* [`ExistentialAny`][SE-0335]: `P` → `any P`.
* [`ImplicitOpenExistentials`][SE-0352]: Suppress opening with `as any P`
  coercions.
* [`BareSlashRegexLiterals`][SE-0354]: Disambiguate using parentheses,
  e.g. `foo(/a, b/)` → `foo((/a), b/)`.
* [`DeprecateApplicationMain`][SE-0383]: `@UIApplicationMain` → `@main`,
  `@NSApplicationMain` → `@main`.
* [`DisableOutwardActorInference`][SE-0401]: Specify global actor isolation
  explicitly.
* [`InternalImportsByDefault`][SE-0409]: `import X` → `public import X`.
* [`GlobalConcurrency`][SE-0412]: Convert the global variable to a `let`, or
  `@MainActor`-isolate it, or mark it with `nonisolated(unsafe)`.
* [`MemberImportVisibility`][SE-0444]: Add explicit imports appropriately.
* [`InferSendableFromCaptures`][SE-0418]: Suppress inference with coercions
  and type annotations.
* [Inherit isolation by default for async functions][async-inherit-isolation-pitch]:
  Mark nonisolated functions with the proposed attribute.

Application of these adjustments can be fully automated in favor of preserving
behavior, saving time for more important tasks, such as identifying, auditing,
and testing code where a change in behavior is preferable.

## Proposed solution

Introduce the notion of a migration mode for individual experimental and
upcoming features.
The core idea behind migration mode is a declaration of intent that can be
leveraged to build better supportive adoption experiences for developers.
If enabling a feature communicates an intent to *enact* rules, migration mode
communicates an intent to migrate code so as to preserve compatibility once the
feature is enabled.

This proposal will support the set of existing upcoming features that
have mechanical migrations, as described in the [Automation](#automation)
section.
All future proposals that intend to introduce an upcoming feature and
provide for a mechanical migration should include a migration mode and detail
its behavior alongside the migration paths in the *Source compatibility*
section.

## Detailed design

Upcoming features that have mechanical migrations will support a migration
mode, which is a new mode of building a project that will produce compiler
warnings with attached fix-its that can be applied to preserve the behavior
of the code under the feature.

The action of enabling a previously disabled upcoming feature in migration
mode must not cause any new compiler errors or behavioral changes, and the
fix-its produced must preserve compatibility.
Compatibility here refers to both source and binary compatibility, as well as
to behavior.
Additionally, this action will have no effect if the mode is not supported
for a given upcoming feature, i.e., because the upcoming feature does not
have a mechanical migration.
A corresponding warning will be emitted in this case to avoid the false
impression that the impacted source code is compatible with the feature.
This warning will belong to the diagnostic group `StrictLanguageFeatures`.

### Interface

The `-enable-*-feature` frontend and driver command line options will start
supporting an optional mode specifier with `migrate` as the only valid mode:

```
-enable-upcoming-feature <feature>[:<mode>]
-enable-experimental-feature <feature>[:<mode>]

<mode> := migrate
```

For example:

```
-enable-upcoming-feature InternalImportsByDefault:migrate
```

If the specified mode is invalid, the option will be ignored, and a warning will
be emitted.
This warning will belong to the diagnostic group `StrictLanguageFeatures`.
In a series of either of these options applied to a given feature, only the
last option will be honored.
If a feature is both implied by the effective language mode and enabled in
migration mode, the latter option will be disregarded.

### Diagnostics

Diagnostics emitted in relation to a specific feature in migration mode must
belong to a diagnostic group named after the feature.
The names of diagnostic groups can be displayed alongside diagnostic messages
using `-print-diagnostic-groups` and used to associate messages with features.

### `swift package migrate` command

To enable seamless migration experience for Swift packages, I'd like to propose a new Swift Package Manager command - `swift package migrate` to complement the Swift compiler-side changes.

The command would accept one or more features that have migration mode enabled and optionally a set of targets to migrate, if no targets are specified the whole package is going to be migrated to use new features.

#### Interface

```
USAGE: swift package migrate [<options>] --to-feature <to-feature> ...

OPTIONS:
  --target <targets>     The targets to migrate to specified set of features or a new language mode.
  --to-feature <to-feature>
                          The Swift language upcoming/experimental feature to migrate to.
  -h, --help              Show help information.
```

#### Use case

```
swift package migrate --target MyTarget,MyTest --to-feature ExistentialAny
```

This command would attempt to build `MyTarget` and `MyTest` targets with `ExistentialAny:migrate` feature flag, apply any fix-its associated with
the feature produced by the compiler, and update the `Package.swift` to
enable the feature(s) if both of the previous actions are successful:

```
.target(
  name: "MyTarget",
  ...
  swiftSettings: [
    // ... existing settings,
    .enableUpcomingFeature("ExistentialAny")
  ]
)
...
.testTarget(
  name: "MyTest",
  ...
  swiftSettings: [
    // ... existing settings,
    .enableUpcomingFeature("ExistentialAny")
  ]
)
```

In the "whole package" mode, every target is going to be updated to include
new feature flag(s). This is supported by the same functionality as `swift package add-setting` command.

If it's, for some reason, impossible to add the setting the diagnostic message would suggest what to add and where i.e. `...; please add 'ExistentialAny' feature to 'MyTarget' target manually`.

#### Impact on Interface

This proposal introduces a new command but does not interfere with existing commands. It follows the same pattern as `swift build` and `swift test` in a consistent manner.

## Source compatibility

This proposal does not affect language rules.
The described changes to the API surface are source-compatible.

## ABI compatibility

This proposal does not affect binary compatibility or binary interfaces.

## Implications on adoption

Entering or exiting migration mode can affect behavior and is therefore a
potentially source-breaking action.

## Future directions

### Producing source incompatible fix-its

For some features, a source change that alters the semantics of
the program is a more desirable approach to addressing an error that comes
from enabling the feature.
For example, programmers might want to replace cases of `any P` with `some P`.
Migration tooling could support the option to produce source incompatible
fix-its in cases where the compiler can detect that a different behavior might
be more beneficial.

### Applications beyond mechanical migration

The concept of migration mode could be extrapolated to additive features, such
as [typed `throws`][SE-0413] or [opaque parameter types][SE-0341], by providing
actionable adoption tips.
Additive features are hard-enabled and become an integral part of the language
as soon as they ship.
Many recent additive features are already integrated into the Swift feature
model, and their metadata is kept around either to support
[feature availability checks][SE-0362-feature-detection] in conditional
compilation blocks or because they started off as experimental features.

Another feasible extension of migration mode is promotion of best practices.

### Augmented diagnostic metadata

The current serialization format for diagnostics does not include information
about diagnostic groups or whether a particular fix-it preserves semantics.
There are several reasons why this data can be valuable for users, and why it
is essential for future tools built around migration mode:
* The diagnostic group name can be used to, well, group diagnostics, as well as
  to communicate relationships between diagnostics and features and filter out
  relevant diagnostics.
  This can prove especially handy when multiple features are simultaneously
  enabled in migration mode, or when similar diagnostic messages are caused by
  distinct features.
* Exposing the purpose of a fix-it can help developers make quicker decisions
  when offered multiple fix-its.
  Furthermore, tools can take advantage of this information by favoring and
  auto-applying source-compatible fix-its.

## Alternatives considered

### A distinct `-migrate` option

This direction has a questionably balanced set of advantages and downsides.
On one hand, it would provide an adequate foundation for invoking migration
for a language mode in addition to individual features.
On the other hand, an independent option is less discoverable, has a steeper
learning curve, and makes the necessary relationships between it and the
existing `-enable-*-feature` options harder to infer.
Perhaps more notably, a bespoke option by itself would not scale to any future
modes, setting what might be an unfortunate example for further decentralization
of language feature control.

### API for package manifests

The decision around surfacing migration mode in the `PackageDescription`
library depends on whether there is a consensus on the value of enabling it as
a persistent setting as opposed to an automated procedure in the long run.

Here is how an API change could look like for the proposed solution:

```swift
+extension SwiftSetting {
+  @available(_PackageDescription, introduced: 6.2)
+  public enum SwiftFeatureMode {
+    case migrate
+    case on
+  }
+}
```
```diff
    public static func enableUpcomingFeature(
        _ name: String,
+       mode: SwiftFeatureMode = .on,
        _ condition: BuildSettingCondition? = nil
    ) -> SwiftSetting

    public static func enableExperimentalFeature(
        _ name: String,
+       mode: SwiftFeatureMode = .on,
        _ condition: BuildSettingCondition? = nil
    ) -> SwiftSetting
```

It can be argued that both Swift modules and the volume of changes required for
migration can be large enough to justify spreading the review over several
sessions, especially if migration mode gains support for parallel
[source-incompatible fix-its][#producing-source-incompatible-fix-its].
However, we also expect higher-level migration tooling to allow for
incremental progress.

### Naming

The next candidates in line per discussions are ***adopt***, ***audit***,
***stage***, and ***preview***, respectively.
* ***preview*** and ***stage*** can both be understood as to report on the
  impact of a change, but are less commonly used in the sense of code
  migration.
* ***audit*** best denotes a recurrent action in this context, which we believe
  is more characteristic of the static analysis domain, such as enforcing a set
  of custom compile-time rules on code.
* An important reservation about ***adoption*** of source-breaking features is
  that it comprises both code migration and integration.
  It may be more prudent to save this term for a future add-on mode that,
  unlike migration mode, implies that the feature is enabled, and can be invoked
  in any language mode to aid developers in making better use of new behaviors
  or rules.
  To illustrate, this mode could appropriately suggest switching from `any P`
  to `some P` for `ExistentialAny`.
  
### `swift package migrate` vs. `swift migrate`

Rather than have migrate as a subcommand (ie. `swift package migrate`), another option is to add another top level command, ie. `swift migrate`.

As the command applies to the current package, we feel a `swift package` sub-command fits better than a new top-level command. This also aligns with the recently added package refactorings (eg. `add-target`).

## Acknowledgements

This proposal was inspired by documents prepared by [Allan Shortlidge] and
[Holly Borla].
Special thanks to Holly for her guidance throughout the draft stage.

<!-- Links -------------------------------------------------------------------->

[Holly Borla]: https://github.com/hborla
[Allan Shortlidge]: https://github.com/tshortli

[SE-0192]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0192-non-exhaustive-enums.md
[SE-0274]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0274-magic-file.md
[SE-0286]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0286-forward-scan-trailing-closures.md
[SE-0296]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0296-async-await.md
[SE-0335]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0335-existential-any.md
[SE-0337]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md
[SE-0341]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0341-opaque-parameters.md
[SE-0352]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0352-implicit-open-existentials.md
[SE-0354]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0354-regex-literals.md
[SE-0362]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0362-piecemeal-future-features.md
[SE-0362-feature-detection]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0362-piecemeal-future-features.md#feature-detection-in-source-code
[SE-0383]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0383-deprecate-uiapplicationmain-and-nsapplicationmain.md
[SE-0401]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0401-remove-property-wrapper-isolation.md
[SE-0401-acceptance]: https://forums.swift.org/t/accepted-with-modifications-se-0401-remove-actor-isolation-inference-caused-by-property-wrappers/66241
[SE-0409]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md
[SE-0411]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0411-isolated-default-values.md
[SE-0413]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md
[SE-0412]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0412-strict-concurrency-for-global-variables.md
[SE-0418]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0418-inferring-sendable-for-methods.md
[SE-0423]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0423-dynamic-actor-isolation.md
[SE-0434]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0434-global-actor-isolated-types-usability.md
[SE-0444]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
[async-inherit-isolation-pitch]: https://forums.swift.org/t/pitch-inherit-isolation-by-default-for-async-functions/74862
