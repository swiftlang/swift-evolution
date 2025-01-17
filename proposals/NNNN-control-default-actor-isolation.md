# Control default actor isolation inference

* Proposal: [SE-NNNN](NNNN-control-default-actor-isolation.md)
* Authors: [Holly Borla](https://github.com/hborla)
* Review Manager: TBD
* Status: **Awaiting review**
* Vision: [Improving the approachability of data-race safety](/visions/approachable-concurrency.md)
* Implementation: On `main` behind the `UnspecifiedMeansMainActorIsolated` experimental feature.
* Review: ([pitch](https://forums.swift.org/t/pitch-control-default-actor-isolation-inference/77482))

## Introduction

This proposal introduces a new compiler setting for inferring `@MainActor` isolation by default within the module to mitigate false-positive data-race safety errors in sequential code.

## Motivation

> Note: This motivation section was adapted from the [prospective vision for approachable data-race safety](https://github.com/hborla/swift-evolution/blob/approachable-concurrency-vision/visions/approachable-concurrency.md#mitigating-false-positive-data-race-safety-errors-in-sequential-code). Please see the vision document for extended motivation.

A lot of code is effectively “single-threaded”. For example, most executables, such as apps, command-line tools, and scripts, start running on the main actor and stay there unless some part of the code does something concurrent (like creating a `Task`). If there isn’t any use of concurrency, the entire program will run sequentially, and there’s no risk of data races — every concurrency diagnostic is necessarily a false positive! It would be good to be able to take advantage of that in the language, both to avoid annoying programmers with unnecessary diagnostics and to reinforce progressive disclosure. Many people get into Swift by writing these kinds of programs, and if we can avoid needing to teach them about concurrency straight away, we’ll make the language much more approachable.

The easiest and best way to model single-threaded code is with a global actor. Everything on a global actor runs sequentially, and code that isn’t isolated to that actor can’t access the data that is. All programs start running on the global actor `MainActor`, and if everything in the program is isolated to the main actor, there shouldn’t be any concurrency errors.

Unfortunately, it’s not quite that simple right now. Writing a single-threaded program is surprisingly difficult under the Swift 6 language mode. This is because Swift 6 defaults to a presumption of concurrency: if a function or type is not annotated or inferred to be isolated, it is treated as non-isolated, meaning it can be used concurrently. This default often leads to conflicts with single-threaded code, producing false-positive diagnostics in cases such as:

- global and static variables,
- conformances of main-actor-isolated types to non-isolated protocols,
- class deinitializers,
- overrides of non-isolated superclass methods in a main-actor-isolated subclass, and
- calls to main-actor-isolated functions from the platform SDK.

## Proposed solution

This proposal allows code to opt in to being “single-threaded” by default, on a module-by-module basis. A new `-default-isolation` compiler flag specifies the default isolation within the module, and a corresponding `SwiftSetting` method specifies the default isolation per target within a Swift package.

This would change the default isolation rule for unannotated code in the module: rather than being non-isolated, and therefore having to deal with the presumption of concurrency, the code would instead be implicitly isolated to `@MainActor`. Code imported from other modules would be unaffected by the current module’s choice of default. When the programmer really wants concurrency, they can request it explicitly by marking a function or type as `nonisolated` (which can be used on any declaration as of [SE-0449](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0449-nonisolated-for-global-actor-cutoff.md)), or they can define it in a module that doesn’t default to main-actor isolation.

## Detailed design

### Specifying default isolation per module

#### `-default-isolation` compiler flag

The `-default-isolation` flag can be used to control the default actor isolation for all code in the module. The only valid arguments to `-default-isolation` are `MainActor` and `nonisolated`. It is an error to specify both `-default-isolation MainActor` and `-default-isolation nonisolated`. If no `-default-isolation` flag is specified, the default isolation for the module is `nonisolated`.

#### `SwiftSetting.defaultIsolation` method

The following method on `SwiftSetting` can be used to specify the default actor isolation per target in a Swift package manifest:

```swift
extension SwiftSetting {
  @available(_PackageDescription, introduced: 6.2)
  public static func defaultIsolation(
    _ globalActor: MainActor.Type?,
    _ condition: BuildSettingCondition? = nil
  ) -> SwiftSetting
}
```

The only valid values for the `globalActor` argument are `MainActor.self` and `nil`. The `nil` argument corresponds to `nonisolated`; `.defaultIsolation(nil)` will default to `nonisolated` within the module. When no `.defaultIsolation` setting is specified, the default isolation within the module is `nonisolated`.

### Default actor isolation inference

When the default actor isolation is specified as `MainActor`, declarations are inferred to be `@MainActor`-isolated by default. Default isolation does not apply in the following cases:

* Declarations with explicit actor isolation
* Declarations with inferred actor isolation from a superclass, overridden method, protocol conformance, or member propagation
* Static variables and methods in an actor
* Actor initializers and deinitializers
* Declarations that cannot have global actor isolation, including typealiases, import statements, enum cases, and individual accessors

The following code example shows the inferred actor isolation in comments given the code is built with `-default-isolation MainActor`:

```swift
// @MainActor
func f() {}

// @MainActor
class C {
  // @MainActor
  init() { ... }

  // @MainActor
  deinit { ... }

  // @MainActor
  struct Nested { ... }

  // @MainActor
  static var value = 10
}

@globalActor
actor MyActor {
  // nonisolated
  init() { ... }

  // nonisolated
  deinit { ... }

  // nonisolated
  static let shared = MyActor()
}

@MyActor
protocol P {}

// @MyActor
struct S: P {
  // @MyActor
  func f() { ... }
}
```

This proposal does not change the default isolation inference rules for closures. Non-Sendable closures and closures passed to `Task.init` already have the same isolation as the enclosing context by default. When specifying `MainActor` isolation by default in a module, non-`@Sendable` closures and `Task.init` closures will have inferred `@MainActor` isolation when the default `@MainActor` inference rules apply to the enclosing context:

```swift
// Built with -default-isolation MainActor

// @MainActor
func f() {
  Task { // @MainActor in
    ...
  }

  Task.detached { // nonisolated in
    ...
  }
}

nonisolated func g() {
  Task { // nonisolated in
    ...
  }
}
```

## Source compatibility

Changing the default actor isolation for a given module or source file is a source incompatible change. The default isolation will remain the same for existing projects unless they explicitly opt into `@MainActor` inference by default via `-default-isolation MainActor` or `defaultIsolation(MainActor.self)` in a package manifest.

## ABI compatibility

This proposal has no ABI impact on existing code.

## Implications on adoption

This proposal does not change the adoption implications of adding `@MainActor` to a declaration that was previously `nonisolated` and vice versa. The source and ABI compatibility implications of changing actor isolation are documented in the Swift migration guide's [Library Evolution](https://github.com/apple/swift-migration-guide/blob/29d6e889e3bd43c42fe38a5c3f612141c7cefdf7/Guide.docc/LibraryEvolution.md#main-actor-annotations) article.

## Future directions

### Specify build settings per file

There are some build settings that are applicable on a per-file basis, including specifying default actor isolation and controlling diagnostic behavior. We could consider allowing settings in individual files which the setting should apply to by introducing a `#pragma`-like compiler directive. This idea has been [pitched separately](https://forums.swift.org/t/pitch-compilersettings-a-top-level-statement-for-enabling-compiler-flags-locally-in-a-specific-file/77994).

## Alternatives considered

### Allow defaulting isolation to a custom global actor

The `-default-isolation` flag could allow a custom global actor as the argument, and the `SwiftSetting` API could be updated to accept a string that represents a custom global actor in the target.

This proposal only supports `MainActor` because any other global actor does not help with progressive disclosure. It has the opposite effect - it forces asynchrony on any main-actor-isolated caller. However, there's nothing in this proposal prohibits generalizing these settings to supporting arbitrary global actors in the future if a compelling use case arises.

### Infer `MainActor` by default as an upcoming feature

Instead of introducing a separate mode for configuring default actor isolation inference, the default isolation could be changed to be `MainActor` under an upcoming feature that is enabled by default in a future Swift language mode. The upcoming feature approach was not taken because `MainActor` isolation is the wrong default for many kinds of modules, including libraries that offer APIs that can be used from any isolation domain, and highly-concurrent server applications.

See the approachable data-race safety vision document for an [analysis on the risks of introducing a language dialect](https://github.com/hborla/swift-evolution/blob/approachable-concurrency-vision/visions/approachable-concurrency.md#risks-of-a-language-dialect) for default actor isolation.

## Acknowledgments

Thank you to John McCall for providing much of the motivation for this pitch in the approachable data-race safety vision document, and to Michael Gottesman for helping with the implementation.