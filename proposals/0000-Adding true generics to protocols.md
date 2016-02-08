# Adding true generics to protocols

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Maximilian Hünenberger](https://github.com/Qbyte248)
* Status: **Awaiting review**
* Review manager: TBD


## Introduction

This proposal adds generics to protocols and replaces `where` clauses in many cases. It also allows you to use protocols with associated types as abstract types.

Swift-evolution thread: [link to the discussion thread for that proposal](https://lists.swift.org/pipermail/swift-evolution)


## Motivation

Currently if you have a protocol with associated types you cannot use it as a "normal" type. Like `SequenceType` it can only be used as generic constraint where you have to use `where` clauses instead of a simple `SequenceType<Int>`. This also allows us to remove the `AnyXXX` types which are only generic wrappers.

`Where` clauses on associated types are also disallowed which lets you do more than the protocol would allow normally.
For example a node protocol:

```swift
protocol NodeType {
  associated T
  var element: T { get }
  
  associated Node: NodeType where Node.T == T // where clause prohibited
  var next: Node? { get }
}
```

## Proposed solution

Describe your solution to the problem. Provide examples and describe
how they work. Show how your solution is better than current
workarounds: is a cleaner, safer, or more efficient?

Using the `NodeType` example:

```swift
protocol NodeType {
  associated T
  var element: T { get }
  var next: NodeType<Self.T == T>? { get } // Self.T is associated to the type of `next`
}
```

It looks much cleaner and is easier to understand. In addition `NodeType<Self.T == T>` is considered a "normal" type and you can use more specific node types like this:

```swift
var intNode: NodeType<Self.T == Int> = IntNode()
intNode = GenericNode<Int>()

intNode.element // Int
intNode.next // NodeType<Self.T == Int>
```

`SequenceType` in generic functions:

```swift
// old version which can still be used
func sum<S: SequenceType where Generator.Element == Int>(seq: S) -> Int { ... }

// new version
func sum(seq: SequenceType<Self.Generator.Element == Int>) -> Int { ... }
```

In case of abstract types like protocols you can use both `==` and `:` :

```swift
protocol P {}

// old version which can still be used
func sum<S: SequenceType where Generator.Element == P>(seq: S) -> Int { ... }
func sum<S: SequenceType where Generator.Element: P>(seq: S) -> Int { ... }

// new version
func sum(seq: SequenceType<Self.Generator.Element == P>) -> Int { ... }
func sum(seq: SequenceType<Self.Generator.Element: P>) -> Int { ... }
```

## Detailed design

Describe the design of the solution in detail. If it involves new
syntax in the language, show the additions and changes to the Swift
grammar. If it's a new API, show the full API and its documentation
comments detailing what it does. The detail in this section should be
sufficient for someone who is *not* one of the authors to be able to
reasonably implement the feature.


Associated types of protocols can be constrained by using "generic-argument-clauses" after their type and accessing them with `Self.AssociatedTypeName`.

There is no change in the grammar of Swift since a "generic-argument-clause" after the protocol name is grammarwise allowed. 

## Impact on existing code

Describe the impact this change will have on existing code. Will some
Swift applications stop compiling due to this change? Will applications still
compile but produce different behavior than they used to? Is it
possible to migrate existing Swift code to use a new feature or API
automatically?

Since this proposal is only additional there is no impact on existing code.

## Alternatives considered

Describe alternative approaches to addressing the same problem, and
why you chose this approach instead.

