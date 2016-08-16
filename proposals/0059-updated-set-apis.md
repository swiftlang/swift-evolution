# Update API Naming Guidelines and Rewrite Set APIs Accordingly

* Proposal: [SE-0059](0059-updated-set-apis.md)
* Author: [Dave Abrahams](https://github.com/dabrahams)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-April/000105.html)

## Introduction

When
[SE-0006, *Apply API Guidelines to the Standard Library*](0006-apply-api-guidelines-to-the-standard-library.md)
was proposed, the lack of an acceptable naming convention for some
mutating/nonmutating method pairs meant that the APIs of `SetAlgebra`,
`Set<T>` and `OptionSet<T>` were not adjusted accordingly.  This
proposal remedies both problems by:

1. establishing the necessary naming conventions and 

2. applying the corresponding changes to the Set APIs.  A few other
   issues in these APIs are cleaned up along the way (details below).

For reference as you read this proposal, you may be interested in the
following links:

* [Updated API guidelines](http://dabrahams.github.io/swift-internals/api-design-guidelines) (corresponding [diff](https://github.com/apple/swift-internals/pull/8))
* [Updated `SetAlgebra` API](https://github.com/apple/swift/blob/set-api/stdlib/public/core/SetAlgebra.swift) (corresponding [diff](https://github.com/apple/swift/pull/2002))


## Fixing the API Guidelines

The guidelines say that method calls with side-effects should read
as verb phrases, and those without side-effects should read as noun
phrases.  They also describe how to name mutating/nonmutating method
pairs accordingly: starting with the assumption that the fundamental
operation can be described by a verb, we are to use the `ed` or `ing`
suffix to create a noun phrase for the nonmutating operation.

The problem is that in some cases, the operation's only natural
description is as a noun. Consider the **union** of two sets, or the
**remainder** when dividing two integers.  In these cases, we have a
suitable name for the non-mutating operation, and we need to create a
name that reads as a verb phrase for its mutating counterpart. The
proposed solution is to use the `form` prefix, so that

```swift
x.formUnion(y)
```

is equivalent to

```swift
x = x.union(y)
```

## Changes to the Set APIs

This proposal changes APIs of the `SetAlgebra` protocol, which
propagate into the library's models of those protocols, `Set<T>` and
`OptionSet<T>`.  Most of the changes amount to a straightforward
application of the new guidelines.

### Usage Example:

```swift
x = y.union(z)
y.formUnion(z)                         // y = y.union(z)

x = y.intersection(z)
y.formIntersection(z)                 // y = y.intersection(z)

x = y.subtracting(z)
y.subtract(z)                         // y = y.subtracting(z)

x = y.symmetricDifference(z)
y.formSymmetricDifference(z)         // y = y.symmetricDifference(z)

if x.contains(c) { ... }

y.insert(a)
y.remove(b)
y.update(with: c)

if x.isSubset(of: y) 
   && y.isStrictSubset(of: z)
   && z.isDisjoint(with: x)
   && y.isSuperset(of: z)
   && x.isStrictSuperset(of: z)
   && !y.isEmpty { ... }
```

### Other Changes

There are a few notable changes to `SetAlgebra` that go beyond simple
renaming:

* The concept of elements
  [subsuming or being disjoint with](https://developer.apple.com/library/ios/documentation/Swift/Reference/Swift_SetAlgebraType_Protocol/index.html)
  other elements has been dropped from the documentation, along with
  the corresponding
  [static methods](https://developer.apple.com/library/ios/documentation/Swift/Reference/Swift_SetAlgebraType_Protocol/index.html#//apple_ref/doc/uid/TP40016191-CH1-DontLinkElementID_32)
  of `SetAlgebra`.  The idea was only used in describing the
  semantics of the
  [`remove`](https://developer.apple.com/library/ios/documentation/Swift/Reference/Swift_SetAlgebraType_Protocol/index.html#//apple_ref/swift/intfm/SetAlgebraType/s:FPs14SetAlgebraType6removeFwx7ElementGSqwxS0__)
  method, but we have found a simpler way to describe those semantics.

* The semantics of `remove`'s return value have changed slightly, to
  make them more useful for `OptionSet`s.  When `e` is a “compound
  option” with several bits set in its `rawValue`, and option set `s`
  has a strict subset of those bits set in its raw value,
  `s.remove(e)` no longer returns `nil`.  Instead, it returns
  `s.intersection(e)`.  This change only affects `OptionSet`, not
  `Set`.

* The semantics of `someSet.insert(newMember)` method have been
  changed slightly, so that if `newMember` was already a member of
  `someSet`, it has no effect.  This change in behavior is
  unnoticeable under most circumstances, but can be observed if equal
  `Element` instances can be distinguished.  For example, when
  `Element` is a class, instances may be distinguished using the `===`
  operator.  The new behavior matches that of `NSMutableSet.insert`,
  and is also likely to be more efficient.  Users needing the old
  behavior can always use the new `update(with:)` method, described below.
  In practice this change only affects `Set`, not `OptionSet`.

* `someSet.insert(newMember)` now returns a (discardable) pair
  containing an indication of whether the insertion took place and the
  `Element` equal to `newMember` that is a member of the set after the
  insertion.  This change is an expression of the principle that the
  library shouldn't discard potentially useful and information that
  may have a non-trivial cost to compute.

* A new `update(with: newMember)` API was added, to provide the
  previous unconditional insertion semantics of the `insert` API.

### Detailed Changes

You can follow
[this link](https://github.com/apple/swift/pull/2002/files?diff=split#diff-ad3e45198fdc0c94ad3f05c691813bda)
to see exactly how `SetAlgebra` has changed.  As noted earlier, all
other API changes proposed here are a consequence of applying exactly
the same changes to `Set` and `OptionSet`.

## Impact on existing code

Like all renamings, this is a source-breaking change that can be
largely automated by a migrator.

To avoid any semantic change one could consider automatically
migrating uses of `someSet.insert(newMember)` to `someSet.update(with:
newMember)`, though the chances that a user actually wants the
semantics of `update(with:_)` where she has used `insert(_)` seem
quite slim.

The slight change to the result of `remove` is unlikely to affect
anyone, but one could consider issuing a warning during migration to
inspect the usage if the returned value from `someOptionSet.remove(x)`
is not discarded.

## Alternatives considered

### Naming Guidelines

So many alternatives to the `form` prefix convention were considered
that it's impossible to enumerate them all, but only one candidate
stands out as being particularly worthy of mention: the `InPlace`
suffix that was previously used in the standard library.  `InPlace`
has one major advantage over `form`: the fact that it is a suffix
benefits grouping in alphabetical catalogs of method names and tools
that do code completion by prefix.  However, the `InPlace` suffix has
a few major weaknesses:

* Reading *someNoun*`InPlace` as a verb phrase requires reading
  *someNoun* as a verb. A willingness to pretend that nouns are verbs
  undermines some basic principles of the API guidelines, which
  prescribe different uses for different parts of speech.
  
* `InPlace` could more grammatically be applied to a verb, which means
  you'd really need to read the guidelines carefully to understand how
  to use it properly.  A knowledge of common English doesn't lead
  toward properly applying it.
  
* `InPlace` is visually heavyweight when compared to `form`, and quite
  distasteful to some.
  
### Set API

Since operation nouns tend to arise in mathematical domains, we
considered avoiding math terms and instead using a more
“container-like” API for sets:

```swift
x = y.insertingContents(of: z)
y.insertContents(of: z)

x = y.removingContents(notInCommonWith: z)
y.removeContents(notInCommonWith: z)

x = y.removingContents(inCommonWith: z)
y.removeContents(inCommonWith: z)

x = y.insertingContents(removingCommonContents: z)
y.insertContents(removingCommonContents: z)

if x.contains(c) { ... }

y.insert(a)
y.remove(b)

if x.allContentsAreContained(in: y) 
   && y.allContentsAndMoreAreContained(in: z)
   && z.hasNoContentsInCommon(with: x)
   && y.containsAllContents(of: z)
   && x.containsAllContentsAndMore(of: z)
   && !y.isEmpty { ... }
```

Aside from the obvious awkwardness of some of the resulting code, we
felt that the loss of the immediately-recognizable semantics of
terms-of-art such as `union` and `intersection` was too great a cost.

We also considered being much more explicit about the semantics of the
`insert(_)` / `remove(_)` / `update(with:)` suite of methods, leading
to usage like:

```swift
s.insertIfAbsent(x)
s.removeIfPresent(x)
s.insert(replacingIfPresent: x)
```

In the end, we thought, the extra words would not add clarity to
typical uses of these APIs, where equal set elements are treated as
indistinguishable.

