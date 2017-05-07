# Permit where clauses to constrain associated types

* Proposal: [SE-0142](0142-associated-types-constraints.md)
* Authors: [David Hart](https://github.com/hartbit), [Jacob Bandes-Storch](https://github.com/jtbandes), [Doug Gregor](https://github.com/DougGregor)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 4)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161003/027606.html)
* Bugs: [SR-4506](https://bugs.swift.org/browse/SR-4506)

## Introduction

This proposal seeks to introduce a `where` clause to associated type
declarations and improvements to protocol constraints to bring associated types
the same expressive power as generic type parameters.

This proposal was discussed twice on the Swift Evolution list in the following
threads:

* [\[Completing Generics\] Arbitrary requirements in protocols](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160411/014667.html)
* [Proposal] More Powerful Constraints for Associated Types
  - [Week #1](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160418/015625.html)
  - [Week #2](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160425/015753.html)
  - [Week #3](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160502/016354.html)

## Motivation

Currently, associated type declarations can only express simple inheritance
constraints and not the more sophisticated constraints available to generic
types with the `where` clause. Some designs, including many in the Standard
Library, require more powerful constraints for associated types to be truly
elegant. For example, the `SequenceType` protocol could be declared as follows
if the current proposal was accepted:

```swift
protocol Sequence {
    associatedtype Iterator : IteratorProtocol
    associatedtype SubSequence : Sequence where SubSequence.Iterator.Element == Iterator.Element
    ...
}
```

## Detailed Design

First of all, this proposal modifies the grammar for a protocol's associated types
to the following:

*protocol-associated-type-declaration* →
	*attributes<sub>opt</sub>*
	*access-level-modifier<sub>opt</sub>*
	**associatedtype**
	*typealias-name*
	­*type-inheritance-clause­<sub>opt</sub>*
	*typealias-assignment­<sub>opt</sub>*
	*requirement-clause<sub>opt</sub>*

The new requirement-clause is then used by the compiler to validate the
associated types of conforming types.

Secondly, the proposal also allows protocols to use the associated types of
their conforming protocols in their declaration `where` clause as below:

```swift
protocol IntSequence : Sequence where Iterator.Element == Int {
    ...
}
```

Name lookup semantics in the protocol declaration `where` clause only looks at
associated types in the parent protocols. For example, the following code would
cause an error:

```swift
protocol SomeSequence : Sequence where Counter : SomeProtocol { // error: Use of undefined associated type 'Counter'
    associatedtype Counter
}
```

But instead should be written on the associated type itself:

```swift
protocol IntSequence : Sequence {
    associatedtype Counter : SomeProtocol
}
```
 
## Effect on ABI Stability

As mentioned previously, there are a number of places in the standard library where this feature would be adopted (such as the `SubSequence.Iterator.Element == Iterator.Element` example), each of which will change the mangling of any generic function/type that makes use of them.

## Alternatives

Douglas Gregor argues that the proposed syntax is redundant when adding new
constraints to an associated type declared in a parent protocol and proposes
another syntax: 

```swift
protocol Collection : Sequence {
    where SubSequence : Collection
}
```

But as Douglas notes himself, that syntax is ambiguous since we adopted the
generic `where` clause at the end of declarations of the following proposal:
[SE-0081: Move where clause to end of declaration](https://github.com/apple/swift-evolution/blob/master/proposals/0081-move-where-expression.md). For those reasons, it might be wiser not to introduce the shorthand syntax.
 
## Acknowledgements

Thanks to Dave Abrahams and Douglas Gregor for taking the time to help me
through this proposal.
