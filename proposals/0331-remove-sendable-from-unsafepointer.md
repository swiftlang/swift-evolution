# Remove Sendable conformance from unsafe pointer types

* Proposal: [SE-0331](0331-remove-sendable-from-unsafepointer.md)
* Authors: [Andrew Trick](https://github.com/atrick)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Active review (November 29...December 10, 2021)**

* Implementation: [apple/swift#39218](https://github.com/apple/swift/pull/39218)

## Introduction

[SE-0302](0302-concurrent-value-and-concurrent-closures.md) introduced the `Sendable` protocol, including `Sendable` requirements for various language constructs, conformances of various standard library types to `Sendable`, and inference rules for non-public types to implicitly conform to `Sendable`. SE-0302 states that the unsafe pointer types conform to `Sendable`:

> `Unsafe(Mutable)(Buffer)Pointer`: these generic types _unconditionally_ conform to the `Sendable` protocol. This means that an unsafe pointer to a non-Sendable value can potentially be used to share such values between concurrency domains. Unsafe pointer types provide fundamentally unsafe access to memory, and the programmer must be trusted to use them correctly; enforcing a strict safety rule for one narrow dimension of their otherwise completely unsafe use seems inconsistent with that design.

Experience with `Sendable` shows that this formulation is unnecessarily dangerous and has unexpected negative consequences for implicit conformance.

Swift-evolution thread: [Discussion thread](https://forums.swift.org/t/unsafepointer-sendable-should-be-revoked/51926)

## Motivation

The role of `Sendable` is to prevent sharing reference-semantic types across actor or task boundaries. Unsafe pointers have reference semantics, and therefore should not be be `Sendable`.

Unsafe pointers are unsafe in one primary way: it is the developer's responsibility to guarantee the lifetime of the memory referenced by the unsafe pointer. This is an intentional and explicit hole in Swift's memory safety story that has been around since the beginning. That well-understood form of unsafety should not be implicitly extended to allow pointers to be unsafely used in concurrent code. The concurrency diagnostics that prevent race conditions in other types with reference semantics should provide the same protection for pointers.

Another problem with making the unsafe pointers `Sendable` is the second-order effect it has on value types that store unsafe pointers. Consider a wrapper struct around a resource:

```swift
struct FileHandle { // implicitly Sendable
  var stored: UnsafeMutablePointer<File>
}
```

The `FileHandle` type will be inferred to be `Sendable` because all of its instance storage is `Sendable`. Even if we accept that an `UnsafeMutablePointer` by itself can be `Sendable ` because the "unsafe" can now apply to concurrency safety as well (as was argued in SE-0302), that same argument does not hold for the `FileHandle` type. Removing the conformance of the unsafe pointer types to `Sendable` eliminates the potential for it to propagate out to otherwise-safe wrappers.

## Proposed solution

Remove the `Sendable` conformance introduced by SE-0302 for the following types:

* `AutoreleasingUnsafeMutablePointer`
* `OpaquePointer`
* `CVaListPointer`
* `Unsafe(Mutable)?(Raw)?(Buffer)?Pointer`
* `Unsafe(Mutable)?(Raw)?BufferPointer.Iterator`

## Source compatibility

The removal of `Sendable` conformances from unsafe pointer types can break code that depends on those conformances. There are two mitigating factors here that make us feel comfortable doing so at this time. The first mitigating factor is that `Sendable` is only very recently introduced in Swift 5.5, and `Sendable` conformances aren't enforced in the Swift Concurrency model just yet. The second is that the staging in of `Sendable` checking in the compiler implies that missing `Sendable` conformances are treated as warnings, not errors, so there is a smooth transition path for any code that depended on this now-removed conformances.

## Effect on ABI stability

`Sendable` is a marker protocol, which was designed to have zero ABI impact. Therefore, this proposal itself should have no ABI impact, because adding and removing `Sendable` conformances is invisible to the ABI.

## Effect on API resilience

This proposal does not affect API resilience.

## Alternatives considered

Keep SE-0302 behavior. This would require explicit "non-Sendable" annotation of many important aggregate types that embed unsafe pointers. 
