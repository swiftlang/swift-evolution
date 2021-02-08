# `count(where:)`

* Proposal: [SE-0220](0220-count-where.md)
* Author: [Soroush Khanlou](https://github.com/khanlou)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Deferred**
* Implementation: [apple/swift#16099](https://github.com/apple/swift/pull/16099), [apple/swift#22289](https://github.com/apple/swift/pull/22289) (revert PR)

## Introduction

While Swift's `Sequence` models brings a lot of niceties that we didn't have access to in Objective-C, like `map` and `filter`, there are other useful operations on sequences that the standard library doesn't support yet. One current missing operation is  `count(where:)`, which counts the number of elements in a `Sequence` that pass some test.

Swift-evolution thread: [`count(where:)` on Sequence](https://forums.swift.org/t/count-where-on-sequence/11186)

## Motivation

Counting the number of objects that pass a test has a wide range of uses in many domains. However, Swift currently doesn't give its users a simple way to perform this operation. While the behavior can currently be approximated with a `filter` and a `count`, this approach creates an intermediate array which it immediately discards. This is a bit wasteful.

    [1, 2, 3, -1, -2].filter({ $0 > 0 }).count // => 3

To correctly avoid a potentially expensive intermediate array, you can use the Swift's `lazy` subsystem:

    [1, 2, 3, -1, -2].lazy.filter({ $0 > 0 }).count // => 3

However, using `lazy` comes with the downside of being forced to use an `@escaping` block. Lastly, you could rely on an eminently unreadable `reduce`:

    [1, 2, 3, -1, -2].reduce(0) { $1 > 0 ? $0 + 1 : $0 }

These three solutions lie on a spectrum between "easy to write, but include performance traps" to "performant, but require Swift arcana to write".

## Proposed solution

The proposed solution would avoid a performance trap and provide a simple interface for users to both read and write. Autocomplete should present it to them handily as well.

    [1, 2, 3, -1, -2].count(where: { $0 > 0 }) // => 3

I use it as an extension in my code regularly, and I think it'd make a nice addition to the standard library.

## Detailed design

A reference implementation for the function is included here:

    extension Sequence {
        func count(where predicate: (Element) throws -> Bool) rethrows -> Int {
            var count = 0
            for element in self {
                if try predicate(element) {
                    count += 1
                }
            }
            return count
        }
    }

The recommended implementation can be found [in a pull request to `apple/swift`](https://github.com/apple/swift/pull/16099).

## Source compatibility

This change is additive only.

## Effect on ABI stability

This change is additive only.

## Effect on API resilience

This change is additive only.

## Alternatives considered

One alternative worth discussing is the addition of `count(of:)`, which can be implemented on sequences where `Element: Equatable`. This function returns the count of all objects that are equal to the parameter. I'm open to amending this proposal to include this function, but in practice I've never used or needed this function, so I've omitted it here.

