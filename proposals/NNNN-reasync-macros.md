# `@Reasync` and `@ReasyncMembers`

* Proposal: [SE-NNNN](NNNN-reasync-macros.md)
* Authors: [broken-circle](https://github.com/broken-circle)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [swift-developer-tools/swift-reasync](https://github.com/swift-developer-tools/swift-reasync)
* Review: ([pitch](https://forums.swift.org/t/pitch-reasync-and-reasyncmembers-macros/86180))


## Summary of changes

Adds `@Reasync` and `@ReasyncMembers` macros that generate synchronous 
overloads of `async` functions by removing `async` and `await` keywords, 
allowing a single source of truth for functions that must exist in both 
synchronous and asynchronous forms.


## Motivation

Swift developers frequently need the same function to exist in both 
synchronous and asynchronous forms. For example, a library that works 
with both synchronous and asynchronous user-provided closures cannot 
expose a single function that accepts either version. Swift does not 
currently offer a way to make a function generic over the `async`-ness 
of its parameters. The canonical workaround is to write the function 
twice: once as `async` and once as synchronous, with the two 
declarations differing only in the presence of the `async` and `await` 
keywords.

This pattern appears in the author's own library 
[swift-test-kit](https://github.com/swift-developer-tools/swift-test-kit), 
which offers a parallel API for Swift Testing and XCTest. swift-test-kit 
contains paired sync/`async` implementations across property-based, 
stateful, temporal, performance, and atomic evaluators, each duplicated 
to support both synchronous and asynchronous test bodies. In all of 
these cases, the synchronous function is identical to the `async` 
version, apart from the `async` and `await` keywords.

This duplication is not a small cost. Each paired implementation doubles 
the surface area that must be tested, documented, and kept in sync. 
Drift between the two versions is easy to introduce, since any bug fix, 
refactor, or behavioral change applied to one version but not the other 
produces inconsistency between the synchronous and asynchronous APIs. 

The cost compounds over time and grows with the complexity of the 
function being duplicated. Consider the following overload from 
swift-test-kit, one of four `XCTKForAll` property-based testing 
overloads that each ship in both synchronous and asynchronous forms:

```swift
public func XCTKForAll<each T>(
    using generators    : repeat Generator<each T>,
    where precondition  : @escaping (repeat each T) -> Bool,
    examples            : @autoclosure () -> [(repeat each T)]  = [],
    message             : @autoclosure () -> String             = "",
    fileID              : StaticString                          = #fileID,
    file                : StaticString                          = #filePath,
    line                : UInt                                  = #line,
    column              : UInt                                  = #column,
    options             : TestOptions?                          = nil,
    _ property          : (repeat each T) async throws -> Void
) async
{
    await TKForAll(
        using:      repeat each generators,
        where:      precondition,
        examples:   examples,
        message:    message,
        fileID:     fileID,
        file:       file,
        line:       line,
        column:     column,
        options:    options ?? TestConfiguration.current,
        property,
        context:    failureContext
    )
}
```

Every parameter, default value, trivia detail, and call-site forwarding 
must be replicated exactly in the synchronous overload. swift-test-kit's
property-based testing API has four `ForAll` overloads (differing in 
generator and precondition usage), each of which must ship in both 
synchronous and asynchronous forms. Across the library's Swift Testing 
and XCTest APIs, that produces 16 declarations to keep in sync for 
only one of many evaluator types (PBT, stateful, temporal, atomic, 
performance).

The Swift community has 
[explored](https://forums.swift.org/t/a-case-study-for-reasync/64590) 
a language-level solution similar to `rethrows`. Swift compiler engineer 
Doug Gregor explained:

> `reasync` is in a tricky place because the design is easy (just follow 
> `rethrows` but with `async`), and the motivation is easy, but a decent 
> implementation in the compiler is a bunch of work.
>
> Moreover, it's *almost* a syntactic-sugar feature, because you can get 
> nearly the same effect by duplicating the code into `async` and 
> non-`async` versions. Indeed, now that we have macros, I'd be curious 
> just how far one can get by implementing a peer macro that, when 
> applied to an `async` function with `async` closure parameters, 
> produces a synchronous version of that function that zaps the `async` 
> from closure parameters as well as all of the `await`s within the 
> function body.

A full `reasync` language feature remains difficult for the reasons 
explored in that thread and elsewhere. So far, no proposal has advanced.
But Doug Gregor's observation points at a narrower solution that does 
not require language-level changes: If the workaround is duplication, 
and the duplication is mechanical, then the duplication can reliably be 
generated by a macro.

This proposal formalizes that observation. The `@Reasync` peer macro is 
attached to an `async` function and synthesizes its synchronous overload 
by removing `async` and `await`. The `@ReasyncMembers` member macro does 
the same thing at the type scope, generating synchronous overloads for 
all functions declared within the type, and can be applied to structs, 
classes, enums, actors, and extensions.

This allows library authors to maintain a single source of truth, while 
Swift's overload resolution selects the appropriate version at the call 
site. The macros do not attempt to solve the general problem that a 
language-level `reasync` would solve, but they solve the common case 
that most library authors actually encounter in practice, and they do 
so with machinery that already exists in the language.


## Proposed solution

This proposal adds two macros to either the Swift standard library or 
to a swiftlang-org package. The choice of venue is left open. Either 
path provides the canonical, shared solution that library authors 
currently lack.

The `@Reasync` macro is attached to an `async` function declaration. 
At compile time, it produces a synchronous overload of the function by 
removing `async` and `await` from the declaration and body.

```swift
@Reasync
func run(
    _ body: () async throws -> Void
) async rethrows
{
    try await body()
}

// Generated by @Reasync:
// 
// func run(
//     _ body: () throws -> Void
// ) rethrows
// {
//     try body()
// }
```

The asynchronous declaration is the single source of truth. The 
synchronous overload is produced at compile time, and Swift's overload 
resolution selects the appropriate version at each call site based on 
the caller's context.

The transformation applies throughout the function, not just the 
signature. `async let` bindings become `let` bindings, `for await` 
loops become `for` loops, and `await` expressions are replaced by their 
synchronous equivalents:

```swift
@Reasync
func sum(
    _ a             : Int,
    _ b             : Int,
    using compute   : (Int) async -> Int
) async -> Int
{
    async let x : Int   = compute(a)
    async let y : Int   = compute(b)
    
    return await x + y
}

// Generated by @Reasync:
// 
// func sum(
//     _ a             : Int,
//     _ b             : Int,
//     using compute   : (Int) -> Int
// ) -> Int
// {
//     let x : Int   = compute(a)
//     let y : Int   = compute(b)
// 
//     return x + y
// }
```

All other attributes, modifiers, generic constraints, trivia, and 
documentation comments are preserved in the generated overload, so the 
synchronous version carries the same API-level presentation as the 
asynchronous source.

`@ReasyncMembers` applies the same transformation to every asynchronous 
function member of an annotated type or extension:

```swift
@ReasyncMembers
struct Operations
{
    func double(
        _ value: Int
    ) async -> Int
    {
        return value * 2
    }
    
    // Generated: synchronous overload of double(_:).
    
    func increment(
        _ value: Int
    ) -> Int
    {
        return value + 1
    }
    
    // No overload generated: increment(_:) is already synchronous.
}
```

Synchronous members are left unchanged. Members that are already 
annotated with `@Reasync` are skipped, since `@Reasync` generates its 
own overload. `@ReasyncMembers` can be applied to structs, classes, 
enums, actors, and extensions.

Returning to the motivating example, the duplication in swift-test-kit 
collapses to a single annotation:

```swift
@Reasync
public func XCTKForAll<each T>(
    using generators    : repeat Generator<each T>,
    // parameters omitted
    _ property          : (repeat each T) async throws -> Void
) async
{
    // body omitted
}
```

The synchronous overload is generated at compile time. 16 declarations 
across swift-test-kit's property-based testing API collapse to 8, with 
no possibility of drift between sync and `async` overloads.

The macros rely on Swift's own type-checking to validate the generated 
overload. If the body contains constructs that are inherently 
asynchronous, such as calls to actor-isolated methods or `async`-only 
APIs, the compiler rejects the generated overload with an error at the 
invalid expression. This makes the macros safe to use: A function can 
only be marked `@Reasync` if it can actually be made synchronous.

Because the transformation is purely syntactic, the macros impose no 
constraints on future evolution of Swift's concurrency model. Any 
constraint they would impose already exists today wherever a developer 
maintains paired sync and `async` overloads by hand. The 
[Semantic Validity](#semantic-validity) subsection details the 
equivalence between the generated peer and a hand-written declaration.


## Detailed design

For a full working implementation, please see 
[swift-reasync](https://github.com/swift-developer-tools/swift-reasync/tree/main).

### Macro declarations

Two macros are introduced:

```swift
@attached(peer, names: overloaded)
public macro Reasync()

@attached(member, names: arbitrary)
public macro ReasyncMembers()
```

`@Reasync` is a peer macro that declares `overloaded` names, since the 
generated declaration shares its name with the annotated function, and 
is distinguished from it only by its `async`-ness.

`@ReasyncMembers` is a member macro that declares `arbitrary` names, 
since the set of generated declarations is determined by the `async` 
members the annotated type may contain.

### Transformation

Both macros apply the same purely syntactic transformation: The macro 
walks the function's syntax tree and removes `async` and `await` tokens 
wherever they appear, leaving all other syntax unchanged. 

The following tokens are removed:

- The `async` effect specifier in the function signature.
- The `async` effect specifier in any closure parameter types, 
including deeply-nested specifiers.
- Each `await` keyword. The inner expression is preserved in place.
- The `async` modifier on `async let` bindings, producing an ordinary 
`let` binding.
- The `await` keyword in `for await` loops, including `for try await`.

All other syntax is preserved, including:

- The function name, generic parameters, generic `where` clauses, the 
parameter list, parameter default values, the return type, any 
attributes other than `@Reasync`, access-level modifiers, and any other 
declaration modifiers.
- `throws`, `rethrows`, and typed throws such as `throws(SomeError)`.
- The function body in its entirety, apart from the removed tokens.
- Leading and trailing trivia, including whitespace, newlines, source 
comments, and documentation comments.

### Trivia preservation

The transformation is designed to produce generated code that is 
indistinguishable from hand-written code, so trivia attached to removed 
tokens is transferred to the next meaningful token rather than being 
discarded.

- When the `async` effect specifier is removed from a function signature 
that also has a `throws` clause, the leading trivia of `async` is 
transferred to `throws`, preserving the spacing between the parameter 
list and the effects clause. 

- When `async` is removed from an `async let` binding, the trivia is 
transferred to the `let` keyword, or to the first remaining modifier, 
if one is present.

- When `await` is removed from a `for await` loop, the trivia is 
transferred to the `try` keyword, if present, and to the loop's pattern 
otherwise.

- When `await` is removed from an expression, the trivia is transferred 
to the inner expression, preserving the indentation of the enclosing 
statement.

The `@Reasync` attribute is removed from the generated peer declaration. 
If `@Reasync` was the only attribute, its leading trivia is transferred 
to the next access-level modifier, or to the `func` keyword if no 
modifiers are present. If other attributes are present, the leading 
trivia is transferred to the first remaining attribute. This ensures 
that the generated peer retains the same leading whitespace and 
documentation comments as the source declaration.

### Overload resolution

The generated synchronous declaration has the same name, generic 
signature, parameter list, and return type as the annotated function, 
differing only in the absence of `async` in the signature and in 
closure parameter types.

Swift's existing overload resolution selects the appropriate overload 
based on the calling context. A call from a synchronous context resolves 
to the generated synchronous overload, and a call from an asynchronous 
context resolves to the `async` source.

### Diagnostics

The macros emit the following diagnostics:

- `@Reasync can only be applied to async functions` is emitted when 
`@Reasync` is attached to a synchronous function declaration.
- `@Reasync cannot be applied to protocols` is emitted when 
`@ReasyncMembers` is attached to a protocol declaration.
- `@Reasync can only be applied to async functions` is emitted when 
`@Reasync` is attached to a declaration that is not a function. If the 
declaration is a type declaration other than a protocol (i.e. a struct, 
class, enum, actor, or extension), the diagnostic also includes a fix-it 
that replaces `@Reasync` with `@ReasyncMembers`.

### Member macro behavior

`@ReasyncMembers` iterates the function members of the annotated 
declaration and applies the `@Reasync` transformation to each one that 
meets all of the following conditions:

- The member is a function declaration.
- The function is declared `async`.
- The function is not already annotated with `@Reasync`.

Synchronous functions are left unchanged. Functions already annotated 
with `@Reasync` are skipped to avoid producing duplicate peers, since 
`@Reasync` generates its own overloads. Non-function members, such as 
stored properties, computed properties, initializers, and subscripts 
are ignored.

`@ReasyncMembers` can be applied to structs, classes, enums, actors, 
and extensions. It cannot be applied to protocols, since protocol 
declarations contain requirements rather than implementations, and 
the transformation requires a function body to be meaningful.

### Semantic validity

The transformation walks the syntax tree of the function declaration, 
and does not inspect or have access to the semantics of the function 
body. After macro expansion, the Swift compiler determines whether the 
generated synchronous declaration is valid at the usual semantic 
analysis stage. If the body contains constructs that are inherently 
asynchronous, such as calls to actor-isolated methods or calls to 
`async`-only APIs, the generated overload will fail to compile, and the 
compiler will report the error at the site of the invalid expression in 
the expanded source.

This is the intended behavior. It ensures at compile time that the 
macro cannot silently produce a synchronous function that diverges in 
meaning from the asynchronous source.

Because the transformation is purely syntactic, the generated 
synchronous overload is indistinguishable from a hand-written 
declaration with the `async` and `await` keywords removed. 
The compiler applies the same parsing, type-checking, and 
isolation-checking rules to the generated peer that it would apply to 
any other declaration in the source file. The macros introduce no new 
constructs that the compiler needs to recognize, and contribute no 
behavior at run time.

An inherent consequence of operating on the syntax tree is that the 
macros cannot enforce the discipline that a language-level `reasync` 
would. A true language feature, modeled on `rethrows`, would require 
that the function's `async` effect arise only from its closure 
parameters, and the compiler would reject any function where this is 
not the case. The macro has no comparable enforcement, since determining 
whether a given `await` corresponds to a closure parameter requires 
semantic analysis the macro cannot perform. A function that calls an 
`async`-only API independently of its parameters can therefore be marked 
`@Reasync` and expand successfully. The compile error appears afterward, 
when the generated peer is type-checked. The error will identify the 
offending expression in the generated source, but the macro itself 
cannot flag the misuse at the attachment site.

Any property of the generated peer declaration (whether it compiles, 
what diagnostics it produces, how it interacts with isolation checking, 
and so on) is fundamentally a property of the equivalent hand-written 
declaration. The macros do not introduce new edge cases or limitations 
beyond those that may already exist in synchronous Swift.

### Grammar and parsing

The macros introduce no new syntax. They are applied using the existing 
attribute syntax and require no changes to the Swift grammar or parser.


## Source compatibility

This proposal is purely additive. It introduces two new macro 
declarations and does not modify any existing language features, 
standard library APIs, or parsing rules. Existing code continues to 
compile and behave exactly as before.

The macro names `Reasync` and `ReasyncMembers` occupy the attribute 
namespace, but attribute names do not conflict with identifiers in 
other namespaces. Code that uses `Reasync` or `ReasyncMembers` as a 
type name, function name, or variable name is unaffected.


## ABI compatibility

The macros have no ABI impact of their own. They expand at compile time 
to ordinary Swift function declarations, and the ABI of each generated 
declaration is exactly that of the equivalent hand-written synchronous 
function. Existing compiled code is unaffected.


## Implications on adoption

The macros are implemented entirely at compile time via SwiftSyntax, 
and require no runtime support.

Adopting `@Reasync` or `@ReasyncMembers` in a library is a 
source-compatible change for the library's clients, since the macros 
only introduce new synchronous overloads alongside the existing 
asynchronous declarations. Clients in asynchronous contexts continue 
to resolve to the original asynchronous declarations, and clients in 
synchronous contexts gain access to the newly-generated overloads.

Removing `@Reasync` or `@ReasyncMembers` from a declaration whose 
generated synchronous overloads are in use by clients is a 
source-breaking change, since the synchronous overloads are no longer 
generated. Library authors should therefore treat the synchronous 
overloads as part of the library's public API once adopted, in the same 
way as any other API.

Neither adopting nor removing the macros affects ABI compatibility, 
since the macros expand to ordinary function declarations at compile 
time.


## Future directions

Each of the following future directions is discussed in further detail 
in [Alternatives considered](#alternatives-considered).

### A language-level `reasync`

A language-level `reasync` keyword would allow a single function 
declaration to be synchronous or asynchronous depending on its closure 
arguments, similar to how `rethrows` interacts with `throws`. Such a 
feature would subsume this proposal and extend to cases the macros 
cannot cover, such as protocol requirements.

### Protocol support for `@ReasyncMembers`

Extending `@ReasyncMembers` to protocol declarations would generate 
synchronous requirement declarations alongside asynchronous ones. This 
would require different transformation logic and raises design questions 
better addressed in a separate proposal.

### Asynchronous overloads generated from synchronous sources

Symmetric macros that generate asynchronous overloads from synchronous 
sources could complement the macros proposed here, but are not 
included in this proposal.


## Alternatives considered

### A language-level `reasync`

The most direct alternative is a `reasync` keyword that mirrors 
`rethrows`, allowing a single function declaration to be synchronous or 
asynchronous depending on the `async`-ness of its closure arguments.

A language-level `reasync` would be strictly more expressive than the 
macros proposed here. It would allow a single symbol to serve both 
calling contexts, and would extend to protocol requirements, both of 
which are outside the scope of what a peer macro can do.

The macros are not a replacement for `reasync`. They cover the common 
case of paired synchronous and asynchronous implementations that differ 
only in `async`-ness, with functionality that exists today. A 
language-level `reasync`, if added in the future, would subsume this 
use case and extend to the cases the macro cannot cover. This proposal 
and a possible future `reasync` are complementary.

### A single combined peer-and-member macro

The two proposed macros could in principle be combined into a single 
macro that behaves as a peer macro when attached to a function, and 
behaves as a member macro when attached to a type. This would simplify 
the user-facing API to a single attribute name.

The author implemented and tested this approach. It is not possible 
under Swift's current macro system. The compiler validates that all 
roles of a multi-role macro target are the same declaration kind, and 
peer and member roles operate on function declarations and type 
declarations, respectively. A single macro cannot carry both roles.

The proposed two-macro design also has the practical advantage of 
making the user's intent explicit at the attachment site: `@Reasync` 
unambiguously produces one peer, while `@ReasyncMembers` unambiguously 
iterates the type's members. This removes any ambiguity about which 
mode is active.

### Asynchronous overloads generated from synchronous sources

The proposed macros generate synchronous overloads from asynchronous 
sources, but not the reverse. A symmetric pair of macros could generate 
asynchronous overloads from synchronous sources by inserting `async` 
and `await` keywords.

The proposal does not include this direction for two reasons.

1. The transformation is not mechanical in the same way. There is 
no single correct place to insert `await`, since a synchronous function 
body does not generally have enough information to determine which calls 
should become asynchronous. A purely syntactic transformation cannot 
produce correct code without semantic knowledge the macro does not have.

2. The practical motivation is weaker. When a library provides 
both versions of a function, the asynchronous version is almost always 
the more general one, and libraries typically start with a synchronous 
implementation and add an asynchronous version later. The direction of 
this proposal matches how the duplication actually arises in practice.

### Protocol support for `@ReasyncMembers`

`@ReasyncMembers` could in principle be extended to protocol 
declarations, generating synchronous requirement declarations alongside 
asynchronous ones. This would complement the existing Swift convention 
of providing both synchronous and asynchronous forms of a protocol 
such as `Sequence` and `AsyncSequence`.

The proposal does not include this extension. The macro's transformation 
is defined in terms of rewriting a function body, and protocol 
requirements have no body to rewrite. A protocol-aware extension would 
require different logic: generating requirement declarations rather 
than implementations, and deciding whether the synchronous and 
asynchronous requirements should belong to the same protocol or to 
separate protocols. These are significant design questions that would 
expand the scope of this proposal and are better addressed separately.

### Diagnosing misuse syntactically at the expansion site

The macro could attempt a best-effort syntactic check at expansion time, 
refusing to expand (or emitting a warning) when an `await` in the body 
does not appear to correspond to a call on one of the function's closure 
parameters. This would surface diagnostics on the original source rather 
than on generated code, more closely approximating the experience a 
language-level `reasync` would provide.

This proposal does not include such a check. The macro operates on the 
syntax tree and has no access to type information or name resolution. 
The cases where a syntactic check would suffice are a small subset of 
legitimate uses of `@Reasync`.

Consider the simplest case, where a syntactic check would work:

```swift
@Reasync
func run(
    _ body: () async -> Int
) async -> Int
{
    return await body()
}
```

This is true `reasync`-ability: `run(_:)` is `async` only because it 
needs to call `body`. The macro can see this from the syntactic AST 
alone.

Now consider:

```swift
@Reasync
func run(
    _ body: () async -> Int
) async -> Int
{
    let callback = body
    return await callback()
}
```

The syntactic check sees `await callback()` and notes that `callback` 
is not a parameter. Refusing to expand would be wrong, since the 
function is perfectly `reasync`-able. The macro would need semantic 
analysis to reliably determine that `callback` is bound to `body`.

Similar problems arise with methods on parameters 
(`await body.someMethod()`), passing closures through other constructs, 
or any number of indirections the compiler handles trivially but a 
syntax walker cannot handle. A check strict enough to be sound would 
reject legitimate patterns, while a check loose enough to accept them 
would miss most of the cases it was meant to catch.

The compiler's downstream type-checking is a more reliable enforcement 
mechanism, even though it produces diagnostics on generated code rather 
than on the source.

### Keeping the macros as a third-party package

The macros are currently published as a third-party package, 
[swift-reasync](https://github.com/swift-developer-tools/swift-reasync). 
Leaving them there indefinitely is one possible outcome.

The case against this outcome is that the problem these macros solve is 
universal across Swift libraries that support both synchronous and 
asynchronous calling contexts. Leaving the solution in a third-party 
package means that each library that adopts such macros either takes on 
a dependency on one particular package, or duplicates the 
implementation. In the latter case, the Swift ecosystem ends up with 
multiple incompatible implementations of the same transformation, with 
inconsistent naming, semantics, and diagnostics. Either outcome 
fragments the solution.

Promoting the macros to a canonical location, either within the Swift 
standard library or as a swiftlang-org package, avoids this 
fragmentation and signals that these macros are the recommended solution 
to this problem until a language-level feature potentially supersedes 
them.

### A `sed` script or code generator

The earlier 
[Swift Forums discussion](https://forums.swift.org/t/a-case-study-for-reasync/64590) 
for `reasync` noted that the transformation can be accomplished with a 
`sed` script that rewrites an asynchronous source file into a 
synchronous one at build time.

This approach works, but has significant drawbacks compared to a macro:

- It operates on text rather than a syntax tree, and cannot distinguish 
`async` as a keyword from `async` appearing in an identifier or comment.
- It requires a build step external to the Swift compiler, and is not 
portable across platforms.
- It produces a separate source file that must be committed or 
regenerated, rather than a compile-time expansion.
- It cannot emit diagnostics on invalid inputs at the point of the 
annotation.

A macro-based solution addresses all of these concerns by operating 
on the Swift AST and integrating with the compiler's existing expansion 
and diagnostic infrastructure.

### Preserving `@Reasync` on the generated peer

The peer macro could in principle leave `@Reasync` on the generated 
synchronous declaration. This would have the advantage of making the 
relationship between the source declaration and generated declaration 
visible in the expanded code.

The proposal instead removes `@Reasync` from the peer. The macro would 
otherwise re-trigger on the generated declaration, producing infinite 
expansion, or require special-case handling in the macro expansion 
logic to suppress re-triggering. Removing the attribute is the simpler 
and more robust choice, and the relationship between the source 
declaration and generated declaration remains evident from the expansion 
itself.


## Acknowledgments

Thank you to ZPedro for the Swift Forum thread 
[A case study for `reasync`](https://forums.swift.org/t/a-case-study-for-reasync/64590).

Thank you to Doug Gregor for the observation in the linked thread that a 
peer macro could plausibly cover the common case.

Thank you to Konrad Malawski for encouraging this proposal in the linked 
thread.