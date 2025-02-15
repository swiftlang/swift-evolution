# Import Objective-C completion handler parameters as `@Sendable`

* Proposal: [SE-NNNN](NNNN-sendable-completion-handlers.md)
* Authors: [Holly Borla](https://github.com/hborla)
* Review Manager: TBD
* Status: **Awaiting review**
* Vision: [[Prospective Vision] Improving the approachability of data-race safety](https://forums.swift.org/t/prospective-vision-improving-the-approachability-of-data-race-safety/76183)
* Implementation: On `main` behind `-enable-experimental-feature SendableCompletionHandlers`
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

This proposal changes the Objective-C importing rules such that completion handler parameters are `@Sendable` by default.

## Motivation

Swift's data-race safety model requires function declarations to codify their concurrency invariants in the function signature with annotations. The `@Sendable` annotation indicates that closure parameters are passed over an isolation boundary before they're called. A missing `@Sendable` annotation in a library has negative effects on clients who call the function; the caller can unknowingly introduce data races, and [SE-0423: Dynamic actor isolation enforcement from non-strict-concurrency contexts][SE-0423] injects runtime assertions for non-`Sendable` closure parameters that are passed into libraries that don't have data-race safety checking. This means that a missing `@Sendable` annotation can lead to a runtime crash for any code that calls the API from an actor isolated context, which is extremely painful for projects that are migrating to the Swift 6 language mode.

There's a large category of APIs with closure parameters that can be automatically identified as `@Sendable` functions, even if the annotation is missing: Objective-C methods with completion handler parameters. `@Sendable` is nearly always the right default for Objective-C completion handlers, and [programmers have already been searching for an automatic way for completion handlers to be `@Sendable` by default when auditing Clang headers](https://forums.swift.org/t/clang-sendability-audit-for-closures/75557).

## Proposed solution

I propose automatically importing completion handler parameters from Objective-C methods as `@Sendable` functions.

## Detailed design

If an imported method has an async variant (as described in [SE-0297: Concurrency Interoperability with Objective-C][SE-0297]), the original method will be imported with a `@Sendable` annotation on its completion handler parameter.

For example, given the following Objective-C method signature:

```objc
- (void)performOperation:(NSString * _Nonnull)operation
  completionHandler:(void (^ _Nullable)(NSString * _Nullable, NSError * _Nullable))completionHandler;
```

Swift will import the method with `@Sendable` on the `completionHandler` parameter:

```swift
@preconcurrency
func perform(
  operation: String,
  completionHandler: @Sendable @escaping ((String?, Error?) -> Void)?
)
```

When calling the `perform` method from a Swift actor, the inference rules that allow non-`Sendable` closures to be isolated to the context they're formed in will no longer apply. The closure will be inferred as `nonisolated`, and warnings will be produced if any mutable state in the actor's region is accessed from the closure. Note that all APIs imported from C/C++/Objective-C are automatically `@preconcurrency`, so data-race safety violations are only ever warnings, even in the Swift 6 language mode.

### Opting out of `@Sendable` completion handlers

If a completion handler does not cross an isolation boundary before it's called, the parameter can be annotated in the header with the `@nonSendable` attribute using `__attribute__((swift_attr(“@nonSendable”)))`. The `@nonSendable` attribute is only for Clang header annotations; it is not meant to be used from Swift code. 

## Source compatibility

This change has no effect in language modes prior to Swift 6 when using minimal concurrency checking, and it only introduces warnings when using complete concurrency checking, even in the Swift 6 language mode. Declarations imported from C/C++/Objective-C are implicitly `@preconcurrency`, which makes all data-race safety violations warnings.

## ABI compatibility

This proposal has no impact on existing ABI.

## Alternatives considered

### Import completion handlers as `sending` instead of `@Sendable`

The choice to import completion handlers as `@Sendable` instead of `sending` is pragmatic - the experimental `SendableCompletionHandlers` implementation has existed since 2021 and has been extensively tested for source compatibility. Similarly, `@Sendable` has been explicitly adopted in Objective-C frameworks for several years, and source compatibility issues resulting from corner cases in the compiler implementation that were intolerable to `@Sendable` mismatches have shaken out over time. `sending` is still a relatively new parameter attribute, it has not been adopted as extensively as `@Sendable`, and it does not support downgrading diagnostics in the Swift 6 language mode when combined with `@preconcurrency`.

The pain caused by the dynamic actor isolation runtime assertions is enough that it's worth solving this problem now conservatively using `@Sendable`. From the caller side, `sending` imposes fewer restrictions than `@Sendable`. This means that, after more extensive adoption of `sending` and gaining confidence that automatic adoption in a vast API surface will not cause source compatibility issues, the import rule in this proposal can later be changed to use `sending` instead of `@Sendable` and the only effect will be eliminating false positive warnings.

## Future directions

### Generalize `@nonSendable` for use in Swift code

If a library author wants to explicitly annotate a type as "not Sendable", that might mean two different things:

1. The type has mutable state and is never `Sendable`.
2. The type might be conditionally `Sendable`, e.g. based on the dynamic type at runtime.

Currently, the semantics described by 1. is expressed today with an unavailable conformance to `Sendable`:

```swift
class HasMutableState {}

@available(*, unavailable)
extension HasMutableState: Sendable {}
```

This is unfortunate boilerplate. Instead, the `@nonSendable` attribute could expand to the above unavailable `Sendable` conformance via conformance macro.

The semantics described by 2. is not explicitly expressible today. This could be allowed using the suppressible conformance syntax `~Sendable`:

```swift
public class C: ~Sendable {}

public class MutableC {
  var mutableState = 0
}

public class ImmutableC: @unchecked Sendable {
  let immutableState = 0
}
```

Though `~Sendable` does not mean anything different than leaving the `Sendable` conformance out entirely, this syntax is useful for library authors who want to be explicit about `Sendable` conformances for their entire public API surface to ensure they've audited every public type in a given library.

## Acknowledgments

Thank you to Becca Royal-Gordon for implementing the `SendableCompletionHandlers` experimental feature, and thank you to Pavel Yaskevich for consistently fixing compiler bugs where the implementation was intolerant to `@Sendable` mismatches.

[SE-0297]: /proposals/0297-concurrency-objc.md
[SE-0423]: /proposals/0423-dynamic-actor-isolation.md
