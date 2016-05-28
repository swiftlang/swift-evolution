# Restructuring Condition Clauses

* Proposal: [SE-0099](0099-conditionclauses.md)
* Authors: [Erica Sadun](https://github.com/erica), [Chris Lattner](https://github.com/lattner)
* Status: **Active Review May 27 ... June 3, 2016**
* Review manager: [Joe Groff](https://github.com/jckarter)

## Introduction

Swift condition clauses appear in `guard`, `if`, and `while` statements. This proposal re-architects the condition grammar to enable an arbitrary mix of Boolean expressions, `let` conditions (which test and unwrap optionals), general `case` clauses for arbitrary pattern matching, and availability tests.  It removes `where` clauses from optional binding conditions, and introduces semicolons between unrelated condition types rather than commas, which are reserved for continuation lists.  This eliminates ambiguity problems in the current syntax, and alleviates the situation where many Swift developers don't know they can use arbitrary Boolean conditions after a value binding.

Swift-evolution thread:
[\[Pitch\] making where and ,	interchangeable in guard conditions](http://thread.gmane.org/gmane.comp.lang.swift.evolution/17926)

## Motivation

Swift currently allows an arbitrary mix of binding, patterns, availability
tests, and Boolean assertions within a single compound condition. However, its grammar includes ambiguity that force subsequent Boolean assertions to be preceded by a `where` clause (with a special-case exception made for availability tests). 

```
condition-clause → expression
condition-clause → expression, condition-list
condition-clause → condition-list
condition-clause → availability-condition, expression
condition-list → condition | condition, condition-list
condition → availability-condition | case-condition | optional-binding-condition
```

The rules are complex, confusing, and imprecise. These rules establish that standalone Boolean tests must either precede binding or be joined with optional binding and pattern conditions. The `where` clause, which makes sense in for loops and switch statement pattern matching, adds little to optional binding in condition clauses, as in the following example. It allows for code such as:

```swift
guard 
    x == 0,
    let y = optional where z == 2 
    else { ... 
```

In this example, the Boolean `z == 2` clause has no semantic relationship to the optional condition to which it's syntactically bound. Eliminating `where` enables the subordinate condition to stand on its own and be treated as a first class test among peers. 

The root problem lies in the condition grammar: commas are used both to separate items within a clause (e.g. in `if let x = a, y = b {`) and to separate mixed kinds of clauses (e.g. `if let x = a, case y? = b {`).  This proposal resolves this problem by retaining commas as separators within clauses (as used elsewhere in Swift) and introducing semicolons (or newlines) to separate distinct kinds of clauses.  This better aligns with the rest of the Swift language.

After adoption of these changes, the previous example would be written in any of
these styles:

```swift
guard
    x == 0;
    let y = optional;
    z == 2 
    else { ... 

guard
     x == 0
     let y = optional
     z == 2 
     else { ... 

guard x == 0; let y = optional; z == 2 else { ... 
```

etc.

This approach also solves ambiguity problems with the current grammar. For example, in current Swift, the comma in the following example could indicate a separator between two different pattern matches within the "case" clause (which has a 'let' pattern), or it could be an "if case" followed by an "if let" clause:

```swift
if case let x = a, let y = b {
```

The advantages in accepting this proposal are:

* The "list of lists" ambiguity problems are solved, and uses a cleaner and simpler grammar.
* `where` clauses are no longer used to conjoin Boolean expressions with conditional binding.  This fixes user confusion issues and addresses a problem where Boolean conditions need to be attached to arbitrary bindings.
* This better aligns with the rest of the Swift language.  It uses semicolons to separate statements and expression that occur on the same line, and allows those semicolons to be elided when broken across multiple lines (as is more typical).  
* This reduces clutter in practice, by replacing the heavy weight "where" keyword with a lighter weight semicolon in the inline case, and eliminating punctuation completely when clauses are broken across lines.

## Detailed Design

Under this proposal, condition lists are updated to accept a grammar along the following lines:

```
‌condition-list → condition | condition ; condition-list
‌condition → expression | availability-condition | case-condition | optional-binding-condition
```

This enables `guard`, `while`, and `if` to adopt grammars like:

```
guard condition-list else code-block
while condition-list code-block
if condition-list code-block (else-clause)?
```

*Note: A repeat-while statement does not use a condition list. Its grammar is `repeat code-block while expression`*

Where clauses are removed from optional binding conditions, so:

```
optional-binding-condition → optional-binding-head (optional-binding-continuation-list)? (where-clause)?
```

becomes:

```
optional-binding-condition → optional-binding-head (optional-binding-continuation-list)?
```

The `optional-binding-continuation-list` is retained, allowing comma-delineated binding of multiple items:

```swift
guard let x = opt1, y = opt2, z = opt3; booleanAssertion else { }
```

This change will not affect `case-condition`s, which will continue to allow `where` clauses, both in switch statements and in the condition lists for `guard`, `while`, and `if` statements:

```
case-condition → case patterninitializer (where-clause)?
```

All three conditions (availability conditions, case conditions, 
and optional binding conditions) remain otherwise unaffected.

## Impact on Existing Code

This proposal requires migration all condition lists, affecting commas outside of continuation lists and `where` keywords in optional binding statements.  This should be straight-forward for the compiler to address using fixit hints.

## Alternatives Considered

An earlier version of this proposal considered allowing free interchange of commas with the `where` keyword. Adjusting the `where` clause in this way wouldn't introduce the ability to mix and match Boolean expressions, availability conditions, case conditions, and optional binding conditions in condition clauses, and was therefore discarded from
consideration.

Another version retained commas and where clauses but allowed arbitrary ordering of conditions and expressions.