# Function Body Macros

* Proposal: [SE-NNNN](nnnn-function-body-macros.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: 
* Status: **Awaiting review**
* Implementation: [Pull request](https://github.com/apple/swift/pull/70034)
* Feature Flag: `BodyMacros`
* Review: 

[TOC]

## Introduction

Macros augment Swift programs with additional code, which can include new declarations, expressions, and statements. One of the key ways in which one might want to augment code---synthesizing or updating the body of a function---is not currently supported by the macro system. One can create new functions that have their own function bodies, but not provide function bodies for a function declared by the user.

This proposal introduces *function body macros*, which do exactly that: allow the wholesale synthesis of function bodies given a declaration, as well as augmenting an existing function body with more functionality. This opens up a number of new use cases for macros, including:

* Synthesizing function bodies given the function declaration and some metadata, such as automatically synthesizing remote procedure calls that pass along the provided arguments.
* Augmenting function bodies to perform logging/tracing, check preconditions, or establish invariants.

## Proposed solution

This proposal introduces *function body macros*, which are [attached macros](https://github.com/apple/swift-evolution/blob/main/proposals/0389-attached-macros.md) that can augment a function (including initializers, deinitializers, and accessors) with a new body. For example, one could introduce a `Remote` macro that packages up arguments for a remote procedure call:

```swift
 @Remote
 func f(a: Int, b: String) async throws -> String
```

which could expand the function to provide a body, e.g.:

```swift
func f(a: Int, b: String) async throws -> String {
    return try await remoteCall(function: "f", arguments: ["a": a, "b": b])
}
```

One could also use a macro to introduce logging code on entry and exit to a function, expanding the following

```swift
@Logged
func g(a: Int, b: Int) -> Int {
  return a + b
}
```

into

```swift
func g(a: Int, b: Int) -> Int {
  log("Entering g(a: \(a), b: \(b))")
  defer {
    log("Exiting g")
  }
  return a + b
}
```

Or tie directly into an existing tracing library such as [swift-distributed-tracing](https://swiftpackageindex.com/apple/swift-distributed-tracing):

```swift
@Traced("Doing complicated math")
func h(a: Int, b: Int) -> Int {
  return a + b
}
```

which could expand to:

```swift
func h(a: Int, b: Int) -> Int {
  withSpan("Doing complicated math") { span in
    return a + b
  }
}
```

## Detailed design

### Declaring function body macros

Function body macros are declared with the `body` or `preamble` role, which indicate that they can be attached to any kind of function, and can produce the contents of a function body. For example, here are declarations for the macros used above:

```swift
@attached(body) macro Remote() = #externalMacro(...)

@attached(preamble) macro Logged() = #externalMacro(...)

@attached(body) macro Traced(_ name: String? = nil) = #externalMacro(...)
```

Like other attached macros, function body macros have no return type.  A `preamble` macro cannot produce any non-unique names; for rationale, see the detailed section on type checking of the function bodies later.

### Implementing function body macros

Body macros are implemented with a type that conforms to the `BodyMacro` protocol:

```swift
/// Describes a macro that can create the body for a function.
public protocol BodyMacro: AttachedMacro {
  /// Expand a macro described by the given custom attribute and
  /// attached to the given declaration and evaluated within a
  /// particular expansion context.
  ///
  /// The macro expansion introduces code block items that will become the body for the
  /// given function. Any existing body will be implicitly ignored.
  static func expansion(
    of node: AttributeSyntax,
    providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
    in context: some MacroExpansionContext
  ) throws -> [CodeBlockItemSyntax]
}
```

That function may have a function body, which will be replaced by the code items produced from the macro implementation.

Preamble macros are implemented with a type that conforms to the `PreambleMacro` protocol:

```swift
/// Describes a macro that can introduce "preamble" code into an existing
/// function body.
public protocol PreambleMacro: AttachedMacro {
  /// Expand a macro described by the given custom attribute and
  /// attached to the given declaration and evaluated within a
  /// particular expansion context.
  ///
  /// The macro expansion can introduce code items that form a preamble to
  /// the body of the given function. The code items produced by this macro
  /// expansion will be inserted at the beginning of the function body.
  static func expansion(
    of node: AttributeSyntax,
    providingPreambleFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
    in context: some MacroExpansionContext
  ) throws -> [CodeBlockItemSyntax]
}
```

Preamble macros don't provide a complete function body. Rather, they provide code items that will be introduced at the beginning of the existing function body. Preamble macros are useful for injecting code without changing anything else about the function body, for example to introduce logging or simple tracing facilities. The `defer` statement can be used to trigger code that will run once the function returns.

### Composing function body macros

At most one `body` macro can be applied to a given function. It receives the function declaration to which it is attached as it was written in the source code and produces a new function body.

Any number of `preamble` macros can be applied to a given function. Each sees the function declaration to which it is attached as it was written in the source code, and produces code items that will be introduced at the beginning of the function body. The code items produced by the `preamble` macros will be applied in the order that the preamble macro attributes are applied in the source.

For example, given:

```swift
@A @B @C func f() { print("hello") }
```

Where `A` and `B` are preamble macros and `C` is a function body macro, each macro will see the same declaration of `f`. The resulting function body for `f` will involve the code items produced by all three macros as follows:

```swift
{
  // code items produced by preamble macro A
  // code items produced by preamble macro B
  // code items produced by function body macro C
}
```

### Type checking of functions involving function body macros

When a function body macro is applied, the macro-expanded function body will need to be type checked when it is incorporated into the program. However, the function might already have a body that was written by the developer, which can be inspected by the macro implementation. The function body as written must be syntactically well-formed (i.e., it must conform to the [Swift grammar](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/summaryofthegrammar/)) but will *not* be type-checked, so it need not be semantically well-formed. For example, it could include references to entities that are introduced by the macro, such as the `span` variable introduced by the `@Traced` macro:

```swift
@Traced("Doing complicated math")
func myMath(a: Int, b: Int) -> Int {
  span.attributes["operation"] = "addition" // note: would not type-check by itself due to missing "span"
  return a + b
}
```

This approach follows what other attached macros do: they operate on the syntax of the declaration to which they are attached, and the declaration itself need not have been type-checked before the macro is expanded. However,  this approach does lend itself to potential abuse. For example, one could create a ` SQL` macro that expects the function body to be a SQL statement, then rewrites that into code that executes the query. For example, the input could be:

```swift
@SQL
func employees(hiredIn year: Int) -> [String] {
  SELECT 
    name
  FROM
    employees
  WHERE
    YEAR(hire_date) = year;
}
```

However, this would only work for places where the SQL grammar is a subset of the Swift grammar. Collapsing the same function into two lines would produce an error because it is not syntactically well-formed Swift:

```swift
@SQL
func employees(hiredIn year: Int) -> [String] {
  SELECT name FROM employees        // error: consecutive statements on a line must be separated by ';'
    WHERE YEAR(hire_date) = year;
}
```

The requirement for syntactic wellformedness should help rein in the more outlandish uses of function body macros, as well as making sure that existing tools that operate on source code will continue to work well even in the presence of body macros.

## Source compatibility

Function body macros introduce new macro roles into the existing attached macro syntax, and therefore do not have an impact on source compatibility.

## Effect on ABI stability

Macros are a source-to-source transformation tool that have no ABI impact.

## Effect on API resilience

Macros are a source-to-source transformation tool that have no effect on API resilience.

## Alternatives considered

### Eliminating preamble macros

Preamble macros aren't technically necessary, because one could always write a function body macro that injects the preamble code into an existing body. However, preamble macros provide several end-user benefits over function body macros for the cases where they apply:

* Preamble macros can be composed, whereas function body macros cannot.
* Preamble macros are separately type-checked, so the function body as written can be type-checked independently of the macro expansion, providing a better user experience (e.g., for diagnostics, code completion, and so on).

### Capturing the `withSpan` pattern in another macro role

The `withSpan` function used in the `Traced` macro example is one instance of a fairly general pattern in Swift, where a `with<something>` function accepts a closure argument and runs it with some extra contextual parameters. As we did with the `preamble` macro role, we could introduce a special macro role that describes this pattern: the macro would not see the function body that was written by the developer at all, but would instead have a function value representing the body that it could call opaquely. For example, the `Traced` example function `h` would expand to:

```swift
func h(a: Int, b: Int) -> Int {
  withSpan("Doing complicated math", body: h-impl)
}
```

With this approach, the original function body for `h` would be type-checked prior to macro expansion, and then would be handed off to the macro as an opaque value `h-impl` to be called by `withSpan`. The macro could introduce its own closure wrapping that body as needed, e.g.,

```swift
@Traced("Doing complicated math") { span in 
  span.attributes["operation"] = "addition"
}
func myMath(a: Int, b: Int) -> Int {
  return a + b
}
```

could expand to:

```swift
func myMath(a: Int, b: Int) -> Int {
  return withSpan("Doing complicated math") { span in 
    span.attributes["operation"] = "addition"
    return myMath-impl()
  }
}
```

The advantage of this approach over allowing a `body` macro to replace a body is that we can type-check the  function body as it was written, and only need to do so once---then it becomes a value of function type that's passed along to the underying macro. Also like preamble macros, this approach can compose, because the result of one macro could produce another value of function type that can be passed along to another macro.

On the other hand, having a third kind of macro role for function body macros adds yet more language complexity, and introducing this role in lieu of allowing function body macros to replace an existing function body might be overfitting to today's use cases.

### Type-checking bodies as they were written

As noded previously, not checking the body of functions that was written by the user and then replaced by a `body` macro has some down sides. For one, it allows some abuse, where code that wouldn't make sense in Swift is permitted to be written by the user and then significantly altered by the `body` macro. Moreover, wherever the macro is performing some modification that makes ill-formed code into well-formed code (even by something as simple as introducing a `span` variable like `@Tracing` does), tools that cannot reason about the macro expansion might be less useful: code completion won't know to provide `span` as a possible completion, nor will it know what type `span` would have. Therefore, the experience of writing code that makes use of `body` macros could be significantly worse than that for normal Swift code.

On the other hand, type-checking the function bodies before macro expansion has other issues. Type checking is a significant part of compilation time, and having to type-check the body of a function twice---once before macro expansion, once after---could be prohibitively expensive. Type-checking the function body before macro expansion also limits what can be expressed by body macros, including making some use cases (like the `@Traced` macro described earlier) impossible to express without more extensions to the model.

### Introducing names in body macros

It's possible that one could extend macro declarations to provide more information about names introduced by the macro along with their types. for example, `@Traced` could introduce `span` with type `Span`:

```swift
@attached(body, names: named(span: Span)) 
macro Traced(_ name: String? = nil) = #externalMacro(...)
```

This would allow code completion and other tools to reason about the existence and type of `span` without expanding the macro. This could be viewed as an extension of the current proposal, which could be introduced later to aid tools. We do not propose this extension now because it isn't clear whether it is necessary (the problems envisioned might be too small to matter) or sufficient (we might need a more expressive mechanism to address the problems we find in practice with body macros).