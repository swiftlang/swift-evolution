# Replacing Equal Signs with Colons For Attribute Arguments

* Proposal: [SE-0040](0040-attributecolons.md)
* Author: [Erica Sadun](http://github.com/erica)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160307/012100.html)
* Implementation: [apple/swift#1537](https://github.com/apple/swift/pull/1537)

## Introduction

Attribute arguments are unlike other Swift language arguments. At the call site, they use `=` instead of colons
to distinguish argument names from passed values. This proposal brings attributes into compliance with Swift 
standard practices by replacing the use of "=" with ":" in this one-off case.

*Discussion took place on the Swift Evolution mailing list in the [\[Discussion\] Replacing Equal Signs with Colons For Attribute Arguments](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160215/010448.html) thread. Thanks to [Doug Gregor](https://github.com/DougGregor) for suggesting this enhancement.*

## Motivation

Attributes enable developers to annotate declarations and types with keywords that constrain behavior. 
Recognizable by their [at-sign](http://foldoc.org/strudel) "@" prefix, attributes communicate features, 
characteristics, restrictions, and expectations of types and declarations to the Swift compiler. 
Common attributes include `@noescape` for parameters that cannot outlive the lifetime of a call, 
`@convention`, to indicates whether a type's calling conventions follows a Swift, C, or (Objective-C) block model, and 
`@available` to enumerate a declaration's compatibility with platform and OS versions. Swift currently
offers about a dozen distinct attributes, and is likely to expand this vocabulary in future language updates.

Some attributes accept arguments: `@attribute-name(attribute-arguments)` including, at this time,
`@available`, `@warn_unused_result` and `@swift3_migration`. In the current grammar, an equal sign separates attribute 
argument keywords from values.

```swift
introduced=version-number
deprecated=version-number
obsoleted=version-number
message=message
renamed=new-name
mutable_variant=method-name
```

Using `=` is out of step with other Swift parameterization call-site patterns.
Although the scope of this proposal is quite small, tweaking the grammar to match the 
rest of Swift introduces a small change that adds consistency across the language. 

```swift
parameter name: parameter value
```

## Detail Design 

This proposal replaces the use of `=` with `:` in the balanced tokens used to compose an attribute 
argument clause along the following lines:

```swift
attribute → @ attribute-name attribute-argument-clause<sub>opt</sub>
attribute-name → identifier
attribute-argument-clause → ( balanced-tokens<sub>opt<opt> )
balanced-tokens → balanced-token
balanced-tokens → balanced-token, balanced-tokens
balanced-token → attribute-argument-label : attribute argument-value
```

This design can be summarized as "wherever current Swift attributes use `=`, use `:` instead", for example:

```swift
@available(*, unavailable, renamed: "MyRenamedProtocol")
typealias MyProtocol = MyRenamedProtocol

@warn_unused_result(mutable_variant: "sortInPlace")
public func sort() -> [Self.Generator.Element]

@available(*, deprecated, message: "it will be removed in Swift 3.  Use the 'generate()' method on the collection.")
public init(_ bounds: Range<Element>)
```

## Alternatives Considered

There are no alternatives to put forth other than not accepting this proposal.
