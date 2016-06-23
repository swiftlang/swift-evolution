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

The primary goal of this release is to solidify and mature the Swift language and
development experience.  While source breaking changes to the language have been
the norm for Swift 1 through 3, we would like the Swift 3.x (and Swift 4+)
languages to be as *source compatible* with Swift 3.0 as reasonably possible.
However, this will still be best-effort: if there is a really good reason to
make a breaking change beyond Swift 3, we will consider it and find the least
invasive way to roll out that change (e.g. by having a long deprecation cycle).

To achieve this end, Swift 3 focuses on getting the basics right for the
long term: 

* **API design guidelines**: The way in which Swift is used in popular
  libraries has almost as much of an effect on the character of Swift
  code as the Swift language itself. The [API naming and design
  guidelines](https://swift.org/documentation/api-design-guidelines/) are a
  carefully crafted set of guidelines for building great Swift APIs.

* **Automatic application of naming guidelines to imported Objective-C APIs**:
  When importing Objective-C APIs, the Swift 3 compiler 
  [automatically maps](proposals/0005-objective-c-name-translation.md) methods
  into the new Swift 3 naming guidelines, and provides a number of Objective-C
  features to control and adapt this importing.

* **Adoption of naming guidelines in key APIs**: The Swift Standard Library has
  been significantly overhauled to embrace these guidelines, and key libraries
  like [Foundation](proposals/0069-swift-mutability-for-foundation.md) and
  [libdispatch](proposals/0088-libdispatch-for-swift3.md) have seen major
  updates, which provide the consistent development experience we seek.

* **Swiftification of imported Objective-C APIs**: Beyond the naming guidelines,
  Swift 3 provides an improved experience for working with Objective-C APIs.
  This includes importing
  [Objective-C generic classes](proposals/0057-importing-objc-generics.md),
  providing the ability to [import C APIs](proposals/0044-import-as-member.md)
  into an "Object Oriented" style, much nicer
  [imported string enums](proposals/0033-import-objc-constants.md), safer
  syntax to work with [selectors](proposals/0022-objc-selectors.md) and
  [keypaths](proposals/0062-objc-keypaths.md), etc.

* **Focus and refine the language**: Since Swift 3 is the last release to make
  major source breaking changes, it is also the right release to reevaluate the
  syntax and semantics of the core language.  This means that some obscure or
  problematic features will be removed, we focus on improving consistency of
  syntax in many small ways (e.g. by 
  [revising handling of parameter labels](proposals/0046-first-label.md), and
  focus on forward looking improvements to the type system.  This serves the
  overall goal of making Swift a simpler, more predictable, and more consistent
  language over the long term.

* **Improvements to tooling quality**: The overall quality of the compiler is
  really important to us: it directly affects the joy of developing in Swift.
  Swift 3 focuses on fixing bugs in the compiler and IDE features, improving the
  speed of compile times and incremental builds, improving the performance of
  the generated code, improving the precision of error and warning messages, etc.

One of the reasons that stability is important is that **portability** to non-Apple
systems is also a strong goal of Swift 3.  This release enables
broad scale adoption across multiple platforms, including significant
functionality in the [Swift core libraries](https://swift.org/core-libraries/)
(Foundation, libdispatch, XCTest, etc).  A useful Linux/x86 port is
already available (enabling many interesting server-side scenarios), and work is
underway across the community to bring Swift to FreeBSD, Raspberry Pi, Android,
Windows, and others.  While we don't know which platforms will reach a useful
state by the launch of Swift 3, significant effort continues to go into making
the compiler and runtime as portable as practically possible.

Finally, Swift 3 also includes a mix of relatively small but important additions
to the language and standard library that make solving common problems easier and
make everything feel nicer.  A detailed list of accepted proposals is included
below:


### Implemented proposals for Swift 3

* [SE-0002: Removing currying `func` declaration syntax](proposals/0002-remove-currying.md)
* [SE-0003: Removing `var` from Function Parameters](proposals/0003-remove-var-parameters.md)
* [SE-0004: Remove the `++` and `--` operators](proposals/0004-remove-pre-post-inc-decrement.md)
* [SE-0005: Better Translation of Objective-C APIs Into Swift](proposals/0005-objective-c-name-translation.md)
* [SE-0006: Apply API Guidelines to the Standard Library](proposals/0006-apply-api-guidelines-to-the-standard-library.md)
* [SE-0007: Remove C-style for-loops with conditions and incrementers](proposals/0007-remove-c-style-for-loops.md)
* [SE-0008: Add a Lazy flatMap for Sequences of Optionals](proposals/0008-lazy-flatmap-for-optionals.md)
* [SE-0016: Adding initializers to Int and UInt to convert from UnsafePointer and UnsafeMutablePointer](proposals/0016-initializers-for-converting-unsafe-pointers-to-ints.md)
* [SE-0017: Change `Unmanaged` to use `UnsafePointer`](proposals/0017-convert-unmanaged-to-use-unsafepointer.md)
* [SE-0019: Swift Testing](proposals/0019-package-manager-testing.md)
* [SE-0023: API Design Guidelines](proposals/0023-api-guidelines.md)
* [SE-0028: Modernizing Swift's Debugging Identifiers (\__FILE__, etc)](proposals/0028-modernizing-debug-identifiers.md)
* [SE-0029: Remove implicit tuple splat behavior from function applications](proposals/0029-remove-implicit-tuple-splat.md)
* [SE-0031: Adjusting inout Declarations for Type Decoration](proposals/0031-adjusting-inout-declarations.md)
* [SE-0032: Add `first(where:)` method to `SequenceType`](proposals/0032-sequencetype-find.md)
* [SE-0033: Import Objective-C Constants as Swift Types](proposals/0033-import-objc-constants.md)
* [SE-0034: Disambiguating Line Control Statements from Debugging Identifiers](proposals/0034-disambiguating-line.md)
* [SE-0037: Clarify interaction between comments & operators](proposals/0037-clarify-comments-and-operators.md)
* [SE-0039: Modernizing Playground Literals](proposals/0039-playgroundliterals.md)
* [SE-0040: Replacing Equal Signs with Colons For Attribute Arguments](proposals/0040-attributecolons.md)
* [SE-0043: Declare variables in 'case' labels with multiple patterns](proposals/0043-declare-variables-in-case-labels-with-multiple-patterns.md)
* [SE-0044: Import as Member](proposals/0044-import-as-member.md)
* [SE-0046: Establish consistent label behavior across all parameters including first labels](proposals/0046-first-label.md)
* [SE-0047: Defaulting non-Void functions so they warn on unused results](proposals/0047-nonvoid-warn.md)
* [SE-0048: Generic Type Aliases](proposals/0048-generic-typealias.md)
* [SE-0049: Move @noescape and @autoclosure to be type attributes](proposals/0049-noescape-autoclosure-type-attrs.md)
* [SE-0052: Change IteratorType post-nil guarantee](proposals/0052-iterator-post-nil-guarantee.md)
* [SE-0053: Remove explicit use of `let` from Function Parameters](proposals/0053-remove-let-from-function-parameters.md)
* [SE-0054: Abolish `ImplicitlyUnwrappedOptional` type](proposals/0054-abolish-iuo.md)
* [SE-0055: Make unsafe pointer nullability explicit using Optional](proposals/0055-optional-unsafe-pointers.md)
* [SE-0057: Importing Objective-C Lightweight Generics](proposals/0057-importing-objc-generics.md)
* [SE-0059: Update API Naming Guidelines and Rewrite Set APIs Accordingly](proposals/0059-updated-set-apis.md)
* [SE-0061: Add Generic Result and Error Handling to autoreleasepool()](proposals/0061-autoreleasepool-signature.md)
* [SE-0062: Referencing Objective-C key-paths](proposals/0062-objc-keypaths.md)
* [SE-0064: Referencing the Objective-C selector of property getters and setters](proposals/0064-property-selectors.md)
* [SE-0065: A New Model For Collections and Indices](proposals/0065-collections-move-indices.md)
* [SE-0066: Standardize function type argument syntax to require parentheses](proposals/0066-standardize-function-type-syntax.md)
* [SE-0069: Mutability and Foundation Value Types](proposals/0069-swift-mutability-for-foundation.md)
* [SE-0070: Make Optional Requirements Objective-C-only](proposals/0070-optional-requirements.md)
* [SE-0071: Allow (most) keywords in member references](proposals/0071-member-keywords.md)
* [SE-0072: Fully eliminate implicit bridging conversions from Swift](proposals/0072-eliminate-implicit-bridging-conversions.md)
* [SE-0085: Package Manager Command Names](proposals/0085-package-manager-command-name.md)
* [SE-0093: Adding a public `base` property to slices](proposals/0093-slice-base.md)
* [SE-0094: Add sequence(first:next:) and sequence(state:next:) to the stdlib](proposals/0094-sequence-function.md)

### Accepted proposals which do not have a complete implementation

This is the list of proposals which have been accepted for inclusion into Swift,
but they are not implemented yet, and may not have anyone signed up to implement
them.  If they are not implemented in time for Swift 3, they will roll into a
subsequent release.

* [SE-0025: Scoped Access Level](proposals/0025-scoped-access-level.md)
* [SE-0035: Limiting `inout` capture to `@noescape` contexts](proposals/0035-limit-inout-capture.md)
* [SE-0036: Requiring Leading Dot Prefixes for Enum Instance Member Implementations](proposals/0036-enum-dot.md)
* [SE-0038: Package Manager C Language Target Support](proposals/0038-swiftpm-c-language-targets.md)
* [SE-0042: Flattening the function type of unapplied method references](proposals/0042-flatten-method-types.md)
* [SE-0045: Add scan, prefix(while:), drop(while:), and iterate to the stdlib](proposals/0045-scan-takewhile-dropwhile.md)
* [SE-0060: Enforcing order of defaulted parameters](proposals/0060-defaulted-parameter-order.md)
* [SE-0063: SwiftPM System Module Search Paths](proposals/0063-swiftpm-system-module-search-paths.md)
* [SE-0067: Enhanced Floating Point Protocols](proposals/0067-floating-point-protocols.md)
* [SE-0068: Expanding Swift `Self` to class members and value types](proposals/0068-universal-self.md)
* [SE-0075: Adding a Build Configuration Import Test](proposals/0075-import-test.md)
* [SE-0076: Add overrides taking an UnsafePointer source to non-destructive copying methods on UnsafeMutablePointer](proposals/0076-copying-to-unsafe-mutable-pointer-with-unsafe-pointer-source.md)
* [SE-0080: Failable Numeric Conversion Initializers](proposals/0080-failable-numeric-initializers.md)
* [SE-0081: Move `where` clause to end of declaration](proposals/0081-move-where-expression.md)
* [SE-0082: Package Manager Editable Packages](proposals/0082-swiftpm-package-edit.md)
* [SE-0088: Modernize libdispatch for Swift 3 naming conventions](proposals/0088-libdispatch-for-swift3.md)
* [SE-0089: Renaming `String.init<T>(_: T)`](proposals/0089-rename-string-reflection-init.md)
* [SE-0092: Typealiases in protocols and protocol extensions](proposals/0092-typealiases-in-protocols.md)
* [SE-0096: Converting dynamicType from a property to an operator](proposals/0096-dynamictype.md)
* [SE-0099: Restructuring Condition Clauses](proposals/0099-conditionclauses.md)

## Swift 2.2 - Released on March 21, 2016

[This release](https://swift.org/blog/swift-2-2-released/) focused on fixing
bugs, improving quality-of-implementation (QoI)
with better warnings and diagnostics, improving compile times, and improving
performance.  It put some finishing touches on features introduced in Swift 2.0, 
and included some small additive features that don't break Swift code or
fundamentally change the way Swift is used. As a step toward Swift 3, it
introduced warnings about upcoming source-incompatible changes in Swift 3
so that users can begin migrating their code sooner.

Aside from warnings, a major goal of this release was to be as source compatible
as practical with Swift 2.0.

### Implemented proposals in Swift 2.2

* [SE-0001: Allow (most) keywords as argument labels](proposals/0001-keywords-as-argument-labels.md)
* [SE-0011: Replace `typealias` keyword with `associatedtype` for associated type declarations](proposals/0011-replace-typealias-associated.md)
* [SE-0014: Constraining `AnySequence.init`](proposals/0014-constrained-AnySequence.md)
* [SE-0015: Tuple comparison operators](proposals/0015-tuple-comparison-operators.md)
* [SE-0020: Swift Language Version Build Configuration](proposals/0020-if-swift-version.md)
* [SE-0021: Naming Functions with Argument Labels](proposals/0021-generalized-naming.md)
* [SE-0022: Referencing the Objective-C selector of a method](proposals/0022-objc-selectors.md)


# Other Proposals

### Rejected or withdrawn proposals
* [SE-0009: Require self for accessing instance members](proposals/0009-require-self-for-accessing-instance-members.md)
* [SE-0010: Add StaticString.UnicodeScalarView](proposals/0010-add-staticstring-unicodescalarview.md)
* [SE-0012: Add `@noescape` to public library API](proposals/0012-add-noescape-to-public-library-api.md)
* [SE-0013: Remove Partial Application of Non-Final Super Methods (Swift 2.2)](proposals/0013-remove-partial-application-super.md)
* [SE-0024: Optional Value Setter `??=`](proposals/0024-optional-value-setter.md)
* [SE-0027: Expose code unit initializers on String](proposals/0027-string-from-code-units.md)
* [SE-0041: Updating Protocol Naming Conventions for Conversions](proposals/0041-conversion-protocol-conventions.md)
* [SE-0051: Conventionalizing stride semantics](proposals/0051-stride-semantics.md)
* [SE-0056: Allow trailing closures in `guard` conditions](proposals/0056-trailing-closures-in-guard.md)
* [SE-0073: Marking closures as executing exactly once](proposals/0073-noescape-once.md)
* [SE-0074: Implementation of Binary Search functions](proposals/0074-binary-search.md)
* [SE-0084: Allow trailing commas in parameter lists and tuples](proposals/0084-trailing-commas.md)
* [SE-0087: Rename `lazy` to `@lazy`](proposals/0087-lazy-attribute.md)
* [SE-0097: Normalizing naming for "negative" attributes](proposals/0097-negative-attributes.md)
* [SE-0098: Lowercase `didSet` and `willSet` for more consistent keyword casing](proposals/0098-didset-capitalization.md)

## Review
[Swift Evolution Review Schedule](https://github.com/apple/swift-evolution/blob/master/schedule.md)

### Returned for Revision

* [SE-0018: Flexible Memberwise Initialization](proposals/0018-flexible-memberwise-initialization.md)
* [SE-0030: Property Behaviors](proposals/0030-property-behavior-decls.md)
* [SE-0050: Decoupling Floating Point Strides from Generic Implementations](proposals/0050-floating-point-stride.md)
* [SE-0095: Replace `protocol<P1,P2>` syntax with `Any<P1,P2>`](proposals/0095-any-as-existential.md)


### Deferred for Future Discussion

* [SE-0026: Abstract classes and methods](proposals/0026-abstract-classes-and-methods.md)
* [SE-0058: Allow Swift types to provide custom Objective-C representations](proposals/0058-objectivecbridgeable.md)
* [SE-0078: Implement a rotate algorithm, equivalent to std::rotate() in C++](proposals/0078-rotate-algorithm.md)
* [SE-0083: Remove bridging conversion behavior from dynamic casts](proposals/0083-remove-bridging-from-dynamic-casts.md)
* [SE-0090: Remove `.self` and freely allow type references in expressions](proposals/0090-remove-dot-self.md)


