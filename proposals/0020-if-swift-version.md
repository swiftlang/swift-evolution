# Swift Language Version Build Configuration

* Proposal: [SE-0020](0020-if-swift-version.md)
* Author: [David Farler](https://github.com/bitjammer)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 2.2)**
* Implementation: [apple/swift@c32fb8e](https://github.com/apple/swift/commit/c32fb8e7b9a67907e8b6580a46717c6a345ec7c6)

## Introduction

This proposal aims to add a new build configuration option to Swift
2.2: `#if swift`.

Swift-evolution threads:
- [Swift 2.2: #if swift language version](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/003385.html)
- [Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006398.html)

## Motivation

Over time, Swift syntax may change but library and package authors will
want their code to work with multiple versions of the language. Up until
now, the only recourse developers have is to maintain separate release
branches that follow the language. This gives developers another tool to
track syntax changes without having to maintain separate source trees.

We also want to ease the transition between language revisions for
package authors that distribute their source code, so clients can build
their package with older or newer Swift.

## Proposed solution

The solution is best illustrated with a simple example:

```swift
#if swift(>=2.2)
  print("Active!")
#else
  this! code! will! not! parse! or! produce! diagnostics!
#endif
```

## Detailed design

This will use existing version mechanics already present in the
compiler. The version of the language is baked into the compiler when
it's built, so we know how to determine whether a block of code is
active. If the version is at least as recent as specified in the
condition, the active branch is parsed and compiled into your code.

Like other build configurations, `#if swift` isn't line-based - it
encloses whole statements or declarations. However, unlike the others,
the compiler won't parse inactive branches guarded by `#if swift` or
emit lex diagnostics, so syntactic differences for other Swift versions
can be in the same file.

For now, we'll only expect up to two version components, since it will
be unlikely that a syntax change will make it in a +0.0.1 revision.

The argument to the configuration function is a unary prefix expression,
with one expected operator, `>=`, for simplicity. If the need arises,
this can be expanded to include other comparison operators.

## Impact on existing code

This mechanism is opt-in, so existing code won't be affected by this
change.

## Alternatives considered

We considered two other formats for the version argument:
- String literals (`#if swift("2.2")`): this allows us to embed an
  arbitrary number of version components, but syntax changes are
  unlikely in micro-revisions. If we need another version component, the
  parser change won't be severe.
- Just plain `#if swift(2.2)`: Although `>=` is a sensible default, it
  isn't clear what the comparison is here, and might be assumed to be
  `==`.
- Argument lists (`#if swift(2, 2)`: This parses flexibly but can
  indicate that the second `2` might be an argument with a different
  meaning, instead of a component of the whole version.

