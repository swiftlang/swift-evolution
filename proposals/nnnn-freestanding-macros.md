# Freestanding Macros

* Proposal: [SE-nnnn](nnnn-freestanding-macros.md)
* Authors: [Doug Gregor](https://github.com/DougGregor), [Richard Wei](https://github.com/rxwei), [Holly Borla](https://github.com/hborla)
* Review Manager: Unassigned
* Status: **Pending review**
* Implementation: On `main` behind the experimental flag `Macros`
* Review:

## Introduction

 [SE-0382 "Expression macros"](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md) introduces macros into Swift. The approach involves an explicit syntax for uses of macros (prefixed by `#`), type checking for macro arguments prior to macro expansion, and macro expansion implemented via separate programs that operate on the syntax tree of the arguments.

This proposal generalizes the `#`-prefixed macro expansion syntax introduced for expression macros to also allow macros to generate declarations and statements, enabling a number of other use cases, including:

* Subsuming the `#warning` and `#error` directives introduced in [SE-0196](https://github.com/apple/swift-evolution/blob/main/proposals/0196-diagnostic-directives.md) into macros.
* Logging entry/exit of a function.

## Proposed solution

The proposal introduces "freestanding" macros, which are expanded to create zero or more new declarations, statements, and expressions. The generated declarations can  be referenced from other Swift code, making freestanding macros useful for many different kinds of code generation and manipulation.

All freestanding macros use the `#`-prefixed syntax introduced in [SE-0382 "Expression macros"](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md) , building on and generalizing its design. Indeed, this proposal reclassifies expression macros as one form of freestanding macros, introducing two additional kinds of freestanding macro:

* *Declaration macros* introduce zero or more declarations. These macros can be used anywhere where a declaration is permitted, including at the top level, in a function or closure body, or in a type definition or extension thereof. 
* *Code item* macros introduce a mix of statements, expressions, and declarations. These macros can be used wherever one can write a statement, including at the top level (for Swift scripts or main files) and in the body of a function or closure.

Freestanding macros are declared with the `macro` introducer, and have one or more `@freestanding` attributes applied to them. The `@freestanding` attribute always contains a macro *role* (expression, declaration, or code item) and, optionally, a set of *introduced names*. For example, a freestanding code item macro would have an attribute like this:

```swift
@freestanding(codeItem)
```

whereas a declaration macro that introduced an enum named `CodingKeys` would have an attribute like this:

```swift
@freestanding(declaration, names: named(CodingKeys))
```

Implementations of freestanding macros are types that conform to the `FreestandingMacro` protocol, which is defined as follows:

```swift
protocol FreestandingMacro: Macro { }
```

### Expression macros

As previously noted, expression macros are one form of freestanding macro. As such, we revise the definition of the `ExpressionMacro` protocol provided in [SE-0382 "Expression macros"](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md)  by making it refine `FreestandingMacro`:

```swift
protocol ExpressionMacro: FreestandingMacro {
  // ...
}
```

Additionally, we replace the `@expression` attribute introduced in SE-0382 with `@freestanding(expression)`. For example, the `stringify` macro would be declared as follows:

```swift
@freestanding(expression) macro stringify<T>(_: T) -> (T, String)
```

Expression macros can be used anywhere that a declaration is permitted, e.g., within the body of a function or closure, or as a subexpression anywhere. Their implementations always produce another expression.

### Declaration macros

Declaration macros can be used anywhere that a declaration is permitted, e.g., in a function or closure body, at the top level, or within a type definition or extension thereof. Declaration macros produce zero or more declarations. The `warning` directive introduced by [SE-0196](https://github.com/apple/swift-evolution/blob/main/proposals/0196-diagnostic-directives.md) can be described as a freestanding declaration macro as follows:

```swift
/// Emits the given message as a warning, as in SE-0196.
@freestanding(declaration) macro warning(_ message: String)
```

Given this macro declaration, the syntax

```swift
#warning("unsupported configuration")
```

can be used anywhere a declaration can occur. 

Freestanding macros are implemented as types that conform to the `DeclarationMacro` protocol :

```swift
public protocol DeclarationMacro: FreestandingMacro {
  /// Expand a macro described by the given freestanding macro expansion declaration
  /// within the given context to produce a set of declarations.
  static func expansion(
    of node: MacroExpansionDeclSyntax, in context: any MacroExpansionContext
  ) throws -> [DeclSyntax]
}
```

The `MacroExpansionDeclSyntax` node provides the syntax tree for the use site (e.g., `#warning("unsupported configuration")`), and has the same grammar and members as the `MacroExpansionExprSyntax` node introduced in [SE-0382](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md#macro-expansion). The grammar parallels `macro-expansion-expression`:

```
declaration -> macro-expansion-declaration
macro-expansion-declaration -> '#' identifier generic-argument-clause[opt] function-call-argument-clause[opt] trailing-closures[opt]
```

The implementation of a  `warning` declaration macro extracts the string literal argument (producing an error if there wasn't one) and emits a warning. It returns an empty list of declarations:

```swift
public struct WarningMacro: DeclarationMacro {
  public static func expansion(
    of node: MacroExpansionDeclSyntax, in context: inout MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let messageExpr = node.argumentList.first?.expression?.as(SpecializeExprSyntax.self),
        messageExpr.segments.count == 1,
        let firstSegment = messageExpr.segments.first,
        case let .stringSegment(message) = firstSegment else {
    	throw SimpleError(node, "warning macro requires a non-interpolated string literal")
    }

    context.diagnose(.warning(firstSegment.text))
    return []
  }
}
```

A macro that does introduce declarations needs to document the names it introduces. The `@freestanding` attribute has a `names` argument that provides the names introduced by a macro. For example, consider a macro that declares a `main` function suitable for use with the [`@main` attribute](https://github.com/apple/swift-evolution/blob/main/proposals/0281-main-attribute.md) but that handles an exit code, e.g.,

```swift
#main {
  if hasBadArgument() { return -1 }
  if noNetwork() { return -2 }  
  return 0
}
```

will generate code such as:

```swift
static func unique_name() -> Int {
  if hasBadArgument() { return -1 }
  if noNetwork() { return -2 }  
  return 0
}

static func main() {
  guard let exit_code = unique_name(), exit_code == 0 else {
    exit(exit_code)
  }
  
  return 0
}
```

The `main` attribute would be declared as follows:

```swift
@freestanding(declaration, names: named(main))
```

This specifies that the macro will produce a declaration named `main`. It is also allowed to produce declarations with names produced by `MacroExpansionContext.createUniqueName` (implied by `unique_name` in the example above) without documenting them, because they are not visible to other parts of the program not generated by the macro. The reasons for documenting macro names are provided within the detailed design.

### Code item macros

Code item macros can produce any mix of declarations, statements, and expressions, which are collectively called "code items" in the grammar. Code item macros can be used for top-level code and within the bodies of functions and closures. They are declaration with `@freestanding(codeItem)`. For example, we could declare a macro that logs when we are entering and exiting a function:

```swift
@freestanding(declaration) macro logEntryExit(arguments: Any...)
```

Code item macros are implemented as types conforming to the `CodeItemMacro` protocol:

```swift
public protocol CodeItemMacro: FreestandingMacro {
  /// Expand a macro described by the given freestanding macro expansion declaration
  /// within the given context to produce a set of code items, which can be any mix of
  /// expressions, statements, and declarations.
  static func expansion(
    of node: MacroExpansionDeclSyntax, in context: any MacroExpansionContext
  ) throws -> [CodeBlockItemSyntax]
}
```

The `logEntryExit` macro could introduce code such as:

```swift
print("- Entering \(#function)(\(arguments))")
defer {
  print("- Exiting \(#function)(\(arguments))")  
}
```

## Detailed design

### Up-front declarations of newly-introduced names

Whenever a macro produces declarations that are visible to other Swift code, it is required to declare the names in advance. This enables the Swift compiler and related tools to better reason about the set of names that can be introduced by a given use of a macro without having to expand the macro (or type-check its arguments), which can reduce the compile-time cost of macros and improve incremental builds. All of the names need to be specified within the attribute declaring the macro role, using the following forms:

* Declarations with a specific fixed name: `named(<declaration-name>)`.
* Declarations whose names cannot be described statically, for example because they are derived from other inputs: `arbitrary`.

Multiple names can be provided after the `names` label, e.g.,

```swift
@freestanding(declarations, names: named(CodingKeys), named(init(coder:)), named(encode(with:)))
macro codable: Void
```

A macro can only introduce new declarations whose names are covered by the kinds provided, or have their names generated via `MacroExpansionContext.createUniqueName`. This ensures that, in most cases (where `.arbitrary` is not specified) the Swift compiler and related tools can reason about the set of names that will be introduced by a given use of a declaration macro without having to expand the macro, which can reduce the compile-time cost of macros and improve incremental builds.

### Macros in the Standard Library

#### SE-0196 `warning` and `error`

The `#warning` and `#error` directives introduced in [SE-0196](https://github.com/apple/swift-evolution/blob/main/proposals/0196-diagnostic-directives.md): can be implemented directly as declaration macros:

```swift
/// Emit a warning containing the given message.
@freestanding(declaration) macro warning(_ message: String)

/// Emit an error containing the given message
@freestanding(declaration) macro error(_ message: String)
```

## Source compatibility

Freestanding declaration macros use the same syntax introduced for expression macros, which were themselves a pure extension without an impact on source compatibility. There is a syntactic ambiguity between expression and freestanding declaration macros, i.e., `#warning("watch out")` within a function body could be either an expression or a declaration. The distinction will need to be determined semantically, by determining whether the named macro is either an expression or a freestanding declaration macro.

Attached declaration macros use the same syntax introduced for custom attributes (such as property wrappers), and therefore do not have an impact on source compatibility.

## Effect on ABI stability

Macros are a source-to-source transformation tool that have no ABI impact.

## Effect on API resilience

Macros are a source-to-source transformation tool that have no effect on API resilience.

## Alternatives considered

## Future directions

(nothing just yet)
