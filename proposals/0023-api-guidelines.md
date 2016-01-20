# API Design Guidelines

* Proposal: [SE-0023](https://github.com/apple/swift-evolution/blob/master/proposals/0023-api-guidelines.md)
* Author(s): Dave Abrahams, Doug Gregor, Dmitri Hrybenko, Ted Kremenek, Chris Lattner, Alex Migicovsky, Max Moiseev, Ali Ozer, Tony Parker
* Status: **Awaiting review** (January 21...31, 2016)

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
[https://swift.org/documentation/api-design-guidelines.html](https://swift.org/documentation/api-design-guidelines.html).

## Impact on existing code

The existence of API Design Guidelines has no specific impact on
existing code. However, two companion proposals that apply these
guidelines to the [Standard
Library](0006-apply-api-guidelines-to-the-standard-library.md) and via
the [Clang importer](0005-objective-c-name-translation.md) will have a
massive impact on existing code, changing a significant number of
APIs.
