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
@declaration(freestanding) macro warning(_ message: String)
```

The `@declaration` attribute specifies that this is a declaration macro, which is also freestanding (the `freestanding` argument). Given this macro declaration, the syntax

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

Attached macros are named as such because they are attached to a specific declaration. They are written using attribute syntax (e.g., `@addCompletionHandler`), and are able to reason about the declaration to which they are attached. There are a number of different forms of attached macros, each of which has a specific effect such as adding members to the declaration (e.g., if it's a type or extension thereof), adding "peer" members alongside the declaration, adding accessors to the declaration, and so on. Each of these kinds of macros is described in the following sections.

#### Peer declaration macros

Peer declaration macros produce new declarations alongside the declaration to which they are attached.  For example, here is a declaration of a macro that introduces a completion-handler version of a given asynchronous function:

```swift
@declaration(peers: [.overloaded]) macro addCompletionHandler: Void
```

Again, this macro uses the `@declaration` attribute to indicate that it is a declaration macro. The `peers` argument specifies that this macro will generate peer declarations, and how the names of those peer declarations are formed. In this case, our macro will produce a peer that is overloaded with the declaration to which it is attached, i.e., it has the same base name. Later parts of this proposal will go into more depth on the naming of generated declarations , as well as providing rationale for this up-front declaration of macro behavior.

The macro can be used like this, as an attribute:

```swift
@addCompletionHandler
func fetchAvatar(_ username: String) async -> Image? { ... }
```

Peer declaration macros are implemented via types that conform to the `PeerDeclarationMacro` protocol:

```swift
public PeerDeclarationMacro: DeclarationMacro {
  /// Expand a macro described by the given custom attribute to
  /// produce "peer" declarations of the declaration to which it
  /// is attached.
  ///
  /// The macro expansion can introduce "peer" declarations that 
  /// go alongside the given declaration.
  static func expansion(
    of node: CustomAttributeSyntax,
    peersOf declaration: DeclSyntax,
    in context: inout MacroExpansionContext
  ) throws -> [DeclSyntax]
}
```

The effect of `addCompletionHandler` is to produce a new "peer" declaration with the same signature as the declaration it is attached to, but with `async` and the result type removed in favor of a completion handler argument, e.g.,

```swift
/// Expansion of the macro produces the following.
func fetchAvatar(_ username: String, completionHandler: @escaping (Image?) -> Void) {
  Task.detached {
    completionHandler(await fetchAvatar(username))
  }
}
```

The actual implementation of this macro involves a lot of syntax manipulation, so we settle for a pseudo-code definition here and leave the complete implementation to the appendix:

```swift
public struct AddCompletionHandler: PeerDeclarationMacro {
  public static func expansion(
    of node: CustomAttributeSyntax,
    peersOf declaration: DeclSyntax,
    in context: inout MacroExpansionContext
  ) throws -> [DeclSyntax] {
    // make sure we have an async function to start with
    // form a new function "completionHandlerFunc" by starting with that async function and
    //   - remove async
    //   - remove result type
    //   - add a completion-handler parameter
    //   - add a body that forwards arguments
    // return the new peer function
    return [completionHandlerFunc]
  }
}
```

#### Member declaration macros

Member declaration macros allow one to introduce new members into the type or extension to which the macro is attached. For example, we can write a macro that defines static members to ease the definition of an [`OptionSet`](https://developer.apple.com/documentation/swift/optionset). Given:

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

The macro itself will be declared as a member declaration macro that defines an arbitrary set of members:

```swift
/// Create the necessary members to turn a struct into an option set.
@declaration(members: [.named("rawValue"), .arbitrary]) macro optionSetMembers: Void
```

The `members` argument specifies that this macro will be defining new members of the declaration to which it is attached. In this case, while the macro knows it will define a member named `rawValue`, there is no way for the macro to predict the names of the static properties it is defining, so it also specifies `.arbitrary` to indicate that it will introduce members with arbitrarily-determined names.

Member declaration macros are implemented with types that conform to the `MemberDeclarationMacro` protocol:

```swift
protocol MemberDeclarationMacro: DeclarationMacro {
  /// Expand a macro described by the given custom attribute to
  /// produce additional members of the given declaration to which
  /// the attribute is attached.
  static func expansion(
    of node: CustomAttributeSyntax,
    membersOf declaration: DeclSyntax,
    in context: inout MacroExpansionContext
  ) throws -> [DeclSyntax]  
}
```

#### Accessor macros

Accessor macros allow a macro to add accessors to a property or subscript, for example by turning a stored property into a computed property. For example, consider a macro that can be applied to a stored property to instead access a dictionary keyed by the property name. Such a macro could be used like this:

```swift
struct MyStruct {
  var storage: [AnyHashable: Any] = [:]
  
