# Swift Programming Language Evolution

**Before you initiate a pull request**, please read the process document. Ideas should be thoroughly discussed on the [swift-evolution mailing list](https://swift.org/community/#swift-evolution) first.

This repository tracks the ongoing evolution of Swift. It contains:

* Goals for upcoming Swift releases (this document).
* The [Swift evolution review schedule](schedule.md) tracking proposals to change Swift.
* The [Swift evolution process](process.md) that governs the evolution of Swift.
* [Commonly Rejected Changes](commonly_proposed.md), proposals which have been denied in the past.

This document describes goals for the Swift language on a per-release
basis, usually listing minor releases adding to the currently shipping
version and one major release out.  Each release will have many
smaller features or changes independent of these larger goals, and not
all goals are reached for each release.

Goals for past versions are included at the bottom of the document for
historical purposes, but are not necessarily indicative of the
features shipped. The release notes for each shipped version are the
definitive list of notable changes in each release.

## Development major version:  Swift 3.0

Expected release date: Late 2016

The primary goal of this release is to stabilize the binary interface
of the language and standard library. As part of this process, we will
focus and refine the language to provide better overall consistency in
feel and implementation. Swift 3.0 will contain *source-breaking*
changes from Swift 2.x where necessary to support these goals. More
concretely, this release is focused on several key areas:

* **Stable ABI**: Stabilize the binary interface (ABI) to guarantee a level of binary compatibility moving forward. This involves finalizing runtime data structures, name mangling, calling conventions, and so on, as well as finalizing some of the details of the language itself that have an impact on its ABI. Stabilizing the ABI also extends to the Standard Library, its data types, and core algorithms. Successful ABI stabilization means that applications and libraries compiled with future versions of Swift can interact at a binary level with applications and libraries compiled with Swift 3.0, even if the source language changes.
* **Resilience**: Solve the general problem of [fragile binary interface](https://en.wikipedia.org/wiki/Fragile_binary_interface_problem), which currently requires that an application be recompiled if any of the libraries it depends on changes. For example, adding a new stored property or overridable method to a class should not require all subclasses of that class to be recompiled. There are several broad concerns for resilience:
  * *What changes are resilient?*: Define the kinds of changes that can be made to a library without breaking clients of that library. Source-compatible changes to libraries are good candidates for resilient changes, but such decisions also consider the effects on the implementation.
  * *How is a resilient library implemented?*: What runtime representations are necessary to allow applications to continue to work after making resilient changes to a library? This dovetails with the stabilization of the ABI, because the stable ABI should be a resilient ABI.
  * *How do we maintain high performance?*: Resilient implementations often incur more execution overhead than non-resilient (or *fragile*) implementations, because resilient implementations need to leave some details unspecified until load time, such as the specific sizes of a class or offsets of a stored property.
* **Portability**: Make Swift available on other platforms and ensure that one can write portable Swift code that works properly on all of those platforms.
* **Type system cleanup and documentation**: Revisit and document the various subtyping and conversion rules in the type system, as well as their implementation in the compiler's type checker. The intent is to converge on a smaller, simpler type system that is more rigorously defined and more faithfully represented by the type checker.
* **Complete generics**: Generics are used pervasively in a number of Swift libraries, especially the standard library. However, there are a number of generics features the standard library requires to fully realize its vision, including recursive protocol constraints, the ability to make a constrained extension conform to a new protocol (i.e., an array of `Equatable` elements is `Equatable`), and so on. Swift 3.0 should provide those generics features needed by the standard library, because they affect the standard library's ABI.
* **Focus and refine the language**: Despite being a relatively young language, Swift's rapid development has meant that it has accumulated some language features and library APIs that don't fit well with the language as a whole. Swift 3 will remove or improve those features to provide better overall consistency for Swift.
* **API design guidelines**: The way in which Swift is used in popular
  libraries has almost as much of an effect on the character of Swift
  code as the Swift language itself. The [API design
  guidelines](https://swift.org/documentation/api-design-guidelines/) provide guidance for
  building great Swift APIs. For Swift 3.0, the Swift standard library
  and core libraries are being updated to match these guidelines, and
  Swift's Objective-C importer will [automatically map](proposals/0005-objective-c-name-translation.md) from the [Cocoa guidelines for
  Objective-C](https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/CodingGuidelines/CodingGuidelines.html)
  to the Swift API guidelines.

### Out of Scope

A significant part of delivering a major release is in deciding what
*not* to do, which means deferring many good ideas. The following is a
sampling of potentially good ideas that are not in scope for Swift
3.0:

* **Full source compatibility**: Swift 3.0 will not provide full
  source compatibility. Rather, it can and will introduce
  source-breaking changes needed to support the main goals of Swift
  3.0.

* **Concurrency**: Swift 3.0 relies entirely on platform concurrency
  primitives (libdispatch, Foundation, pthreads, etc.) for
  concurrency. Language support for concurrency is an often-requested
  and potentially high-value feature, but is too large to be in scope
  for Swift 3.0.

* **C++ Interoperability**: Swift's interoperability with C and
  Objective-C is one of its major strengths, allowing it to integrate
  with platform APIs. Interoperability with C++ libraries would
  enhance Swift's ability to work with existing libraries and APIs.
  However, C++ itself is a very complex language, and providing good
  interoperability with C++ is a significant undertaking that is out
  of scope for Swift 3.0.

* **Hygienic Macros** and **Compile-Time Evaluation**: A first-class macro
  system, or support for compile-time code execution in general, is something
  we may consider in future releases.  We don't want the existence of a macro
  system to be a workaround that reduces the incentive for making the core
  language great.

* **Major new library functionality**: The Swift Standard Library is focused on
  providing core "language" functionality as well as common data structures.  The
  "corelibs" projects are focused on providing existing Foundation functionality
  in a portable way.  We *will* consider minor extensions to their existing
  feature sets to round out these projects.
 
  On the other hand, major new libraries (e.g. a new Logging subsystem) are
  best developed as independent projects on GitHub (or elsewhere) and organized
  with the Swift Package Manager.  Beyond Swift 3 we may consider standardizing
  popular packages or expanding the scope of the project.  

### Implemented proposals for Swift 3

* [SE-0005: Better Translation of Objective-C APIs Into Swift](proposals/0005-objective-c-name-translation.md)
* [SE-0006: Apply API Guidelines to the Standard Library](proposals/0006-apply-api-guidelines-to-the-standard-library.md)
* [SE-0019: Swift Testing](proposals/0019-package-manager-testing.md)
* [SE-0031: Adjusting inout Declarations for Type Decoration](proposals/0031-adjusting-inout-declarations.md)
* [SE-0023: API Design Guidelines](proposals/0006-apply-api-guidelines-to-the-standard-library.md)
* [SE-0028: Modernizing Swift's Debugging Identifiers (\__FILE__, etc)](proposals/0028-modernizing-debug-identifiers.md)
* [SE-0034: Disambiguating Line Control Statements from Debugging Identifiers](proposals/0034-disambiguating-line.md)
* [SE-0040: Replacing Equal Signs with Colons For Attribute Arguments](proposals/0040-attributecolons.md)

### Accepted proposals for Swift 3.0

* [SE-0002: Removing currying `func` declaration syntax](proposals/0002-remove-currying.md)
* [SE-0003: Removing `var` from Function Parameters](proposals/0003-remove-var-parameters.md)
* [SE-0004: Remove the `++` and `--` operators](proposals/0004-remove-pre-post-inc-decrement.md)
* [SE-0007: Remove C-style for-loops with conditions and incrementers](proposals/0007-remove-c-style-for-loops.md)
* [SE-0029: Remove implicit tuple splat behavior from function applications](proposals/0029-remove-implicit-tuple-splat.md)
* [SE-0033: Import Objective-C Constants as Swift Types](proposals/0033-import-objc-constants.md)
* [SE-0035: Limiting `inout` capture to `@noescape` contexts](proposals/0035-limit-inout-capture.md)
* [SE-0037: Clarify interaction between comments & operators](proposals/0037-clarify-comments-and-operators.md)
* [SE-0038: Package Manager C Language Target Support](proposals/0038-swiftpm-c-language-targets.md)
* [SE-0039: Modernizing Playground Literals](proposals/0039-playgroundliterals.md)
* [SE-0046: Establish consistent label behavior across all parameters including first labels](proposals/0046-first-label.md)

## Development minor version:  Swift 2.2

Expected release date: Spring 2016

This release will focus on fixing bugs, improving
quality-of-implementation (QoI) with better warnings and diagnostics,
improving compile times, and improving performance.  It may also put
some finishing touches on features introduced in Swift 2.0, and
include some small additive features that don't break Swift code or
fundamentally change the way Swift is used. As a step toward Swift
3.0, it will introduce warnings about upcoming source-incompatible
changes in Swift 3.0 so that users can begin migrating their code
sooner.

### Implemented proposals for Swift 2.2

* [SE-0001: Allow (most) keywords as argument labels](proposals/0001-keywords-as-argument-labels.md)
* [SE-0011: Replace `typealias` keyword with `associatedtype` for associated type declarations](proposals/0011-replace-typealias-associated.md)
* [SE-0014: Constraining `AnySequence.init`](proposals/0014-constrained-AnySequence.md)
* [SE-0015: Tuple comparison operators](proposals/0015-tuple-comparison-operators.md)
* [SE-0020: Swift Language Version Build Configuration](proposals/0020-if-swift-version.md)
* [SE-0021: Naming Functions with Argument Labels](proposals/0021-generalized-naming.md)
* [SE-0022: Referencing the Objective-C selector of a method](proposals/0022-objc-selectors.md)

### Accepted proposals for Swift 2.2
* [SE-0008: Add a Lazy flatMap for Sequences of Optionals](proposals/0008-lazy-flatmap-for-optionals.md)

# Other Proposals

### Rejected proposals
* [SE-0009: Require self for accessing instance members](proposals/0009-require-self-for-accessing-instance-members.md)
* [SE-0010: Add StaticString.UnicodeScalarView](proposals/0010-add-staticstring-unicodescalarview.md)
* [SE-0013: Remove Partial Application of Non-Final Super Methods (Swift 2.2)](proposals/0013-remove-partial-application-super.md)
* [SE-0024: Optional Value Setter `??=`](proposals/0024-optional-value-setter.md)
* [SE-0027: Expose code unit initializers on String](proposals/0027-string-from-code-units.md)

## Review
[Swift Evolution Review Schedule](https://github.com/apple/swift-evolution/blob/master/schedule.md)

### Returned for Revision

* [SE-0018: Flexible Memberwise Initialization](proposals/0018-flexible-memberwise-initialization.md)
* [SE-0025: Scoped Access Level](proposals/0025-scoped-access-level.md)
* [SE-0030: Property Behaviors](proposals/0030-property-behavior-decls.md)

### Deferred for Future Discussion

* [SE-0026: Abstract classes and methods](proposals/0026-abstract-classes-and-methods.md)
