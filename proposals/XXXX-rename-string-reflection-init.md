# Renaming `String.init<T>(_: T)`

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-rename-string-reflection-init.md)
* Author(s): [Austin Zheng](https://github.com/austinzheng)
* Status: **[Awaiting review](#rationale)**
* Review manager: TBD

## Introduction

Swift's `String` type ships with a large number of initializers that take one unlabeled argument. One of these initializers, defined as `init<T>(_: T)`, is used to create a string containing the textual representation of an object. It is very easy to write code which accidentally invokes this initializer by accident, when one of the other synonymous initializers was desired. Such code will compile without warnings and can be very difficult to detect.

Discussion thread: [part 1](https://lists.swift.org/pipermail/swift-users/Week-of-Mon-20160502/001846.html), [part 2](https://lists.swift.org/pipermail/swift-users/Week-of-Mon-20160509/001867.html)

## Motivation

`String` ships with a number of initializers which take a single unlabeled argument. These include non-failable initializers which create a `String` out of a `Character`, `NSString`, `CharacterView`, or `UnicodeScalarView`, initializers which build a string out of a number, and failable initializers which take a `UTF8View` or a `UTF16View`.

There are at least two possible situations in which a user may write incorrect code which nevertheless compiles successfully:

* The user means to call one of the non-failable initializers besides the `init<T>(_: T)` initializer, but passes in an argument of incorrect type.
* The user means to call one of the failable initializers, but accidentally assigns the created object to a value of non-nullable type.

In both cases the compiler silently infers the use of the `init<T>(_: T)` initializer in lieu of the desired initializer. This may result in degraded performance and/or unexpected output.

## Proposed solution

Rename `init<T>(_: T)` to require an argument label: `init<T>(printing: T)`, per [Joe Groff's](https://github.com/jckarter) suggestion in the aforementioned thread.

## Impact on existing code

This API change may impact existing code.

Code which intends to invoke `init<T>(_: T)` will need to be modified so that the initializer is called with the argument label. In addition, it is possible that this change may uncover instances of the erroneous behavior described previously.

## Alternatives considered

An alternative to this proposal brought up in the aforementioned thread would be to remove the `init<T>(_: T)` initializer entirely and replace it with a global function. However, the design of the standard library API has been moving away from global functions in favor of members (initializers, methods, properties, etc) on types. As well, the use of an initializer remains the most semantically obvious way to implement the creation of a new `String` instance based on an existing value.

-------------------------------------------------------------------------------

# Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
