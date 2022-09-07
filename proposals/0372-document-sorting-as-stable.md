# Document Sorting as Stable

* Proposal: [SE-0372](0372-document-sorting-as-stable.md)
* Author: [Nate Cook](https://github.com/natecook1000)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Active review (September 7, 2022...September 20, 2022)**
* Implementation: [apple/swift PR #60936](https://github.com/apple/swift/pull/60936)
* Review: ([pitch](https://forums.swift.org/t/pitch-document-sorting-as-stable/59880))

## Introduction

Swift's sorting algorithm was changed to be stable before Swift 5, but we've never updated the documentation to provide that guarantee. Let's commit to the sorting algorithm being stable so that people can rely on that behavior.

## Motivation

A *stable sort* is a sort that keeps the original relative order for any elements that compare as equal or unordered. For example, given this list of players that are already sorted by last name, a sort by first name preserves the original order of the two players named "Ashley":

```swift
var roster = [
   Player(first: "Sam", last: "Coffey"),
   Player(first: "Ashley", last: "Hatch"),
   Player(first: "Kristie", last: "Mewis"),
   Player(first: "Ashley", last: "Sanchez"),
   Player(first: "Sophia", last: "Smith"),
]

roster.sort(by: { $0.first < $1.first })
// roster == [
//    Player(first: "Ashley", last: "Hatch"),
//    Player(first: "Ashley", last: "Sanchez"),
//    Player(first: "Kristie", last: "Mewis"),
//    Player(first: "Sam", last: "Coffey"),
//    Player(first: "Sophia", last: "Smith"),
// ]
```

For users who are unaware that many sorting algorithms aren't stable, an unstable sort can be surprising. Preserving relative order is an expectation set by software like spreadsheets, where sorting by one column, and then another, is a way to complete a sort based on multiple properties.

Sort stability isn't always observable. When a collection is sorted based on the elements' `Comparable` conformance, like sorting an array of integers, "unordered" elements are typically indistinguishable. In general, sort stability is important when elements are sorted based on a subset of their properties.

The standard library `sort()` has long been stable, but the documentation explicitly [doesn't make this guarantee](https://github.com/apple/swift/blob/release/5.7/stdlib/public/core/Sort.swift#L40-L41):

> The sorting algorithm is not guaranteed to be stable. A stable sort preserves the relative order of elements that compare as equal.

This status quo is a problem — developers who are aware of what stability is cannot rely on the current behavior, and developers who are unaware of stability could be surprised by unexpected bugs if stability were to disappear. Guaranteeing stability would resolve both of these issues.

## Proposed solution

Let's change the documentation! Since all current versions of the Swift runtime include a stable sort (which was introduced before ABI stability), this change can be made to the standard library documentation only:

```diff
- /// The sorting algorithm is not guaranteed to be stable. A stable sort
+ /// The sorting algorithm is guaranteed to be stable. A stable sort
  /// preserves the relative order of elements that compare as equal.
```

## Source compatibility

This change codifies the existing standard library behavior, so it is compatible with all existing source code.

## Effect on ABI stability

The change to make sorting stable was implemented before ABI stability, so all ABI-stable versions of Swift already provide this behavior.

## Effect on API resilience

Making this guarantee explicit requires that any changes to the sort algorithm maintain stability.

## Alternatives considered

### Providing an `unstableSort()`

Discussing the *stability* of the current sort naturally brings up the question of providing an alternative sort that is *unstable*. An unstable sort by itself, however, doesn't provide any specific benefit to users — no one is asking for a sort that mixes up equivalent elements! Instead, users could be interested in sort algorithms that have other characteristics, such as using only an array's existing allocation, that are much faster to implement without guaranteeing stability. If and when proposals for those sort algorithms are introduced, the lack of stability can be addressed through documentation and/or API naming, and having the default sort be stable is still valuable for the reasons listed above.

## Future directions

There are a variety of other sorting-related improvements that could be interesting to pursue, including key-path or function-based sorting, sorted collection types or protocols, sort descriptors, and more. These ideas can be explored in future pitches and proposals.
