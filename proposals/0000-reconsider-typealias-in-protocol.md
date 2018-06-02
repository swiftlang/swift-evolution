# Reconsider how type aliases are used within protocols and their extensions

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: Awaiting implementation

## Introduction

This proposal encourages to bring consistency to the grammar of using type aliases within protocols and their extensions.

[Swift-evolution pitch thread](https://forums.swift.org/t/disallow-type-aliases-in-protocols/11965?u=anthonylatsis)

## Motivation

The ability to declare type aliases that share names with associated types in protocols and protocol extensions
has been a workaround for same-type constraints in protocol declarations, introduced in **Swift 4** ([SE-0142](https://github.com/apple/swift-evolution/blob/master/proposals/0142-associated-types-constraints.md)).

Here, the declaration of a `typealias` that shares its name with an `associatedtype` is tantamount to a same-type constraint
that is syntactically and semantically inconsistent with the language. This feature violates the rule that declarations
in a protocol extension should never conflict with its requirements (the type alias does not act as a default value) and
introduces counterproductive situations that often have no practical value and are thus hard to judge and assess. 

```swift
protocol P {
    associatedtype E
    func foo(_ arg: E)
}
protocol P1: P {...} 

class Foo: P {
    typealias E = String

    func foo(_ arg: E) {}
}
// This will break Foo and any other conformances to P and its descendants. 
extension P { typealias E = Bool } 
```
This feature is further inconsistent with the convention of not having any implementation details within a protocol body.
Those are described in an extension or upon conformance.

## Proposed solution

**Swift 4.1** began preparations to eliminate the feature by adding warnings and disallowing such type aliases in protocol
extensions by raising a `type look up ambiguity` error towards appliances of the conflicting type name:

#### `#1`
```swift
protocol P {associatedtype A}
protocol P1: P {typealias A = Int}
// warning: typealias overriding associated type 'R' from protocol 'P' is better expressed as same-type constraint on the protocol
```
#### `#2`
```swift
protocol P {typealias A = Int}
protocol P1: P {associatedtype A}
// warning: associated type 'R' is redundant with type 'R' declared in inherited protocol 'P'
```
#### `#3`
```swift
protocol P {
  associatedtype A
  func foo() -> A // error: 'A' is ambiguous for type lookup in this context
}
extension P {typealias A = Int}
```

Now that we have powerful enough where clauses for protocol declarations,
I propose to bring consistency to the usage type aliases within protocols and protocol extensions:

* Permit type aliases to act as default values for associated types in protocol extensions **or** change the error message
  to propose the current syntax instead of simply producing **#3**, which is actually a generic error.
* Type aliases in protocols should be always discouraged in **Swift 4.2** and always disallowed in **Swift 5**,
  the same way we disallow any implementation details.
* Warning **#1** must become an error in **Swift 5**; in the case when the warning is not produced,
  emit a generic `typealias should not be declared within a protocol` warning for **Swift 4.2** and error for **Swift 5**.
* Warning **#2** must be superseded by the `typealias must not be declared within a protocol` error in **Swift 5**.

## Detailed design

#### Non-conflicting type alias in protocol
```swift
protocol P {
 typealias A = Int // fixit: typealias -> associatedtype
 /// Swift 4.2
 /// warning: type alias should not be declared within a protocol;
 /// move to an extension or use 'associatedtype' to define an associated type requirement 
 /// Swift 5
 /// error: type alias must not be declared within a protocol;
 /// move to an extension or use 'associatedtype' to define an associated type requirement
}
```
#### Type alias conflicting with inherited associated type

```swift
protocol P {associatedtype A}
protocol P1: P {
  typealias A = Int
  /// Swift 5
  /// error: typealias must not be declared within a protocol;
  /// use 'associatedtype' to specify a default value for 'A' from protocol 'P' or a same-type constraint on the protocol.
}
```

## Source compatibility

Only **Swift 5** mode will produce compile-time errors if any of the proposed changes are violated.
**Swift 4.2** will receive warnings for compatibility. 
Automatic migration is possible.

## Effect on ABI stability

This proposal changes some rules but doesn't affect any runtime language features.
Likely it doesn't change existing ABI.
