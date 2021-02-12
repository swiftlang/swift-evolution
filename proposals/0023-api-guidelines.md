# API Design Guidelines

* Proposal: [SE-0023](0023-api-guidelines.md)
* Authors: [Dave Abrahams](https://github.com/dabrahams), [Doug Gregor](https://github.com/DougGregor), [Dmitri Gribenko](https://github.com/gribozavr), [Ted Kremenek](https://github.com/tkremenek), [Chris Lattner](http://github.com/lattner), Alex Migicovsky, [Max Moiseev](https://github.com/moiseev), Ali Ozer, [Tony Parker](https://github.com/parkera)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://forums.swift.org/t/accepted-with-modifications-se-0023-api-design-guidelines/1666)

## Reviewer notes

This review is part of a group of three related reviews, running
concurrently:

* [SE-0023 API Design Guidelines](0023-api-guidelines.md)
  ([Review](https://forums.swift.org/t/review-se-0023-api-design-guidelines/1162))
* [SE-0006 Apply API Guidelines to the Standard Library](0006-apply-api-guidelines-to-the-standard-library.md)
  ([Review](https://forums.swift.org/t/review-se-0006-apply-api-guidelines-to-the-standard-library/1163))
* [SE-0005 Better Translation of Objective-C APIs Into Swift](0005-objective-c-name-translation.md)
  ([Review](https://forums.swift.org/t/review-se-0005-better-translation-of-objective-c-apis-into-swift/1164))

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

The sources for these guidelines are available at
https://github.com/apple/swift-internals.  Pull requests for trivial
copyediting changes are most welcome.  More substantive changes should
be handled as part of the review process.

## Impact on existing code

The existence of API Design Guidelines has no specific impact on
existing code. However, two companion proposals that apply these
guidelines to the [Standard
Library](0006-apply-api-guidelines-to-the-standard-library.md) and via
the [Clang importer](0005-objective-c-name-translation.md) will have a
massive impact on existing code, changing a significant number of
APIs.
