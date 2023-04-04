# Freestanding Macros

* Proposal: [SE-nnnn](nnnn-freestanding-macros.md)
* Authors: [Doug Gregor](https://github.com/DougGregor), [Richard Wei](https://github.com/rxwei), [Holly Borla](https://github.com/hborla)
* Review Manager: Unassigned
* Status: **Pending review**
* Implementation: On `main` behind the experimental flag `FreestandingMacros`
* Review:

## Introduction

 [SE-0382 "Expression macros"](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md) introduces macros into Swift. The approach involves an explicit syntax for uses of macros (prefixed by `#`), type checking for macro arguments prior to macro expansion, and macro expansion implemented via separate programs that operate on the syntax tree of the arguments.

This proposal generalizes the `#`-prefixed macro expansion syntax introduced for expression macros to also allow macros to generate declarations and statements, enabling a number of other use cases, including:

* Subsuming the `#warning` and `#error` directives introduced in [SE-0196](https://github.com/apple/swift-evolution/blob/main/proposals/0196-diagnostic-directives.md) into macros.
* Logging entry/exit of a function.

## Proposed solution

The proposal introduces "freestanding" macros, which are expanded to create zero or more new declarations and expressions. The generated declarations can be referenced from other Swift code, making freestanding macros useful for many different kinds of code generation and manipulation.

All freestanding macros use the `#`-prefixed syntax introduced in [SE-0382 "Expression macros"](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md) , building on and generalizing its design. Indeed, this proposal reclassifies expression macros as one form of freestanding macros, introducing one additional kind of freestanding macro:

* *Declaration macros* introduce zero or more declarations. These macros can be used anywhere where a declaration is permitted, including at the top level, in a function or closure body, or in a type definition or extension thereof. 

Freestanding macros are declared with the `macro` introducer, and have one or more `@freestanding` attributes applied to them. The `@freestanding` attribute always contains a macro *role* (expression or declaration) and, optionally, a set of *introduced names* like attached macros. For example, a freestanding declaration macro would have an attribute like this:

```swift
@freestanding(declaration)
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

As previously noted, expression macros are one form of freestanding macro. [SE-0382 "Expression macros"](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md)  already introduced the `FreestandingMacro` protocol and the `ExpressionMacro` protocol that inherits from it:

```swift
protocol ExpressionMacro: FreestandingMacro {
  // ...
}
```

As well as the `@freestanding(expression)` syntax:

```swift
@freestanding(expression) macro stringify<T>(_: T) -> (T, String)
```

Expression macros can be used anywhere that an expression is permitted, e.g., within the body of a function or closure, or as a subexpression anywhere. Their implementations always produce another expression.

### Declaration macros

Declaration macros can be used anywhere that a declaration is permitted, e.g., in a function or closure body, at the top level, or within a type definition or extension thereof. Declaration macros produce zero or more declarations. The `warning` directive introduced by [SE-0196](https://github.com/apple/swift-evolution/blob/main/proposals/0196-diagnostic-directives.md) can be described as a freestanding code item macro as follows:

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
    of node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext
  ) async throws -> [DeclSyntax]
}
```

The `MacroExpansionDeclSyntax` node provides the syntax tree for the use site (e.g., `#warning("unsupported configuration")`), and has the same grammar and members as the `MacroExpansionExprSyntax` node introduced in [SE-0382](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md#macro-expansion). The grammar parallels `macro-expansion-expression`:

```
declaration -> macro-expansion-declaration
macro-expansion-declaration -> '#' identifier generic-argument-clause[opt] function-call-argument-clause[opt] trailing-closures[opt]
```

The implementation of a `warning` declaration macro extracts the string literal argument (producing an error if there wasn't one) and emits a warning. It returns an empty list of declarations:

```swift
public struct WarningMacro: DeclarationMacro {
  public static func expansion(
    of node: some FreestandingMacroExpansionSyntax, in context: inout MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let messageExpr = node.argumentList.first?.expression.as(StringLiteralExprSyntax.self),
          messageExpr.segments.count == 1,
          let firstSegment = messageExpr.segments.first,
          case let .stringSegment(message) = firstSegment else {
      throw SimpleError(node, "warning macro requires a non-interpolated string literal")
    }

    context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnosticMessage(
      message: message.description,
      diagnosticID: .init(domain: "test", id: "error"),
      severity: .warning)))
    return []
  }
}
```

A macro that does introduce declarations needs to document the names it introduces. Just like `@attached`, the `@freestanding` attribute has a `names` argument that provides the names introduced by a macro. For example, consider a macro that declares a `main` function suitable for use with the [`@main` attribute](https://github.com/apple/swift-evolution/blob/main/proposals/0281-main-attribute.md) but that handles an exit code, e.g.,

```swift
@main
struct App {
  #main {
    if hasBadArgument() { return -1 }
    if noNetwork() { return -2 }  
    return 0
  }
}
```

will be expanded to:

```swift
@main
struct App {
  static func $_unique_name() -> Int {
    if hasBadArgument() { return -1 }
    if noNetwork() { return -2 }  
    return 0
  }

  static func main() {
    guard let exitCode = $_unique_name(), exitCode == 0 else {
      exit(exitCode)
    }
  }
}
```

The `main` macro would be declared as follows:

```swift
@freestanding(declaration, names: named(main))
macro main(_ body: () -> Int)
```

This specifies that the macro will produce a declaration named `main`. It is also allowed to produce declarations with names produced by `MacroExpansionContext.makeUniqueName(_:)` (implied by `$_unique_name` in the example above) without documenting them, because they are not visible to other parts of the program not generated by the macro. The reasons for documenting macro names are provided within the detailed design.

## Detailed design

### Syntax

The syntactic representation of a freestanding macro expansion site is a macro expansion declaration. A macro expansion declaration is described by the following grammar. It has the same production rule as a macro expansion expression.

```
declaration -> macro-expansion-declaration
macro-expansion-declaration -> '#' identifier generic-argument-clause[opt] function-call-argument-clause[opt] trailing-closures[opt]
```

At top level and function scope where both expressions and declarations are allowed, a freestanding macro expansion site is first parsed as a macro expansion expression. It will be replaced by a macro expansion declaration later during type checking, if the macro resolves to a declaration macro. This is to allow the following expressions to still be parsed correctly as an expression.

```swift
#line + 1
#line as Int?
```

### Composing macro roles

A freestanding macro can be declared as both an expression macro and a declaration macro.

```swift
@freestanding(expression)
@freestanding(declaration)
macro dualRoleMacro()
```

In this case, we expand it based on its expansion context. If it's being expanded where an declaration is allowed, it will always be expanded to a declaration. Otherwise, it's expanded as an expression.

```swift
// File scope
#dualRoleMacro // expanded as a declaration

func foo() {
  #dualRoleMacro // expanded as a declaration
    
  _ = #dualRoleMacro // expanded as an expression
    
  bar(#dualRoleMacro) // expanded as an expression
    
  takesClosure {
    #dualRoleMacro // expanded as a declaration
  }
}
```

### Restrictions

Like attached peer macros, a freestanding macro can expand to any declaration that is syntatically and semantically well-formed within the context where the macro is expanded, but also share the same requirements and restrictions.

- [Specifying newly-introduced names](https://github.com/apple/swift-evolution/blob/main/proposals/0389-attached-macros.md#specifying-newly-introduced-names)
  - Note that only `named(...)` and `arbitrary` are allowed as macro-introduced names for a declaration macro.
- [Visibility of names used and introduced by macros](https://github.com/apple/swift-evolution/blob/main/proposals/0389-attached-macros.md#visibility-of-names-used-and-introduced-by-macros)
- [Permitted declaration kinds](https://github.com/apple/swift-evolution/blob/main/proposals/0389-attached-macros.md#permitted-declaration-kinds)

### Examples

#### SE-0196 `warning` and `error`

The `#warning` and `#error` directives introduced in [SE-0196](https://github.com/apple/swift-evolution/blob/main/proposals/0196-diagnostic-directives.md): can be implemented directly as declaration macros:

```swift
/// Emit a warning containing the given message.
@freestanding(declaration) macro warning(_ message: String)

/// Emit an error containing the given message
@freestanding(declaration) macro error(_ message: String)
```

### Boilerplate generation

Freestanding declaration macros can be used to generate boilerplace code. For example, the Standard Library could use such a macro to generate integer types.

```swift
@freestanding(declaration)
fileprivate macro IntegerTypes(_ bitWidth: Int...)

#IntegerTypes(bitWidths: 8, 16, 32, 64)
```

This expands to:

```swift
public struct Int8 { ... }
public struct UInt8 { ... }

public struct Int16 { ... }
public struct UInt16 { ... }

public struct Int32 { ... }
public struct UInt32 { ... }

public struct Int64 { ... }
public struct UInt64 { ... }
```

### Short hand for `@main`

A freestanding declaration macro `#main` could be defined as a short hand for a `@main` struct with a `main()` method.

```swift
@freestanding(declaration)
macro main(_ body: () -> Void)

#main {
  print("Hello")
}
```

This expands to:

```swift
@main
struct $_unique_name {
  static func main() {
    print("Hello")
  }
}
```

### Environment values

In apps built with SwiftUI, environment properties are declared with the `@Environment` property wrapper. In most cases, environment properties have the same identifier as the key path passed to `@Environment`, but are prone to typographical errors because the language won't enforce the same spelling. 

```swift
struct ContentView: View {
  @Environment(\.menuOrder) var menuOrder 
}
```

One could define an `#EnvironmentProperty` macro such that the identifier only needs to be spelled once as part of the key path.

```swift
@freestanding(declaration)
macro EnvironmentProperty<Value>(_ keyPath: KeyPath<EnvironmentValues, Value>)

struct ContentView: View {
  #EnvironmentProperty(\.menuOrder)
}
```

This expands to:

```swift
struct ContentView: View {
  @Environment(\.menuOrder) var menuOrder
}
```

## Source compatibility

Freestanding macros use the same syntax introduced for expression macros, which were themselves a pure extension without an impact on source compatibility. There is a syntactic ambiguity between expression and freestanding declaration macros, i.e., `#warning("watch out")` within a function body could be either an expression or a declaration. The distinction will need to be determined semantically, by determining whether the named macro is either an expression or a freestanding declaration macro.

Attached declaration macros use the same syntax introduced for custom attributes (such as property wrappers), and therefore do not have an impact on source compatibility.

## Effect on ABI stability

Macros are a source-to-source transformation tool that have no ABI impact.

## Effect on API resilience

Macros are a source-to-source transformation tool that have no effect on API resilience.

## Alternatives considered

N/A

## Revision History

- Scoped code item macros out as a future direction.  

## Future directions

### Code item macros

A code item macro is another kind of freestanding macro that can produce any mix of declarations, statements, and expressions, which are collectively called "code items" in the grammar. Code item macros can be used for top-level code and within the bodies of functions and closures. They are declaration with `@freestanding(codeItem)`. For example, we could declare a macro that logs when we are entering and exiting a function:

```swift
@freestanding(codeItem) macro logEntryExit(arguments: Any...)
```

Code item macros are implemented as types conforming to the `CodeItemMacro` protocol:

```swift
public protocol CodeItemMacro: FreestandingMacro {
  /// Expand a macro described by the given freestanding macro expansion declaration
  /// within the given context to produce a set of code items, which can be any mix of
  /// expressions, statements, and declarations.
  static func expansion(
    of node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext
  ) async throws -> [CodeBlockItemSyntax]
}
```

The `logEntryExit` macro could introduce code such as:

```swift
print("- Entering \(#function)(\(arguments))")
defer {
  print("- Exiting \(#function)(\(arguments))")  
}
```

Code item macros can only introduce new declarations that have unique names, created with `makeUniqueName(_:)`. They cannot introduce named declarations, because doing so affects the ability to type-check without repeatedly expanding the macro with potentially complete information. See the section on the visibility of names used and introduced by macros.