  @dictionaryStorage
  var name: String
  
  @dictionaryStorage(key: "birth_date")
  var birthDate: Date?
}
```

The `dictionaryStorage` attached declaration macro would alter the properties of `MyStruct` as follows, adding accessors to each:

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
@declaration(accessors) macro dictionaryStorage: Void
@declaration(accessors) macro dictionaryStorage(key: String)
```

Implementations of accessor macros conform to the AccessorMacro protocol, which is defined as follows:

```swift
protocol AccessorMacro: DeclarationMacro {
  /// Expand a macro described by the given custom attribute to
  /// produce accessors for the given declaration to which
  /// the attribute is attached.
  static func expansion(
    of node: CustomAttributeSyntax,
    accessorsOf declaration: DeclSyntax,
    in context: inout MacroExpansionContext
  ) throws -> [AccessorDeclSyntax]  
}
```

The implementation of the `dictionaryStorage` macro would create the accessor declarations shown above, using either the `key` argument (if present) or deriving the key name from the property name. The effect of this macro isn't something that can be done with a property wrapper, because the property wrapper wouldn't have access to `self.storage`.

The presence of an accessor macro on a stored property removes the initializer. It's up to the implementation of the accessor macro to either diagnose the presence of the initializer (if it cannot be used) or incorporate it in the result.

#### Body macros

A body macro allows one to create or replace the body of a function, initializer, or closure through syntactic manipulation. Body macros are attached to one of these entities, e.g.,

```swift
@traced(logLevel: 2)
func myFunction(a: Int, b: Int) { ... }
```

where the `traced` macro is declared as something like:

```swift
@declaration(body) macro traced(logLevel: Int = 0)
```

and implemented in a conformance to the `BodyMacro` protocol:

```swift
protocol BodyMacro: Macro {
  /// Expand a macro described by the given custom attribute to
  /// produce or modify a body for the given entity to which
  /// the attribute is attached.
  static func expansion(
    of node: CustomAttributeSyntax,
    bodyOf entity: some WithCodeBlockSyntax,
    in context: inout MacroExpansionContext
  ) throws -> CodeBlockSyntax
}
```

The `WithCodeBlockSyntax` protocol describes all entities that have an optional "body". The `traced` macro could inject a log-level check and a call to log the values of each of the parameters, e.g.,

```swift
if shouldLog(atLevel: 2) {
  log("Entering myFunction((a: \(a), b: \(b)))")
}
```

Body macros will only be applied when the body is required, e.g., to generate code. A body macro will be applied whether the entity has an existing body or not; if the entity does have an existing body, it will be type-checked before the macro is invoked, as with other macro arguments.

#### Default witness macros

Swift provides default "witness" synthesis for a number of protocols in the standard library, including `Equatable`, `Hashable`, `Encodable`, and `Decodable`. This behavior is triggered when a type has a conformance to a known protocol, and there is no suitable implementation for one of the protocol's requirements, e.g.,

```swift
struct Point: Equatable {
  var x: Int
  var y: Int
  
  // no suitable function
  //
  //   
  //
  // to satisfy the protocol requirement, so the compiler creates one like the following
  //

}
```

There is no suitable function to meet the protocol requirement

```swift
static func ==(lhs: Self, rhs: Self) -> Bool
```

so the compiler as bespoke logic to synthesize the following:

```swift
  static func ==(lhs: Point, rhs: Point) -> Bool {
    lhs.x == rhs.x && lhs.y == rhs.y
  }
```

