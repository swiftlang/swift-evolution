# Expression Macros

* Proposal: [SE-NNNN](NNNN-expression-macros.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting implementation**

* Implementation: Partial implementation is available in `main` under the experimental feature flag `Macros`.

## Introduction

Expression macros provide a way to extend Swift with new kinds of expressions, which can perform arbitary syntactic transformations on their arguments to produce new code. Expression macros make it possible to extend Swift in ways that were only previously possible by introducing new language features, helping developers build more expressive libraries and eliminate extraneous boilerplate.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

Expression macros are one part of the [vision for macros in Swift](https://forums.swift.org/t/a-possible-vision-for-macros-in-swift/60900), which lays out general motivation for introducing macros into the language. Expressions in particular are an area where the language already provides decent abstractions for factoring out runtime behavior, because one can create a function that you call as an expression from anywhere. However, with a few hard-coded exceptions like `#file` and `#line`, an expression cannot reason about or modify the source code of the program being compiled. Such use cases will require external source-generating tools, which don't often integrate cleanly with other tooling.

## Proposed solution

This proposal introduces the notion of expression macros, which are used as expressions in the source code (marked with `#`) and are expanded into expressions. Expression macros can have parameters and a result type, much like a function, which describes the effect of the macro expansion on the expression without requiring the macro to actually be expanded first.

The actual macro expansion is implemented with source-to-source translation on the syntax tree: the expression macro is provided with the syntax tree for the macro expansion itself (e.g., starting with the `#` and ending with the last argument), which it can rewrite into the expanded syntax tree. That expanded syntax tree will be type-checked against the result type of the macro.

As a simple example, let's consider a `stringify` macro that takes a single argument as input and produces a tuple containing both the original argument and also a string literal containing the source code for that argument. This macro could be used in source code as, for example:

```swift
#stringify(x + y)
```

and would be expanded into

```swift
(x + y, "x + y")
```

The type signature of a macro is part of its declaration, which looks a lot like a function:

```swift
macro stringify<T>(_: T) -> (T, String)
```

### Type-checked macro arguments and results

Macro arguments are type-checked against the parameter types of the macro. For example, the macro argument `x + y` will be type-checked; if it is ill-formed (for example, if `x` is an `Int` and `y` is a `String`), the macro will never be expanded. If it is well-formed, the generic parameter `T` will be inferred to the result of `x + y`, and that type is carried through to the result type of the macro. There are several benefits to this type-checked model:

* Macro implementations are guaranteed to have well-typed arguments as inputs, so they don't need to be concerned about incorrect code being passed into the macro.
* Tools can treat macros much like functions, providing the same affordances for code completion, syntax highlighting, and so on, because the macro arguments follow the same rules as other Swift code. 
* A macro expansion expression can be partially type-checked without having to expand the macro. This allows tools to still have reasonable results without performing macro expansion, as well as improving compile-time performance because the same macro will not be expanded repeatedly during type inference.

When the macro is expanded, the expanded syntax tree is type-checked against the result type of the macro. In the `#simplify(x + y)` case, this means that if `x + y` had type `Int`, the expanded syntax tree (`(x + y, "x + y")`) is type-checked with a contextual type of `(Int, String)`. 

### Syntactic translation

Macro expansion is a syntactic operation, which takes as input a well-formed syntax tree consisting of the full macro expansion expression (e.g., `#stringify(x + y)`) and produces a syntax tree as output. The resulting syntax tree is then type-checked based on the macro result type.

Syntactic translation has a number of benefits over more structured approaches such as direct manipulation of a compiler's Abstract Syntax Tree (AST) or internal representation (IR):

* A macro expansion can use the full Swift language to express its effect. If it can be written as Swift source code at that position in the grammar, a macro can expand to it.
* Swift programmers understand Swift source code, so they can reason about the output of a macro when applied to their source code. This helps both when authoring and using macros.
* Source code that uses macros can be "expanded" to eliminate the use of the macro, for example to make it easier to reason about or debug, or make it work with an older Swift compiler that doesn't support macros.
* The compiler's AST and internal representation need not be exposed to clients, which would limit the ability of the compiler to evolve and improve due to backward-compatibility concerns.

On the other hand, purely syntactic translations have a number of downsides, too:

* Syntactic macro expansions are prone to compile-time failures, because we're effectively working with source code as strings, and it's easy to introduce (e.g.) syntax errors or type errors in the macro implementation.
* Syntactic macro expansions are re-parsed and re-type-checked, which incurs more compile-time overhead than an approach that (say) manipulated the AST or IR directly.
* Syntactic macros are not *hygienic*, meaning that the way in which a macro expansion is processed depends on the environment in which it is expanded, and can affect that environment. 

The proposed macro design attempts to mitigate these problems, but they are somewhat fundamental to the use of syntactic macros. On balance, the ease-of-use and easy-of-interpretation of syntactic macros outweighs these problems.

### Macros defined as separate programs

Macro definitions operate on syntax trees. Broadly speaking, there are two different ways in which a macro's expansion operation can be defined:

* *A declarative set of transformations*: this involves extending the language with a special syntax that allows macros to define how the macro is expanded given the macro inputs, and the compiler applies those rules for each macro expansion. The C preprocessor employs a simplistic form of this, but Racket's [pattern-based macros](https://docs.racket-lang.org/guide/pattern-macros.html) and Rust's [declarative macros](https://doc.rust-lang.org/book/ch19-06-macros.html#declarative-macros-with-macro_rules-for-general-metaprogramming)  offer more advanced rules that match the macro arguments to a pattern and then perform a a rewrite to new syntax as described in the macro. For Swift to adopt this approach, we would likely need to invent a pattern language for matching and rewriting syntax trees.
* *An executable program that transforms the source*: this involves running a program that manipulates the program syntax directly. How the program is executed depends a lot on the environment: [Scala 3 macros](https://docs.scala-lang.org/scala3/guides/macros/macros.html) benefit from the use of the JVM so they can intertwine target code (the program being generated) and host code (where the compiler is running), whereas Rust's [procedural macros](https://doc.rust-lang.org/reference/procedural-macros.html) are built into a separate crate that the compiler interacts with. For Swift to adopt this approach, we would either need to build a complete interpreter for Swift code in the compiler, or take an approach similar to Rust's and build macro definitions as separate programs that the compiler can interact with.

We propose the latter approach, where a macro definition is a separate program that operates on Swift syntax trees using the [swift-syntax](https://github.com/apple/swift-syntax/) package. Expression macros are defined as types that conform to the `ExpressionMacro ` protocol:

```swift
public protocol ExpressionMacro: Macro {
  /// Evaluate a macro described by the given macro expansion expression
  /// within the given context to produce a replacement expression.
  static func apply(
    _ macro: MacroExpansionExprSyntax, in context: inout MacroEvaluationContext
  ) -> MacroResult<ExprSyntax>
}
```

The `apply` method takes as arguments the syntax node for the macro expansion (e.g., `#stringify(x + y)`) and a "context" that provides more information about the compilation context in which the macro is being expanded. It produces a macro result that includes the rewritten syntax tree.

The specifics of  `Macro`, `MacroEvaluationContext`, and `MacroResult` will follow in the Detailed Design section.

### The `stringify` macro implementation

Let's continue with the implementation of the `stringify` macro. It's a new type `StringifyMacro` that conforms to `ExpressionMacro`: 

```swift
import SwiftSyntax
import SwiftSyntaxBuilder
import _SwiftSyntaxMacros

public struct StringifyMacro: ExpressionMacro {
  public static func apply(
    _ macro: MacroExpansionExprSyntax, in context: inout MacroEvaluationContext
  ) -> MacroResult<ExprSyntax> {
    guard let argument = macro.argumentList.first?.expression else {
      fatalError("compiler bug: the macro does not have any arguments")
    }

    return MacroResult("(\(argument), #\"\(argument.description)\"#)")
  }
}
```

The `apply` function is fairly small, because the `stringify` macro is pretty simple. It extracts the macro argument from the syntax tree (the `x + y` in `#stringify(x + y)`) and then forms the resulting tuple expression by interpolating in the original argument both as a value and then as source code within the string literal. That string is then parsed as an expression (producing an `ExprSyntax` node) and returned as the result of the macro expansion. This is a simple form of quasi-quoting provided by the `SwiftSyntaxBuilder` module, implemented by making the major syntax nodes (`ExprSyntax` in this case, for expressions) conform to [`ExpressibleByStringInterpolation`](https://developer.apple.com/documentation/swift/expressiblebystringinterpolation), where existing syntax nodes can be interpolated into string literals containing the expanded Swift code.

The `StringifyMacro` struct is the implementation for the `stringify` macro declared earlier. We will need to tie these together in the source code via some mechanism. One approach is to name the module and `ExpressionMacro` struct name within the macro declaration, e.g.,

```swift
macro stringify<T>(_: T) -> (T, String) = ExampleMacros.StringifyMacro
```

## Detailed design

There are two major pieces to the macro design: how macros are declared and expanded within a program, and how they are implemented as separate programs. The following sections provide additional details.

### Macro declarations

A macro declaration is described by the following grammar:

```
declaration -> macro-declaration

macro-declaration -> macro-head identifier generic-parameter-clause[opt] macro-signature '=' external-macro-name

macro-head -> attributes[opt] declaration-modifiers[opt] 'macro'

macro-signature -> parameter-clause '->' type
macro-signature -> ':' type

external-macro-name -> identifier '.' identifier
```

The signature of a macro is either function-like (`(T) -> (T, String)`) or value-like (`: Int`), depending on the form of the `macro-signature`.

Macros can only be declared at file scope. They can be overloaded in the same way as functions, so long as the argument labels, parameter types, or result type differ.

The `external-macro-name` refers to the module name (before the `.`) and type name (after the `.`) of the macro implementation. The library used to implement macros is defined below.

### Macro expansions

A macro expansion expression is described by the following grammar:

```
primary-expression -> macro-expansion-expression
macro-expansion-expression -> '#' identifier generic-argument-clause[opt] function-call-argument-clause[opt] trailing-closures[opt]
```

When either a `function-call-argument-clause` or a `trailing-closures` term is present, the identifier must refer to a function-like macro. When neither is present, the identifier must refer to a value-like macro. There is no such thing as a value of macro type.

### Macro implementation library

Macro definitions will make use of the [swift-syntax](https://github.com/apple/swift-syntax) package, which provides the Swift syntax tree manipulation and parsing capabilities for Swift tools. The `SwiftSyntaxMacros` module will provide the functionality required to define macros.

#### `Macro` protocols

The `Macro` protocol is the root protocol for all kinds of macro definitions. At present, it does not have any requirements:

```swift
public protocol Macro { }
```

The `ExpressionMacro` protocol is used to describe expression macros:

```swift
public protocol ExpressionMacro: Macro {
  /// Evaluate a macro described by the given macro expansion expression
  /// within the given context to produce a replacement expression.
  static func apply(
    _ macro: MacroExpansionExprSyntax, in context: inout MacroEvaluationContext
  ) -> MacroResult<ExprSyntax>
}
```

The `MacroExpansionExprSyntax` type is the `swift-syntax` node describing the `macro-expansion-expression` grammar term from above, so it carries the complete syntax tree (including all whitespace and comments) of the macro expansion as it appears in the source code. 

Macro definitions should conform to the `ExpressionMacro` protocol and implement their syntactic transformation via `apply`.

#### `MacroEvaluationContext`

The macro evaluation context provides additional information about the environment in which the macro is being expanded. This context can be queried as part of the macro expansion:

```swift
/// System-supplied structure that provides information about the context in
/// which a given macro is being expanded.
public struct MacroEvaluationContext {
  /// The name of the module in which the macro is being evaluated.
  public let moduleName: String

  /// Used to map the provided syntax nodes into source locations.
  public let sourceLocationConverter: SourceLocationConverter

  /// Generate a unique local name for use in the macro.
  public mutating func createUniqueLocalName() -> String
  
  /// Create a new macro evaluation context.
  public init(
    moduleName: String,
    sourceLocationConverter: SourceLocationConverter
  )
}
```

The `SourceLocationConverter` allows one to map syntax nodes to their line and column within the file, as well as providing the file name. It is useful for cases where the macro expansion wants to refer to the original source location, for example as part of logging or an assertion failure.

The `createUniqueLocalName()` function allows one to create new, unique names so that the macro expansion can produce new declarations that won't conflict with any other declarations in the same scope. This allows macros to be more hygienic, by not introducing new names that could affect the way that the code provided via macro expansion arguments is type-checked.

#### `MacroResult` 

The `MacroResult` structure describes the result of macro expansion. It contains the rewritten syntax node, as well as a set of diagnostics that the macro implementation itself produces:

```swift
public struct MacroResult<Rewritten: SyntaxProtocol> {
  public let rewritten: Rewritten
  public let diagnostics: [Diagnostic]

  public init(_ rewritten: Rewritten, diagnostics: [Diagnostic] = []) {
    self.rewritten = rewritten
    self.diagnostics = diagnostics
  }
}
```

The [`Diagnostic`](https://github.com/apple/swift-syntax/blob/main/Sources/SwiftDiagnostics/Diagnostic.swift) type is part of the swift-syntax library, and its form is likely to change over time, but it is able to express the different kinds of diagnostics a compiler or other tool might produce, such as warnings and errors, along with range highlights, Fix-Its, and attached notes to provide more clarity. A macro definition can introduce diagnostics if, for example, the macro argument successfully type-checked but used some Swift syntax that the macro implementation does not understand. The diagnostics will be presented by whatever tool is expanding the macro, such as the compiler.

### "Builtin" macro examples

The `#` syntax for macro expansion expressions was specifically chosen because Swift already contains a number of a `#`-prefixed expressions that are somewhat macro-like in nature. For example, `#line`, `#column`, and `#filePath`, all give source-location information; `#function` gives information about the current function; and`#colorLiteral(red:green:blue:alpha:)` are syntactic sugar for forming color literals. Many of these can be implemented as expression macros, which may imply a future simplification to the compiler and tools (use a macro instead of a built-in implementation) but also demonstrates ways in which macros can take the place of new language features. Prototype implementations of these and other builtin macros are [available in the swift-syntax repository](https://github.com/apple/swift-syntax/blob/main/Sources/_SwiftSyntaxMacros/MacroSystem%2BBuiltin.swift).

First up, the humble `#column` macro:

```swift
// Declaration of #column
macro column<T: ExpressibleByIntegerLiteral>: T = BuiltinMacros.ColumnMacro

// Implementation of #column
struct ColumnMacro: ExpressionMacro {
  static func apply(
    _ macro: MacroExpansionExprSyntax, in context: MacroEvaluationContext
  ) -> MacroResult<ExprSyntax> {
    let line = macro.startLocation(
      converter: context.sourceLocationConverter
    ).column ?? 0
    return .init("\(line)")
  }
}
```

The `#colorLiteral` macro introduces some parameters and does a simple rewrite of the argument labels:

```swift
// Declaration of #colorLiteral
macro colorLiteral<T: ExpressibleByColorLiteral>(red: Float, green: Float, blue: Float, alpha: Float) -> T
  = BuiltinMacros.ColorLiteralMacro

// Implementation of #colorLiteral
struct ColorLiteralMacro: ExpressionMacro {
  /// Replace the label of the first element in the tuple with the given
  /// new label.
  func replaceFirstLabel(
    of tuple: TupleExprElementListSyntax, with newLabel: String
  ) -> TupleExprElementListSyntax{
    guard let firstElement = tuple.first else {
      return tuple
    }

    return tuple.replacing(
      childAt: 0, with: firstElement.withLabel(.identifier(newLabel)))
  }
 
  static func apply(
    _ macro: MacroExpansionExprSyntax, in context: MacroEvaluationContext
  ) -> MacroResult<ExprSyntax> {
    let argList = replaceFirstLabel(
      of: macro.argumentList, with: "_colorLiteralRed"
    )
    let initSyntax: ExprSyntax = ".init(\(argList))"
    if let leadingTrivia = macro.leadingTrivia {
      return MacroResult(initSyntax.withLeadingTrivia(leadingTrivia))
    }
    return MacroResult(initSyntax)
  }  
}
```

### Additional macro examples

There are many other uses for expression macros. This section will collect some of the more interesting ones that come from the Swift forums and other sources of inspiration:

* [Power assertions](https://forums.swift.org/t/a-possible-vision-for-macros-in-swift/60900/87) by Kishikawa Katsumi: this assertion macro captures intermediate values within the assertion expression so that when the assertion fails, those values are displayed. The results are exciting!

  ```swift
  #powerAssert(mike.isTeenager && john.age < mike.age)
               |    |          |  |    |   | |    |
               |    true       |  |    42  | |    13
               |               |  |        | Person(name: "Mike", age: 13)
               |               |  |        false
               |               |  Person(name: "John", age: 42)
               |               false
               Person(name: "Mike", age: 13)
  ```

### Tools for using and developing macros

One of the primary concerns with macros is their ease of use and development: how do we know what a macro does to a program? How does one develop and debug a new macro?

With the right tool support, the syntactic model of macro expansion makes it easy to answer the first question. The tools will need to be able to show the developer what the expansion of any use of a macro is. At a minimum, this should include flags that can be passed to the compiler to expand macros (the prototype provides `-Xfrontend -dump-macro-expansions for this`),  and possibly include a mode to write out a "macro-expanded" source file akin to how C compilers can emit a preprocessed source file. Other tools such as IDEs should be able to show the expansion of a given use of a macro so that developers can inspect what a macro is doing. Because the result is always Swift source code, one can reason about it more easily than (say) inspecting the implementation of a macro that manipules an AST or IR.

The fact that macro implementations are separate programs actually makes it easier to develop macros. One can write unit tests for a macro implementation that provides the input source code for the macro (say, `#stringify(x + y)`), expands that macro using facilities from swift-syntax, and verifies that the resulting code is free of syntax errors and matches the expected result. Most of the "builtin" macro examples were developed this way in the [syntax macro test file](https://github.com/apple/swift-syntax/blob/main/Tests/SwiftSyntaxMacrosTest/MacroSystemTests.swift).

## Source compatibility

Macros are a pure extension to the language, utilizing new syntax, so they don't have an impact on source compatibility.

## Effect on ABI stability

Macros are a source-to-source transformation tool that have no ABI impact.

## Effect on API resilience

Macros are a source-to-source transformation tool that have no effect on API resilience.

## Alternatives considered

(To be written as alternatives get discussed)

## Acknowledgments

