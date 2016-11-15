# Simplifying `guard case`/`if case` syntax

* Proposal: TBD
* Author: [Erica Sadun](https://github.com/erica)
* Status: TBD
* Review manager: TBD

## Introduction

This proposal re-architects `guard case` and `if case` grammar for unwrapping complex enumerations. 

Swift-evolution thread:
[\[Pitch\] Reimagining `guard case`/`if case`](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161024/tbd.html) 

## Motivation

Swift's current `guard case` and `if case` design aligns statement layout with the `switch` statement: 

```swift
switch value {
    case let .enumeration(embedded): ...
}

if case let .enumeration(embedded) = value
```

Although this grammar unifies the `switch` and `if`/`guard` approaches, offering an overall conceptual "win", real-world users may not consider this parallel construction or naturally connect the two layouts. 

### Background

`guard case` and `if case` perform simultaneous pattern matching and conditional binding. These examples demonstrate their use for a simple one-associated-value enumeration:

```swift
enum Result<T> { case success(T), error(Error) }

// valid Swift
guard case let .success(value) = result
    else { ... }
guard case .success(let value) = result
    else { ... }
    
// valid Swift
if case .success(let value) = result { ... }
if case let .success(value) = result { ... }
```

The status quo for the `=` operator is iteratively built up in this fashion:

* `=` performs assignment
* `let x =` performs binding
* `if let x =` performs conditional binding on optionals
* `if case .foo(let x) = ` and `if case let .foo(x) =` performs conditional binding on enumerations *and* applies pattern matching

Using `if case`/`guard case` in the absense of conditional binding duplicates basic pattern matching with less obvious meaning. These two statements are functionally identical:

```swift
if range ~= myValue { ... } // simpler
if case range = myValue { ... } // confusing
```

### Design Issues

Issues with the current design include:

* `guard case` and `if case` look like assignment statements but they are *not* assignment statements. Using the assignment operator violates the [principle of least astonishment](https://en.wikipedia.org/wiki/Principle_of_least_astonishment).  
* In `switch`, a `case` is followed by a colon, not an assignment operator.
* Swift has a pattern matching operator (`~=`) but does not use it here.
* `case` syntax is overly wordy. The statement includes `case`, `=`, and optionally `let`/`var` assignment. Design alternatives could streamline this syntax, enhance clarity, and introduce a more concise format.

## Detailed Design

A successful design replaces the current syntax with a simpler grammar that prioritizes pattern matching and support conditional binding.

### Design 1: Using the Pattern Matching Operator

This design drops the `case` keyword and replaces `=` with `~=`. The results look like this, showcasing a variety of `let` placement, variable binding, and optional sugar alternatives.

```swift
guard let .success(value) ~= result else { ... }
guard var .success(value) ~= result else { ... }
guard .success(let value) ~= result else { ... }
if let .success(value) ~= result { ... }
if .success(let value) ~= result { ... }
guard let x? ~= anOptional else { ... }
if let x? ~= anOptional { ... }
```

In this design:

* The `case` keyword is subsumed into the (existing) pattern matching operator
* The statements adopt the existing `if-let`/`if var` and `guard-let`/`guard var` syntax, including `Optional` syntactic sugar.

```swift
if let x = anOptional { ... } // current
if case let x? = anOptional { ... } // current, would be removed

if let x? ~= anOptional { ... } // proposed replacement for `if case`
```

Pattern matching without conditional binding simplifies to a standalone Boolean condition clause. On adopting this syntax, the two identical range tests naturally unify to this single version:

```swift
if range ~= myValue { ... } // before
if case range = myValue { ... } // before

if range ~= myValue { ... } // after
```

### Design 2: Using a Declare and Assign Operator

This design introduces new `:=` "declare and assign" operator. This operator eliminates the need for explicit `let`:

```swift
guard .success(value) := result else { ... } // clean and elegant
if .success(value) := result { ... } // clean and elegant
guard x? := anOptional else { ... } // newly legal, although unnecessary
```

Assignments to variables require the `var` keyword, and `let` would be permitted even if it is not required, enabling coders to clarify the distinct roles in mix-and-match pattern matching:

```swift
guard .pair(value1, var value2) := result else { ... } // implied let
guard .pair(let value1, var value2) := result else { ... } // explicit let
if .success(var value) := result { ... } // variable assignment
guard var x? := anOptional else { ... } // variable assignment
guard var x := anOptional else { ... } // simpler variable assignment
guard var x = anOptional else { ... } // even simpler (current) variable assignment
guard x := anOptional else { ... } // new constant assignment
```

Adopting this syntax  provides more natural results for binding associated enumeration variables.

### Excluded from this proposal

This proposal does not address `switch case` or `for case`.

## Impact on Existing Code

This proposal is breaking and would require migration.

### Timeline

Although removing `if case` and `guard case` are breaking, this proposal should wait until Swift 4 Stage two to allow proper debate and consideration from the core team.

## Alternatives Considered

* Leaving the grammar as-is, albeit confusing
* Retaining `case` and replacing the equal sign with `~=` (pattern matching) or `:` (to match the switch statement).
* Adding `matches` or `is` as an alternative to the pattern matching operator