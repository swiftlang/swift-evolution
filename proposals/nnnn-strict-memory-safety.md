# Opt-in Strict Memory Safety Checking

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status:  **Awaiting review**
* Vision: *if applicable* [Opt-in Strict Memory Safety Checking (Prospective)](https://github.com/swiftlang/swift-evolution/pull/2581)
* Implementation:  On main with experimental feature flags `AllowUnsafeAttribute` and `WarnUnsafe`
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

[Memory safety](https://en.wikipedia.org/wiki/Memory_safety) is a popular topic in programming languages nowadays. Essentially, memory safety is a property that prevents programmer errors from manifesting as [undefined behavior](https://en.wikipedia.org/wiki/Undefined_behavior) at runtime. Undefined behavior effectively breaks the semantic model of a language, with unpredictable results including crashes, data corruption, and otherwise-impossible program states, which directly lead to hard-to-reproduce problems as well as security problems.

Swift provides memory safety with a combination of language affordances and runtime checking. However, Swift also deliberately includes some unsafe constructs, such as the `Unsafe` pointer types in the standard library, language features like `nonisolated(unsafe)`, and interoperability with unsafe languages like C. For most Swift developers, this is a pragmatic solution that appropriate level of memory safety while not getting in the way.

However, there are certain projects, organizations, and code bases that require stronger memory-safety guarantees, such as in security-critical subsystems handling untrusted data or that are executing with elevated privileges in an OS. This proposal introduces opt-in strict memory safety checking to identify those places in Swift code that make use of unsafe language constructs and APIs. Any code written within this strictly-safe subset also works as “normal” Swift and can interoperate with existing Swift code.

## Motivation

Much of the recent focus on memory safety is motivated by security, because memory safety issues offer a fairly direct way to compromise a program: in fact, the lack of memory safety in C and C++ has been found to be the root cause for ~70% of reported security issues in various analyses [[1](https://msrc.microsoft.com/blog/2019/07/a-proactive-approach-to-more-secure-code/)][[2](https://www.chromium.org/Home/chromium-security/memory-safety/)].

### Dimensions of memory safety

While there are a number of potential definitions for memory safety, the one provided by [this blog post](https://security.apple.com/blog/towards-the-next-generation-of-xnu-memory-safety/) breaks it down into five dimensions of safety:

* **Lifetime safety** : all accesses to a value are guaranteed to occur during its lifetime. Violations of this property, such as accessing a value after its lifetime has ended, are often called use-after-free errors.
* **Bounds safety**: all accesses to memory are within the intended bounds of the memory allocation, such as accessing elements in an array. Violations of this property are called out-of-bounds accesses.
* **Type safety** : all accesses to a value use the type to which it was initialized, or a type that is compatible with that type. For example, one cannot access a `String` value as if it were an `Array`. Violations of this property are called type confusions.
* **Initialization safety** : all values are initialized properly prior to being used, so they cannot contain unexpected data. Violations of this property often lead to information disclosures (where data that should be invisible becomes available) or even other memory-safety issues like use-after-frees or type confusions.
* **Thread safety:** all values are accessed concurrently in a manner that is synchronized sufficiently to maintain their invariants. Violations of this property are typically called data races, and can lead to any of the other memory safety problems.

### Memory safety in Swift

Since its inception, Swift has provided memory safety for the first four dimensions. Lifetime safety is provided for reference types by automatic reference counting and for value types via [memory exclusivity](https://www.swift.org/blog/swift-5-exclusivity/); bounds safety is provided by bounds-checking on `Array` and other collections; type safety is provided by safe features for casting (`as?` , `is` ) and `enum` s; and initialization safety is provided by “definite initialization”, which doesn’t allow a variable to be accessed until it has been defined. Swift 6’s strict concurrency checking extends Swift’s memory safety guarantees to the last dimension.

Providing memory safety does not imply the absence of run-time failures. Good language design often means defining away runtime failures in the type system. However, memory safely requires only that an error in the program cannot be escalated into a violation of one of the safety properties. For example, having reference types be non-nullable by default defines away most problems with NULL pointers. With explicit optional types, the force-unwrap operator (postfix `!` ) meets the definition of memory safety by trapping at runtime if the unwrapped optional is `nil` . The standard library also provides the [`unsafelyUnwrapped` property](https://developer.apple.com/documentation/swift/optional/unsafelyunwrapped) that does not check for `nil` in release builds: this does not meet the definition of memory safety because it admits violations of initialization and lifetime safety that could be exploited.

## Proposed solution

This proposal introduces an opt-in strict memory safety checking mode that identifies all uses of unsafe behavior within the given module. There are several parts to this change:

* A compiler flag `-strict-memory-safety` that enables warnings for all uses of unsafe constructs within a given module. All warnings will be in the diagnostic group `Unsafe`, enabling precise control over memory-safety-related warnings per [SE-0443](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md).
* An attribute `@unsafe` that indicates that a declaration is unsafe to use. Such declarations may use unsafe constructs within their signatures or definitions.
* An attribute `@safe(unchecked)` that indicates that a declaration provides a safe interface despite using unsafe constructs within its definition. The `unchecked` indicates that Swift cannot check this assertion of safety.
* Standard library annotations to identify unsafe declarations.

### Example of `unsafe` usage

The `UnsafeBufferPointer` type will be marked with `@unsafe` in the Standard library, as will the other unsafe types (e.g., `UnsafePointer`, `UnsafeRawPointer`):

```swift
@unsafe 
public struct UnsafeBufferPointer<Element> { ... }
```

This indicates that use of this type is not memory-safe. Any declaration that has `UnsafeBufferPointer` as part of its type is also unsafe, and would produce a warning under this strict safety mode, e.g.,

```swift
extension Array {
  // warning on next line: reference to unsafe generic struct 'UnsafeBufferPointer'
  func withUnsafeBufferPointerSimplified<T>(_ body: (UnsafeBufferPointer<Element>) -> T) -> T {
    // ...
  }
}
```

This warning can be suppressed by marking the function as `@unsafe`:

```swift
extension Array {
  @unsafe
  func withUnsafeBufferPointerSimplified<T>(_ body: (UnsafeBufferPointer<Element>) -> T) -> T {
    // ...
  }
}
```

Users of this function that also enable strict safety checking will see warnings when using it. For example:

```swift
extension Array<Int> {
  func sum() -> Int {
    // warning: use of unsafe function 'withUnsafeBufferPointerSimplified'
    withUnsafeBufferPointerSimplified { buffer in
      c_library_sum_function(buffer.baseAddress, buffer.count, 0)
    }
  }
}
```

Both the call to `withUnsafeBufferPointerSimplified` (which is `@unsafe`) and the call to `c_library_sum_function` (which has a parameter of `@unsafe` type `UnsafePointer`) would trigger warnings about uses of unsafe constructs. The author of `sum` has a choice to suppress the warnings:

1. Mark the `sum` function as `@unsafe`, propagating the "unsafe" checking out to callers of `sum`; or
2. Mark the `sum` function as `@safe(unchecked)`, taking responsibility for the safety of the code within the body. Here, one needs to verify that the `UnsafeBufferPointer` itself is being used safely (i.e., accesses are in-bounds and the buffer doesn't escape the closure) and that `c_library_sum_function` does the same with the pointer and bounds it is given.

### Incremental adoption

The strict memory safety checking proposed here enforces a subset of Swift. Code written within this subset must also be valid Swift code, and must interoperate with Swift code that does not use this strict checking. Compared to other efforts in Swift that introduce stricter checking or a subset, strictly-safe Swift is smaller and more constrained, providing better interoperability and a more gradual adoption curve:

* Strict concurrency checking, the focus of the Swift 6 language mode, required major changes to the type system, including the propagation of `Sendable` and the understanding of what code must be run on the main actor. These are global properties that don't permit local reasoning, or even local fixes, making the interoperability problem particularly hard. In contrast, strict safety checking has little or no effect on the type system, and unsafety can be encapsulated with `@safe(unchecked)` or ignored by a module that doesn't enable the checking.
* [Embedded Swift](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md) is a subset of Swift that works without a runtime. Like the proposed strictly-safe subset, code written in Embedded Swift will also work as regular Swift. Embedded Swift and the strict safety checking proposed here are orthogonal and can be composed to (for example) ensure that firmware written in Swift has no runtime and provides the best memory-safety guarantees.

A Swift module that adopts strict safety checking can address all of the resulting diagnostics by applying the `@unsafe` and `@safe(unchecked)` attributes in the appropriate places, without changing any other code. This application of attributes can be automated through Fix-Its, making it possible to enable the mode and silence all diagnostics automatically. It would then be left to the programmer to audit those places that have used `@safe(unchecked)` to encapsulate unsafe behavior within a safe interface, to ensure that they are indeed safe.

The introduction of the `@safe(unchecked)` attribute on a declaration has no effect on its clients. The introduction of the `@unsafe` attribute on a declaration has no effect on clients compiled without strict safety enabled. For clients that have enabled strict safety, they will start diagnosing uses of the newly-`@unsafe` API. However, these diagnostics are warnings with their own diagnostic group, so a client can ensure that they do not prevent the client from building. Therefore, modules can adopt strict safety checking at their own pace (or not) and clients of those modules are never "stuck" having to make major changes in response.

## Detailed design

This section describes how the `@unsafe` and `@safe` attributes interact with the strict type checking mode, and enumerates the places in the language and standard library that introduce non-memory-safe code. 

### `@unsafe` attribute

The `@unsafe` attribute can be applied to any declaration to indicate that use of that declaration can undermine memory safety. Any use of a declaration marked `@unsafe` will result in a warning. The closest analogue in the language today is `@available(*, deprecated)`, which has effectively no impact on the type system, yet any use of a deprecated declaration results in a warning.

When a type is marked `@unsafe`, a declaration that uses that type in its interface is implicitly `@unsafe`. For example, consider a program containing three separate modules:

```swift
// Module A
@unsafe
public struct DataWrapper {
  var buffer: UnsafeBufferPointer<UInt8>
  
  public func checksum() -> Int32 { ... }
}

// Module B
import A

public struct MyType {
  public var wrapper: DataWrapper
}

// Module C
import A
import B

extension MyType {
  public func checksum() -> Int32 {}
    return wrapper.checksum()
  }
}
```

Module `A` defines a type, `DataWrapper`, that is `@unsafe`. It can be compiled with or without strict safety checking enabled, and is fine either way.

Module `B` uses the `DataWrapper` type. If compiled without strict safety checking, there will be no diagnostics about memory safety. If compiled with strict safety checking, there will be a diagnostic about `wrapper` using an `@unsafe` type (`DataWrapper`) in its interface. This diagnostic can be ignored.

In module `C` enables strict memory safety, the use of `MyType` is considered safe (since it was not marked `@unsafe` and doesn't involve unsafe types in its interface). However, the access to `wrapper` will result in a diagnostic, because the type of `wrapper` involves an `@unsafe` type. 

### Encapsulating unsafe behavior

When a declaration is marked `@unsafe`, it is free to use any other unsafe declarations as part of its interface or implementation. In the example from the previously section, both `wrapper` and C's `checksum` can be marked as `@unsafe` to suppress diagnostics by explicitly propagating unsafety to their clients:

```swift
// Module B
import A

public struct MyType {
  @unsafe public var wrapper: DataWrapper
}

// Module C
import A
import B

extension MyType {
  @unsafe public func checksum() -> Int32 {}
    return wrapper.checksum()
  }
}
```

However, these two APIs diff in the severity of the problem they post for memory safety: `wrapper` has an unsafe type in its interface, so any use of `wrapper` is fundamentally unsafe. However, `MyType` itself can encapsulate the memory-unsafe behavior within a safe API., The `MyType.checksum` operation is actually safe for clients to use. Marking it as `@unsafe` is therefore undesirable, because it (incorrectly) forces clients to treat this as an unsafe API, causing unnecessary extra work and deluting the value of correctly-identified unsafe APIs.

One option would be for the author of module `C` to simply ignore the memory-safety warnings produced within its body, which will have the effect of encapsulating the unsafe behavior, but would make it harder to ensure that all unsafe behavior has been accounted for in that module. Another option would be to factor this code into a separate module that doesn't enable strict safety checking, but this is a fairly heavyweight solution.

Instead, introduce an attribute `@safe(unchecked)` that asserts that the definition is safe despite uses of unsafe constructs. This is a programmer assertion that cannot be validated by the compiler, so it should be used carefully. For the `checksum` operation, it would be used as follows to suppress all memory-safety diagnostics within the body of the function:

```swift
extension MyType {
  @safe(unchecked) public func checksum() -> Int32 {}
    return wrapper.checksum()
  }
}
```

Note that `@safe(unchecked)` only suppresses memory-safety diagnostics in the definition. If we were to try to apply it to the `wrapper` property and enable strict safety checking in module `B`, like this:

```swift
public struct MyType {
  @safe(unchecked) public var wrapper: DataWrapper // warning: use of unsafe type 'DataWrapper'
}
```

it would not suppress the diagnostic, because `wrapper` is still fundamentally unsafe.

The `@safe` attribute allows an optional message, which can be used to explain why the use of unsafe constructs is justified, and is meant to help with an audit trail. Bringing back out early example of producing the sum of values in an array, one can provide an explanation here:

```swift
extension Array<Int> {
  @safe(unchecked, message: "use of C API that does its own bounds-safety checking")
  func sum() -> Int {
    withUnsafeBufferPointerSimplified { buffer in
      c_library_sum_function(buffer.baseAddress, buffer.count, 0)
    }
  }
}
```

### Unsafe language constructs

The following language constructs are always considered to be unsafe:

* `unowned(unsafe)`: Used to store a reference without maintaining its reference count. The safe counterpart, `unowned`, uses dynamic checking to ensure that the reference isn't accessed after the corresponding object has been released. The `unsafe` variant disables that dynamic checking. Uses of `unowned(unsafe)` entities are not memory-safe.
* `unsafeAddressor`, `unsafeMutableAddressor`: These accessors vend an unsafe pointer, and are therefore unsafe to declare. Other accessors (e.g., `get` and `set`) can provide safe alternatives.

The following language constructs are considered to be unsafe when strict concurrency checking is enabled (i.e., in the Swift 6 language mode):

* `nonisolated(unsafe)`: Allows a property to be accessed from concurrent code without ensuring that such accesses are done so safely. Uses of `nonisolated(unsafe)` entities are not memory-safe.
* `@preconcurrency` imports: Suppresses diagnostics related to data race safety when they relate to specific imported modules, which can introduce thread safety issues.

### Unsafe standard library APIs

In the standard library, the following functions and types would be marked `@unsafe` :

* `Unsafe(Mutable)(Raw)(Buffer)Pointer`, `OpaquePointer`, `CVaListPointer`: These types provide neither lifetime nor bounds safety. Over time, Swift code is likely to move toward their safe replacements, such as `(Raw)Span`.
* `(Closed)Range.init(uncheckedBounds:)`: This operation makes it possible to create a range that doesn't satisfy invariants on which other bounds safety checking (e.g., in `Array.subscript`)
* `Span.subscript(unchecked:)` : An unchecked subscript whose use can introduce bounds safety problems.
* `Unmanaged`: Wrapper over reference-counted types that explicitly disables reference counting, potentially introducing lifetime safety issues.
* `unsafeBitCast`: Allows type casts that are not known to be safe, which can introduce type safety problems.
* `unsafeDowncast`: An unchecked form of an `as!` cast that can introduce type safety problems.
* `Optional.unsafelyUnwrapped`: An unchecked form of the postfix `!` operation on optionals that can introduce various type, initialization, or lifetime safety problems when `nil` is interpreted as a typed value.
* `UnsafeContinuation`, `withUnsafe(Throwing)Continuation`: An unsafe form of `withChecked(Throwing)Continuation` that does not verify that the continuation is called exactly once, which can cause various safety problems.
* `withUnsafeCurrentTask` and `UnsafeCurrentTask`: The `UnsafeCurrentTask` type does not provide lifetime safety, and must only be used within the closure passed to `withUnsafeCurrentTask`.
* `UnownedSerialExecutor`: This type is intentionally not lifetime safe. It's primary use is the `unownedExecutor` property of the `Actor` protocol, which documents the lifetime assumptions of the `UnownedSerialExecutor` instance it produces.

All of these APIs will be marked `@unsafe`. For all of the types that are `@unsafe`, any API that uses that type in its signature will also be marked `@unsafe`, such as `Array.withUnsafeBufferPointer`. Unless mentioned above, standard library APIs that do not have an unsafe type in their signature, but use unsafe constructs in their implementation, will be marked `@safe(unchecked)` because they provide safe abstractions to client code.

### Unsafe compiler flags

The `-Ounchecked` compiler flag disables some checking in the standard library, including (for example) bounds checking on array accesses. It is generally discouraged in all Swift code, but is particularly problematic in conjunction with strict memory safety because it removes the checking that makes certain standard library APIs safe. Therefore, the compiler will produce a diagnostic when the two features are combined.

### Unsafe overrides

Overriding a safe method within an `@unsafe` one could introduce unsafety, so it will produce a diagnostic in the strict safety mode:

```swift
class Super {
  func f() { }
}

class Sub: Super {
  @unsafe func f() { ... } // warning: override of safe instance method with unsafe instance method
}
```

to suppress this warning, the `Sub` class itself can be marked as `@unsafe`, e.g.,

```swift
@unsafe
class Sub: Super {
  func f() { ... } // warning: override of safe instance method with unsafe instance method
}
```

The `@unsafe` annotation is at the class level because any use of the `Sub` type can now introduce unsafe behavior, and any indication of that unsafe behavior will be lost once that `Sub` is converted to a `Super` instance.

### Unsafe conformances

Implementing a protocol requirement that is safe (and not part of an `@unsafe` protocol) within an `@unsafe` declaration introduces unsafety, so it will produce a diagnostic in the strict safety mode:

```swift
protocol P {
  func f()
}

struct ConformsToP { }

extension ConformsToP: P {
  @unsafe func f() { } // warning: unsafe instance method 'f()' cannot satisfy safe requirement
}
```

To suppress this warning, one can place `@unsafe` on the conformance to `P` is supplied. This notes that the conformance itself is unsafe:

```swift
extension ConformsToP: @unsafe P {
  @unsafe func f() { }
}
```

Use of an `@unsafe` conformance for any reason (e.g., when that conformance is needed to call a generic function with a `ConformsToP` requirement) is diagnosed as an unsafe use, much like use of an `@unsafe` declaration. For example

```swift
func acceptP<T: P>(_: T.Type) { }

func passUnsafe() {
  acceptP(ConformsToP.self) // warning: use of @unsafe conformance of 'ConformsToP' to protocol 'P'
}
```

### Strict safety mode and escalatable warnings

The strict memory safety mode can be enabled with the new compiler flag `-strict-memory-safety`.

All of the memory-safety diagnostics produced by the strict memory safety mode will be warnings. These warnings be in the group `Unsafe` (possibly organized into subgroups) so that one can choose to escalate them to errors or keep them as warnings using the compiler flags introduced in [SE-0443](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md). For example, one can choose to enable the mode and make memory-safety issues errors using:

```
swiftc -strict-memory-safety -Werror Unsafe
```

### SwiftPM integration

Swift package manifests will need a way to enable strict memory safety mode on a per-module and per-package basis. This proposal extends the `SwiftSetting` type in the manifest with a new option to enable that checking:

```swift
static func strictMemorySafety(
  _ condition: BuildSettingCondition? = nil
) -> SwiftSetting
```

## Source compatibility

The introduce of this strict safety checking mode has no impact on source compatibility for any module that does not enable it. When enabling strict safety checking, source compatibility impact is limited to the introduction of warnings that will not break source compatibility (and can be treated as warnings even under `-warnings-as-errors` mode). The source compatibility and interoperability story is covered in detail in prior sections.

## ABI compatibility

The attributes and strict memory-safety checking model proposed here have no impact on ABI.

## Future Directions

### Overloading to stage in safe APIs

When adopting the strict memory safety mode, it's likely that a Swift module will want to replace existing APIs that traffic in unsafe types (such as `UnsafeMutablePointer`) with safer equivalents (such as `Span`). To retain compatibility for older clients, the existing APIs will need to be left in place. Unfortunately, this might mean that the best name for the API is already taken. For example, perhaps we have a data packet that exposes its bytes via a property:

```swift
public class DataPacket {
  @unsafe public let bytes: UnsafeRawBufferPointer
}
```

The `bytes` property is necessarily unsafe. Far better would be to produce a `RawSpan`, which we can easily do with another property:

```swift
extension DataPacket {
  @safe(unchecked) public var byteSpan: RawSpan
}
```

Clients using the existing `bytes` will continue to work, and those that care about memory safety can choose to move to `byteSpan`. All of this works, but is somewhat annoying because the good name, `bytes`, has been taken for the API we no longer want to use.

Swift does allow type-based overloading, including on the type of properties, so one could introduce an overloaded `bytes` property, like this:

```swift
extension DataPacket {
  @safe(unchecked) public var bytes: RawSpan
}
```

This works for code that accesses `bytes` and then uses it in a context where type inference can figure out whether we need an `UnsafeRawBufferPointer` or a `RawSpan`, but fails if that context does not exist:

```swift
let unsafeButGoodBytes: UnsafeRawBufferPointer = dataPacket.bytes // ok, uses @unsafe bytes
let goodBytes: RawSpan = dataPacket.bytes // ok, uses safe bytes
let badBytes = dataPacket.bytes // error: ambiguous!
```

We could consider extending Swift's overloading rules to make this kind of evolution possible. For example, one could introduce a pair of rules into the language:

1. When strict memory safety checking is enabled, `@unsafe` declarations are dis-favored vs. safe ones, so the unsafe `bytes: UnsafeRawBufferPointer` would be a worse solution for type inference to pick than the safe alternative, `bytes: RawSpan`. 

2. Overloads that were introduced to replace unsafe declarations could be marked with a new attribute `@safe(unsafeDisfavored)` so that they would be disfavored only when building with strict memory safety checking disabled.

Assuming these rules, and that the safe `bytes: RawSpan` had the `@safe(unsafeDisfavored)` attribute, the example uses of `DataPacket` would resolve as follows:

* `unsafeButGoodBytes` would always be initialized with the unsafe `bytes`. If strict memory safety were enabled, this use would produce a warning.
* `goodBytes` would always be initialized with the safe `bytes`.
* `badBytes` would be initialized differently based on whether strict memory safety was enabled:
  * If enabled, `badBytes` would choose the safe version of `bytes` to produce the safest code,  because the unsafe one is disfavored (rule #1).
  * If disabled, `badBytes` would choose the unsafe version of `bytes` to provide source compatibility with existing code, because the safe one is disfavored (rule #2).

There are downsides to this approach. It partially undermines the source compatibility story for the strict safety mode, because type inference now behaves differently when the mode is enabled. That means, for example, there might be errors---not warnings---because some code like `badBytes` above would change behavior, causing additional failures. Changing the behavior of type inference is also risky in an of itself, because it is not always easy to reason about all of the effects of such a change. That said, the benefit of being able to move toward a more memory-safe future might be worth it.

## Alternatives considered

### `unsafe` blocks

The attribute `@safe(unchecked)` indicates that a definition is safe despite the use of unsafe constructs in its body. The attribute has no effect on the client, and could effectively be eliminated from the public interface (e.g., documentation, Swift textual interfaces, etc.) without changing how clients behave.

There is an alternative formulation for acknowledging unsafe code that is used in some peer languages like C# and Rust: an `unsafe` block, which is a statement (or expression) that suppresses diagnostics about uses of unsafe code within it. For example, the `sum` example could be written as follows:

```swift
extension Array<Int> {
  func sum() -> Int {
    unsafe {
      withUnsafeBufferPointerSimplified { buffer in
        c_library_sum_function(buffer.baseAddress, buffer.count, 0)
      }
    }
  }
}
```

For Swift, `unsafe` would be a statement that can also be used as an expression when its body is an expression, much like `if` or `switch` expressions following [SE-0380](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0380-if-switch-expressions.md).

This proposal suggests the `@safe(unchecked)` attribute instead of `unsafe` blocks for a few reasons, but the choice is effectively arbitrary: either syntax will work with the rest of this proposal. Some of the reasons for preferring `@safe(unchecked)` include:

* It's easier to stage in this change without affecting the surrounding code. One can add
  ```swift
  if #hasAttribute(safe)
  @safe(unchecked)
  #endif
  ```

  to `sum` without changing any other code, which is easy to review and will still work with compilers that predate the introduction of this feature.

* The `unsafe` blocks end up adding another level of nesting, which also means that introducing them to silence warnings causes unnecessarily large amount of code change when adopting the feature.

* The `unsafe` blocks aren't a natural boundary between unsafe and safe code in the same way as a function boundary, because there is no place to state the expected invariants. Combined with pressure to make `unsafe` blocks have as little code as possible (as a proxy for that code being safer), it becomes easy for "minimizing the amount of code in unsafe blocks" to introduce more safety problems. For example, `sum` might be incorrectly factored as follows:

  ```swift
  extension Array<Int> {
    func sum() -> Int {
      let (ptr, count) = unsafe {
        withUnsafeBufferPointerSimplified { buffer in
          (buffer.baseAddress, buffer.count)
        }
      }
      return unsafe { c_library_sum_function(ptr, count, 0) }
    }
  }
  ```

  Here, the base address pointer has escaped the `withUnsafeBufferPointerSimplified` block, causing a member safety problem that wouldn't have been there before. If we tried to do this kind of factoring with the `@safe(unchecked)` approach, the intermediate function producing the pointer would have to be marked `@unsafe`.



### Strictly-safe-by-default

This proposal introduced strict safety checking as an opt in mode and not an [*upcoming* language feature](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0362-piecemeal-future-features.md) because there is no intent to make this feature the default behavior in a future language mode. There are several reasons why this checking should remain an opt-in feature for the foreseeable future:

* The various `Unsafe` pointer types are the only way to work with contiguous memory in Swift today, and  the safe replacements (e.g., `Span`) are new constructs that will take a long time to propagate through the ecosystem. Some APIs depending on these `Unsafe` pointer types cannot be replaced because it would break existing clients (either source, binary, or both).
* Interoperability with the C family of languages is an important feature for Swift. Most C(++) APIs are unlikely to ever adopt the safety-related attributes described above, which means that enabling strict safety checking by default would undermine the usability of C(++) interoperability.
* Swift's current (non-strict) memory safety by default is likely to be good enough for the vast majority of users of Swift, so the benefit of enabling stricter checking by default is unlikely to be worth the disruption it would cause.

