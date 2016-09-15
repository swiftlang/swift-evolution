# Add a `macOS` Alias for the `OSX` Platform Configuration Test

* Proposal: [SE-0106](0106-rename-osx-to-macos.md)
* Author: [Erica Sadun](http://github.com/erica)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-June/000193.html)
* Bugs: [SR-1823](https://bugs.swift.org/browse/SR-1823),
        [SR-1887](https://bugs.swift.org/browse/SR-1887)

## Introduction

Starting in Sierra, Apple's Mac-based OS (OS X) will be renamed "macOS". All user-facing Swift APIs must go through Swift Evolution. While this is a trivial API change, I have put together a formal proposal as is normal and usual for this process. 

This proposal adds the `#if os(macOS)` platform configuration test to alias the current `#if os(OSX)`

Swift Evolution Discussion: [\[DRAFT\] Aliasing the OS X Platform Configuration	Test](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160613/021239.html)

## Motivation

At WWDC 2016, Apple renamed its Mac operating system from OSX to macOS. Adding rather than replacing "OSX" enables API adoption to be purely additive and supports the notion that Swift-based applications can and may be deployed to operating systems earlier than Sierra.

Choosing to use both names originates from the following rationale:

* The configuration test should not remain as #if os(OSX). That's the wrong name for Sierra's now-supported operating system. 
* Developers can and will still deploy to OS X for Yosemite and El Capitan using Swift.
* Forcing developers to migrate OSX to macOS places an undue burden on existing code.
* While aliasing the two may cause issues down the road ("Why does this test have two names?"), I believe Swift developers can easily reason why both variations exist.

## Current Art
Swift currently supports the following platform configuration tests, defined in lib/Basic/LangOptions.cpp.

* The literals `true` and `false`
* The `os()` function that tests for `OSX, iOS, watchOS, tvOS, Linux, Windows, Android, and FreeBSD`
* The `arch()` function that tests for `x86_64, arm, arm64, i386, powerpc64, s390x, and powerpc64le`
* The `swift()` function that tests for specific Swift language releases, e.g. `swift(>=2.2)`


## Detailed Design

```c++
  static const StringRef SupportedConditionalCompilationOSs[] = {
  "OSX",
  "macOS",
  "tvOS",
  "watchOS",
  "iOS",
  "Linux",
  "FreeBSD",
  "Windows",
  "Android"
  };

  if (Target.isMacOSX()) {
    addPlatformConditionValue("os", "OSX");
    addPlatformConditionValue("os", "macOS");
  }
```

Use:

```swift
#if os(macOS) 
    // Code specific to macOS or OS X
#endif
```

## Impact on Existing Code

This proposal is purely additive. It will not affect existing code other than adding another way to refer to OS X/macOS. 

## Alternatives Considered

Instead of retaining and aliasing `os(OSX)`, it can be fully replaced by `os(macOS)`. This mirrors the situation with the phoneOS to iOS rename and would require a migration assistant to fixit old-style use. 

Charlie Monroe points out: "Since Swift 3.0 is a code-breaking change my guess is that there is no burden if the Xcode migration assistent automatically changes all `#if os(OSX)` to `#if os(macOS)`, thus deprecating the term OSX, not burdening the developer at all. If iOS was renamed to phoneOS and kept versioning, you'd still expect `#if os(iOS)` to be matched when targeting phoneOS and vice-versa."

## Unaddressed Issues

This proposal is narrowly focused on conditional compilation blocks. Both `@available` and `#available` are also affected by the macOS rename. Current [platform names](https://github.com/apple/swift/blob/master/include/swift/AST/PlatformKinds.def) include both `OSX` and `OSXApplicationExtension`. The obvious alternatives for these are `macOS` and `macOSApplicationExtension`. A separate bug report [SR-1887](https://bugs.swift.org/browse/SR-1887) has been filed for this.
