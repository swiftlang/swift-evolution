# Source-Level Control Over Compiler Warnings

* Proposal: [SE-0515](0515-source-warning-control.md)
* Authors: [Artem Chikin](https://github.com/artemcm), [Doug Gregor](https://github.com/douggregor), [Holly Borla](https://github.com/hborla)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#85036](https://github.com/swiftlang/swift/pull/85036), [swiftlang/swift-syntax#3174](https://github.com/swiftlang/swift-syntax/pull/3174)
* Experimental Feature Flag: `SourceWarningControl`
* Review: ([pitch](https://forums.swift.org/t/pitch-source-level-control-over-compiler-warnings/82766))

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
@warn(DeprecatedDeclaration, as: warning, reason: "Must maintain compatibility until end of release cycle")
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
@warn(ForeignReferenceType, as: error)
public func foo() {
  ...
}
```

Within the scope of the `foo` declaration in this example, the effect of the attribute is equivalent to `-Werror ForeignReferenceType`, but without affecting diagnostic behavior on any other source code in the current module. The attribute supports 3 `as:` behavior specifiers: `error`, `warning`, and `ignored`. The attribute also supports an optional `reason:` parameter which accepts a string literal. With `error` and `warning` behavior specifiers, the attribute has the effect equivalent to that of `-Werror <groupID>` and `-Wwarning <groupID>`, respectively, without affecting other source code in the module. With the `ignored` behavior specifier, warnings belonging to the diagnostic group `<groupID>` are fully suppressed (akin to a global (module-wide) `-Wsuppress`, which does not exist).

The `@warn` attribute overrides diagnostic behavior for the specified diagnostic group, relative to its *enclosing scope* - with command-line behavior specifiers representing global (module-wide) scope: `-warnings-as-errors`, `-Werror`, `-Wwarning`.

For example, suppose there existed a hypothetical diagnostic group `UnsafeImportedAPI`. On a compilation which specifies either `-warnings-as-errors` or `-Werror UnsafeImportedAPI`, the `@warn` attribute can be used to lower the severity of `UnsafeImportedAPI` diagnostics to a warning within the scope of a specific method, while the same code pattern elsewhere in the module would be diagnosed as an error:

```swift
let result = c_parse_buffer(ptr, len)
// 🟥 error: call to imported function 'c_parse_buffer' is unsafe API [#UnsafeImportedAPI]

@warn(UnsafeImportedAPI, as: warning)
func parseLegacyFormat(_ data: UnsafeRawPointer, _ count: Int) -> ParsedResult {
  c_parse_buffer(data, count)
  // 🟨 warning: call to imported function 'c_parse_buffer' is unsafe API [#UnsafeImportedAPI]
}
```

Diagnostic behavior can be refined further by modifying the severity of diagnostics belonging to the same group in a nested declaration:

```swift
@warn(UnsafeImportedAPI, as: warning)
struct LegacyFormatReader {
  func read(_ data: UnsafeRawPointer, _ count: Int) -> Header {
    c_read_bundle(data, count)
    // 🟨 warning: call to imported function 'c_read_bundle' is unsafe API [#UnsafeImportedAPI]
  }

  @warn(UnsafeImportedAPI, as: ignored, reason: "input is validated upstream")
  func readTrustedInput(_ data: UnsafeRawPointer, _ count: Int) -> Header {
    c_read_bundle(data, count)
    // No diagnostic is emitted
  }
}
```

Furthermore, the `@warn` attribute can be used to restrict behavior of diagnostic **sub**groups. For example, for a hypothetical subgroup `UnsafeImportedOwnership` of the `UnsafeImportedAPI` group, module-wide control (`-Werror UnsafeImportedAPI`) of the latter can be refined with a fine-grained scoped attribute for the former:

```swift
@warn(UnsafeImportedOwnership, as: warning)
func createSession(_ ctx: OpaquePointer) -> Session {
  let session = c_create_session(ctx)
  // 🟨 warning: cannot infer ownership of reference value returned by 'c_create_session' [#UnsafeImportedOwnership]

  c_bind_session(session, nil)
  // 🟥 error: call to imported function 'c_bind_session' is unsafe API [#UnsafeImportedAPI]
}
```

`import` statements can generate various warnings related to deprecation, cross-import overlays, and `import` access control violations. The `@warn` attribute can be used for fine-grained control over which import-related warnings should be treated as errors, warnings, or temporarily ignored.

## Detailed design

### @warn attribute on declarations

A `@warn` attribute's argument list must have at least two arguments: a diagnostic group identifier in the first position, and a diagnostic behavior specifier in the second position of a parameter labelled `as:`, supporting arguments `error`, `warning`, `ignored`. The attribute may have a third, optional string literal argument in the third position of a parameter labelled `reason:`. The reason argument must not have any string interpolation.

```
attribute → '@warn' '(' group-identifier ',' 'as' ':' behavior-specifier (',' 'reason' ':' static-string-literal)? ')'
    behavior-specifier → 'error' | 'warning' | 'ignored'
    group-identifier → identifier
```

This attribute only affects warning diagnostics belonging to the specified `group-identifier` diagnostic group.
Compilation **error** diagnostics, even when belonging to a specified diagnostic group, cannot be controlled by either diagnostic control compiler options or the `@warn` attribute.

The `@warn` attribute can be applied on:

* *`function-declaration`*, *`initializer-declaration`*, *`deinitializer-declaration`*, *`subscript-declaration`*, *`getter-clause`*, *`setter-clause`*, computed property declaration (with a *`code-block`*)
    Setting behavior of all warning diagnostics belonging to the indicated group in the ***lexical scope*** of the body of the corresponding declaration.
* *`enum-declaration`*, *`struct-declaration`*, *`extension-declaration`*, *`class-declaration`*, *`actor-declaration`*, *`protocol-declaration`*
    Setting behavior of all warning diagnostics belonging to the indicated group in the ***lexical scope*** of the declaration, affecting all declarations contained within.
* *`import-declaration`*
    Setting behavior of all warning diagnostics emitted on the import statement itself.

```swift
// Import statement
@warn(DiagGroupID, as: ignored)
import bar

// Function declaration
@warn(DiagGroupID, as: ignored, reason: "Proposal Example")
func foo() {...}

// Initializer and Deinitializer
struct Foo {
    @warn(DiagGroupID, as: ignored)
    init() {...}
    @warn(DiagGroupID, as: ignored)
    deinit {...}
}

// Subscript and Operator
struct FooCollection<T> {
  @warn(DiagGroupID, as: ignored)
  subscript(index: Int) -> T { ... }

  @warn(DiagGroupID, as: ignored)
  static func +++ (lhs: T, rhs: T) -> T { ... }
}

// Getter and Setter
struct Foo {
    var property: Int {
        @warn(DiagGroupID, as: ignored)
        get {...}
        @warn(DiagGroupID, as: ignored)
        set {...}
    }
}

// Enum
@warn(DiagGroupID, as: ignored)
enum Foo {...}

// Struct
@warn(DiagGroupID, as: ignored)
struct Foo {...}

// Class
@warn(DiagGroupID, as: ignored)
class Foo {...}

// Extension
@warn(DiagGroupID, as: ignored)
extension Foo {...}

// Actor
@warn(DiagGroupID, as: ignored)
actor Foo {...}

// Protocol
@warn(DiagGroupID, as: ignored)
protocol Foo {...}
```

### Interaction with compiler options and evaluation order

For a given warning diagnostic group, its global (module-wide) behavior is defined by the diagnostic’s default behavior and [compiler option evaluation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md#compiler-options-evaluation). A warning diagnostic’s default behavior is either to be always emitted or fully suppressed - where default-suppressed warnings can be enabled with `-Wwarning` and `-Werror`.

At the top-level file scope, a `@warn` attribute overrides the specified diagnostic group’s global behavior within the lexical scope of the declaration it is applied to. For example, for a globally-escalated (with `-Werror groupID`) diagnostic group, `@warn(groupID, as: warning)` top-level function declaration defines the behavior of `groupID` warnings within the lexical scope of the function’s body.

A `@warn` attribute applied to a declaration at a nested lexical scope overrides the specified diagnostic group’s behavior as defined for the parent lexical scope, either by the global behavior, or a `@warn` attribute applied to the parent scope declaration. For example, `@warn` attribute for diagnostic group `groupID` applied to a method definition in a `struct` declaration may override the diagnostic group’s global behavior as configured with compiler flags, or it may override the diagnostic group’s behavior as defined by a `@warn` attribute on the containing `struct`’s declaration.

#### Multiple `@warn` attributes on the same declaration

More than one `@warn` attribute on a given declaration for the same diagnostic group is not valid and results in an error.

```swift
@warn(DiagGroupID, as: error)
@warn(DiagGroupID, as: warning) // 🟥 error: multiple conflicting `@warn` attributes for group `DiagGroupID`.
public func foo()
```

Multiple `@warn` attributes on a given declaration for nested diagnostic groups are evaluated in the order they are specified in source. For example:

```swift
@warn(UnsafeImportedAPI, as: error)
@warn(UnsafeImportedOwnership, as: ignored)
public func foo()
```

Where `UnsafeImportedOwnership` is a subgroup of `UnsafeImportedAPI`, this annotation will first apply the `error` behavior for the broader parent group, and then apply the `ignored` behavior to the sub-group. In the opposite case:

```swift
@warn(UnsafeImportedOwnership, as: ignored)
@warn(UnsafeImportedAPI, as: warning) // 🟨 warning: `warning` diagnostic behavior for `UnsafeImportedAPI` overrides prior attribute for `UnsafeImportedOwnership` `ignored` behavior
public func foo()
```

The second attribute completely overrides the first attribute’s diagnostic severity directive, with a corresponding compiler warning.

#### Interaction with `-suppress-warnings`

[SE-0443](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md) deliberately excluded `-suppress-warnings` from the unified group control model, forbidding its combination with `-Wwarning` and `-Werror`. This proposal similarly treats `-suppress-warnings` as outside the scoped override model: when `-suppress-warnings` is in effect, it suppresses all warning diagnostics module-wide, and `@warn` attributes specifying `warning` or `ignored` behavior have no additional observable effect (warnings are already suppressed).

However, `@warn` attributes that *escalate* diagnostics — `@warn(groupID, as: error)` — do take effect even under `-suppress-warnings`. This allows developers to enforce critical diagnostic policies at the declaration level regardless of the module-wide suppression setting with an explicit, deliberate in-source assertion. Honoring `as: error` behavior control under `-suppress-warnings` ensures that source-level annotations can always be used to express "this must not be ignored here".

#### Behavior in macro-expanded code
If a macro expansion generates code inside a `@warn`-annotated scope, the attribute's effect applies to expanded code as well.

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

It may be desirable to provide a mechanism for an even finer-grained warning behavior control within lexical scopes which do not correspond to a declaration, such as a `do {}` block. For example, one can imagine extending the file-level `using @warn` mechanism to allow its use anywhere in a given lexical scope, affecting warnings emitted anywhere in entirety of the lexical scope (or strictly the code which follows the `using` statement within said lexical scope). This proposal focuses on providing such control at the granularity of a declaration, leaving this direction for future consideration.

### `closure-expression`

It may be desirable to provide a mechanism to control the behavior of warning diagnostics emitted in the body of a specific closure. Such a mechanism would need to be carefully weighed against any possible extension to this proposal for even finer-grained control as closures represent an intermediate granularity between full declarations and arbitrary code blocks.

### File-scope warning behavior control

A complementary proposal of the file-scope `using <attribute>` syntax would further expand on this capability by allowing the use of `using @warn(<group>, as: <behavior>)` to define file-scope warning behavior for a given diagnostic group, but is out of scope of this proposal.

### Generalized diagnostic control for third-party tools

Linters and other code analysis tools typically define their own mechanisms for suppressing or controlling diagnostics within a region of code, often through specially-formatted comments, e.g.
```swift
// swiftlint:disable rule1
class C {
...
}
// swiftlint:enable rule1
```
The `@warn` attribute could be extended to serve as a unified, declaration-level or source-file-level diagnostic control mechanism for third-party tools as well. This could take the form of an additional parameter to namespace the group identifier by tool, such as `@warn(unused_parameter, from: SwiftLint, as: ignored)`.

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

## Acknowledgments

Allan Shortlidge, Kavon Farvardin, and Aviral Goel for their input on the attribute design and use cases.
