# Feature name

* Proposal: [SE-NNNN](NNNN-windows.md)
* Authors: [russhy](https://github.com/russhy)
* Review Manager: TBD
* Status: **Awaiting implementation**

*During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN)
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

Adding Windows means the language will be crossplatform, people will be able to write games/app for phone, but also on desktop without having to rewrite in a different language

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/)

## Motivation

I have game on iOS but i want to port on PC to release on steam

But right now the solution is to REWRITE! i don't want to do that, and this is why all my new projects are in C#, this is tru crossplatform

## Proposed solution

Support windows, and release prebuilt compiler binaries

## Detailed design

Swift compiler + package manager + c interop (dll)

## Source compatibility
-

## Effect on ABI stability
-

## Effect on API resilience
-

## Alternatives considered

My alternative is to use a different language, C# or Java or something else
