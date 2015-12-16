# Conversion Protocol Naming Conventions 

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/0000-conversion-protocol-conventions.md)
* Author(s): [Matthew Johnson](https://github.com/anandabits), [Erica Sadun](https://github.com/erica)
* Status: **Review**
* Review manager: TBD

## Introduction

This proposal describes how we can improve the naming convention established by the API Guidelines and the standard library for conversion related protocols.  It assigns specific meaning to conventional suffixes and requires all converstion related protocols in the standard library: `*Convertible` and `RawRepresentable` so they conform to the convention.

Swift-evolution thread: [Proposal: conversion protocol naming conventions](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/002052.html)

## Motivation

The Swift standard library establishes conventional suffixes for protocol names.  In most cases these suffixes have a clear and consistent meaning.  However, `Convertible` is used in two different senses.  There are many `Convertible` protocols that convert *from* the type contained in the protocol name.  There are also two protocols, `CustomStringConvertible` and `CustomDebugStringConvertible` that convert *to* the type contained in the protocol name.  It is best to remove this ambiguity and establish a practice of clear and consistent naming conventions whenever possible.

## Proposed solution

This proposal establishes precise conventional meaning for three protocol suffixes.  The API Guidelines will be updated to document the conventional meanings and the relevant protocols in the standard library will be renamed accordingly.

The conventions are intended to communicate the general functionality provided by conforming types.  They are not intended to communicate specific implementation details.  Examples of implementation details include whether an initializer or static factory method is used to create an instance as well as specific naming of members.

1. `Creatable`
The `Creatable` suffix is used for protocols which convert *from* the type or associated type mentioned in the protocol name such as `IntegerLiteralConvertible`, `StringLiteralConvertible`, etc.  

2. `Convertible`
The `Convertible` suffix is used for protocols which allow for both projection to and conversion from the type or associated type mentioned in the protocol name.  `RawRepresentable` is currently the only example in the standard library.

3. `Representable`
The `Representable` suffix is used for protocols which project *to* the type or associated type mentioned in the protocol name.  `CustomStringConvertible` and `CustomDebugStringConvertible` are the current examples in the standard library.

Establishing and following this convention will allow Swift developers to have an immediate understanding of the purpose of any protocol that correctly follows the convention.

## Detailed design

The following protocols in the standard library will be renamed:

* `ArrayLiteralConvertible`
* `BooleanLiteralConvertible`
* `DictionaryLiteralConvertible`
* `ExtendedGraphemeClusterLiteralConvertible`
* `FloatLiteralConvertible`
* `IntegerLiteralConvertible`
* `NilLiteralConvertible`
* `StringInterpolationConvertible`

* `RawRepresentable`

* `CustomStringConvertible`
* `CustomDebugStringConvertible`

It may be interesting to consider renaming additional projection-like protocols to this standard, although they are less obvious candidates:

* `CustomReflectable`
* `CustomLeafReflectable`
* `CustomPlaygroundQuickLookable`

## Impact on existing code

If this proposal is accepted all code mentioning the renamed protocols will fail to compile until it is updated.  Code that only mentions members of these protocols will not be affected.  Fortunately a mechanical transformation is possible to migrate existing code to use the new names.

User code that used the `Convertible`, `Representable` or `Creatable` protocol suffixes or will also be impacted as it is unlikely to follow the newly established convention in the API Guidelines.  This code will continue to compile and work as intended but will be out of step with the the API Guidelines.

If desired, it should be possible to detect user protocols that follow the `Representable` or `Projectable` conventions and offer a fixit to rename these protocols.  A warning could be offered for protocols that do not appear to follow any of the three conventions.  Alternatively, users could be required to update the names of their protocols manually if they wish to follow the convention.

## Alternatives considered

The original draft of this proposal suggested the following convention:
1. `Convertible` when converting *from* the type mentioned in the protocol name.
2. `Representable` for bidirectional conversion.
3. `Projectable` when converting *to* the type mentioned in the protocol name.

The rationale for this was to make the minimal change necessary to establish a clear and consistent convention.  The proposal has been modified to present what the authors believe is the best possible convention among the possibilties that have been discussed on the mailing list.

Some additional alternatives considerd for each class of protocol are:

can be created from: Instantiable, Initializable, Establishable, Constructable, Creatable
can be converted to: Representable, Expressible, Presentable, Projectable
can be represented as and instantiated by: Convertible, Representable

We also considered proposing separate conventions for instantiation by initializer and instantiation by factory method.  Some names potentially applicable to the latter are Building, Producer/Producing and Establishable.  This approach was rejected for being too implementation oriented. 
