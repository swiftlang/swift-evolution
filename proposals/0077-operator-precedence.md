# Improved operator declarations

* Proposal: [SE-0077](0077-operator-precedence.md)
* Author: [Anton Zhilin](https://github.com/Anton3)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Replace syntax of operator definition, and replace numerical precedence with partial ordering of operators:

```swift
// Before
infix operator <> { precedence 100 associativity left }

// After
precedencegroup Comparative {
  associativity(left)
  precedence(> LogicalAnd)
}
infix operator <> : Comparative
```

Swift-evolution thread: [link to the discussion thread for that proposal](https://lists.swift.org/pipermail/swift-evolution)

## Motivation

### Problems with numeric definition of precedence

In the beginning, operators had nice precedence values: 90, 100, 110, 120, 130, 140, 150, 160.

As time went, new and new operators were introduced.
Precedence could not be simply changed, as this would be a breaking change.
Ranges got precedence 135, `as` got precedence 132.
`??` had precedence greater than `<`, but less than `as`, so it had to be given precedence 131.

Now it is not possible to insert any custom operator between `<` and `??`.
It is an inevitable consequence of current design: it will be impossible to insert an operator between two existing ones at some point.

### Problems with a single precedence hierarchy

Currently, if an operator needs to define precedence by comparison to one operator, it must do so for all other operators.

In many cases, this is undesirable. For example, `a & b < c` and `a / b as Double` are common error patterns. C++ compilers sometimes emit warnings on these, but Swift does not.

The root of the problem is that precedence is currently defined for any pair of operators.
If `&` had its precedence defined only in relation to other bitwise operators and `/` – only to arithmetic operators, we would have to use parentheses in the preceding examples. This would avoid subtle bugs.

### Problems with current operator definition syntax

Current operator definition syntax is basically an unstructured bag of words.
Such definitions are not used anywhere else in Swift.
I attempt to make it at least partially consistent with other Swift declarations.

## Proposed solution

### Syntax for definitions of operators and groups

Operator declarations no longer have body:

```swift
prefix operator !
infix operator +
```

Precedence groups declare optional associativity (`left` or `right`).
Infix operators declare their precedence groups at definition using inheritance-like syntax:

```swift
precedencegroup Additive {
  associativity(left)
  precedence(> Comparative)  // explained below
}

infix operator + : Additive
infix operator - : Additive
```

### Precedence mechanism

Concept of a single precedence hierarchy is removed.
Instead, to omit parentheses in expression with two neighbouring `infix` operators, precedence relation *must* be defined between their precedence groups.

It is performed by placing `precedence(RELATION OTHER_GROUP_NAME)` inside body of our precedence group,
where `RELATION` is one of `<`, `=`, `>`. Example:

```swift
precedencegroup Additive {
  associativity(left)
}
precedencegroup Multiplicative {
  associativity(left)
  precedence(> Additive)
}
precedencegroup BitwiseAnd {
  associativity(left)
}
infix operator + : Additive
infix operator * : Multiplicative
infix operator & : BitwiseAnd

1 + 2 * 3  // ok, precedence of * is greater than precedence of +
1 + 2 & 3  // error, precedence between + and & is not defined
```

Precedence equality can only be defined for precedence groups with same associativity.

### Transitive precedence propagation

Compiler will apply transitivity axiom to compare precedence of two given precedence groups. Example:

```swift
// take the previous example and change BitwiseAnd
precedencegroup BitwiseAnd {
  associativity(left)
  precedence(< Additive)
}
1 * 2 & 3
```

Here, `Multiplicative > Additive` and `BitwiseAnd < Additive` imply `Multiplicative > BitwiseAnd`.

Compiler will also check that all precedence relations are transitive. If we define `A < B`, `B < C` and `A > C`, it will be a compilation error.

### Default precedence group

If `infix` operator does not state group that it belongs to, it is assigned to `Default` group, which is defined as follows:

```swift
precedencegroup Default {
  precedence(> Ternary)
}
```

So the following two statements are equivalent:

```swift
infix operator |> : Default
infix operator |>
```

### Avoiding conflicts

No such mechanism is proposed currently, meaning that operators and precedence groups can only be defined once.

The only mechanisms to interact with existing precedence groups is adding new operators to them and declaring precedence relation between it and a new precedence group.

## Detailed design

### Precedence

Compiler will represent all precedence groups as a Directed Acyclic Graph.

This would require developers of Swift compiler to solve the problem of [Reachability](https://en.wikipedia.org/wiki/Reachability) and ensure that corresponding algorithm does not have observable impact on compilation time.

### Special operators

Built-ins `is`, `as`, `as?`, `as!`, `=`, `?:` have stated precedence, but cannot be declared using Swift syntax.

They will be hardcoded in the compiler and assigned to appropriate precedence groups,
**as if** the following declarations took place:

```swift
// NOT valid Swift
infix operator is : Cast
infix operator as : Cast
infix operator as? : Cast
infix operator as! : Cast
ternary operator ?: : Ternary
infix operator = : Assignment
```

Built-ins `&` (as a prefix operator), `->`, `?`, and `!` (as a postfix operator) are explicitly excluded
from possible Swift operators. Precedence is not applicable to their built-in operator-like usage.

### Grammar

`precedencegroup` keyword will be added. `assignment` local keyword will be removed.

*operator-declaration* → *prefix-operator-declaration* | *postfix-operator-declaration* | *infix-operator-declaration*

*prefix-operator-declaration* → `prefix` `operator` *operator*

*postfix-operator-declaration* → `postfix` `operator` *operator*

*infix-operator-declaration* → `infix` `operator` *operator* *infix-operator-group<sub>opt</sub>*

*infix-operator-group* → `:` *precedence-group-name*

*precedence-group-declaration* → `precedencegroup` *precedence-group-name* `{` *precedence-group-attributes* `}`

*precedence-group-attributes* → *precedence-group-associativity<sub>opt</sub>*
*precedence-group-relations<sub>opt</sub>*

*precedence-group-associativity* → `associativity` `(` *precedence-group-associativity-option* `)`

*precedence-group-associativity-option* → `left` | `right`

*precedence-group-relations* → *precedence-group-relation* | *precedence-group-relation* *precedence-group-relations*

*precedence-group-relation* → `precedence` `(` *precedence-group-relation-option* *precedence-group-name* `)`

*precedence-group-relation-option* → `<` | `>` | `=`

*precedence-group-name* → *identifier*

### Standard library changes

```swift
prefix operator !
prefix operator ~
prefix operator +
prefix operator -

precedencegroup Assignment {
}
precedencegroup Ternary {
  associativity(right)
  precedence(> Assignment)
}
precedencegroup Default {
  precedence(> Ternary)
}
precedencegroup LogicalOr {
  associativity(left)
  precedence(> Ternary)
}
precedencegroup LogicalAnd {
  associativity(left)
  precedence(> LogicalOr)
}
precedencegroup Comparative {
  associativity(left)
  precedence(> LogicalAnd)
}
precedencegroup NilCoalescing {
  associativity(right)
  precedence(> Comparative)
}
precedencegroup Cast {
  associativity(left)
  precedence(> NilCoalescing)
}
precedencegroup Range {
  precedence(> Cast)
}
precedencegroup Additive {
  associativity(left)
  precedence(> Range)
}
precedencegroup Multiplicative {
  associativity(left)
  precedence(> Additive)
}
precedencegroup BitwiseShift {
  precedence(> Multiplicative)
}

infix operator *= : Assignment
infix operator /= : Assignment
infix operator %= : Assignment
infix operator += : Assignment
infix operator -= : Assignment
infix operator <<= : Assignment
infix operator >>= : Assignment
infix operator &= : Assignment
infix operator ^= : Assignment
infix operator |= : Assignment
infix operator &&= : Assignment
infix operator ||= : Assignment

infix operator && : LogicalAnd
infix operator || : LogicalOr

infix operator < : Comparative
infix operator <= : Comparative
infix operator > : Comparative
infix operator >= : Comparative
infix operator == : Comparative
infix operator != : Comparative
infix operator === : Comparative
infix operator ~= : Comparative

infix operator ?? : NilCoalescing

infix operator ..< : Range
infix operator ... : Range

infix operator + : Additive
infix operator - : Additive
infix operator &+ : Additive
infix operator &- : Additive
infix operator | : Additive
infix operator ^ : Additive

infix operator * : Multiplicative
infix operator / : Multiplicative
infix operator % : Multiplicative
infix operator &* : Multiplicative
infix operator & : Multiplicative

infix operator << : BitwiseShift
infix operator >> : BitwiseShift
```

## Impact on existing code

Standard library operator declarations will be rewritten, and precedence groups will be added.

User defined operators will need to be rewritten as well.
Migration tool will remove bodies of operator declarations. `infix` operators will be implicitly added to `Default` group.

More importantly, some code may rely on precedence rules being removed.
No automatic conversion for these cases is suggested, because they might represent existing bugs.

## Future directions

### Change precedence of the Standard Library operators

Actually, this is one of the main reasons why this proposal was created: break single hierarchy of operators from Standard Library.

```swift
prefix operator !
prefix operator ~
prefix operator +
prefix operator -

precedencegroup Assignment {
}
precedencegroup Ternary {
  precedence(> Assignment)
}
precedencegroup Default {
  precedence(> Ternary)
}

precedencegroup LogicalOr {
  associativity(left)
  precedence(> Ternary)
}
precedencegroup LogicalAnd {
  associativity(left)
  precedence(> LogicalOr)
}
precedencegroup Comparative {
  precedence(> LogicalAnd)
}

precedencegroup NilCoalescing {
  associativity(right)
  precedence(> Comparative)
}
precedencegroup Cast {
  associativity(left)
  precedence(> Comparative)
}
precedencegroup Range {
  precedence(> Comparative)
}

precedencegroup Additive {
  associativity(left)
  precedence(> Comparative)
}
precedencegroup Multiplicative {
  associativity(left)
  precedence(> Additive)
}

precedencegroup BitwiseOr {
  associativity(left)
  precedence(> Comparative)
}
precedencegroup BitwiseXor {
  associativity(left)
  precedence(> Comparative)
}
precedencegroup BitwiseAnd {
  associativity(left)
  precedence(> BitwiseOr)
}
precedencegroup BitwiseShift {
  members(<<, >>)
  precedence(> Comparative)
}

infix operator + : Additive
infix operator - : Additive
infix operator &+ : Additive
infix operator &- : Additive

infix operator * : Multiplicative
infix operator / : Multiplicative
infix operator % : Multiplicative
infix operator &* : Multiplicative

infix operator << : BitwiseShift
infix operator >> : BitwiseShift

infix operator | : BitwiseOr
infix operator ^ : BitwiseXor
infix operator & : BitwiseAnd

infix operator ..< : Range
infix operator ... : Range

infix operator ?? : NilCoalescing

infix operator < : Comparative
infix operator <= : Comparative
infix operator > : Comparative
infix operator >= : Comparative
infix operator == : Comparative
infix operator != : Comparative
infix operator === : Comparative
infix operator ~= : Comparative

infix operator && : LogicalAnd
infix operator || : LogicalOr

infix operator *= : Assignment
infix operator /= : Assignment
infix operator %= : Assignment
infix operator += : Assignment
infix operator -= : Assignment
infix operator <<= : Assignment
infix operator >>= : Assignment
infix operator &= : Assignment
infix operator ^= : Assignment
infix operator |= : Assignment
infix operator &&= : Assignment
infix operator ||= : Assignment
```
