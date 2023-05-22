# Tuple of value pack expansion

* Proposal: [SE-0399](0399-tuple-of-value-pack-expansion.md)
* Authors: [Sophia Poirier](https://github.com/sophiapoirier), [Holly Borla](https://github.com/hborla)
* Review Manager: [Xiaodi Wu](https://github.com/xwu)
* Status: **Active review (May 16...29, 2023)**
* Implementation: On `main` gated behind `-enable-experimental-feature VariadicGenerics`
* Previous Proposals: [SE-0393](0393-parameter-packs.md), [SE-0398](0398-variadic-types.md)
* Review: ([pitch](https://forums.swift.org/t/tuple-of-value-pack-expansion/64269)) ([review](https://forums.swift.org/t/se-0399-tuple-of-value-pack-expansion/65017))

## Introduction

Building upon the **Value and Type Parameter Packs** proposal [SE-0393](https://forums.swift.org/t/se-0393-value-and-type-parameter-packs/63859), this proposal enables referencing a tuple value that contains a value pack inside a pack repetition pattern.

## Motivation

When a tuple value contains a value pack, there is no way to reference those pack elements or pass them as a value pack function argument.

Additionally, type parameter packs are only permitted within a function parameter list, tuple element, or generic argument list. This precludes declaring a type parameter pack as a function return type, type alias, or as a local variable type to permit storage. The available solution to these restrictions is to contain the value pack in a tuple, which makes it important to provide full functional parity between value packs and tuple values containing them. This proposal fills that functionality gap by providing a method to reference individual value pack elements contained within a tuple.

## Proposed solution

This proposal extends the functionality of pack repetition patterns to values of _abstract tuple type_, which enables an implicit conversion of an _abstract tuple value_ to its contained value pack. An _abstract tuple type_ is a tuple that has an unknown length and elements of unknown types. Its elements are that of a single type parameter pack and no additional elements, and no label. In other words, the elements of the type parameter pack are the elements of the tuple. An _abstract tuple value_ is a value of _abstract tuple type_. This proposal provides methods to individually access the dynamic pack elements of an abstract tuple value inside of a repetition pattern.

The following example demonstrates how, with this proposal, we can individually reference and make use of the elements in an abstract tuple value that was returned from another function. The example also highlights some constructs that are not permitted under this proposal:

```swift
func tuplify<each T>(_ value: repeat each T) -> (repeat each T) {
  return (repeat each value)
}

func example<each T>(_ value: repeat each T) {
  let abstractTuple = tuplify(repeat each value)
  repeat print(each abstractTuple) // okay as of this proposal

  let concreteTuple = (true, "two", 3)
  repeat print(each concreteTuple) // invalid

  let mixedConcreteAndAbstractTuple = (1, repeat each value)
  repeat print(each mixedConcreteAndAbstractTuple) // invalid

  let labeledAbstractTuple = (label: repeat each value)
  repeat print(each labeledAbstractTuple) // invalid
}
```

### Distinction between tuple values and value packs

The following example demonstrates a pack repetition pattern on a value pack and an abstract tuple value separately first, then together but with the repetition pattern operating only on the value pack, and finally with the repetition pattern operating on both the value pack and the tuple value's contained value pack together interleaved. Note that, because the standard library function `print` does not currently accept parameter packs but instead only a single value parameter, all of the calls to it wrap the value argument pack in a tuple (hence all of those parentheses).

```swift
func example<each T>(packElements value: repeat each T, tuple: (repeat each T)) {
  print((repeat each value))
  print((repeat each tuple))
  
  print((repeat (each value, tuple)))
  
  print((repeat (each value, each tuple)))
}

example(packElements: 1, 2, 3, tuple: (4, 5, 6))

// Prints the following output:
// (1, 2, 3)
// (4, 5, 6)
// ((1, (4, 5, 6)), (2, (4, 5, 6)), (3, (4, 5, 6)))
// ((1, 4), (2, 5), (3, 6))
```

## Detailed design

Pack reference expressions inside a repetition pattern can have abstract tuple type. The outer structure of the tuple is removed, leaving the elements of a value pack:

```swift
func expand<each T>(value: (repeat each T)) -> (repeat (each T)?) {
  return (repeat each value)
}
```

Applying the pack repetition pattern effectively removes the outer structure of the tuple leaving just the value pack. In the repetition expression, the base tuple is evaluated once before iterating over its elements.

```swift
repeat each <tuple expression>

// the above is evaluated like this
let tempTuple = <tuple expression>
repeat each tempTuple
```

## Source compatibility

There is no source compatibility impact given that this is an additive change. It enables compiling code that previously would not compile.

## ABI compatibility

This proposal does not add or affect ABI as its impact is only on expressions. It does not change external declarations or types. It rests atop the ABI introduced in the **Value and Type Parameter Packs** proposal.

## Implications on adoption

Given that this change rests atop the ABI introduced in the **Value and Type Parameter Packs** proposal, this shares with it the same runtime back-deployment story.

## Alternatives considered

An earlier design required the use of an abstract tuple value expansion operator, in the form of `.element` (effectively a synthesized label for the value pack contained within the abstract tuple value). This proposal already requires a tuple with a single element that is a value pack, so it is unnecessary to explicitly call out that the expansion is occurring on that element. Requiring `.element` could also introduce potential source breakage in the case of existing code that contains a tuple using the label "element". Dropping the `.element` requirement averts the language inconsistency of designating a reserved tuple label that functions differently than any other tuple label.

## Future directions

### Repetition patterns for concrete tuples

It could help unify language features to extend the repetition pattern syntax to tuples of concrete type.

```swift
func example<each T>(_ value: repeat each T) {
  let abstractTuple = (repeat each value)
  let concreteTuple = (true, "two", 3)
  repeat print(each abstractTuple)
  repeat print(each concreteTuple) // currently invalid
}
```

### Pack repetition patterns for arrays

If all elements in a type argument pack are the same or share a conformance, then it should be possible to declare an Array value using a value pack.

### Lift the single value pack with no label restriction

This would be required to enable pack repetition patterns for a contained value pack amongst arbitrary other tuple elements that could be addressable via their labels.
