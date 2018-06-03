# Reconsider how type aliases are used within protocols and their extensions

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: Awaiting implementation

## Introduction

This proposal encourages to change the grammar of using type aliases within protocols and their extensions to be consistent relative to the language.

[Swift-evolution pitch thread](https://forums.swift.org/t/disallow-type-aliases-in-protocols/11965?u=anthonylatsis)

## Motivation

The ability to declare type aliases that share names with associated types in protocols and protocol extensions
has been a workaround for same-type constraints in protocol declarations, introduced together with [SE-0142](https://github.com/apple/swift-evolution/blob/master/proposals/0142-associated-types-constraints.md) in **Swift 4**.

Here, the declaration of a `typealias` that shares its name with an `associatedtype` is tantamount to a same-type constraint
that is syntactically and semantically inconsistent with the language. This feature violates the rule that declarations
in a protocol extension should never conflict with its requirements (the `typealias` does not act as a default value) and
introduces counterproductive situations that often have no practical value and are hard to judge and assess. 

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
A further contradiction is seen with the convention of leaving out any implementation details within a protocol body:
those are ought to be described in an extension or upon conformance.

### Type aliases in extensions
Currently a `typealias` in a protocol extension that conflicts with an `associatedtype` is treated as a same-type constraint on the associatedtype **if** there are no appliances of the type name **among the requirements**. Example:

```swift
protocol P {associatedtype A}
extension P {typealias A = Int} // same-type constraint on A.
```

If there **is** an appliance of `A`, an error occurs:

```swift
protocol P {
  associatedtype A
  func foo() -> A // 'A' is ambiguous for type lookup in this context
}
extension P {typealias A = Int}
```

This is inconsistent with the behavior of any other implementation details declared in protocol extensions, which become defaults. The fact that an appliance generates an error is either a bug or proof that the rules aren't solid and conflict with the language on the implementation level.

## Proposed solution

**Swift 4.1** began preparations to eliminate the feature by adding certain warnings and conditionally disallowing such type aliases in protocol extensions by raising a `type look up ambiguity` error towards appliances of the conflicting type name, if any.

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
### Solution
Having introduced powerful and expressive where clauses for protocol declarations,
I propose to bring consistency to the usage of type aliases within protocols and protocol extensions.

* [Type aliases in protocol extensions](#type-aliases-in-protocol-extensions). There are two options:
    * Permit type aliases to act as default values for associated types in protocol extensions. This is the preferred solution. 
    * Change the error message to propose the current syntax instead of simply producing **#3**,
    which is actually a generic error.
* Type aliases in protocols should be always discouraged in **Swift 4.2** and always disallowed in **Swift 5**,
  the same way we disallow any implementation details.
* Warning **#1** should become an error in **Swift 5**; in the case when the warning is not produced,
  emit a generic `typealias should not be declared within a protocol` warning for **Swift 4.2** and error for **Swift 5**.
* Warning **#2** should be superseded by the `typealias should/must not be declared within a protocol` warning/error in **Swift 4.2** and **Swift 5** respectively.

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
### Type aliases in protocol extensions
The benign second options stated under [Solution](#solution) will not break source, but will remain a contradictory case on the background of the proposed changes and in constrast to established language rules.

The first case, however, is just as harmless: switching from same-type constraints to default values is source breaking **neither** in the case when there are no appliances of the `associatedtype` among the requirements, nor when there are: it relaxes an existing error.

## Source compatibility

Only **Swift 5** mode will produce compile-time errors if any of the proposed changes are violated.
**Swift 4.2** will receive warnings for compatibility. 
Automatic migration is possible.

## Effect on ABI stability

This proposal changes some rules but doesn't affect any runtime language features.
Likely it doesn't change existing ABI.
