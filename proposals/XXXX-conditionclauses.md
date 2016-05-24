# Simplifying condition clauses and intermingling expressions with other conditions

* Proposal: TBD
* Author: [Erica Sadun](https://github.com/erica)
* Status: TBD
* Review manager: TBD

## Introduction

This proposal adjust Swift grammar to enable the arbitrary mix of expressions among conditions rather 
than constraining them before other conditions. Under this proposal, expressions are no longer limited
to where clauses after the initial list of Boolean conditions.

Swift-evolution thread:
[\[Pitch\] making where and ,	interchangeable in guard conditions](http://thread.gmane.org/gmane.comp.lang.swift.evolution/17926)

## Motivation

There is no technical reason to disallow arbitrary mixes of binding, patterns, availability tests,
and Boolean assertions within a single compound condition clause. Swift currently enforces a grammar
that limits expressions to `where` clauses after the first non-Boolean condition clause has been mentioned.
This rule means that all standalone Boolean tests must precede binding and pattern conditions and
allows for code such as:

```swift
guard 
    x == 0,
    let y = optional where z == 2 
    else { ... }
```

In this example, the Boolean `z == 2` clause has no semantic relationship to the optional 
condition to which it's syntactically bound. Ideally, `where` clauses should be restricted to a Boolean
assertion tied to variables connected to the binding or pattern condition. Unrelated
Boolean assertions should be allowed to stand on their own

If accepted, the following code would be legal, as would similar usage in `while` and `if` statements.

```swift
guard
    x == 0,
    let y = optional,
    z == 2
    else { ... }
```

Under the current system, all Boolean clauses must be conjoined and expressed as the first item of the condition clause except in one special case after an availability condition. The advantages in accepting this proposal are:

* Coders need not conjoin Boolean assertions using &&, as they may be separated into separate expressions and will break at the first false value
* Coders will be allowed to move Boolean assertions out of where clauses when there is no relationship to conditions
* Coders will be allowed to order the statements as desired. It is left to the coder to make wise ordering decisions.
* There will be a cleaner, and simpler grammar.

## Detailed Design

Under this proposal, condition lists are updated to accept a grammar along the following lines:

```
‌condition-list → condition | expression | condition , condition-list | expression, condition-list
```

This enables `guard`, `while`, `repeat-while`, and `if` to adopt grammars like:

```
guard condition-list else code-block
while condition-list code-block
if condition-list code-block (else-clause)?
```

*Note: A repeat-while  statement does not use a condition list. Its grammar is `repeat code-block while expression`*

This approach simplifies the current Swift grammar, which constructs condition clauses 
separately from condition lists and conditions. This extra work is needed to introduce an expression before condition lists and to allow an expression after availability checks:

```
condition-clause → expression
condition-clause → expression , condition-list
condition-clause → condition-list
condition-clause → availability-condition , expression
condition-list → condition | condition,condition-list
condition → availability-condition | case-condition | optional-binding-condition
```

Beyond this high level change, all three conditions (availability conditions, case conditions, 
and optional binding conditions) remain unaffected as do their associated `where` clause grammar.
This solution changes list construction not `where` clauses.

## Impact on Existing Code

This proposal does not affect existing code.

## Alternatives Considered

The "easiest" solution that free interchange of commas with `where`, 
permits construction of statements like the following:
```swift
// where-clause → (where | ,) where-expression
for i in 0...10, i % 2 == 0 { print(i) }
```

Adjusting the `where` clause in this way wouldn't introduce the ability to mix 
and match Boolean expressions, availability conditions, case conditions, and 
optional binding conditions in condition clauses, and is therefore discarded from
consideration.

## Future directions

This proposal was motivated by freeing Boolean assertions that were semantically unrelated
to their associated conditions. In the following example the `z == 2` test
is unrelated to `let y = optional`.

```swift
guard 
    x == 0,
    let y = optional where z == 2 
    else { ... }
```

I cannot see any easy or obvious way to test whether the variables in 
a `where` clause's Boolean assertions are mentioned or related to the 
condition that precedes them. While it would be valuable to allow Swift to
emit warnings, it may not be practical or possible to provide this functionality.