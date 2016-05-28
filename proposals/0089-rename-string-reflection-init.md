# Renaming `String.init<T>(_: T)`

* Proposal: [SE-0089](0089-rename-string-reflection-init.md)
* Author: [Austin Zheng](https://github.com/austinzheng)
* Status: **Awaiting Review**
* Review manager: [Chris Lattner](http://github.com/lattner)
* Revision: 2
* Previous Revisions: [1](https://github.com/apple/swift-evolution/blob/40aecf3647c19ae37730e39aa9e54b67fcc2be86/proposals/0089-rename-string-reflection-init.md)

## Introduction

Swift's `String` type ships with a large number of initializers that take one unlabeled argument. One of these initializers, defined as `init<T>(_: T)`, is used to create a string containing the textual representation of an object. It is very easy to write code which accidentally invokes this initializer by accident, when one of the other synonymous initializers was desired. Such code will compile without warnings and can be very difficult to detect.

Discussion threads: [pre-proposal part 1](https://lists.swift.org/pipermail/swift-users/Week-of-Mon-20160502/001846.html), [pre-proposal part 2](https://lists.swift.org/pipermail/swift-users/Week-of-Mon-20160509/001867.html), [review thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160516/017881.html), [post-review thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160523/019018.html)

## Motivation

`String` ships with a number of initializers which take a single unlabeled argument. These include non-failable initializers which create a `String` out of a `Character`, `NSString`, `CharacterView`, or `UnicodeScalarView`, initializers which build a string out of a number, and failable initializers which take a `UTF8View` or a `UTF16View`.

There are at least two possible situations in which a user may write incorrect code which nevertheless compiles successfully:

* The user means to call one of the non-failable initializers besides the `init<T>(_: T)` initializer, but passes in an argument of incorrect type.
* The user means to call one of the failable initializers, but accidentally assigns the created object to a value of non-nullable type.

In both cases the compiler silently infers the use of the `init<T>(_: T)` initializer in lieu of the desired initializer. This may result in code which inadvertently utilizes the expensive reflection machinery and/or produces an unintentionally lossy representation of the value.

## Proposed solution

A proposed solution to this problem follows.

* The current reflection-based `String.init<T>(_: T)` initializer will be renamed to `String.init<T>(describing: T)`. This initializer will rarely be invoked directly by user code.

* A new protocol will be introduced: `ValuePreservingStringConvertible`. This protocol will be defined as follows:

	```swift
	protocol ValuePreservingStringConvertible {

		/// A lossless, unambiguous representation of the conforming type as a string.
		var stringRepresentation : String { get }

		/// Instantiate an instance of the conforming type from a string representation.
		init?(stringRepresentation: String)
	}
	```

	Values of types that conform to `ValuePreservingStringConvertible` are capable of being represented in a lossless, unambiguous manner as a string. For example, the integer value `1050` can be represented in its entirety as the string `"1050"`. As such, it should be possible to attempt to create an instance of a `ValuePreservingStringConvertible` conforming type from a string representation.

* A new initializer will be introduced: `init<T: ValuePreservingStringConvertible>(_ v: T) { return v.stringRepresentation }`. This allows the `String(x)` syntax to continue to be used on all values of types that can be converted to a string in a value-preserving way.

* The standard library will be audited. Any type which can be reasonably represented as a string in a value-preserving way will be modified to conform to `ValuePreservingStringConvertible`. If they conform to `CustomStringConvertible` and their existing `description` is value-preserving, `stringRepresentation` will simply return `description`.

* The Foundation SDK overlay will be audited in the same manner.

* As a performance optimization, the implementation of the string literal interpolation syntax will be changed to prefer the unlabeled initializer when interpolating a type that is `ValuePreservingStringConvertible` or that otherwise has an unlabeled `String` initializer, but use the `String.init<T>(describing: T)` initializer if not.

With the introduction of the `ValuePreservingStringConvertible` protocol, the intended semantics of the three string convertible protocols can thus be clarified:

* `CustomStringConvertible` will provide a human-readable description of an instance. It may provide as little or as much detail as deemed appropriate.

* `CustomDebugStringConvertible` will provide a human-readable description of an instance. It can provide additional information relative to `CustomStringConvertible`, information that would not be pertinent for consumers of `description`s (such as human readers or other APIs), but would be useful for development or diagnostic purposes.

* `ValuePreservingStringConvertible` will provide an exact, value-preserving representation of an instance, one that is sufficent to reconstruct an instance of that type.

## Impact on existing code

This API change may impact existing code.

Code which intends to invoke `init<T>(_: T)` will need to be modified so that the proper initializer is called. In addition, it is possible that this change may uncover instances of the erroneous behavior described previously.

## Alternatives considered

One alternative solution might be to make `ValuePreservingStringConvertible` an empty protocol narrowing `CustomStringConvertible`, and require conforming types to vend a `description` providing a value-preserving representation. There are several potential pitfalls to this approach:

* The term `description` does not unambigiously imply "a value-preserving string representation" to readers. It can be reasonably construed as referring to a human-readable abridged summary of the value in question, which is how it is used today for many complex types (such as `UIView`). Overloading `description` to mean two different things would require types to choose between conforming to `ValuePreservingStringConvertible` and providing abridged descriptions of their instances.

* It would make conforming certain Foundation types (which would otherwise be a natural fit for this functionality) impossible without introducing changes in functionality to existing APIs. Code that depends on `description` returning a string with a particular format might break as a result.

Another alternative solution might be to avoid introducing any new protocols, and instead allow `CustomStringConvertible` or `CustomDebugStringConvertible` to provide the means by which a String could be initialized from another type. This solution would prevent any sort of formal distinction between types that can be turned into value-preserving strings, and those that cannot.

-------------------------------------------------------------------------------

# Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
