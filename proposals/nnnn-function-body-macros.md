# Function Body Macros

* Proposal: [SE-NNNN](nnnn-function-body-macros.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: 
* Status: **Awaiting review**
* Implementation: 
* Review: 

[TOC]

## Introduction

Macros augment Swift programs with additional code, which can include new declarations, expressions, and statements. One of the key ways in which one might want to augment code---synthesizing or updating the body of a function---is not currently supported by the macro system. One can create new functions that have their own function bodies, but not provide function bodies for a function declared the by user.

This proposal introduces *function body macros*, which do exactly that: allow the wholesale synthesis of function bodies given a declaration, as well as augmenting an existing function body with more functionality. This opens up a number of new use cases for macros, including:

* Synthesizing function bodies given the function declaration and some metadata, such as automatically synthesizing remote procedure calls that pass along the provided arguments.
* Augmenting function bodies to perform logging/tracing, check preconditions, or establish invariants.

## Proposed solution

This proposal introduces *function body macros*, which are [attached macros](https://github.com/apple/swift-evolution/blob/main/proposals/0389-attached-macros.md) that can create or augment a function (including initializers, deinitializers, and accessors) with a new body. For example, one could introduce a `Remote` macro that packages up arguments for a remote procedure call:

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

Or tying directly into an existing tracing library such as [swift-distributed-tracing](https://swiftpackageindex.com/apple/swift-distributed-tracing):

```swift
@Traced("Doing complicated math")
func h(a: Int, b: Int) -> Int {
  return a + b
}
```

which could expand to:

```swift
func h(a: Int, b: Int) -> Int {
  withSpan("Doing complicated math") { _ in
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
    providingBodyFor declaration: some DeclSyntaxProtocol & HasTrailingOptionalCodeBlock,
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
    providingPreambleFor declaration: some DeclSyntaxProtocol & HasTrailingOptionalCodeBlock,
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

When a function body macro is applied to a macro, the macro-expanded function body will need to be type checked. However, the function might already have a body that was written by the developer, which can be inspected by the macro. What level of checking should be applied to the function body that was written for `h` prior to expansion? On the one hand, macros [type check their arguments](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md#type-checked-macro-arguments-and-results) because it provides a better user experience---IDE features work on macro arguments, and the macro arguments are just normal Swift code. The same argument could be made for the function bodies as they are written, prior to macro expansion: if they are fully type-checked prior to expansion, then the bodies are easier to reason about for programmers and also for tools.

On the other hand, type-checking the function bodies before macro expansion has other issues. For one, the declarations to which an attached macro is attached are generally not type-checked at all prior to expansion, so type-checking the body prior to expansion would be a departure from that. Additionally, type-checking a function body can be expensive at compile time, and doing that work twice (once for the function body as-written, once after expansion) could increase compile times unacceptably. Finally, type-checking the function body before macro expansion limits what can be expressed by function body macros.

There is no clear-cut answer, so we categorize function body macros into three general kinds:

* Macros that create function bodies when there is no existing function body, such as the `Remote` macro that creates the boilerplate for a remote procedure call given the declaration of the function.
* Macros that inject code at the beginning of an existing function body, such as the `Logged` macro that adds `log` calls at the beginning of the function along with a `defer` to trigger the log at the end of the function.
* Macros that rewrite function bodies into another function body, such as the `Traced` macro that puts the existing function body into a closure passed along to the `withSpan` function.

For the first kind, there is no existing function body to type check ahead of time, so we can ignore it for the purposes of this discussion. 

The second kind is expected to be common, because a lot of boilerplate occurs at the beginning of a function to (e.g.) perform extra validation on the input arguments. As previously noted, `defer` also allows macros of this kind to perform cleanup actions before leaving the function, covering a number of other use cases. The `preamble` macro role specifically addresses this kind of function body macro, and provides an opportunity for special type checking behavior. Specifically, the existing body of the function is type-checked independently of any `preamble` macro expansion. Preamble macros are restricted to only introduce unique names to ensure that the code produced by expanding a preamble macro cannot change the way that the existing body is type-checked. The code items produced by expanding `preamble` macros are also type-checked independently, and spliced into the final function body. This way, the code in the function body is always treated as-if there were no macros, with preamble macros augmenting (but not changing) the final result.

The third kind of macro is the complicated case, because the macro itself can completely change the body of the function. This proposal opts *not* to type-check the function body that was written prior to expanding the macro: the function body must be syntactically correct, but need not be well-typed and may even refer to entities that do not exist prior to the macro expansion. This follows how attached macros generally work (the declaration to which they are attached has not been fully checked) and is eliminates redundant type checking work for function bodies. However, it will have negative effects on the quality of tooling, which cannot necessarily relate the code as written with the expanded code. For example, this design enables the following `Traced` implementation, which injects a `span` variable that can be used in the original function body despite it only being declared by the macro expansion:

```swift
@Traced("Doing complicated math", spanName: "span")
func myMath(a: Int, b: Int) -> Int {
  span.attributes["operation"] = "addition"   // note: would not type-check by itself
  return a + b
}
```

This could be expanded to the following:

```swift
func myMath(a: Int, b: Int) -> Int {
  withSpan("Doing complicated math") { span in 
    span.attributes["operation"] = "addition"
    return a + b
  }
}
```

Because the `span` parameter isn't known prior to macro expansion, various tools are unlikely to work well with it: for example, code completion won't know the type of `span` and therefore can't provide code completion for the members of it after `span.`. Other tools such as Jump-To-Definition are unlikely to work without some amount of heuristic guessing. 

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