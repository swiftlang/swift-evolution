# Adoption tooling for Swift features

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: TBD
* Review: TBD

## Introduction

The future we envision for Swift will take many more valiant evolutionary
decisions and major transformations with a proportional impact on its
expanding domains.

Source-breaking changes to Swift were first staged behind the now obsolete
Swift 3 language mode.
Each successive major release has since included a correponding language mode,
using the previous language mode as the default to maximize source
compatibility.
For example, Swift 6 compilers operate in the Swift 5 language mode by default.
Users that are not ready to adopt the new default can still specify an earlier
language mode explicitly.
Once the time is right, old language modes together with the legacy behaviors
they manifest will be proposed to be deprecated.

The cumulative source compatibility impact of the changes that were accreting
around a converging Swift 6 language mode gave rise to the
[Swift feature model][SE-0362], which enabled piecemeal adoption of individual
features as opposed to an entire language mode.
Upcoming features facilitated sooner adoption of improvements and drastically
reduced the pressures in our evolutionary model.

This proposal centers seeks to improve the experience of adopting individual
features.
The proposition is that the growing complexity and diversification of Swift
calls for a flexible, integrated mechanism for supporting quality assistance
with feature adoption.
And that — in principle — comprehensive, code-aware assistance can be delivered
without breaking source and acted upon incrementally.

## Motivation

Whether you are adjusting code to follow new language rules or researching ways
to apply new functionality, adopting features can be a time-consuming endeavor
at the least.

Some source-breaking language features are anticipated to generate hundreds
of targeted errors in sizable projects.
Occasionally, errors will also cascade down the dependecy graph or fall out
from changes in behavior without a clear indication of the precise cause or source of
the issue, requiring further investigation.
Developers are left to either resolve all of these errors or address a subset
and take the risk of switching the feature back off before they can resume
development and focus on other important tasks.

### User Intent

> [!CAUTION]
> TODO: No way for users to declare an intetion to adopt a feature

### Automation

Many existing and prospective upcoming features imply or implement simple and
consistent code modifications to facilitate the adoption process:

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

Feature

Extending diagnostic metadata to include information that allows for
recognizing these diagnostics and distinguishing semantics-preserving fix-its
from alternative source changes would open up numerous opportunities for
higher-level tools — ranging from the Swift package manager to IDEs — to
implement powerful solutions for organizing, automating, and tuning code
migration processes.

### Flexibility/Ergonomics

> [!CAUTION]
> Still a draft.

Although upcoming features should strive to facilitate code migration, 

language design principles may prevail over bespoke code migration solutions.
Some features, like [StrictConcurrency][SE-0337], inherently require user
intervetion

Adjusting to new behaviors or language requirements can demand research,
careful consideration, coordinated efforts, and manual code refactorings,
sometimes on a case-by-case basis.

Currently best solution is to implement custom staging solutions. This approach
has limited applications (why?).

UPCOMING_FEATURE(DynamicActorIsolation, 423, 6)
UPCOMING_FEATURE(GlobalActorIsolatedTypesUsability, 0434, 6)
UPCOMING_FEATURE(StrictConcurrency, 0337, 6)
UPCOMING_FEATURE(IsolatedDefaultValues, 411, 6)
UPCOMING_FEATURE(RegionBasedIsolation, 414, 6)

## Proposed solution

Introduce the notion of a "adoption" mode for individual experimental and
upcoming features.
The core idea behind adoption mode is a declaration of intent that can be
leveraged to build holistic supportive adoption experiences for developers.
If enabling a feature communicates an intent to *enact* rules, adoption mode
communicates an intent to *adopt* them.
An immediate benefit of adoption mode is the capability to deliver source
modifications that can be applied to preserve or improve the behavior of
existing code whenever the feature provides for them.

> [!NOTE]
> The subject of this proposal is an enhancement to the Swift feature model.
> Applications of adoption mode to existing features are beyond its scope.

## Detailed design

### Behavior

The action of enabling a previously disabled source-breaking feature in adoption
mode per se must never produce compilation errors.
Additionally, this action will have no effect on the state of the feature if
it does not implement the mode.
A corresponding warning will be emitted in this case to avoid the false
impression that the impacted source code is compatible with the feature.

> [!NOTE]
> Experimental features can be both additive and source-breaking.
> Upcoming features are necessarily source-breaking.

adoption mode will deliver guidance in the shape of warnings, notes, remarks,
and fix-its, as and when appropriate.

When implemented, adoption mode for upcoming features is expected to anticipate
and call out any behavioral differences that will result from enacting the
feature, coupling diagnostic messages with counteracting source-compatible
changes and helpful alternatives whenever possible.
Adoption mode cannot guarantee to provide exclusively source-compatible
modifications because the impact of a change on dependent source code is
generally unpredictable.
Neither can it promise to always offer fix-its in the first place for the
same reason in regards to user intention.

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
belong to a diagnostic group named after the feature.
There are several reasons why this will be useful:
* Future feature-oriented adoption tooling can use the group identifier to
  filter out relevant diagnostics.
* IDEs and other diagnostic consumers can integrate group identifiers into
  their interfaces to, well, group diagnostics, as well as to communicate
  relationships between diagnostics and features. This can prove especially
  handy when multiple features are simultaneously enabled in adoption mode.

## Source compatibility

This proposal does not affect language rules. The described changes to the API
surface are source-compatible.

## ABI compatibility

This proposal does not affect binary compatibility or binary interfaces.

## Implications on adoption

Demoting an enabled source-breaking feature to adoption mode may affect
behavior and is therefore a potentially source-breaking action.

## Future directions

### Augment diagnostic metadata



### Support baseline features

Adoption mode can be extrapolated to baseline features, such as `TypedThrows`
or [opaque parameter types][SE-0341], with an emphasis on actionable adoption
tips and otherwise unsolicited educational notes.
These additive features are hard-enabled in all language modes and become an
integral part of the language as soon as they ship.
Baseline feature identifiers are currently kept around for the sole purpose of
supporting [feature availability checks][feature-detection] in conditional
compilation blocks.

### `swift adopt`

The Swift package manager could implement an `adopt` subcommand with an
interactive command line interface similar to `git add --patch` for selecting
and applying fix-its ...

## Alternatives considered

### Naming



## Acknowledgements

This proposal was inspired by documents prepared by [Allan Shortlidge][Allan]
and [Holly Borla][Holly].
Special thanks to Holly for her feedback throughout the draft stage.

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
[SE-0412]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0412-strict-concurrency-for-global-variables.md
[SE-0418]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0418-inferring-sendable-for-methods.md
[SE-0444]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
[async-inherit-isolation-pitch]: https://forums.swift.org/t/pitch-inherit-isolation-by-default-for-async-functions/74862
