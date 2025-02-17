# Adoption tooling for Swift features

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: TBD
* Review: TBD

## Introduction

In Swift 5.8 introduced [upcoming features][SE-0362],
which enabled piecemeal adoption of individual source-incompatible changes that
are included in a language mode.
Many upcoming features have a mechanical migration, meaning the compiler can
determine the exact source changes necessary to allow the code to compile under
the upcoming feature while preserving the behavior of the code.
This proposal seeks to improve the experience of enabling individual
upcoming features by providing a mechanism for producing the necessary source
code changes automatically for a given set of upcoming features that a
programmer wants to enable.

## Motivation

Adopting certain features is a time-consuming endeavor at the least.
It is the responsibility of project maintainers to preserve source (and binary)
compatibility both internally and externally for library clients when enabling
an upcoming feature, which can be difficult or tedious without having tools to
help detect possibly inadvertent changes and perform monotonous migration
shenanigans for you.
*Our* responsibility is to make that an easier task for everybody.

### User intent

A primary limiting factor in how proactively and accurately the compiler can
assist developers with adopting a feature is a lack of comprehension of user
intent.
Is the developer expecting guidance on adopting an improvement?
All the compiler knows to do when a feature is enabled is to compile code
accordingly.
This suffices if a feature merely supplants an existing syntactical construct
or changes the behavior of existing code in strictly predictable ways because
Swift can infer the need to suggest a fix just from spotting certain code
patterns.

