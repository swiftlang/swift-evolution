# Improved operator declarations

* Proposal: [SE-0077](0077-operator-precedence.md)
* Author: [Anton Zhilin](https://github.com/Anton3)
* Status: **Active Review: May 17...23**
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

Replace syntax of operator declaration, and replace numerical precedence with partial ordering of operators:

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

[Swift-evolution discussion thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160328/014062.html)

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

### Problems with current operator declaration syntax

Current operator declaration syntax is basically an unstructured bag of words.
This proposal appempts to make it at least partially consistent with other Swift declarations.

## Proposed solution

### Syntax for declaration of operators and groups

Operator declarations no longer have body:

```swift
prefix operator !
infix operator +
```

Precedence groups declare optional associativity (`left` or `right`).
Infix operators can be included in a single precedence group using inheritance-like syntax:

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

Only one declaration of the same operator / precedence group is allowed,
meaning that new precedence relations between existing groups cannot be added.

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

Multiple precedence relationships can be stated for a single precedence group. Example:

```swift
precedencegroup A { }
precedencegroup C { }
precedencegroup B { precedence(> A) precedence(< C) }
```

By transitivity, precedence of C becomes greater than precedence of A.

### Default precedence group

If `infix` operator does not state group that it belongs to, it is assigned to `Default` group, which is defined as follows:

```swift
precedencegroup Default {
  precedence(> Ternary)
}
```

The following two statements are equivalent:

```swift
infix operator |> : Default
infix operator |>
```

## Detailed design

### Precedence

Compiler will represent all precedence groups as a Directed Acyclic Graph.

This will require developers of Swift compiler to solve the problem of [Reachability](https://en.wikipedia.org/wiki/Reachability) and ensure that corresponding algorithm does not have observable impact on compilation time.

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
infix operator ?: : Ternary
infix operator = : Assignment
```

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

Code, which relies on precedence relations of user-defined operators being implicitly defined, may be broken.
This will need to be fixed manually by adding them to desired precedence group.

## Future directions

### Change precedence of the Standard Library operators

Actually, this is one of the main reasons why this proposal was created: break single hierarchy of operators from Standard Library.

This is a draft; actual precedence relationships will be discussed in another proposal.

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

## Alternatives considered

### Use `operator` instead of `precedencegroup`

This would avoid introducing a new keyword.

On the other hand, `precedencegroup` more clearly represents what it declares.
Additionally, `operator` remains a local keyword.

### Define precedence relationships outside of group declarations

```swift
precedencegroup B : associativity(left)
precedencerelation B > A
precedencerelation B < C
infix operator <$> : B
```

Precedence groups are closed in this proposal to discourage recreating a single hierarchy of standard library operators.
This matter is discussable.

### Do not use precedence groups

It would make each operator define precedence relationships.

The graph of relationships would be considerably larger and less understandable in this case.

Precedence groups concept would still be present, but it would make one operator in each group "priveleged":

```swift
precedencerelation - = +
precedencerelation &+ = +
precedencerelation / = *
precedencerelation % = *
precedencerelation * > +
```

### Possible syntax variations

We could use comma instead of parentheses and/or words instead of comparison symbols:

```swift
precedencegroup Comparative {
  associativity: left
  precedence: greater(LogicalAnd)
}
```
