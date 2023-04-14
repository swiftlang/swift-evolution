# Tuple of value pack expansion

* Proposal: [SE-NNNN](nnnn-tuple-of-value-pack-expansion.md)
* Authors: [Sophia Poirier](https://github.com/sophiapoirier), [Holly Borla](https://github.com/hborla)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Upcoming Feature Flag: `VariadicGenerics`
* Previous Proposal: [SE-0393](0393-parameter-packs.md)

## Introduction

Building upon the **Value and Type Parameter Packs** proposal [SE-0393](https://forums.swift.org/t/se-0393-value-and-type-parameter-packs/63859), this proposal enables referencing a tuple value that contains a value pack inside a pack repetition pattern.

## Motivation

When a tuple value contains a value pack, there is no way to reference those pack elements or pass them as a value pack function argument.

Additionally, type parameter packs are only permitted within a function parameter list, tuple element, or generic argument list. This precludes declaring a type parameter pack as a function return type, type alias, or as a local variable type to permit storage. The available solution to these restrictions is to contain the value pack in a tuple, which makes it important to provide full functional parity between value packs and tuple values containing them. This proposal fills that functionality gap by providing a method to reference individual value pack elements contained within a tuple.

## Proposed solution

This proposal extends the functionality of pack repetition patterns to values of _abstract tuple type_, which enables an implicit conversion of an _abstract tuple value_ to its contained value pack. An _abstract tuple type_ is a tuple that has an unknown length and elements of unknown types. Its elements are that of a single type parameter pack and no additional elements, and no label. In other words, the elements of the type parameter pack are the elements of the tuple. An _abstract tuple value_ is a value of _abstract tuple type_. This proposal provides methods to individually access the dynamic pack elements of an abstract tuple value inside of a repetition pattern.

### Distinction between tuple values and value packs

The following example demonstrates a pack repetition pattern on a value pack and an abstract tuple value separately first, then together but with the repetition pattern operating only on the value pack, and finally with the repetition pattern operating on both the value pack and the tuple value's contained value pack together interleaved.

```swift
func example<each U>(packElements value: repeat each U, tuple: (repeat each U)) {
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
TODO: is this example actually informative or illustrative?

## Source compatibility

There is no source compatibility impact given that this is an additive change. It enables compiling code that previously would not compile.

## ABI compatibility

This proposal does not add or affect ABI as its impact is only on expressions. It does not change external declarations or types. It rests atop the ABI introduced in the **Value and Type Parameter Packs** proposal.

## Implications on adoption

Given that this change rests atop the ABI introduced in the **Value and Type Parameter Packs** proposal, this shares with it the same runtime back-deployment story.

## Alternatives considered

The **Value and Type Parameter Packs** proposal provides no means for declaring local variable value packs or stored property packs. This is mentioned as a potential future direction, but without that, containing the packs within tuples is the way to access such functionality. Therefore an alternative to this proposal would be to instead pursue those future directions instead. However that would only partially address the motivations for this proposal, still leaving a broader pack repetition pattern design needed for abstract tuples.

## Future directions

* Repetition patterns for concrete tuples
* Pack repetition patterns for arrays containing a value pack where all pack elements are of the same type
* Lifting the restriction that a tuple containing a value pack must contain only the single value pack and use no label. This would be required to enable pack repetition patterns for a contained value pack amongst arbitrary other tuple elements, addressable via a label.