Needless to say, not all upcoming features fall under these criteria (and not
all features are source-breaking in the first place). Consider
[`DisableOutwardActorInference`][SE-0401], which changes actor isolation
inference of a type that contains an actor-isolated property wrapper. There
is no way for the programmer to specify that they'd like compiler fix-its to
make the existing actor isolation inference explicit. If they enable the
upcoming feature, their code will simply behave differently. This was a
point of debate in the review of SE-0401, and the Language Steering Group
concluded that automatic migration tooling is the right way to address this
particular workflow, as [noted in the acceptance notes][SE-0401-acceptance:

> the Language Steering Group believes that separate migration tooling to
> help programmers audit code whose behavior will change under Swift 6 mode
> would be beneficial for all upcoming features that can change behavior
> without necessarily emitting errors.

### Automation

Many existing and prospective upcoming features come with simple and reliable
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
* [`GlobalConcurrency`][SE-0412]:
  - Convert the global variable to a `let` (or)
  - `@MainActor`-isolate it (or)
  - Mark it with `nonisolated(unsafe)`
* [`MemberImportVisibility`][SE-0444]: Add explicit imports appropriately.
* [`InferSendableFromCaptures`][SE-0418]: Suppress inference with coercions
  and type annotations.
* [Inherit isolation by default for async functions][async-inherit-isolation-pitch]:
  Mark nonisolated functions with the proposed attribute.

Extending diagnostic metadata to include information that allows for
recognizing these diagnostics and distinguishing semantics-preserving fix-its
from alternative source changes will open up numerous opportunities for
higher-level tools — ranging from the Swift package manager to IDEs — to
implement powerful solutions for organizing, automating, and tuning feature
adoption processes.

It is not always feasible or in line with language design principles for an
upcoming feature to have a mechanical migration path.
For example, the following upcoming features require manual migration to
preserve semantics:

* [`DynamicActorIsolation`][SE-0423]
* [`GlobalActorIsolatedTypesUsability`][SE-0434]
* [`StrictConcurrency`][SE-0337]
* [`IsolatedDefaultValues`][SE-0411]

## Proposed solution

Introduce the notion of an "adoption" mode for individual experimental and
upcoming features.
The core idea behind adoption mode is a declaration of intent that can be
leveraged to build better supportive adoption experiences for developers.
If enabling a feature communicates an intent to *enact* rules, adoption mode
communicates an intent to *adopt* them.
An immediate benefit of adoption mode is the capability to deliver source
modifications that can be applied to preserve or improve the behavior of
existing code whenever the feature provides for them.

This proposal will support the set of existing upcoming features that
have mechanical migrations, as described in the [Automation](#automation)
section.
All future proposals that introduce a new upcoming feature and provide a
mechanical migration are expected to support adoption mode and detail its
behavior in the *Source compatibility* section of the proposal.

## Detailed design

### Behavior

The action of enabling a previously disabled source-breaking feature in adoption
mode per se must not cause compilation errors.
Additionally, this action will have no effect if the mode is not supported.
A corresponding warning will be emitted in this case to avoid the false
impression that the impacted source code is compatible with the feature.

> [!NOTE]
> Experimental features can be both additive and source-breaking.
> Upcoming features are necessarily source-breaking.

Adoption mode should deliver guidance in the shape of regular diagnostics.
For arbitrary upcoming features, adoption mode is expected to anticipate and
call out any compatibility issues that result from enacting the feature,
coupling diagnostic messages with counteracting compatible changes and helpful
alternatives whenever feasible.
Compatibility issues encompass both source and binary compatibility issues,
including behavioral changes.

Note that adoption mode does not provide any new general guarantees in respect
to fix-its.
We cannot promise to offer exclusively compatible modifications.
Besides the impact of a change on dependent source code being generally
unpredictable, it can be reasonable to couple compatible fix-its with
potentially incompatible, albeit better, alternatives, as in `any P` → `some P`.
The same stands for provision of modifications — features might not have a
mechanical migration path, and the compiler remains inherently limited in the
extent to which it can make assumptions about what is helpful or best for the
programmer.

### Interface

#### Compiler

The `-enable-*-feature` frontend and driver command line options will start
supporting an optional mode specifier with `adoption` as the only valid mode:

```
-enable-upcoming-feature <feature>[:<mode>]
-enable-experimental-feature <feature>[:<mode>]

<mode> := adoption
```

For example:

```
-enable-upcoming-feature InternalImportsByDefault:adoption
```

In a series of either of these options applied to a given feature, only the
last option will be honored.
If an upcoming feature is both implied by the effective language mode and
enabled in adoption mode using either of the aforementioned options, the latter
will be disregarded.

#### Swift package manager

The [`SwiftSetting.enableUpcomingFeature`] and
[`SwiftSetting.enableExperimentalFeature`] methods from the
[`PackageDescription`](https://developer.apple.com/documentation/packagedescription)
library will be augmented with a `mode` parameter defaulted to match the
current behavior:

```swift
extension SwiftSetting {
  @available(_PackageDescription, introduced: 6.2)
  public enum SwiftFeatureMode {
    case adoption
    case on
  }
}
```
```diff
    public static func enableUpcomingFeature(
        _ name: String,
+       mode: SwiftFeatureMode = .on,
        _ condition: BuildSettingCondition? = nil
    ) -> SwiftSetting {
+       let argument = switch mode {
+           case .adoption: "\(name):adoption"
+           case .mode: name
+       }
+
        return SwiftSetting(
-           name: "enableUpcomingFeature", value: [name], condition: condition)
+           name: "enableUpcomingFeature", value: [argument], condition: condition)
    }
```
```diff
    public static func enableExperimentalFeature(
        _ name: String,
+       mode: SwiftFeatureMode = .on,
        _ condition: BuildSettingCondition? = nil
    ) -> SwiftSetting {
+       let argument = switch mode {
+           case .adoption: "\(name):adoption"
+           case .mode: name
+       }
+
        return SwiftSetting(
-           name: "enableExperimentalFeature", value: [name], condition: condition)
+           name: "enableExperimentalFeature", value: [argument], condition: condition)
    }
```

For example:

```
SwiftSetting.enableUpcomingFeature("InternalImportsByDefault", mode: .adoption)
```

### Diagnostics

Diagnostics emitted in relation to a specific feature in adoption mode must
belong to a diagnostic group named after the feature. The names of diagnostic
groups can be displayed alongside diagnostic messages using
`-print-diagnostic-groups` and used to associate messages with features.

## Source compatibility

This proposal does not affect language rules. The described changes to the API
surface are source-compatible.

## ABI compatibility

This proposal does not affect binary compatibility or binary interfaces.

## Implications on adoption

Entering or exiting adoption mode may affect behavior and is therefore a
potentially source-breaking action.

## Future directions

### Applications beyond migration

Adoption mode can be extrapolated to additive features, such as
[typed `throws`][SE-0413] or [opaque parameter types][SE-0341], by providing
actionable adoption tips.
Additive features are hard-enabled and become an integral part of the language
as soon as they ship.
Many recent additive features are already integrated into the Swift feature
model and kept around for the sole purpose of supporting
[feature availability checks][feature-detection] in conditional compilation
blocks.

Another potential direction for adoption mode is promotion of best practices.

### Augmented diagnostic metadata

The current serialization format for diagnostics does not include information
about diagnostic groups or whether a particular fix-it preserves semantics.
There are several reasons why this data can be valuable for users, and why it
is essential for future tools built around adoption mode:
* The diagnostic group name can be used to, well, group diagnostics, as well as
  to communicate relationships between diagnostics and features and filter out
  relevant diagnostics.
  This can prove especially handy when multiple features are simultaneously
  enabled in adoption mode, or when similar diagnostic messages are caused by
  distinct features.
* Fix-its that preserve semantics can be prioritized and auto-applied in
  previews.

### `swift adopt`

The Swift package manager could implement an `adopt` subcommand for interactive
review and application of adoption mode output for a given set of features,
with a command line interface similar to `git add --patch`.

## Alternatives considered

### Naming

Perhaps the most intuitive alternative to "adoption" is "migration". We
settled on the former because there is no reason for this concept to be limited
to upcoming features or migrational changes.

## Acknowledgements

This proposal was inspired by documents prepared by [Allan Shortlidge][Allan]
and [Holly Borla][Holly].
Special thanks to Holly for her guidance throughout the draft stage.

<!----------------------------------------------------------------------------->

[Holly]: https://github.com/hborla
[Allan]: https://github.com/tshortli

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
[feature-detection]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0362-piecemeal-future-features.md#feature-detection-in-source-code
[SE-0383]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0383-deprecate-uiapplicationmain-and-nsapplicationmain.md
[SE-0401]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0401-remove-property-wrapper-isolation.md
[SE-0409]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md
[SE-0411]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0411-isolated-default-values.md
[SE-0413]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md
[SE-0412]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0412-strict-concurrency-for-global-variables.md
[SE-0418]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0418-inferring-sendable-for-methods.md
[SE-0423]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0423-dynamic-actor-isolation.md
[SE-0434]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0434-global-actor-isolated-types-usability.md
[SE-0444]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
[async-inherit-isolation-pitch]: https://forums.swift.org/t/pitch-inherit-isolation-by-default-for-async-functions/74862
[SE-0401-acceptance]: https://forums.swift.org/t/accepted-with-modifications-se-0401-remove-actor-isolation-inference-caused-by-property-wrappers/66241
