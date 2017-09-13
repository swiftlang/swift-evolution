# Unsafe[Mutable][Raw][Buffer]Pointer: add missing methods, adjust existing labels for clarity, and remove deallocation size

* Proposal: [SE-0184](0184-unsafe-pointers-add-missing.md)
* Author: [Kelvin Ma (“Taylor Swift”)](https://github.com/kelvin13)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Active review (September 1...7, 2017)**
* Implementation: [apple/swift#11464](https://github.com/apple/swift/pull/11464)

## Introduction

Swift’s pointer types are an important interface for low-level memory manipulation, but the current API design is not very consistent, complete, or convenient. Many memory methods demand a `capacity:` or `count:` argument, forcing the user to manually track the size of the memory block, even though most of the time this is either unnecessary, or redundant as buffer pointers track this information natively. In some places, poor naming choices and overengineered function signatures compromise memory safety by leading users to believe that they have allocated or freed memory when in fact, they have not.

This proposal seeks to improve the Swift pointer API by ironing out naming inconsistencies, adding missing methods, and reducing excessive verbosity, offering a more convenient, more sensible, and less bug-prone API. We also attempt to introduce a buffer pointer API that supports partial initialization without excessively compromising memory state safety.

Swift-evolution thread: [Pitch: Improved Swift pointers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170710/038013.html), [Pitch: More Improved Swift pointers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170717/038121.html)

Implementation branch: [**PR 11464**](https://github.com/apple/swift/pull/11464)

## Background 

There are four binary memorystate operations: *initialization*, *move-initialization*, *assignment*, and *move-assignment*. They can be grouped according to how they affect the source buffer and the destination buffer. **Copy** operations only read from the source buffer, leaving it unchanged. **Move** operations deinitialize the source memory, decrementing the reference count by 1 if the memory type is not a trivial type. **Retaining** operations initialize the destination memory, incrementing the reference count by 1 if applicable. **Releasing** operations deinitialize the destination memory before reinitializing it with the new values, resulting in a net change in the reference count of 0, if applicable.

|                    | Copy (+0)  | Move (−1)       |
| -------------:     |----------: | ---------:      |
| **Retaining (+1)** | initialize | move-initialize |
| **Releasing (+0)** | assign     |  move-assign    |

Note: deinitialization by itself is a unary operation; it decrements the reference count of the buffer by 1. 

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

There are unary memorystate operations such as *deinitialization* and *type rebinding*, which are not listed in the tables, but are still covered by this proposal. Raw pointers also have a unique operation, *bytewise-copying*, which we will lump together with the memorystate functions, but does not actually change a pointer’s memory state.

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

Finally, some of the naming choices in the current API deserve a second look. While the original API intended to introduce a naming convention where `bytes` refers to uninitialized memory, `capacity` to uninitialized elements, and `count` to initialized elements, the actual usage of the three words does not always agree. In `copyBytes(from:count:)`, `count` refers to the number of *bytes*, which may or may not be initialized. Similarly, the `UnsafeMutableRawBufferPointer` `allocate(count:)` type method includes a `count` argument which actually refers to uninitialized bytes. The argument label `to:` is also excessively overloaded; sometimes it refers to a type `T.Type`, and sometimes it refers to a repeated value parameter. This becomes problematic when both parameters appear in the same method, as in `initializeMemory<T>(as:at:count:to)`.

## Proposed solution

The goal of the API redesign is to bring all of the functionality in `UnsafeMutablePointer` and `UnsafeMutableRawPointer` to their buffer types, `UnsafeMutableBufferPointer` and `UnsafeMutableRawBufferPointer`. `UnsafeMutableRawBufferPointer` already contains some of this functionality, providing a useful blueprint for the proposed `UnsafeMutableBufferPointer` API.

The full toolbox of methods that we could possibly support includes:

 - allocation 
 - deallocation 
 
 - initialization 
 - move-initialization 
 
 - assignment 
 - move-assignment 
 
 - deinitialization 
 - type rebinding 
 
 - bytewise copying 

Because copy operations (initialization and assignment) don’t mutate the source argument, they can also come in a form which takes a repeated-value source instead of a buffer source.

 - initialization (repeated-value)
 - assignment (repeated-value) 
 
`UnsafeMutablePointer` and `UnsafeMutableRawPointer` already contain repeated-value methods for initialization in the form of `initialize(to:count:)` and `initializeMemory<T>(as:at:count:to:)`. This proposal will add the assignment analogues. For reasons explained later, the argument label for the repeated-value parameter will be referred to as `repeating:`, not `to:`.

In their most general form, these functions are written like this:

``` 
static 
func allocate(as:count:) -> PointerType
func deallocate()

func initialize(at:as:repeating:count:)
func initialize(at:as:from:count:)
func moveInitialize(at:as:from:count:)

func assign(at:as:repeating:count:)
func assign(at:as:from:count:)
func moveAssign(at:as:from:count:)

func deinitialize(at:as:count:)
func rebindMemory(as:count:)

func copyBytes(at:from:count:)
```

where 

 - **`as:`** refers to the element type 
 - **`at:`** refers to an offset from `self`, in strides of the element type, if any 
 - **`repeating:`** refers to a repeating value 
 - **`from:`** refers to a second pointer which serves as the **source** 
 - **`count:`** refers the number of elements the operation operates on 
 
On actual pointer types, most of these parameters are unnecessary, and some of the methods themselves either don’t make sense to support, or are not practically useful.

 - it only makes sense for immutable pointer types to support deallocation and type rebinding. Note that Swift’s memory model does not require memory to be mutable for deallocation. 
 
 - raw (untyped) pointers should not support any operations which involve deinitialization on `self`. This rules out deinitialization itself, as well as any releasing operations (assignment, move-assignment).

 - typed pointers don’t need an `as:` parameter (except for type rebinding) — they already have a type. It also doesn’t make sense for them to support byte-wise copying.

 - pointers for which it is syntactically easy to offset in strides, or in the case of raw pointers, bytes (for example, by pointer arithmetic with `+`), don’t need to take an `at:` argument. 

This proposal moves the `at:` parameter to the front of the parameter list. (Where this parameter used to appear in `UnsafeMutableRawPointer`, it came after the `as:` parameter.) The rationale for this is that this proposal redefines the `at:` parameter in terms of pointer arithmetic offsets, and pointer arithmetic is written “first” from left to right. Since some of our pointer types will use `at:` and others won’t, we want the offset value to occur roughly in the same reading order across all our pointer types. 

> note: some of these conceptual argument labels have different names in the real API. `as:` is written as `to:` in the type-rebinding methods because it sounds better. `count:` is sometimes written as `capacity:` or `bytes:` to express the assumptions about the stride and initialization state of the memory in question. 

> * `bytes` refers to, well, a byte quantity that is *not assumed* to be initialized.
> * `capacity` refers to a strided quantity that is *not assumed* to be initialized.
> * `count` refers to a strided quantity that is *assumed* to be initialized.

> note: we don’t bother supporting an `at:` offset in type rebinding operations since we don’t anticipate much use for such a feature.

### `UnsafePointer<Pointee>`

``` 
func deallocate()
func withMemoryRebound<T, Result>(to:capacity:_:) -> Result
```

`UnsafePointer` does not get an allocator static method, since you almost always want a mutable pointer to newly allocated memory. Its type rebinding method is also written as a decorator, taking a trailing closure, for memory safety. `UnsafePointer` does not take `at:` arguments since `+` provides pointer arithmetic for it.

### `UnsafeMutablePointer<Pointee>`

``` 
static 
func allocate<Pointee>(capacity:) -> UnsafeMutablePointer<Pointee>
func deallocate()

func initialize(repeating:count:)
func initializePointee(to:)
func initialize(from:count:)
func moveInitialize(from:count:)

func assign(repeating:count:)
func assign(from:count:)
func moveAssign(from:count:)

func deinitialize(count:)
func withMemoryRebound<T, Result>(to:capacity:_:) -> Result
```

Like `UnsafePointer`, `UnsafeMutablePointer`’s type rebinding method is written as a decorator, and its methods do not need `at:` arguments. 

Unlike earlier versions of this proposal, we propose adding a method `initializePointee(to:)` to `UnsafeMutablePointer`. Previously, the single-element initialization case was supported by a default argument of `1` on `initialize(repeating:count:)`’s `count:` parameter, but it was decided this was too confusing in terms of API readability. For example, calls to `initialize(repeating:count:)` and its corresponding method on `UnsafeMutableBufferPointer` were prone to look the same. 

```swift 
plainPointer.initialize(repeating: pointee) 
bufferPointer.initialize(repeating: repeatedValue)
```

Increasing API surface by adding this method is justified by the large number of calls to `initialize(to:count:)` in the standard library (and likely other code) which rely on the default argument of `1`. We do *not* need to add a corresponding `assignPointee(to:)` method since this can be done with the assignment operator. 

```swift 
ptr.pointee = newValue 
```

### `UnsafeRawPointer`

``` 
func deallocate()

func bindMemory<T>(to:capacity:) -> UnsafePointer<T>
```

### `UnsafeMutableRawPointer`

``` 
static 
func allocate(bytes:alignedTo:) -> UnsafeMutableRawPointer
func deallocate()

func initializeMemory<T>(as:repeating:count:) -> UnsafeMutablePointer<T>
func initializeMemory<T>(as:from:count:) -> UnsafeMutablePointer<T>
func moveInitializeMemory<T>(as:from:count:) -> UnsafeMutablePointer<T>

func bindMemory<T>(to:capacity:) -> UnsafeMutablePointer<T>

func copyMemory(from:bytes:)
```

The `as:` argument in `allocate(bytes:alignedTo:)` is represented by an alignment parameter which takes an integer. This is more useful since we often need a computed alignment (like when aligning a structure) instead of a preset type alignment.

Currently, `UnsafeMutableRawPointer`’s methods take an `at:` offset argument that is interpreted in strides. This argument is not currently in use in the entire Swift standard library, and we believe that it is not useful in practice. This proposal replaces it with a `atByteOffset:` argument which takes a byte offset, a much more useful parameter. Since a byte offset off of a `UnsafeMutableRawPointer` can easily be obtained through pointer arithmetic, we do not actually need such an argument here.

Unlike `UnsafeMutablePointer`, we do not add a single-instance initialize method to `UnsafeMutableRawPointer`, as such a method would probably not be useful. However, we still remove the default argument of `1` from the `count:` argument in `initializeMemory<T>(as:repeating:count:)` to prevent confusion with calls to its buffer variant.

-------------

Buffer pointers are conceptually similar to plain pointers, except the `count:` argument is often unnecessary since they track their own length internally. This means you would call 

```swift
ptr1.initialize(repeating: value, count: count)
```

on an `UnsafeMutablePointer`, but 

```swift
buffer1.initialize(repeating: value)
```

on an `UnsafeMutableBufferPointer`. 

Implementing unary operations like repeated-value initialization, repeated-value assignment, and type rebinding is straightforward. However, with binary operations like move-initialization, which involves both a source buffer and a destination buffer, the question of whose `count` to use becomes important. 

One option is to use the destination’s `count`, and set the precondition that source`.count` `>=` destination`.count`. The benefit to this is that the destination is always guaranteed to be fully initialized, so that a sizeless `deinitialize()` can be safely called on it. However, in the case of move-initialization and move-assignment, it can leave the source buffer partially *deinitialized* which is just as big a problem. It is also not very useful in practice, since real collections tend to grow monotonically, periodically moving their contents into larger and larger buffers. 

A better option is to use the source’s `count`, combined with an `at:` offset, and set the precondition that `offset` `+` source`.count` `<=` destination`.count`. This *`at:from:`* system inspired by existing `UnsafeMutableRawPointer` APIs is an extremely useful system for supporting partially initialized buffer pointers by allowing us to initialize, assign, and move buffers in segments. For example, it would now be easy to concatenate multiple buffers into one.

```swift
let pixels:Int = scanlines.map{ $0.count }.reduce(0, +)
var image = UnsafeMutableBufferPointer<Pixel>.allocate(capacity: pixels)

var filled:Int = 0
for scanline:UnsafeMutableBufferPointer<Pixel> in scanlines 
{
    image.moveInitialize(at: filled, from: scanline)
    filled += scanline.count
}

image.deinitialize(at: 0, count: filled)
image.deallocate()
```

Under this system, it will be impossible to leave part of a source buffer deinitialized, and every segment of a destination buffer will be accessible (instead of only segments starting at index `0`.) 

For now, **calling `deallocate()` on a buffer pointer is only defined behavior if the buffer pointer references a complete heap memory block**. This operation may become supported in a wider variety of cases in the future if Swift gets a more sophisticated heap allocation backend.

> note: we use `at:` instead of `+` because pointer arithmetic does not play well with the nillable buffer pointer `baseAddress`.

> note: while deinitialization can be performed on a buffer pointer using its own `count` property, we have decided it’s better to explicitly ask for the `at:count:` pair to be consistent with real use patterns and the rest of the proposed API which operates on segments of `self`.

### `UnsafeBufferPointer<Element>`

``` 
func deallocate()
func withMemoryRebound<T, Result>(to:_:) -> Result
```

The buffer type rebind method dynamically computes the new count by performing multiplication and integer division, since the target type may have a different stride than the original type. This is in line with existing precedent in the generic buffer method `initializeMemory<S>(as:from:)` on `UnsafeMutableRawBufferPointer`.

### `UnsafeMutableBufferPointer<Element>`

``` 
static 
func allocate<Element>(capacity:) -> UnsafeMutableBufferPointer<Element>
func deallocate()

func initialize(repeating:)
func initialize(at:from:)
func moveInitialize(at:from:)

func assign(repeating:)
func assign(at:from:)
func moveAssign(at:from:)

func deinitialize(at:count)
func withMemoryRebound<T, Result>(to:_:) -> Result
```

The buffer type rebind method works the same way as in `UnsafeBufferPointer`. (Type rebinding never cares about mutability.)

> note: the `at:` arguments in `UnsafeMutableBufferPointer` and `UnsafeMutableRawBufferPointer` should *not* receive default values, as they are an integral part of the buffer pointer memory state safety system, and so it is important they appear at the call site.

### `UnsafeRawBufferPointer`

``` 
func deallocate()

func bindMemory<T>(to:) -> UnsafeBufferPointer<T>
```

### `UnsafeMutableRawBufferPointer`

``` 
static 
func allocate(bytes:alignedTo:) -> UnsafeMutableRawBufferPointer
func deallocate()

func initializeMemory<T>(as:repeating:) -> UnsafeMutableBufferPointer<T>
func initializeMemory<T>(atByteOffset:as:from:) -> UnsafeMutableBufferPointer<T>
func moveInitializeMemory<T>(atByteOffset:as:from:) -> UnsafeMutableBufferPointer<T>

func bindMemory<T>(to:) -> UnsafeMutableBufferPointer<T>

func copyMemory(at:from:)
```

> note: `initializeMemory(as:repeating:)` performs integer division on `self.count` (just like `bindMemory(to:)`) 

> note: the return values of `initializeMemory(as:repeating:)`, `initializeMemory(as:at:from:)`, and `moveInitializeMemory(as:at:from:)` should all be marked as `@discardableResult`. 

> note: even though the `at:` argument in `copyMemory(at:from:)` is in terms of bytes, it is not written as `atByteOffset` since there is no type object parameter in the function signature that could suggest that the offset is in typed strides. 

## Detailed changes

The proposed new API attempts to build on the existing API wherever possible. With the exception of `deallocate()` (which has good justification to replace `deallocate(capacity:)` and `deallocate(bytes:alignedTo:)`), all changes are either pure additive changes, or renames which are trivial to automigrate. This reduces the amount of source breakage.

- **fix the ordering of the arguments in `initializeMemory<Element>(as:at:count:to:)` and rename the argument `to:` to `repeating:` in all repeated-value copy functions**

The ordering of the `to:` and `count:` argument labels in the `initializeMemory<Element>(as:at:count:to:)` method on `UnsafeMutableRawPointer` contradicts the rest of the Swift pointer API, where `to:` precedes `count:`. 

Because the ordering `initializeMemory<Element>(as:at:to:count:)` conflicts with the use of `to:` as the argument label for a target type, this argument should be renamed to `repeating:`. The word `repeating:` is much more clear in terms of describing the methods’ behavior, and is consistent with the use of the word in the `Array` API.

- **add the repeated-value copy assignment method `assign(repeating:count:)`**

This addresses the missing assignment analogue to the `initialize(to:count:)` method.

- **rename `copyBytes(from:count:)` and `copyBytes(from:)` to `copyMemory(from:bytes:)` and `copyMemory(at:from:)`**

This brings the method names in line with the rest of the raw pointer API.

> note: we do not change the `copyBytes<C>(from:)` collection method.

- **rename `count` in `UnsafeMutableRawBufferPointer.allocate(count:)` to `bytes` and add an `alignedTo` parameter to make it `UnsafeMutableRawBufferPointer.allocate(bytes:alignedTo:)`**

This brings it in line with the `UnsafeMutableRawPointer` allocator, and avoids the contradictory and inconsistent use of `count` to represent a byte quantity. Currently `UnsafeMutableRawBufferPointer.allocate(count:)` aligns to the size of `UInt`, an assumption not shared by its plain variant.

- **add an `init(mutating:)` initializer to `UnsafeMutableBufferPointer`**

This makes it much easier to make a mutable copy of an immutable buffer pointer. Such an initializer already exists on `UnsafeMutableRawBufferPointer`, so adding one to `UnsafeMutableBufferPointer` is also necessary for consistency. The reverse initializer, from `UnsafeMutableBufferPointer` to `UnsafeBufferPointer` should also be added for completeness.

- **add a mutable overload to the `copyMemory(at:from:)` method on `UnsafeMutableRawBufferPointer`, the `initialize(at:from:)` and `assign(at:from:)` methods on `UnsafeMutableBufferPointer`, and the `initializeMemory<T>(atByteOffset:as:from:)` method on `UnsafeMutableRawBufferPointer`**

Currently, for plain pointers, there is a compiler subtyping relationship between `UnsafePointer` and `UnsafeMutablePointer`. No such relationship exists between `UnsafeBufferPointer` and `UnsafeMutableBufferPointer` or their raw counterparts, so it is necessary to provide mutable overloads for these functions.

- **add `deallocate()` to all pointer types, replacing any existing deallocation methods**

Removing `capacity` from `deallocate(capacity:)` will end the confusion over what `deallocate()` does, making it obvious that `deallocate()` will free the *entire* memory block at `self`, just as if `free()` were called on it.

The old `deallocate(capacity:)` method should be marked as `deprecated` and eventually removed since it currently encourages dangerously incorrect code. This avoids misleading future users, encourages current users to address this potentially catastrophic memory bug, and leaves the possibility open for us to add a `deallocate(capacity:)` method in the future, or perhaps even a `reallocate(toCapacity:)` method.

Along similar lines, the `bytes` and `alignedTo` parameters should be removed from the `deallocate(bytes:alignedTo:)` method on `UnsafeMutableRawPointer` and `UnsafeRawPointer`.

An unsized `deallocate()` method should be added to all pointer types, even immutable ones, as Swift’s memory model does not require memory to be mutable for deallocation. This fixes [SR-3309](https://bugs.swift.org/browse/SR-3309). Note, immutable raw buffer pointers already support this API.

> note: the deallocation size parameters were originally included in early versions of Swift in order to support a more sophisticated hypothetical heap allocator backend that we wanted to have in the future. (Swift currently calls `malloc(_:)` and `free()`.) While such a backend would theoretically run more efficiently than the C backend, overengineering Swift to support it in the future has proven to be a detriment to users right now. By removing the size parameters now, we make it easier and safer to reintroduce such an API in the future without inadvertently causing silent source breakage.

> note: changes to deallocation methods are not listed in the type-by-type overview below. All items in the following list are either non-source breaking, or trivially automigratable.

### `UnsafePointer<Pointee>`

#### Existing methods 

``` 
func withMemoryRebound<T, Result>(to:capacity:_:) -> Result
```

### `UnsafeMutablePointer<Pointee>`

#### Existing methods 

``` 
static 
func allocate<Pointee>(capacity:) -> UnsafeMutablePointer<Pointee>

func initialize(from:count:)
func moveInitialize(from:count:)

func assign(from:count:)
func moveAssign(from:count:)

func deinitialize(count:)
func withMemoryRebound<T, Result>(to:capacity:_:) -> Result
```

#### Renamed methods 

```diff 
--- func initialize(to:count:)
+++ func initialize(repeating:count:)
```

#### New methods 

```diff 
+++ func initializePointee(to:)
+++ func assign(repeating:count:)
```

### `UnsafeRawPointer`

#### Existing methods 

``` 
func bindMemory<T>(to:capacity:) -> UnsafePointer<T>
```

### `UnsafeMutableRawPointer`

#### Existing methods 

``` 
static 
func allocate(bytes:alignedTo:) -> UnsafeMutableRawPointer

func initializeMemory<T>(as:from:count:) -> UnsafeMutablePointer<T>
func moveInitializeMemory<T>(as:from:count:) -> UnsafeMutablePointer<T>

func bindMemory<T>(to:capacity:) -> UnsafeMutablePointer<T>
```

#### Renamed methods and dropped arguments

```diff 
--- func initializeMemory<T>(as:at:count:to:) -> UnsafeMutablePointer<T>
+++ func initializeMemory<T>(as:repeating:count:) -> UnsafeMutablePointer<T>

--- func copyBytes(from:count:) 
+++ func copyMemory(from:bytes:)
```

> note: We are adding a *new* default argument of `MemoryLayout<UInt>.alignment` for the `alignment` parameter in `allocate(bytes:alignedTo:)`. The rationale is that Swift is introducing a language-level default guarantee of word-aligned storage, so the default argument reflects Swift’s memory model. Higher alignments (such as 16-byte alignment) should be specified explicitly by the user.

### `UnsafeBufferPointer<Element>`

#### New methods 

```diff 
+++ func deallocate()

+++ withMemoryRebound<T, Result>(to:_:) -> Result
```

### `UnsafeMutableBufferPointer<Element>`

#### New methods 

```diff 
+++ static 
+++ func allocate<Element>(capacity:) -> UnsafeMutableBufferPointer<Element>
+++ func deallocate()

+++ func initialize(repeating:)
+++ func initialize(at:from:)
+++ func moveInitialize(at:from:)

+++ func assign(repeating:)
+++ func assign(at:from:)
+++ func moveAssign(at:from:)

+++ func deinitialize(at:count:)
+++ func withMemoryRebound<T, Result>(to:_:) -> Result
```

### `UnsafeRawBufferPointer`

#### Existing methods 

```
deallocate()
```

#### New methods 

```diff 
+++ func bindMemory<T>(to:) -> UnsafeBufferPointer<T>
```

### `UnsafeMutableRawBufferPointer`

#### Existing methods 

```
deallocate()
```

#### Renamed methods and new/renamed arguments 

```diff 
--- static 
--- func allocate(count:) -> UnsafeMutableRawBufferPointer
+++ static 
+++ func allocate(bytes:alignedTo:) -> UnsafeMutableRawBufferPointer

--- func copyBytes(from:) 
+++ func copyMemory(at:from:)
```

#### New methods 

```diff 
+++ func initializeMemory<T>(as:repeating:) -> UnsafeMutableBufferPointer<T>
+++ func initializeMemory<T>(atByteOffset:as:from:) -> UnsafeMutableBufferPointer<T>
+++ func moveInitializeMemory<T>(atByteOffset:as:from:) -> UnsafeMutableBufferPointer<T>

+++ func bindMemory<T>(to:) -> UnsafeMutableBufferPointer<T>
```

> note: for backwards compatibility, the `alignedTo:` argument in `allocate(bytes:alignedTo:)` should take a default value of `MemoryLayout<UInt>.alignment`. This requires [SR-5664](https://bugs.swift.org/browse/SR-5664) to be fixed before it will work properly.

> note: The new `at:` argument in `copyMemory(at:from:)` has a backwards-compatible default argument of `0`. This poses no risk to memory state safety, since this method can only perform a bytewise copy anyways.

## What this proposal does not do 

- **attempt to fully support partial initialization**

This proposal attempts to design a buffer interface that provides some semblance of memory state safety. However, it does not fully address issues relating to ergonomics such as

 - overloading `+` for buffer pointers, allowing “pointer arithmetic” to be performed on buffer pointers 
 - easier buffer pointer slicing, which does not produce wasteful `MutableRandomAccessSlice<UnsafeMutableBufferPointer<Element>>` structures
 
nor does it attempt to design a higher level buffer type which would be able to provide stronger memory state guarantees.

We expect possible solutions to these problems to purely additive, and would not require modifying the methods this proposal will introduce.

- **address problems relating to the generic `Sequence` buffer API**

Buffer pointers are currently missing generic `assign<S>(from:S)` and `initializeMemory<S>(as:S.Element.Type, from:S)` methods. The existing protocol oriented API also lacks polish and is inconvenient to use. (For example, it returns tuples.) This is an issue that can be tackled separately from the lower-level buffer-pointer-to-buffer-pointer API.

## Detailed design

```diff
struct UnsafePointer<Pointee>
{
+++ func deallocate()

    func withMemoryRebound<T, Result>(to:T.Type, capacity:Int, _ body:(UnsafePointer<T>) -> Result) 
         -> Result
}

struct UnsafeMutablePointer<Pointee>
{
    static func allocate<Pointee>(capacity:Int) -> UnsafeMutablePointer<Pointee>

--- func deallocate(capacity:Int)
+++ func deallocate()

--- func initialize(to:Pointee, count:Int = 1)
+++ func initialize(repeating:Pointee, count:Int)
+++ func initializePointee(to:Pointee)
    func initialize(from:UnsafePointer<Pointee>, count:Int)
    moveInitialize(from:UnsafeMutablePointer<Pointee>, count:Int)

+++ func assign(repeating:Pointee, count:Int)
    func assign(from:UnsafePointer<Pointee>, count:Int)
    func moveAssign(from:UnsafeMutablePointer<Pointee>, count:Int)

    func deinitialize(count:Int)

    func withMemoryRebound<T, Result>(to:T.Type, capacity:Int, _ body:(UnsafeMutablePointer<T>) -> Result) 
         -> Result
}

struct UnsafeRawPointer
{
--- func deallocate(bytes:Int, alignedTo:Int)
+++ func deallocate()

    func bindMemory<T>(to:T.Type, count:Int) -> UnsafeMutablePointer<T>
}

struct UnsafeMutableRawPointer
{
--- static 
--- func allocate(bytes:Int, alignedTo:Int) -> UnsafeMutableRawPointer
+++ static
+++ func allocate(bytes:Int, alignedTo:Int = MemoryLayout<UInt>.alignment) 
+++      -> UnsafeMutableRawPointer
--- func deallocate(bytes:Int, alignedTo:Int)
+++ func deallocate()

--- func initializeMemory<T>(as:T.Type, at:Int = 0, count:Int = 1, to:T) -> UnsafeMutablePointer<T>
+++ func initializeMemory<T>(as:T.Type, repeating:T, count:Int) -> UnsafeMutablePointer<T>

    func initializeMemory<T>(as:T.Type, from:UnsafePointer<T>, count:Int) -> UnsafeMutablePointer<T>
    func moveInitializeMemory<T>(as:T.Type, from:UnsafeMutablePointer<T>, count:Int) 
         -> UnsafeMutablePointer<T>

    func bindMemory<T>(to:T.Type, count:Int) -> UnsafeMutablePointer<T>

--- func copyBytes(from:UnsafeRawPointer, count:Int)
+++ func copyMemory(from:UnsafeRawPointer, bytes:Int)
}

struct UnsafeBufferPointer<Element>
{
+++ init(_:UnsafeMutableBufferPointer<Element>)

+++ func deallocate()

+++ func withMemoryRebound<T, Result>
+++ (to:T.Type, _ body:(UnsafeBufferPointer<T>) -> Result)
}

struct UnsafeMutableBufferPointer<Element> 
{
+++ init(mutating:UnsafeBufferPointer<Element>)

+++ static 
+++ func allocate<Element>(capacity:Int) -> UnsafeMutableBufferPointer<Element>

+++ func initialize(repeating:Element)
+++ func initialize(at:Int, from:UnsafeBufferPointer<Element>)
+++ func initialize(at:Int, from:UnsafeMutableBufferPointer<Element>)
+++ func moveInitialize(at:Int, from:UnsafeMutableBufferPointer<Element>)

+++ func assign(repeating:Element)
+++ func assign(at:Int, from:UnsafeBufferPointer<Element>)
+++ func assign(at:Int, from:UnsafeMutableBufferPointer<Element>)
+++ func moveAssign(at:Int, from:UnsafeMutableBufferPointer<Element>)

+++ func deinitialize(at:Int, count:Int)

+++ func withMemoryRebound<T, Result>
+++ (to:T.Type, _ body:(UnsafeMutableBufferPointer<T>) -> Result)
}

struct UnsafeRawBufferPointer
{
    func deallocate()
    
+++ func bindMemory<T>(to:T.Type) -> UnsafeBufferPointer<T>
}

struct UnsafeMutableRawBufferPointer 
{
--- static func allocate(count:Int) -> UnsafeMutableRawBufferPointer
+++ static func allocate(bytes:Int, alignedTo:Int = MemoryLayout<UInt>.alignment) 
+++      -> UnsafeMutableRawBufferPointer
    func deallocate()

+++ func initializeMemory<T>(as:T.Type, repeating:T) -> UnsafeMutableBufferPointer<T>
+++ func initializeMemory<T>(atByteOffset:Int, as:T.Type, from:UnsafeBufferPointer<T>) 
+++      -> UnsafeMutableBufferPointer<T>
+++ func initializeMemory<T>(atByteOffset:Int, as:T.Type, from:UnsafeMutableBufferPointer<T>) 
+++      -> UnsafeMutableBufferPointer<T>
+++ func moveInitializeMemory<T>(atByteOffset:Int, as:T.Type, from:UnsafeMutableBufferPointer<T>) 
+++      -> UnsafeMutableBufferPointer<T>

+++ func bindMemory<T>(to:T.Type) -> UnsafeMutableBufferPointer<T>

--- func copyBytes(from:UnsafeRawBufferPointer)
+++ func copyMemory(at:Int = 0, from:UnsafeRawBufferPointer)
+++ func copyMemory(at:Int = 0, from:UnsafeMutableRawBufferPointer)
}
```

## Source compatibility

- **fix the ordering of the arguments in `initializeMemory<Element>(as:at:count:to:)` and rename the argument `to:` to `repeating:` in all repeated-value copy functions**

This change is source breaking but can be trivially automigrated.

- **add the repeated-value copy assignment method `assign(repeating:count:)`**

This change is purely additive.

- **rename `copyBytes(from:count:)` and `copyBytes(from:)` to `copyMemory(from:bytes:)` and `copyMemory(at:from:)`**

This change is source breaking but can be trivially automigrated.

- **rename `count` in `UnsafeMutableRawBufferPointer.allocate(count:)` to `bytes` and add an `alignedTo` parameter to make it `UnsafeMutableRawBufferPointer.allocate(bytes:alignedTo:)`**

This change is source breaking but can be trivially automigrated. The `alignedTo:` parameter can be filled in with `MemoryLayout<UInt>.stride`. If [SR-5664](https://bugs.swift.org/browse/SR-5664) is fixed, `MemoryLayout<UInt>.stride` can even be provided as a default argument.

- **add an `init(mutating:)` initializer to `UnsafeMutableBufferPointer`**

This change is purely additive.

- **add a mutable overload to the `copyMemory(at:from:)` method on `UnsafeMutableRawBufferPointer`, the `initialize(at:from:)` and `assign(at:from:)` methods on `UnsafeMutableBufferPointer`, and the `initializeMemory<T>(atByteOffset:as:from:)` method on `UnsafeMutableRawBufferPointer`**

This change is purely additive.

- **add `deallocate()` to all pointer types, replacing any existing deallocation methods**

This change is source-breaking, but this is a Good Thing™. The current API encourages incorrect code to be written, and sets us up for potentially catastrophic source breakage down the road should the implementations of `deallocate(capacity:)` and `deallocate(bytes:alignedTo:)` ever be “fixed”, so users should be forced to stop using them as soon as possible.


## Effect on ABI stability

Removing sized deallocators changes the existing ABI, as will renaming some of the methods and their argument labels. 

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
