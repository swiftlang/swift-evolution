# Partially constrained protocols and generic types

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Maximilian Hünenberger](https://github.com/Qbyte248)
* Status: **Awaiting review**
* Review manager: TBD


## Introduction

This proposal adds generics to protocols and generic types which can be partially constrained. It can replace `where` clauses in many cases and also allows you to use protocols with associated types as abstract types. Therefore replacing `AnyXXX` types, which are only generic wrappers, as return types.

Swift-evolution thread: [link to the discussion thread for that proposal](https://lists.swift.org/pipermail/swift-evolution)


## Motivation

Currently if you have a protocol with associated types you cannot use it as a "normal" type. Like `SequenceType` it can only be used as generic constraint where you have to use `where` clauses instead of a simple `SequenceType<Int>`.

`Where` clauses on associated types are also disallowed which allows for too much flexibility on types.

For example a node protocol:

```swift
protocol NodeType {
	typealias T
	var element: T { get }
  
 	typealias Node: NodeType // error: Type may not reference itself as a requirement
	var next: Node? { get }
}
```

In this case you cannot model the type of `Node` such that it conforms to `NodeType` and has the same `element` type `T`.


In the standard library there are some `AnyXXX` types. In this case it would be `AnyNode`:

```swift
class AnyNode<T>: NodeType {
	var element: T
	var next: Node<T>?
  
	init<N: NodeType where N.T == T>(node: N) {
		/*  init cannot be implemented since
			N.Node has to have the same requirements
			as N in oder to initialize `next`.
			Therefore introducing a recursive type requirement
			which cannot be resolved.
		*/
	}
}
```

A more practical example like a simple `Sequence`:

```swift
protocol Sequence {
	typealias Element
	typealias SubSequence
	
	var elements: [Element] { get }
	func prefix(n: Int) -> Self.SubSequence
}

extension Sequence {
	func prefix(n: Int) -> AnySequence<Element> {
		return elements.prefix(n)
	}
}
```

Constraining `SubSequence` to `Sequence` doesn't work (recursive type requirement) and it should also have the same `Element` type.


## Proposed solution

Describe your solution to the problem. Provide examples and describe
how they work. Show how your solution is better than current
workarounds: is a cleaner, safer, or more efficient?

We make protocols and generic types in general partially constraint. In addition they can be used as variable type.
For example using the former `NodeType`:

```swift
protocol NodeType {
	typealias T
	var element: T { get }
	
	typealias Node: NodeType<Self.T == T>
	var next: Node? { get } // Self.T is associated to the type of `next`
}
```

It looks much cleaner, it is easier to understand and allows to constrain associated types further. In addition `NodeType<Self.T == T>` is also considered a "normal" type and you can use more specific node types like this:

```swift
var intNode: NodeType<Self.T == Int> = IntNode()
intNode = GenericNode<Int>()

intNode.element // Int
intNode.next 	// is automatically inferred to Optional<GenericNode<Int>.Node>
				// further information on this type inference in "Detailed design"
```

This allows you to program on a more abstract level without having generic wrapper types as return types.


The standard library's `SequenceType` in generic functions:

```swift
// old version which can **still be used**
func sum<S: SequenceType where Generator.Element == Int>(seq: S) -> Int { ... }

// new versions (all are equivalent)
func sum(seq: SequenceType<Self.Generator.Element == Int>) -> Int { ... }
func sum(seq: SequenceType<Self.Generator: GeneratorType<Self.Element == Int>>) -> Int { ... }
```


In case of abstract types like protocols and classes (because of inheritance) you can use both `==` and `:`. The old and new versions below which have the same number are all equivalent.

```swift
protocol P { var value: Int { get } }

// old versions which can **still be used**
/*1*/ func sum<S: SequenceType where Generator.Element == P>(seq: S, value: P) -> Int { ... }
/*2*/ func sum<S: SequenceType where Generator.Element: P>(seq: S) -> Int? { ... }
/*3*/ func sum<T: P, S: SequenceType where Generator.Element == T>(seq: S, value: T) -> Int { ... }

// new versions
/*1*/ func sum(seq: SequenceType<Self.Generator.Element == P>, value: P) -> Int { ... }
/*2*/ func sum(seq: SequenceType<Self.Generator.Element: P>) -> Int? { ... }
/*3*/ func sum<T: P>(seq: SequenceType<Self.Generator.Element == T>, value: T) -> Int { ... }
```

The new versions constrain the generic sequence inside the parameter-clause so the generic-parameter-clause only contains the "real" generic parameter.


## Detailed design

Describe the design of the solution in detail. If it involves new
syntax in the language, show the additions and changes to the Swift
grammar. If it's a new API, show the full API and its documentation
comments detailing what it does. The detail in this section should be
sufficient for someone who is *not* one of the authors to be able to
reasonably implement the feature.


Protocol types can be constrained using "generic-parameter-clauses" after their "type-name" and accessing its associated types with `Self.AssociatedTypeName`.

Unconstrained and `:`-constrained associated types of protocols and generic types are automatically inferred by the compiler (to some extend):

Using current `SequenceType` and `Array` with proposed syntax.

```swift
var sequence: SequenceType<Self.Generator.Element == Int> = [0]
// sequence.dynamicType.Generator == Array<Int>.Generator == IndexingGenerator<Array<Int>>
// sequence.dynamicType.SubSequence == Array<Int>.SubSequence == Slice<Array<Int>>

sequence = Set([1])
// sequence.dynamicType.Generator == Set<Int>.Generator == SetGenerator<Int>
// sequence.dynamicType.SubSequence == Set<Int>.SubSequence == Slice<Set<Int>>


// in case of dynamic control flow like a conditional assignment
if condition {
	sequence = [2]
	// same type as in first assignment
} else {
	sequence = Set([3])
	// same type as in second assignment
}

sequence
// here sequence has the following dynamic type
// sequence.dynamicType.Generator: GeneratorType<Self.Element == Int>
// sequence.dynamicType.SubSequence: Any

var generator: GeneratorType<Self.Element == Int> = sequence.generate()
// `dropFirst` returns `SubSequence` of `sequence` which can be anything (`Any`) at this point
var subsequence: Any = sequence.dropFirst()


// array of sequences
var seqenceArray: Array<Self.Element: SequenceType<Self.Generator.Element == Int>> = [sequence]
// inferred types (note serveral associated types of `sequence` could not be inferred):
// seqenceArray.dynamicType.Generator.Element == SequenceType<Self.Generator.Element == Int>
// seqenceArray.dynamicType.Generator.Element.Generator == Generator<Self.Element == Int>
```

Since constraining a type with `:` is kind of related to covariance and contravariance here an illustration:

```swift
protocol P {
	typealias T: Equatable
	typealias U: P
	func getReturn(value: T) -> U
}
protocol Q0 {}
protocol Q1: Q0 {}

class Q0Class: Q0 {}
class Q1Class: Q1 {}

class A: P { func getReturn(value: Q0Class) -> Q0Class { ... } }
class B: P { func getReturn(value: Q1Class) -> Q1Class { ... } }

var p: P<Self.T: Q0, Self.U: Q0> = A()
// p.dynamicType.T == Q0Class
// p.dynamicType.U == Q0Class

// you are forced to pass P.T which is equal to Q0Class
p.getReturn(Q0Class()) // returns Q0Class()

if condition {
 	p = A()
} else {
 	p = B()
}

// parameter of `p.getReturn` is of type `P.T: Q0` which isn't unambiguously defined (can be Q0Class or Q1Class)
// so this method cannot be called here
p.getReturn(...) // would return Q0
```

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

