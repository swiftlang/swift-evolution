# Temporary uninitialized buffers

* Proposal: [SE-0322](0322-temporary-buffers.md)
* Author: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Implemented (Swift 5.6)**
* Implementation: [apple/swift#37666](https://github.com/apple/swift/pull/37666)
* Decision Notes: [Acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0322-temporary-uninitialized-buffers/52532)

## Introduction

This proposal introduces new Standard Library functions for manipulating temporary buffers that are preferentially allocated on the stack instead of the heap.

Swift-evolution thread: [[Pitch] Temporary uninitialized buffers](https://forums.swift.org/t/pitch-temporary-uninitialized-buffers/48954)

## Motivation

Library-level code often needs to deal with C functions, and C functions have a wide variety of memory-management approaches. A common way to handle buffers of value types (i.e. structures) in C is to have a caller allocate a buffer of sufficient size and pass it to a callee to initialize; the caller is then responsible for deinitializing the buffer (if non-trivial) and then deallocating it. In C or Objective-C, it's easy enough to stack-allocate such a buffer, and the logic to switch to the heap for a larger allocation is pretty simple too. This sort of pattern is pervasive:

```c
size_t tacoCount = ...;
taco_fillings_t fillings = ...;

taco_t *tacos = NULL;
taco_t stackBuffer[SOME_LIMIT];
if (tacoCount < SOME_LIMIT) {
  tacos = stackBuffer;
} else {
  tacos = calloc(tacoCount, sizeof(taco_t));
}

taco_init(tacos, tacoCount, &fillings);

// do some work here
ssize_t tacosEatenCount = tacos_consume(tacos, tacoCount);
if (tacosEatenCount < 0) {
  int errorCode = errno;
  fprintf(stderr, "Error %i eating %zu tacos: %s", errorCode, tacoCount, strerror(errorCode));
  exit(EXIT_FAILURE);
}

// Tear everything down.
taco_destroy(tacos, tacoCount);
if (buffer != stackBuffer) {
  free(buffer);
}
```

In C++, we can make judicious use of `std::array` and `std::vector` to achieve the same purpose while generally preserving memory safety.

But there's not really any way to express this sort of transient buffer usage in Swift. All values must be initialized in Swift before they can be used, but C typically claims responsibility for initializing the values passed to it, so a Swift caller ends up initializing the values _twice_. The caller can call `UnsafeMutableBufferPointer<taco_t>.allocate(capacity:)` to get uninitialized memory, of course. `allocate(capacity:)` places buffers on the heap by default, and the optimizer can only stack-promote them after performing escape analysis.

Since Swift requires values be initialized before being used, and since escape analysis is [undecidable](https://duckduckgo.com/?q=escape+analysis+undecidable) for non-trivial programs, it's not possible to get efficient (i.e. stack-allocated and uninitialized) temporary storage in Swift.

It is therefore quite hard for developers to provide Swift overlays for lower-level C libraries that use these sorts of memory-management techniques. This means that an idiomatic Swift program using a C library's Swift overlay will perform less optimally than the same program would if written in C.

## Proposed solution

I propose adding a new transparent function to the Swift Standard Library that would allocate a buffer of a specified type and capacity, provide that buffer to a caller-supplied closure, and then deallocate the buffer before returning. The buffer would be passed to said closure in an uninitialized state and treated as uninitialized on closure return—that is, the closure would be responsible for initializing and deinitializing the elements in the buffer.

A typical use case might look like this:

```swift
// Eat a temporary taco buffer. A buffet, if you will.
try taco_t.consume(count: tacoCount, filledWith: ...)

// MARK: - Swift Overlay Implementation

extension taco_t {
  public static func consume(count: Int, filledWith fillings: taco_fillings_t) throws {
    try withUnsafeTemporaryAllocation(of: taco_t.self, capacity: count) { buffer in
      withUnsafePointer(to: fillings) { fillings in
        taco_init(buffer.baseAddress!, buffer.count, fillings)
      }
      defer {
        taco_destroy(buffer.baseAddress!, buffer.count)
      }
    
      let eatenCount = tacos_consume(buffer.baseAddress!, buffer.count)
      guard eatenCount >= 0 else {
        let errorCode = POSIXErrorCode(rawValue: errno) ?? .ENOTHUNGRY
        throw POSIXError(errorCode)
      }
    }
  }
}
```

The proposed function allows developers to effectively assert to the compiler that the buffer pointer used in the closure cannot escape the closure's context (even if calls are made to non-transparent functions that might otherwise defeat escape analysis.) Because the compiler then "knows" that the pointer does not escape, it can optimize much more aggressively.

A library developer going the extra mile would probably want to produce an interface that we would consider idiomatic in Swift. With the proposed function, the developer would be able to build such an interface without sacrificing C's performance. (The exact design of the hypothetical Swift "taco" interface is beyond the scope of this proposal.)

## Detailed design

A new free function would be introduced in the Standard Library:

```swift
/// Provides scoped access to a buffer pointer to memory of the specified type
/// and with the specified capacity.
///
/// - Parameters:
///   - type: The type of the buffer pointer being temporarily allocated.
///   - capacity: The capacity of the buffer pointer being temporarily
///     allocated.
///   - body: A closure to invoke and to which the allocated buffer pointer
///     should be passed.
///
///  - Returns: Whatever is returned by `body`.
///
///  - Throws: Whatever is thrown by `body`.
///
/// This function is useful for cheaply allocating storage for a sequence of
/// values for a brief duration. Storage may be allocated on the heap or on the
/// stack, depending on the required size and alignment.
///
/// When `body` is called, the contents of the buffer pointer passed to it are
/// in an unspecified, uninitialized state. `body` is responsible for
/// initializing the buffer pointer before it is used _and_ for deinitializing
/// it before returning, but deallocation is automatic.
///
/// The implementation may allocate a larger buffer pointer than is strictly
/// necessary to contain `capacity` values of type `type`. The behavior of a
/// program that attempts to access any such additional storage is undefined.
///
/// The buffer pointer passed to `body` (as well as any pointers to elements in
/// the buffer) must not escape—it will be deallocated when `body` returns and
/// cannot be used afterward.
public func withUnsafeTemporaryAllocation<T, R>(
  of type: T.Type,
  capacity: Int,
  _ body: (UnsafeMutableBufferPointer<T>) throws -> R
) rethrows -> R
```

Two additional free functions, composed atop that one, would also be introduced for dealing with a raw buffer or a pointer to a single value:

```swift
/// Provides scoped access to a raw buffer pointer with the specified byte count
/// and alignment.
///
/// - Parameters:
///   - byteCount: The number of bytes to temporarily allocate. `byteCount` must
///     not be negative.
///   - alignment: The alignment of the new, temporary region of allocated
///     memory, in bytes.
///   - body: A closure to invoke and to which the allocated buffer pointer
///     should be passed.
///
///  - Returns: Whatever is returned by `body`.
///
///  - Throws: Whatever is thrown by `body`.
///
/// This function is useful for cheaply allocating raw storage for a brief
/// duration. Storage may be allocated on the heap or on the stack, depending on
/// the required size and alignment.
///
/// When `body` is called, the contents of the buffer pointer passed to it are
/// in an unspecified, uninitialized state. `body` is responsible for
/// initializing the buffer pointer before it is used _and_ for deinitializing
/// it before returning, but deallocation is automatic.
///
/// The implementation may allocate a larger buffer pointer than is strictly
/// necessary to contain `byteCount` bytes. The behavior of a program that
/// attempts to access any such additional storage is undefined.
///
/// The buffer pointer passed to `body` (as well as any pointers to elements in
/// the buffer) must not escape—it will be deallocated when `body` returns and
/// cannot be used afterward.
public func withUnsafeTemporaryAllocation<R>(
  byteCount: Int,
  alignment: Int,
  _ body: (UnsafeMutableRawBufferPointer) throws -> R
) rethrows -> R

/// Provides scoped access to a pointer to memory of the specified type.
///
/// - Parameters:
///   - type: The type of the pointer to allocate.
///   - body: A closure to invoke and to which the allocated pointer should be
///     passed.
///
///  - Returns: Whatever is returned by `body`.
///
///  - Throws: Whatever is thrown by `body`.
///
/// This function is useful for cheaply allocating storage for a single value
/// for a brief duration. Storage may be allocated on the heap or on the stack,
/// depending on the required size and alignment.
///
/// When `body` is called, the contents of the pointer passed to it are in an
/// unspecified, uninitialized state. `body` is responsible for initializing the
/// pointer before it is used _and_ for deinitializing it before returning, but
/// deallocation is automatic.
///
/// The pointer passed to `body` must not escape—it will be deallocated when
/// `body` returns and cannot be used afterward.
public func withUnsafeTemporaryAllocation<T, R>(
  of type: T.Type,
  _ body: (UnsafeMutablePointer<T>) throws -> R
) rethrows -> R
```

Note the functions will be marked with attributes that ensure they are emitted into the calling frame. This is consistent with the annotations on most other pointer manipulation functions.

### New builtins

The proposed functions will need to invoke a new builtin function equivalent to C's `alloca()`, which I have named `Builtin.stackAlloc()`. A second builtin, `Builtin.stackDealloc()`, must then be invoked after the call to the body closure returns or throws in order to clean up the stack.

If the alignment and size are known at compile-time, the compiler can convert a call to `stackAlloc()` into a single LLVM `alloca` instruction, which can then ultimately be lowered to a single CPU instruction adjusting the stack pointer. If either argument needs to be computed at runtime, a dynamic stack allocation can instead be emitted by the compiler.

### Location of allocated buffers

The proposed functions do _not_ guarantee that their buffers will be stack-allocated. This omission is intentional: guaranteed stack-allocation would make this feature equivalent to C99's variable-length arrays—a feature that is extremely easy to misuse and which is the cause of many [real-world security vulnerabilities](https://duckduckgo.com/?q=cve+variable-length+array). Instead, the proposed functions should stack-promote aggressively, but heap-allocate (just as `UnsafeMutableBufferPointer.allocate(capacity:)` does today) when passed overly large sizes.

A common C approach is to say "anything larger than _n_ bytes uses `calloc()`", where _n_ is some moderately-sized constant. For allocations smaller than _n_, the compiler will simply allocate on the stack. This is as safe as the common Swift expression `let x = T()`, where `T` is a type whose size is smaller than _n_.

### Runtime support for more complex heuristics

For allocations **larger than** _n_, the compiler will emit a conditionalized call to a new Standard Library function `_swift_stdlib_isStackAllocationSafe()`. This function will be able to quickly determine if the desired allocation can fit in the available stack space. If it approves, the allocation will be performed on the stack. Otherwise, it will be performed on the heap.

This function will be a no-op on platforms where the current stack cannot be queried (i.e. there is no platform API to do so) or cannot be queried efficiently (i.e. doing so is more expensive than allocating to the heap.) Because the Standard Library owns this function, enhancements can be made in future Swift revisions that improve the heuristic without requiring callers to recompile.

The body of this function is an implementation detail of the Swift Standard Library and is **not** part of this proposal. A possible implementation might ask the operating system for details about the current thread's stack (e.g. by calling `GetCurrentThreadStackLimits()` on Windows or `pthread_getattr_np()` on Linux.)

### Custom heuristics

Several contributors to the pitch and review threads asked about providing their own heuristic for stack- vs. heap-allocation. It is unlikely that a caller will have sufficient additional information about the state of the program such that it can make better decisions about stack promotion than the compiler and/or Standard Library. An additional argument to the proposed functions that forces stack allocation is too visible a solution. Instead, callers that really do need larger stack allocations can pass `-stack-alloc-limit n` to the compiler frontend in order to specify a larger limit than the default for stack promotion.

## Source compatibility

This is new API, so there are no source compatibility considerations.

## Effect on ABI stability

This is new API, so there are no ABI stability considerations. The proposed functions should always be inlined into their calling frames, so they should be back-deployable to older Swift targets.

## Effect on API resilience

The addition of the proposed functions does not affect API resilience. If they were removed in a future release, it would be a source-breaking change but not an ABI-breaking change, because the proposed functions should always be inlined into their calling frames.

## Alternatives considered

In the pitch thread for this proposal, a number of alternatives were discussed:

### Doing nothing

* A number of developers both at Apple and in the broader Swift community have indicated that the performance costs cited above are measurably affecting the performance of their libraries and applications.
* The proposed functions would let developers build higher-order algorithms, structures, and interfaces that they cannot build properly today.

### Naming the functions something different

* Several commenters suggested making the proposed functions static members of `UnsafeMutableBufferPointer` (etc.) instead of free functions. The Standard Library has precedent for producing transient resources via free function, e.g. `withUnsafePointer(to:)` and `withUnsafeThrowingContinuation(_:)`. I am not immediately aware of counter-examples in the Standard Library.
* My initial proposal used longer names for each function, but review found they were too wordy. Several commenters proposed alternative names: `withEphemeral(...)`, `withUnsafeLocalStorage(...)`, and `withUnsafeUninitializedBuffer(...)` were all suggested, among others.

### Exposing some subset of the three proposed functions

* One commenter wanted to expose _only_ `withUnsafeTemporaryAllocation(byteCount:alignment:_:)` in order to add friction and reduce the risk that someone would adopt the function without understanding its behaviour. Since most adopters would immediately need to call `bindMemory(to:)` to get a typed buffer, my suspicion is that developers would quickly learn to do so anyway.
* Another commenter did not want to expose `withUnsafeTemporaryAllocation(of:_)` on the premise that it is trivial to get an `UnsafeMutablePointer` out of an `UnsafeMutableBufferPointer` with a `count` of `1`. It is indeed easy to do so, however the two types have different sets of member functions and I'm not sure that the added friction _improves_ adopting code. On the other hand, if anyone needs a _single_ stack-allocated value, they can use `Optional` today to get one.

### Exposing this functionality as a type rather than as a scoped function

* It is likely the capacity of such a type would need to be known at compile time. Swift already has a mechanism for declaring types with a fixed-size sequence of values: homogeneous tuples. In fact, Michael Gottesman has [a pitch](https://forums.swift.org/t/pitch-improved-compiler-support-for-large-homogenous-tuples/49023) open at the time of this writing to add syntactic sugar to make homogeneous tuples look more like C arrays.
* As a type, values thereof would need to be initialized before being used. They would impose the same initialization overhead we want to avoid.
* A type, even a value type, suffers from the same stack-promotion limitations as `UnsafeMutableBufferPointer<T>` or `Array<T>`, namely that the optimizer must act conservatively and may still need to heap-allocate. Value types also get copied around quite a bit (although the Swift compiler is quite good at copy elision.)
* One commenter suggested making this hypothetical type _only_ stack-allocatable, but no such type exists today in Swift. It would be completely new to both the Swift language and the Swift compiler. It would not generalize well, because (to my knowledge) there are no other use cases for stack-only types.

### Telling adopters to use `ManagedBuffer<Void, T>`

* `ManagedBuffer` has the same general drawbacks as any other type (see above.)
* `ManagedBuffer` is a reference type, not a value type, so the compiler _defaults_ to heap-allocating it. Stack promotion is possible but is not the common case.
* `ManagedBuffer` is not a great interface in and of itself.
* To me, `ManagedBuffer` says "I want to allocate a refcounted object with an arbitrarily long tail-allocated buffer" thus avoiding two heap allocations when one will do. I can then use that object as I would use any other object. This sort of use case doesn't really align with the use cases for the proposed functions.

### Exposing an additional function to initialize a value by address without copying

* One commenter suggested:
    > A variation of the signature that gives you the initialized value you put in the memory as the return value, `makeValueAtUninitializedPointer<T>(_: (UnsafeMutablePointer<T>) -> Void) -> T`, which could be implemented with return value optimization to do the initialization in-place.

    The proposed functions can be used for this purpose:

    ```swift
    let value = withUnsafeTemporaryAllocation(of: T.self) { ptr in
      ...
      return ptr.move()
    }
    ```

    Subject to the optimizer eliminating the `move()`, which in the common case it should be able to do.

### Eliminating "unsafe" interfaces from Swift entirely

* Some commenters were concerned by the idea of adding more "unsafe" interfaces to the Standard Library. The proposed functions are "unsafe" by the usual Swift definition, but not moreso than existing functions such as `withUnsafePointer(to:_:)` or `Data.withUnsafeBytes(_:)`.
* As discussed previously, in order to provide a high-level "safe" interface, the language needs some amount of lower-level unsafety. `Data` cannot be implemented without `UnsafeRawPointer` (or equivalent,) nor `Array<T>` without `UnsafeMutableBufferPointer<T>`, nor `CheckedContinuation<T, E>` without `UnsafeContinuation<T, E>`.
* The need for unsafe interfaces is not limited to the Standard Library: developers working at every layer of the software stack can benefit from careful use of unsafe interfaces like the proposed functions.
* Creating a dialect of Swift that bans unsafe interfaces entirely is an interesting idea and is worth discussing in more detail, but it is beyond the scope of this proposal.

### Using a different stack-promotion heuristic

* The original proposal used only a trivial "allocation ≤ _n_" heuristic for stack allocations. A number of reviewers wanted stronger guarantees around stack promotion. By adding the Standard Library function `_swift_stdlib_isStackAllocationSafe()`, we give the language a hook it can use to implement more complex heuristics.
* Some reviewers wanted the proposed functions to yield an optional buffer and `nil` on stack allocation failure. The Swift standard library currently considers allocation to be a non-failable operation: if an allocation actually fails, the library terminates the program rather than yielding a `nil` pointer. Since the proposed functions are intended to be used in scenarios where callers are currently already using `UnsafeMutableBufferPointer.allocate(capacity:)`, a fallback path that uses that function does not represent a performance regression.
* Some reviewers wanted the proposed functions to _always_ stack-allocate and _never_ heap-allocate. Putting aside inputs that require heap allocation (e.g. `alignment` not known at compile-time, so the correct LLVM `alloca` instructions cannot be generated), such a function would be inherently _dangerous_ rather than simply unsafe. Consider this seemingly-harmless program:

    ```swift
    print("How many tacos do you want?")
    guard let n = readLine().flatMap(Int.init(_:)) else {
      printUsageAndExit()
    }
    
    withUnsafeTemporaryAllocation(of: taco_t, capacity: n) { buffer
      taco_init(buffer.baseAddress!, buffer.count, fillings)
    }
    
    ...
    ```
    
    If the user specifies a very large number of tacos (an understandable choice), this function will smash the stack. While this function is marked "unsafe", Swift still strives to be a safe language, and such a sharp edge on the proposed functions is unacceptable.

## Acknowledgments

Thank you to the Swift team for your help and patience as I learn how to write Swift proposals. And thank you to everyone who commented in the pitch thread—it was great to see your feedback and your ideas!