Default witness macros bring this capability to the macro system, by allowing a macro to define a witness to satisfy a requirement when there is no suitable witness. Consider an `equatableSyntax` macro declared as follows:

```swift
@declaration(witness)
macro equatableSynthesis: Void
```

This default-witness macro would be written on the protocol requirement itself, i.e.,

```swift
protocol Equatable {
  @equatableSynthesis
  static func ==(lhs: Self, rhs: Self) -> Bool

  static func !=(lhs: Self, rhs: Self) -> Bool
}
```

The macro type would implement the following protocol:

```swift
protocol DefaultWitnessMacro: DeclarationMacro {
  /// Expand a macro described by the given custom attribute to
  /// produce a witness definition for the requirement to which
  /// the attribute is attached.
  static func expansion(
    of node: CustomAttributeSyntax,
    witness: DeclSyntax,
    conformingType: TypeSyntax,
    storedProperties: [StoredProperty],
    in context: inout MacroExpansionContext
  ) throws -> DeclSyntax
}
```

The contract with the compiler here is interesting. The compiler would use the `@equatableSynthesis` macro to define the witness only when there is no other potential witness. The compiler will then produce a declaration for the witness based on the requirement, performing substitutions as necessary to (e.g.) replace `Self` with the conforming type, and provide that declaration via the `witness` parameter. For `Point`, the `==` declaration would look like this:

```swift
static func ==(lhs: Point, rhs: Point) -> Bool
```

The `expansion` operation then augments the provided `witness` with a body, and could perform other adjustments if necessary, before returning it. The resulting definition will be inserted as a member into the conforming type (or extension), wherever the protocol conformance is declared. This approach gives a good balance between making macro writing easier, because the compiler is providing a witness declaration that will match the requirement, while still allowing the macro implementation freedom to alter that witness as needed. Its design also follows how witnesses are currently synthesized in the compiler today, which has fairly well-understood implementation properties (at least, to compiler implementers).

The `conformingType` parameter provides the syntax of the conforming type, which can be used to refer to the type anywhere in the macro. The `storedProperties` parameter provides the set of stored properties of the conforming type, which are needed for many (most?) kinds of witness synthesis. The `StoredProperty` struct is defined as follows:

```swift
struct StoredProperty {
  /// The stored property syntax node.
  var property: VariableDeclSyntax
  
  /// The original declaration from which the stored property was created, if the stored property was
  /// synthesized.
  var original: Syntax?
}
```

The `property` field is the syntax node for the stored property. Typically, this is the syntax node as written in the source code. However, some stored properties are formed in other ways, e.g., as the backing property of a property wrapper (`_foo`) or due to some other macro expansion (member, peer, freestanding, etc.). In these cases, `property` refers to the syntax of the generated property, and `original` refers to the syntax node that caused the stored property to be generated. This `original` value can be used, for example, to find information from the original declaration that can affect the synthesis of the default witness.

Providing stored properties to this expansion method does require us to introduce a limitation on default-witness macro implementations, which is that they cannot themselves introduce stored properties. This eliminates a potential circularity in the language model, where the list of stored properties could grow due to expansion of a macro, thereby potentially invalidating the results of already-expanded macros that saw a subset of the stored properties. Note that directly preventing default-witness macros from defining stored properties isn't a complete solution, because one could (for example) have a default-witness macro produce a witness function that itself involves a peer-declaration macro that introduces a stored property. Such problems will be detected as a dependency cycle in the compiler and reported as an error.

### Composing macro roles

A given macro can have several different roles, allowing the various macro features to be composed. Each of the roles is considered independently, so a single use of a macro in source code can result in different macro expansion functions being called. These calls are independent, and could even happen concurrently. As an example, let's define a macro that emulates property wrappers fairly closely.  The property wrappers proposal has an example for a [clamping property wrapper](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md#clamping-a-value-within-bounds):

```swift
@propertyWrapper
struct Clamping<V: Comparable> {
  var value: V
  let min: V
  let max: V

  init(wrappedValue: V, min: V, max: V) {
    value = wrappedValue
    self.min = min
    self.max = max
    assert(value >= min && value <= max)
  }

  var wrappedValue: V {
    get { return value }
    set {
      if newValue < min {
        value = min
      } else if newValue > max {
        value = max
      } else {
        value = newValue
      }
    }
  }
}

struct Color {
  @Clamping(min: 0, max: 255) var red: Int = 127
  @Clamping(min: 0, max: 255) var green: Int = 127
  @Clamping(min: 0, max: 255) var blue: Int = 127
  @Clamping(min: 0, max: 255) var alpha: Int = 255
}
```

