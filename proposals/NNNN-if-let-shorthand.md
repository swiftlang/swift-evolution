# `if let` shorthand for shadowing an existing optional variable 

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

Since the pattern following the `let` serves as both an evaluated expression _and_ an identifier for the newly-defined non-optional variable, only valid identifiers would be permitted. For example, this example would not be permitted:

```swift
if let foo.bar { ... } // 🛑
```

### Interaction with implicit self

Like with existing optional bindings, this new syntax would support implifict self references to unwrap optional members of `self`. For example, the usage in this example would be permitted:

```swift
struct UserView: View {
  let name: String
  let emailAddress: String?

  var body: some View {
    VStack {
      Text(user.name)

      // Equivalent to `if let emailAddress = emailAddress { ... }`,
      // unwraps `self.emailAddress`.
      if let emailAddress {
        Text(emailAddress)
      }
    }
  }
}
```

## Source compatibility

This change is purely additive and does not break source compatibility of any valid existing Swift code.

## Effect on ABI stability

This change is purely additive, and is a syntactic transformation to existing valid code, so has no effect on ABI stability.

## Effect on API resilience

This change is purely additive, and is a syntactic transformation to existing valid code, so has no effect on ABI stability.

## Future directions

### Optional casting

A natural extension of this new syntax could be to support shorthand for optional casting. For example:

`if let foo as? Bar { ... }`

could be equivalent to:

`if let foo = foo as? Bar { ... }`

This is not included in this proposal, but is a reasonable feature that could be added in the future.

### Interaction with future borrow introducers

