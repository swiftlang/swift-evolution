# `if let` shorthand

* Proposal: [SE-NNNN](NNNN-if-let-shorthand.md)
* Authors: [Cal Stephens](https://github.com/calda)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#40694](https://github.com/apple/swift/pull/40694)

## Introduction

Optional binding using `if let foo = foo { ... }`, to create an unwrapped variable that shadows an existing optional variable, is an extremely common pattern. This pattern requires the author to repeat the referenced identifier twice, which can cause these optional binding conditions to be verbose, especialy when using lengthy variable names. We should introduce a shorthand syntax for optional binding when shadowing an existing variable:

```swift
let foo: Foo? = ...

if let foo {
    // `foo` is of type `Foo`
}
```

Swift-evolution thread: [`if let` shorthand](https://forums.swift.org/t/if-let-shorthand/54230)

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

One approach for dealing with this is to use shorter, less descriptive, names for the unwrapped variables:

```swift
if let a = someLengthyVariableName, let b = anotherImportantVariable {
    ...
}
```

This approach, however, reduces clarity at the point of use for the unwrapped variables. Instead of encouraging short variable names, we should allow for the ergonomic use of descriptive variable names.

## Proposed solution

If we instead omit the right-hand expression, and allow the compiler to automatically shadow the existing variable with that name, these optional bindings are much less verbose, and noticably easier to read / write:

```swift
let someLengthyVariableName: Foo? = ...
let anotherImportantVariable: Bar? = ...

if let someLengthyVariableName, let anotherImportantVariable {
    ...
}
```

This is a fairly natural extension to the existing syntax for optional binding conditions.

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

else if let foo { ... }
else if var foo { ... }

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

Explicit type annotations are permitted, like with standard optional binding conditions.

For example:

```swift
if let foo: Foo { ... }
```

is transformed into:

```swift
if let foo: Foo = foo { ... }
```

## Source compatibility

This change is purely additive and does not break source compatibility of any valid existing Swift code.

## Effect on ABI stability

This change is purely additive, and is a syntactic transformation to existing valid code, so has no effect on ABI stability.

## Effect on API resilience

This change is purely additive, and is a syntactic transformation to existing valid code, so has no effect on ABI stability.

## Alternatives considered

There have been many other proposed spellings for this feature:

### `if let foo?`

One common suggestion is to include a `?` to explicitly indicate that this is unwrapping an optional, using `if let foo?`. This is indicative of the existing `case let foo?` pattern matching syntax.

`if let foo = foo` (the most common existing syntax for this) unwraps optionals without an explicit `?`. This implies that a conditional optional binding is sufficiently clear without a `?` to indicate the presence of an optional. If this is the case, then an additional `?` is likely not strictly necessary in the shorthand `if let foo` case.

While the symmetry of `if let foo?` with `case let foo?` is quite nice, the symmetry of `if let foo` with `if let foo = foo` is even more important. Pattern matching is a somewhat advanced feature — `if let foo = foo` bindings are much more fundamental. 

Additionally, the `?` makes it trickier to support explicit type annotations like in `if let foo: Foo = foo`. `if let foo: Foo` is a natural consequence of the existing grammar. It's less clear how this would work with an additional `?`. `if let foo?: Foo` likely makes the most sense, but doesn't match any existing language constructs.

### `if unwrap foo`

Another common suggestion is to introduce a new keyword for this purpose, like `if unwrap foo` or `if have foo`. 

It is preferable to draw from existing keywords and patterns rather than introduce a new keyword specifically for this shorthand syntax. 

For pairity with existing optional binding conditions, any new syntax should support the distintion between `if let foo = foo` and `if var foo = foo`. Additionally, explicitly writing `let` or `var` is important for indicating that a new variable is being declared for the inner scope.

### `if foo != nil`

One somewhat common proposal is to permit `nil`-checks (like `if foo != nil`) to unwrap the variable in the inner scope. Kotlin supports this type of syntax:

```kt
var foo: String? = "foo"
print(foo?.length) // "3"

if (foo != null) {
    // `foo` is non-optional
    print(foo.length) // "3"
}
```

This pattern in Kotlin _does not_ define a new variable -- it merely changes the type of the existing variable within the inner scope. So mutations that affect the inner scope also affect the outer scope:

```kt
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