Instead, let's implement this as a macro:

```swift
@declaration(peers: [.prefixed("_")])
@declaration(accessors)
macro Clamping<T: Comparable>(min: T, max: T) = #externalMacro(module: "MyMacros", type: "ClampingMacro")
```

The usage syntax is the same in both cases. As a macro, `Clamping` both defines a peer (a backing storage property with an `_` prefix) and also defines accessors (to check min/max).  The peer declaration macro is responsible for defining the backing storage, e.g.,

```swift
private var _red: Int = {
  let newValue = 127
  let minValue = 0
  let maxValue = 255
  if newValue < minValue {
    return minValue
  }
  if newValue > maxValue {
    return maxValue
  }
  return newValue
}()
```

Which is implemented by having `ClampingMacro` conform to `PeerDeclarationMacro`:

```swift
enum ClampingMacro { }

extension ClampingMacro: PeerDeclarationMacro {
  static func expansion(
    of node: CustomAttributeSyntax,
    peersOf declaration: DeclSyntax,
    in context: inout MacroExpansionContext
  ) throws -> [DeclSyntax] {
    // create a new variable declaration that is the same as the original, but...
    //   - prepend an underscore to the name
    //   - make it private
  }
}
```



And introduces accesssors such as

```swift
    get { return _red }

    set(__newValue) {
      let __minValue = 0
      let __maxValue = 255
      if __newValue < __minValue {
        _red = __minValue
      } else if __newValue > __maxValue {
        _red = __maxValue
      } else {
        _red = __newValue
      }
    }
```

by conforming to `AccessorMacro`:

```swift
extension ClampingMacro: AccessorMacro {
  static func expansion(
    of node: CustomAttributeSyntax,
    accessorsOf declaration: DeclSyntax,
    in context: inout MacroExpansionContext
  ) throws -> [AccessorDeclSyntax] {
    let originalName = /* get from declaration */, 
        minValue = /* get from custom attribute node */,
        maxValue = /* get from custom attribute node */
    let storageName = "_\(originalName)",
        newValueName = context.getUniqueName(),
        maxValueName = context.getUniqueName(),
        minValueName = context.getUniqueName()
    return [
      """
      get { \(storageName) }
      """,
      """
      set(\(newValueName)) {
        let \(minValueName) = \(minValue)
        let \(maxValueName) = \(maxValue)
        if \(newValueName) < \(minValueName) {
          \(storageName) = \(minValueName)
        } else if \(newValueName) > maxValue {
          \(storageName) = \(maxValueName)
        } else {
          \(storageName) = \(newValueName)
        }
      }
      """
    ]
  }  
}
```

This formulation of `@Clamping` offers some benefits over the property-wrapper version: we don't need to store the min and max values as part of the backing storage (so the presence of `@Clamping` doesn't add any storage), nor do we need to define a new type. More importantly, it demonstrates how the composition of different macro roles together can produce interesting effects.

### Up-front declarations of newly-introduced macro names

Declaration macros require one to declare the names of entities that will be declared. These can involve member and/or peer declaration names, and are provided as an array consisting of a few different kinds:

* Declarations with a specific fixed name: `.named("rawValue")`
* Declarations that have the same base name as the declaration to which the macro is attached, and are therefore overloaded with it: `.overloaded`.
* Declarations whose name is formed by adding a prefix to the name of the declaration to which the macro is attached: `.prefixed("_")`
* Declarations whose name is formed by adding a suffix to the name of the declaration to which the macro is attached: `.suffixed("_docinfo")`. 
* Declarations whose names cannot be described by any of the simple rules above: `.arbitrary`.

