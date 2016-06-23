# Improved operator declarations

* Proposal: [SE-0077](0077-operator-precedence.md)
* Author: [Anton Zhilin](https://github.com/Anton3)
* Status: **Under revision** ([Rationale](#rationale))
* Review manager: [Joe Groff](http://github.com/jckarter)

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
Instead, to omit parentheses in expression with two neighbouring `infix` operators, precedence relationship *must* be defined between their precedence groups.

It is performed by placing `precedence(RELATION OTHER_GROUP_NAME)` inside body of our precedence group,
where `RELATION` is `<` or `>`. Example:

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
meaning that new precedence relationships between existing groups cannot be added.

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

Compiler will also check that all precedence relationships are transitive. If we define `A < B`, `B < C` and `A > C`, it will be a compilation error.

Multiple precedence relationships can be stated for a single precedence group. Example:

```swift
precedencegroup A { }
precedencegroup C { }
precedencegroup B { precedence(> A) precedence(< C) }
```

By transitivity, precedence of C becomes greater than precedence of A.

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

### Joining unrelated precedence groups

Precedence relationships that, by transitivity rule, create relationship between two imported groups, is an error. Example:

```swift
// Module X
precedencegroup A { }
precedencegroup C { }

// Module Y
import X
precedencegroup B { precedence(> A) precedence(< C) }
```

This results in *compilation error* "B uses transitivity to define relationship between imported groups A and C".
The rationale behind this is that otherwise one can create relationships between standard precedence groups that are confusing for the reader.

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

*precedence-group-relation-option* → `<` | `>`

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

// infix operator = : Assignment
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

// infix operator ?: : Ternary

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

// infix operator as : Cast
// infix operator as? : Cast
// infix operator as! : Cast
// infix operator is : Cast

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
  associativity(right)
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

// infix operator as : Cast
// infix operator as? : Cast
// infix operator as! : Cast
// infix operator is : Cast

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

// infix operator ?: : Ternary

// infix operator = : Assignment
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

On the other hand, `precedencegroup` or `precedence` more clearly represent what they declare.
Additionally, `operator` remains a local keyword.

### Declare associativity and precedence separately

```swift
associativity Multiplicative left
precedence Multiplicative > Additive
precedence Exponentiative > Multiplicative
```

Appearence of precedence group name in any of these "declarations" would mean declaration of the precedence group.
Precedence relationship declaration would only allow `>` sign for consistency.

Limitations on connecting unrelated imported groups could still hold.

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

Instead of `above` and `below`, there could be:
- `upper` and `lower`
- `greaterThan` and `lessThan`
- `gt` and `lt`
- `before` and `after`

Instead of `associativity`, there could be `associate`.

```swift
// Syntax used throughout this proposal
precedencegroup Multiplicative {
  associativity(left)
  precedence(> Additive)
  precedence(< Exponentiative)
}
```

```swift
precedencegroup Multiplicative {
  associativity: left
  precedence: above(Additive)
  precedence: below(Exponentiative)
}
```

```swift
precedence Multiplicative {
  associativity(left)
  above(Additive)
  below(Exponentiative)
}
```

```swift
precedence Multiplicative {
  associativity: left,
  above: Additive,
  below: Exponentiative
}
```

```swift
precedence Multiplicative {
  associativity left
  above Additive
  below Exponentiative
}
```

```swift
precedence Multiplicative {
  associativity left
  > Additive
  < Exponentiative
}
```

```swift
precedence Multiplicative : associativity(left), above(Additive), below(Exponentiative)
```

```swift
precedence Multiplicative : associativity left, above Additive, below Exponentiative
```

```swift
precedence Multiplicative > Additive, < Exponentiative, associativity left
```

```swift
precedence left Multiplicative > Additive, < Exponentiative
```

```swift
precedence associativity(left) Multiplicative > Additive, < Exponentiative
```

```swift
// Only `>` relationships, associativity goes last
precedence Multiplicative : Additive, left

// Full syntax for complex cases
precedence Multiplicative {
  associativity left
  above Additive
  below Exponentiative
}
```

```swift
// Only `>` relationships, associativity goes last
precedence Multiplicative > Additive, left

// Full syntax for complex cases
precedence Multiplicative {
  associativity left
  > Additive
  < Exponentiative
}
```

## Note for review

Swift Core team is supposed to make a decision on syntax of precedence groups declarations.
It may be from "Alternatives considered" variants, modifications of them, or any different syntax.

During review on swift-evolution, many participants showed preference to the following one:

```swift
precedence Multiplicative {
  associativity left
  above Additive
  below Exponentiative
}
```

Or its slightly modified forms.

-------------------------------------------------------------------------------

# Rationale

On June 22, 2016, the core team decided to **return** the first version of this
proposal for revision. The core design proposed is a clear win over the Swift 2
design, but feels that revisions are necessary for usability and consistency
with the rest of the language:

- The proposed `associativity(left)` and `precedence(<)` syntax for precedence
  group attributes doesn't have a precedent elsewhere in Swift. Furthermore,
  it isn't clear which relationship `<` and `>` correspond to in the `precedence`
  syntax. The core team feels that it's more in the character of Swift to use
  colon-separated "key-value" syntax, with `associativity`, `strongerThan`,
  and `weakerThan` keyword labels:

    ```swift
    precedencegroup Foo {
      associativity: left
      strongerThan: Bar
      weakerThan: Bas
    }
    ```

- If "stronger" and "weaker" relationships are both allowed, that would
  enable different code to express precedence relationships in different,
  potentially confusing ways. To promote consistency and clarity, the
  core team recommends the following restriction: Relationships between
  precedence groups defined within the same module must be expressed
  **exclusively** in terms of `strongerThan`. `weakerThan` can only be
  used to extend the precedence graph relative to another module's
  groups, subject to the transitivity constraints already described in the
  proposal. This enforces a consistent style internally within modules
  defining operators.

- The proposal states that precedence groups live in a separate namespace from
  other declarations; however, this is unprecedented in Swift, and leads to
  significant implementation challenges. The core team recommends that
  precedence groups exist in the same namespace as all Swift declarations. It
  would be an error to reference a precedence group in value contexts.

- Placing precedence groups in the standard namespace makes the question of
  naming conventions for `precedencegroup` declarations important. The core
  team feels that this is an important issue for the proposal to address.
  As a starting point, we recommend `CamelCase` with a `-Precedence` suffix,
  e.g. `AdditivePrecedence`. This is unfortunately redundant in the context of
  a `precedencegroup` declaration; however, `precedencegroup`s should be rare
  in practice, and it adds clarity at the point of use in `operator`
  declarations in addition to avoiding naming collisions. The standard library
  team also requests time to review the proposed names of the standard
  precedence groups

- This proposal quietly drops the `assignment` modifier that exists on operators
  today. This modifier had one important function--an operator marked
  `assignment` gets folded into an optional chain, allowing `foo?.bar += 2`
  to work as `foo?(.bar += 2)` instead of `(foo?.bar) += 2`. In practice,
  all Swift operators currently marked `assignment` are at the `Assignment`
  precedence level, so the core team recommends making this optional chaining
  interaction a special feature of the `Assignment` precedence group.

- This proposal also accidentally includes declarations of `&&=` and `||=`
  operators, which do not exist in Swift today and should not be added as part
  of this proposal.
