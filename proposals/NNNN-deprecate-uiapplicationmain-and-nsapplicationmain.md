# Deprecate @UIApplicationMain and @NSApplicationMain

* Proposal: [SE-NNNN](NNNN-deprecate-uiapplicationmain-and-nsapplicationmain.md)
* Authors: [Robert Widmann](https://github.com/codafi)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Awaiting review**
* Implementation: [PR 62151](https://github.com/apple/swift/pull/62151)
* Review: ([pitch](https://forums.swift.org/t/deprecate-uiapplicationmain-and-nsapplicationmain/61493))

## Introduction

`@UIApplicationMain` and `@NSApplicationMain` used to be the standard way for iOS and macOS apps respectively to declare a synthesized platform-specific entrypoint for an app. These functions have since been obsoleted by [SE-0281](https://github.com/apple/swift-evolution/blob/main/proposals/0281-main-attribute.md) and the `@main` attribute, and now represent a confusing bit of duplication in the language. This proposal seeks to deprecate these alternative entrypoint attributes in favor of `@main` in Swift 5.8, and makes their use in Swift 6 a hard error.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/deprecate-uiapplicationmain-and-nsapplicationmain/)

## Motivation

UIKit and AppKit have fully embraced the `@main` attribute and have made application adoption as simple as conforming to the `UIApplicationDelegate` and `NSApplicationDelegate` protocols. This now means that an author of an application is presented with two different, but ultimately needless, choices for an entrypoint:

* Use hard coded framework-specific attributes
* Use the language’s general-purpose syntax for declaring an entrypoint

The right choice is clearly the latter. Moreover, having two functionally identical ways to express the concept of an app-specific entrypoint is clutter at best and confusing at worst. This proposal seeks to complete the migration work implied by [SE-0281](https://github.com/apple/swift-evolution/blob/main/proposals/0281-main-attribute.md) by having the compiler push Swift authors towards the more general, unified solution.

## Proposed solution

The use of both `@UIApplicationMain` and `@NSApplicationMain` under Swift 5 language modes will unconditionally warn and offer to replace these attributes with the appropriate conformances. In Swift 6 language modes, usage of these attributes will result in a hard error.

## Detailed design

>Because `@UIApplicationMain` and `@NSApplicationMain` have remarkably similar usages in abstract, this portion of the document will only use examples of `@UIApplicationMain` and assume that the case for `@NSApplicationMain` follows similarly.


Issue a diagnostic asking the user to remove `@UIApplicationMain`. The existing conformance to `UIApplicationDelegate` will kick in when the code is next built and the general-purpose entrypoint will be added instead.

```
@UIApplicationMain // warning: '@UIApplicationMain' is deprecated in Swift 5
                   // fixit: Change `@UIApplicationMain` to `@main`
final class MyApplication: UIResponder, UIApplicationDelegate {
  /**/
}
```

We can get away with this simple remedy because 
- A Swift module can have at most one of: @UIApplicationMain, @main, and @NSApplicationMain
- A class annotated with @UIApplicationMain or @NSApplicationMain must conform directly to the corresponding delegate protocol anyways. They therefore inherit the `main` entrypoint [provided by these protocols](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/3656306-main), they just aren't using it!

## Source compatibility

This proposal is intentionally source-breaking, but that breakage is relegated to a new language mode and the diagnostics involved provide a clear and simple migration path for existing usages of these entrypoint attributes.

## Effect on ABI stability

This proposal has no impact on ABI.

## Effect on API resilience

None.

## Alternatives considered

We could choose not to do this.
