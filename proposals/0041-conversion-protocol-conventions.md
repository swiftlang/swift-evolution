# Updating Protocol Naming Conventions for Conversions

* Proposal: [SE-0041](0041-conversion-protocol-conventions.md)
* Authors: [Matthew Johnson](https://github.com/anandabits), [Erica Sadun](http://github.com/erica)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000160.html)

## Introduction

We propose to expand and improve the naming conventions established by the API Guidelines and the standard library with regard to conversion related protocols. We believe common protocol naming patterns should be clear, consistent, and meaningful. The Swift standard library includes slightly north of eighty protocols. Of these, about 15% concern themselves with type initialization and conversion. This proposal assigns specific conventional suffixes to these tasks.  We present this proposal to improve overall language coherence.

*The Swift-evolution thread about this topic can be found here: [Proposal: conversion protocol naming conventions](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/002052.html)*

## Motivation

The Swift standard library establishes conventional suffixes for protocol names.  In most cases suffixes have clear and consistent meanings. `Convertible`, however, is used in two different senses.  

* Most `Convertible` protocols convert *from* a type contained in the protocol name.  
* Two protocols, `CustomStringConvertible` and `CustomDebugStringConvertible` convert *to* the type contained in the protocol name.
* A further protocol, `RawRepresentable` converts type to and from an associated raw type, but does not use the word "convert" in its protocol name.

We propose to remove ambiguity and establish a practice of clear and consistent naming conventions.

The Swift team has updated protocol names in the past, always moving towards clearer naming. Here are a few examples where standard library protocols were affected.

* LogicValue became BooleanType
* Printable and DebugPrintable became CustomStringConvertible, CustomDebugStringConvertible
* ExtensibleCollectionType was folded into RangeReplaceableCollectionType

The conventions proposed in this document offer similar logical naming enhancements.

## Proposed solution

This proposal establishes precise conventional meanings for three protocol suffixes. They describe requirements where conforming instances convert *from* a type, *to* a type, or perform *bi-directional* conversion both to and from a type. We propose updating the API Guidelines to document these conventions and we propose renaming affected protocols in the standard library.

The following conventions communicate the kinds of functionality required from conforming types. This naming scheme excludes any implementation details, such as whether an initializer or static factory method is used to create an instance or how members must be named.

1. `Creatable`
  > The `Creatable` suffix designates protocols that convert *from* a type or associated type mentioned in the protocol name such as `IntegerLiteralConvertible`, `StringLiteralConvertible`, etc. The standard library currently includes many examples.

2. `Convertible`
  > The `Convertible` suffix designates protocols that both project to and convert from a type or associated type mentioned in the protocol name.  The standard library currently includes `RawRepresentable`.

3. `Representable`
  > The `Representable` suffix designates protocols that project *to* a type or associated type mentioned in the protocol name.  The standard library currently includes `CustomStringConvertible` and `CustomDebugStringConvertible`.

We believe these conventions better convey protocol conversion roles to Swift developers.

## Detailed design

This proposal affects the following standard library protocols.

#### Current protocols fulfilling the new Creatable convention:

* `ArrayLiteralConvertible`
* `BooleanLiteralConvertible`
* `DictionaryLiteralConvertible`
* `ExtendedGraphemeClusterLiteralConvertible`
* `FloatLiteralConvertible`
* `IntegerLiteralConvertible`
* `NilLiteralConvertible`
* `StringInterpolationConvertible`


#### Current protocols fulfilling the new Convertible convention:

* `RawRepresentable`


#### Current protocols fulfilling the new Representable convention:

* `CustomStringConvertible`
* `CustomDebugStringConvertible`

## Impact on existing code

If accepted, this proposal will create the following impacts.

* Code mentioning renamed protocols won't compile until updated to the new conventions or will need deprecation warnings and fixits.
* Code that only mentions members of these protocols will not be affected.  

A simple mechanical transformation can migrate existing code to use the new names. There is ample precedent from earlier Swift language updates to guide this change.

Existing user code that includes `Convertible`, `Representable`, and `Creatable` protocol suffixes should be evaluated.  These code bases are unlikely to follow the exact conventions newly established in the API Guidelines.  While this code will continue to compile and work as intended, it will be out of step with the new API Guidelines.

In addition:

* Xcode may be able to detect user-sourced protocols following the old `Representable` or `Convertible` conventions and offer a fixit to rename them. 
* A warning could be offered for protocols that engage in conversion tasks and do not appear to follow any of the three conventions. 
* Alternatively, users who wished to stay in step with the API Guidelines could manually update protocols names to follow these conventions.

## Alternatives considered

The original draft of this proposal suggested the following convention:

1. `Convertible` when converting *from* the type mentioned in the protocol name.
2. `Representable` for bidirectional conversion.
3. `Projectable` when converting *to* the type mentioned in the protocol name.

These choices minimize the changes needed to establish a clear and consistent convention.  This modified proposal presents what the authors believe is the best convention among the possibilities discussed on the mailing list.

Additional names considered for each class of protocol include:

* can be created from: Instantiable, Initializable, Establishable, Constructable, Creatable
* can be converted to: Representable, Expressible, Presentable, Projectable
* can be represented as and instantiated by: Convertible, Representable

We also considered proposing separate conventions for instantiation by initializer and instantiation by factory method. Names potentially applicable to the latter include Building, Producer/Producing and Establishable.  We rejected this approach for being too implementation oriented. 

## Response to Design Team Feedback

The Standard Library design team raises the following concerns:

> While we agree with the basic intention of the proposal, we
don't agree with the proposed answer.
>
> In particular, we think the “LiteralConvertible” names are the only ones
that can be improved upon by anything we've seen proposed or have been
able to think of.  In particular, swapping “Representable” and “Convertible”
doesn't do anything to clarify directionality, and for us, “XXXConvertible”
has exactly the connotation of “convertibility to XXX”

**Our Response** 

We picked these names after significant research and consideration:

* *Convertible* implies a commutative or two-way relation. For example, a convertible car can be converted to a sedan style or an open style. A convertible sofa can act as a bed or a sofa. Convertible suggests a R b as well as b R a. The word means to change into a different form and be used in a different way. 

* To *represent* means to serve as or to take the place of by accruing characteristics or qualities. This suggests that a R b is not the same as b R a. My lawyer can represent my legal interests but I cannot represent my lawyer in court. 

* To *create* means to produce something new and cause it to exist. While semantically distant from initializing, the terms overlap in practical use. The current (badly named) IntegerLiteralConvertible means "a conforming construct can use an integer literal to establish an instance of itself". 

> For the “Literalconvertible” names, we think the optimal answer would be
to sink them into a subnamespace of Swift called “Swift.Syntax” and
rename them by dropping “Convertible” (and changing
StringInterpolationConvertible to InterpolatedStringLiteral).  Lacking
that language feature, we'd propose to underscore the canonical names of
these protocols and create typealiases in an empty enum called “Syntax.”
That would lead to, e.g. `extension ArraySlice : Syntax.ArrayLiteral, ...  {  }`
>

**Our Response**

These are implementation details that fall outside the scope of our proposal. This proposal concerns itself with core semantic conventions for protocol names and does not address how those names are otherwise formed, structured, or applied.

> We don't think there are enough
real examples of outside the “Literal” category to start nailing down
conventions for them.  We only have 3 of those, and only 2 of them are
particularly similar to one another.

**Our Response**

The semantics cover "converting to a type", "converting from a type", and "converting to and from a type". We have examples from our own code and from third party code on GitHub that suggest conversion tasks are common enough that standardizing API naming conventions will be valuable.

## Updated Approach


Our updated approach further incorporates design team feedback and focuses on the two most important conventions: one for initialization and one for representation.

#### `Initializable`

`Initializable` designates protocols that convert *from* a type or from an associated type mentioned in the protocol name, such as the current `\<Type\>LiteralConvertible` protocols.  This convention would include member requirements for initializers, factory methods, and any other way an instance can be imported to establish a new instance of the conforming type.

For example, conforming to `ArrayLiteralInitializable` would allow a set to be created with `Set(arrayLiteral: \<some array\>)` and `var set: Set\<T\> = []`.

This phrase replaces the `Creatable` form from our original proposal.

#### `Representable`

`Representable` designates protocols whose primary purpose is to project *to* a type or associated type mentioned in the protocol name.  Items in the standard library that would be subsumed into this naming include `CustomStringConvertible`, `CustomDebugStringConvertible`, and `RawRepresentable`, which we imagine would become `CustomStringRepresentable`, `CustomDebugStringRepresentable`, and (as current) `RawRepresentable`.

This second category groups together the `Convertible` and `Representable` categories from our original proposal and is predicated on the feedback from the design team review. The `Representable` designation does not promise bidirectional conversion although some `Representable` protocols may include requirements to allow attempted initialization *from* the type of the representation. Doing so falls outside the naming contract we are proposing. 

#### Future Directions

We do not include a third category for bidirectional conversion in this update. We recognize that style of contract is rare in Swift. Lossless conversion does not appear in the standard library outside of `RawRepresentable`, which we agreed was better covered by `Representable`. If such a convention is needed or adopted, we reserve the `Isomorphic` designation for future use.
