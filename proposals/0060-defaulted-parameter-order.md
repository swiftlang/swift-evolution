# Enforcing order of defaulted parameters

* Proposal: [SE-0060](0060-defaulted-parameter-order.md)
* Author: [Joe Groff](https://github.com/jckarter)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000146.html)
* Bug: [SR-1489](https://bugs.swift.org/browse/SR-1489)

## Introduction

Swift generally follows in the Smalltalk/Objective-C tradition of compound
method names with significant, order-sensitive argument labels, but an
exception is made for parameters with default arguments. We should remove
this exception.

Swift-evolution thread: [Enforce argument order for defaulted parameters](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160328/013789.html)

## Motivation

The ability to reorder arguments with defaulted parameters is a vestige
of prerelease builds of Swift that had a more Python-like keyword
argument model, allowing arbitrary argument reordering in call sites.
Our trend since those early days has been shaped by the Cocoa
frameworks, which put a lot of thought into argument
labels and ordering as part of API design, to be stricter about argument
keywords. This encourages readability as well as predictability, ensuring
that the same API call looks similar in different users' code. We held onto
reordering of default arguments as a potentially useful convenience, but few
users know this is possible, and many have expressed surprise or disgust 
that it's possible. In modern Swift, it's arguably a corner case that
complicates the language for little benefit.

## Proposed solution

I propose that we require the order of arguments used at a call site to
always match a function's declared parameter order, regardless of whether
they have default arguments. This makes the language simpler and more
consistent.

## Detailed design

A call site must always supply the arguments it provides to a function in their
declared order:

```swift
func requiredArguments(a: Int, b: Int, c: Int) {}
func defaultArguments(a: Int = 0, b: Int = 0, c: Int = 0) {}

requiredArguments(a: 0, b: 1, c: 2)
requiredArguments(b: 0, a: 1, c: 2) // error
defaultArguments(a: 0, b: 1, c: 2)
defaultArguments(b: 0, a: 1, c: 2) // error
```

Arbitrary labeled parameters with default arguments may still be elided, as
long as the specified arguments follow declaration order:

```swift
defaultArguments(a: 0) // ok
defaultArguments(b: 1) // ok
defaultArguments(c: 2) // ok
defaultArguments(a: 1, c: 2) // ok
defaultArguments(b: 1, c: 2) // ok
defaultArguments(c: 1, b: 2) // error
```

## Impact on existing code

Code that takes advantage of reordering will need to be migrated to reorder
the arguments. This should be easy to automate.

## Alternatives considered

[Matthew Johnson](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160328/013802.html)
raises an interesting point in favor of our current behavior. For memberwise
initializers, it makes sense to allow reordering, because declared member order
is not usually significant otherwise:

> One place where I believe argument re-ordering is useful is with memberwise arguments when you are initializing an instance.  Order usually plays no significant role with these arguments which are in some sense similar to assignment statements (which are inherently re-orderable).  

> In fact, I have found myself wishing non-defaulted memberwise initializer parameters were re-orderable at times, especially when using the implicit memberwise initializer for a struct.  Source order for property declarations does not always match what makes the most sense at the initialization site (something that was pointed out numerous times during the review of my memberwise init proposal).

[Erica Sadun](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160328/013791.html)
notes that defaulted arguments are useful to simulate an ad-hoc sum type
parameter:

> While I do take advantage of this feature, it would be less than honest to point out that a large portion of such
> usage is to point out how cool the ability is.
> 
> That said, what I'm really doing is treating them in code like an ad hoc set of enumerated cases with associated
> values. Perhaps rethinking about them in that light would be better than simply removing them from the
> language?
