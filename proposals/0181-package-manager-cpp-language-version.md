# Package Manager C/C++ Language Standard Support

* Proposal: [SE-0181](0181-package-manager-cpp-language-version.md)
* Authors: [Ankit Aggarwal](https://github.com/aciidb0mb3r)
* Review Manager: [Daniel Dunbar](https://github.com/ddunbar)
* Status: **Implemented (Swift 4)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170717/038142.html)
* Implementation: [apple/swift-package-manager#1264](https://github.com/apple/swift-package-manager/pull/1264)

## Introduction

This proposal adds support for declaring the language standard for C and C++
targets in a SwiftPM package.

## Motivation

The C++ language standard is one of the most important build setting needed to
compile C++ targets. We want to add some mechanism to declare it until we get
the complete build settings feature, which is deferred from the Swift 4 release.

## Proposed solution

We will add support to the package manifest declaration to specify the C and C++
language standards:

```swift
let package = Package(
    name: "CHTTP",
    ...
    cLanguageStandard: .c89,
    cxxLanguageStandard: .cxx11
)
```

These settings will apply to all the C and C++ targets in the package. The
default value of these properties will be `nil`, i.e., a language standard flag
will not be passed when invoking the C/C++ compiler.

_Once we get the build settings feature, we will deprecate these properties._

## Detailed design

The C/C++ language standard will be defined by the enums below and
updated as per the Clang compiler [repository](https://github.com/llvm-mirror/clang/blob/master/include/clang/Frontend/LangStandards.def).

```swift
public enum CLanguageStandard {
    case c89
    case c90
    case iso9899_1990
    case iso9899_199409
    case gnu89
    case gnu90
    case c99
    case iso9899_1999
    case gnu99
    case c11
    case iso9899_2011
    case gnu11
}

public enum CXXLanguageStandard {
    case cxx98
    case cxx03
    case gnucxx98
    case gnucxx03
    case cxx11
    case gnucxx11
    case cxx14
    case gnucxx14
    case cxx1z
    case gnucxx1z
}
```
## Impact on existing code

There will be no impact on existing packages because this is a new API and the
default behaviour remains unchanged.

## Alternatives considered

We considered adding this property at target level but we think that will
pollute the target namespace. Moreover, this is a temporary measure until we get
the build settings feature.
