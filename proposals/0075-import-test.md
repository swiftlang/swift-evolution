# Adding a Build Configuration Import Test

* Proposal: [SE-0075](0075-import-test.md)
* Author: [Erica Sadun](http://github.com/erica)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 4.1)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000159.html)
* Bug: [SR-1560](https://bugs.swift.org/browse/SR-1560)

## Introduction

Expanding the build configuration suite to test for the ability to import certain 
modules was [first introduced](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160215/010693.html)
on the Swift-Evolution list by Kevin Ballard. Although his initial idea (checking for Darwin
to differentiate Apple targets from non-Apple targets) proved problematic, developers warmly
greeted the notion of an import-based configuration test. 
Dmitri Gribenko wrote, "There's a direction that we want to move to a unified name for the libc module for all platform, so 'can import Darwin' might not be a viable long-term strategy." 
Testing for imports offers advantages that stand apart from this one use-case: to test for API availability before use.

[Swift Evolution Review Thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160509/017044.html)
 
## Motivation

Swift's existing set of build configurations specify platform differences, not module commonalities. For example, UIKit enables you to write view code supported on both iOS and tvOS. SpriteKit allows common code to render on OS X, iOS, and tvOS that would require an alternate UI on Linux. Testing for Metal support or Media Player would guard code that will not function on the simulator. If the simulator adopted these modules at some future time, the code would naturally expand to provide compatible execution without source modification.

```swift
#if canImport(UIKit)
   // UIKit-based code
   #elseif canImport(Cocoa)
   // OSX code
   #elseif
   // Workaround/text, whatever
#endif
```

Guarding code with operating system tests can be less future-proofed than testing for module support.  Excluding OS X to use UIColor creates code that might eventually find its way to a Linux plaform. Targeting Apple platforms by inverting a test for Linux essentially broke after the introduction of `Windows` and `FreeBSD` build configurations:

```swift
// Exclusive os tests are brittle
#if !os(Linux)
   // Matches OSX, iOS, watchOS, tvOS, Windows, FreeBSD
#endif
```

Inclusive OS tests (if os1 || os2 || os3...) must be audited each time the set of possible platforms expands. 
In addition, compound build statements are harder to write, to validate, and are more confusing to read. 
They are more prone to errors than a single test that's tied to the API capabilities used by the code it guards.

Evan Maloney writes, "Being able to test for the importability of a given module/framework at runtime 
would be extremely helpful. We use several frameworks that are only available in a subset of the platforms 
we support, and on only certain OS versions. To work around this problem now, we dynamically load frameworks 
from Obj-C only when we're running on an OS version we know is supported by the framework(s) in question.
We can't dynamically load them from Swift because if they're included in an import, the runtime tries to 
load it right away, leading to a crash on any unsupported platform. The only way to selectively load dynamic 
frameworks at runtime is to do it via Obj-C. Some sort of check like the ones you propose should let us avoid this."

## Detail Design

`#if canImport(module-name)` tests for module support by name. My proposed name uses lower camelCase, which is not currently used in the current build configuration vocabulary but is (in my opinion) clearer in intention than the other two terms brought up on the evolution list, `#if imports()` and `#if supports()`. 

* This build configuration does not import the module it names. A test whose body performs the import may be separated from other tests whose code use the framework. This is why the call does not import.
* This build configuration is intended to differentiate API access and not to detect platforms.
* The supplied module token is an arbitrary string. It does not belong to an enumerated set of known 
  members as this configuration test is intended for use with both first and third party modules 
  for the greatest flexibility. At compile time, Swift determines whether the module can or cannot be 
  linked and builds accordingly.

```swift
#if canImport(module)
    import module
    // use module APIs safely
#endif

#if canImport(module)
    // provide solution with module APIs
    #else
    // provide alternative solution that does not depend on that module
#endif
```
 
## Current Art
Swift currently supports the following configuration tests:

* The literals `true` and `false`
* The `os()` function that tests for `OSX, iOS, watchOS, tvOS, Linux, Windows, and FreeBSD`
* The `arch()` function that tests for `x86_64, arm, arm64, i386, powerpc64, and powerpc64le`
* The `swift()` function that tests for specific Swift language releases, e.g. `swift(>=2.2)`
 
Chris Lattner writes, "[T]his is directly analogous to the Clang extension `__has_include`.  `__has_include` has been useful, and the C++ committee is discussing standardizing the functionality there." Further details about include file checking can be found on the [clang.llvm.org site](http://clang.llvm.org/docs/LanguageExtensions.html#include-file-checking-macros).
 
## Alternatives Considered

There are no alternatives considered.
