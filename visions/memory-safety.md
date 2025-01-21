# Optional Strict Memory Safety for Swift

Swift is a memory-safe language *by default* , meaning that the major language features and standard library APIs are memory-safe. However, it is possible to opt out of memory safety when it’s pragmatic using certain “unsafe” language or library constructs. This document proposes a path toward an optional “strict” subset of Swift that prohibits any unsafe features. This subset is intended to be used for Swift code bases where memory safety is an absolute requirement, such as security-critical libraries.

This document is an official feature [vision document](https://forums.swift.org/t/the-role-of-vision-documents-in-swift-evolution/62101). The Language Steering Group has endorsed the goals and basic approach laid out in this document. This endorsement is not a pre-approval of any of the concrete proposals that may come out of this document. All proposals will undergo normal evolution review, which may result in rejection or revision from how they appear in this document.

## Introduction

[Memory safety](https://en.wikipedia.org/wiki/Memory_safety) is a popular topic in programming languages nowadays. Essentially, memory safety is a property that prevents programmer errors from manifesting as [undefined behavior](https://en.wikipedia.org/wiki/Undefined_behavior) at runtime. Undefined behavior effectively breaks the semantic model of a language, with unpredictable results including crashes, data corruption, and otherwise-impossible program states. Much of the recent focus on memory safety is motivated by security, because memory safety issues offer a fairly direct way to compromise a program: in fact, the lack of memory safety in C and C++ has been found to be the root cause for ~70% of reported security issues in various analyses [[1](https://msrc.microsoft.com/blog/2019/07/a-proactive-approach-to-more-secure-code/)][[2](https://www.chromium.org/Home/chromium-security/memory-safety/)].

### Memory safety in Swift

While there are a number of potential definitions for memory safety, the one provided by [this blog post](https://security.apple.com/blog/towards-the-next-generation-of-xnu-memory-safety/) breaks it down into five dimensions of safety:

* **Lifetime safety** : all accesses to a value are guaranteed to occur during its lifetime. Violations of this property, such as accessing a value after its lifetime has ended, are often called use-after-free errors.
* **Bounds safety**: all accesses to memory are within the intended bounds of the memory allocation, such as accessing elements in an array. Violations of this property are called out-of-bounds accesses.
* **Type safety** : all accesses to a value use the type to which it was initialized, or a type that is compatible with that type. For example, one cannot access a `String` value as if it were an `Array`. Violations of this property are called type confusions.
* **Initialization safety** : all values are initialized property to being used, so they cannot contain unexpected data. Violations of this property often lead to information disclosures (where data that should be invisible becomes available) or even other memory-safety issues like use-after-frees or type confusions.
* **Thread safety:** all values are accessed concurrently in a manner that is synchronized sufficiently to maintain their invariants. Violations of this property are typically called data races, and can lead to any of the other memory safety problems.

Since its inception, Swift has provided memory safety for the first four dimensions. Lifetime safety is provided for reference types by automatic reference counting and for value types via [memory exclusivity](https://www.swift.org/blog/swift-5-exclusivity/); bounds safety is provided by bounds-checking on `Array` and other collections; type safety is provided by safe features for casting (`as?` , `is` ) and `enum` s; and initialization safety is provided by “definite initialization”, which doesn’t allow a variable to be accessed until it has been defined. Swift 6’s strict concurrency checking extends Swift’s memory safety guarantees to the last dimension.

Providing memory safety does not imply the absence of run-time failures. Good language design often means defining away runtime failures in the type system. However, memory safely requires only that an error in the program cannot be escalated into a violation of one of the safety properties. For example, having reference types be non-nullable by default defines away most problems with NULL pointers. With explicit optional types, the force-unwrap operator (postfix `!` ) meets the definition of memory safety by trapping at runtime if the unwrapped optional is `nil` . The standard library also provides the [`unsafelyUnwrapped` property](https://developer.apple.com/documentation/swift/optional/unsafelyunwrapped) that does not check for `nil` in release builds: this does not meet the definition of memory safety because it admits violations of initialization and lifetime safety that could be exploited.

### Unsafe code

Swift is a memory-safe language *by default* , meaning that the major language features and standard library APIs are memory-safe. However, there exist opt-outs that allow one to write memory-unsafe code in Swift:

* Language features like `unowned(unsafe)` and `nonisolated(unsafe)` that disable language safety features locally.
* Library constructs like `UnsafeMutableBufferPointer` or `unsafeBitCast(to:)` that provide lower-level access than existing language constructs provide.
* Interoperability with C-family APIs, which are implemented in a non-memory-safe language and tend to traffic in unsafe pointer types.

The convention of using `unsafe` or `unchecked` in the names of unsafe constructs works fairly well in practice: memory-unsafe code in Swift tends to sticks out because of the need for `withUnsafe<...>` operations, and for large swaths of Swift code there is no need to reach down for the unsafe APIs.

However, the convention is not entirely sufficient for identifying all Swift code that makes use of unsafe constructs. For example, it is possible to call the C `memcpy` directly from Swift as, e.g., `memcpy(&to, &from, numBytes)` , which can easily violate memory-safety along any dimension: `to` and `from` might be arrays with incompatible types, the number of bytes might be incorrect, etc. However, “unsafe” or “unchecked” do not appear in this code except as the (unseen) type of the parameters to `memcpy` .

Moreover, some tasks require lower-level access to memory that is only expressible today via the unsafe pointer types, meaning that one must choose between using only safe constructs, or having access to certain APIs and optimizations. For example, all access to contiguous memory requires an `UnsafeMutableBufferPointer` , which compromises on both lifetime and bounds safety. However, it fulfills a vital role for various systems-programming tasks, including interacting directly with specialized hardware or using lower-level system libraries written in the C family.

## Strictly-safe subset of Swift

Swift’s by-default memory safety is a pragmatic choice that provides the benefits of memory safety to most Swift code while not requiring excessive ceremony for those places where some code needs to drop down to use unsafe constructs. However, there are code bases where memory safety is more important than programmer convenience, such as in security-critical subsystems handling untrusted data or that are executing with elevated privileges in an OS.

For such code bases, it’s important to ensure that the code is staying within the strictly-safe subset of Swift. This can be accomplished with a compiler option that produces an error for any use of unsafe code, whether it’s an unsafe language feature or unsafe library construct. Any code written within this strictly-safe subset also works as “normal” Swift and can interoperate with existing Swift code.

The compiler would flag any use of the following unsafe language features:

* `@unchecked Sendable`
* `unowned(unsafe)`
* `nonisolated(unsafe)`
* `unsafeAddressor`, `unsafeMutableAddressor`

In addition, an `@unsafe` attribute would be added to the language and would be used to mark any declaration that is unsafe to use. In the standard library, the following functions and types would be marked `@unsafe` :

* `Unsafe(Mutable)(Raw)(Buffer)Pointer`
* `(Closed)Range.init(uncheckedBounds:)`
* `OpaquePointer`
* `CVaListPointer`
* `Unmanaged`
* `unsafeBitCast`, `unsafeDowncast`
* `Optional.unsafelyUnwrapped`
* `UnsafeContinuation`, `withUnsafe(Throwing)Continuation`
* `UnsafeCurrentTask`
* `Mutex`'s `unsafeTryLock`, `unsafeLock`, `unsafeUnlock`
* `VolatileMappedRegister.init(unsafeBitPattern:)`
* The `subscript(unchecked:)` introduced by the `Span` proposal.

Any use of these APIs would be flagged by the compiler as a use of an unsafe construct. In addition to the direct `@unsafe` annotation, any API that uses an `@unsafe` type is considered to itself be unsafe. This includes C-family APIs that use unsafe types, such as the aforementioned `memcpy` that uses `Unsafe(Mutable)RawPointer` in its signature:

```swift
func memcpy(
  _: UnsafeMutableRawPointer?,
  _: UnsafeRawPointer?,
  _: Int
) -> UnsafeMutableRawPointer?
```

The rules described above make it possible to detect and report the use of unsafe constructs in Swift.

An `@unsafe` function is allowed to use other unsafe constructs. As such, a Swift module compiled in the strictly-safe subset can contain both safe and unsafe code, but all unsafe code is marked by `@unsafe`. A client of the module can opt to use only the safe parts of that module, potentially using the strict safety checking to ensure this.

### Wrapping unsafe behavior in safe APIs

There should also be a way to wrap unsafe behavior into safe APIs. For example, the standard library's `Array` and [`Span`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md) are necessarily implemented from unsafe primitives, such as `UnsafeRawPointer`, but expose primarily safe APIs. For example, the `Span` type could be defined like this:

```swift
public struct Span<Element: ~Copyable & ~Escapable>: ~Escapable, Copyable, BitwiseCopyable {
  internal let buffer: UnsafeBufferPointer<Element>
}
```

The subscript operation is safe, but necessarily uses `buffer`, which has an `@unsafe` type. Its implementation must acknowledge that it is using unsafe constructs internally, but that it does so in a manner that preserves safety for clients. There are several potential syntaxes, including an `unsafe { ... }` code block, which could look like this:

```swift
public subscript(_ position: Int) -> Element {
  get {
    unsafe {
      precondition(position >= 0 && position < buffer.count)
      return buffer[position]
    }
  }
}
```

Alternatively, Swift could provide a `@safe(unchecked)` attribute that states that a particular API is safe, but that its safety cannot be checked by the compiler, akin to `@unchecked Sendable` conformances:

```swift
public subscript(_ position: Int) -> Element {
  @safe(unchecked) get {
    precondition(position >= 0 && position < buffer.count)
    return buffer[position]
  }
}
```

The specific syntax chosen will be the subject of a specific proposal, and need not be determined by this  document. Regardless, a Swift module that enables strict safety checking must limit its use of unsafe constructs to `@unsafe` declarations or those parts of the code that have acknowledged local use of unsafe constructs.

### Auditability

The aim of optional strict memory safety for Swift is to make it possible to write Swift that avoids unintentional use of unsafe constructs while not preventing their use entirely. To aid projects that wish to set a higher bar for memory safety, such as permitting no unsafe constructs outside of the standard library or requiring additional code review for any uses of unsafe constructs, Swift tooling should provide a way to audit the uses of unsafe constructs within an entire project (including its dependencies). An auditing tool should be able to identify and report Swift modules that were compiled without strict memory safety as well as all of the places where the opt-out mechanism (e.g., `unsafe { ... }` blocks or `@safe(unchecked)`) is used in modules that do opt in to strict memory safety.

## Improving the expressibility of strictly-safe Swift

The following sections describe language features and library constructs that improve on what can be expressed within the strictly-safe subset of Swift. These improvements will also benefit Swift in general, making it easier to correctly work with contiguous memory and interoperate with APIs from the C-family on languages.

### Accessing contiguous memory

Nearly every “unsafe” language feature and standard library API described in the previous section already has safe counterparts in the language: safe concurrency patterns via actors and `Mutex` , safe casting via `as?` , runtime-checked access to optionals (via `!` ) and continuations (`withChecked(Throwing)Continuation` ), and so on.

One of the primary places where this doesn’t hold is with low-level access to contiguous memory. Even with `ContiguousArray` , which stores its elements contiguously, the only way to access elements is either one-by-one (e.g., subscripting) or to use an operation like `withUnsafeBufferPointer` that provides temporary access the storage via an `Unsafe(Mutable)BufferPointer` argument to a closure. These APIs are memory-unsafe along at least two dimensions:

* **Lifetime safety**: the unsafe buffer pointer should only be used within the closure, but there is no checking to establish that the pointer does not escape the closure. If it does escape, it could be used after the closure has returned and the pointer could have effectively been “freed.”
* **Bounds safety**: the unsafe buffer pointer types do not perform bounds checking in release builds.

[Non-escapable types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md) provide the ability to create types whose instances cannot escape out of the context in which they were created with no runtime overhead. Non-escapable types allow the creation of a [memory-safe counterpart to the unsafe buffer types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md), `Span` . With `Span` , it becomes possible to access contiguous memory in an array in a manner that maintains memory safety. For example:

```swift
let span = myInts.storage

globalSpan = span // error: span value cannot escape the scope of myInts
print(span[myArray.count]) // runtime error: out-of-bounds access
print(span.first ?? 0)
```

[Lifetime dependencies](https://github.com/swiftlang/swift-evolution/pull/2305) can greatly improve the expressiveness of non-escaping types, making it possible to build more complex data structures while maintaining memory safety.

### Expressing memory-safe interfaces for the C family of languages

The C family of languages do not provide memory safety along any of the dimensions described in this document. As such, a Swift program that makes use of C APIs is never fully “memory safe” in the strict sense, because any C code called from Swift could undermine the memory safety guarantees Swift is trying to provide. Requiring that all such C code be rewritten in Swift would go against Swift’s general philosophy of incremental adoption into existing ecosystems. Therefore, this document proposes a different strategy: code written in Swift will be auditably memory-safe so long as the C APIs it uses follow reasonable conventions with respect to memory safety. As such, writing new code (or incrementally rewriting code from the C family) will not introduce new memory safety bugs, so that adopting Swift in an existing code base will incrementally improve on memory safety. This approach is complementary to any improvements made to memory safety within the C family of languages, such as [bounds-safety checks for C](https://clang.llvm.org/docs/BoundsSafety.html) or [C++ standard library hardening](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2024/p3471r0.html).

In the C family of languages, the primary memory safety issue for APIs is the widespread use of pointers that have neither lifetime annotations (who owns the pointer?) nor bounds annotations (how many elements does it point to?). As such, the pointers used in C APIs are reflected in Swift as unsafe pointer types, as shown above with `memcpy` .

Despite the lack of this information, C APIs often follow a reasonable set of conventions that make them usable in Swift without causing memory-safety problems. Swift has a long history of utilizing annotations in C headers to describe these conventions and improve the projection of C APIs into Swift, including:

* Nullability annotations (`_Nullable`, `_Nonnull`) that describe what values can be NULL, and affects whether a C type is reflected as optional in Swift.
* Non-escaping annotations (e.g., `__attribute__((noescape))`) on block pointer parameters, which results in them being imported as non-escaping function parameters.
* `@MainActor` and `Sendable` annotations on C APIs that support Swift 6’s data-race safety model.

To provide safer interoperability with C APIs, additional annotations can be provided in C that Swift can use to project those C APIs into Swift APIs without any use of unsafe pointers. For example, the Clang [bounds-safety attributes](https://clang.llvm.org/docs/BoundsSafety.html) allow one to express when a C pointer’s size is described by another value:

```cpp
double average(const double *__counted_by(N) ptr, int N);
```

Today, this function would be projected into a Swift function like the following:

```swift
/*@unsafe*/ func average(_ ptr: UnsafePointer<Double>!, _ N: CInt) -> Double
```

However, Swift could use the `__counted_by` attribute to provide a more convenient API that bundles the count and length together, e.g.,

```swift
/*@unsafe*/ func average(_ ptr: UnsafeBufferPointer<Double>) -> Double
```

Now, a Swift caller that passes a local `Double` array would not need to pass the count separately, and cannot get it wrong:

```swift
var values = [3.14159, 2.71828]
average(values) // ok, no need to pass count separately
```

This call is still technically unsafe, because we’re passing a temporary pointer into the array’s storage down to the `average` function. That function could save that pointer into some global variable that gets accessed some time after the call, causing a memory safety violation. The actual implementation of `average` is unlikely to do so, and could express this constraint using the existing `noescape` attribute as follows:

```cpp
double average(const double *__counted_by(N) __attribute__((noescape)) ptr, int N);
```

The `average` function is now expressing that it takes in a `double` pointer referencing `count` values but will not retain the pointer beyond the call. These are the semantic requirements needed to provide a memory-safe Swift projection as follows:

```swift
func average(_ ptr: Span<Double>) -> Double
```

More expressive Swift lifetime features can also have corresponding C annotations, allowing more C APIs to be reflected into safe APIs in Swift. For example, consider a C function that finds the minimal element in an array and returns a pointer to it:

```cpp
const double *min_element(const double *__counted_by(N) __attribute__((noescape)) ptr, int N);
```

The returned pointer will point into the buffer passed in, so its lifetime is tied to that of the pointer argument. The aforementioned [lifetime dependencies proposal](https://github.com/swiftlang/swift-evolution/pull/2305) allows this kind of dependency to be expressed in Swift, where the resulting non-escaping value (e.g., a `Span` containing one element) has its lifetime tied to the input argument. Clang provides a [`lifetimebound`](https://clang.llvm.org/docs/AttributeReference.html#id11) attribute that expresses when a return value refers into memory associated with one of the parameters, which offers one way to express this lifetime relationship for C APIs:

```c
const double * _Nullable __counted_by(1)
min_element(const double *__counted_by(N) __attribute__((noescape)) __attribute__((lifetimebound)) ptr, int N);
```

The result could be the following memory-safe Swift API:

```swift
@lifetime(ptr) func min_element(_ ptr: Span<Double>) -> Span<Double>?
```

### Affordances for C++ interoperability

C++ offers a number of further opportunities for improved safety by modeling lifetimes. For example, `std::vector<T>` has a `front()` method that returns a reference to the element at the front of the vector:

```cpp
const T& front() const;
```

The returned reference is valid so long as the vector instance still exists and has not been modified since the call to `front()`. Describing that lifetime dependency in C++ (for example, with the aforementioned `lifetimebound` attribute) would lead to a safe mapping of this API into Swift without the need to introduce an extra copy of the returned element, improving both safety and, potentially, performance.

The C++ [`std::span`](https://en.cppreference.com/w/cpp/container/span) type is similar to the Swift `Span` type, in that it also carries both a pointer and bounds to describe a region of memory. However, `std::span` doesn't provide lifetime safety, so it is essentially an unsafe type from the Swift perspective. The same C attributes that provide lifetime safety for C pointers and references could be applied to `std::span` instances to provide safe Swift projections of C++ APIs. For example, the following annotated C++ API:

```c++
std::span<char> substring_match(
    std::span<char> sequence [[clang::lifetimebound]],
    std::span<char> subsequence [[clang::noescape]]
);
```

could be imported into Swift as:

```swift
@lifetime(sequence)
func substring_match(_ sequence: Span<CChar>, _ subsequence: Span<CChar>) -> Span<CChar>
```

## Incremental adoption

The introduction of any kind of additional checking into Swift requires a strategy that accounts for the practicalities of adoption within the Swift ecosystem. Different developers adopt new features on their own schedules, and some Swift code will never enable new checking features. Therefore, it is important that a given Swift module can adopt the proposed strict safety checking without requiring any module it depends on to have already done so, and without breaking any of its own clients that have not enabled strict safety checking.

The optional strict memory safety model proposed by this  lends itself naturally to incremental adoption. The proposed `@unsafe` attribute is not part of the type of the declaration it is applied to, and therefore does not propagate through the type system in any manner. Additionally, any use of an unsafe construct can be addressed locally, either by encapsulating it (e.g., via `@safe(unchecked)`) or propagating it (with `@unsafe`). This means that a module that has not adopted strict safety checking will not see any diagnostics related to this checking, even when modules it depends on adopt strict safety checking.

The strict memory safety checking does not require any changes to the binary interface of a module, so it can be retroactively enabled (including `@unsafe` annotations) with no ABI or back-deployment concerns. Additionally, it is independent of other language subsetting approaches, such as Embedded Swift.

## Should strict memory safety checking become the default?

This  proposes that the strict safety checking described be an opt-in feature with no path toward becoming the default behavior in some future language mode. There are several reasons why this checking should remain an opt-in feature for the foreseeable future:

* The various `Unsafe` pointer types are the only way to work with contiguous memory in Swift today, and  the safe replacements (e.g., `Span`) are new constructs that will take a long time to propagate through the ecosystem. Some APIs depending on these `Unsafe` pointer types cannot be replaced because it would break existing clients (either source, binary, or both).
* Interoperability with the C family of languages is an important feature for Swift. Most C(++) APIs are unlikely to ever adopt the safety-related attributes described above, which means that enabling strict safety checking by default would undermine the usability of C(++) interoperability.
* Swift's current (non-strict) memory safety by default is likely to be good enough for the vast majority of users of Swift, so the benefit of enabling stricter checking by default is unlikely to be worth the disruption it would cause.
* The auditing facilities described in this vision should be sufficient for Swift users who require strict memory safety, to establish where unsafe constructs are used and prevent "backsliding" where their use grows in an existing code base. These Swift users are unlikely to benefit much from strict safety being enabled by default in a new language mode, aside from any additional social pressure that would create on Swift programmers to adopt it.
