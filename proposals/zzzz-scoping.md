# Flexible Access Control Scoping

* Proposal: TBD <!-- [SE-NNNN](NNNN-filename.md) -->
* Authors: [Erica Sadun](https://github.com/erica), [Jeffrey Bergier](https://github.com/jeffreybergier)
* Review Manager: TBD
* Status: TBD <!-- **Awaiting review** -->

<!--
*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

-->

## Introduction

This proposal introduces flexible access control scoping to Swift. It offers an underlying additive architecture that mitigates Swift scoped access issues. For example, a Swift coder should not have to mark a symbol `internal` so it can be accessed in just one other file by a targeted consumer, delegate, or data source. The proposal retains Swift 3 keywords and expands scoping to match the level of customization found in other parts of the Swift programming language. 

This proposal follows on to [SE-0169](https://github.com/apple/swift-evolution/blob/master/proposals/0169-improve-interaction-between-private-declarations-and-extensions.md). SE-0169 proposed a minimal workaround to improve the less than ideal "access control situation we have today, while leaving open this direction for future discussion." 

## Background

Significant time and effort has been dedicated in the Swift Evolution community to refining Swift's scoped access model.

* [SE-0025](https://github.com/apple/swift-evolution/blob/master/proposals/0025-scoped-access-level.md) introduced the current model. A year of deployment and real-world use has produced mixed reactions from the developer community. 

* [SE-0159](https://github.com/apple/swift-evolution/blob/master/proposals/0159-fix-private-access-levels.md) attempted to revert Swift's access control model back to the pre-SE-0025 Swift 2 design. It was rejected as too large a change, opposing Swift 4's source compatibility goals.

* [SE-0169](https://github.com/apple/swift-evolution/blob/master/proposals/0169-improve-interaction-between-private-declarations-and-extensions.md) focused on the narrow challenge of embracing Swift's extension-oriented design, allowing `private` access control to propagate to all uses of a type, regardless of whether those members are used within the original declaration or extensions. Under SE-0169:
	* Extensions within the same scope are granted access to a type's `private` members.
	* Extensions within the same scope are granted access to `private` members declared in other extensions of the same type.
	* John McCall writes, "The only question is whether extensions of the same type within a file should be considered part of the same scope for the purposes of 'private'."

## Motivation

SE-0169's adoption will not be sufficiently wide-reaching. It fails to address the following scenarios, which are covered by this proposal directly or as future directions: 

* Same-type access at the modular level above the current scope, generally referred to as `typeprivate`. 
* Access for derived types, both within the same scope and throughout the module.
* Unit test access. You should not need to mark a type `internal` or `public` solely to support unit test compatibility.
* Granting access to a limited set of client types within the same module, essentially creating a *submodule*, which is more restricted than `internal` access levels and less restricted than `private` access levels.

This last point is particularly important. Access levels should allow you to expose code to subsystems. For example, you might need to make a cache visible to multiple participants. For safety, that cache should not be exposed outside that subsystem. To accomplish this goal, you must select one of the following options:

1. Place everything in one file, leading to messy megafile implementations.
2. Mark the cache system as `internal` and break the safety contract.
3. Break the cache system into a separate framework, which might be difficult to justify architecturally, and which places a  higher load on compilation and execution.

Other examples include placing client, delegate, and data source code in separate files while limiting their visibility to the types they serve. 

As a final note, some inherently private protocol members must be marked `public` to enable public use by other protocol members. While these members shouldn’t participate in published APIs, they have to due to Swift technical limitations. While we don't have a solution to this problem in this proposal, we hope that this proposal could be enhanced in the future to help solve this issue.

### Design Philosophy

Given the design realities of modifying access control in Swift 4, *success* depends on meeting the following criteria:

* **Source Compatible** The changes must be source compatible with Swift 3.
* **Addressing Harm** The changes must mitigate active harm within the language to fall within the scope of Swift 4.
* **Flexible** The changes must be sufficiently flexible to express a majority of the desired scenarios enumerated in the previous sections.
* **Extensible** The changes must be extensible, permitting new access levels to be introduced at a future date.
* **Documentable** The changes must support descriptions, encouraging integrated documentation markup and presentation for integration into the Xcode Quick Help system.
* **Readable** The changes must be readable and support code review. New terms may interchange with and be placed near existing keywords.
* **Low Impact** The changes must limit keyword impact and not clog the language.

## Proposed solution

We propose adding parameterized `accessgroup` declarations to establish access modifiers, both for existing Swift 3 keywords and user-driven requirements. Group modifiers express a symbol's *visible* and *override* scopes. System-supplied groups will provide source compatibility with Swift 3 (see the following sample). They can be extended using both custom group declarations and derived access groups modeled on existing groups:

```
// This is the default access level
accessgroup internal {
    visible: #module
    override: #module
}

// Private access 
accessgroup private {
    visible: #scope
    override: #scope
}

// Fileprivate access
accessgroup fileprivate {
    visible: #file
    override: #file
}

// Public access
accessgroup public {
    visible: #all
    override: #module
}

// Open access
accessgroup open: public {
    override: #all
}

// Final access denies subtyping and override
accessgroup final {
    override: #none
}
```

In some cases, developers may want to have a "one off" accessgroup declared inline on a type:

```swift
accessgroup { visible: #all, OtherType; override: #none } class SomeType {
    ...
}
```

## Detailed Design

Here is a near-approximation to the `accessgroup` grammar:

```
// An encompassing description of possible scope values
Scope :- 
    `#module`  |    // aka S3 `internal`, default
    `#all`     |    // aka S3 `public` or `open`
    `#none`    |    // hidden or denied
    `#scope`   |    // aka S3 `private`
    `#file`    |    // aka S3 `fileprivate`
    `#type`    |    // aka `typeprivate`
    `#subtype` |    // types *and* derived types
    TypeName        // specific type or protocol

// Scope references, which may include individual scopes
// and scopes derived from the parent access group
Scoping :- Scope | `super`

// Access group declaration, which may be optionally
// derived from a parent group
Group :- `accessgroup` (GroupName (: GroupName)? )? {   (AccessFeature)*, }

// Elements that may be assigned scopes
AccessFeature :- Visibility | Override

// Declaration visibility. Default is `#module` (aka `internal`)
Visibility :- `visible` : (Scoping, ...)

// Declaration overrides, either by subtyping or overriding a 
// method in a subtype, default is `#module` (aka `internal`)
Override :- `override` : (Scoping, ...)
```

This design was influenced by [SE-0077](https://github.com/apple/swift-evolution/blob/master/proposals/0077-operator-precedence.md). SE-0077 evolved Swift operator precedence syntax to introduce a more flexible and descriptive system. The Swift 3 precedence declaration describes operator qualities, incorporating meta-information about precedence levels, associativity, and assignment use. This `accessgroup` syntax reflects SE-0077's `precedencegroup` keyword and structured meta-information approach.

### Combining Modifiers

Under this proposal, Swift will continue to allow stacked access modifiers like this:

```swift
internal final class ClassName { ... }
```

Upon adoption, you'll be able to stack custom groups as well:

```swift
fileprivate customgroup class ClassName { ... }
```

The custom groups will support setter differentiation:

```swift
public private(set) myvar: T // ok
public customgroup(set) myvar: T // ok
```

#### Stacking Visibility

When stacked, visibility modifiers are additive. To introduce visibility to `CacheClass1` and `CacheClass2` client classes, create a `cacheprivate` access group:

```swift
accessgroup cacheprivate {
    visible: CacheClass1, CacheClass2
}

// stacked accessgroup visibility in declaration
private cacheprivate var importantString: String
```

Alternatively, incorporate private scope into the `cacheprivate ` declaration:

```swift
accessgroup cacheprivate: private {
    // derived visibility from private using `super` keyword
    visible: super, CacheClass1, CacheClass2
}

// Alternatively:
accessgroup cacheprivate {
    visible: #scope, CacheClass1, CacheClass2
}

// direct accessgroup visibility in declaration
cacheprivate var importantString: String
```

#### Stacking Overrides

When stacking overrides, the most restrictive override policy wins. In this example, `importantFunction` can be overridden throughout the file but not the module.

```swift
accessgroup fileoverride {
    override: #file
}

accessgroup moduleoverride {
    override: #module
}

fileoverride moduleoverride func importantFunction() {} 
```

Without this policy, adding `final` would be pointless. Anything stacking a less restrictive override would win.

#### Derived Values

An access group *derived* from another group is rubber-stamped with all those settings. Unless those values are incorporated as `super`, each additional `visible` or `override` declaration completely replaces its parent:

```swift
accessgroup groupAddingProtocol: groupWithoutProtocol {
    access: super, MyProtocol // additive
}

accessgroup groupAddingProtocol: groupWithoutProtocol {
    access: MyProtocol // replacement
}
```

### Diagnostics

The semantics around stacking and inheritance may make some combinations of access groups harder to immediately comprehend than the library-provided access groups. Diagnostics and editor support accommodate this issue by emitting warnings and marking confusing groups. Solutions include:

- Emitting warnings and supplying fix-its on `accessgroup` definitions when a group provides redundant information:
    
    ```swift
    accessgroup customAccess {
        visible: #type, #subtype // warning: Redundant "#type" is already included by "#subtype"
    }
    ```
    
    Warnings should also be emitted for redundancy introduced via inheritance:
    
    ```swift
    accessgroup submoduleAccess: internal {
        visible: super, AnotherType // warning: Redundant "AnotherType" is already included by super
    }
    ```
- Allowing users to option-click a marked `accessgroup` in Xcode to see its resolved visibility and overridability.
- Allowing users to option-click a marked type in Xcode to see its resolved visibility and overridability.

## Future Directions

The following topics should be considered as future directions for access groups.

### Availability

Availability, like visibility, is a meta description on a declaration. `accessgroups` could be extended to add an `available: ...` feature but that is beyond the scope of this proposal.

### Extensibility

It is conceivable that a type author may wish to indicate that a particular type *cannot* be extended. Currently, Swift has the model that all types are extensible. The `accessgroup` syntax provides an affordance for a hypothetical `extend: ...` feature whereby type authors can indicate who is allowed to extend their type.

### Unit Tests

A symbol should not adopt an unnecessarily broad access policy solely to support unit testing. While a separate `#test` scope should not be needed (as it can be fixed through other means), it should be considered as a short-term solution for adding a unit test scope in access groups. 

### Underscored Protocols

In Swift, developers cannot make a `public` type conform to a protocol to access its protocol extensions without making the protocol `public` as well. The core team should consider whether there needs to be a `#compilerpublic` scope that says either "expose this to the compiler for optimizations but don’t show it to anyone else" or maybe "this is usable within the module, but has restricted exposure to the compiler outside of the module". That's just one example; there may be other solutions to this problem.

### Other Meta Attributes

By extending this concept further, `accessgroup` syntax could encompass more or all of the metadata around a type. In the case of methods, this could potentially mean folding in attributes like `@discardableResult` or an `@objc(...)` declaration.

## Source compatibility

This proposal preserves source compatibility.

## Effect on ABI stability

We are not aware of anything in this proposal that would affect ABI stability. There is nothing that changes calling conventions, memory layout, or dynamic features.

## Alternatives considered

[SE-0159](https://github.com/apple/swift-evolution/blob/master/proposals/0159-fix-private-access-levels.md) was rejected because of lack of source compatibility and the feeling of churn for a relatively minor feature.
