# Listing all possible values of a type

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Brent Royal-Gordon](https://github.com/brentdax)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal adds a `ValuesEnumerable` protocol to the standard library.
Conforming to this protocol requires your type to offer a static `allValues`
property, vending a collection which includes all permitted values of the 
type. The Swift compiler will automatically derive an implementation for 
this property in certain cases, particularly for simple `enum`s.

Swift-evolution thread: Several, most recently [Pre-proposal: CaseEnumerable protocol (derived collection of enum cases)](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006876.html)

## Motivation

Sometimes, particularly when using enums, developers want to fetch all 
possible instances of a type.

This desire manifests in many different ways with varying degrees of 
hackiness. Some developers [create an array, but have to keep it up to date](http://stackoverflow.com/questions/24033782/how-to-get-all-values-of-an-enum-in-swift).
Others [keep a count of the cases and use `RawRepresentable` to construct them](http://stackoverflow.com/questions/27094878/how-do-i-get-the-count-of-a-swift-enum),
presuming they are all consecutive and start at 0. Different developers use 
different names for this operation. And all possible solutions require you 
to either specify redundant information, rely on implementation details, or 
both.

In short, this operation is crying out to be standardized by Swift 3.

## Proposed solution

The Swift standard library will include a protocol called `ValuesEnumerable`:

	/// Conforming types have a finite, easily calculable set of possible 
	/// values, which they offer through the `allValues` property.
	protocol ValuesEnumerable {
		/// A collection containing all possible values for this type.
		/// 
		/// If `Self` is `Equatable`, performing `allValues.indexOf(value)` 
		/// must never return `nil`. Otherwise, performing 
		/// `allValues.indexOf { $0 ~= value }` must never return `nil`. If 
		/// `Self` is `Comparable`, `allValues` must contain its values in 
		/// sorted order.
		/// 
		/// -Note: Reference types need not provide every possible instance 
		///        in this property, but all instances must compare `==` or 
		///        (if the type is not `Equatable`) `=~` to one of its 
		///        elements.
		static var allValues: [Self]
	}

If no implementation of the `allValues` property is provided, and the
`enum` meets implementation-specified requirements, the Swift compiler
will automatically derive an implementation of `allValues`.

## Detailed design

The precise requirements for an enum to receive a derived `allValues` 
property are implementation-specific, and changes to them should 
not require additional proposals. At minimum, the Swift compiler 
must derive an `allValues` property for `enum`s where:

* None of the cases include associated values.
* There is no conformance to `Comparable`.

The cases should be listed in the `allValues` property in the same 
order in which they appear in the source code.

This proposal permits, but does not require, the Swift compiler to 
derive an `allValues` property for `enum`s where:

* Some cases include associated values, but all types in these values
  are themselves `ValuesEnumerable`, and no cases are `indirect`.
* The Swift compiler can determine that a `Comparable` conformance
  matches source order. (For instance, if the comparator compares 
  integer `rawValue`s and the source doesn't assign any, it must match 
  source order.)

### Interactions with future features

There is currently a [discussion of future generics and protocol features](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160229/011666.html).
One of these proposals could be used to loosen the type of `allValues`,
permitting it to be any collection type:

	protocol ValuesEnumerable {
		/// The type of the static `allValues` property on this type. This 
		/// must be a collection of `Self`.
		associatedtype AllValuesCollection: Collection where AllValuesCollection.Iterator.Element == Self
		
		/// A collection containing all possible values for this type.
		/// 
		/// If `Self` is `Equatable`, performing `allValues.indexOf(value)` 
		/// must never return `nil`. Otherwise, performing 
		/// `allValues.indexOf { $0 ~= value }` must never return `nil`. If 
		/// `Self` is `Comparable`, `allValues` must contain its values in 
		/// sorted order.
		/// 
		/// -Note: Reference types need not provide every possible instance 
		///        in this property, but all instances must compare `==` or 
		///        (if the type is not `Equatable`) `=~` to one of its 
		///        elements.
		static var allValues: AllValuesCollection
	}

If the necessary feature is added to Swift, `ValuesEnumerable` should 
use this definition instead. That will free implementors to use more 
efficient collection types which generate the instances on the fly 
instead of storing them in an array.

No additional proposal would be required to change to this definition.

## Impact on existing code

None, unless someone is already defining a protocol named `ValuesEnumerable`.

## Future directions

It may make sense to make other standard library types conform to 
`ValuesEnumerable`:

* `Bool`
* Small integer types like `Int8` and perhaps `Int16`
* *All* integer types (by using ranges), which might subsume their `min` 
  and `max` properties.
* `Optional` and `ImplicitlyUnwrappedOptional`, if conditional conformances
  are added to Swift.
* `()` and tuples of `CaseEnumerable` types, if conformances for structural 
  types are added to Swift.

We consider these changes severable, so they will be left for future 
proposals.

## Alternatives considered

Many people suggested adding a `count` property; this was actually a 
common start to threads on this topic. This option was rejected in 
favor of a collection because `count` is only useful for enums backed 
by contiguous integers, whereas an `allValues` collection is much more 
broadly usable.

Many, many options for the name of the protocol and property were considered.
I've chosen `allValues` and `ValuesEnumerable` because they make sense when 
applied to non-enum types; other options like `cases` do not have that property.
(`cases` has an additional weakness: the most natural choice for a `for` loop
iteration variable, `case`, is invalid because it is a keyword when it comes 
after `for`.)

We considered requiring the recursive `ValuesEnumerable` derivation behavior,
but it was deemed insufficiently important to the feature as a whole.

We considered automatically providing a `ValuesEnumerable` conformance on all 
enums for which we could derive an implementation, but this would introduce 
possibly unnecessary overhead. Using an `extension` to retroactively add the 
protocol is good enough.
