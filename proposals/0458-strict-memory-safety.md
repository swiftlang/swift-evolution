# Opt-in Strict Memory Safety Checking

* Proposal: [SE-0458](0458-strict-memory-safety.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status:  **Active Review (January 17th...27th, 2025)**
* Feature name: `StrictMemorySafety`
* Vision: [Opt-in Strict Memory Safety Checking (Prospective)](https://github.com/swiftlang/swift-evolution/pull/2581)
* Implementation:  On main with experimental feature flags `AllowUnsafeAttribute` and `WarnUnsafe`
* Review: ([pitch](https://forums.swift.org/t/pitch-opt-in-strict-memory-safety-checking/76689)) ([review](https://forums.swift.org/t/se-0458-opt-in-strict-memory-safety-checking/77274))

## Introduction

[Memory safety](https://en.wikipedia.org/wiki/Memory_safety) is a property of programming languages and their implementations that prevents programmer errors from manifesting as [undefined behavior](https://en.wikipedia.org/wiki/Undefined_behavior) at runtime. Undefined behavior effectively breaks the semantic model of a language, with unpredictable results including crashes, data corruption, and otherwise-impossible program states. Such behavior can lead to hard-to-reproduce bugs as well as introduce security vulnerabilities.

Swift provides memory safety with a combination of language affordances and runtime checking. However, Swift also deliberately includes some unsafe constructs, such as the `Unsafe` pointer types in the standard library, language features like `nonisolated(unsafe)`, and interoperability with unsafe languages like C. For most Swift developers, this is a pragmatic solution that provides an appropriate level of memory safety while not getting in the way.

However, some projects want to require stronger memory-safety guarantees than Swift provides by default. These projects want to pay closer attention to uses of unsafe constructs in their code, and discourage casual use of unsafe constructs when a safe alternative exists. This proposal introduces opt-in strict memory safety checking to identify those places in Swift code that make use of unsafe language constructs and APIs. Any code written within this strictly-safe subset also works as “normal” Swift and can interoperate with existing Swift code.

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

Swift achieves safety with a mixture of static and dynamic checks. Static checks are better when possible, because they are surfaced at compile time and carry no runtime cost. Dynamic checks are sometimes necessary and are still acceptable, so long as the failure can't escalate into a memory safety problem. Swift offers unsafe features to allow problems to be solved when neither static nor dynamic checks are sufficient. These unsafe features can still be used without compromising memory safety, but doing so requires more care because they have requirements that Swift can't automatically check.

For example, Swift solves null references with optional types. Statically, Swift prevents you from using an optional reference without checking it first. If you're sure it's non-null, you can use the `!` operator, which is safe because Swift will dynamically check for `nil`. If you really can't afford that dynamic check, you can use [`unsafelyUnwrapped`](https://developer.apple.com/documentation/swift/optional/unsafelyunwrapped). This can still be correct if you can prove that the reference is definitely non-null for some reason that Swift doesn't know. But it is an unsafe feature because it admits violations if you're wrong.

## Proposed solution

This proposal introduces an opt-in strict memory safety checking mode that identifies all uses of unsafe behavior within the given module. There are several parts to this change:

* A compiler flag `-strict-memory-safety` that enables warnings for all uses of unsafe constructs within a given module. All warnings will be in the diagnostic group `Unsafe`, enabling precise control over memory-safety-related warnings per [SE-0443](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md). When strict memory safety is enabled, the `StrictMemorySafety` feature will be set: `#if hasFeature(StrictMemorySafety)` can be used to detect when Swift code is being compiled in this mode.
* An attribute `@unsafe` that indicates that a declaration is unsafe to use. Such declarations may use unsafe constructs within their signatures. 
* A corresponding attribute `@safe` that indicates that a declaration whose signature contains unsafe constructs is actually safe to use. For example, the `withUnsafeBufferPointer` method on `Array` has an unsafe type in its signature (`self`), but is actually safe to use because it handles safety for the unsafe buffer pointer it vends to its closure argument. The closure itself will need to handle the unsafety when using that unsafe buffer pointer.
* An `unsafe` expression that marks any use of unsafe constructs in an expression, much like `try` and `await`.
* Standard library annotations to identify unsafe declarations.

### Example of `unsafe` usage

The `UnsafeBufferPointer` type will be marked with `@unsafe` in the Standard library, as will the other unsafe types (e.g., `UnsafePointer`, `UnsafeRawPointer`):

```swift
@unsafe 
public struct UnsafeBufferPointer<Element> { ... }
```

This indicates that use of this type is not memory-safe. Any declaration that has `UnsafeBufferPointer` as part of its type is also unsafe, and would produce a warning under this strict safety mode, e.g.,

```swift
// warning: reference to unsafe generic struct 'UnsafePointer'
func sumIntBuffer(_ address: UnsafePointer<Int>?, _ count: Int) -> Int { ... }
```

This warning can be suppressed by marking the function as `@unsafe`:

```swift
@unsafe
func sumIntBuffer(_ address: UnsafePointer<Int>?, _ count: Int, _ start: Int) -> Int { ... }
```

Users of this function that enable strict safety checking will see warnings when using it. For example:

```swift
extension Array<Int> {
  func sum() -> Int {
    withUnsafeBufferPointer { buffer in
      // warning: use of unsafe function 'sumIntBuffer' and unsafe property 'baseAddress'
      sumIntBuffer(buffer.baseAddress, buffer.count, 0)
    }
  }
}
```

Both the call to `sumIntBuffer` and access to the property `UnsafeBufferPointer.baseAddress` involve unsafe code, and therefore will produce a warning. Because `UnsafeBufferPointer` and `UnsafePointer` are `@unsafe` types, this code will get a warning regardless of whether the declarations were marked `@unsafe`, because having unsafe types in the signature of a declaration implies that they are `@unsafe`. This helps us identify more unsafe code even when the libraries we depend on haven't enabled strict safety checking themselves.

To suppress these warnings, the expressions involving unsafe code must be marked with `unsafe` in the same manner as one would mark a throwing expression with `try` or an asynchronous expression with `async`. The warning-free version of this code is:

```swift
extension Array<Int> {
  func sum() -> Int {
    withUnsafeBufferPointer { buffer in
      // warning: use of unsafe function 'sumIntBuffer' and unsafe property 'baseAddress'
      unsafe sumIntBuffer(buffer.baseAddress, buffer.count, 0)
    }
  }
}
```

The `unsafe` keyword here indicates the presence of unsafe code within that expression. As with `try` and `await`, it can cover multiple sources of unsafety within that expression: the call to `sumIntBuffer` is unsafe, as is the use of `buffer` and `buffer.baseAddress`, yet they are all covered by one `unsafe`. 

Unlike `try`, `unsafe` doesn't propagate outward: we do *not* require that the `sum` function be marked `@unsafe` just because it has unsafe code in it. Similarly, the call to `withUnsafeBufferPointer` doesn't have to be marked as `unsafe` just because it has a closure that is unsafe. The programmer may choose to indicate that `sum` is unsafe, but the assumption is that unsafe behavior is properly encapsulated when using `unsafe` if the signature doesn't contain any unsafe types.  

The function `Array.withUnsafeBufferPointer` has an unsafe type in its signature, because it passes an unsafe buffer pointer to its closure parameter. However, this function itself is addressing all of the memory-safety issues with providing such a pointer, and it's up to the closure itself to ensure that it is memory safe. Therefore, we mark `withUnsafeBufferPointer` with the `@safe` attribute to indicate that it iself is not introducing memory-safety issues:

```swift
extension Array {
  @safe func withUnsafeBufferPointer<R, E>(
    _ body: (UnsafeBufferPointer<Element>) throws(E) -> R
  ) throws(E) -> R
}
```

The new attributes `@safe` and `@unsafe`, as well as the `unsafe` expression, are all available in Swift regardless of whether strict safety checking is enabled, and all code using these features retains the same semantics. Strict safety checking will *only* produce diagnostics.

### A larger example: `swapAt` on unsafe pointers

The operation `UnsafeMutableBufferPointer.swapAt` swaps the values at the given two indices in the buffer. Under the proposed strict safety mode, it would look like this:

```swift
extension UnsafeMutableBufferPointer {
  @unsafe public func swapAt(_ i: Index, _ j: Index) {
    guard i != j else { return }
    precondition(i >= 0 && j >= 0)
    precondition(unsafe i < endIndex && j < endIndex)
    let pi = unsafe (baseAddress! + i)
    let pj = unsafe (baseAddress! + j)
    let tmp = unsafe pi.move()
    unsafe pi.moveInitialize(from: pj, count: 1)
    unsafe pj.initialize(to: tmp)
  }
}
```

The `swapAt` implementation uses a mix of safe and unsafe code. The code marked with `unsafe` identifies operations that Swift cannot verify memory safety for:

* Performing pointer arithmetic on `baseAddress`: Swift cannot reason about the lifetime of that underlying pointer, nor whether the resulting pointer is still within the bounds of the allocation.
* Moving and initializing the actual elements. The elements need to already be initialized.

The code itself has preconditions to ensure that the provided indices aren't out of bounds before performing the pointer arithmetic. However, there are other safety properties that cannot be checked with preconditions: that the memory associated with the pointer has been properly initialized, has a lifetime that spans the whole call, and is not being used simultaneously by any other part of the code. These safety properties are something that must be established by the *caller* of `swapAt`. Therefore, `swapAt` is marked `@unsafe` because callers of it need to reason about these properties.

### Incremental adoption

The strict memory safety checking proposed here enforces a subset of Swift. Code written within this subset must also be valid Swift code, and must interoperate with Swift code that does not use this strict checking. Compared to other efforts in Swift that introduce stricter checking or a subset, this mode is smaller and more constrained, providing better interoperability and a more gradual adoption curve:

* Strict concurrency checking, the focus of the Swift 6 language mode, required major changes to the type system, including the propagation of `Sendable` and the understanding of what code must be run on the main actor. These are global properties that don't permit local reasoning, or even local fixes, making the interoperability problem particularly hard. In contrast, strict safety checking has little or no effect on the type system, and unsafety can be encapsulated with `unsafe` expressions or ignored by a module that doesn't enable the checking.
* [Embedded Swift](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md) is a subset of Swift that works without a runtime. Like the proposed strictly-safe subset, code written in Embedded Swift will also work as regular Swift. Embedded Swift and the strict safety checking proposed here are orthogonal and can be composed to (for example) ensure that firmware written in Swift has no runtime and provides the best memory-safety guarantees.

A Swift module that adopts strict safety checking can address all of the resulting diagnostics by applying the `@unsafe` attribute and `unsafe` expression in the appropriate places, without changing any other code. This application of attributes can be automated through Fix-Its, making it possible to enable the mode and silence all diagnostics automatically. It would then be left to the programmer to audit those places that have used `unsafe` to encapsulate unsafe behavior, to ensure that they are indeed safe. Note that the strict safety checking does not by itself make the code more memory-safety: rather, it identifies those constructs that aren't safe, encouraging the use of safe alternatives and making it easier to audit for unsafe behavior.

The introduction of the `@unsafe` attribute on a declaration has no effect on clients compiled without strict safety enabled. For clients that have enabled strict safety, they will start diagnosing uses of the newly-`@unsafe` API. However, these diagnostics are warnings with their own diagnostic group, so a client can ensure that they do not prevent the client from building. Therefore, modules can adopt strict safety checking at their own pace (or not) and clients of those modules are never "stuck" having to make major changes in response.

## Detailed design

This section describes how the primary proposed constructs, the `@unsafe` attribute and `unsafe` expression, interact with the strict type checking mode, and enumerates the places in the language, standard library, and compiler that introduce non-memory-safe code. 

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

Module `B` uses the `DataWrapper` type. If compiled without strict safety checking, there will be no diagnostics about memory safety. If compiled with strict safety checking, there will be a diagnostic about `wrapper` using an `@unsafe` type (`DataWrapper`) in its interface. This diagnostic can be ignored, but ideally the `wrapper` property will be marked as `@unsafe` (silencing the warning).

If module `C` enables strict memory safety, the use of `MyType` is considered safe (since it was not marked `@unsafe` and doesn't involve unsafe types in its interface). However, the access to `wrapper` will result in a diagnostic, because the type of `wrapper` involves an `@unsafe` type. This diagnostic will occur whether or not `wrapper` has been explicitly marked `@unsafe`.

There are a few exemptions to the rule that any unsafe constructs within the signature require the declaration to be `@unsafe`:

* Local variables involving unsafe types do not need to be marked with `@unsafe`. For example, the local variable `base` will have unsafe type `UnsafePointer?`, but does not require `@unsafe` because every *use* of this local variable will need to be marked using the `unsafe` expression described in the next section.

  ```swift
  func sum(array: [Int]) -> Int {
    array.withUnsafeBufferPointer { buffer in
      /*@unsafe is unnecessary here*/ let base = unsafe buffer.baseAddress
      // ...
    }
  }
  ```

* Default arguments of functions are part of the implementation of a function, not its signature. For example, the following function does not have any unsafe types in its signature, so it does not require `@unsafe`, even though the default argument for `value` involves unsafe code. That unsafe code is effectively part of the body of the function, so it follows the rules for `unsafe` expressions.

  ```swift
  func hasDefault(value: Int = unsafe getIntegerUnsafely()) { ... }
  ```

### `@safe` attribute

Like the `@unsafe` attribute, the `@safe` attribute ise used on declarations whose signatures involve unsafe types. However, the `@safe` attribute means that the declaration is consider safe to use even though its signature includes unsafe types. For example, marking `UnsafeBufferPointer` as `@unsafe` means that all operations involving an unsafe buffer pointer are implicitly considered `@unsafe`. The `@safe` attribute can be used to say that those particular operations are actually safe. For example, any operation involving buffer indices or count are safe, because they don't touch the memory itself. This can be indicated by marking these APIs `@safe`:

```swift
extension UnsafeBufferPointer {
  @safe public let count: Int
  @safe public var startIndex: Int { 0 }
  @safe public var endIndex: Int { count }
}
```

For an array, the `withUnsafeBufferPointer` operation itself also involves the unsafe type that it passes along to the closure. The array itself takes responsibility for the memory safety of the unsafe buffer pointer it vends, ensuring that the elements have been initialized (which is always the case for array elements), that the bounds are correct, and that nobody else has access to the buffer when it is provided. From that perspective, `withUnsafeBufferPointer` itself can be marked `@safe`, and any unsafety will be in the closure's use of the `UnsafeBufferPointer`.

```swift
extension Array {
  @safe func withUnsafeBufferPointer<R, E>(
    _ body: (UnsafeBufferPointer<Element>) throws(E) -> R
  ) throws(E) -> R
}
```

A use of this API with the `c_library_sum_function` would look like this:

```swift
extension Array<Int> {
  func sum() -> Int {
    withUnsafeBufferPointer { buffer in
      unsafe c_library_sum_function(buffer.baseAddress, buffer.count, 0)
    }
  }
}
```

### `unsafe` expression

When a declaration is marked `@unsafe`, it is free to use any other unsafe types as part of its interface. Any time there is executable code that makes use of unsafe constructs, that code must be within an `unsafe` expression or it will receive a diagnostic about uses of unsafe code. In the example from the previous section, `wrapper` can be marked as `@unsafe` to suppress diagnostics by explicitly propagating unsafety to their clients:

```swift
// Module B
import A

public struct MyType {
  @unsafe public var wrapper: DataWrapper
}
```

However, the use of the `wrapper` property in module `C` will produce a diagnostic unless it is part of an `unsafe` expression, like this:

```swift
// Module C
import A
import B

extension MyType {
  public func checksum() -> Int32 {}
    return unsafe wrapper.checksum()
  }
}
```

The `unsafe` expression is much like `try` and `await`, in that it acknowledges that unsafe constructs (`wrapper`) are used within the subexpression but otherwise does not change the type. Unlike `try` and `await`, which require the enclosing context to handle throwing or be asynchronous, respectively, the `unsafe` expression does not imply any requirements about the enclosing block: it is purely a marker to indicate the presence of unsafe code, silencing a diagnostic.

### Unsafe language constructs

The following language constructs are always considered to be unsafe:

* `unowned(unsafe)`: Used to store a reference without maintaining its reference count. The safe counterpart, `unowned`, uses dynamic checking to ensure that the reference isn't accessed after the corresponding object has been released. The `unsafe` variant disables that dynamic checking. Uses of `unowned(unsafe)` entities are not memory-safe.
* `unsafeAddressor`, `unsafeMutableAddressor`: These accessors vend an unsafe pointer, and are therefore unsafe to declare. Other accessors (e.g., `get` and `set`) can provide safe alternatives. The accessors are considered to be part of the signature of the property or subscript they're associated with; the property should be marked either `@unsafe` or `@safe` to suppress the safety diagnostic on the declaration of an unsafe accessor.
* `@exclusivity(unchecked)`: Used to remove dynamic exclusivity checks from a particular variable, which can mean that dynamic exclusivity violations go undetected at run time, causing a memory safety violation. Uses of `@exclusivity(unchecked)` entities are not memory-safe.

The following language constructs are considered to be unsafe when strict concurrency checking is enabled (i.e., in the Swift 6 language mode):

* `nonisolated(unsafe)`: Allows a property to be accessed from concurrent code without ensuring that such accesses are done so safely. Uses of `nonisolated(unsafe)` entities are not memory-safe.
* `@preconcurrency` imports: Suppresses diagnostics related to data race safety when they relate to specific imported modules, which can introduce thread safety issues. The `@preconcurrency` import will need to be annotated with `@unsafe` in the strict safety mode.

### Unsafe standard library APIs

In the standard library, the following functions and types would be marked `@unsafe` :

* `Unsafe(Mutable)(Raw)(Buffer)Pointer`, `OpaquePointer`, `CVaListPointer`: These types provide neither lifetime nor bounds safety. Over time, Swift code is likely to move toward their safe replacements, such as `(Raw)Span`.
* `(Closed)Range.init(uncheckedBounds:)`: This operation makes it possible to create a range that doesn't satisfy invariants on which other bounds safety checking (e.g., in `Array.subscript`) relies.
* `Span.subscript(unchecked:)` : An unchecked subscript whose use can introduce bounds safety problems.
* `Unmanaged`: Wrapper over reference-counted types that explicitly disables reference counting, potentially introducing lifetime safety issues.
* `unsafeBitCast`: Allows type casts that are not known to be safe, which can introduce type safety problems.
* `unsafeDowncast`: An unchecked form of an `as!` cast that can introduce type safety problems.
* `Optional.unsafelyUnwrapped`: An unchecked form of the postfix `!` operation on optionals that can introduce various type, initialization, or lifetime safety problems when `nil` is interpreted as a typed value.
* `UnsafeContinuation`, `withUnsafe(Throwing)Continuation`: An unsafe form of `withChecked(Throwing)Continuation` that does not verify that the continuation is called exactly once, which can cause various safety problems.
* `withUnsafeCurrentTask` and `UnsafeCurrentTask`: The `UnsafeCurrentTask` type does not provide lifetime safety, and must only be used within the closure passed to `withUnsafeCurrentTask`.
* `UnownedSerialExecutor`: This type is intentionally not lifetime safe. It's primary use is the `unownedExecutor` property of the `Actor` protocol, which documents the lifetime assumptions of the `UnownedSerialExecutor` instance it produces.

All of these APIs will be marked `@unsafe`. For standard library APIs that involve unsafe types, those that are safe to use will be marked `@safe` while those that require the user to maintain some aspect of safety will be marked `@unsafe`. Unless mentioned above, standard library APIs that do not have an unsafe type in their signature, but use unsafe constructs in their implementation, will be considered to be safe.

### Unsafe compiler flags

There are a number of compiler flags that intentionally disable some safety-related checking. For each of these flags, the compiler will produce a diagnostic if they are used with strict memory safety:

* `-Ounchecked`, which disables some checking in the standard library, including (for example) bounds checking on array accesses.
* `-enforce-exclusivity=unchecked` and `-enforce-exclusivity=none`, which disables exclusivity checking that is needed for memory safety.
* `-strict-concurrency=` for anything other than "complete", because the memory safety model requires strict concurrency to eliminate thread safety issues.
* `-disable-access-control`, which allows one to break invariants of a type that can lead to memory-safety issues, such as breaking the invariant of `Range` that the lower bound not exceed the upper bound.

### Unsafe overrides

Overriding a safe method within an `@unsafe` one could introduce unsafety, so it will produce a diagnostic in the strict safety mode:

```swift
class Super {
  func f() { }
}

class Sub: Super {
  @unsafe override func f() { ... } // warning: override of safe instance method with unsafe instance method
}
```

to suppress this warning, the `Sub` class itself can be marked as `@unsafe`, e.g.,

```swift
@unsafe
class Sub: Super {
  override func f() { ... } // no more warning
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

The `unsafe` keyword in this proposal will be introduced as a contextual keyword following the precedent set by `await`'s' introduction in [SE-0296](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0296-async-await.md) and `consume`'s introduction in [SE-0366](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0366-move-function.md). This allows `unsafe` to continue to be used as an identifier, albeit with a small potential to break existing source that uses `unsafe` as a function that is then called with a trailing closure, like this:

```swift
func unsafe(_ body: () -> Void) { }

unsafe {
  // currently calls 'unsafe(_:)', but will become an unsafe expression
}
```

As with those proposals, the impact of this source break in expected to be small enough that it is acceptable. If not, the parsing of the `unsafe` expression can be limited to code that has enabled strict safety checking.

Other than the source break above, the introduction of this strict safety checking mode has no impact on source compatibility for any module that does not enable it. When enabling strict safety checking, source compatibility impact is limited to the introduction of warnings that will not break source compatibility (and can be treated as warnings even under `-warnings-as-errors` mode using the aforementioned diagnostic flags). The interoperability story is covered in detail in prior sections.

## ABI compatibility

The attributes, `unsafe` expression, and strict memory-safety checking model proposed here have no impact on ABI.

## Future Directions

### The `SerialExecutor` and `Actor` protocols

The `SerialExecutor` protocol provides a somewhat unique challenge for the strict memory safety mode. For one, it is impossible to implement this protocol with entirely safe code due to the presence of the `unownedExecutor` requirement:

```swift
protocol SerialExecutor: Executor {
  // ...
  @unsafe var unownedExecutor: UnownedSerialExecutor { get }
}
```

To make it possible to safely implement `SerialExecutor`, the protocol will need to be extended with a safe form of `unownedExecutor`, which itself will likely require a [non-escapable](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md) form of `UnownedSerialExecutor` to provide lifetime safety without introducing any overhead. The `Actor` protocol has the same `unownedExecutor` requirement, so it will need the corresponding safe variant. The Swift implementation will need to start using this new requirement for scheduling work on actors to eliminate the implicit use of unsafe constructs.

The `SerialExecutor` protocol has additional semantic constraints involving the serial execution of the jobs provided to the executor. While conformance to any protocol implies that the conforming type meets the documented semantic requirements, `SerialExecutor` is unique in that the data-race safety model (and therefore the memory safety model) depends on it correctly implementing these semantics: a conforming type that currently executes two jobs will create memory-safety violations. There are a few options for addressing this:

* The `SerialExecutor` protocol itself could be marked `@unsafe`, meaning that any use of this protocol must account for unsafety.
* Some requirements of the `SerialExecutor` protocol (such as the replacement for `unownedExecutor`) could be marked `@unsafe`, so any use of this protocol's requirements must account for unsafety.
* Conformance to the `SerialExecutor` protocol could require some attestation (such as `@safe(unchecked)`) to make it clear from the source code that there is some unsafety encapsulated in the conformance.

The first two options are the most straightforward, but the fact that actors have implicit uses of `SerialExecutor` means that it would effectively make every actor `@unsafe`. This pushes the responsibility for acknowledging the memory unsafety to clients of `SerialExecutor`, rather than at the conforming type where the responsibility for a correct implementation lies. The third option appears best, because it provides an auditable place to assert memory safety that corresponds with where extra care must be taken to avoid introducing a problem.

It is unclear whether `SerialExecutor` is or will be the only protocol of this nature. If there are others, it could be worth providing a special form of the `@unsafe` attribute on the protocol itself, such as `@unsafe(conforms)`, that is only considered unsafe for conforming types.

### Handling of `@unsafe` cases

When an enum case is explicitly marked `@unsafe`, but involves no associated data that is unsafe, this proposal doesn't have a way to suppress safety diagnostics when pattern matching that case. For example:

```swift
enum WeirdAddress {
  @unsafe case rawOffsetIntoGlobalArray(Int)
}

func example(_ address: WeirdAddress) {
  if case .rawOffsetIntoGlobalArray(let offset) = weirdAddress { // reference to @unsafe case rawOffsetIntoGlobalArray that can't be suppressed
  }
}

```

We have several options here:

* We could suppress the diagnostic for this use of an `@unsafe case`. One would still get diagnostics when constructing such a case.

* We could reject `@unsafe` on case declarations that don't involve any unsafe types.

* We could extend the pattern grammar with an `unsafe` pattern to suppress this diagnostic, e.g.,
  ```swift
  if case unsafe .rawOffsetIntoGlobalArray(let offset) = weirdAddress { ... }
  ```

## Alternatives considered

### `@unsafe` implying `unsafe` throughout a function body

A function marked `@unsafe` is unsafe to use, so any clients that have enabled strict safety checking will need to put uses of the function into an `unsafe` expression. The implementation of that function is likely to use unsafe code (possibly a lot of it), which could result in a large number of annotations:

```swift
extension UnsafeMutableBufferPointer {
  @unsafe public func swapAt(_ i: Index, _ j: Index) {
    guard i != j else { return }
    precondition(i >= 0 && j >= 0)
    precondition(unsafe i < endIndex && j < endIndex)
    let pi = unsafe (baseAddress! + i)
    let pj = unsafe (baseAddress! + j)
    let tmp = unsafe pi.move()
    unsafe pi.moveInitialize(from: pj, count: 1)
    unsafe pj.initialize(to: tmp)
  }
}
```

We could choose to make `@unsafe` on a function acknowledge all uses of unsafe code within its definition. For example, this would mean that marking `swapAt` with `@unsafe` means that one need not have any `unsafe` expressions in its body:

```swift
extension UnsafeMutableBufferPointer {
  @unsafe public func swapAt(_ i: Index, _ j: Index) {
    guard i != j else { return }
    precondition(i >= 0 && j >= 0)
    precondition(i < endIndex && j < endIndex)
    let pi = (baseAddress! + i)
    let pj = (baseAddress! + j)
    let tmp = pi.move()
    pi.moveInitialize(from: pj, count: 1)
    pj.initialize(to: tmp)
  }
}
```

This approach reduces the annotation burden in unsafe code, but makes it much harder to tell exactly what  aspects of the implementation are unsafe. Indeed, even unsafe functions should still strive to minimize the use of unsafe constructs, and benefit from having the actual unsafe behavior marked in the source. It also conflates the notion of "exposes an unsafe interface" from "has an unsafe implementation". 

Rust's `unsafe` functions have this behavior, where an `unsafe fn` in Rust implies an `unsafe { ... }` block around the entire function body. [Rust RFC #2585](https://rust-lang.github.io/rfcs/2585-unsafe-block-in-unsafe-fn.html)  argues for Rust to remove this behavior; the motivation there generally applies to Swift as well.

### Making "encapsulation" of unsafe behavior explicit

In the proposed design, a function with no unsafe types in its signature is considered safe unless the programmer explicitly marked it `@unsafe`. The implementation may contain any amount of unsafe code, so long as it is covered by an `unsafe` expression:

```swift
extension Array<Int> {
  // this function is considered safe
  func sum() -> Int {
    withUnsafeBufferPointer { buffer in
      unsafe sumIntBuffer(buffer.baseAddress, buffer.count, 0)
    }
  }
}
```

This differs somewhat from the way in which throwing and asynchronous functions work. A function that has a `try` or `await` in the body needs to be `throws` or `async`, respectively. Essentially, the effect from the body has to also be reflected in the signature. With unsafe code, this could mean that having `unsafe` expressions in the function body requires you to either make the function `@unsafe` or use some other suppression mechanism to acknowledge that you are using unsafe constructs to provide a safe interface.

There are several options for such a suppression mechanism. An attribute form, `@safe(unchecked)`, is described below as an alternative to the `unsafe` expression. Another approach would be to provide an `unsafe!` form the `unsafe` expression, which (like `try!`) acknowledges the effect but doesn't propagate that effect out to the function. For the `sum` function, it would be used as follows:

```swift
extension Array<Int> {
  // this function is considered safe
  func sum() -> Int {
    withUnsafeBufferPointer { buffer in
      unsafe! sumIntBuffer(buffer.baseAddress, buffer.count, 0)
    }
  }
}
```

This proposal chooses not to go down this path, because having a function signature involving no unsafe types is already a strong indication that the function is providing a safe interface, and there is little to be gained from requiring additional ceremony (whether an attribute like `@safe(unchecked)` or the `unsafe!` form described above).

### `@safe(unchecked)` attribute to allow unsafe code

Early iterations of this proposal introduced a `@safe(unchecked)` attribute as an alternative to `unsafe` expressions. The `@safe(unchecked)` attribute would be placed on a function to suppress diagnostics about use of unsafe constructs within its definition. This has all of the same downsides as having `@unsafe` imply cover for all of the uses of unsafe code within the body of a function, albeit while providing a safe interface.

### `unsafe` blocks

The `unsafe` expression proposed here  covers unsafe constructs within a single expression. For unsafe-heavy code, this can introduce a large number of `unsafe` keywords. There is an alternative formulation for acknowledging unsafe code that is used in some peer languages like C# and Rust: an `unsafe` block, which is a statement that suppresses diagnostics about uses of unsafe code within it. For example:

```swift
extension UnsafeMutableBufferPointer {
  @unsafe public func swapAt(_ i: Index, _ j: Index) {
    guard i != j else { return }
    precondition(i >= 0 && j >= 0)
    precondition(i < endIndex && j < endIndex)
    unsafe {
      let pi = (baseAddress! + i)
      let pj = (baseAddress! + j)
      let tmp = pi.move()
      pi.moveInitialize(from: pj, count: 1)
      pj.initialize(to: tmp)
    }
  }
}
```

For Swift, an `unsafe` block would be a statement that can also be used as an expression when its body is an expression, much like `if` or `switch` expressions following [SE-0380](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0380-if-switch-expressions.md).

`unsafe` blocks are more coarse-grained than the proposed `unsafe` expressions, which represents a trade-off: `unsafe` blocks will be less noisy for unsafe-heavy code, because one `unsafe { ... }` can cover a lot of code. On the other hand, doing so hides which code within the block is actually unsafe, making it harder to audit the unsafe parts. In languages that have `unsafe` blocks, it's considered best practice to make the `unsafe` blocks as narrow as possible. The proposed `unsafe` expressions enforce that best practice at the language level.

### Strictly-safe-by-default

This proposal introduced strict safety checking as an opt in mode and not an [*upcoming* language feature](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0362-piecemeal-future-features.md) because there is no intent to make this feature the default behavior in a future language mode. There are several reasons why this checking should remain an opt-in feature for the foreseeable future:

* The various `Unsafe` pointer types are the only way to work with contiguous memory in Swift today, and  the safe replacements (e.g., `Span`) are new constructs that will take a long time to propagate through the ecosystem. Some APIs depending on these `Unsafe` pointer types cannot be replaced because it would break existing clients (either source, binary, or both).
* Interoperability with the C family of languages is an important feature for Swift. Most C(++) APIs are unlikely to ever adopt the safety-related attributes described above, which means that enabling strict safety checking by default would undermine the usability of C(++) interoperability.
* Swift's current (non-strict) memory safety by default is likely to be good enough for the vast majority of users of Swift, so the benefit of enabling stricter checking by default is unlikely to be worth the disruption it would cause.

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
  public var byteSpan: RawSpan
}
```

Clients using the existing `bytes` will continue to work, and those that care about memory safety can choose to move to `byteSpan`. All of this works, but is somewhat annoying because the good name, `bytes`, has been taken for the API we no longer want to use.

Swift does allow type-based overloading, including on the type of properties, so one could introduce an overloaded `bytes` property, like this:

```swift
extension DataPacket {
  public var bytes: RawSpan
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

### Optional `message` for the `@unsafe` attribute

We could introduce an optional `message` argument to the `@unsafe` attribute, which would allow programmers to indicate *why* the use of a particular declaration is unsafe and, more importantly, how to safely write code that uses it. However, this argument isn't strictly necessary: a comment could provide the same information, and there is established tooling to expose comments to programmers that wouldn't be present for this attribute's message, so we have omitted this feature.

## Acknowledgments

This proposal has been greatly improved by the feedback from Félix Cloutier, Geoff Garen, Gábor Horváth, Frederick Kellison-Linn, Karl Wagner, and Xiaodi Wu.
