# Source-Level Control Over Compiler Warnings

* Proposal: [SE-0522](0522-source-warning-control.md)
* Authors: [Artem Chikin](https://github.com/artemcm), [Doug Gregor](https://github.com/douggregor), [Holly Borla](https://github.com/hborla)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Accepted**
* Implementation: [swiftlang/swift#85036](https://github.com/swiftlang/swift/pull/85036), [swiftlang/swift-syntax#3174](https://github.com/swiftlang/swift-syntax/pull/3174)
* Experimental Feature Flag: `SourceWarningControl`
* Review: ([pitch](https://forums.swift.org/t/pitch-source-level-control-over-compiler-warnings/82766)) ([review](https://forums.swift.org/t/se-0522-source-level-control-over-compiler-warnings/85453)) ([acceptance](https://forums.swift.org/t/accepted-se-0522-source-level-control-over-compiler-warnings/85860))

## Summary of changes

This proposal introduces a new declaration attribute for controlling compiler warning behavior in specific code regions: to be emitted as warnings, errors, or suppressed.

## Motivation

[SE-0443](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md) introduced control over compiler warnings with command-line flags which control behaviors of specific warning groups. Module-level controls are a blunt instrument, applying the same behavior to all code regardless of whether it's appropriate everywhere, making it desirable to provide a source-level control mechanism which can be used to refine default or module-wide behaviors. Furthermore, [SE-0443](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md) review identified module-wide warning *suppression* as problematic; however, suppression of warnings in some circumstances remains a desired use-case, one which would be well-suited to a fine-grained source-level application.

Source-level warning control addresses the practical reality of codebases undergoing migration or incremental adoption of new Swift features. During deprecation cycles, teams must maintain compatibility with older APIs in specific declarations while enforcing strict usage elsewhere. For example, a project may be using `-Werror DeprecatedDeclaration` to enforce migration off deprecated APIs across an entire library module; however, there may be legitimate cases to make an exception for a particular function to maintain compatibility with an older library version:
```swift
func bridgeToLegacySystem() {
  oldAPI() // error: 'oldAPI()' is deprecated [#Deprecated]
}
```
Today, the only recourse is to amend the module-wide policy. With source-level control, the developer will be empowered to make a scoped exception:
```swift
@diagnose(DeprecatedDeclaration, as: warning, reason: "Must maintain compatibility until end of release cycle")
func bridgeToLegacySystem() {
  oldAPI() // warning: 'oldAPI()' is deprecated [#Deprecated]
}
```
Similarly, when adopting other stricter warning policies, such as `-warnings-as-errors`, teams may encounter legitimate edge cases or temporary technical debt that necessitate warning suppression or deescalation in isolated scopes without compromising module-wide policy.

As Swift evolves to include more advanced static analyses and stricter language modes (such as [strict memory safety](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0458-strict-memory-safety.md) and explicit ownership checking) that enforce certain practices and patterns through diagnostics, their deployment would greatly benefit from fine-grained warning control: it would enable the use of diagnostics to guide developers toward safer patterns while allowing certain warnings to be temporarily suppressed or escalated during adoption or in specific implementation contexts.

Declaration-level warning behavior controls provide the precision needed for these scenarios, allowing developers to document exceptions exactly where they occur, and allowing stricter language modes to be incrementally adopted by annotating exceptional cases while ensuring the diagnostic rules remain enforced throughout the majority of the codebase.

## Proposed solution

This proposal introduces a new declaration attribute to the language which will allow the behavior of warnings to be controlled in the lexical scope of the annotated declaration, for a specific diagnostic group.

```swift
@diagnose(ForeignReferenceType, as: error)
public func foo() {
  ...
}
```

For the entirety of the `foo` declaration in this example, including the function signature and its lexical scope, the effect of the attribute is equivalent to `-Werror ForeignReferenceType`, but without affecting diagnostic behavior on any other source code in the current module. The attribute supports 3 `as:` behavior specifiers: `error`, `warning`, and `ignored`. The attribute also supports an optional `reason:` parameter which accepts a string literal. With `error` and `warning` behavior specifiers, the attribute has the effect equivalent to that of `-Werror <groupID>` and `-Wwarning <groupID>`, respectively, without affecting other source code in the module. With the `ignored` behavior specifier, warnings belonging to the diagnostic group `<groupID>` are fully suppressed (akin to a global (module-wide) `-Wsuppress`, which does not exist).

The `@diagnose` attribute overrides diagnostic behavior for the specified diagnostic group, relative to its *enclosing scope* - with command-line behavior specifiers representing global (module-wide) scope: `-warnings-as-errors`, `-Werror`, `-Wwarning`.

For example, suppose there existed a hypothetical diagnostic group `UnsafeImportedAPI`. On a compilation which specifies either `-warnings-as-errors` or `-Werror UnsafeImportedAPI`, the `@diagnose` attribute can be used to lower the severity of `UnsafeImportedAPI` diagnostics to a warning within the scope of a specific method, while the same code pattern elsewhere in the module would be diagnosed as an error:

```swift
let result = c_parse_buffer(ptr, len)
// 🟥 error: call to imported function 'c_parse_buffer' is unsafe API [#UnsafeImportedAPI]

@diagnose(UnsafeImportedAPI, as: warning)
func parseLegacyFormat(_ data: UnsafeRawPointer, _ count: Int) -> ParsedResult {
  c_parse_buffer(data, count)
  // 🟨 warning: call to imported function 'c_parse_buffer' is unsafe API [#UnsafeImportedAPI]
}
```

Diagnostic behavior can be refined further by modifying the severity of diagnostics belonging to the same group in a nested declaration:

```swift
@diagnose(UnsafeImportedAPI, as: warning)
struct LegacyFormatReader {
  func read(_ data: UnsafeRawPointer, _ count: Int) -> Header {
    c_read_bundle(data, count)
    // 🟨 warning: call to imported function 'c_read_bundle' is unsafe API [#UnsafeImportedAPI]
  }

  @diagnose(UnsafeImportedAPI, as: ignored, reason: "input is validated upstream")
  func readTrustedInput(_ data: UnsafeRawPointer, _ count: Int) -> Header {
    c_read_bundle(data, count)
    // No diagnostic is emitted
  }
}
```

Furthermore, the `@diagnose` attribute can be used to restrict behavior of diagnostic **sub**groups. For example, for a hypothetical subgroup `UnsafeImportedOwnership` of the `UnsafeImportedAPI` group, module-wide control (`-Werror UnsafeImportedAPI`) of the latter can be refined with a fine-grained scoped attribute for the former:

```swift
@diagnose(UnsafeImportedOwnership, as: warning)
func createSession(_ ctx: OpaquePointer) -> Session {
  let session = c_create_session(ctx)
  // 🟨 warning: cannot infer ownership of reference value returned by 'c_create_session' [#UnsafeImportedOwnership]

  c_bind_session(session, nil)
  // 🟥 error: call to imported function 'c_bind_session' is unsafe API [#UnsafeImportedAPI]
}
```

`import` statements can generate various warnings related to deprecation, cross-import overlays, and `import` access control violations. The `@diagnose` attribute can be used for fine-grained control over which import-related warnings should be treated as errors, warnings, or temporarily ignored.

## Detailed design

### @diagnose attribute on declarations

A `@diagnose` attribute's argument list must have at least two arguments: a diagnostic group identifier in the first position, and a diagnostic behavior specifier in the second position of a parameter labelled `as:`, supporting arguments `error`, `warning`, `ignored`. The attribute may have a third, optional string literal argument in the third position of a parameter labelled `reason:`. The reason argument must not have any string interpolation.

```
attribute → '@diagnose' '(' group-identifier ',' 'as' ':' behavior-specifier (',' 'reason' ':' static-string-literal)? ')'
    behavior-specifier → 'error' | 'warning' | 'ignored'
    group-identifier → identifier
```

This attribute only affects warning diagnostics belonging to the specified `group-identifier` diagnostic group.
Compilation **error** diagnostics, even when belonging to a specified diagnostic group, cannot be controlled by either diagnostic control compiler options or the `@diagnose` attribute.

The `@diagnose` attribute can be applied on:

* *`enum-declaration`*, *`struct-declaration`*, *`extension-declaration`*, *`class-declaration`*, *`actor-declaration`*, *`protocol-declaration`*, *`function-declaration`*, *`initializer-declaration`*, *`deinitializer-declaration`*, *`subscript-declaration`*, *`macro-declaration`*, computed property declaration (with a *`code-block`*), accessors (*`getter-clause`*, *`setter-clause`*, etc.), observers (*`willSet-clause`*, *`willSet-clause`*).
    Setting behavior of all warning diagnostics belonging to the indicated group in the ***lexical scope*** of the body of the corresponding declaration and the declaration's signature.
* *`union-style-enum-clause`*, *`raw-value-style-enum-case-clause`*, *`typealias-declaration`*, *`protocol-associated-type-declaration`*
    Setting behavior of all warning diagnostics belonging to the indicated group in the declaration's signature (these declaration kinds do not open a further lexical scope).
* *`macro-expansion-declaration`* (freestanding declaration macro invocation)
    Setting behavior of all warning diagnostics belonging to the indicated group in all declarations produced by the macro expansion.
* *`import-declaration`*
    Setting behavior of all warning diagnostics emitted on the import statement itself.

```swift
// Import statement
@diagnose(DiagGroupID, as: ignored)
import bar

// Function declaration
@diagnose(DiagGroupID, as: ignored, reason: "Proposal Example")
func foo() {...}

// Initializer and Deinitializer
struct Foo {
    @diagnose(DiagGroupID, as: ignored)
    init() {...}
    @diagnose(DiagGroupID, as: ignored)
    deinit {...}
}

// Subscript and Operator
struct FooCollection<T> {
  @diagnose(DiagGroupID, as: ignored)
  subscript(index: Int) -> T { ... }

  @diagnose(DiagGroupID, as: ignored)
  static func +++ (lhs: T, rhs: T) -> T { ... }
}

// Accessors
struct Foo {
    var property: Int {
        @diagnose(DiagGroupID, as: ignored)
        get {...}
        @diagnose(DiagGroupID, as: ignored)
        set {...}
    }
}

// Observers
extension Foo {
    var property: Int {
        @diagnose(DiagGroupID, as: ignored)
        willSet {...}
        @diagnose(DiagGroupID, as: ignored)
        didSet {...}
    }
}

// Enum
@diagnose(DiagGroupID, as: ignored)
enum Foo {...}

// Enum case
enum Foo {
  @diagnose(DiagGroupID, as: ignored)
  case c1
}

// Struct
@diagnose(DiagGroupID, as: ignored)
struct Foo {...}

// Class
@diagnose(DiagGroupID, as: ignored)
class Foo {...}

// Extension
@diagnose(DiagGroupID, as: ignored)
extension Foo {...}

// Actor
@diagnose(DiagGroupID, as: ignored)
actor Foo {...}

// Protocol
@diagnose(DiagGroupID, as: ignored)
protocol Foo {...}

// Typealias
@diagnose(DiagGroupID, as: ignored)
typealias Foo = Bar

// Associated type
protocol P {
  @diagnose(DiagGroupID, as: ignored)
  associatedtype Foo: Bar
}

// Macro declaration
@diagnose(DiagGroupID, as: ignored)
@freestanding(declaration)
macro Foo() = ...

// Freestanding declaration macro invocation
@diagnose(DiagGroupID, as: ignored)
#generateBindings(for: Foo)
```

The `@diagnose` attribute's effect on a declaration's signature includes other attributes applied to the same declaration, regardless of the position of `@diagnose` relative to non-`@diagnose` attributes. For example, if `@SomeWrapper` is deprecated, both of the following are equivalent and will escalate the deprecation warning to an error:

```swift
@diagnose(DeprecatedDeclaration, as: error)
@SomeWrapper func foo() { ... }

@SomeWrapper
@diagnose(DeprecatedDeclaration, as: error)
func foo() { ... }
```

### Interaction with compiler options and evaluation order

For a given warning diagnostic group, its global (module-wide) behavior is defined by the diagnostic’s default behavior and [compiler option evaluation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md#compiler-options-evaluation). A warning diagnostic’s default behavior is either to be always emitted or fully suppressed - where default-suppressed warnings can be enabled with `-Wwarning` and `-Werror`.

At the top-level file scope, a `@diagnose` attribute overrides the specified diagnostic group’s global behavior within the lexical scope of the declaration it is applied to. For example, for a globally-escalated (with `-Werror groupID`) diagnostic group, `@diagnose(groupID, as: warning)` top-level function declaration defines the behavior of `groupID` warnings within the lexical scope of the function’s body.

A `@diagnose` attribute applied to a declaration at a nested lexical scope overrides the specified diagnostic group’s behavior as defined for the parent lexical scope, either by the global behavior, or a `@diagnose` attribute applied to the parent scope declaration. For example, `@diagnose` attribute for diagnostic group `groupID` applied to a method definition in a `struct` declaration may override the diagnostic group’s global behavior as configured with compiler flags, or it may override the diagnostic group’s behavior as defined by a `@diagnose` attribute on the containing `struct`’s declaration.

#### Multiple `@diagnose` attributes on the same declaration

Application of multiple `@diagnose` attibutes on the same declaration is order-sensitive and follows a convention similar to [SE-0443](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md): lexically-last attribute "wins", i.e. multiple `@diagnose` attributes on a given declaration for nested or same diagnostic groups are evaluated in the order they are specified in source. For example:

```swift
@diagnose(DiagGroupID, as: error)
@diagnose(DiagGroupID, as: warning) // Overrides the above 'error' behavior
public func foo()
```

Multiple `@diagnose` attributes may be used to first specify a broader group policy, and later refine the policy for a specific sub-group. For example, if `UnsafeImportedOwnership` is a subgroup of `UnsafeImportedAPI`, the following annotation will first apply the `error` behavior for the broader parent group, and then apply the `ignored` behavior to the sub-group:

```swift
@diagnose(UnsafeImportedAPI, as: error)
@diagnose(UnsafeImportedOwnership, as: ignored) // Overrides the above 'error' behavior for a subset of the diagnostics
public func foo()
```

In the opposite case:

```swift
@diagnose(UnsafeImportedOwnership, as: ignored)
@diagnose(UnsafeImportedAPI, as: warning) // Overrides the above 'ignored' behavior for a superset of the diagnostics
public func foo()
```

The second attribute completely overrides the first attribute’s diagnostic severity directive by covering the super set of diagnostics covered by the first attirubte's diagnostic group.

Order-sensitivity is a departure from the norm of having attributes in Swift be order-insensitive (with the exception of property wrappers); however, order-sensitivity affords `@diagnose` an added expressivity of being able to specify both broad goup and fine-grained sub-group control, and do it in a fashion consistent with the command line flag behavior outlined in [SE-0443](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md).

#### Interaction with `-suppress-warnings`

[SE-0443](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md) deliberately excluded `-suppress-warnings` from the unified group control model, forbidding its combination with `-Wwarning` and `-Werror`. This proposal similarly treats `-suppress-warnings` as outside the scoped override model: when `-suppress-warnings` is in effect, it suppresses all warning diagnostics module-wide, and `@diagnose` attributes have no observable effect, including `@diagnose` attributes that specify `as: error` behavior.

This semantic is also in alignment with how [SE-0480](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0480-swiftpm-warning-control.md) handles warning control for remote package dependencies: SwiftPM strips all warning control flags (`-Werror`, `-Wwarning`, etc.) from the command line and substitutes `-suppress-warnings` when building a package as a dependency. If `@diagnose(groupID, as: error)` were honored under `-suppress-warnings`, source-level escalation would cause build failures in remote dependencies that the equivalent command-line flag (`-Werror groupID`) would not.

#### Behavior in macro-expanded code

If a macro expansion generates code inside a `@diagnose`-annotated scope, the attribute's effect applies to the expanded code. For example, if a method annotated with `@diagnose(groupID, as: ignored)` contains a call to an expression macro, warnings belonging to `groupID` that are emitted within the macro's expansion are also suppressed.

##### `@diagnose` on freestanding declaration macros

The `@diagnose` attribute can be applied to a freestanding declaration macro expansion. The attribute's behavior applies to *all* declarations produced by the macro expansion, analogous to applying `@diagnose` to a type declaration that contains multiple members:

```swift
@diagnose(DeprecatedDeclaration, as: ignored)
#generateLegacyBindings(for: OldFramework)
```

##### `@diagnose` in macro-generated code

Macro expansions are permitted to produce `@diagnose` attributes on declarations within the expansion. This allows macro authors to encode diagnostic expectations about the code they generate, escalating specific warnings to errors when the macro's own code-generation logic guarantees they should not occur, or suppressing warnings that are expected artifacts of a particular code-generation pattern.

For example, consider a freestanding declaration macro that generates a public API endpoint from a user-specified type:

```swift
#PublicEndpoint(returning: UserProvidedType)
```

Suppose the macro's authors intend its use to enforce a requirement that the generated public API must not expose deprecated types. Since the macro cannot control which type is specified as input, it escalates `DeprecatedDeclaration` warnings to errors in its expansion so that violations are caught immediately:

```swift
// The macro expansion may produce:
@diagnose(DeprecatedDeclaration, as: error)
public func endpoint() -> UserProvidedType {
  // 🟥 error: 'UserProvidedType' is deprecated [#DeprecatedDeclaration]
}
```

Without the ability to annotate its own expansion, the macro would have no way to express this intent, and users would need to manually apply `@diagnose` at every call site to achieve a similar enforcement.

When both the macro-expanded code and an enclosing scope both provide `@diagnose` attributes for the same diagnostic group, the normal nesting rules apply: the innermost (macro-generated) attribute overrides the enclosing attribute for the scope it is applied to.

##### `@diagnose` and attached peer macros

An `@diagnose` attribute applied to a declaration does not propagate to peer declarations generated by an attached macro on that declaration. Peer macros produce independent sibling declarations alongside the annotated declaration ([SE-0389](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0389-attached-macros.md)), and these peers are outside the lexical scope of the original declaration.

To control warning behavior in peer-generated declarations, macro authors can emit `@diagnose` attributes directly in the expansion (see *`@diagnose` in macro-generated code* above). Users who need broader control can apply `@diagnose` to an enclosing scope that contains both the original and the generated declarations, or use module-wide compiler flags.

### Effect on the public interface

This attribute is not emitted into textual module interfaces and does not affect emitted binary module contents.

## Source compatibility

This proposal is purely additive and has no effect on source compatibility.

## ABI compatibility

This proposal has no effect on ABI compatibility.

## Implications on adoption

This feature can be freely adopted and un-adopted in source code with no deployment constraints and without affecting source or ABI compatibility.

## Future directions

### Local lexical scope control

It may be desirable to provide a mechanism for an even finer-grained warning behavior control within lexical scopes which do not correspond to a declaration, such as a `do {}` block. For example, one can imagine extending the file-level `using @diagnose` mechanism to allow its use anywhere in a given lexical scope, affecting warnings emitted anywhere in entirety of the lexical scope (or strictly the code which follows the `using` statement within said lexical scope). This proposal focuses on providing such control at the granularity of a declaration, leaving this direction for future consideration.

### `closure-expression`

It may be desirable to provide a mechanism to control the behavior of warning diagnostics emitted in the body of a specific closure. Such a mechanism would need to be carefully weighed against any possible extension to this proposal for even finer-grained control as closures represent an intermediate granularity between full declarations and arbitrary code blocks.

### File-scope warning behavior control

A complementary proposal of the file-scope `using <attribute>` syntax would further expand on this capability by allowing the use of `using @diagnose(<group>, as: <behavior>)` to define file-scope warning behavior for a given diagnostic group, but is out of scope of this proposal.

### Generalized diagnostic control for third-party tools

Linters and other code analysis tools typically define their own mechanisms for suppressing or controlling diagnostics within a region of code, often through specially-formatted comments, e.g.
```swift
// swiftlint:disable rule1
class C {
...
}
// swiftlint:enable rule1
```
The `@diagnose` attribute could be extended to serve as a unified, declaration-level or source-file-level diagnostic control mechanism for third-party tools as well. This could take the form of an additional parameter to namespace the group identifier by tool, such as `@diagnose(unused_parameter, from: SwiftLint, as: ignored)`.

## Alternatives considered

### Region-based `#pragma`-style directives

Clang and other C-family compilers use `#pragma` directives to control diagnostic behavior within arbitrary regions of code:

```c++
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
...
#pragma clang diagnostic pop
```

While this mechanism is flexible, it does not align with Swift's conventions:

* Swift generally favors attaching metadata and behavior to declarations, making developer intent clear and self-documenting.
* Asking the developer to define the “end” of a region means requiring careful manual state management - forgetting or misplacing a region delimiter could lead to complex unintended behaviors when multiple scopes are overlapping and potentially affect nested diagnostic groups.

### Prohibiting `@diagnose` in macro-generated code

An alternative design would prohibit macro expansions from producing `@diagnose` attributes entirely, ensuring that all warning control is explicitly visible in the developer's source code. However, this would prevent macros from enforcing diagnostic policies on code they generate but do not fully control. Allowing `@diagnose` in macro expansions gives macro authors the ability to express these constraints directly, while users retain the ability to specify their own controls via `@diagnose` at the invocation site.

### Honoring `as: error` under `-suppress-warnings`

An alternative design would have `@diagnose(groupID, as: error)` take effect even under `-suppress-warnings`, allowing unconditional source-level escalation. However, this would be inconsistent with both [SE-0443](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md), which outlines that `-suppress-warnings` overrides `-Werror` and with [SE-0480](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0480-swiftpm-warning-control.md), which relies on `-suppress-warnings` to prevent remote package dependencies from failing builds, including when new warnings are introduced in future compiler versions.

## Acknowledgments

Allan Shortlidge, Kavon Farvardin, and Aviral Goel for their input on the attribute design and use cases.
