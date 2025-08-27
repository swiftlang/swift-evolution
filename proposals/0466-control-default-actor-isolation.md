# Control default actor isolation inference

* Proposal: [SE-0466](0466-control-default-actor-isolation.md)
* Authors: [Holly Borla](https://github.com/hborla), [Doug Gregor](https://github.com/DougGregor)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Active review (July 8...15, 2025)**
* Vision: [Improving the approachability of data-race safety](/visions/approachable-concurrency.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-control-default-actor-isolation-inference/77482))([review](https://forums.swift.org/t/se-0466-control-default-actor-isolation-inference/78321))([acceptance](https://forums.swift.org/t/accepted-se-0466-control-default-actor-isolation-inference/78926))([amendment pitch](https://forums.swift.org/t/pitch-amend-se-0466-se-0470-to-improve-isolation-inference/79854))([amendment review](https://forums.swift.org/t/amendment-se-0466-control-default-actor-isolation-inference/80994))

## Introduction

This proposal introduces a new compiler setting for inferring `@MainActor` isolation by default within the module to mitigate false-positive data-race safety errors in sequential code.

## Motivation

> Note: This motivation section was adapted from the [vision for approachable data-race safety](https://github.com/hborla/swift-evolution/blob/approachable-concurrency-vision/visions/approachable-concurrency.md#mitigating-false-positive-data-race-safety-errors-in-sequential-code). Please see the vision document for extended motivation.

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
* All declarations inside an `actor` type, including static variables, methods, initializers, and deinitializers
* Declarations that cannot have global actor isolation, including typealiases, import statements, enum cases, and individual accessors
* Declarations whose primary definition directly conforms to a protocol that inherits `SendableMetatype`
* Declarations that are types nested within a nonisolated type

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

nonisolated protocol Q: Sendable { }

// nonisolated
struct S2: Q {
  // nonisolated
  struct Inner { }

  // @MyActor
  struct IsolatedInner: P
}

// @MainActor
struct S3 { }

extension S3: Q { }
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

This proposal only supports `MainActor` because any other global actor does not help with progressive disclosure. It has the opposite effect - it forces asynchrony on any main-actor-isolated caller. However, there's nothing in this proposal that prohibits generalizing these settings to supporting arbitrary global actors in the future if a compelling use case arises.

### Infer `MainActor` by default as an upcoming feature

Instead of introducing a separate mode for configuring default actor isolation inference, the default isolation could be changed to be `MainActor` under an upcoming feature that is enabled by default in a future Swift language mode. The upcoming feature approach was not taken because `MainActor` isolation is the wrong default for many kinds of modules, including libraries that offer APIs that can be used from any isolation domain, and highly-concurrent server applications.

Similarly, a future language mode could enable main actor isolation by default, and require an opt out for using `nonisolated` as the default actor isolation. However, as the Swift package ecosystem grows, it's more likely for `nonisolated` to be the more common default amongst projects. If we discover that not to be true in practice, nothing in this proposal prevents changing the default actor isolation in a future language mode.

See the approachable data-race safety vision document for an [analysis on the risks of introducing a language dialect](https://github.com/hborla/swift-evolution/blob/approachable-concurrency-vision/visions/approachable-concurrency.md#risks-of-a-language-dialect) for default actor isolation.

### Alternative to `SendableMetatype` for suppressing main-actor inference

The protocols to which a type conforms can affect the isolation of the type. Conforming to a global-actor-isolated protocol can infer global-actor isolatation for the type. When the default actor isolation is `MainActor`, it is valuable for protocols to be able to push inference toward keeping conforming types `nonisolated`, for example because conforming types are meant to be usable from any isolation domain.

In this proposal, inheritance from `SendableMetatype` (introduced in [SE-0470](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0470-isolated-conformances.md)) is used as an indication that types conforming to the protocol should be `nonisolated`. The `SendableMetatype` marker protocol indicates when a type (but not necessarily its instances) can cross isolation domains, which implies that the type generally needs to be usable from any isolation domain. Additionally, protocols that inherit from `SendableMetatype` can only be meaningfully be used with nonisolated conformances, as discussed in SE-0470. Experience using default main actor isolation uncovered a number of existing protocols that reinforce the notion of `SendableMetatype` inheritance is a reasonable heuristic to indicate that a conforming type should be nonisolated: the standard library's [`CodingKey`](https://developer.apple.com/documentation/swift/codingkey) protocol inherits `Sendable` (which in turn inherits `SendableMetatype`) so a typical conformance will fail to compile with default main actor isolation:

```swift
struct S: Codable {
  var a: Int

  // error if CodingKeys is inferred to `@MainActor`. The conformance cannot be main-actor-isolated, and
  // the requirements of the (nonisolated) CodingKey cannot be satisfied by main-actor-isolated members of
  // CodingKeys.
  enum CodingKeys: CodingKey {
    case a
  }
}
```

Other places that have similar issues with default main actor isolation include the [`Transferable`](https://developer.apple.com/documentation/coretransferable/transferable) protocol and the uses of key paths in the [`@Model` macro](https://developer.apple.com/documentation/swiftdata/model()).

Instead of using `SendableMetatype` inheritance, this proposal could introduce new syntax for a protocol to explicitly indicate 

```swift
@nonisolatedConformingTypes
public protocol CodingKey { 
  // ...
}
```

This would make the behavior pushing conforming types toward `nonisolated` opt-in. However, it means that existing protocols (such as the ones mentioned above) would all need to adopt this spelling before code using default main actor isolation will work well. Given the strong semantic link between `SendableMetatype` and `nonisolated` conformances and types, the proposed rule based on `SendableMetatype` inheritance is likely to make more code work well with default main actor isolation. An explicit opt-in attribute like the above could be added at a later time if needed.

### Use an enum for the package manifest API

An alternative to using a `MainActor` metatype for the Swift package manifest API is to use an enum, e.g.

```swift
public enum DefaultActorIsolation {
  case mainActor
  case nonisolated
}

extension SwiftSetting {
  @available(_PackageDescription, introduced: 6.2)
  public static func defaultIsolation(
    _ isolation: DefaultActorIsolation,
    _ condition: BuildSettingCondition? = nil
  ) -> SwiftSetting
}

// in a package manifest

swiftSettings: [
  .defaultIsolation(.mainActor)
]
```

The enum approach introduces a different way of writing main actor isolation that does not involve the `MainActor` global actor type. The proposed design matches exactly the values used for `#isolation`, i.e. `MainActor.self` for main actor isolation and `nil` for `nonisolated`, which programmers are already familiar with.

The primary argument for using an enum is that it can be extended in the future to support custom global actor types. This proposal deliberately puts supporting custom global actors in the alternatives considered and not future directions, because defaulting a module to a different global actor does not help improve progressive disclosure for concurrency.

## Revision history

* Changes in amendment review:
  * Disable `@MainActor` inference when type conforms to a `SendableMetatype` protocol

## Acknowledgments

Thank you to John McCall for providing much of the motivation for this pitch in the approachable data-race safety vision document, and to Michael Gottesman for helping with the implementation.
