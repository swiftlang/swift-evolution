# Declaration Macros

* Proposal: [SE-nnnn](nnnn-declaration-macros.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: Unassigned
* Status: **Pending review**
* Implementation: Nothing yet
* Review:

## Introduction

Declaration macros provide a way to extend Swift by creating new declarations based on arbitrary syntactic transformations on their arguments. They make it possible to extend Swift in ways that were only previously possible by introducing new language features, helping developers build more expressive libraries and eliminate extraneous boilerplate.

Swift-evolution thread: 

## Motivation

Declaration macros are one part of the [vision for macros in Swift](https://forums.swift.org/t/a-possible-vision-for-macros-in-swift/60900), which lays out general motivation for introducing macros into the language. They build on the ideas and motivation of [SE-0382 "Expression macros"](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md) to cover a large new set of use cases; we will refer to that proposal often for the basic model of how macros integrate into the language. While expression macros are limited to generating a single expression, declaration macros can create new declarations---functions, properties, types, and so on---greatly expanding the expressiveness of the macro system. Here are a number of potential use cases for declaration macros, many of which will be explored in detail in this proposal: 

* Creating trampoline or wrapper functions, such as automatically creating a completion-handler version of an `async` function.
* Creating wrapper types from another type, such as forming an [`OptionSet`](https://developer.apple.com/documentation/swift/optionset) from an enum containing flags.
* Creating accessors for a stored property or subscript, subsuming some of the behavior of [SE-0258 "Property Wrappers"](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md).
* Performing a non-trivial compile-time computation to produce an efficient implementation of a function, such as creating a [perfect hash function](https://en.wikipedia.org/wiki/Perfect_hash_function) for a fixed set of strings.
* Subsuming the `#warning` and `#error` directives introduced in [SE-0196](https://github.com/apple/swift-evolution/blob/main/proposals/0196-diagnostic-directives.md) into macros.

## Proposed solution

The proposal adds declaration macros, which are expanded to create zero or more new declarations. These declarations can then be referenced from other Swift code, making declaration macros useful for many different kinds of code generation and manipulation.

There are several different forms of declaration macros, which differ both based on the kinds of inputs to the macro and on the effects the macro can have on the resulting program. This proposal introduces the following kinds of declaration macros:

* *Freestanding* declaration macros use the same `#`-prefixed syntax as [expression macros](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md), and can produce zero or more declarations as a result. Freestanding declaration macros can be used anywhere that a declaration can occur, e.g., at the top level, within types and extensions, and in function bodies.
* *Attached* declaration macros use custom attribute syntax (as in [property wrappers](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md) and [result builders](https://github.com/apple/swift-evolution/blob/main/proposals/0289-result-builders.md)) and are associated with a particular declaration. These macros can augment the declaration to which they are attached in limited ways, as well as introducing "peer" declarations alongside the declaration to which they are attached.

Both freestanding and attached declaration macros are declared with `macro`, and have [type-checked macro arguments](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md#type-checked-macro-arguments-and-results) in the same manner as expression macros, which allows their behavior to be customized. 

All declaration macros are implemented as types that conform to the `DeclarationMacro` protocol. Like the [`Macro` protocol](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md#macro-protocols), the `DeclarationMacro` protocol has no requirements, but is used to describe the role of macros more generally. 

```swift
public protocol DeclarationMacro: Macro { }
```

Each kind of declaration macro (freestanding or attached) will have its own protocol that inherits `DeclarationMacro`.

### Freestanding macros

Freestanding macros are the most like expression macros. For example, the `warning` directive introduced by [SE-0196](https://github.com/apple/swift-evolution/blob/main/proposals/0196-diagnostic-directives.md) can be described as a freestanding macro as follows:

```swift
/// Emits the given message as a warning, as in SE-0196.
@declaration(.freestanding) macro warning(_ message: String)
```

The `@declaration` attribute specifies that this is a declaration macro, which is also freestanding. Given this macro declaration, the syntax

```swift
#warning("unsupported configuration")
```

can be used anywhere a declaration can occur. 

Freestanding macros are implemented as types that conform to the `FreestandingDeclarationMacro` protocol :

```swift
public protocol FreestandingDeclarationMacro: DeclarationMacro {
  /// Expand a macro described by the given freestanding macro expansion declaration
  /// within the given context to produce a set of declarations.
  static func expansion(
    of node: MacroExpansionDeclSyntax, in context: inout MacroExpansionContext
  ) throws -> [DeclSyntax]
}
```

The `MacroExpansionDeclSyntax` node provides the syntax tree for the use site (e.g., `#warning("unsupported configuration")`), and has the same grammar and members as the `MacroExpansionExprSyntax` node introduced in [SE-0382](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md#macro-expansion). The grammar parallels `macro-expansion-expression`:

```
declaration -> macro-expansion-declaration
macro-expansion-declaration -> '#' identifier generic-argument-clause[opt] function-call-argument-clause[opt] trailing-closures[opt]
```

The implementation of a freestanding `warning` declaration macro extracts the string literal argument (producing an error if there wasn't one) and emits a warning. It returns an empty list of declarations:

```swift
public struct WarningMacro: FreestandingDeclarationMacro {
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

### Attached macros

Attached macros are named as such because they are attached to a specific declaration. They are written using attribute syntax (e.g., `@addCompletionHandler`), and are able to make specific additions to both the declaration to which they are attached as well as introducing "peer" declarations alongside the declaration to which they are attached.

For example, here is a declaration of a macro that introduces a completion-handler version of a given asynchronous function:

```swift
@declaration(.attached, peers: [.overloaded]) macro addCompletionHandler
```

Again, this macro uses the `@declaration` to indicate that it is a declaration macro, but with `.attached`. The `peers` argument specifies that this macro will generate peer declarations, and how the names of those peer declarations are formed. In this case, our macro will produce a peer that is overloaded with the declaration to which it is attached, i.e., it has the same base name. Later parts of this proposal will go into more depth on the naming of generated declarations , as well as providing rationale for this up-front declaration of macro behavior.

An attached macro like this can be used as an attribute. For example:

```swift
@addCompletionHandler
func fetchAvatar(_ username: String) async -> Image? { ... }
```

Attached macros are implemented via types that conform to the `AttachedDeclarationMacro` protocol:

```swift
public AttachedDeclarationMacro: DeclarationMacro {
  /// Expand a macro described by the given custom attribute and
  /// attached to the given declaration and evaluated within a
  /// particular expansion context.
  ///
  /// The macro expansion can introduce a number of changes to
  /// the given declaration, all of which must be represented by
  /// the `AttachedDeclarationExpansion` result.
  static func expansion(
    of node: CustomAttributeSyntax,
    attachedTo declaration: DeclSyntax,
    in context: inout MacroExpansionContext
  ) throws -> AttachedDeclarationExpansion
}
```

The effect of `addCompletionHandler` is to produce a new "peer" declaration with the same signature as the declaration it is attached but with `async` and the result type removed, and a completion handler argument added, e.g.,

```swift
/// Expansion of the macro produces the following.
func fetchAvatar(_ username: String, completionHandler: @escaping (Image?) -> Void ) {
  Task.detached {
    completionHandler(await fetchAvatar(username))
  }
}
```

The actual implementation of this macro involves a lot of syntax manipulation, so we settle for a pseudo-code definition here:

```swift
public struct AddCompletionHandler: AttachedDeclarationMacro {
  public static func expansion(
    of node: CustomAttributeSyntax,
    attachedTo declaration: DeclSyntax,
    in context: inout MacroExpansionContext
  ) throws -> AttachedDeclarationExpansion {
    // make sure we have an async function to start with
    // form a new function "completionHandlerFunc" by starting with that async function and
    //   - remove async
    //   - remove result type
    //   - add a completion-handler parameter
    //   - add a body that forwards arguments
    // return the new peer function
    return AttachedDeclarationExpansion(peers: [completionHandlerFunc])
  }
}
```

The full capabilities of `AttachedDeclarationExpansion` will be described later, and are expected to expand over time. However, another common use case involves creating member declarations within a type. For example, to define static members to ease the definition of an [`OptionSet`](https://developer.apple.com/documentation/swift/optionset). Given:

```swift
@optionSetMembers
struct MyOptions: OptionSet {
  enum Option: Int {
    case a
    case b
    case c
  }
}
```

This struct should be expanded to contain both a `rawValue` field and static properties for each of the options, e.g.,

```swift
// Expands to...
struct MyOptions: OptionSet {
  enum Option: Int {
    case a
    case b
    case c
  }
  
  // Synthesized code below...
  var rawValue: Int = 0
  
  static var a = MyOptions(rawValue: 1 << Option.a.rawValue)
  static var b = MyOptions(rawValue: 1 << Option.b.rawValue)
  static var c = MyOptions(rawValue: 1 << Option.c.rawValue)
}
```

The macro itself will be declared as an attached declaration macro that defines an arbitrary set of members:

```swift
/// Create the necessary members to turn a struct into an option set.
@declaration(.attached, members: [.named("rawValue"), .arbitrary]) macro optionSetMembers
```

The `members` argument specifies that this macro will be defining new members of the declaration to which it is attached. In this case, while the macro knows it will define a member named `rawValue`, there is no way for the macro to predict the names of the static properties it is defining, so it also specifies `.arbitrary` to indicate that it will introduce members with arbitrarily-determined names.

As a final example, property-wrapper-like behavior can be implemented via an attached declaration macro that introduces accessors. Consider a macro that can be applied to a stored property to instead access a dictionary keyed by the property name. Such a macro could be used like this:

```swift
struct MyStruct {
  var storage: [AnyHashable: Any] = [:]
  
  @dictionaryStorage
  var name: String
  
  @dictionaryStorage(key: "birth_date")
  var birthDate: Date?
}
```

The `dictionaryStorage` attached declaration macro would alter `MyStruct` as follows:

```swift
struct MyStruct {
  var storage: [String: Any] = [:]
  
  var name: String {
    get { 
      storage["name"]! as! String
    }
    
    set {
      storage["name"] = newValue
    }
  }
  
  var birthDate: Date? {
    get {
      storage["birth_date"] as Date?
    }
    
    set {
      if let newValue {
        storage["birth_date"] = newValue
      } else {
        storage.removeValue(forKey: "birth_date")
      }
    }
  }
}
```

The macro can be declared as follows:

```swift
@declaration(.attached, members: [.accessors]) macro dictionaryStorage
@declaration(.attached, members: [.accessors]) macro dictionaryStorage(key: String)
```

The implementation of the macro itself would create the accessor declarations and supply them via `AttachedDeclarationExpansion(members:)`. Property wrappers aren't great for this case, because they would still define a backing stored property (e.g., `_name`) of the property wrapper type. To mimic the full behavior of property wrappers, one could introduce both members (for the accessors) and peers (for the backing stored property).

### Up-front declarations of newly-introduced macro names

Declaration macros require one to declare the names of entities that will be declared. These can involve member and/or peer declaration names, and are provided as an array consisting of a few different kinds:

* Declarations with a specific fixed name: `.named("rawValue")`
* Declarations that have the same base name as the declaration to which the macro is attached, and are therefore overloaded with it: `.overloaded`.
* Accessors of the declaration to which the macro is attached: `.accessors`
* Declarations whose name is formed by adding a prefix to the name of the declaration to which the macro is attached: `.prefixed("_")`
* Declarations whose name is formed by adding a suffix to the name of the declaration to which the macro is attached: `.suffixed("_docinfo")`. 
* Declarations whose names cannot be described by any of the simple rules above: `.arbitrary`.

A declaration macro can only introduce new declarations whose names are covered by the kinds provided, or have their names generated via `MacroExpansionContext.createUniqueLocalName`. This ensures that, in most cases (where `.arbitrary` is not specified) the Swift compiler and related tools can reason about the set of names that will introduced by a given use of a declaration macro without having to expand the macro, which can reduce the compile-time cost of macros and improve incremental builds.

## Detailed design

### `AttachedDeclarationExpansion`

An attached declaration macro implementation returns an instance of the `AttachedDeclarationExpansion` structure to specify the changes. The structure is specified as follows:

```swift
public struct AttachedDeclarationExpansion {
  /// The set of peer declarations introduced by this macro, which will be introduced alongside the use of the
  /// macro.
  public var peers: [DeclSyntax] = []
  
  /// The set of member declarations introduced by this macro, which are nested inside 
  public var members: [DeclSyntax] = []
  
  /// For a function, body for the function. If non-nil, this will replace any existing function body.
  public var functionBody: CodeBlockSyntax? = nil
  
  public init(peers: [DeclSyntax] = [], members: [DeclSyntax] = [], functionBody: CodeBlockSyntax? = nil)
}
```

This structure is expected to grow more capabilities over time. Changes that can affect how a particular declaration is used will likely require paired changes to the arguments of `@declaration`, and can be considered in subsequent proposals. 

### Macros in the Standard Library

#### SE-0196 `warning` and `error`

The `#warning` and `#error` directives introduced in [SE-0196](https://github.com/apple/swift-evolution/blob/main/proposals/0196-diagnostic-directives.md): can be implemented directly as freestanding macros:

```swift
/// Emit a warning containing the given message.
@declaration(.freestanding) macro warning(_ message: String)

/// Emit an error containing the given message
@declaration(.freestanding) macro error(_ message: String)
```

## Source compatibility

Freestanding declaration macros use the same syntax introduced for expression macros, which were themselves a pure extension without an impact on source compatibility. There is a syntactic ambiguity between expression and freestanding declaration macros, i.e., `#warning("watch out")` within a function body could be either an expression or a declaration. The distinction will need to be determined semantically, by determining whether the named macro is either an expression or a freestanding declaration macro.

Attached declaration macros use the same syntax introduced for custom attributes (such as property wrappers), and therefore do not have an impact on source compatibility.

## Effect on ABI stability

Macros are a source-to-source transformation tool that have no ABI impact.

## Effect on API resilience

Macros are a source-to-source transformation tool that have no effect on API resilience.

## Alternatives considered

### Mutating declarations rather than augmenting them

Attached declaration macro implementations are provided with information about the macro expansion itself and the declaration to which they are attached. The implementation cannot directly make changes to the syntax of the declaration to which it is attached; rather, it must specify the additions or changes by packaging them in `AttachedDeclarationExpansion`. 

An alternative approach would be to allow the macro implementation to directly alter the declaration to which the macro is attached. This would provide a macro implementation with greater flexibility to affect the declarations it is attached to. However, it means that the resulting declaration could vary drastically from what the user wrote, and would preventing the compiler from making any determinations about what the declaration means before expanding the macro. This could have detrimental effects on compile-time performance (one cannot determine anything about a declaration until the macros have been run on it) and might also prevent macros from accessing information about the actual declaration in the future, such as the types of parameters.

It might be possible to provide a macro implementation API that is expressed in terms of mutation on the original declaration, but restrict the permissible changes to those that can be handled by the implementation. For example, one could "diff" the syntax tree provided to the macro implementation and the syntax tree produced by the macro implementation to identify changes: those changes that are acceptable would be recorded into something like `AttachedDeclarationExpansion`, and any other differences would be reported as errors. Such a design could be layered on top of the design proposed here, e.g., with an `AttachedDeclarationExpansion` initializer that accepts the original declaration and the rewritten declaration.

## Future directions

### Extending `AttachedDeclarationExpansion`

The set of changes that a macro can apply to the declaration to which is attached is (intentionally) limited by what can be expressed in `AttachedDeclarationExpansion`. Over time, we expect this structure to be extended to enable additional kinds of changes, such as adding attributes or modifiers to the declaration. These changes will likely be paired with changes to the `@declaration` syntax. For example, adding attributes to the declaration could mean introducing the following property into `AttachedDeclarationExpansion`:

```swift
var attributes: [AttributeSyntax] = []
```

but to minimize compile-time dependencies we would likely want to note when a macro may add attributes, e.g.,

```swift
@declaration(.attached, augmenting: [.attributes])
macro sometimesDeprecated
```

This would ensure that the compiler knows when the attributes as they are written on a declaration are the complete set of attributes, vs. when it will have to expand the macro to determine what attributes are applied to the declaration.