["A roadmap for improving Swift performance predictability"](https://forums.swift.org/t/a-roadmap-for-improving-swift-performance-predictability-arc-improvements-and-ownership-control/54206#borrow-variables-7) discusses potential new `ref` and `inout` introducers for creating variables that "borrow" existing variables without making a copy (by enforcing exclusive access). For consistency with `let` / `var`, it will likely make sense to support optional binding conditions for these new introducers:

```swift
if ref foo = foo {
  // if `foo` is not nil, it is borrowed and made available as a non-optional, immutable variable
}

if inout foo = &foo {
  // if `foo` is not nil, it is borrowed and made available as a non-optional, mutable variable
}
```

The shorthand syntax for `let` / `var` optional bindings would extend fairly naturally to these new introducers:

```swift
if ref foo {
  // if `foo` is not nil, it is borrowed and made available as a non-optional, immutable variable
}

if inout &foo {
  // if `foo` is not nil, it is borrowed and made available as a non-optional, mutable variable
}
```

### Unwrapping nested members of objects

This proposal doesn't permit shorthand unwrapping for members nested in other objects. For example:

`if let foo.bar { ... } // 🛑`

There are a few different options that could allow us to support this type of syntax in the future.

One approach could be to automatically synthesize the identifier name for the unwrapped variable in the inner scope. For example. `if let foo.bar` could introduce a new non-optional variable named `bar` or `fooBar`. 

Another approach could be to permit this for potential future borrow introducers `ref` and `inout` (from ["A roadmap for improving Swift performance predictability"](https://forums.swift.org/t/a-roadmap-for-improving-swift-performance-predictability-arc-improvements-and-ownership-control/54206#borrow-variables-7)). These borrows would have compiler-enforced exclusive access to the underlying storage, so they technically do not require a unique identifier name for the inner scope. This could allow us to unwrap members of objects without any new variables or copies. For example:

```swift
// `mother.father.sister` is optional

if ref mother.father.sister {
  // `mother.father.sister` is non-optional and immutable
}

if inout &mother.father.sister {
  // `mother.father.sister` is non-optional and mutable
}
```

## Alternatives considered

There have been many other proposed spellings for this feature:

### `if foo`

The briefest possible spelling for this feature would just be a bare `if foo` condition. This spelling, however, would create ambiguity between optional unwrapping conditions and boolean conditions, and could lead to confusing / conter-intuitive situations:

```swift
let foo: Bool = true
let bar: Bool? = false

if foo, bar {
  // would succeed
}

if foo == true, bar == true {
  // would fail
}
```

To avoid this abiguity, we need some sort of distinct syntax for optional bindings.

### `if foo?`, `if unwrap foo`

Another option is to introduce a new keyword or sigil for this purpose, like `if foo?`, `if unwrap foo` or `if have foo`.

One of the key behaviors of optional unwrapping is that it creates a new variable defined within the inner scope. We use `let` / `var` to introduce new variables elsewhere in the language, so `if let foo` should make the variable scoping behavior reasonably clear and unabiguous. For `if foo?` and `if unwrap foo`, it is not inherently obvious whether or not a new variable is defined for the inner scope. This has the potential to be confusing, and likely reduces clarity compared to the existing syntax.

Another downside of introducing a new keyword / sigil is that the limitations of this shorthand syntax become less intutive. For example, it is not necessarily obvious that `if foo.bar?` or `if unwrap foo.bar` would be invalid. On the other hand, it is somewhat intuitive that `if let foo.bar` would be invalid (e.g. that `let` can only be followed by an identifier and not an expression) since this is the case elsewhere in the language.

Other benefits of using the `let` keyword here include:

 - supporting `var` (like in `if var foo = foo`) is trivial since we already have the `let` introducer for the more common immutable case.

 - consistency with existing optional binding conditions, which is useful in mixed-expression `if` statements:

      ```swift
      // Consistent
      if let user, let defaultAddress = user.shippingAddresses.first { ... }

      // Inconsistent
      if unwrap user, let defaultAddress = user.shippingAddresses.first { ... }

      if user?, let defaultAddress = user.shippingAddresses.first { ... }
      ```

Another important aspect to consider is that using a new syntax like `if unwrap foo` could allow this feature to behave _differently_ from existing optional binding conditions. For example, instead of making a copy like `if let foo = foo`, a new `if unwrap foo` syntax could instead perform a [_borrow_](https://forums.swift.org/t/a-roadmap-for-improving-swift-performance-predictability-arc-improvements-and-ownership-control/54206#borrow-variables-7) of `foo`. This could make `if unwrap foo` behave like shorthand for `if ref foo = foo`.

It would be very useful for this shorthand to support borrows, once that feature is added to Swift. That doesn't mean, however, that the shorthand syntax _shouldn't_ support making copies (e.g. with `let` / `var`). Borrows introduce conceptual overhead since they require exclusive access to the variable being borrowed, which brings with it a whole new class of potential exclusivity violation errors that would need to be reasoned about. This implies that using copy introducers or using borrow introducers will be a tradeoff between convenience and performance. It likely makes sense for this syntax to support both classes of variables / introducers, so the user can choose the option that best suits their specific use case.

Additionally, this syntax should support the distinction between immutable and mutable variables. Combined with the disctinction between copies and borrows, that would give us the same set of options as normal variables (immutable copy, mutable copy, immutable borrow, mutable borrow). Since we already have syntax for these concepts (`let`, `var`, and potentially `ref` and `inout` in the future) it would be preferable to reuse that syntax in optional binding conditions:

```swift
if let foo { /* foo is an immutable copy */ }
if var foo { /* foo is a mutable copy */ }
if ref foo { /* foo is an immutable borrow */ }
if inout &foo { /* foo is a mutable borrow */ }
```

### `if let foo?`

Another option is to include a `?` to explicitly indicate that this is unwrapping an optional, using `if let foo?`. This is indicative of the existing `case let foo?` pattern matching syntax.

`if let foo = foo` (the most common existing syntax for this) unwraps optionals without an explicit `?`. This implies that a conditional optional binding is sufficiently clear without a `?` to indicate the presence of an optional. If this is the case, then an additional `?` is likely not strictly necessary in the shorthand `if let foo` case.

While the symmetry of `if let foo?` with `case let foo?` is quite nice, the symmetry of `if let foo` with `if let foo = foo` is even more important. Pattern matching is a somewhat advanced feature — `if let foo = foo` bindings are much more fundamental. 

Additionally, the `?` makes it trickier to support explicit type annotations like in `if let foo: Foo = foo`. `if let foo: Foo` is a natural consequence of the existing grammar. It's less clear how this would work with an additional `?`. `if let foo?: Foo` likely makes the most sense, but doesn't match any existing language constructs.

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

This is different from Swift's optional binding conditions (`if let foo = foo`), which define a new, _separate_ variable in the inner scope. This is a defining characteristic of optional binding conditions in Swift, so any shorthand syntax must make it abundantly clear that a new variable is being declared.

### Don't permit `if var foo`

Since `if var foo = foo` is significantly less common that `if let foo = foo`, we could potentially choose to _not_ support `var` in this shorthand syntax. 

`var` shadowing has the potential to be more confusing than `let` shadowing -- `var` introduces a new _mutable_ variable, and any mutations to the new variable are not shared with the original optional variable. `if var foo = foo` already exists, and it seems unlikely that `if var foo` would be more confusing / less clear than the existing syntax.

Since `let` and `var` are interchangable elsewhere in the language, that should also be the case here -- disallowing `if var foo` would be inconsistent with existing optional binding condition syntax. If we were using an alternative spelling that _did not_ use `let`, it may be reasonable to exclude `var` -- but since we are using `let` here, `var` should also be allowed.

## Acknowledgments

Many thanks to Craig Hockenberry, who recently wrote about this topic in [Let’s fix `if let` syntax](https://forums.swift.org/t/lets-fix-if-let-syntax/48188) which directly informed this proposal.

Thanks to Ben Cohen for suggesting the alternative `if let foo?` spelling, and for providing valuable feedback on this proposal.

Thanks to Chris Lattner for suggesting to consider how this proposal should interact with upcoming language features like potential `ref` and `inout` borrow introducers.

Thanks to [tera](https://forums.swift.org/u/tera/summary) for suggesting the alternative `if foo` spelling.

Thanks to James Dempsey for providing the "consistency with existing optional binding conditions" example.

Thanks to Jon Shier for providing the SwiftUI optional binding example.