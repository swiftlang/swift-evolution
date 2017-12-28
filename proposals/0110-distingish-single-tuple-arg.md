# Distinguish between single-tuple and multiple-argument function types

* Proposal: [SE-0110](0110-distingish-single-tuple-arg.md)
* Authors: Vladimir S., [Austin Zheng](https://github.com/austinzheng)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Deferred**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000215.html), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution-announce/2017-June/000386.html)
* Bug: [SR-2008](https://bugs.swift.org/browse/SR-2008)

## Introduction

Swift's type system should properly distinguish between functions that take one tuple argument, and functions that take multiple arguments.

Discussion: [pre-proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160620/021793.html)

## Motivation

Right now, the following is possible:

```swift
let fn1 : (Int, Int) -> Void = { x in
	// The type of x is the tuple (Int, Int).
	// ...
}

let fn2 : (Int, Int) -> Void = { x, y in
	// The type of x is Int, the type of y is Int.
	// ...
}
```

A variable of function type where there exist _n_ parameters (where _n_ > 1) can be assigned a value (whether it be a named function, a closure literal, or other acceptable value) which either takes in _n_ parameters, or one tuple containing _n_ elements. This seems to be an artifact of the tuple splat behavior removed in [SE-0029](0029-remove-implicit-tuple-splat.md).

The current behavior violates the principle of least surprise and weakens type safety, and should be changed.

## Proposed solution

We propose that this behavior should be fixed in the following ways:

* A function type declared with _n_ parameters (_n_ > 1) can only be satisfied by a function value which takes in _n_ parameters. In the above example, only the `fn2` expression would be considered valid.

* To declare a function type with one tuple parameter containing _n_ elements (where _n_ > 1), the function type's argument list must be enclosed by double parentheses:

	```swift
	let a : ((Int, Int, Int)) -> Int = { x in return x.0 + x.1 + x.2 }
	```

	We understand that this may be a departure from the current convention that a set of parentheses enclosing a single object are considered semantically meaningless, but it is the most natural way to differentiate between the two situations described above and would be a clearly-delineated one-time-only exception.

## Impact on existing code

Minor changes to user code may be required if this proposal is accepted.

## Alternatives considered

Don't make this change.
