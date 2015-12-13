# Conversion Protocol Naming Conventions 

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/0000-conversion-protocol-conventions.md)
* Author(s): [Matthew Johnson](https://github.com/anandabits)
* Status: **Review**
* Review manager: TBD

## Introduction

This proposal describes how we can improve the naming convention established by the standard library for conversion related protocols.  It assigns specific meaning to conventional suffixes and requires renaming `CustomStringConvertible` to `CustomStringProjectable` and `CustomDebugStringConvertible` to `CustomDebugStringProjectable` so they conform to the more precise convention.

Swift-evolution thread: [link to the discussion thread for that proposal](https://lists.swift.org/pipermail/swift-evolution)

## Motivation

The Swift standard library establishes conventional suffixes for protocol names.  In most cases these suffixes have a clear and consistent meaning.  However, `Convertible` is used in two different senses.  There are many `Convertible` protocols that convert *from* the type contained in the protocol name.  There are also two protocols, `CustomStringConvertible` and `CustomDebugStringConvertible` that convert *to* the type contained in the protocol name.  It is best to remove this ambiguity and establish a practice of clear and consistent naming conventions whenever possible.

## Proposed solution

This proposal establishes precise conventional meaning for three protocol suffixes.

1. `Convertible`
The `Convertible` suffix is used for protocols which convert *from* the type or associated type mentioned in the protocol name such as `IntegerLiteralConvertible`, `StringLiteralConvertible`, etc.

2. `Representable`
The `Representable` suffix is used for protocols which allow for both projection to and conversion from the type or associated type mentioned in the protocol name.  `RawRepresentable` is currently the only example in the standard library.

3. `Projectable`
The `Projectable` suffix is used for protocols which project *to* the type or associated type mentioned in the protocol name.  If the proposal is accepted `CustomStringProjectable` and `CustomDebugStringProjectable` will be the current examples in the standard library.

Establishing and following this convention will allow Swift developers to have an immediate understanding of the purpose of any protocol that correctly follows the convention.

## Detailed design

The only code change nessary is to update the two impacted protocol declarations to their new names.

```swift
public protocol CustomStringConvertible {
    public var description: String { get }
}
public protocol CustomDebugStringConvertible {
    public var debugDescription: String { get }
}
````

becomes:

```swift
public protocol CustomStringProjectable {
    public var description: String { get }
}
public protocol CustomDebugStringProjectable {
    public var debugDescription: String { get }
}
````

## Impact on existing code

If this proposal is accepted all code mentioning the names of the `CustomStringConvertible` and `CustomDebugStringConvertible` protocols will fail to compile until it is updated (code that only mentions the respective `descripition` and `debugDescription` members of these protocols will not be affected).  Fortunately a mechanical transformation is possible to migrate existing code to use the new names.

User code that used the `Convertible` suffix for protocols that do something other than convert *from* the type mentioned in the protocol name will also be impacted as it will not follow a convention established by the community.  This code will continue to compile and work as intended but will be out of step with the conventions of the community.

If desired, it should be possible to detect user protocols that follow the `Representable` or `Projectable` conventions and offer a fixit to rename these protocols.  A warning could be offered for protocols that do not appear to follow any of the three conventions.  Alternatively, users could be required to update the names of their protocols manually if they wish to follow the convention.

## Alternatives considered

Alternatives to the `Projectible` suffix could be considered but no good ones have been identified.
