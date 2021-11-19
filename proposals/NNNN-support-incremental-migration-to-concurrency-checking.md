# Support incremental migration to concurrency checking

* Proposal: [SE-NNNN](NNNN-support-incremental-migration-to-concurrency-checking.md)
* Authors: [Doug Gregor](https://github.com/DougGregor), [Becca Royal-Gordon](https://github.com/beccadax)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

[SE-0302](https://github.com/apple/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md) introduced the `Sendable` protocol, which is used to indicate which types have values that can safely be copied across task boundaries or, more generally, into any context where a copy of the value might be used concurrently with the original. However, Swift 5.5 does not fully enforce `Sendable` because interacting with modules which have not been updated for Swift Concurrency would be painful. We propose adding features to help developers migrate their code to support `Sendable` checking and interoperate with other modules that have not yet adopted it.

Swift-evolution threads: [[Pitch] Staging in `Sendable` checking](https://forums.swift.org/t/pitch-staging-in-sendable-checking/51341), [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

Swift Concurrency seeks provide a mechanism for isolating state in concurrent programs to eliminate data  That mechanism is `Sendable` checking. APIs which send data across task boundaries require their inputs to conform to the `Sendable` protocol; types which are safe to send declare conformance, and the compiler checks that these types only contain `Sendable` types, unless the type's author explicitly indicates that the type is implemented so that it uses any un-`Sendable` contents safely.

This would all be well and good if we were writing Swift 1, a brand-new language which did not need to interoperate with any existing code. Unfortunately, we are instead writing Swift 6, a new version of an existing language with millions of lines of existing libraries and deep interoperation with C, Objective-C, and hopefully soon C++ headers. None of this code specifies any of its concurrency behavior in a way that `Sendable` checking can understand, but until it can be updated, we still want to use it from Swift 6 code.

There are several areas where we wish to address adoption difficulties.

### Adding retroactive concurrency annotations to libraries

Many existing APIs should be updated to formally specify specify concurrency behavior that they have always followed, but have not been able to describe to the compiler until now. For instance, it has always been the case that most UIKit methods and properties should only be used on the main thread, but before the `@MainActor` attribute, this behavior could only be documented and asserted in the implementation, not described to the compiler.

Thus, many modules should undertake a comprehensive audit of their APIs to decide where to add concurrency annotations. But if they try to do so with the tools they currently have, this will surely cause source breaks. For instance, if a method is marked `@MainActor`, projects which have not yet adopted Swift Concurrency will be unable to call it even if they are using it correctly, because the project does not yet have the annotations to *prove to the compiler* that the call will run in the main actor.

In some cases, these changes can even cause ABI breaks. For instance, `@Sendable` attributes on function types and `Sendable` constraints on generic parameters are incorporated into mangled function names, even though `Sendable` conformances otherwise have no impact on the calling convention (there isn't an extra witness table parameter, for instance). A mechanism is needed to enforce these constraints during typechecking, but generate code as though they do not exist.

Here, we need:

* A formal specification of a "compatibility mode" for pre-concurrency code which imports post-concurrency modules

* A way to mark declarations as needing special treatment in this "compatibility mode" because their signatures were changed for concurrency

### Adopting `Sendable` checking before the modules you use have been updated

The process of auditing libraries to add concurrency annotations will take a long time. We don't think it's realistic for each module to wait until all of its libraries have been updated before they can start adopting `Sendable` checking.

This means modules need a way to work around incomplete annotations in their imports--either by tweaking the specifications of imported declarations, or by telling the compiler to ignore errors. Whatever mechanism we use, we don't want it to be too verbose, though; for example, marking every single variable of a non-`Sendable` type which we want to treat as `Sendable` would be pretty painful.

We must also pay special attention to what happens when the library finally *does* add its concurrency annotations, and they reveal that a client has made a mistaken assumption about its concurrency behavior. For instance, suppose you import type `Point` from module `Geometry`. You enable `Sendable` checking before `Geometry`'s maintainers have added concurrency annotations, so it diagnoses a call that sends a `Point` to a different actor. Based on the publicly-known information about `Point`, you decide that this type is probably `Sendable`, so you silence this diagnostic. However, `Geometry`'s maintainers later examine the implementation of `Point` and determine that it is *not* safe to send, so they mark it as non-`Sendable`. What should happen when you get the updated version of `Geometry` and rebuild your project?

Ideally, Swift should not continue to suppress the diagnostic about this bug. After all, the `Geometry` team has now marked the type as non-`Sendable`, and that is more definitive than your guess that it would be `Sendable`. On the other hand, it probably shouldn't *prevent* you from rebuilding your project either, because this bug is not a regression. The updated `Geometry` module did not add a bug to your code; your code was already buggy. It merely *revealed* that your code was buggy. That's an improvement on the status quo--a diagnosed bug is better than a hidden one.

But if Swift reacts to this bug's discovery by preventing you from building a module that built fine yesterday, you might have to put off updating the `Geometry` module or even pressure `Geometry`'s maintainers to delay their update until you can fix it, slowing forward progress. So when your module assumes something about an imported declaration that is later proven to be incorrect, Swift should emit a *warning*, not an error, about the bug, so that you know about the bug but do not have to correct it just to make your project build again.

Here, we need:

* A mechanism to silence diagnostics about missing concurrency annotations related to a particular declaration or module

* Rules which cause those diagnostics to return once concurrency annotations have been added, but only as warnings, not errors

### Adding `Sendable` conformances from Objective-C

[SE-0297](https://github.com/apple/swift-evolution/blob/main/proposals/0297-concurrency-objc.md)'s `__attribute__((swift_attr))` makes it possible to declare many Swift concurrency behaviors in Objective-C headers[1], and  [SE-0302](https://github.com/apple/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md#support-for-imported-c--objective-c-apis) specifies structural inference rules for `Sendable` conformances. However, neither proposal allows you to declare whether there should or shouldn't be a `Sendable` *conformance*, so there is no way to override SE-0302's rules when the semantic behavior doesn't match the behavior implied by the structural inference rules.

For instance, a struct containing an `int` would be inferred to be `Sendable` because integers can generally be safely copied, but if that `int` is really a file descriptor, you would only want the struct to be `Sendable` if the APIs used that that file descriptor in a thread-safe way. Contrariwise, Objective-C classes can contain shared mutable state so they should not be `Sendable` by default, but if a specific class is known to be synchronized or truly immutable, it should be possible to make it `Sendable`. In both cases, we should be able to override the default behavior and specify the sendability of the type.

Here, we need:

* A way to add a `Sendable` conformance--whether available or [explicitly unavailable](https://github.com/DougGregor/swift-evolution/blob/sendable-inference/proposals/nnnn-sendable-inference.md#introduce-a-syntax-to-specify-explicitly-that-a-type-is-non-sendable)--to imported types

> [1] SE-0297 alone allows you to specify:
>
> * `swift_attr("@MainActor")` on declarations and block types.
> * `swift_attr("nonisolated")` on declarations.
> * `swift_attr("@Sendable")` on block types, Objective-C method declarations, and C function declarations.

## Proposed solution

We propose a suite of features to aid in the adoption of concurrency annotations and `Sendable` checking. These features are designed to enable the following workflow for adopting `Sendable` checking:

1. Enable Swift 6 mode or the `-warn-concurrency` flag. This causes new errors or warnings to appear when `Sendable` constraints are violated.

2. Start solving those errors. If they relate to types from another module, a fix-it will suggest using `@predatesConcurrency import`; do that to silence those warnings.

3. Once you've solved these errors, integrate your changes into the larger build.

4. At some future point, a module you import may be updated to add `Sendable` conformances and other concurrency annotations. If it is, and your code violates `Sendable` constraints, you will see warnings telling you about these mistakes; these are latent concurrency bugs in your code. Correct them.

5. Once you've fixed those bugs, or if there aren't any, you will see a warning telling you that the `@predatesConcurrency import` is unnecessary. Remove the `@predatesConcurrency` attribute. Any `Sendable`-checking failures involving that module from that point forward will not suggest using `@predatesConcurrency import` and, in Swift 6 mode, will be errors that prevent your project from building.

Achieving this will require several features working in tandem:

* In Swift 6 mode, all code will be checked for missing `Sendable` conformances and other concurrency violations, with mistakes generally diagnosed as errors. The `-warn-concurrency` flag will diagnose these violations as warnings in older language versions.

* When applied to a nominal declaration, the `@predatesConcurrency` attribute specifies that a declaration was modified to update it for concurrency checking, so the compiler should allow some uses in Swift 5 mode that violate `Sendable` checking, and generate code that interoperates with pre-concurrency binaries.

* When applied to an `import` statement, the `@predatesConcurrency` attribute tells the compiler that it should only diagnose `Sendable`-requiring uses of non-`Sendable` types from that module if the type explicitly declares a `Sendable` conformance that is unavailable or has constraints that are not satisifed; even then, this will only be a warning, not an error.

* For Objective-C libraries, `__attribute__((swift_attr()))` will be extended to allow you to specify which types should be `Sendable`, including blanket non-`Sendable` for regions of your headers that you have finished auditing.

## Detailed design

### Recovery behavior

When this proposal speaks of an error being emitted as a warning or suppressed, it means that the compiler will recover by behaving as though (in order of preference):

* A nominal type that does not conform to `Sendable` does.

* A function type with an `@Sendable` or global actor attribute doesn't have it.

### Concurrency checking modes

Every scope in Swift can be described as having one of three "concurrency checking modes":

* **Full concurrency checking**: Missing `Sendable` conformances are diagnosed as errors.

* **Strict concurrency checking**: Missing `Sendable` conformances are diagnosed as warnings.

* **Minimal concurrency checking**: Missing `Sendable` conformances are diagnosed as warnings; on nominal declarations, `@predatesConcurrency` (defined below) has special effects in this mode which suppress many diagnostics.

The top level scope's concurrency checking mode is:

* **Full** when the module is being compiled in Swift 6 mode or later.

* **Strict** when the module is being compiled in a language version mode before Swift 6, but the `-warn-concurrency` flag is used, or when the file being parsed is a module interface.

* **Minimal** otherwise.

A child scope's concurrency checking mode is:

* **Strict** if the parent's concurrency checking mode is **Minimal** and any of the following conditions is true of the child scope:

  * It is a closure with an explicit `@actorIndependent` or global actor attribute.

  * It is a closure or autoclosure whose type is `async` or `@Sendable`. (Note that the fact that the parent scope is in Minimal mode may affect whether the closure's type is inferred to be `@Sendable`.)

  * It is a declaration with an explicit `@actorIndependent`, `nonisolated`, or global actor attribute.

  * It is a function, method, initializer, accessor, variable, or subscript which is marked `async` or `@Sendable`.

  * It is an `actor` declaration.

* Otherwise, the same as the parent scope's.

> Implementation note: The logic for determining whether a child scope is in Minimal or Strict mode is currently implemented in `swift::contextUsesConcurrencyFeatures()`.

Imported Objective-C declarations belong to a scope with Minimal concurrency checking.

### `@predatesConcurrency` attribute on nominal declarations

To describe their concurrency behavior, maintainers must change some existing declarations in ways which, by themselves, could be source-breaking in pre-concurrency code or ABI-breaking when interoperating with previously-compiled binaries. In particular, they may need to:

* Add `@Sendable` or global actor attributes to function types
* Add `Sendable` constraints to generic signatures
* Add global actor attributes to declarations

When applied to a nominal declaration, the `@predatesConcurrency` attribute indicates that a declaration existed before the module it belongs to fully adopted concurrency, so the compiler should take steps to avoid these source and ABI breaks. It can be applied to any `enum`, enum `case`, `struct`, `class`, `actor`, `protocol`, `associatedtype`, `var`, `let`, `subscript`, `init`, `func`, accessor, or `deinit` declaration. It can also be applied to an extension, in which case it will be applied to all declarations of those kinds in the extension.

[Maybe you should be allowed to apply it to `typealias`, where it would mean that any declaration that used that typealias in its signature would need to have `@predatesConcurrency`. That way, if you changed a typealias for `(T) -> U` into `@Sendable (T) -> U`, you could add `@predatesConcurrency` to the typealias to ensure that the APIs using that typealias were all updated.]

When a nominal declaration uses `@predatesConcurrency`:

* Its name is mangled as though it does not use any of the listed features.

* At use sites whose enclosing scope uses Minimal concurrency checking, the compiler will suppress any diagnostics about mismatches in these traits.

* The ABI checker will remove any use of these features when it produces its digests.

Objective-C declarations are always imported as though they were annotated with `@predatesConcurrency`.

### `Sendable` conformance status

A type can be described as having one of the following three `Sendable` conformance statuses:

* **Explicitly `Sendable`** if it actually conforms to `Sendable`.

* **Explicitly non-`Sendable`** if a `Sendable` conformance has been declared for the type, but it is not available or has constraints the type does not satisfy, *or* if the type was declared in a scope that uses Full or Strict concurrency checking.[2]

* **Implicitly non-`Sendable`** if no `Sendable` conformance has been declared on this type at all.

> [2] This means that, if a module is compiled with Swift 6 mode or the `-warn-concurrency` flag, all of its types are either explicitly `Sendable` or explicitly non-`Sendable`.

### `@predatesConcurrency` attribute on `import` declarations

The `@predatesConcurrency` attribute can be applied to an `import` statement to indicate that the compiler should reduce the strength of some concurrency-checking violations caused by types imported from that module. You can use it to import a module which has not yet been updated with concurrency annotations; if you do, the compiler will tell you when all of the types you need to be `Sendable` have been annotated. It also serves as a temporary escape hatch to keep your project compiling until any mistaken assumptions you had about that module are fixed.

When an import is marked `@predatesConcurrency`, the following rules are in effect:

* If an implicitly non-`Sendable` type is used where a `Sendable` type is needed:

  * If the type is visible through an `@predatesConcurrency import`, no diagnostic is emitted.
  
  * Otherwise, the diagnostic is emitted normally, but a note is attached recommending that `@predatesConcurrency import` be used to work around the issue.

* If an explicitly non-`Sendable` type is used where a `Sendable` type is needed:

  * If the type is visible through an `@predatesConcurrency import`, a warning is emitted instead of an error, even in Full concurrency checking mode.

  * Otherwise, the diagnostic is emitted normally.

* If the `@predatesConcurrency` attribute is unused[3], a warning will be emitted recommending that it be removed.

> [3] We don't define "unused" more specifically because we aren't sure if we can refine it enough to, for instance, recommend removing one of a pair of `@predatesConcurrency` imports which both import an affected type.

### Customizing the `Sendable` behavior of Objective-C declarations

#### `swift_attr("@Sendable")`

Swift will extend `swift_attr("@Sendable")` to allow it to be applied to Objective-C interfaces and protocols, C record types (structs and unions), and C enum types. If an `@Sendable` attribute is present on such a type, Swift will synthesize an unconditional, fully available `Sendable` conformance.

Swift will implicitly add `swift_attr("@Sendable")` to:

* The block type of the completion handler parameter of a method which is imported as `async`. (That is, if Swift infers an imported method to be `async`, it will also modify the completion handler of the *non*-`async` version of the method to be `@Sendable`.)

* Declarations for types marked with the following attributes:
  * `enum_extensibility` (`NS_ENUM`)
  * `ns_error_domain` (`NS_ERROR`)
  * `flag_enum` (`NS_OPTIONS`)
  * `swift_wrapper` (`NS_TYPED_ENUM`)

> **Warning**: Marking `swift_wrapper` types as `Sendable` creates a small hole in `Sendable` checking because, if you returned an `NSMutableString` from a Swift API that was imported as the `swift_wrapper` type and later mutated it, this mutation would be visible from another thread. However, this is a serious misuse of `swift_wrapper` types even in non-concurrent scenarios.

#### `swift_attr("@_nonSendable")`

ClangImporter will also add `swift_attr("@_nonSendable")`, which can be applied to anything that allows `swift_attr("@Sendable")`, including the type declarations mentioned above. When applied to a type declaration, it indicates that Swift should synthesize an explicitly unavailable `Sendable` conformance for that declaration.

This attribute can also be specified as `swift_attr("@_nonSendable(_assumed)")`. The two variants differ in how they behave when `swift_attr("@Sendable")` has also been applied to the same declaration or type:

* `swift_attr("@_nonSendable")` causes any `@Sendable` attribute on the same declaration or type to be ignored.

* `swift_attr("@_nonSendable(_assumed)")` is ignored if there is a `@Sendable` attribute on the same declaration or type.

That creates the following set of rules:

1. If the type inherits `Sendable` from a superclass, it has a `@MainActor` attribute, or its superclass has a `@MainActor` attribute, it is explicitly `Sendable`.

1. If `swift_attr("@_nonSendable")` is present, the type is explicitly non-`Sendable`.

2. If `swift_attr("@Sendable")` is present (including if it's added because of `enum_extensibility` or one of the other attributes mentioned above), the type is explicitly `Sendable`.

3. If `swift_attr("@_nonSendable(_audited)")` is present, the type is explicitly non-`Sendable`.

4. If the type meets one of the [`Sendable` Objective-C type criteria described in SE-0302](https://github.com/apple/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md#support-for-imported-c--objective-c-apis), it is explicitly `Sendable`.

5. Otherwise, the type is implicitly non-`Sendable`.

#### Feature detection

`__has_attribute(swift_attr)` is not sufficient for a header file to check if the `swift_attr("@Sendable")` changes and new `swift_attr("@_nonSendable")` attribute are supported by the Swift compiler importing it. To help with this, ClangImporter will define the `__SWIFT_ATTR_SUPPORTS_SENDABLE_DECLS` macro to be `1` or greater when these features are supported.

#### Region-based auditing

> **Note**: In the past, Foundation has provided macros with an `NS_` prefix for working more easily with ClangImporter features. However, Foundation is not part of the Swift Evolution process, so adding macros for these new features is out of scope for an Evolution proposal.

`swift_attr` will be updated to allow it to be used with [the `clang attribute` pragma](https://clang.llvm.org/docs/LanguageExtensions.html#specifying-an-attribute-for-multiple-declarations-pragma-clang-attribute). With this change, it will be possible to define macros to do region-based `Sendable` auditing (i.e. a pair of `MY_ASSUME_UNSENDABLE_BEGIN`/`_END` macros).

Here's a full set of macros as a sample:

```objc
#ifdef __SWIFT_ATTR_SUPPORTS_SENDABLE_DECLS

#define MY_SENDABLE __attribute__((swift_attr("@Sendable")))
#define MY_UNSENDABLE __attribute__((swift_attr("@_nonSendable")))
#define MY_MAIN_ACTOR __attribute__((swift_attr("@MainActor")))
#define MY_NONISOLATED __attribute__((swift_attr("nonisolated")))

#define MY_ASSUME_UNSENDABLE_BEGIN _Pragma("clang attribute MY_ASSUME_UNSENDABLE.push __attribute__((swift_attr(\"@_nonSendable(_assumed)\"))), defined_in = any(objc_interface, record, enum, function, objc_method)")
#define MY_ASSUME_UNSENDABLE_END _Pragma("clang attribute MY_ASSUME_UNSENDABLE.pop")

#else

#define MY_SENDABLE
#define MY_UNSENDABLE
#define MY_MAIN_ACTOR
#define MY_NONISOLATED

#define MY_ASSUME_UNSENDABLE_BEGIN
#define MY_ASSUME_UNSENDABLE_END

#endif
```

And an example of how they might be used:

```objc
// This struct would normally be inferred as Sendable because the imported types
// of its fields are all Sendable, but we know that `fd` is a file descriptor
// and `MyDatabaseHandle` does not attempt to synchronize its use across
// multiple clients, so using the same handle in several tasks would not be
// safe.
MY_UNSENDABLE struct MyDatabaseHandle {
  int fd;
};

// If that struct were below this line, we would also import it as explicitly
// non-Sendable.
MY_ASSUME_UNSENDABLE_BEGIN

// Outside of an ASSUME_UNSENDABLE block, this struct would be inferred to be
// Sendable, but ASSUME_UNSENDABLE takes priority over that.
MY_SENDABLE struct MyPoint {
  double x;
  double y;
};

// This class would normally be inferred as non-Sendable, but we happen to know
// that it, all of its subclasses, and all objects accessible through it are
// truly immutable and can be used by multiple tasks simultaneously.
MY_SENDABLE @interface MyRecord : NSObject

@property (readonly) NSInteger recordID;
@property (readonly,copy) NSString *name;

// This method should only be called on the main actor.
- (void)validateOrPresentErrorUsingResponder:(NSResponder*)responder MY_MAIN_ACTOR;

@end

// The first closure is run on an unspecified background task; the second is on
// the main actor.
void runInBackgroundAndThenOnMainActor(
  MY_SENDABLE void (^backgroundFn)(),
  MY_MAIN_ACTOR void (^mainActorFn)()
);

MY_ASSUME_UNSENDABLE_END
```

## Source compatibility

This proposal is largely motivated by source compatibility concerns. Correct use of `@predatesConcurrency` should prevent source breaks in code built with Minimal concurrency checking, and `@predatesConcurrency import` temporarily weakens concurrency-checking rules to preserve source compatibility if a project adopts Full or Strict concurrency checking before its dependencies have finished adding concurrency annotations.

## Effect on ABI stability

By itself, `@predatesConcurrency` does not change the ABI of a declaration. If it is applied to declarations which have already adopted one of the features it affects, that will create an ABI break. However, if those features are added at the same time or after `@predatesConcurrency` is added, adding those features will *not* break ABI.

`@predatesConcurrency`'s tactic of disabling `Sendable` conformance errors is compatible with the current ABI because `Sendable` was designed to not emit additional metadata, have a witness table that needs to be passed, or otherwise impact the calling convention or most other parts of the ABI. It only affects the name mangling.

This proposal should not otherwise affect ABI.

## Effect on API resilience

`@predatesConcurrency` on nominal declarations will need to be printed into module interfaces. It is effectively a feature to allow the evolution of APIs in ways that would otherwise break resilience.

`@predatesConcurrency` on `import` statements will not need to be printed into module interfaces; since module interfaces use the Strict concurrency checking mode, where concurrency diagnostics are warnings, they have enough "wiggle room" to tolerate the missing conformances. (As usual, compiling a module interface silences warnings by default.)

## Alternatives considered

### A "concurrency epoch"

If the evolution of a given module is tied to a version that can be expressed in `@available`, it is likely that there will be some specific version where it retroactively adds concurrency annotations to its public APIs, and that thereafter any new APIs will be "born" with correct concurrency annotations. We could take advantage of this by allowing the module to specify a "concurrency a particular version when it started ensuring that new APIs were annotated and automatically applying `@predatesConcurrency` to APIs available before this cutoff.

This would save maintainers from having to manually add `@predatesConcurrency` to many of the APIs they are retroactively updating. However, it would have a number of limitations:

1. It would only be useful for modules used exclusively on Darwin. Non-Darwin or cross-platform modules would still need to add `@predatesConcurrency` manually.

2. It would only be useful for modules which are version-locked with either Swift itself or a Darwin OS. Modules in the package ecosystem, for instance, would have little use for it.

3. In practice, version numbers may be insufficiently granular for this task. For instance, if a new API is added at the beginning of a development cycle and it is updated for concurrency later in that cycle, you might mistakenly assume that it will automatically get `@predatesConcurrency` when in fact you will need to add it by hand.

Since these shortcomings significantly reduce its applicability, and you only need to add `@predatesConcurrency` to declarations you are explicitly editing (so you are already very close to the place where you need to add it), we think a concurrency epoch is not worth the trouble.

### Objective-C and `@predatesConcurrency`

Because all Objective-C declarations are implicitly `@predatesConcurrency`, there is no way to force concurrency APIs to be checked in Minimal-mode code, even if they are new enough that there should be no violating uses. We think this limitation is acceptable to simplify the process of auditing large, existing Objective-C libraries.correctlyepoch"races.to 
