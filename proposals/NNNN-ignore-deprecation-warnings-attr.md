# Adding an attribute to ignore deprecation warnings in a declaration or import statement - `@ignoreDeprecationWarnings`

* Proposal: SE-NNNN
* Authors: [Serena A.](https://github.com/SerenaKit)
* Review Manager: TBD
* Status: **Implementation complete, awaiting review**
* Implementation: [apple/swift#59232](https://github.com/apple/swift/pull/59232)
* [Additional Commentary](https://forums.swift.org/t/pitch-attribute-to-silence-deprecation-warnings-for-a-specified-scope/57791)

## Introduction

This proposal introduces an attribute, `@ignoreDeprecationWarnings`, that silences deprecation warnings in the scope it's applied on, or, when applied to a import statement, on all symbols sourced from the module being imported.

Swift-evolution thread: [[Pitch] Attribute to silence Deprecation Warnings for a specified scope](https://forums.swift.org/t/pitch-attribute-to-silence-deprecation-warnings-for-a-specified-scope/57791)

## Motivation

Swift's warnings help the user write better, more maintainable code over the long term by promoting better coding practices. Most target a specific antipattern or suspicious construct with a low false positive rate. When code is mistakenly flagged, there are usually fairly straightforward workarounds available to confirm programmer intent and silence the warning.

Deprecation warnings are different. They come from the code that people write rather than from the language itself. They're a way for an author of a particular piece of code (henceforth referred to as a "vendor" for a "library", although these terms are being used very broadly) to notify a downstream user ("client") that they wish to discourage use of a particular API. In the ideal case, an alternative is available that clients should adopt instead. Reality, however, is generally not this simple.

Vendors mark symbols as deprecated for a multitude of reasons. Most are good, but some can cause issues for clients. Here are some, although this list is in no way exhaustive:

* Sometimes symbols are deprecated without a replacement. Whether the reasons are straightforward ("we do not wish to support this functionality in our library anymore"), well-intentioned ("we don't really want people using this API, but it's the de-facto way to do it and we failed to consider that Swift does not have a way to use it without a warning"), or straight-up whimsical ("oops, we marked that as deprecated by mistake").

* Replacement APIs are not feasible to adopt. They may be buggy or not yet production-ready, or perhaps be missing some functionality that the old library provided. Or there may be incompatible for other, project-specific reasons.

* Migrations take time! Vendors have to design new libraries, and then clients have to rewrite their code to adopt them. Deprecation warnings don't really have a way to account for "we will are planning to fix this".

In all of these cases, clients are better off using APIs that are marked as deprecated but are punished for doing so with warnings they cannot resolve. Larger, older projects are generally more likely to hit this issue, and to work around it they may choose to silence *all* warnings in their project or rewrite the code in another language that allows for more granular control over how warnings are emitted. These are both undesirable, because they throw the baby out with the bathwater: there's a lot of *good* warnings that are lost in the process.

## Proposed solution

The proposed solution to the issues mentioned above is to introduce an attribute, `@ignoreDeprecationWarnings`, that can be applied on the scope in which the deprecated symbols are intended to be used. Consider the following API:

```swift
@available(*, deprecated)
func unfortunatelyDeprecated()
```

Attempting to use it will trigger a warning:

```swift
func foo() {
	// Code…
	// We need to use this old API because newHotness() is broken.
	unfortunatelyDeprecated() // warning: 'unfortunatelyDeprecated()' is deprecated
	// More code…
}
```

```swift
@ignoreDeprecationWarnings
func foo() {
	// Code…
	// We need to use this old API because newHotness() is broken.
	unfortunatelyDeprecated() // No warnings here
	// More code…
}
```

Sometimes it may be appropriate to ignore deprecation warnings for an entire module. If `LegacyLibrary` contains an `OldButGold` type that is marked as deprecated, the following code will allow a client to use it without warnings:

```swift
// There's no replacement for this API yet.
@ignoreDeprecationWarnings
import LegacyLibrary.OldButGold

struct Bar {
	var oldButGold: OldButGold // No warnings here
}
```

## Detailed design

The attribute can be applied to:

- All declarations which `@available` can be applied to.
- Import statements.

When applied on a declaration, there will be no deprecation warnings diagnosed in the scope of the declaration. When applied on an import statement, no deprecation warnings will be diagnosed for the symbols imported from the module imported with the attribute.

## Source compatibility

This is an additive change and will not break source compatibility.

## Effect on ABI stability

This is an additive change which will not affect ABI stability.

## Effect on API resilience

This is an additive change which will have no effect on API resilience.

## Alternatives considered

Barring solutions that are outside the scope of the Swift language (e.g. "ask the vendor to change their library"), there are not many alternatives available to consider. Disabling all warnings or moving code into another language are heavy-handed "solutions" with significant downsides. Swift allows use of deprecated symbols from a context that itself is marked as deprecated, but this just makes handling the inevitable warning someone else's problem instead of solving the issue.

It may be that a proposal to consider more granular control over how warnings are diagnosed is considered in the future, covering not just deprecation warnings but those coming from the language itself. While this presents an interesting direction to go in, this proposal specifically chooses to keep its scope limited to just deprecation warnings with the aim of resolving a top source of frustration from developers dealing with Swift's handing of warnings. Most of the diagnostics in the language have high value, a low false positive rate, and simple workarounds to ensure valid code remains warning-free, making a proposal for finer-grained control over them a challenging proposition to entertain.

One alternative syntax considered for this proposal was using compilation directives instead of attributes, as in

```swift
func foo() {
	// Code…
#disableDeprecationWarnings
	// We need to use this old API because newHotness() is broken.
	unfortunatelyDeprecated() // warning: 'unfortunatelyDeprecated()' is deprecated
#enableDeprecationWarnings
	// More code…
}
```

This would mirror constructs in other languages such as C. The current implementation was chosen for simplicity (no need to maintain a mental stack of conditions, or forget to include the terminating directive at the end of the section) and because it loosely matched the `@available` attribute, which it is related to.

## Acknowledgments

I'd like to thank [Hamish Knight](https://github.com/hamishknight) for their extensive help with pointing out and fixing the issues of the [implementation](https://github.com/apple/swift/pull/59232).
