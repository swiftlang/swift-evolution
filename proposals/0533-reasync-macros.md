# Generating synchronous overloads of `async` functions with a macro

* Proposal: [SE-0533](0533-reasync-macros.md)
* Authors: [broken-circle](https://github.com/broken-circle)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Active review (June 1...June 15, 2026)**
* Implementation: [swift-developer-tools/swift-reasync](https://github.com/swift-developer-tools/swift-reasync/tree/evolution)
* Review: ([pitch](https://forums.swift.org/t/pitch-reasync-and-reasyncmembers-macros/86180))

## Summary of changes

This proposal adds an `@Reasync` macro that generates a synchronous 
overload of an `async` function, allowing a single source of truth for 
functions that must exist in both synchronous and asynchronous forms.


## Motivation

Swift developers frequently need the same function to exist in both 
synchronous and asynchronous forms. For example, a library that works 
with both synchronous and asynchronous user-provided closures cannot 
expose a single function that accepts either version. Swift does not 
currently offer a way to make a function generic over the `async`-ness 
of its parameters. The canonical workaround is to write the function 
twice: once as `async` and once as synchronous, with the two 
declarations typically differing only in the presence of the `async` 
and `await` keywords.

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
Doug Gregor [explained](https://forums.swift.org/t/a-case-study-for-reasync/64590/28): 

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
explored in that thread and elsewhere; no proposal has advanced. But 
Doug Gregor's observation points at a narrower solution that does not 
require language-level changes: If the workaround is mechanical 
duplication, then the duplication can be generated by a macro.


## Proposed solution

This proposal adds the `@Reasync` macro either to the Swift standard 
library or as an official package in the `swiftlang` GitHub 
organization. The choice of venue is left open. Either path provides 
the canonical, shared solution that library authors currently lack.

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
    _       values      : [Int],
    using   transform   : (Int) async -> Int
) async -> Int
{
    var total: Int = 0

    for value in values
    {
        total += await transform(value)
    }

    return total
}

// Generated by @Reasync:
//
// func sum(
//     _       values      : [Int],
//     using   transform   : (Int) -> Int
// ) -> Int
// {
//     var total: Int = 0
//
//     for value in values
//     {
//         total += transform(value)
//     }
//
//     return total
// }
```

Aside from the concurrency annotations covered in 
[Strict concurrency](#strict-concurrency), all attributes, modifiers, 
generic constraints, trivia, and documentation comments are preserved 
in the generated overload, so the synchronous version carries the same 
API-level presentation as the asynchronous source.

Returning to the motivating example, `@Reasync` eliminates the 
duplication in swift-test-kit with a single annotation:

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

16 declarations across swift-test-kit's property-based testing API 
collapse to 8, with no possibility of drift between sync and `async` 
overloads.


## Detailed design

For a full working implementation, please see 
[swift-reasync](https://github.com/swift-developer-tools/swift-reasync/tree/evolution).

### Macro declarations

A new macro is introduced:

```swift
@attached(peer, names: overloaded)
public macro Reasync()
```

The macro is declared as introducing `overloaded` names because the 
generated peer has the same name as the source function, differing 
only in the signature changes required to make it a valid synchronous 
declaration. Swift's overload resolution distinguishes the two 
declarations at each call site, selecting the synchronous peer in 
synchronous contexts and selecting the asynchronous source in 
asynchronous contexts.

### Transformation

The macro walks the function's syntax tree and removes the `async` and 
`await` keywords wherever they appear, along with the related 
concurrency annotations that are either invalid on synchronous forms or 
that the peer's synchronous body can no longer support. All other 
syntax is preserved.

The macro removes:

- The `async` effect specifier in the function signature.
- The `async` effect specifier in any closure parameter types, 
including deeply-nested specifiers.
- Each `await` keyword, preserving the inner expression in place.
- The `async` modifier on `async let` bindings, producing ordinary 
`let` bindings.
- The `await` keyword in `for await` loops, including `for try await`.
- The `@Sendable` attribute on closure types appearing in the 
function's parameter clause, at any depth. Closure types appearing in 
body positions are not affected (for example, local binding type 
annotations).
- The `@isolated(any)` attribute on closure parameter types appearing 
in the function's parameter clause, at any depth. Closure types 
appearing in body positions are not affected, as with `@Sendable`.
- The `@concurrent` attribute on the function declaration and on 
closure parameter types.
- The `nonisolated(nonsending)` modifier on the function declaration 
and on closure parameter types.

The rationale for each of these removals is detailed in 
[Strict concurrency](#strict-concurrency).

### Nesting

The transformation is applied recursively throughout the function to 
which the macro is attached. Every nested declaration that the function 
body contains (nested function declarations, closure expressions, and 
computed property accessors) and every nested function type that appears 
in the body have their `async` tokens, `await` tokens, concurrency 
annotations, and `async let`/`for await` constructs rewritten in the 
same way as the outer function. This is necessary for the generated 
synchronous peer to compile, since any `async` token, `await` token, or 
concurrency annotation left untransformed in a nested position would be 
invalid in the synchronous context of the peer.

Because nested function declarations are transformed by the enclosing 
macro, attaching `@Reasync` directly to a nested function has no 
additional effect. The macro emits a warning at the redundant attribute, 
along with a fix-it to remove it. See [Diagnostics](#diagnostics).

### Local computed properties

Local computed properties declared inside the body of an `@Reasync` 
function may have `async` accessors. The transformation applies to 
these accessors as it does to nested function declarations: the `async` 
effect specifier is removed from the accessor's signature, and the 
body is rewritten in the same way as the outer function. This is 
necessary for the generated synchronous peer to compile, since the 
body's accesses to the property are rewritten to remove `await`, and 
would otherwise be invalid against an `async` accessor.

`@Reasync` is not supported on a computed property declaration. 
Although the macro's transformation is well-defined for an `async` 
accessor, the result cannot participate in the language's overload 
resolution: two property declarations with the same name and type at 
the same scope are an invalid redeclaration, not an overload, 
regardless of `async`.

### Strict concurrency

The macro's transformation removes `async` and `await` from the function 
declaration, but real-world `async` functions in Swift 6 frequently 
carry additional annotations. The macro handles these as follows:

| Annotation                | Rule     | Removal Scope                                  |
|---------------------------|----------|------------------------------------------------|
| `async`, `await`          | Remove   | Everywhere                                     |
| `@isolated(any)`          | Remove   | Closure parameter types (at any nesting depth) |
| `nonisolated(nonsending)` | Remove   | Everywhere                                     |
| `@concurrent`             | Remove   | Everywhere                                     |
| `@Sendable`               | Remove   | Closure parameter types (at any nesting depth) |
| `sending`                 | Preserve |                                                |
| Global actors             | Preserve |                                                |
| `isolated` parameters     | Preserve |                                                |
| Bare `nonisolated`        | Preserve |                                                |

The rules are designed to produce a synchronous peer that is 
type-correct under Swift 6 strict concurrency in the cases the macro is 
intended to handle, without silently changing the meaning of annotations 
that have nothing to do with concurrent execution.

#### `@isolated(any)`

`@isolated(any)` is removed from closure types in the function's 
parameter clause. The annotation is allowed on synchronous function 
types, so in positions outside the function's parameter clause (for 
example, a local binding's type annotation in the body), the macro 
preserves it.

[SE-0431](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0431-isolated-any-functions.md) 
specifies the rule that governs calls to `@isolated(any)` function 
values:

> Since the isolation of an `@isolated(any)` function value is 
> statically unknown, calls to it typically cross an isolation boundary. 
> This means that the call must be `await`ed even if the function is 
> synchronous...

SE-0431 also describes an exception to this rule: calls that do not 
cross an isolation boundary because the caller is isolated to a 
derivation of the function's `.isolation`. This exception relies on 
language mechanisms (for example, `isolated` captures on closure 
expressions) that cannot be expressed by a function declaration's 
signature. The synchronous peer that the macro generates is a function 
declaration; its isolation is fixed by global actor attributes, an 
`isolated` parameter, or `nonisolated`, and cannot be made dependent on 
a derivation of a parameter's `.isolation` property. Any call to the 
closure parameter in the peer's body therefore crosses an isolation 
boundary and requires `await`.

However, a synchronous function body cannot contain `await`. The peer 
must therefore omit `@isolated(any)` to compile in the common case that 
the macro is intended to handle.

#### `nonisolated(nonsending)`

`nonisolated(nonsending)` is removed wherever it appears. 
[SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md) 
defines `nonisolated(nonsending)` as an annotation on `async` functions: 

> Async functions annotated with `nonisolated(nonsending)` will always 
> run on the caller's actor.

The compiler accordingly rejects `nonisolated(nonsending)` on 
synchronous functions and on synchronous function types. Since the 
generated peer is always synchronous, the annotation is removed 
unconditionally.

#### `@concurrent`

`@concurrent` is removed wherever it appears. The annotation is the 
counterpart to `nonisolated(nonsending)` under SE-0461 and is subject 
to the same restriction:

> `@concurrent` cannot be applied to synchronous functions.

The restriction extends to synchronous function types as well. Since 
the generated peer is always synchronous, the annotation is removed 
unconditionally.

#### `@Sendable`

`@Sendable` is removed from closure types in the function's parameter 
clause. Unlike the annotations above, `@Sendable` remains legal on a 
synchronous function: the language does not reject it, and a 
hand-written synchronous overload could retain it without a compile 
error. The macro removes it since, in the common case, an `@Sendable` 
constraint on a closure parameter is present because the `async` 
function body sends the closure across an isolation boundary (for 
example, by passing it into a child task via `async let` or 
`TaskGroup`). The generated peer eliminates these constructs and 
invokes the closure in-place, in the caller's isolation, so the 
`@Sendable` requirement is no longer needed for the peer's body to 
compile. The Language Steering Group identified this behavior in its 
evaluation of this proposal:

> ...at least in this case, that `@Sendable` annotation could be 
> filtered from the generated synchronous variant since the parallel 
> execution is eliminated.

`@Sendable` on a closure type that appears elsewhere in the source is 
preserved (for example, on a local binding's type annotation in the 
function body). The macro's transformation eliminates parallel execution 
arising from `async let` and `for await` constructs in the function 
body, but does not transform `Task`-based concurrent execution that the 
body may also contain. An `@Sendable` annotation in body position may 
still be required by the body's own constructs, and the macro preserves 
it rather than risk producing a peer that fails strict concurrency 
checking.

This default fits the common case, but is not universal. The Language 
Steering Group flagged this directly:

> [Filtering the `@Sendable` annotation] may not necessarily be a 
> universally applicable part of the transform.

Determining whether `@Sendable` remains necessary on the synchronous 
peer would require the macro to analyze what the function body does 
with the closure: whether the closure is sent across an isolation 
boundary, captured by a `Task`, shared with another concurrent context, 
and so on. The macro operates on syntax alone and cannot perform this 
analysis. Its only options are to always remove `@Sendable` or to 
always preserve it.

The macro always removes it. Always preserving `@Sendable` would 
silently over-constrain callers in cases where the macro's 
transformation has already eliminated the parallel execution that 
motivated the annotation. Always removing `@Sendable` instead surfaces 
potential misalignments as a compile error, where the user can write 
the synchronous overload by hand.

There are cases where this default does not match the author's intent 
or the body's actual needs, and the macro cannot distinguish them 
from the syntax alone. When this happens, the generated peer fails 
strict-concurrency checking, and the compiler surfaces the diagnostic 
in the macro expansion. There is no silent miscompilation. The author 
writes the synchronous overload by hand, where the type system applies 
the same checks to an ordinary declaration. The asynchronous source 
can remain `@Reasync`-free in that case. The macro is intended to 
eliminate the mechanical duplication that arises in the common case; 
it is not intended to express every possible relationship between an 
`async` function and its synchronous counterpart.

#### `sending`

`sending` is preserved on parameters and on return types. Unlike the 
annotations above, `sending` does not describe how a function executes; 
it describes a property of the values that flow across the function's 
boundary. [SE-0430](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md) 
makes this explicit through an example in which `sending` appears on a 
fully synchronous method:

> ```swift
> @MainActor
> struct S {
>   let ns: NonSendable
>
>   func getNonSendable() -> sending NonSendable {
>     return NonSendable() // okay
>   }
> }
> ```

The `sending` annotation on this synchronous method permits the caller 
to send the returned value across an isolation boundary, exactly as it 
would for an `async` function with the same return type. The 
annotation's meaning is independent of whether the function is `async`.

The same reasoning applies to `sending` parameters. A `sending` 
parameter expresses that the caller's region is split at the call site, 
allowing the callee to send the value into an opaque region. This 
applies whether the callee is synchronous or asynchronous. SE-0430 
specifies:

> A `sending` function parameter requires that the argument value be in 
> a disconnected region. At the point of the call, the disconnected 
> region is no longer in the caller's isolation domain, allowing the 
> callee to send the parameter value to a region that is opaque to the 
> caller.

#### Isolation

The macro preserves the function's isolation. Global actor attributes 
such as `@MainActor`, bare `nonisolated` modifiers, and `isolated` 
parameters carry over to the peer unchanged. These annotations describe 
properties that are independent of whether the function is `async`. 
SE-0461 draws this distinction directly:

> nonisolated functions will have consistent execution semantics by 
> default, regardless of whether the function is synchronous or 
> asynchronous.

The same holds for global actor isolation and `isolated` parameters: 
they describe where the function runs, not whether it suspends. Because 
the peer's static isolation matches the source's, a call to the peer 
that originates from a context with the same isolation does not cross 
an isolation boundary, and the sendability rules that govern the 
source's parameters and results apply identically to those of the peer.

The dynamic-isolation distinctions that SE-0461 introduces for `async` 
functions, between `nonisolated(nonsending)` and `@concurrent`, are not 
expressible on synchronous functions, as described in the preceding 
[`nonisolated(nonsending)`](#nonisolatednonsending) and 
[`@concurrent`](#concurrent) sections. Bare `nonisolated` carries no 
such constraint and applies to synchronous and asynchronous functions 
equally; it is preserved on the peer without modification.

### Overload resolution

The generated synchronous declaration has the same name, generic 
signature, parameter list, and return type as the annotated function. 
With `async` removed from the signature, it qualifies as an overload of 
the source under [SE-0296](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0296-async-await.md), 
which permits two declarations to differ only in `async` and specifies 
the resolution rule for selecting between them:

> Given a call, overload resolution prefers non-`async` functions 
> within a synchronous context (because such contexts cannot contain a 
> call to an `async` function). Furthermore, overload resolution prefers 
> `async` functions within an asynchronous context (because such 
> contexts should avoid stepping out of the asynchronous model into 
> blocking APIs).
> 
> The overload-resolution rule depends on the synchronous or 
> asynchronous context, in which the compiler selects one and only one 
> overload.

The macro relies on this existing rule and introduces no new resolution 
behavior.

### Diagnostics

If `@Reasync` is attached to a synchronous function declaration, or 
to a declaration that is not a function, the macro emits the following 
error: 

> '@Reasync' can only be applied to async functions

If `@Reasync` is attached to a function declaration that is nested 
within another `@Reasync`-attributed function, the macro emits the 
following warning at the redundant attribute: 

> Nested function declarations within an '@Reasync' function are 
> already transformed by the enclosing macro

And a fix-it is offered to remove the attribute.

If `@Reasync` is attached to a function requirement within a protocol, 
the macro emits the following error:

> '@Reasync' cannot be applied to protocol requirements

See [Protocol requirements](#protocol-requirements).

### Semantic validity

The transformation walks the syntax tree of the function declaration, 
and does not inspect or have access to the semantics of the function 
body. After macro expansion, the compiler determines whether the 
generated synchronous declaration is valid at the usual semantic 
analysis stage. If the body contains constructs that are inherently 
asynchronous, such as calls to actor-isolated methods or calls to 
`async`-only APIs, the generated overload will fail to compile, and the 
compiler will report the error at the site of the invalid expression in 
the expanded source.

This ensures at compile time that the macro cannot silently produce a 
synchronous function that diverges in meaning from the asynchronous 
source.

Because the transformation is purely syntactic, the generated 
synchronous overload is an ordinary Swift declaration: the compiler 
applies the same parsing, type-checking, and isolation-checking rules 
to the generated peer that it would apply to any other declaration in 
the source file. The macro introduces no new constructs that the 
compiler needs to recognize, and contributes no behavior at run time.

An inherent consequence of operating on the syntax tree is that the 
macro cannot enforce the discipline that a language-level `reasync` 
would. A true language feature, modeled on `rethrows`, would require 
that the function's `async` effect arise only from its closure 
parameters, and the compiler would reject any function where this is 
not the case. The macro has no comparable enforcement, since determining 
whether a given `await` corresponds to a closure parameter requires 
semantic analysis the macro cannot perform. A function that calls an 
`async`-only API independently of its parameters can therefore be marked 
`@Reasync` and expand successfully; the compile error appears afterward, 
when the generated peer is type-checked. The error will identify the 
invalid expression in the expanded source, but the macro itself cannot 
flag the misuse at the attachment site. See 
[Diagnosing misuse syntactically at the expansion site](#diagnosing-misuse-syntactically-at-the-expansion-site).

Any property of the generated peer declaration (whether it compiles, 
what diagnostics it produces, how it interacts with isolation checking, 
and so on) is fundamentally a property of the equivalent hand-written 
declaration. The macro does not introduce new edge cases or limitations 
beyond those that may already exist in synchronous Swift.

### Trivia preservation

The transformation is designed to preserve the source's formatting in 
the generated peer. Trivia attached to removed tokens is transferred to 
a nearby meaningful token rather than being discarded, so that 
whitespace, source comments, and documentation comments survive the 
transformation in their original positions.

When the source declaration is nested inside another declaration's 
body, the macro normalizes the peer's indentation to its attachment 
site so that the peer renders at the same depth as the source.

### Grammar and parsing

The macro introduces no new syntax. It is applied using the existing 
attribute syntax and requires no changes to the Swift grammar or parser.


## Source compatibility

This proposal is purely additive. It introduces a new macro declaration 
and does not modify any existing language features, standard library 
APIs, or parsing rules. Existing code continues to compile and behave 
exactly as before.

The macro name `Reasync` occupies the attribute namespace, but attribute 
names do not conflict with identifiers in other namespaces. Code that 
uses `Reasync` as a type name, function name, or variable name is 
unaffected.


## ABI compatibility

The macro has no ABI impact of its own. It expands at compile time 
to an ordinary Swift function declaration, and the ABI of each generated 
declaration is exactly that of the equivalent hand-written synchronous 
function. Existing compiled code is unaffected.


## Implications on adoption

The macro is implemented entirely at compile time via SwiftSyntax, 
and requires no runtime support.

Adopting `@Reasync` in a library is a source-compatible change for the 
library's clients, since the macro only introduces new synchronous 
overloads alongside the existing asynchronous declarations. Clients in 
asynchronous contexts continue to resolve to the original asynchronous 
declarations, and clients in synchronous contexts gain access to the 
newly-generated overloads.

Adopting `@Reasync` for a function whose hand-written synchronous 
overload previously required `@Sendable` on a closure parameter is a 
source-compatible change, since callers that previously satisfied 
`@Sendable` will continue to satisfy the now-unconstrained parameter. 
See [Strict concurrency](#strict-concurrency) for when this default 
behavior is or isn't appropriate.

Removing `@Reasync` from a declaration whose generated synchronous 
overload is in use by clients is a source-breaking change, since the 
synchronous overload is no longer generated. Library authors should 
therefore treat the synchronous overload as part of the library's public 
API once adopted, in the same way as any other API.

Neither adopting nor removing the macro affects ABI compatibility, 
since the macro expands to an ordinary function declaration at compile 
time.


## Future directions

### Protocol requirements

The `@Reasync` transformation already works syntactically on protocol 
requirements. However, the generated synchronous requirement is not 
currently handled correctly by the compiler in dispatch through 
protocol existentials, causing runtime crashes (see 
[swiftlang/swift#89397](https://github.com/swiftlang/swift/issues/89397)). 
The macro rejects this attachment site to prevent the crash. Once the 
underlying compiler issue is resolved, an amendment to this proposal 
could remove the rejection and support protocol requirements; no 
further changes to the transformation are needed.

### Subscripts

`@Reasync` could in principle support `async` subscripts, since 
subscript declarations participate in the same overload-resolution 
rules as functions. This direction is separable from the core proposal 
and could be pursued in a follow-up proposal.

### Preserving `@isolated(any)` if isolation expressivity grows

The [Strict concurrency](#strict-concurrency) section explains why the 
macro removes `@isolated(any)` from closure types appearing in the 
function's parameter clause: a function declaration's signature cannot 
currently express isolation to a derivation of a parameter's 
`.isolation` property, so the synchronous peer cannot validly call an 
`@isolated(any)` closure parameter. SE-0431 explores the idea that this 
limitation may not be permanent:

> It is currently not possible for a local function or closure to be 
> isolated to a specific value that isn't already the isolation of the 
> current context.

SE-0431 goes on to describe how value-specific isolation might interact 
with `@isolated(any)` under a future proposal such as the 
[closure isolation control pitch](https://forums.swift.org/t/closure-isolation-control/70378). 
If a comparable mechanism is later extended to function declarations, 
the macro could be revised to preserve `@isolated(any)` on closure 
parameters and generate a peer whose isolation is expressed in terms of 
one of those parameters. This would be a behavioral change for callers 
of the synchronous overload, who would gain the dynamic isolation 
contract that the asynchronous source already provides. Pursuing this 
direction is contingent on language-level support that does not yet 
exist. Until then, removing `@isolated(any)` from the peer's parameter 
clause is the only approach that produces a valid synchronous 
declaration.


## Alternatives considered

### A language-level `reasync`

The most direct alternative to this macro is a `reasync` keyword that 
mirrors `rethrows`, allowing a single function declaration to be 
synchronous or asynchronous depending on the `async`-ness of its 
closure parameters. This direction was sketched in SE-0296, and has 
been discussed periodically in the years since.

A language feature would offer an advantage that a macro cannot: a 
single symbol serving both calling contexts. If that were the only 
consideration, the language feature would be the better design. But 
several arguments favor the macro over the language feature on its 
own merits: efficiency, applicability, evolvability, and implementation.

#### Efficiency: The polymorphism gains of `reasync` are smaller than `rethrows`

The principal polymorphism benefit of `rethrows` does not transfer to 
`reasync`.`rethrows` is efficient because the ABI of throwing and 
non-throwing functions is designed to share a single entry point, so 
one compiled function serves both calling contexts. Synchronous and 
asynchronous functions, by contrast, have fundamentally different 
calling conventions. SE-0296 notes this directly:

> The ABI of throwing functions is intentionally designed to make it 
> possible for a `rethrows` function to act as a non-throwing function, 
> so a single ABI entry point suffices for both throwing and 
> non-throwing calls. The same is not true of `async` functions, which 
> have a radically different ABI that is necessarily less efficient 
> than the ABI for synchronous functions.

The Language Steering Group reiterated this point in their evaluation 
of this proposal, observing that any `reasync` implementation would 
need to emit two separate machine-level functions, mirroring what the 
proposed macro already produces at the source level.

#### Applicability: `reasync` is less broadly applicable than `rethrows`

Following `rethrows`, the `reasync` model assumes that the synchronous 
and asynchronous variants of a function should have the same 
implementation, differing only in the propagation of an effect. This 
assumption holds for many throwing APIs, but holds far less often for 
asynchronous ones. SE-0296 acknowledges this with the example of 
`Sequence.map`, where the right asynchronous implementation is not a 
sequential `await` in a loop, but a concurrent one that processes 
elements in parallel:

> For something like `Sequence.map` that might become concurrent, 
> `reasync` is likely the wrong tool: overloading for `async` closures 
> to provide a separate (concurrent) implementation is likely the 
> better answer. So, `reasync` is likely to be much less generally 
> applicable than `rethrows`.

The Language Steering Group made the same observation in their 
evaluation of this proposal:

> async code offers many more possibilities for semantic distinctions 
> between synchronous and async variations of a function, such as 
> different interactions with isolation and sendability, or different 
> parallel execution strategies that aren't readily available in 
> synchronous code, so it isn't as clear-cut that there is a 
> one-size-fits-most solution like `rethrows` for async.

The recommendation in SE-0296 for cases like this is to write two 
declarations: a synchronous one and an asynchronous one with a tuned 
implementation. This is the pattern the proposed macro produces. The 
macro handles the common case where the two implementations would be 
identical apart from `async`, `await`, and the annotations that depend 
on them.

#### Evolvability: The macro affords easier evolution at both layers

A function annotated with `@Reasync` can later be replaced by a 
hand-written synchronous overload without affecting source compatibility 
or ABI. The Language Steering Group identified this as a specific 
advantage of the macro:

> Being a macro, developers could even evolve their code by removing the 
> macro and switching to a separately-written synchronous variant if 
> necessary, without disturbing API or ABI, which would not necessarily 
> be possible starting from a single `reasync` declaration.

A language-level `reasync` declaration, by contrast, would bind the 
synchronous and asynchronous forms of a function together at the 
language level. Splitting them later would be a source-breaking change 
for clients that have come to depend on the two overloads being a 
single symbol.

The Language Steering Group also noted that the macro form is more 
amenable to incremental development:

> A macro potentially offers more flexibility to evolve in response to 
> unanticipated needs.

A macro is a library-level artifact. Its behavior can be refined, its 
diagnostics improved, and new variants introduced over time without 
amending the language. A language feature, by contrast, becomes part of 
Swift's stable surface and is correspondingly difficult to revise after 
introduction.

#### Implementation: `reasync` would also be implemented with a macro-like mechanism

The same calling-convention asymmetry that limits the polymorphism 
gains of a language-level `reasync` also shapes how such a feature 
would necessarily be implemented. The Language Steering Group described 
this in their evaluation of this proposal:

> Even if we pursued a more integrated `reasync` type system solution 
> in the style of `rethrows`, it would need to have a macro-like 
> underlying implementation, generating two separate machine-level 
> functions, since synchronous and async functions cannot share a 
> calling convention.

Since the duplication exists either way, the question reduces to where 
the feature is implemented. The macro places it at the source level, 
where the generated peer is an ordinary Swift declaration subject to 
the compiler's standard parsing, type-checking, and isolation-checking 
rules. A language feature would place the same duplication inside the 
compiler. The source-level placement carries no efficiency penalty, and 
gains the diagnostic and evolvability properties described in the 
preceding subsections.

The macro is therefore not a stopgap pending a language-level `reasync`. 
It is the preferred approach to the problem on the basis of efficiency, 
applicability, evolvability, and implementation. A future `reasync` 
proposal remains possible, but its acceptance is not a prerequisite for 
solving the common case the macro addresses, and the macro's design 
choices would remain defensible even alongside such a feature.

### Naming

This proposal suggests the name `@Reasync` for the following reasons:

1. "reasync" is the name that many Swift developers have reached for 
when discussing this feature over the years.

2. The feature occupies the same mental slot as `rethrows`: a way for a 
function's effect to be conditional on its closure parameters. The 
macro's mechanism differs (it removes `async` rather than conditionally 
reintroducing it), but the name does not describe the mechanism; it 
describes the user-facing outcome: just as `rethrows` describes a 
function that exists in both throwing and non-throwing forms, "reasync" 
describes a function that exists in both synchronous and asynchronous 
forms.

3. Attached macros within the standard library and third-party 
libraries consistently use title-case names (for example, Swift 
Testing's `@Test` and `@Suite`, and 
[pointfreeco/swift-composable-architecture](https://github.com/pointfreeco/swift-composable-architecture/blob/main/Sources/ComposableArchitecture/Macros.swift)'s 
`@Reducer`, `@ObservableState`, `@Presents`, and `@ViewAction`). 
Lowercase attributes such as `@available` and `@inlinable` are reserved 
for language-level features and follow a different convention.

"reasync" has appeared in many community discussions over the years:

<details>
<summary>Community discussions and proposals using "reasync"</summary>

| Post                                                                                                                                                                                                                 | Date           |
|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------|
| [Pondering about a future with async/await](https://forums.swift.org/t/pondering-about-a-future-with-async-await/16541)                                                                                              | September 2018 |
| [SE-0296: Async/await](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0296-async-await.md#reasync)                                                                                                 | December 2020  |
| [[Pitch #2] Structured Concurrency](https://forums.swift.org/t/pitch-2-structured-concurrency/43452/116)                                                                                                             | January 2021   |
| [Pitch: Fix rethrows checking and add rethrows(unsafe)](https://forums.swift.org/t/pitch-fix-rethrows-checking-and-add-rethrows-unsafe/44863/5)                                                                      | February 2021  |
| [Exploration: Type System Considerations for Actor Proposal](https://forums.swift.org/t/exploration-type-system-considerations-for-actor-proposal/44540/9)                                                           | February 2021  |
| [Pitch #6 Actors](https://forums.swift.org/t/pitch-6-actors/45519/32)                                                                                                                                                | March 2021     |
| [Request to amend `AsyncSequence`](https://forums.swift.org/t/request-to-amend-asyncsequence/50163/16)                                                                                                               | July 2021      |
| [SE-0338: Clarify the Execution of Non-Actor-Isolated Async Functions](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md#explicit-inheritance-of-executors) | January 2022   |
| [Swift project focus areas in 2023](https://forums.swift.org/t/swift-project-focus-areas-in-2023/61522/7)                                                                                                            | November 2022  |
| [The latest information on `reasync`?](https://forums.swift.org/t/the-latest-information-on-reasync/61801)                                                                                                           | December 2022  |
| [A case study for `reasync`](https://forums.swift.org/t/a-case-study-for-reasync/64590)                                                                                                                              | April 2023     |
| [SE-0395: Observability](https://forums.swift.org/t/se-0395-observability/64342/34)                                                                                                                                  | April 2023     |
| [Algebraic Effects](https://forums.swift.org/t/algebraic-effects/38769/22)                                                                                                                                           | June 2023      |
| [New function colour: unsafe](https://forums.swift.org/t/new-function-colour-unsafe/65408/64)                                                                                                                        | June 2023      |
| [[GSoc 2024] Improving keyword completion in SwiftSyntax](https://forums.swift.org/t/gsoc-2024-improving-keyword-completion-in-swiftsyntax-initial-approach-discussion/70432/3)                                      | March 2024     |
| [SE-0443: Precise Control Flags over Compiler Warnings](https://forums.swift.org/t/se-0443-precise-control-flags-over-compiler-warnings/74116/26)                                                                    | August 2024    |
| [How to avoid cascading async functions?](https://forums.swift.org/t/how-to-avoid-cascading-async-functions/74494/18)                                                                                                | September 2024 |
| [Async/Await: is it possible to start a Task on @MainActor synchronously?](https://forums.swift.org/t/async-await-is-it-possible-to-start-a-task-on-mainactor-synchronously/52862/24)                                | December 2024  |
| [Blocking await!](https://forums.swift.org/t/blocking-await/80431/7)                                                                                                                                                 | June 2025      |
| [`Borrow` and `Inout` types for safe, first-class references](https://forums.swift.org/t/borrow-and-inout-types-for-safe-first-class-references/84490/37)                                                            | February 2026  |

</details>
<br/>

Alternative names for this feature have been suggested, and include 
the following:

- `@reasync`: The lowercase version of the proposed name.
- `@duplicate`: Generalizes to a family of transformations beyond 
`async`. See [A generalized duplication macro](#a-generalized-duplication-macro).
- `@deasync`/`@DeAsync`: Emphasizes that the macro removes `async`, 
rather than reintroducing it from closure parameters. See 
[A parameterized type-replacement macro](#a-parameterized-type-replacement-macro).
- `@ConditionallyAsync`: Describes the resulting overload set rather 
than the transformation.

### A generalized duplication macro

Community feedback in the pitch thread suggested generalizing the macro 
into an `@duplicate(remove: [...])` form that could strip arbitrary 
syntactic features beyond `async`, such as `throws`, `@Sendable`, 
escapability, or generic parameters. Under this design, `@Reasync` 
would be one preset of a more general transformation, and library 
authors could compose their own duplications by selecting which 
annotations to remove.

This proposal does not pursue that direction. The `async`/`await` 
transformation works because `async` and `await` are purely annotational 
over a function body that does not depend on inherently-asynchronous 
APIs. When those tokens are removed, the resulting function is 
semantically equivalent to a hand-written synchronous version, by 
construction. The macro can guarantee this property because the 
transformation is well-defined.

Most other function-signature modifications do not share this property: 

- Removing `throws` from a function signature is not mechanical, since 
there's no well-defined answer for what happens to the `throw` 
statements.

- Removing generic parameters or changing parameter types 
produces a different function, not a duplicate of the original.

- Removing `@Sendable` has different implications depending on whether 
the macro also eliminates the parallel execution that motivated the 
annotation in the first place. This question, and the decision to 
handle it with a fixed default rather than a configurable parameter, 
are addressed in [Strict concurrency](#strict-concurrency) and 
[A parameterized type-replacement macro](#a-parameterized-type-replacement-macro).

Each of these transformations carries its own semantic concerns that a 
single generalized macro would either have to encode separately, or 
leave to the user to navigate.

A general-purpose duplication macro could plausibly exist, but each 
transformation it supports would need its own design rationale and its 
own discussion of when the result remains semantically equivalent to 
the source. Combining them under one attribute would not preserve that 
distinction. This proposal addresses the specific, common, mechanical 
case of `async`-to-sync duplication with semantics that can be stated 
precisely. A broader design is better pursued in a separate proposal 
where each supported transformation can be argued on its own merits.

### A parameterized type-replacement macro

An [example of this direction](https://github.com/Uncommon/Rundown) was 
raised in the pitch thread. The exemplified `@DeAsync` macro extends 
the `async`-to-sync transformation with additional parameters that 
replace types in the function signature. The exemplified macro accepts 
arrays of source and replacement types, allowing call-site type aliases 
and callback signatures to be substituted during expansion.

This proposal does not pursue that direction. The `@Reasync` macro 
generates an overload of the source function: a peer with the same 
name, generic signature, and parameter list. Replacing types in the 
signature produces a function that is no longer an overload of the 
source, but a separate function with a related shape. A peer macro that 
generates a non-overload is a different conceptual operation from one 
that generates an overload.

The `stripSendable` parameter of the exemplified macro raises a 
separate question about how the generated synchronous overload 
should interact with strict concurrency. That question is addressed 
in [Strict concurrency](#strict-concurrency), where the macro takes 
a fixed default rather than a configurable one.

A fixed default fits this proposal's intent. The macro's value 
comes from being a single, mechanical decision: a function is either 
a candidate for `@Reasync` or it is not. Per-annotation configuration 
would shift that decision from the macro's design into each adoption 
site, transferring the question of whether the generated peer is 
correct from the macro's authors to the macro's users. The user would 
gain control, but would also gain responsibility for verifying the 
result against strict concurrency on a case-by-case basis, which is the 
same responsibility they would have when hand-writing the overload, but 
now with the additional indirection of a macro expansion.

When the macro is the wrong tool, the preferred approach is to write 
the synchronous overload by hand. This applies whether the generated 
peer would not actually be an overload of the source, or the macro's 
defaults are wrong for a particular function. The type system checks 
the hand-written work directly, and the reasoning that justifies the 
hand-written overload lives in the source alongside it. A configurable 
or type-replacing macro would require the same per-function reasoning, 
distributed across annotations at each adoption site and resolved at 
expansion time rather than in the source.

### Generating `async` overloads from synchronous sources

The proposed macro generates a synchronous overload from an asynchronous 
source, but not the reverse. A symmetric macro could in principle 
generate an asynchronous overload from a synchronous source by 
inserting `async` and `await` keywords. An 
[example of this direction](https://github.com/floormatgen/stdlib-utils) 
was raised in the pitch thread.

This proposal does not pursue that direction. Two considerations favor 
the `async`-to-sync direction: it is the wider context, and the 
syntactic transformation is reliable in only one direction.

#### `async` is the wider context

A synchronous function can be called from an asynchronous context, but 
an asynchronous function cannot be called from a synchronous context. 
The asynchronous form carries strictly more information than the 
synchronous form: it identifies the points at which suspension may 
occur. Removing `async` and `await` discards information that was 
already present, producing a more constrained version of the same 
function, while inserting `async` and `await` requires the macro to 
introduce information that the source did not contain. The 
`async`-to-sync direction is lossless, while the sync-to-`async` 
direction is generative.

#### The syntactic transformation is reliable in only one direction

A synchronous function body does not generally identify which calls 
should become asynchronous. A purely syntactic macro cannot determine 
where to insert `await` without semantic information about which 
expressions resolve to `async` functions. Without that information, the 
macro must either insert `await` indiscriminately (producing invalid 
code) or rely on the user to mark the relevant call sites explicitly 
(transferring the work back to the user that the macro was supposed to 
save).

A future proposal could explore sync-to-`async` duplication. Its 
design space is shaped by the asymmetry between the two directions and 
warrants separate consideration.

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

### A member-iterating companion macro

A companion macro applied to a type or extension could generate 
synchronous overloads for every `async` member declaration in one 
annotation, rather than requiring `@Reasync` on each member 
individually. The transformation itself would be unchanged; only the 
iteration surface would be new. This direction was raised during the 
pitch and is separable from the core proposal. This proposal does not 
pursue it.

An implementation of this direction is available as `@ReasyncMembers` at 
[swift-reasync](https://github.com/swift-developer-tools/swift-reasync/tree/main).

### Keeping the macro as a third-party package

The macro is currently published as a third-party package, 
[swift-reasync](https://github.com/swift-developer-tools/swift-reasync/tree/main). 
Leaving it there indefinitely is one possible outcome.

The case against this outcome is that the problem this macro solves is 
common across Swift libraries that support both synchronous and 
asynchronous calling contexts. Leaving the solution in a third-party 
package means that each library that adopts such a macro either takes on 
a dependency on one particular package, or duplicates the 
implementation. In the latter case, the Swift ecosystem ends up with 
multiple incompatible implementations of the same transformation, with 
inconsistent naming, semantics, and diagnostics. Either outcome 
fragments the solution.

Promoting the macro to a canonical location, either within the Swift 
standard library or as an official package in the `swiftlang` GitHub 
organization, avoids this fragmentation and signals that this macro is 
the recommended solution to the problem.

### A `sed` script or code generator

An [example of this direction](https://forums.swift.org/t/a-case-study-for-reasync/64590) 
was shared on the Swift Forums, noting that the transformation can be 
accomplished with a `sed` script that rewrites an asynchronous source 
file into a synchronous one at build time.

This approach works, but has significant drawbacks compared to a macro:

- It operates on text rather than a syntax tree, and cannot distinguish 
`async` as a keyword from `async` appearing in an identifier or comment.
- It requires a build step external to the Swift compiler, and is not 
portable across platforms.
- It produces a separate source file that must be committed or 
regenerated, rather than a compile-time expansion.
- It cannot emit diagnostics on invalid or problematic code.

A macro-based solution addresses all of these concerns by operating 
on the Swift AST and integrating with the compiler's existing expansion 
and diagnostic infrastructure.

### Preserving `@Reasync` on the generated peer

The peer macro could in principle leave `@Reasync` on the generated 
synchronous declaration. This would have the advantage of making the 
relationship between the source declaration and generated declaration 
visible in the expanded code.

This proposal removes `@Reasync` from the peer. The macro would 
otherwise re-trigger on the generated declaration, producing infinite 
expansion, or require special-case handling in the macro expansion 
logic to suppress re-triggering. Removing the attribute is the simpler 
and more robust choice, and the relationship between the source 
declaration and generated declaration remains evident from the expansion 
itself.


## Revision history

The following changes were made to this proposal after the pitch 
discussion, in response to feedback from the Language Steering Group:

- Added an extended discussion of language-level `reasync` as a true 
alternative, with arguments for why this proposal favors the macro 
approach.
- Added discussion of alternative macro implementations raised in the 
pitch thread.
- Added a "Strict concurrency" section covering the macro's handling 
of `@Sendable`, `@isolated(any)`, `nonisolated(nonsending)`, 
`@concurrent`, and `sending`.
- Gathered the naming alternatives raised in the pitch thread into the 
"Alternatives considered" section.
- Updated the proposal title to be more descriptive of what the macro 
does.
- Separated `@ReasyncMembers` from the proposal.

The implementation was also extended as follows:

- The macro now implements handling of the concurrency-related 
annotations covered by strict concurrency.
- The macro now recursively transforms nested function declarations, 
closure expressions, and accessors of local computed properties within 
the annotated function.
- The macro now refuses to expand on protocol function requirements and 
emits a diagnostic at the attachment site.
- The macro now normalizes indentation when attached to functions 
nested inside another declaration's body, so that the generated peer is 
indented to its attachment site.
- Trivia preservation was expanded and refined.
- The test suite was expanded substantially, with tests running under 
the `NonisolatedNonsendingByDefault` upcoming feature in Swift 6 
language mode and under thread, undefined-behavior, and address 
sanitizers.


## Cited proposals

- [SE-0296: Async/await](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0296-async-await.md)
- [SE-0430: `sending` parameter and result values](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md)
- [SE-0431: `@isolated(any)` Function Types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0431-isolated-any-functions.md)
- [SE-0461: Run nonisolated async functions on the caller's actor by default](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)


## Acknowledgments

Thank you to ZPedro for the Swift Forum thread 
[A case study for `reasync`](https://forums.swift.org/t/a-case-study-for-reasync/64590), 
Doug Gregor for the observation in that thread that a peer macro could 
plausibly cover the common case, and Konrad Malawski for encouraging 
this proposal.
