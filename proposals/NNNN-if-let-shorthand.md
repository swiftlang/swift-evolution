# `if let` shorthand

* Proposal: [SE-NNNN](NNNN-if-let-shorthand.md)
* Authors: [Cal Stephens](https://github.com/calda)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [calda/swift@ee8ebc0](https://github.com/calda/swift/commit/ee8ebc03db3d9be56fd5e2a8b036544e4b544535
https://github.com/calda/swift/commit/ee8ebc03db3d9be56fd5e2a8b036544e4b544535)

## Introduction

Optional binding using `if let foo = foo { ... }`, to create an unwrapped variable that shadows an existing optional variable, is an extremely common pattern. This pattern requires the author to repeat the referenced identifier twice, which can cause these optional binding conditions to be verbose, especialy when using lengthy variable names. We should introduce a shorthand syntax for optional binding when shadowing an existing variable:

```swift
let foo: Foo? = ...

if let foo {
    // `foo` is of type `Foo`
}
```

Swift-evolution thread: TODO

## Motivation

Reducing duplication, especially of lengthy variable names, makes code both easier to write _and_ easier to read.

For example, this statement that unwraps `someLengthyVariableName` and `anotherImportantVariable` is rather arduous to read (and was without a doubt arduous to write):

```swift
let someLengthyVariableName: Foo? = ...
let anotherImportantVariable: Bar? = ...

if let someLengthyVariableName = someLengthyVariableName, let anotherImportantVariable = anotherImportantVariable {
    ...
}
```

## Proposed solution

If we instead omit the right-hand expression, and allow the compiler to automatically shadow the existing variable with that name, these optional bindings are much less verbose, and noticably easier to read / write:

```swift
let someLengthyVariableName: Foo? = ...
let anotherImportantVariable: Bar? = ...

if let someLengthyVariableName, let anotherImportantVariable {
    ...
}
```

This is a fairly natural extension to the existing syntax for optional binding conditions. Using `let` (or `var`) here makes it abundantly clear that a new variable is being defined, which is especially important when used with mutable value types. Using `let` / `var` here also allows us to avoid adding any new keywords to the language.

## Detailed design

Specifically, this proposal extends the Swift grammar for [`optional-binding-condition`](https://docs.swift.org/swift-book/ReferenceManual/Statements.html#grammar_optional-binding-condition)s. 

This is currently defined as:

> optional-binding-condition → **let** [pattern](https://docs.swift.org/swift-book/ReferenceManual/Patterns.html#grammar_pattern) [initializer](https://docs.swift.org/swift-book/ReferenceManual/Declarations.html#grammar_initializer) | **var** [pattern](https://docs.swift.org/swift-book/ReferenceManual/Patterns.html#grammar_pattern) [initializer](https://docs.swift.org/swift-book/ReferenceManual/Declarations.html#grammar_initializer)

and would be updated to:

> optional-binding-condition → **let** [pattern](https://docs.swift.org/swift-book/ReferenceManual/Patterns.html#grammar_pattern) [initializer](https://docs.swift.org/swift-book/ReferenceManual/Declarations.html#grammar_initializer)<sub>opt</sub> | **var** [pattern](https://docs.swift.org/swift-book/ReferenceManual/Patterns.html#grammar_pattern) [initializer](https://docs.swift.org/swift-book/ReferenceManual/Declarations.html#grammar_initializer)<sub>opt</sub>

This would apply to all conditional control flow statements:

```swift
if let foo { ... }
if var foo { ... }

else let foo { ... }
else var foo { ... }

guard let foo else { ... }
guard var foo else { ... }

while let foo { ... }
while var foo { ... }
```

The compiler would synthesize an initializer expression that references the variable being shadowed. 

For example:

```swift
if let foo { ... }
```

is transformed into:

```swift
if let foo = foo { ... }
```

## Source compatibility

This change is purely additive and does not break source compatibility any valid existing Swift code.

## Effect on ABI stability

This change is purely additive, and is a syntactic transformation to existing valid code, so has no effect on ABI stability.

## Effect on API resilience

This change is purely additive, and is a syntactic transformation to existing valid code, so has no effect on ABI stability.

## Alternatives considered

There have been many other proposed spellings for this feature.

One common proposal is to permit `nil`-checks (like `if foo != nil`) to unwrap the variable in the inner scope. Kotlin supports this type of syntax:

```kt
var foo: String? = "foo"
print(foo?.length) // "3"

if (foo != null) {
    // `foo` is non-optional
    print(foo.length) // "3"
}
```

This pattern in Kotlin _does not_ define a new variable -- it merely changes the type of the existing variable within the inner scope. So mutations that affect the inner scope also affect the outer scope:

var foo: String? = "foo"

if (foo != null) {
    print(foo) // "foo"
    foo = "bar"
    print(foo) // "bar"
}

print(foo) // "bar"
```

This is different from Swift's optional binding conditions (`if let foo = foo`), which define a new, _separate_ variable. This is a defining characteristic of optional binding conditions in Swift, so any shorthand syntax must make it abundantly clear that a new variable is being declared. 

## Acknowledgments

Many thanks to Craig Hockenberry, who recently wrote about this topic in [Let’s fix `if let` syntax](https://forums.swift.org/t/lets-fix-if-let-syntax/48188) which directly informed this proposal.
