# Improved operator declarations

* Proposal: [SE-0077](0077-operator-precedence.md)
* Author: [Anton Zhilin](https://github.com/Anton3)
* Status: **Under revision** ([Rationale](#rationale))
* Review manager: [Joe Groff](http://github.com/jckarter)

**Revision history**

- **[v1](https://github.com/apple/swift-evolution/blob/40c2acad241106e1cfe697d0f75e1855dc9e96d5/proposals/0077-operator-precedence.md)** Initial version
- **v2** Updates after core team review

## Introduction

Replace syntax of operator declaration, and replace numerical precedence with partial ordering of operators:

```swift
// Before
infix operator <> { precedence 100 associativity left }

// After
precedencegroup ComparativePrecedence {
  associativity: left
  strongerThan: LogicalAndPrecedence
}
infix operator <> : ComparativePrecedence
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

In many cases, this is undesirable. For example, `a & b < c` and `a / b as Double` are common error patterns.
C++ compilers sometimes emit warnings on these, but Swift does not.

The root of the problem is that precedence is currently defined for any pair of operators.
If `&` had its precedence defined only in relation to other bitwise operators and `/` – only to arithmetic operators,
we would have to use parentheses in the preceding examples. This would avoid subtle bugs.

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
  associativity: left
}

infix operator + : Additive
infix operator - : Additive
```

### Precedence mechanism

Concept of a single precedence hierarchy is removed.
Instead, to omit parentheses in expression with two neighbouring `infix` operators, precedence relationship *must* be defined between their precedence groups.

It is performed by adding `strongerThan` clause, see example:

```swift
precedencegroup Additive {
  associativity: left
}
precedencegroup Multiplicative {
  associativity: left
  strongerThan: Additive
}
precedencegroup BitwiseAnd {
  associativity: left
}
infix operator + : Additive
infix operator * : Multiplicative
infix operator & : BitwiseAnd

1 + 2 * 3  // ok, precedence of * is greater than precedence of +
1 + 2 & 3  // error, precedence between + and & is not defined
```

Only one declaration of the same operator / precedence group is allowed,
meaning that new precedence relationships between existing groups cannot be added.

### Transitive precedence propagation

Compiler will apply transitivity axiom to compare precedence of two given precedence groups. Example:

```swift
precedencegroup Exponentiative {
  associativity: left
  greaterThan: Multiplicative
}
infix operator ** : Exponentiative

1 + 2 ** 3  // same as 1 + (2 ** 3)
```

Here, `Exponentiative > Multiplicative` and `Multiplicative > Additive` imply `Exponentiative > Additive`.

Multiple precedence relationships can be stated for a single precedence group.

### `DefaultPrecedence`

If `infix` operator does not state group that it belongs to, it is assigned to `DefaultPrecedence` group, which is defined as follows:

```swift
precedencegroup DefaultPrecedence {
  strongerThan: Ternary
}
```

The following two statements are equivalent:

```swift
infix operator |> : DefaultPrecedence
infix operator |>
```

### `AssignmentPrecedence`

Swift 2.2 has `assignment` modifier that works as follows: an operator marked `assignment` gets folded into an optional chain,
allowing `foo?.bar += 2` to work as `foo?(.bar += 2)` instead of failing to type-check as `(foo?.bar) += 2`.

This trait will be passed to `AssignmentPrecedence` group.

### `weakerThan` relationship

There are times when we want to insert an operator below an existing one.
If that existing operator resides in another module, we can use `weakerThan` relationship. Example:

```swift
// module Swift
precedencegroup Additive { strongerThan: Range }
precedencegroup Multiplicative { strongerThan: Additive }

// module A
precedencegroup Equivalence {
  strongerThan: Comparative
  weakerThan: Additive  // possible, because Additive lies in another module
}
infix operator ~ : Equivalence

1 + 2 ~ 3    // same as (1 + 2) ~ 3, because Additive > Equivalence
1 * 2 ~ 3    // same as (1 * 2) ~ 3, because Multiplicative > Additive > Equivalence
1 < 2 ~ 3    // same as 1 < (2 ~ 3), because Equivalence > Comparative
1 += 2 ~ 3   // same as 1 += (2 ~ 3), because Equivalence > Comparative > Assignment
1 ... 2 ~ 3  // error, because Range and Equivalence are unrelated
```

## Detailed design

### Precedence rules

Relationships between precedence groups form a Directed Acyclic Graph.
Fetching precedence relationship between given operators is equivalent to problem of [Reachability](https://en.wikipedia.org/wiki/Reachability).

#### Transitivity check

All precedence relationships must be transitive. If we define `A < B`, `B < C` and `A > C`, it will be a compilation error.
Two examples:

```swift
precedencegroup A { strongerThan: B }
precedencegroup B { strongerThan: A }
// A > B > A
```

```swift
precedencegroup A { }
precedencegroup B { strongerThan: A }

precedencegroup C {
  strongerThan: B
  weakerThan: A
}
// C > B > A > C
```

Checking for such situations is equivalent to checking whether DAG of precedence groups contains directed loops.

#### Joining unrelated precedence groups

Precedence relationships that, by transitivity rule, create relationship between two imported groups, is an error. Example:

```swift
// Module X
precedencegroup A { }
precedencegroup C { }

// Module Y
import X
precedencegroup B {
  strongerThan: A
  weakerThan: C
}
```

This results in *compilation error* "B uses transitivity to define relationship between imported groups A and C".
The rationale behind this is that otherwise one can create relationships between standard precedence groups that are confusing for the reader.

### Special operators

Built-ins `is`, `as`, `as?`, `as!`, `=`, `?:` have stated precedence, but cannot be declared using Swift syntax.

They will be hardcoded in the compiler and assigned to appropriate precedence groups,
**as if** the following declarations took place:

```swift
// NOT valid Swift
infix operator is : CastPrecedence
infix operator as : CastPrecedence
infix operator as? : CastPrecedence
infix operator as! : CastPrecedence
infix operator ?: : TernaryPrecedence
infix operator = : AssignmentPrecedence
```

### Grammar

`assignment` and `precedence` local keywords will be removed.
`precedencegroup` keyword, and `strongerThan`, `weakerThan` local keywords will be added.

*operator-declaration* → *prefix-operator-declaration* | *postfix-operator-declaration* | *infix-operator-declaration*

*prefix-operator-declaration* → `prefix` `operator` *operator*

*postfix-operator-declaration* → `postfix` `operator` *operator*

*infix-operator-declaration* → `infix` `operator` *operator* *infix-operator-group<sub>opt</sub>*

*infix-operator-group* → `:` *precedence-group-name*

*precedence-group-declaration* → `precedencegroup` *precedence-group-name* `{` *precedence-group-attributes* `}`

*precedence-group-attributes* → *precedence-group-associativity<sub>opt</sub>*
*precedence-group-relations<sub>opt</sub>*

*precedence-group-associativity* → `associativity` `:` *precedence-group-associativity-option*

*precedence-group-associativity-option* → `left` | `right`

*precedence-group-relations* → *precedence-group-relation* | *precedence-group-relation* *precedence-group-relations*

*precedence-group-relation* → `strongerThan` `:` *precedence-group-name*

*precedence-group-relation* → `weakerThan` `:` *precedence-group-name*

*precedence-group-name* → *identifier*

### Standard library changes

```swift
prefix operator !
prefix operator ~
prefix operator +
prefix operator -

precedencegroup AssignmentPrecedence {
}
precedencegroup TernaryPrecedence {
  associativity: right
  strongerThan: AssignmentPrecedence
}
precedencegroup DefaultPrecedence {
  strongerThan: TernaryPrecedence
}
precedencegroup LogicalOrPrecedence {
  associativity: left
  strongerThan: TernaryPrecedence
}
precedencegroup LogicalAndPrecedence {
  associativity: left
  strongerThan: LogicalOrPrecedence
}
precedencegroup ComparativePrecedence {
  associativity: left
  strongerThan: LogicalAndPrecedence
}
precedencegroup NilCoalescingPrecedence {
  associativity: right
  strongerThan: ComparativePrecedence
}
precedencegroup CastPrecedence {
  associativity: left
  strongerThan: NilCoalescingPrecedence
}
precedencegroup RangePrecedence {
  strongerThan: CastPrecedence
}
precedencegroup AdditivePrecedence {
  associativity: left
  strongerThan: RangePrecedence
}
precedencegroup MultiplicativePrecedence {
  associativity(left)
  strongerThan: AdditivePrecedence
}
precedencegroup BitwiseShiftPrecedence {
  strongerThan: MultiplicativePrecedence
}

// infix operator = : AssignmentPrecedence
infix operator *= : AssignmentPrecedence
infix operator /= : AssignmentPrecedence
infix operator %= : AssignmentPrecedence
infix operator += : AssignmentPrecedence
infix operator -= : AssignmentPrecedence
infix operator <<= : AssignmentPrecedence
infix operator >>= : AssignmentPrecedence
infix operator &= : AssignmentPrecedence
infix operator ^= : AssignmentPrecedence
infix operator |= : AssignmentPrecedence

// infix operator ?: : TernaryPrecedence

infix operator && : LogicalAndPrecedence
infix operator || : LogicalOrPrecedence

infix operator < : ComparativePrecedence
infix operator <= : ComparativePrecedence
infix operator > : ComparativePrecedence
infix operator >= : ComparativePrecedence
infix operator == : ComparativePrecedence
infix operator != : ComparativePrecedence
infix operator === : ComparativePrecedence
infix operator ~= : ComparativePrecedence

infix operator ?? : NilCoalescingPrecedence

// infix operator as : CastPrecedence
// infix operator as? : CastPrecedence
// infix operator as! : CastPrecedence
// infix operator is : CastPrecedence

infix operator ..< : RangePrecedence
infix operator ... : RangePrecedence

infix operator + : AdditivePrecedence
infix operator - : AdditivePrecedence
infix operator &+ : AdditivePrecedence
infix operator &- : AdditivePrecedence
infix operator | : AdditivePrecedence
infix operator ^ : AdditivePrecedence

infix operator * : MultiplicativePrecedence
infix operator / : MultiplicativePrecedence
infix operator % : MultiplicativePrecedence
infix operator &* : MultiplicativePrecedence
infix operator & : MultiplicativePrecedence

infix operator << : BitwiseShiftPrecedence
infix operator >> : BitwiseShiftPrecedence
```

## Impact on existing code

Standard library operator declarations will be rewritten, and precedence groups will be added.

User defined operators will need to be rewritten as well.
Migration tool will remove bodies of operator declarations. `infix` operators will be implicitly added to `DefaultPrecedence` group.

Code, which relies on precedence relations of user-defined operators being implicitly defined, may be broken.
This will need to be fixed manually by adding them to desired precedence group.

## Future directions

### Change precedence of the Standard Library operators

Actually, this is one of the main reasons why this proposal was created: break single hierarchy of operators from Standard Library.
But this will be the topic of another proposal, because separate discussion is needed.

## Alternatives considered

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
precedence - = +
precedence &+ = +
precedence / = *
precedence % = *
precedence * > +
```

### Replace `precedencegroup` with `precedence`

Pros:

- Looks shorter, less bulky
- Declarations use same naming style as protocols

Cons:

- Need to take `precedence` as a keyword
- `precedencegroup` more precisely represents what it declares

### Possible syntax variations

Instead of `strongerThan` and `weakerThan`, there could be:
- `above` and `below`
- `upper` and `lower`
- `greaterThan` and `lessThan`
- `gt` and `lt`
- `before` and `after`

Instead of `associativity`, there could be `associate`.

```swift
precedence Multiplicative {
  associativity(left)
  precedence(> Additive)
  precedence(< Exponentiative)
}
```

```swift
precedence Multiplicative {
  associativity: left
  precedence: strongerThan(Additive)
  precedence: weakerThan(Exponentiative)
}
```

```swift
precedence Multiplicative {
  associativity(left)
  strongerThan(Additive)
  weakerThan(Exponentiative)
}
```

```swift
precedence Multiplicative {
  associativity: left,
  strongerThan: Additive,
  weakerThan: Exponentiative
}
```

```swift
precedence Multiplicative {
  associativity left
  strongerThan Additive
  weakerThan Exponentiative
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
precedence Multiplicative : associativity(left), strongerThan(Additive), weakerThan(Exponentiative)
```

```swift
precedence Multiplicative : associativity left, strongerThan Additive, weakerThan Exponentiative
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
  strongerThan Additive
  weakerThan Exponentiative
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

### Use meta-circular syntax

That is, if a constant is of special type, then it will be used only at compile time:

```swift
struct PrecedenceGroup {
  enum Associativity { case left, right, none }
  let associativity: Associativity
  let strongerThan: [StaticString]
  let weakerThan: [StaticString]
}
let Multiplicative = PrecedenceGroup(.left, [Associativity], [])
```

> This is already strongly library-determined. The library defines what operators exist and defines their
> precedence w.r.t. each other and a small number of built-in operators. Operator precedence has to be
> communicated to the compiler somehow in order to parse code. This proposal is just deciding the syntax of
> that communication.
> 
> I see no reason to use a more conceptually complex approach when a simple declaration will do.
> 
> <cite>-- John McCall</cite>

## Note from review period

During review, many participants showed preference to the following syntax:

```swift
precedence Multiplicative {
  associativity: left
  above: Additive
  below: Exponentiative
}
```

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
