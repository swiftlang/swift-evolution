# Move `where` clause to end of declaration

* Proposal: [SE-0081](0081-move-where-expression.md)
* Authors: [David Hart](https://github.com/hartbit), [Robert Widmann](https://github.com/CodaFi), [Pyry Jahkola](https://github.com/pyrtsa)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000161.html)
* Bug: [SR-1561](https://bugs.swift.org/browse/SR-1561)

## Introduction

This proposal suggests moving the `where` clause to the end of the declaration syntax, but before the body, for readability reasons. It has been discussed at length on the following swift-evolution thread:

[\[Pitch\] Moving where Clauses Out Of Parameter Lists](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160404/014309.html)

## Motivation

The `where` clause in declarations can become quite long. When that happens, it breaks the declaration syntax in two, hurting its readability. There is also no good way of formatting the declaration syntax to make it much better.

## Proposed solution

The proposal suggests moving the `where` clause at the end of the declaration, but before the body of concerned declarations. With the proposed change, `where` clauses do not impede the main declaration and are also more easily formattable. For example, here is the same function declaration before and after the change:  

``` swift
func anyCommonElements<T : SequenceType, U : SequenceType where
    T.Generator.Element: Equatable,
    T.Generator.Element == U.Generator.Element>(lhs: T, _ rhs: U) -> Bool
{
    ...
}

func anyCommonElements<T : SequenceType, U : SequenceType>(lhs: T, _ rhs: U) -> Bool where
    T.Generator.Element: Equatable,
    T.Generator.Element == U.Generator.Element
{
    ...
}
```

This proposal has no impact on extension declarations with constraints because those declarations already have the `where` clauses right before the body. In that regard, the proposal makes the other declarations more consistent with extension declarations.

## Detailed design

First of all, the grammar of *generic-parameter-clause* is modified to lose the *requirement-clause*:

*generic-parameter-clause* → **<** *­generic-parameter-list­­* **>­**

The grammar of declarations are then amended to gain the *requirement-clause*: 

*function-declaration* → *function-head­* *function-name­* *generic-parameter-clause<sub>­opt</sub>­* *function-signature* *requirement-clause<sub>­opt</sub>* *­function-body<sub>­opt</sub>*

*union-style-enum* → **indirect**­*<sub>­opt</sub>­* **­enum** *­enum-name* *­generic-parameter-clause­<sub>­opt</sub>* ­*type-inheritance-clause­<sub>­opt</sub>*­ *requirement-clause<sub>­opt</sub>* **{** *­union-style-enum-members­<sub>­opt</sub>*­ **}**

*raw-value-style-enum* → **enum** ­*enum-name­* *generic-parameter-clause­<sub>­opt</sub>* *­type-inheritance-clause* *requirement-clause<sub>­opt</sub>* **­{** *­raw-value-style-enum-members­* **}*­*

*struct-declaration* → *attributes­<sub>­opt</sub>* *­access-level-modifier­<sub>­opt</sub>* ­**struct** ­*struct-name* ­*generic-parameter-clause­<sub>­opt</sub>* *­type-inheritance-clause­<sub>­opt</sub>* *requirement-clause<sub>­opt</sub>* *­struct-body­*

*class-declaration* → *attributes­<sub>­opt</sub>* *­access-level-modifier<sub>­opt</sub>* ­**final***<sub>­opt</sub>* ­**class** *­class-name* *­generic-parameter-clause<sub>­opt</sub>* *­type-inheritance-clause<sub>­opt</sub>* *requirement-clause<sub>­opt</sub>* ­*class-body­*

*protocol-method-declaration* → *function-head* *­function-name* *­generic-parameter-clause­<sub>­opt</sub>* *­function-signature­* *requirement-clause<sub>­opt</sub>*

*protocol-initializer-declaration* → *initializer-head* *­generic-parameter-clause­<sub>­opt</sub>* *­parameter-clause* ­**throws­***<sub>­opt</sub>*­ *requirement-clause<sub>­opt</sub>*

*protocol-initializer-declaration* → *initializer-head* *­generic-parameter-clause<sub>­opt</sub>* ­*parameter-clause­* **rethrows­** *requirement-clause<sub>­opt</sub>*

*initializer-declaration* → *initializer-head* *­generic-parameter-clause­<sub>­opt</sub>* ­*parameter-clause* ­**throws***<sub>­opt</sub>* *requirement-clause<sub>­opt</sub>* *­initializer-body­*

*initializer-declaration* → *initializer-head* *­generic-parameter-clause<sub>­opt</sub>* ­*parameter-clause* ­**rethrows** *requirement-clause<sub>­opt</sub>* *­initializer-body­*

## Impact on existing code

This proposal impacts all declarations which contain `where` clauses (except for extension declarations) and will therefore require a Fix-It.

## Alternatives considered

The first post in the swift-evolution thread originally proposed moving the `where` clause just after the generic type declaration. Since then, the original author and many other participants in the thread have agreed that the current proposal is superior.

It was also proposed to remove the simple inheritance constraints from the generic parameter list, but several arguments were brought up that it would complicate declarations of simple generics which only needed inheritance constraints. Moreover, the current proposal allows moving simple constraints in the `where` clause:

```swift
func anyCommonElements<T, U>(lhs: T, _ rhs: U) -> Bool where
    T : SequenceType,
    U : SequenceType,
    T.Generator.Element: Equatable,
    T.Generator.Element == U.Generator.Element
{
    ...
}
```
