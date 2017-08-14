# Improved pointers

* Proposal: [SE-0184](0184-improved-pointers.md)
* Author: [Kelvin Ma (“Taylor Swift”)](https://github.com/kelvin13)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

Swift’s pointer types are an important interface for low-level memory manipulation, but the current API design is not very consistent, complete, or convenient. Many memory methods demand a `capacity:` or `count:` argument, forcing the user to manually track the size of the memory block, even though most of the time this is either unnecessary, or redundant as buffer pointers track this information natively. In some places, poor naming choices and overengineered function signatures compromise memory safety by leading users to believe that they have allocated or freed memory when in fact, they have not.

This proposal seeks to improve the Swift pointer API by ironing out naming inconsistencies, adding sensible default argument values, adding missing methods, and reducing excessive verbosity, offering a more convenient, more sensible, and less bug-prone API.

The [previous version](https://gist.github.com/kelvin13/1b8ae906be23dff22f7a7c4767f0c907) of this document ignored the generic initialization methods on `UnsafeMutableBufferPointer` and `UnsafeMutableRawBufferPointer`, leaving them to be overhauled at a later date, in a separate proposal. Instead, this version of the proposal leverages those existing methods to inform a more compact API design which has less surface area, and is more future-proof since it obviates the need to design and add another (redundant) set of protocol-oriented pointer APIs later.

Swift-evolution thread: [Pitch: Improved Swift pointers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170710/038013.html), [Pitch: More Improved Swift pointers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170717/038121.html)

## Background 

There are four binary memorystate operations: *initialization*, *move-initialization*, *assignment*, and *move-assignment*. They can be grouped according to how they affect the source buffer and the destination buffer. **Copy** operations only read from the source buffer, leaving it unchanged. **Move** operations deinitialize the source memory, decrementing the reference count by 1 if the memory type is not a trivial type. **Retaining** operations initialize the destination memory, incrementing the reference count by 1 if applicable. **Releasing** operations deinitialize the destination memory before reinitializing it with the new values, resulting in a net change in the reference count of 0, if applicable.

|                    | Copy (+0)       | Move (−1)            |
| -------------:     |----------:      | ---------:           |
| **Retaining (+1)** | initialize (+1) | move-initialize (+0) |
| **Releasing (+0)** | assign     (+0) |  move-assign    (−1) |

Note: deinitialization is a unary operation; it decrements the reference count of the buffer by 1. 

The four main types of Swift pointers we have currently support different subsets of this toolbox.

### UnsafeMutablePointer 

|               | Copy            | Move                 |
| ------------- |----------:      | ---------:           |
| **Retaining** | `initialize(to:count:)`, `initialize(from:count:)` | `moveInitialize(from:count:)` |
| **Releasing** |                              `assign(from:count:)` |     `moveAssign(from:count:)` |

### UnsafeMutableRawPointer 

|               | Copy            | Move                 |
| ------------- |----------:      | ---------:           |
| **Retaining** | `initializeMemory<T>(as:at:count:to:)`, `initializeMemory<T>(as:from:count:)` | `moveInitializeMemory<T>(as:from:count:)` |
| **Releasing** | | |

### UnsafeMutableBufferPointer 

|               | Copy            | Move                 |
| ------------- |----------:      | ---------:           |
| **Retaining** | `initialize<S>(from:)` | |
| **Releasing** | | |


### UnsafeMutableRawBufferPointer 

|               | Copy            | Move                 |
| ------------- |----------:      | ---------:           |
| **Retaining** | `initializeMemory<S>(as:from:)` | |
| **Releasing** | | |

There are unary memorystate operations such as *deinitialization* and *type rebinding*, which are not listed in the tables, but are still covered by this proposal. Raw pointers also have a unique operation, *bitwise-copying*, which we will lump together with the memorystate functions, but does not actually change a pointer’s memory state.

## Motivation

Right now, `UnsafeMutableBufferPointer` is kind of a black box when it comes to producing and modifying instances of it. Much of the API present on `UnsafeMutablePointer` is absent on its buffer variant. To create, bind, allocate, initialize, deinitialize, and deallocate them, you have to extract `baseAddress`es and `count`s. This is unfortunate because `UnsafeMutableBufferPointer` provides a handy container for tracking the size of a memory buffer, but to actually make use of this information, the buffer pointer must be disassembled. In practice, this means the use of memory buffers requires frequent (and annoying) conversion back and forth between buffer pointers and base address–count pairs. For example, to move-initialize memory between two buffer pointers, you have to write this:

```swift
buffer1.baseAddress?.moveInitialize(from: buffer2.baseAddress!, count: buffer1.count)
```

The `?` is sometimes exchanged with an `!` depending on the personality of the author, as normally, neither operator is meaningful here — the `baseAddress` is never `nil` if the buffer pointer was created around an instance of `UnsafeMutablePointer`. 

Memory buffer allocation is especially painful, since it requires the creation of a temporary `UnsafeMutablePointer` instance. This means that the following “idiom” is very common in Swift code:

```swift
let buffer = UnsafeMutableBufferPointer<UInt8>(start: UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount), count: byteCount)
```

Aside from being extremely long and unwieldy, and requiring the creation of a temporary, `byteCount` must appear twice.

You can’t even cast buffer pointer types to their mutable or immutable forms without creating a temporary.

```swift 

var mutableBuffer = UnsafeMutableBufferPointer(start: UnsafeMutablePointer(mutating: immutableBuffer.baseAddress!), count: immutableBuffer.count)
```

Currently, memory is deallocated by an instance method on `UnsafeMutablePointer`, `deallocate(count:)`. Like much of the Swift pointer API, performing this operation on a buffer pointer requires extracting `baseAddress!` and `count`. It is very common for the allocation code above to be immediately followed by:

```swift
defer
{
    buffer.baseAddress?.deallocate(capacity: buffer.count)
}
```

This method is extremely problematic because nearly all users, on first seeing the signature of `deallocate(capacity:)`, will naturally conclude from the `capacity` label that `deallocate(capacity:)` is equivalent to some kind of `realloc()` that can only shrink the buffer. However this is not the actual behavior — `deallocate(capacity:)` actually *ignores* the `capacity` argument and just calls `free()` on `self`. The current API is not only awkward and suboptimal, it is *misleading*. You can write perfectly legal Swift code that shouldn’t segfault, but still can, for example

```swift 
var ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: 1000000)
ptr.initialize(to: 13, count: 1000000)
ptr.deallocate(capacity: 500000) // deallocate the second half of the memory block
ptr[0] // segmentation fault
```

where the first 500000 addresses should still be valid if the [documentation](https://developer.apple.com/documentation/swift/unsafemutablepointer/2295090-deallocate) is to be read literally. 

Users who are *aware* of this behavior may also choose to disregard the `capacity` argument and write things like this:

```swift
defer
{
    buffer.baseAddress?.deallocate(capacity: 42)
}
```

which is functionally equivalent. However this will lead to disastrous source breakage if the implementation of `deallocate(capacity:)` is ever “corrected”. Since the API would not change, such code would still compile, but suddenly start failing at runtime. Thus, the current API, combined with incorrect documentation, is serving as a vector for introducing memory bugs into Swift code.

The Swift pointer API is incomplete in other ways too. For example, the `initialize(from:count:)` method on `UnsafeMutablePointer` has a repeated-value copy variant, `initialize(to:count:)`, but `assign(from:count:)` has no such variant, even though it would make just as much sense for it to have one.

Finally, the naming of some `UnsafeMutableRawPointer` members deserves a second look. While the original API intended to introduce a naming convention where `bytes` refers to uninitialized memory, `capacity` to uninitialized elements, and `count` to initialized elements, the actual usage of the three words does not always agree. In `copyBytes(from:count:)`, `count` refers to the number of *bytes*, which may or may not be initialized. Similarly, the `UnsafeMutableRawBufferPointer` `allocate(count:)` type method includes a `count` argument which actually refers to uninitialized bytes.

## Proposed solution

The previous draft of this proposal sought to associate the `count` property in `UnsafeMutableBufferPointer` and `UnsafeMutableRawBufferPointer` with the various `count:` arguments, leading to a very natural and elegant set of memory APIs. Because buffer length is tracked externally when using `UnsafeMutablePointer`, memory methods on it should explicitly ask for the sizing parameter. Conversely, because buffer length is tracked internally by `UnsafeMutableBufferPointer`, memory methods on it should supply the buffer’s own `count` property for the operation’s sizing parameter. This means you would call 

```swift
ptr1.initialize(from: ptr2, count: count)
```

on an `UnsafeMutablePointer`, but 

```swift
buffer1.initialize(from: buffer2)
```

on an `UnsafeMutableBufferPointer`. 

This draft improves upon that system by making a small adjustment: when a buffer pointer memory method takes a source argument, the *source* supplies the count, not `self`. This agrees with the existing behavior of the `UnsafeMutableBufferPointer.initialize<S>(from:)` and `UnsafeMutableRawBufferPointer.initializeMemory<S>(as:from:)` methods, which take source arguments which conform to `Sequence`. It also lends itself well to real usage patterns — for example, to implement a dynamic array, to resize the array, you would move-initialize the entirety of the old array into a larger buffer, leaving the new buffer partially initialized, and the old buffer completely uninitialized.

Adopting this convention reduces the amount of new API surface area created, by leveraging existing APIs instead of building parallel APIs. For example, since `UnsafeMutableBufferPointer.initialize<S>(from:)` takes a `Sequence`, and `UnsafeMutableBufferPointer` conforms to `Sequence`, we no longer need to provide a separate *initialize* method which takes an `UnsafeMutableBufferPointer`. There are performance issues that must be considered by making this operation generic, but those are implementation issues that do not affect the outward facing API.

The envisioned new API will give buffer pointers parity with their plain variants. For copy operations, where the source argument would once have been another unsafe pointer, it will now be a `Sequence`. (Move operations still always take pointers since they perform deinitialization.) In addition, all the operations in the copy column (regardless of whether the pointer is a buffer pointer or a plain pointer) will support *repeated-value* sources, and actual *sequence sources*. Unlike sequence sources, repeated-value sources do not come with an associated count property, so `self.count` is used instead. Currently, only initialization methods support repeated-value sources. Under this proposal, assignment methods would get them too.

Typed pointers will support all memorystate operations. Raw pointers should only support retaining operations. The new API will look like this:

### UnsafeMutablePointer 

|               | Copy            | Move                 |
| ------------- |----------:      | ---------:           |
| **Retaining** | `initialize(repeating:count:)`, `initialize(from:count:)` | `moveInitialize(from:count:)` |
| **Releasing** |         `assign(repeating:count:)`, `assign(from:count:)` |     `moveAssign(from:count:)` |

* count comes from explicit `count:` argument 
* values either come from explicit `repeatedValue` parameter (repeated-value copy), `UnsafePointer` source (sourced copy), or `UnsafeMutablePointer` source (sourced move).

### UnsafeMutableRawPointer 

|               | Copy            | Move                 |
| ------------- |----------:      | ---------:           |
| **Retaining** | `initializeMemory<T>(as:at:repeating:count:)`, `initializeMemory<T>(as:from:count:)` | `moveInitializeMemory<T>(as:from:count:)` |

* count comes from explicit `count:` argument 
* values either come from explicit `repeatedValue` parameter (repeated-value copy), `UnsafePointer` source (sourced copy), or `UnsafeMutablePointer` source (sourced move).

### UnsafeMutableBufferPointer 

|               | Copy            | Move                 |
| ------------- |----------:      | ---------:           |
| **Retaining** | `initialize(repeating:)`, `initialize<S>(from:)` | `moveInitialize(from:)` |
| **Releasing** |         `assign(repeating:)`, `assign<S>(from:)` |     `moveAssign(from:)` |

* count either comes from `self.count` (repeated-value copy), or iterating through `source` `Sequence` (sourced copy), or `source.count` (sourced move) 
* values either come from explicit `repeatedValue` parameter (repeated-value copy), `Sequence` source (sourced copy), or `UnsafeMutableBufferPointer` source (sourced move).
* sourced copy operations return updated source `Sequence` state

### UnsafeMutableRawBufferPointer 

|               | Copy            | Move                 |
| ------------- |----------:      | ---------:           |
| **Retaining** | `initializeMemory<T>(as:repeating:)`, `initializeMemory<S>(as:from:)` | `moveInitializeMemory<T>(as:from:)` |

* count either computed from `self.count` and `MemoryLayout<T>.stride` (repeated-value copy), or iterating through `source` `Sequence` (sourced copy), or `source.count` (sourced move) 
* values either come from explicit `repeatedValue` parameter (repeated-value copy), `Sequence` source (sourced copy), or `UnsafeMutableBufferPointer` source (sourced move).
* sourced copy operations return updated source `Sequence` state

Note: raw pointers don’t get deinitializers for the same reasons that they do not support releasing operations. Deinitialization is nothing but a unary releasing operation that does not reinitialize the destination memory.

Many other miscellaneous changes should also be made.

## Detailed solution

- **fix the ordering of the arguments in `initializeMemory<Element>(as:at:count:to:)` and rename the argument `to:` to `repeating:` in all repeated-value copy functions**

The ordering of the `to:` and `count:` argument labels in the `initializeMemory<Element>(as:at:count:to:)` method on `UnsafeMutableRawPointer` contradicts the rest of the Swift pointer API, where `to:` precedes `count:`. 

Because the ordering `initializeMemory<Element>(as:at:to:count:)` conflicts with the use of `to:` as the argument label for a target type, this argument should be renamed to `repeating:`. The word `repeating:` is much more clear in terms of describing the methods’ behavior, and is consistent with the use of the word in the `Array` API.

- **add the repeated-value copy assignment method `assign(repeating:count:)`**

This addresses the missing assignment analogue to the `initialize(to:count:)` method.

- **rename `copyBytes(from:count:)` to `copy(from:bytes:)` on `UnsafeMutableRawPointer`**

To reduce the inconsistency in our use of the words `bytes`, `count`, and `capacity`, we will enforce the convention that:

* `bytes` refers to, well, a byte quantity that is *not assumed* to be initialized.
* `capacity` refers to a strided quantity that is *not assumed* to be initialized.
* `count` refers to a strided quantity that is *assumed* to be initialized.

Since this makes the word “bytes” occur twice in `copyBytes(from:bytes:)`, we should drop the “Bytes” suffix and further rename the method to `copy(from:bytes:)`. Since `UnsafeMutableRawPointer` is inherently untyped, it is obvious that any memory transfer operation on it is a bytewise operation so the “Bytes” suffix adds only verbosity and no clarity. An unsized version of this method will also be added to `UnsafeMutableRawBufferPointer`.

We do not rename the `count` property on `UnsafeMutableRawBufferPointer` to `bytes` since this could be confused with the actual buffer data.

- **rename `count` in `UnsafeMutableRawBufferPointer.allocate(count:)` to `bytes` and add an `alignedTo` parameter to make it `UnsafeMutableRawBufferPointer.allocate(bytes:alignedTo:)`**

This brings it in line with the `UnsafeMutableRawPointer` allocator, and avoids the contradictory and inconsistent use of `count` to represent a byte quantity. Currently `UnsafeMutableRawBufferPointer.allocate(count:)` aligns to the size of `UInt`, an assumption not shared by its plain variant.

- **remove the `capacity` parameter from `deallocate(capacity:)`, and remove all parameters from `deallocate(bytes:alignedTo:)`**

Removing `capacity` from `deallocate(capacity:)` will end the confusion over what `deallocate()` does, making it obvious that `deallocate()` will free the *entire* memory block at `self`, just as if `free()` were called on it.

The old `deallocate(capacity:)` method should be marked as `unavailable` since it currently encourages dangerously incorrect code. This avoids misleading future users, forces current users to address this potentially catastrophic memory bug, and leaves the possibility open for us to add a `deallocate(capacity:)` method in the future, or perhaps even a `reallocate(toCapacity:)` method.

Along similar lines, the `bytes` and `alignedTo` parameters should be removed from the `deallocate(bytes:alignedTo:)` method on `UnsafeMutableRawPointer`.

- **add unsized memory methods to `UnsafeMutableBufferPointer`**

The following methods will be added to `UnsafeMutableBufferPointer`, giving it parity with `UnsafeMutablePointer`. Note that `UnsafeMutableBufferPointer` already contains an `initialize<S>(from:)` method.

```swift 
static func allocate<Element>(capacity:Int) -> UnsafeMutableBufferPointer<Element>
func deallocate()

func initialize(repeating:Element)
// func initialize<S>(from:S) -> (S.Iterator, Index) where S:Sequence, S.Element == Element
func assign(repeating:Element)
func assign<S>(from:S) -> (S.Iterator, Index) where S:Sequence, S.Element == Element
func moveAssign(from:UnsafeMutableBufferPointer<Element>)
func moveInitialize(from:UnsafeMutableBufferPointer<Element>)

func deinitialize()
```

Sourced copy operations should return the remainder of the iterator, and the past-the-end index of the written sub-buffer. This return value should be marked as `@discardableResult`.

- **add unsized memory methods to `UnsafeMutableRawBufferPointer`**

The following methods will be added to `UnsafeMutableRawBufferPointer`, giving it parity with `UnsafeMutableRawPointer`. Note that `UnsafeMutableRawBufferPointer` already contains an `allocate(bytes:alignedTo:)`, `deallocate()`, and `initializeMemory<S>(as:from:)` method.

```swift 
func initializeMemory<T>(as:T.Type, at:Int, repeating:T) -> UnsafeMutableBufferPointer<T>
func moveInitializeMemory<T>(as:T.Type, from:UnsafeMutableBufferPointer<T>) 
     -> UnsafeMutableBufferPointer<T>
```

`UnsafeMutableRawBufferPointer` will compute the count value based on its own `count` property. This involves performing integer division on the stride of `T`, but the standard library already seems to do this for `initializeMemory<S>(as:from:)`, so there is precedent for this behavior.

- **add the unsized rebinding functions `withMemoryRebound<T, Result>(to:_:)` to `UnsafeMutableBufferPointer`, and `bindMemory<T>(to:)` to `UnsafeMutableRawBufferPointer`**

Similarly, `UnsafeMutableBufferPointer` and `UnsafeMutableRawBufferPointer` will compute the count value based on their own lengths, and stride information.

- **add a default value of `1` to all size parameters on `UnsafeMutablePointer` and applicable size parameters on `UnsafeMutableRawPointer`**

Since the most common use case for plain pointers is to manage one single instance of a type, the size parameters on `UnsafeMutablePointer`’s memory methods are good candidates for a default value of `1`. Any size parameter on `UnsafeMutableRawPointer`’s memory methods which take a stride quantity should also receive a default value of `1`. The size parameters in `UnsafeMutableRawPointer`’s other methods should not receive a default value as they refer to byte quantities.

- **add an `init(mutating:)` initializer to `UnsafeMutableBufferPointer`**

This makes it much easier to make a mutable copy of an immutable buffer pointer. Such an initializer already exists on `UnsafeMutableRawBufferPointer`, so adding one to `UnsafeMutableBufferPointer` is also necessary for consistency. The reverse initializer, from `UnsafeMutableBufferPointer` to `UnsafeBufferPointer` should also be added for completeness.

- **add a mutable overload to the `copy(from:)` method on `UnsafeMutableRawBufferPointer`**

Currently, for plain pointers, there is a compiler subtyping relationship between `UnsafePointer` and `UnsafeMutablePointer`. No such relationship exists between `UnsafeBufferPointer` and `UnsafeMutableBufferPointer` or their raw counterparts. Note that it is not necessary to provide a mutable overload for `UnsafeMutableBufferPointer.initialize<S>(from:)` or `UnsafeMutableBufferPointer.assign<S>(from:)` due to their generic nature.

## What this proposal does not do 

- **remove subscripts from `UnsafePointer` and `UnsafeMutablePointer`**

There are strong arguments for removing subscript capability from plain pointer types.

> Subscripts on `UnsafePointer` and `UnsafeMutablePointer` are inconsistent with their intended purpose. For example, `ptr[0]` and `ptr.pointee` both do the same thing. Furthermore, it is not immediately obvious from the grammar that the subscript parameter is an *offset*. New users may conclude that subscripting a pointer at `[89]` dereferences the memory at *address* `0x0000000000000059`! It would make more sense to use pointer arithmetic and the `pointee` property to access memory at an offset from `self` than to allow subscripting.

> C programmers who defend this kind of syntax are reminded that many things obvious to C programmers, are obvious to *only* C programmers. The trend in Swift’s design is to separate C’s array–pointer duality; pointer subscripts run counter to that goal.

> There is an argument that singular pointer subscripts are useful when singular pointers of unknown length are returned by C APIs. The counter-argument is that you almost never need to do random access into a vector of unknown length, rather you would iterate one element at a time until you reach the end. This lends itself well to pointer incrementation and the `pointee` property rather than subscripting.

```swift
while ptr.pointee != sentinel
{
    ...
    
    ptr += 1
}
```

However, this is a source breaking change, and there are (rare) cases where this syntax is helpful, for example, when dealing with multi-element strides.

```swift 
var pixel:UnsafeMutablePointer<UInt8> = base
while pixel < base + size
{
    // assign the RGBA color #ff1096ff
    pixel[0] = 0xff
    pixel[1] = 0x10
    pixel[2] = 0x96
    pixel[3] = 0xff
    pixel += 4
}
```

## Detailed design

```diff
struct UnsafeMutablePointer<Pointee>
{
--- static func allocate<Pointee>(capacity:Int) -> UnsafeMutablePointer<Pointee>
+++ static func allocate<Pointee>(capacity:Int = 1) -> UnsafeMutablePointer<Pointee>
--- func deallocate(capacity _:Int)
+++ func deallocate()

+++ func assign(repeating:Pointee, count:Int = 1)

--- func assign(from:UnsafePointer<Pointee>, count:Int)
--- func moveAssign(from:UnsafeMutablePointer<Pointee>, count:Int)
--- func moveInitialize(from:UnsafeMutablePointer<Pointee>, count:Int)
--- func initialize(from:UnsafePointer<Pointee>, count:Int)
--- func initialize(to:Pointee, count:Int)
+++ func assign(from:UnsafePointer<Pointee>, count:Int = 1)
+++ func moveAssign(from:UnsafeMutablePointer<Pointee>, count:Int = 1)
+++ func moveInitialize(from:UnsafeMutablePointer<Pointee>, count:Int = 1)
+++ func initialize(from:UnsafePointer<Pointee>, count:Int = 1)
+++ func initialize(repeating:Pointee, count:Int = 1)

--- func deinitialize(count:Int)
--- func withMemoryRebound<T, Result>(to:T.Type, count:Int, _ body:(UnsafeMutablePointer<T>) -> Result)
+++ func deinitialize(count:Int = 1)
+++ func withMemoryRebound<T, Result>(to:T.Type, count:Int = 1, _ body:(UnsafeMutablePointer<T>) -> Result)
}

struct UnsafeRawPointer
{
--- func bindMemory<T>(to:T.Type, count:Int) -> UnsafeMutablePointer<T>
+++ func bindMemory<T>(to:T.Type, count:Int = 1) -> UnsafeMutablePointer<T>
}

struct UnsafeMutableRawPointer
{
--- func deallocate(bytes _:Int, alignedTo _:Int)
+++ func deallocate()

--- func copyBytes(from:UnsafeRawPointer, count:Int)
+++ func copy(from:UnsafeRawPointer, bytes:Int)

--- func initializeMemory<T>(as:T.Type, at:Int, count:Int, to:T) -> UnsafeMutablePointer<T>
--- func initializeMemory<T>(as:T.Type, from:UnsafePointer<T>, count:Int) -> UnsafeMutablePointer<T>
+++ func initializeMemory<T>(as:T.Type, at:Int, repeating:T, count:Int = 1) -> UnsafeMutablePointer<T>
+++ func initializeMemory<T>(as:T.Type, from:UnsafePointer<T>, count:Int = 1) -> UnsafeMutablePointer<T>

--- func moveInitializeMemory<T>(as:T.Type, from:UnsafeMutablePointer<T>, count:Int) 
---      -> UnsafeMutablePointer<T>
+++ func moveInitializeMemory<T>(as:T.Type, from:UnsafeMutablePointer<T>, count:Int = 1) 
+++      -> UnsafeMutablePointer<T>

--- func bindMemory<T>(to:T.Type, count:Int) -> UnsafeMutablePointer<T>
+++ func bindMemory<T>(to:T.Type, count:Int = 1) -> UnsafeMutablePointer<T>
}

struct UnsafeBufferPointer<Element> 
{
+++ init(_:UnsafeMutableBufferPointer<Element>)
}

struct UnsafeMutableBufferPointer<Element>
{
+++ init(mutating:UnsafeBufferPointer<Element>)

+++ static func allocate<Element>(capacity:Int) -> UnsafeMutableBufferPointer<Element>
+++ func deallocate()

+++ func initialize(repeating:Element)
    func initialize<S>(from:S) -> (S.Iterator, Index) where S:Sequence, S.Element == Element
+++ func assign(repeating:Element)
+++ func assign<S>(from:S) -> (S.Iterator, Index) where S:Sequence, S.Element == Element

+++ func moveInitialize(from:UnsafeMutableBufferPointer<Element>)
+++ func moveAssign(from:UnsafeMutableBufferPointer<Element>)

+++ func deinitialize()
+++ func withMemoryRebound<T, Result>
+++ (to:T.Type, _ body:(UnsafeMutableBufferPointer<T>) -> Result)
}

struct UnsafeMutableRawBufferPointer
{
--- static func allocate(count:Int) -> UnsafeMutableRawBufferPointer
+++ static func allocate(bytes:Int, alignedTo:Int) -> UnsafeMutableRawBufferPointer
    func deallocate()

+++ func bindMemory<T>(to:T.Type) -> UnsafeMutableBufferPointer<T>
--- func copyBytes(from:UnsafeRawBufferPointer)
+++ func copy(from:UnsafeRawBufferPointer)
+++ func copy(from:UnsafeMutableRawBufferPointer)

+++ func initializeMemory<T>(as:T.Type, at:Int, repeating:T) -> UnsafeMutableBufferPointer<T>
    func initializeMemory<S>(as:S.Element.Type, from:S) 
         -> (unwritten: S.Iterator, initialized: UnsafeMutableBufferPointer<S.Element>) 
           where S:Sequence
+++ func moveInitializeMemory<T>(as:T.Type, from:UnsafeMutableBufferPointer<T>) 
+++      -> UnsafeMutableBufferPointer<T>
}
```

## Source compatibility

Some parts of this proposal are source breaking. This proposal is significantly less source breaking than its [previous iterations](https://gist.github.com/kelvin13/a9c033193a28b1d4960a89b25fbffb06).

- **fix the ordering of the arguments in `initializeMemory<Element>(as:at:count:to:)` and rename the argument `to:` to `repeating:` in all repeated-value copy functions**

This change is source breaking but can be trivially automigrated.

- **add the repeated-value copy assignment method `assign(repeating:count:)`**

This change is purely additive.

- **rename `copyBytes(from:count:)` to `copy(from:bytes:)` on `UnsafeMutableRawPointer`**

This change is source breaking but can be trivially automigrated.

- **rename `count` in `UnsafeMutableRawBufferPointer.allocate(count:)` to `bytes` and add an `alignedTo` parameter to make it `UnsafeMutableRawBufferPointer.allocate(bytes:alignedTo:)`**

This change is source breaking but can be trivially automigrated. The `alignedTo:` parameter can be filled in with `MemoryLayout<UInt>.stride`. If [SR-5664](https://bugs.swift.org/browse/SR-5664) is fixed, `MemoryLayout<UInt>.stride` can even be provided as a default argument.

- **remove the `capacity` parameter from `deallocate(capacity:)`, and remove all parameters from `deallocate(bytes:alignedTo:)`**

This change is source-breaking, but this is a Good Thing™. The current API encourages incorrect code to be written, and sets us up for potentially catastrophic source breakage down the road should the implementations of `deallocate(capacity:)` and `deallocate(bytes:alignedTo:)` ever be “fixed”, so users should be forced to stop using them as soon as possible.

- **add unsized memory methods to `UnsafeMutableBufferPointer`**

This change is purely additive.

- **add unsized memory methods to `UnsafeMutableRawBufferPointer`**

This change is purely additive.

- **add the unsized rebinding functions `withMemoryRebound<T, Result>(to:_:)` to `UnsafeMutableBufferPointer`, and `bindMemory<T>(to:)` to `UnsafeMutableRawBufferPointer`**

This change is purely additive.

- **add a default value of `1` to all size parameters on `UnsafeMutablePointer` and applicable size parameters on `UnsafeMutableRawPointer`**

This change is purely additive.

- **add an `init(mutating:)` initializer to `UnsafeMutableBufferPointer`**

This change is purely additive.

- **add a mutable overload to the `copy(from:)` method on `UnsafeMutableRawBufferPointer`**

This change is purely additive.

## Effect on ABI stability

Removing sized deallocators changes the existing ABI, as will renaming some of the methods and their argument labels. `UnsafeMutableBufferPointer.initialize<S>(from:S)` and `UnsafeMutableRawBufferPointer.initializeMemory<S>(as:S.Element.Type, from:S) ` will receive a `@discardableResult` attribute, which should not affect ABI or API stability.

## Effect on API resilience

Some proposed changes in this proposal change the public API.

Removing sized deallocators right now will break ABI, but offers increased ABI and API stability in the future as reallocator methods can be added in the future without having to rename `deallocate(capacity:)` which currently occupies a “reallocator” name, but has “`free()`” behavior.

This proposal seeks to tackle all the breaking changes required for such an overhaul of Swift pointers, and leaves unanswered only additive changes that still need to be made in the future, reducing the need for future breakage.

## Alternatives considered

- **keeping sized deallocators and fixing the stdlib implementation instead**

Instead of dropping the `capacity` parameter from `deallocate(capacity:)`, we could fix the underlying implementation so that the function actually deallocates `capacity`’s worth of memory. However this would be catastrophically, and silently, source-breaking as existing code would continue compiling, but suddenly start leaking or segfaulting at runtime. `deallocate(capacity:)` can always be added back at a later date without breaking ABI or API, once users have been forced to address this potential bug.

- **adding an initializer `UnsafeMutableBufferPointer<Element>.init(allocatingCount:)` instead of a type method to `UnsafeMutableBufferPointer`**

The allocator could be expressed as an initializer instead of a type method. However since allocation involves acquisition of an external resource, perhaps it is better to keep with the existing convention that allocation is performed differently than regular buffer pointer construction.

- **using the argument label `value:` instead of `repeating:` in methods such as `initialize(repeating:count:)` (originally `initialize(to:count:)`)**

The label `value:` or `toValue:` doesn’t fully capture the repeating nature of the argument, and is inconsistent with `Array.init(repeating:count:)`. While `value:` sounds less strange when `count == 1`, on consistency and technical correctness, `repeating:` is the better term. Furthermore, `value` is a common variable name, meaning that function calls with `value:` as the label would be prone to looking like this:

```swift
ptr.initialize(value: value)
```
