# Remove explicit use of `let` from Function Parameters

* Proposal: [SE-0053](0053-remove-let-from-function-parameters.md)
* Author: [Nicholas Maccharoli](https://github.com/nirma)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-March/000082.html)
* Implementation: [apple/swift#1812](https://github.com/apple/swift/pull/1812)

## Introduction

Since function parameters are immutable by default, allowing function parameters to be explicitly labeled 
as `let` is a bit of a syntactic redundancy that would best be removed.
Not allowing function parameters to be explicitly declared as `let` would permit a more simple and uniform function declaration syntax for swift.
Furthermore proposal [SE-0003​: "Removing `var` from Function Parameters"](0003-remove-var-parameters.md) removes `var` from function parameters removing any possible ambiguity as to whether a function parameter is immutable or not.


Swift-evolution thread: [Removing explicit use of `let` from Function Parameters](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160314/012851.html)

## Motivation
Now that proposal [SE-0003​: "Removing `var` from Function Parameters"](0003-remove-var-parameters.md) has been accepted, it would make sense that the syntax for function parameters being explicitly declared as `let` would be removed as well.
Since prepending `let` to an argument label does not modify behavior, leaving it as part of the language would only add redundancy and complexity to Swift's syntax at no added benefit. 
Furthermore [SE-0001](0001-keywords-as-argument-labels.md) allowed the use of all keywords as argument labels except for `inout`, `var` and `let`.  
Proposal [SE-0031](0031-adjusting-inout-declarations.md) made `inout` a type modifier freeing `inout` to be used as an argument label and proposal [SE-0003](0003-remove-var-parameters.md) prohibits declaring function parameters as `var` freeing `var` to be used as an argument label.
The only keyword still in use that is preventing any keyword from being used as an argument label is `let` which if removed from function parameter syntax would permit [SE-0001](0001-keywords-as-argument-labels.md) to allow all keywords as argument labels with no exceptions. 

## Proposed solution

Make functions with parameters declared with an explicit `let` prohibited and a compile time error.

Basically make functions declared like this a compile time error:
```swift
func foo(let x: Int) { ... }
```

In favor of omitting `let` like this:
```swift
func foo(x: Int) { ... }
```

## Impact on existing code

In code that is migrating to this newer proposed syntax the `let` keyword should be deleted if placed before a function parameter or else it will be treated as an external label.
This should not be too disruptive since the common convention is already to not label function parameters as `let`.


## Alternatives considered

Leave the redundant syntax in place, but I personally don't see any merit in that.