A declaration macro can only introduce new declarations whose names are covered by the kinds provided, or have their names generated via `MacroExpansionContext.createUniqueLocalName`. This ensures that, in most cases (where `.arbitrary` is not specified) the Swift compiler and related tools can reason about the set of names that will introduced by a given use of a declaration macro without having to expand the macro, which can reduce the compile-time cost of macros and improve incremental builds.

## Detailed design

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

(nothing just yet)

## Revision history

Revisions from the first pitch:

* Split peer/member/accessor macro implementations into separate protocols and attribute spellings, so the compiler can query them in a more fine-grained manner.
* Added "body" macros as a separate macro role.
* Added default-witness macros.
* Add example showing composition of different macro roles for the same macro to effect property-wrappers behavior.

## Appendix

### Implementation of `addCompletionHandler`

```swift
public struct AddCompletionHandler: PeerDeclarationMacro {
  public static func expansion(
    of node: CustomAttributeSyntax,
    peersOf declaration: DeclSyntax,
    in context: inout MacroExpansionContext
  ) throws -> [DeclSyntax] {
    // Only on functions at the moment. We could handle initializers as well
    // with a little bit of work.
    guard let funcDecl = declaration.as(FunctionDeclSyntax.self) else {
      throw CustomError.message("@addCompletionHandler only works on functions")
    }

    // This only makes sense for async functions.
    if funcDecl.signature.asyncOrReasyncKeyword == nil {
      throw CustomError.message(
        "@addCompletionHandler requires an async function"
      )
    }

    // Form the completion handler parameter.
    let resultType: TypeSyntax? = funcDecl.signature.output?.returnType.withoutTrivia()

    let completionHandlerParam =
      FunctionParameterSyntax(
        firstName: .identifier("completionHandler"),
        colon: .colonToken(trailingTrivia: .space),
        type: "(\(resultType ?? "")) -> Void" as TypeSyntax
      )

    // Add the completion handler parameter to the parameter list.
    let parameterList = funcDecl.signature.input.parameterList
    let newParameterList: FunctionParameterListSyntax
    if let lastParam = parameterList.last {
      // We need to add a trailing comma to the preceding list.
      newParameterList = parameterList.removingLast()
        .appending(
          lastParam.withTrailingComma(
            .commaToken(trailingTrivia: .space)
          )
        )
        .appending(completionHandlerParam)
    } else {
      newParameterList = parameterList.appending(completionHandlerParam)
    }

    let callArguments: [String] = try parameterList.map { param in
      guard let argName = param.secondName ?? param.firstName else {
        throw CustomError.message(
          "@addCompletionHandler argument must have a name"
        )
      }

      if let paramName = param.firstName, paramName.text != "_" {
        return "\(paramName.withoutTrivia()): \(argName.withoutTrivia())"
      }

      return "\(argName.withoutTrivia())"
    }

    let call: ExprSyntax =
      "\(funcDecl.identifier)(\(raw: callArguments.joined(separator: ", ")))"

    // FIXME: We should make CodeBlockSyntax ExpressibleByStringInterpolation,
    // so that the full body could go here.
    let newBody: ExprSyntax =
      """

        Task.detached {
          completionHandler(await \(call))
        }

      """

    // Drop the @addCompletionHandler attribute from the new declaration.
    let newAttributeList = AttributeListSyntax(
      funcDecl.attributes?.filter {
        guard case let .customAttribute(customAttr) = $0 else {
          return true
        }

        return customAttr != node
      } ?? []
    )

    let newFunc =
      funcDecl
      .withSignature(
        funcDecl.signature
          .withAsyncOrReasyncKeyword(nil)  // drop async
          .withOutput(nil)                 // drop result type
          .withInput(                      // add completion handler parameter
            funcDecl.signature.input.withParameterList(newParameterList)
              .withoutTrailingTrivia()
          )
      )
      .withBody(
        CodeBlockSyntax(
          leftBrace: .leftBraceToken(leadingTrivia: .space),
          statements: CodeBlockItemListSyntax(
            [CodeBlockItemSyntax(item: .expr(newBody))]
          ),
          rightBrace: .rightBraceToken(leadingTrivia: .newline)
        )
      )
      .withAttributes(newAttributeList)
      .withLeadingTrivia(.newlines(2))

    return [DeclSyntax(newFunc)]
  }
}
```

