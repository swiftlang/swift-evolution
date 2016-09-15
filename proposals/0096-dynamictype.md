# Converting `dynamicType` from a property to an operator

* Proposal: [SE-0096](0096-dynamictype.md)
* Author: [Erica Sadun](https://github.com/erica)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-June/000180.html)
* Bug: [SR-2218](https://bugs.swift.org/browse/SR-2218)

## Introduction

This proposal establishes `dynamicType` as a named operator rather than a property.

Swift-evolution thread:
[RFC: didset and willset](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160516/017959.html)

## Motivation

In Swift, `dynamicType` is a property. Because of that, it shows up as an "appropriate" 
code completion for all values regardless of whether it makes sense to do so 
or not. For example, Swift offers `4.dynamicType` and `myFunction().dynamicType`, etc. 

Unlike most properties, it does not express a logical attribute of a specific type.
Instead, it can be applied to any expression. Since `dynamicType` behaves more like a 
operator (like `sizeof`), its user-facing calling syntax should follow suit.  

## Detailed Design

Upon adoption of this proposal, Swift resyntaxes `dynamicType` as an operator instead of a member.
This proposal puts forth `dynamicType`:

```
dynamicType(value) // returns the dynamicType of value
```

Once the Swift language has sufficient capabilities, the goal is to migrate this operation to the standard library.
At this time, this operation cannot be written as a stdlib feature and it will be implemented as a compiler feature.

## Impact on Existing Code

Adopting this proposal will break code and require migration support. The postfix property syntax must change to an operator call. 

## Alternatives Considered

The core team may also consider `typeof(x)` instead of `dynamicType(x)` as the call is syntactically closer to `sizeof(x)`. 
Note that this may introduce confusion. Unlike Swift, identically-named C++ and C# terms return static types. 
Javascript also includes `typeof(x)` but Javascript does not support static types.

## Acknowledgements

Thank you, Nate Cook
