# Literal Expressions

* Proposal: [SE-0531](0531-literal-expressions.md)
* Authors: [Artem Chikin](https://github.com/artemcm), [Doug Gregor](https://github.com/douggregor)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Accepted** 
* Implementation: [swiftlang/swift#86500](https://github.com/swiftlang/swift/pull/86500), [swiftlang/swift#86934](https://github.com/swiftlang/swift/pull/86934), [swiftlang/swift#87006](https://github.com/swiftlang/swift/pull/87006)
* Experimental Feature Flag: `LiteralExpressions`
* Review: ([pitch](https://forums.swift.org/t/pitch-literal-expressions/85505))([review](https://forums.swift.org/t/se-0531-literal-expressions/86794))

## Summary of changes
Several language constructs in Swift require the use of integer literal values: generic value arguments ([SE-0452](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0452-integer-generic-parameters.md)), variables attributed with `@section` ([SE-0492](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0492-section-control.md)), and enum raw values. This proposal builds on the notion of a "constant expression" introduced in [SE-0492](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0492-section-control.md), renaming it *literal expression*, and expanding it to include integer arithmetic, bitwise, and unary operations on literal values of standard library integer types, as well as references to other compile-time-known integer variables. Literal expressions are constant-folded to a single literal value result at compile time. The change is strictly additive with no API or ABI impact.

## Motivation

Each of the three literal expression contexts today requires the programmer to pre-compute values by hand and transcribe the result as a bare literal. The intent behind the value is often lost, leading to a proliferation of "magic" constants throughout the code. Documenting these constants and keeping them in sync with other related use-sites is an added maintenance burden on the developer, with no help from the compiler.

### `@section` and compile-time initializers

The `@section` attribute is aimed specifically at systems and embedded use cases, where values are routinely defined in terms of other constants, e.g. page sizes, register offsets, protocol field widths. As it stands, [SE-0492](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0492-section-control.md) requires that `@section` values are initialized with bare literals and does not yet support operators or variable references in initializer expressions:

```swift
@section("__DATA,config") let pageSize = 4096
@section("__DATA,config") let bufferSize = 65536
@section("__DATA,config") let c = 1 + 1  // ❌ error: operators not allowed
```
Even a common value like `4096` requires the reader to recognize it as *4 x 1024* rather than seeing that intent directly in the code. The fact that `bufferSize` is a derived value of *16 x pageSize* is entirely invisible. Referencing a named constant from a C header, such as `PAGE_SIZE`, is also impossible; the raw number must be copied by hand.

### Enum raw values

Enum raw values have been limited to plain literals since Swift 1.0. There are many use cases where this restriction meaningfully limits expressivity. For example, bit-flag enumerations are a natural fit for shift expressions, yet their raw values cannot currently be expressed that way:

```swift
enum Permissions: Int {
  case read = 1
  case write = 2
  case execute = 4
}
```
A more natural way to express what the developer *means* is `1 << 0`, `1 << 1`, `1 << 2`. This form makes the pattern explicit, self-documenting, and harder to get wrong. The same issue applies when enum raw values are meant to be derived from other constants:

```swift
enum PageSize: Int {
  case standard = 4096   // 4 * 1024
  case large = 16384     // 16 * 1024
}
```

Furthermore, this is a pattern that C and C++ have long supported in their enumerations, making it a natural tool that developers expect available to them.

### Integer generic arguments

[SE-0452](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0452-integer-generic-parameters.md) introduced integer generic parameters, enabling types like `InlineArray<5, Int>`. Today, the generic argument must also be a bare integer literal. Consider a database schema definition where row size is defined once and buffer sizes are derived from it:

```swift
let schemaRowSize = 32

// Want: InlineArray<(2 * schemaRowSize), UInt8>
let buffer: InlineArray<64, UInt8>  // hope 64 == 2 * 32
```

If `schemaRowSize` changes, every derived `InlineArray` size in the codebase must be found and updated by hand, with the change in the value hopefully documented in a comment somewhere nearby. This process is likely to be error-prone and the compiler is unable to assist it with diagnostics. [SE-0452](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0452-integer-generic-parameters.md) identifies this gap, listing "use of constant bindings as generic parameters" and "arithmetic in generic parameters" as desired future directions.

#### Expressivity lost to "magic" constants

These three language constructs share the same fundamental restriction: the programmer must act as a human calculator, pre-computing every value and transcribing the result as a bare literal. The intent behind the value, *why* it is that number, is lost, making code harder to read, harder to maintain, and harder to audit. 

## Proposed solution

This proposal introduces *literal expressions*: expressions of standard library integer types composed of integer literals, standard library arithmetic and bitwise operators, and references to other compile-time-known integer variables. These expressions are constant-folded by the compiler to a single integer-valued result of the appropriate type. All three contexts from the Motivation section are extended to accept literal expressions.

`@section` variable initializers can now express their values in terms of arithmetic operations and other compile-time-known variables:

```swift
@section("__DATA,config") let pageSize = 4 * 1024
@section("__DATA,config") let bufferSize = 16 * pageSize
```

Enum raw values can now be specified using the full range of integer literal expressions:

```swift
enum Permissions: Int {
  case read    = 1 << 0
  case write   = 1 << 1
  case execute = 1 << 2
}
```

Similarly, integer generic values can now be arbitrary literal expressions enclosed in parentheses:

```swift
let schemaRowSize = 32
let buffer: InlineArray<(2 * schemaRowSize), UInt8>
```

A module compiled with literal expressions produces identical artifacts to one where the developer wrote the pre-computed literals by hand.

## Detailed design

### Literal expressions

A *literal expression* is an expression of a standard library integer type that the compiler can reduce at compile time to a single integer value. The following grammar defines the supported expression forms:

```
literal-expression → integer-literal
literal-expression → unary-operator literal-expression
literal-expression → literal-expression binary-operator literal-expression
literal-expression → '(' literal-expression ')'
literal-expression → identifier
```

The supported binary operators are the arithmetic operators `+`, `-`, `*`, `/`, `%`, the wrapping arithmetic operators `&+`, `&-`, `&*`, the bitwise operators `&`, `|`, `^`, the shift operators `<<`, `>>`, and the masking shift operators `&<<`, `&>>`. The supported unary prefix operators are `+`, `-`, and `~`. The non-wrapping arithmetic operators diagnose integer overflow at compile time, while the wrapping forms silently reduce the result modulo the declared type's bit width. The masking shift operators reduce the shift amount modulo the bit width of the result type, matching Swift's runtime semantics. Operator precedence and associativity follow Swift's standard rules.

Operator resolution for literal expressions follows Swift's ordinary name lookup. The compiler identifies the operator callee as it would for any other expression, then verifies that the chosen declaration is a standard library operator on a standard library integer type. If lookup resolves to a user-defined overload, the expression is rejected, even when a matching standard library overload is also in scope. This keeps the fold consistent with runtime execution: a literal expression reduces to the same value that the expression would compute at runtime, and no parallel lookup rule needs to be maintained alongside the standard one.

The result type must be one of the standard library integer types: `Int`, `Int8`, `Int16`, `Int32`, `Int64`, `Int128`, `UInt`, `UInt8`, `UInt16`, `UInt32`, `UInt64`, or `UInt128`.

```swift
let a = 4 * 1024                  // ✅ arithmetic
let b = 1 << 12                   // ✅ bitwise shift
let c = (0xFF & mask) | base      // ✅ bitwise operators and parentheses
let d = -1                        // ✅ unary negation
let w: UInt8 = 250 &+ 10          // ✅ wrapping addition, folds to 4
let e = Int.max / 2               // ❌ property access
let f = a +% b                    // ❌ user-defined operator
```

### Variable references in literal expressions

A literal expression may reference another variable by name, given that the referenced variable is a Swift `let` binding with a default initializer which is itself a literal expression. This includes module-scope and static `let` bindings, variables declared with `@section`, `@objc`, or `@c`, and constants imported from C-family languages. For C imports, values visible to the Swift compiler as constant-initialized are resolved to their value so `static const int` declarations and simple `#define` integer macros can participate directly.

References to variables that form part of the module's binary interface are not permitted in a literal expression. This precludes references to variables with `public`, `package`, or `open` access, and also `internal` variables marked `@usableFromInline`. Folding such a reference would cause the variable's value to become part of the module's ABI surface, which conflicts with this proposal's position that literal expressions introduce no ABI changes.

A `public`, `package`, or `open` variable can be folded by a client directly, while a `@usableFromInline` variable, though not nameable by a client, can still have its value reach one when an `@inlinable` function folds it into an integer generic argument serialized into the inlined body. Variables that are `internal` without `@usableFromInline`, `fileprivate`, or `private` carry no such exposure and remain eligible. Lifting the restriction is left to a future proposal with an explicit opt-in for publishing a value as part of a module's ABI.

References are resolved recursively: when a literal expression references a variable, the compiler folds that variable's initializer to a literal value, then uses the result. A chain of references is followed until a root literal is reached or an initializer is encountered which cannot be constant-folded. No annotation is required on the referenced variable. The compiler infers the constant-foldable property by inspecting the variable's initializer.

```swift
let pageSize = 4 * 1024
let bufferSize = 16 * pageSize             // ✅ references pageSize

import CSystem
let systemBuffer = 4 * SYSTEM_PAGE_SIZE    // ✅ C constant

var mutableSize = 4096
let derived = 2 * mutableSize              // ❌ cannot reference a 'var'

let computed: Int = { 4096 }()             // ❌ initializer is not a literal expression 
let derived2 = 2 * computed
```

### `@section` variable initializers

Variables attributed with `@section` may now have literal expression initializers, where [SE-0492](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0492-section-control.md) previously required bare literals. The compiler folds the expression to a single literal value, which is then used for static initialization and section placement.

```swift
@section("__TEXT,config") let pageSize = 4 * 1024
@section("__TEXT,config") let bufferSize = 16 * pageSize
@section("__TEXT,config") let systemPage = PAGE_SIZE    // C constant
```

The original expression is preserved in the AST for diagnostics and IDE indexing functionality. Module interfaces do not emit initializer values for `@section` variables, so the original expression does not get printed into the `.swiftinterface` file.

If an `@section` initializer expression cannot be folded, the compiler emits an error:

```swift
@section("__TEXT,config") let pageSize = 2 * Int.random(in: 0...512) // ❌ error: not a literal expression
```

### Enum raw values

Enum cases with (supported) integer raw types may now use literal expressions as raw values. The expression is type-checked against the enum's declared raw type, then constant-folded to a literal value.

```swift
enum Permissions: UInt8 {
  case read    = 1 << 0    // 1
  case write   = 1 << 1    // 2
  case execute = 1 << 2    // 4
}
```

Automatic incrementing for cases without explicit raw values continues from the folded value of the preceding case:

```swift
enum Example: Int {
  case a = 2 + 2    // 4
  case b            // 5
}
```

If a raw value expression cannot be folded, the compiler emits a diagnostic:

```swift
enum Invalid: UInt8 {
  case x = UInt8.random(in: 0...10)    // ❌ error: not a literal expression
}
```

Module interfaces do not emit explicit raw values for enums, so neither the original expressions or folded constants appear in `.swiftinterface` files.

### Integer generic parameter arguments

Integer generic arguments, as introduced by [SE-0452](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0452-integer-generic-parameters.md), may now be literal expressions. The grammar for generic arguments is extended to:

```
generic-argument → type
generic-argument → '-'? integer-literal
generic-argument → '(' literal-expression ')'
```

The third form is new. Literal expressions in generic argument position must be enclosed in parentheses to disambiguate from the type-argument parsing context, where `<`, `>`, and `,` tokens serve as delimiters. Bare integer literals (with an optional unary `-`) continue to work without parentheses, as established by [SE-0452](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0452-integer-generic-parameters.md).

```swift
let schemaRowSize = 32
let buffer: InlineArray<(2 * schemaRowSize), UInt8>    // ✅
let flags: InlineArray<(1 << 4), Bool>                 // ✅
let small: InlineArray<5, Int>                         // ✅
```

The `[N of T]` sugar from [SE-0452](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0452-integer-generic-parameters.md) also accepts parenthesized literal expressions:

```swift
let row: [(2 * schemaRowSize) of UInt8]
```

The folded value determines type identity: `InlineArray<(2 + 3), Int>` and `InlineArray<5, Int>` are the same type. Generic requirements are satisfied by the folded value, so a constraint `where N == 5` is satisfied by a type argument of `(2 + 3)`.

When the compiler encounters a parenthesized expression in generic argument position, it first attempts to interpret it as a type expression (tuple). If that succeeds, the argument is treated as a type; otherwise, the expression is type-checked with contextual type `Int` and constant-folded. This ensures that existing type expressions such as `S<(S<()>.X)>` continue to work unchanged.

### Compile-time diagnostics

Several classes of errors in literal expressions are detected and diagnosed at compile time.

Integer overflow is diagnosed when an arithmetic operation produces a result outside the range of the target type:

```swift
let x: UInt8 = 100 * 3    // ❌ error: integer overflow
```

Division and remainder by zero are also diagnosed:

```swift
let y = 10 / 0    // ❌ error: division by zero
let z = 10 % 0    // ❌ error: division by zero
```

Expressions containing unsupported constructs, such as function calls, closures, subscripts, etc., produce a diagnostic indicating the construct is not supported in a literal expression:

```swift
@section("__TEXT,data") let a = abs(-1)    // ❌ error: not supported in a literal expression
```

When a variable reference cannot be folded because the referenced variable's initializer is not itself a literal expression, the compiler diagnoses the error at the initializer site and emits a note pointing to the variable's reference in a literal expression context:

```swift
let runtimeValue = Int.random(in: 0...100)                // ❌ error: not supported in a literal expression
@section("__TEXT,data") let derived = runtimeValue + 1    //    note: requested from reference in a literal expression
                                  
```

## Source compatibility

This proposal extends three expression contexts and does not remove or alter any expression form accepted elsewhere. In the common case existing Swift code retains its previous meaning. Two cases deserve explicit discussion.

### Generic argument list disambiguation

The grammar extension that admits `'(' literal-expression ')'` in generic-argument position widens the set of token sequences the parser can accept as a generic argument list. Consider a call site such as:

```swift
Foo<(a < b, c > .d)>(x)
```

Under the rules prior to this proposal, `<...>` cannot parse as a generic argument list because the content between the angle brackets is not a bare integer literal. The parser falls back to chained comparison: `(Foo < (a < b, c > .d)) > (x)`. Under the new rule, the parser attempts to interpret the parenthesized content as a type expression first (a tuple type), and only on failure as a literal expression. The tuple-type interpretation fails here because `a < b` and `c > .d` are not types, and the literal-expression interpretation also fails because a tuple is not a literal expression. The parse falls through to the prior behavior, so existing code of this shape continues to mean what it meant before.

Type-expression forms introduced by [SE-0452](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0452-integer-generic-parameters.md), such as `S<(S<()>.X)>`, continue to parse as type arguments under the tuple-first rule.

### Value bindings shadowing type names

A local `let` binding that shadows a type name does not change how a parenthesized identifier resolves in generic-argument position:

```swift
let Int = 0
let a: Array<(Int)>    // '(Int)' resolves to the type 'Int', not the local value
```

The tuple-first disambiguation tries `(Int)` as a type first and succeeds, so the generic argument is the type `Int` and the local `let` binding plays no role. The literal-expression interpretation is only attempted when the parenthesized content cannot be resolved as a type.

## ABI compatibility

This proposal has no ABI impact. Literal expressions are folded to a single literal value entirely within the compiler frontend. No changes are made to code generation, the runtime, or symbol mangling. For integer generic arguments, the *folded* value appears as part of the type in module interfaces (e.g., `InlineArray<5, Int>`); for `@section` variables and enum raw values, neither the original expressions nor folded constants appear in module interfaces. A module compiled with literal expressions produces identical binaries to one where the developer wrote the pre-computed literals by hand.

## Implications on adoption

The feature is gated behind the `LiteralExpressions` experimental feature flag. There is no minimum deployment target requirement, since the folding happens at compile time and the emitted code is identical to hand-written literal values. Libraries can adopt literal expressions in their source without affecting clients.

## Future directions

### Lifting the parenthesized integer generic value expression restriction

This proposal requires that integer generic value expressions be enclosed in parentheses, e.g. `InlineArray<(2 + 3), Int>`, while bare integer literals continue to work without them per SE-0452. The parentheses are needed because the `<`, `>`, and `,` tokens that delimit generic argument lists conflict with operators and expression separators, making the grammar ambiguous without a delimiter.

We have a work-in-progress [design](https://github.com/swiftlang/swift/pull/87493) for lifting this restriction by teaching the parser to treat `>`, `==`, and `,` as stop tokens when parsing expressions inside generic argument lists. Under this approach, `InlineArray<2 + 3, Int>` would parse correctly, with parentheses remaining necessary only for the few operators that conflict with generic argument delimiters, such as `>` and `==`. Further work is needed on the source-compatibility implications of this design, before it is folded into the main proposal.

### Floating-point literal expressions

Supporting arithmetic operators (`+`, `-`, `*`, `/`) on `Float` and `Double` literals is a natural next step that would benefit the same contexts, particularly `@section` variables in embedded code where floating-point constants are common. Floating-point folding requires careful consideration of target-dependent precision and rounding semantics, which merits its own design discussion.

### String literal expressions

String concatenation of compile-time-known values (e.g. `"hello" + " world"`) and interpolation with compile-time-known integer or string values are natural extensions of the literal expression concept. This would enable more expressive initializers for `@section` variables and string-typed enum raw values, and would open the door to compile-time validation of string-based APIs such as URL construction.

### Expanding the supported set of operators

This proposal supports arithmetic, bitwise, and unary operators on integers. A natural progression is to expand the set of recognized operations to include comparison operators (`==`, `<`, `>=`, etc.) producing compile-time `Bool` values, standard library functions like `min()`, `max()`, and `abs()`, and, once floating-point literal expressions are supported, mathematical functions such as trigonometric operations.

Compile-time `Bool` values in turn enable control flow in compile-time expressions: the ternary operator (`condition ? a : b`) and `if`/`else` used as expressions. Together, these would significantly broaden what can be expressed without requiring full compile-time function evaluation.

### Compile-time programming

Literal expressions establish the compiler's ability to evaluate a defined set of operations at compile time and reduce them to concrete values. A natural evolution is to broaden this surface into a more general compile-time programming model, encompassing the capabilities explored in [SE-0359](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0359-build-time-constant-values.md) ("Build-Time Constant Values") and extending beyond them to support user-defined pure functions, richer data types, and compile-time validation.

## Alternatives considered

### Require an explicit annotation on all referenced variables

An alternative design would require that any variable referenced in a literal expression carry an explicit annotation (such as `@const`). The review of [SE-0359](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0359-build-time-constant-values.md) ("Build-Time Constant Values") identified virality of such annotations as a central concern: once one declaration requires `@const`, every variable it depends on must also carry the annotation, and the requirement propagates transitively through the codebase, akin to `constexpr` in C++.

For literal expressions the annotation adds no information the compiler does not already have. The supported operations and types are fully known, so the compiler can determine whether a variable's initializer is foldable by inspecting its definition. If it is not, the error is diagnosed regardless of whether an annotation is present. Explicit `@const` annotations have value in a future compile-time programming system as cross-module contracts, but for this proposal's scope, inference is sufficient and avoids introducing annotation virality before the broader system that would justify it.

### Use the term "constant expression" instead of "literal expression"

"Constant expression" is the established term in C and C++, and [SE-0492](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0492-section-control.md) used it for the restricted initializer expressions it introduced. The term "literal expression" was chosen here for two reasons.

The first is scoping. Every context this proposal extends accepts only a literal value today: an `@section` initializer, an enum case raw value, an integer generic argument. The compiler reduces each expression covered by this proposal to a single literal value, which is then used in generated code in exactly the same way a bare literal would have been. The feature's surface is fundamentally literal-valued, and the name reflects this.

The second is the risk of overpromising. "Constant expression" has a broader meaning in C++, where `constexpr` encompasses user-defined functions, control flow, object construction, and a growing body of standard library operations. Swift is likely to want a term that corresponds to that larger notion once it exists: a general compile-time expression that may reduce to an integer, a floating-point value, a string, a tuple, a frozen struct, or some other compile-time value. Reserving "constant expression" for that broader notion leaves room to describe it precisely when it arrives. Adopting the term for this proposal's feature would anchor it at the narrow end of the spectrum and force later proposals to either repurpose the term or introduce a new one.

The name also communicates what is *not* in scope. A literal expression is an expression that folds to a literal value; control flow, user-defined operators, and compound types are out of scope by construction. A reader who encounters a diagnostic of the form "not a literal expression" receives a concrete description of the restriction, rather than the more elastic promise that "constant expression" would carry.

## Acknowledgments

[Kuba Mracek](https://github.com/kubamracek), [Joe Groff](https://github.com/jckarter), [Alejandro Alonso](https://github.com/azoy), [Hamish Knight](https://github.com/hamishknight)

