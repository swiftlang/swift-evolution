# Allow Single Dollar Sign as a Valid Identifier

* Proposal: [SE-0144](0144-allow-single-dollar-sign-as-valid-identifier.md)
* Author: [Ankur Patel](https://github.com/ankurp)
* Review manager: [Chris Lattner](http://github.com/lattner)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-October/000292.html)

## Introduction

The mainline Swift compiler emits an error message when the `$` character
(U+0024) is used as an identifier by itself, which is a source breaking
change from Swift 3.0.  For example:

```swift
let $ = 10
// OR
let $ : (Int) -> (Int) = { $0 * $0 }
// OR
class $ {}
```

This proposal suggests reverting this change, enabling the use of `$` as a
valid identifier in future versions of Swift (>= 3.1).

## Motivation

Some projects depend on the 
[Dollar library](https://github.com/ankurp/Dollar), which uses `$`
as a namespace.
The core team has decided to remove it as a valid character by merging this
[Pull Request](https://github.com/apple/swift/pull/3901)

The reason behind the removal of `$` character as a valid identifier is:

1. it was never intended to be an identifier, and was never documented (e.g. by [TSPL](https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/LexicalStructure.html#//apple_ref/swift/grammar/identifier)).
2. the $ sigil is more operator/punctuation-like than identifier-like.
3. the $ namespace is already used for anonymous closure arguments (when 
   followed by a number) and by debugger/REPL temporaries (when followed by
   a letter).  Misuses of these cases were already properly rejected by the
   compiler, it is just the bare `$` identifier that was accepted:

```swift
ERROR at line 1, col 5: expected numeric value following '$'
var $a = 5
```


## Proposed solution

Allow `$` character (U+0024) to be used as a valid identifier without use of
any tick marks `` `$` ``.

## Impact on existing code

If this proposal is accepted, it will preserve the Swift 3.0 syntax which allows
`$` to be used as a valid identifier by itself, so there will be no impact on 
existing code (the TSPL will be updated to reflect this expansion of the grammar
though).

If this proposal is rejected, then the `$` identifier will be rejected in the 
Swift 4 compiler with a migration hint that changes uses to `` `$` ``.  Users
of the [Dollar](https://github.com/ankurp/Dollar) library will be affected.

## Alternatives considered

The primarily alternative here is to allow for the breaking change and use 
`` `$` `` as the identifier in the [Dollar](https://github.com/ankurp/Dollar)
library, or for Dollar to adapt to another namespace.
