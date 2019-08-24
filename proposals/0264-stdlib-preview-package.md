# Standard Library Preview Package

* Proposal: [SE-0264](0264-stdlib-preview-package.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift), [Max Moiseev](https://github.com/moiseev)
* Review Manager: [Dave Abrahams](https://github.com/dabrahams)
* Status: **Scheduled for review (September 2...September 9, 2019)**

## Introduction

We propose the addition of a new package, `SwiftPreview`, which will form the initial landing spot for certain additions to the Swift Standard Library.

Adding this package serves the goal of allowing for rapid adoption of new standard library features, enabling sooner real-world feedback, and allowing for an initial period of time where that feedback can lead to source- and ABI-breaking changes if needed.

As a secondary benefit, it will reduce technical challenges for new community members implementing new features in the standard library.

In the first iteration, this package will take the following:

- free functions and methods, subscripts, and computed properties via extensions, that do not require access to the internal implementation of standard library types and that could reasonably be emitted into the client
- new types (for example, a sorted dictionary, or useful property wrapper implementations)
- new protocols, with conformance of existing library types to those protocols as appropriate

The package will not include features that need to be matched with language changes, nor functions that cannot practically be implemented without access to existing type internals or other non-public features such as LLVM builtins.

For the purposes of this document, we will refer to the proposed standard library preview package as "the package" and the standard library that ships with the toolchain as "the library".

## Motivation

### Facilitating Rapid Adoption and Feedback

It is common for a feature proposed and accepted through Swift Evolution and added to the Standard Library to wait for months before it gets any real life usage. Take [SE-0199](https://github.com/apple/swift-evolution/blob/master/proposals/0199-bool-toggle.md) (the introduction of `toggle`) for example. It was [accepted](https://forums.swift.org/t/accepted-se-199-add-toggle-to-bool/10681) almost 6 months before Swift 4.2 was released.

Even though all additions go through a thorough review, there is no substitute for feedback from real-world usage in production. Sometimes we discover that the API is not quite as good as it might have been.

While the toolchains downloadable from swift.org are useful for experimentation, they cannot be used to ship applications, so are rarely used for much more than "kicking the tires" on a feature. The beta period for Xcode provides slightly more real usage, but is still relatively short, with feedback often coming too late to be applied, needing, as it should, a further review on Swift evolution as well as time to integrate into the converging release. And the nature of standard library additions are such that you do not always have an immediate need early in the beta to try out a feature such as partial sort or a min heap.

Once a feature ships as part of a Swift release, any future changes resulting from feedback from real usage must clear the very high bar of source and ABI stability. Even if the change is merited and a source break is justified, the absolute need for ABI stability can rule out certain changes entirely on technical grounds. Furthermore, for performance reasons, standard library types that rely on specialization need to expose some of their internal implementation as part of their ABI, closing off future optimizations or performance fixes that are only discovered through subsequent usage and feedback.

### Technical Challenges for Contributors

The requirements for contributing to the standard library can be prohibitive. Not everybody has the time and resources to build a whole stack including LLVM, Clang, and the Swift compiler itself just to change a part of the Standard Library. Additionally, Xcode and XCTest cannot easily be used to maintain and test standard library code.

Integrating changes into the standard library requires knowledge of non-public features and idioms relating to ABI-stability. In particular, implementing a performant, specializable, ABI-stable collection type while preserving partial future flexibility is _significantly_ harder than writing one that is only source-stable. Harder still is knowing what internal implementation details can be changed after such a partially-transparent type has been published as ABI.

It would be of great benefit to the community to allow proposals and contributions to the standard library without these requirements, leaving integration of the final ABI-stable version to a later date and possibly other contributors with more experience maintaining ABI-stable code.

## Proposed solution

We propose the introduction of a "Standard Library Preview" SwiftPM package.

It will be a standalone project hosted on Github under the Apple organization, and will be part of the overall Swift project.

Proposals for additions to the standard library will have the option of first landing in the package for a period before migrating to the library. A PR against the preview package will be sufficient to fulfill the implementation requirement for an evolution proposal.

Additions to the package will **continue to use the Swift Evolution process.** All additions to the package should be made on the assumption that they will in time migrate to the ABI-stable standard library module that ships as part of the Swift toolchain. Proposals first landing in the package should be given the same level of scrutiny currently applied to standard library additions today.

However, requirements around source stability of the package will not be the same as those of the Swift standard library. Follow-up proposals and proposal amendments will be able to make source-breaking changes. Unlike the very high bar for source-breaking changes, and the absolute rules around ABI stability, the bar for changes to API currently only in the package will be that of any other evolution proposal of a new API.

Starting life in the package will not be mandatory. Proposals can opt instead to go straight into the standard library, especially if they do not meet the criteria for suitable package additions (see detailed design section). Functionality that are already available elsewhere, and have been proven in real-life use in that way, and is being "sunk" down into the standard library, would also be good candidates to skip the preview stage.

Since the package will not be ABI-stable, it will not ship as a binary on any platform, or be a dependency of any ABI-stable package. This allows for changes to the internal implementation of any type, and the change/removal of any function, as part of implementation changes, follow-on proposal amendments, or subsequent proposals.

## Detailed design

The following additive evolution proposals could be made using the preview package:

- New algorithms implemented as extensions on library protocols
- Utility types (e.g. wrapper types returned from functions like the `Lazy` types underlying `.lazy`)
- New protocols, including conformances by standard library types
- New collection types
- Property wrappers, such as a late-initialized wrapper

The following are examples of changes that would _not_ go into the package:

- Types introduced as part of and inseparable from language features (like `Optional` or `Error`)
- Implementations that rely on builtins for a reasonable implementation (like atomics or SIMD types)
- Implementations that require access to other types internals to be performant
- Changes that can't be done via a package, like adding customization points to protocols

Some of these cases will require a judgement call. For example, making an extension method a customization point may bring a minor performance optimization — and so not prevent initial deployment in the package — or it may be a major part of the implementation, making the difference between an `O(1)` and `O(n)` implementation. Whether a proposal should go into the preview package should be part of the evolution pitch and review discussions.

### Migration

An important aspect of the design is the experience of users of the package when features migrate from the package to the library. This is handled differently for functions and types.

#### Types

The preview package will have a different module name (`SwiftPreview`) to that of the standard library (`Swift`). As such, every type it declares will be distinct from the type once it migrates into the standard library, and can co-exist with it. Because the preview package is "above" the `Swift` module in the stack, users of the package will get the package version of the type by default in source files that have imported the preview package. They will be able to specify the library version instead by prepending `Swift.` to the type name. This has the benefit that addition of the type into the library is source-compatible with code already using the package version.

It does have a downside for code size. Package users do not benefit from the code-size wins of not including the new type in their app and instead using a version in the OS (though, given that most types in the standard library are generic and need to be specialized, this is not as big a problem as it might be). It would also mean package users miss out on optimizations that may be possible with the library implementation. Once inside the library, fast paths could benefit from internals of other types. For example, a ring buffer might be implemented in terms of the same storage as an `Array`, and conversion from one type to another could just be a question of copying a reference to the other's storage.

In these cases where the standard library's version of the type would be better, the user can easily switch to it by adding a `typealias TheType = Swift.TheType` to their code, or by prefixing the module on individual declarations if needed.

#### Functions

Unlike types, methods cannot be disambiguated. That is, you cannot write something like `myCollection.SwiftPreview.partialSort`. Swift does not have this feature yet (and while desirable, it should not be a dependency of this proposal). So there is no way similar to the typealias approach above to prefer the standard library's implementation of a protocol extension over the packages.

Since Swift 5.1, the standard library has had an internal feature that allows it to force-emit the body of a function into the client code, as a way of  back-deploying critical bug fixes. This `@_alwaysEmitIntoClient` attribute can be used from within the standard library to deploy functions only to prior platforms, at the cost of binary size of the client (when they use them). Again, this cost is mitigated in the case of protocol extensions by the fact that the specialized implementation is already inlined.

This allows use of `#if compiler` directives to simultaneously obsolete implementations in the package for the latest version of Swift when introducing new functions into the standard library. As long as the new library definitions are marked as `@_alwaysEmitIntoClient` the source compatibility of this should not be noticeable.

#### Type/Function Combinations

A common pattern used in the standard library is to return a type from a function, with the type driving much of the functionality initiated by the function call. For example, `myArray.lazy.map` returns a `LazySequence` which maps elements on the fly using the supplied closure.

Since types cannot be emitted into client code, these combination function/type features will follow the pattern for types. This will mean that the package version will be used by default, and type context will be needed to force a call to the standard library if desired.

#### Retirement from the Package

In order to keep the package size and maintainability manageable, implementations will be removed from the package in a version update **1 year** after migration to the standard library. This is a necessary balance between maintainability and convenience. Since the package is open-source, it should be possible to copy source for a specific feature if a user badly needs to keep it while also wanting to upgrade to a newer major version _and_ not upgrade to the latest compiler.

### Evolution

Introduction of the package does not change much in the process of Swift Evolution. Changes to the Standard Library API surface should go through a well developed pitch - discussion - implementation - proposal - decision life-cycle.

The main difference is that the final result will not land straight into the standard library. Instead, at a later point, a new kind of review will have to be run — one to promote parts of the package to the library. This should be done via an amendment to the proposal, and should be kept lightweight. A timeline for this secondary review should be set at proposal acceptance. The duration of time spent in the package should reflect the complexity of the proposal, and thus the amount of "bake time" it might need.

No proposal should be accepted into the package on a provisional basis: it should be assumed that every proposal will be migrated as-is unless feedback while in the package stage reveals that it was a clear misadventure. The review manager of the migration amendment will be responsible for ensuring that the review discussion focuses on new feedback from real-world use, and not purely relitigation of previously settled decisions made during the original review. 

### Testing

The standard library currently uses a combination of `StdlibUnittest` tests and raw `lit` tests. This works well, but is unfamiliar to most developers.

The preferred style of test for Swift packages is `XCTest`, and the package should adopt this approach. This has the benefit of familiarity, and integrates well with Xcode. The work to convert tests from this format to lit can be done at the point of migration into the library.

Certain features of `StdlibUnittest` – in particular crashLater and `StdlibCollectionUnittest`'s `checkCollection`, as well as the helper types like the minimal collections – should be ported over to `XCTest` if possible. This would make for an excellent starter bug, or could be done as part of introducing the first full-featured collection to the package that had a significant need for this kind of testing, but are not a requirement for accepting this proposal.

### GYB

There will be no use of [gyb](https://github.com/apple/swift/blob/master/utils/gyb.py) in the package. Gyb is a powerful and useful tool, but it can cause code that is difficult to read and write, and does not interact well with Xcode, so runs counter one of the goals of this package: to simplify contribution.

The need for gyb has been gradually reducing over time as language features like conditional conformance and improved optimization eliminated the need for it. Generally speaking, most uses of gyb indicate missing language or library features, and so implementations of proposals should probably start by proposing those features instead. For example, it is unlikely we would accept further proposals to splat out multiple operators for different sizes of tuple like we do with `==`. Instead, protocol conformance for non-nominal types and variadic generics should solve this problem more generally.

### Versioning

The fundamental goals of the preview package are somewhat at odds with the usual goals of semantic versioning. Source-breaking changes, including retirements after migrating into the standard library, or source-breaking changes resulting from evolution proposals prior to migration, will be common. Unlike many packages, the preview package will not converge over time, reducing the frequency of its version bumps.

As such, the preview package will remain at major version `0` **permanently**. Minor version bumps will be able to include source-breaking changes. Patch updates should not break source and will just be used for bug fixes.

The use of a `0` major version at all times will act as a signifier that adopters need to be comfortable with the requirement to continuously update
to the latest version of the package. It should not be taken as an indication that the package shouldn't be used for real-world code: the code should be considered production-worthy. But it is a preview, and not source stable. Where practical, deprecated shims could be used to preserve source compatibility between versions, but this may not always be practical.

The decision when to tag minor versions, and potentially to coalesce multiple changes into a single version bump, will be made by the release manager for the standard library as chosen by the Swift project lead.

### Source compatibility

None on Swift itself. The intention of the package is to facilitate long-term source stability by detecting issues with APIs prior to their integration into the library.

# Effect on ABI stability

None. The package will not be declared ABI stable. ABI stability will only happen when proposals are migrated to the standard library. This means that the preview package may not be used within binary frameworks.

Because we do not have cross-module optimization, package implementations should make use of `@inlinable` annotations. However, these annotations should be in the context of source stability only and should be fully reevaluated by the library integrator when stabilizing the ABI.

## Alternatives considered

### Single versus Multiple Packages

An alternative to a single monolithic preview package would be multiple packages. For example, each accepted evolution proposal could have its own package.

This would trade convenience for flexibility. In particular, multiple packages would avoid the source-breaking nature of proposal revisions (and the lesser problem of any additions being technically source breaking). But it would mean that adopters of the different previews would need to look up and add individual proposals rather than get them all in one go, and would rarely "discover" new features also in the package they're already importing.

### Simultaneous Preview and Library Addition

If the goal was to facilitate rapid release only, but not a longer feedback period, then the additional review step would not be necessary. Instead, new features would be integrated directly into the package and library simultaneously.

However, experience has shown that proposals are not always perfect. Recently, significant if manageable issues were discovered with the API of both [SE-180](https://github.com/apple/swift-evolution/blob/master/proposals/0180-string-index-overhaul.md) and [SE-202](https://github.com/apple/swift-evolution/blob/master/proposals/0202-random-unification.md), and in a near-miss [SE-220](https://github.com/apple/swift-evolution/blob/master/proposals/0220-count-where.md) had to be reverted late during 5.0 convergence due to typechecker performance impact. These issues would likely have been caught by a more prolonged exposure in a package.

### Is a Second Review Necessary?

Whether or not a proposal accepted and integrated into the package actually needs a second review is also worth considering. An alternative would be to set a timer, and then to automatically migrate the proposal into the library when the timer expires, without need for a second review. Changes could still be initiated to the preview package, but a new proposal would be required to interrupt the otherwise automatic migration timetable.

