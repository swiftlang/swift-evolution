# API Design Guidelines

* Proposal: [SE-0023](https://github.com/apple/swift-evolution/blob/master/proposals/0023-api-guidelines.md)
* Author(s): Dave Abrahams, Doug Gregor, Dmitri Hrybenko, Ted Kremenek, Chris Lattner, Alex Migicovsky, Max Moiseev, Ali Ozer, Tony Parker
* Status: **Accepted** ([Rationale](http://thread.gmane.org/gmane.comp.lang.swift.evolution/8585))
* Review manager: [Doug Gregor](https://github.com/DougGregor)

## Reviewer notes

This review is part of a group of three related reviews, running
concurrently:

* [SE-0023 API Design Guidelines](https://github.com/apple/swift-evolution/blob/master/proposals/0023-api-guidelines.md)
* [SE-0006 Apply API Guidelines to the Standard Library](https://github.com/apple/swift-evolution/blob/master/proposals/0006-apply-api-guidelines-to-the-standard-library.md)
* [SE-0005 Better Translation of Objective-C APIs Into Swift](https://github.com/apple/swift-evolution/blob/master/proposals/0005-objective-c-name-translation.md)

These reviews are running concurrently because they interact strongly
(e.g., an API change in the standard library will correspond to a
particular guideline, or an importer rule implements a particular
guideline, etc.). Because of these interactions, and to keep
discussion manageable, we ask that you:

* **Please get a basic understanding of all three documents** before
  posting review commentary
* **Please post your review of each individual document in response to
  its review announcement**. It's okay (and encouraged) to make
  cross-references between the documents in your review where it helps
  you make a point.

## Introduction

The design of commonly-used libraries has a large impact on the
overall feel of a programming language. Great libraries feel like an
extension of the language itself, and consistency across libraries
elevates the overall development experience. To aid in the
construction of great Swift libraries, one of the major goals for
Swift 3 is to define a set of API design guidelines and to apply those
design guidelines consistently.

## Proposed solution

The proposed API Design Guidelines are available at
[https://swift.org/documentation/api-design-guidelines/](https://swift.org/documentation/api-design-guidelines/).

## Impact on existing code

The existence of API Design Guidelines has no specific impact on
existing code. However, two companion proposals that apply these
guidelines to the [Standard
Library](0006-apply-api-guidelines-to-the-standard-library.md) and via
the [Clang importer](0005-objective-c-name-translation.md) will have a
massive impact on existing code, changing a significant number of
APIs.
