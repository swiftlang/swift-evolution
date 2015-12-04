# Remove the `++` and `--` operators

* Proposal: [SE-0004](https://github.com/apple/swift-evolution/blob/master/proposals/0004-remove-pre-post-inc-decrement.md)
* Author: [Chris Lattner](https://github.com/lattner)
* Status: **Accepted**

## Introduction

The increment/decrement operators in Swift were added very early in the
development of Swift, as a carry-over from C.  These were added without much
consideration, and haven't been thought about much since then.  This document
provides a fresh look at them, and ultimately recommends we just remove them
entirely, since they are confusing and not carrying their weight.

As a quick refresher, there are four operators in this family:

```swift
let a = ++x  // pre-increment  - returns input value after mutation
let b = x++  // post-increment - returns copy of input value before mutation
let c = --x  // pre-decrement  - returns input value after mutation
let d = x--  // post-decrement - returns copy of input value before mutation
```

However, the result value of these operators are frequently ignored.


## Advantages of These Operators

The primary advantage of these operators is their expressive capability.  They
are shorthand for (e.g.) `x += 1` on a numeric type, or `x.advance()` on an
iterator-like value.  When the return value is needed, the Swift `+=` operator
cannot be used in-line, since (unlike C) it returns `Void`.

The second advantage of Swift supporting this family of operators is continuity
with C, and other common languages in the extended C family (C++, Objective-C, 
Java, C#, Javascript, etc).  People coming to Swift from these other languages
may reasonably expect these operators to exist.  That said, there are also
popular languages which have kept the majority of C operators but dropped these
(e.g. Python).


## Disadvantages of These Operators

1. These operators increase the burden to learn Swift as a first programming
language - or any other case where you don't already know these operators from a
different language.

2. Their expressive advantage is minimal - `x++` is not much shorter
than `x += 1`.

3. Swift already deviates from C in that the `=`, `+=` and other assignment-like
operations returns `Void` (for a number of reasons).  These operators are
inconsistent with that model.

4. Swift has powerful features that eliminate many of the common reasons you'd
use `++i` in a C-style for loop in other languages, so these are relatively
infrequently used in well-written Swift code.  These features include
the `for-in` loop, ranges, `enumerate`, `map`, etc.

5. Code that actually uses the result value of these operators is often
confusing and subtle to a reader/maintainer of code.  They encourage "overly
tricky" code which may be cute, but difficult to understand.

6. While Swift has well defined order of evaluation, any code that depended on
it (like `foo(++a, a++)`) would be undesirable even if it was well-defined.

7. These operators are applicable to relatively few types: integer and floating
point scalars, and iterator-like concepts. They do not apply to complex numbers,
matrices, etc.  

8. Having to support these could add complexity to the potential 
revised numerics model.

Finally, these fail the metric of "if we didn't already have these, would we add
them to Swift 3?"


## Proposed Approach

We should just drop these operators entirely.  In terms of roll-out, we should
deprecate them in the Spring Swift 2.x release (with a nice Fixit hint to cover
common cases), and remove them completely in Swift 3.


## Alternatives considered

Simplest alternative: we could keep them. More interesting to consider, we could
change these operators to return Void.  This solves some of the problems above,
but introduces a new question: once the result is gone, the difference between
the prefix and postfix form also vanishes.  Given that, we would have to pick 
between these unfortunate choices:

1) Keep both `x++` and `++x` in the language, even though they do the same
thing.

2) Drop one of `x++` or `++x`.  C++ programmers generally prefer the prefix
forms, but everyone else generally prefers the postfix forms.  Dropping either
one would be a significant deviation from C.

Despite considering these options carefully, they still don't justify the
complexity that the operators add to Swift.

