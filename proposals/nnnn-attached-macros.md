# Attached Macros

* Proposal: [SE-nnnn](nnnn-attached-macros.md)
* Authors: [Doug Gregor](https://github.com/DougGregor), [Holly Borla](https://github.com/hborla), [Richard Wei](https://github.com/rxwei)
* Review Manager: Unassigned
* Status: **Pending review**
* Implementation: Partially implemented on GitHub `main` behind the experimental flag `Macros`.
* Review:
* Pitch threads: [Pitch #1 under the name "declaration macros"](https://forums.swift.org/t/pitch-declaration-macros/62373), [Pitch #2](https://forums.swift.org/t/pitch-attached-macros/62812)

## Introduction

Attached macros provide a way to extend Swift by creating and extending declarations based on arbitrary syntactic transformations on their arguments. They make it possible to extend Swift in ways that were only previously possible by introducing new language features, helping developers build more expressive libraries and eliminate extraneous boilerplate.

Attached macros are one part of the [vision for macros in Swift](https://github.com/apple/swift-evolution/pull/1927), which lays out general motivation for introducing macros into the language. They build on the ideas and motivation of [SE-0382 "Expression macros"](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md) and [freestanding macros](https://github.com/DougGregor/swift-evolution/blob/freestanding-macros/proposals/nnnn-freestanding-macros.md) to cover a large new set of use cases; we will refer to those proposals often for the basic model of how macros integrate into the language. While freestanding macros are designed as standalone entities introduced by `#`, attached macros are associated with a specific declaration in the program that they can augment and extend. This supports many new use cases, greatly expanding the expressiveness of the macro system:

* Creating trampoline or wrapper functions, such as automatically creating a completion-handler version of an `async` function.
* Creating members of a type based on its definition, such as forming an [`OptionSet`](https://developer.apple.com/documentation/swift/optionset) from an enum containing flags and conforming it to the `OptionSet` type.
* Creating accessors for a stored property or subscript, subsuming some of the behavior of [SE-0258 "Property Wrappers"](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md).
* Augmenting members of a type with a new attribute, such as applying a property wrapper to all stored properties of a type.

## Proposed solution

The proposal adds *attached macros*, so-called because they are attached to a particular declaration. They are written using the custom attribute syntax (e.g., `@addCompletionHandler`) that was introduced for property wrappers, and is also used for result builders and global actors. Attached macros can reason about the declaration to which they are attached, and provide additions and changes based on one or more different macro *roles*. Each role has a specific purpose, such as adding members, creating accessors, or adding peers alongside the declaration. A given attached macro can inhabit several different roles, and as such will be expanded multiple times corresponding to the different roles, which allows the various roles to be composed. For example, an attached macro emulating property wrappers might inhabit both the "peer" and "accessor" roles, allowing it to introduce a backing storage  property and also synthesize a getter/setter that go through that backing storage property. Composition of macro roles will be discussed in more depth once the basic macro roles have been established.

As with freestanding macros, attached declaration macros are declared with `macro`, and have [type-checked macro arguments](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md#type-checked-macro-arguments-and-results) that allow their behavior to be customized. Attached macros are identified with the `@attached` attribute, which also provides the specific role as well as [any names they introduce](https://github.com/DougGregor/swift-evolution/blob/freestanding-macros/proposals/nnnn-freestanding-macros.md#up-front-declarations-of-newly-introduced-names). For example, the aforemented macro emulating property wrappers could be declared as follows:

```swift
@attached(peer, names: prefixed(_))
@attached(accesor)
macro wrapProperty<WrapperType>()
```

All attached macros are implemented as types that conform one of the protocols that inherits from the `AttachedMacro` protocol.  Like the [`Macro` protocol](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md#macro-protocols), the `AttachedMacro` protocol has no requirements, but is used to organize macro implementations.

```swift
public protocol AttachedMacro: Macro { }
```

Each attached macro role will have its own protocol that inherits `AttachedMacro`.

#### Peer macros

Peer macros produce new declarations alongside the declaration to which they are attached.  For example, here is a declaration of a macro that introduces a completion-handler version of a given asynchronous function:

```swift
@attached(peer, names: overloaded) macro addCompletionHandler()
```

This macro uses the `@attached` attribute to indicate that it is an attached peer attribute. The `names` argument specifies that how the names of the peer declarations are created, using an extended form of the scheme introduced with [freestanding macros](https://github.com/DougGregor/swift-evolution/blob/freestanding-macros/proposals/nnnn-freestanding-macros.md#up-front-declarations-of-newly-introduced-names). In this case, `overloaded` means that this macro will produce a peer that is overloaded with the declaration to which it is attached, i.e., it has the same base name.

The macro can be used like this:

```swift
@addCompletionHandler
func fetchAvatar(_ username: String) async -> Image? { ... }
```

Peer macros are implemented via types that conform to the `PeerMacro` protocol:

```swift
public PeerMacro: AttachedMacro {
  /// Expand a macro described by the given attribute to
  /// produce "peer" declarations of the declaration to which it
  /// is attached.
  ///
  /// The macro expansion can introduce "peer" declarations that 
  /// go alongside the given declaration.
  static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: DeclSyntax,
    in context: some MacroExpansionContext
  ) async throws -> [DeclSyntax]
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

The actual implementation of this macro involves a bit of syntax manipulation, so we settle for a pseudo-code definition here and leave the complete implementation to the appendix:

```swift
public struct AddCompletionHandler: PeerDeclarationMacro {
  public static func expansion(
    of node: CustomAttributeSyntax,
    providingPeersOf declaration: DeclSyntax,
    in context: some MacroExpansionContext
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

#### Member macros

Member macros allow one to introduce new members into the type or extension to which the macro is attached. For example, we can write a macro that defines static members to ease the definition of an [`OptionSet`](https://developer.apple.com/documentation/swift/optionset). Given:

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

The macro itself will be declared as a member macro that defines an arbitrary set of members:

```swift
/// Create the necessary members to turn a struct into an option set.
@attached(member, names: names(rawValue), arbitrary]) macro optionSetMembers()
```

The `member` role specifies that this macro will be defining new members of the declaration to which it is attached. In this case, while the macro knows it will define a member named `rawValue`, there is no way for the macro to predict the names of the static properties it is defining, so it also specifies `arbitrary` to indicate that it will introduce members with arbitrarily-determined names.

Member macros are implemented with types that conform to the `MemberMacro` protocol:

```swift
protocol MemberMacro: AttachedMacro {
  /// Expand a macro described by the given attribute to
  /// produce additional members of the given declaration to which
  /// the attribute is attached.
  static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    in context: some MacroExpansionContext
  ) async throws -> [DeclSyntax]
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

The `dictionaryStorage` attached macro would alter the properties of `MyStruct` as follows, adding accessors to each:

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
@attached(accessor) macro dictionaryStorage(key: String? = nil)
```

Implementations of accessor macros conform to the `AccessorMacro` protocol, which is defined as follows:

```swift
protocol AccessorMacro: AttachedMacro {
  /// Expand a macro described by the given attribute to
  /// produce accessors for the given declaration to which
  /// the attribute is attached.
  static func expansion(
    of node: AttributeSyntax,
    providingAccessorsOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) async throws -> [AccessorDeclSyntax]
}
```

The implementation of the `dictionaryStorage` macro would create the accessor declarations shown above, using either the `key` argument (if present) or deriving the key name from the property name. The effect of this macro isn't something that can be done with a property wrapper, because the property wrapper wouldn't have access to `self.storage`.

The presence of an accessor macro on a stored property removes the initializer. It's up to the implementation of the accessor macro to either diagnose the presence of the initializer (if it cannot be used) or incorporate it in the result.

#### Member attribute macros

Member declaration macros allow one to introduce new member declarations within the type or extension to which they apply. In contrast, member *attribute* macros allow one to modify the member declarations that were explicitly written within the type or extension by adding new attributes to them. Those new attributes could then refer to other macros, such as peer or accessor macros, or builtin attributes. As such, they are primarily a means of *composition*, since they have fairly little effect on their own.

Member attribute macros allow a macro to provide similar behavior to how many built-in attributes work, where declaring the attribute on a type or extension will apply that attribute to each of the members. For example, a global actor `@MainActor` written on an extension applies to each of the members of that extension (unless they specify another global actor or `nonisolated`), an access specifier on an extension applies to each of the members of that extension, and so on.

As an example, we'll define a macro that partially mimics the behavior of the `@objcMembers` attributes introduced long ago in [SE-0160](https://github.com/apple/swift-evolution/blob/main/proposals/0160-objc-inference.md#re-enabling-objc-inference-within-a-class-hierarchy). Our `myObjCMembers` macro is a member-attribute macro:

```swift
@attached(memberAttribute)
macro myObjCMembers
```

The implementation of this macro will add the `@objc` attribute to every member of the type or extension, unless that member either already has an `@objc` macro or has `@nonobjc` on it. For example, this:

```swift
@myObjCMembers extension MyClass {
  func f() { }

  var answer: Int { 42 }

  @objc(doG) func g() { }

  @nonobjc func h() { }
}
```

would result in:

```swift
extension MyClass {
  @objc func f() { }

  @objc var answer: Int { 42 }

  @objc(doG) func g() { }

  @nonobjc func h() { }
}
```

Member-attribute macro implementations should conform to the `MemberAttributeMacro` protocol:

```swift
protocol MemberAttributeMacro: AttachedMacro {
  /// Expand a macro described by the given custom attribute to
  /// produce additional attributes for the members of the type.
  static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingAttributesFor member: DeclSyntax,
    in context: some MacroExpansionContext
  ) async throws -> [AttributeSyntax]
}
```

The `expansion` operation accepts the attribute syntax `node` for the spelling of the member attribute macro and the declaration to which that attribute is attached (i.e., the type or extension). The implementation of the macro can walk the members of the `declaration` to determine which members require additional attributes. The returned dictionary will map from those members to the additional attributes that should be added to each of the members.

#### Conformance macros

Conformance macros allow one to introduce new protocol conformances to a type. This would often be paired with other macros whose purpose is to help satisfy the protocol conformance. For example, one could imagine an extended version of the `optionSetMembers` attributed shown earlier that also adds the `OptionSet` conformance. With it, the mimimal implementation of an option set could be:

```swift
@OptionSet
struct MyOptions
  enum Option: Int {
    case a
    case b
    case c
  }
}
```

where `OptionSet` is both a member and a conformance macro, providing members (as in `optionSetMembers`) and the conformance to `OptionSet`. The macro would be declared as, e.g.,

```swift
/// Create the necessary members to turn a struct into an option set.
@attached(member, names: names(rawValue), arbitrary])
@attached(conformance)
macro OptionSet()
```

Conformance macro implementations should conform to the `ConformanceMacro` protocol:

```swift
/// Describes a macro that can add conformances to the declaration it's
/// attached to.
public protocol ConformanceMacro: AttachedMacro {
  /// Expand an attached conformance macro to produce a set of conformances.
  ///
  /// - Parameters:
  ///   - node: The custom attribute describing the attached macro.
  ///   - declaration: The declaration the macro attribute is attached to.
  ///   - context: The context in which to perform the macro expansion.
  ///
  /// - Returns: the set of `(type, where-clause?)` pairs that each provide the
  ///   protocol type to which the declared type conforms, along with
  ///   an optional where clause.
  static func expansion(
    of node: AttributeSyntax,
    providingConformancesOf declaration: some DeclGroupSyntax,
    in context: some MacroExpansionContext
  ) throws -> [(TypeSyntax, WhereClauseSyntax?)]
}
```

The returned array contains the conformances. The `TypeSyntax` describes the protocol to which the enclosing type conforms, and the optional `where` clause provides any additional constraints that would make the conformance conditional.

## Detailed design

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
@attached(peer, prefixed(_))
@attached(accessor)
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

Which is implemented by having `ClampingMacro` conform to `PeerMacro`:

```swift
enum ClampingMacro { }

extension ClampingMacro: PeerDeclarationMacro {
  static func expansion(
    of node: CustomAttributeSyntax,
    providingPeersOf declaration: DeclSyntax,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    // create a new variable declaration that is the same as the original, but...
    //   - prepend an underscore to the name
    //   - make it private
  }
}
```

And introduces accessors such as

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
    providingAccessorsOf declaration: DeclSyntax,
    in context: some MacroExpansionContext
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

### Specifying newly-introduced names

The proposal for freestanding macros introduced the need to [specify macro-introduced names](https://github.com/DougGregor/swift-evolution/blob/freestanding-macros/proposals/nnnn-freestanding-macros.md#up-front-declarations-of-newly-introduced-names) as a way of isolating the effect that macros can have on the compilation process. Attached macros introduce a few more ways in which one can describe the names of declarations that are produced by a macro:

* Declarations that have the same base name as the declaration to which the macro is attached, and are therefore overloaded with it: `overloaded`.
* Declarations whose name is formed by adding a prefix to the name of the declaration to which the macro is attached: `prefixed("_")`
* Declarations whose name is formed by adding a suffix to the name of the declaration to which the macro is attached: `suffixed("_docinfo")`. 

A  macro can only introduce new declarations whose names are covered by the kinds provided, or have their names generated via `MacroExpansionContext.createUniqueame`. This ensures that, in most cases (where `arbitrary` is not specified), the Swift compiler and related tools can reason about the set of names that will introduced by a given use of a macro without having to expand the macro, which can reduce the compile-time cost of macros and improve incremental builds.

### Ordering of macro expansions

The freestanding macros proposal describes the [visibility of macro-introduced names](https://github.com/DougGregor/swift-evolution/blob/freestanding-macros/proposals/nnnn-freestanding-macros.md#visibility-of-names-used-and-introduced-by-macros), which provides "outside-in" ordering rules where macros in outer scopes are expanded before those in inner scopes. The same general rules apply to attached macros, so macros attached to a type or extension will be expanded before macros on the members of that type or extension are.

When there are multiple attached macros on a single declaration (e.g., `@macro1 @macro2 func f()`), and those macros have the same role, the macros will be expanded in left-to-right order.

## Source compatibility

Attached declaration macros use the same syntax introduced for custom attributes (such as property wrappers), and therefore do not have an impact on source compatibility.

## Effect on ABI stability

Macros are a source-to-source transformation tool that have no ABI impact.

## Effect on API resilience

Macros are a source-to-source transformation tool that have no effect on API resilience.

## Alternatives considered

### Mutating declarations rather than augmenting them

Attached declaration macro implementations are provided with information about the macro expansion itself and the declaration to which they are attached. The implementation cannot directly make changes to the syntax of the declaration to which it is attached; rather, it must specify the additions or changes by packaging them in `AttachedDeclarationExpansion`. 

An alternative approach would be to allow the macro implementation to directly alter the declaration to which the macro is attached. This would provide a macro implementation with greater flexibility to affect the declarations it is attached to. However, it means that the resulting declaration could vary drastically from what the user wrote, and would preventing the compiler from making any determinations about what the declaration means before expanding the macro. This could have detrimental effects on compile-time performance (one cannot determine anything about a declaration until the macros have been run on it) and might also prevent macros from accessing information about the actual declaration in the future, such as the types of parameters.

It might be possible to provide a macro implementation API that is expressed in terms of mutation on the original declaration, but restrict the permissible changes to those that can be handled by the implementation. For example, one could "diff" the syntax tree provided to the macro implementation and the syntax tree produced by the macro implementation to identify changes, and return those changes that are acceptable to the compiler.

## Revision History

* After the first pitch:
  * Added conformance macros, to produce conformances
* Originally pitched as "declaration macros"; attached macros were separated into their own proposal

## Future directions

### Additional attached macro roles

There are numerous ways in which this proposal could be extended to provide new macro roles. Each new macro role would introduce a new role kind to the `@attached` attribute, along with a corresponding protocol. The macro vision document has a number of such suggestions.

## Appendix

### Implementation of `addCompletionHandler`

```swift
public struct AddCompletionHandler: PeerDeclarationMacro {
  public static func expansion(
    of node: CustomAttributeSyntax,
    providingPeersOf declaration: DeclSyntax,
    in context: some MacroExpansionContext
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

