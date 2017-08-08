# Improved pointers

* Proposal: [SE-0184](0184-improved-pointers.md)
* Author: [Kelvin Ma (“Taylor Swift”)](https://github.com/kelvin13)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

Swift’s pointer types are an important interface for low-level memory manipulation, but the current API design is not very consistent, complete, or convenient. Many memory methods demand a `capacity:` or `count:` argument, forcing the user to manually track the size of the memory block, even though most of the time this is either unnecessary, or redundant as buffer pointers track this information natively. In some places, poor naming choices and overengineered function signatures compromise memory safety by leading users to believe that they have allocated or freed memory when in fact, they have not.

This proposal seeks to improve the Swift pointer API by ironing out naming inconsistencies, adding sensible default argument values, adding missing methods, and reducing excessive verbosity, offering a more convenient, more sensible, and less bug-prone API.

The [previous draft](https://gist.github.com/kelvin13/a9c033193a28b1d4960a89b25fbffb06) of this proposal was relatively source-breaking, calling for a separation of functionality between singular pointer types and vector (buffer) pointer types. This proposal instead separates functionality between internally-tracked length pointer types and externally-tracked length pointer types. This results in an equally elegant API with about one-third less surface area.

Swift-evolution thread: [Pitch: Improved Swift pointers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170710/038013.html), [Pitch: More Improved Swift pointers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170717/038121.html)

## Motivation

Right now, `UnsafeMutableBufferPointer` is kind of a black box when it comes to producing and modifying instances of it. To create, bind, allocate, initialize, deinitialize, and deallocate them, you have to extract `baseAddress`es and `count`s. This is unfortunate because `UnsafeMutableBufferPointer` provides a handy container for tracking the size of a memory buffer, but to actually make use of this information, the buffer pointer must be disassembled. In practice, this means the use of memory buffers requires frequent (and annoying) conversion back and forth between buffer pointers and base address–count pairs. For example, to move-initialize memory between two buffer pointers, you have to write this:

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

Inconsistencies exist in the memorystate functions. The `initialize(from:count:)` method on `UnsafeMutablePointer` has a repeating variant, `initialize(to:count:)`, but `assign(from:count:)` has no such variant, even though it would make just as much sense for it to have one.

While most of the memorystate functions are absent from `UnsafeMutableBufferPointer`, there is *one* strange exception — `UnsafeMutableBufferPointer` features an `initialize<S>(from:)` method which takes a `Sequence`. This method was originally an inhabitant of `UnsafeMutablePointer` before it was [supposedly](https://github.com/apple/swift-evolution/blob/master/proposals/0147-move-unsafe-initialize-from.md#detailed-design) moved to `UnsafeMutableBufferPointer` by [SE-147](https://github.com/apple/swift-evolution/blob/master/proposals/0147-move-unsafe-initialize-from.md). This decision appears to have never been carried out, as the type still features an active `initialize<C>(from:)` method which takes a `Collection`. (The original SE-147 method took a `Collection`.)

Finally, the naming of some `UnsafeMutableRawPointer` members deserves a second look. While the original API intended to introduce a naming convention where `bytes` refers to uninitialized memory, `capacity` to uninitialized elements, and `count` to initialized elements, the actual usage of the three words does not always agree. In `copyBytes(from:count:)`, `count` refers to the number of *bytes*, which may or may not be initialized. Similarly, the `UnsafeMutableRawBufferPointer` `allocate(count:)` type method includes a `count` argument which actually refers to uninitialized bytes.

## Proposed solution

The presence of an associated `count` variable in `UnsafeMutableBufferPointer`, and the absence of it in `UnsafeMutablePointer` leads to a very natural and elegant set of memory APIs. Because buffer length is tracked externally when using `UnsafeMutablePointer`, memory methods on it should explicitly ask for the sizing parameter. Conversely, because buffer length is tracked internally by `UnsafeMutableBufferPointer`, memory methods on it should supply the buffer’s own `count` property for the operation’s sizing parameter. This means you would call 

```swift
ptr1.initialize(from: ptr2, count: count)
```

on an `UnsafeMutablePointer`, but 

```swift
buffer1.initialize(from: buffer2)
```

on an `UnsafeMutableBufferPointer`. This differs from the [previous draft](https://gist.github.com/kelvin13/a9c033193a28b1d4960a89b25fbffb06) of this proposal, in that this expansion is more additive and less source-breaking, preserving the much of the sized API present on `UnsafeMutablePointer`.

In detail, the following changes should be made:

- **remove the `capacity` parameter from `deallocate(capacity:)` and `deallocate(bytes:alignedTo:)`**

Removing `capacity` from `deallocate(capacity:)` will end the confusion over what `deallocate()` does, making it obvious that `deallocate()` will free the *entire* memory block at `self`, just as if `free()` were called on it.

The old `deallocate(capacity:)` method should be marked as `unavailable` since it currently encourages dangerously incorrect code. This avoids misleading future users, forces current users to address this potentially catastrophic memory bug, and leaves the possibility open for us to add a `deallocate(capacity:)` method in the future, or perhaps even a `reallocate(toCapacity:)` method.

Along similar lines, the `bytes` and `alignedTo` parameters should be removed from the `deallocate(bytes:alignedTo:)` method on `UnsafeMutableRawPointer`.

- **add unsized memory methods to `UnsafeMutableBufferPointer`**

The following methods will be added to `UnsafeMutableBufferPointer`, giving it parity with `UnsafeMutablePointer`.

```swift 
static func allocate<Element>(capacity:Int) -> UnsafeMutableBufferPointer<Element>
func deallocate()

func assign(from:UnsafeBufferPointer<Element>)
func moveAssign(from:UnsafeMutableBufferPointer<Element>)
func moveInitialize(from:UnsafeMutableBufferPointer<Element>)
func initialize(from:UnsafeBufferPointer<Element>)
func initialize(to:Element)
func deinitialize()
```

Where there would have been a `capacity:` or `count:` argument on these methods, this value will be filled by the buffer pointer’s own `count` property. For the binary operations `assign(from:)`, `moveAssign(from:)`, `moveInitialize(from:)`, and `initialize(from:)`, it is assumed that the other buffer pointer contains *at least* as many elements as `self` does.

- **add an `assign(to:count:)` method to `UnsafeMutablePointer` and an `assign(to:)` method to `UnsafeMutableBufferPointer`**

This addresses the missing assignment analogues to the `initialize(to:count:)` and `initialize(to:)` methods.

- **add a default value of `1` to all size parameters on `UnsafeMutablePointer` and applicable size parameters on `UnsafeMutableRawPointer`**

Since the most common use case for plain pointers is to manage one single instance of a type, the size parameters on `UnsafeMutablePointer`’s memory methods are good candidates for a default value of `1`. Any size parameter on `UnsafeMutableRawPointer`’s memory methods which take a stride quantity should also receive a default value of `1`. The size parameters in `UnsafeMutableRawPointer`’s other methods should not receive a default value as they refer to byte quantities.

- **rename `copyBytes(from:count:)` to `copy(from:bytes:)`**

To reduce the inconsistency in our use of the words `bytes`, `count`, and `capacity`, we will enforce the convention that:

* `bytes` refers to, well, a byte quantity that is *not assumed* to be initialized.
* `capacity` refers to a strided quantity that is *not assumed* to be initialized.
* `count` refers to a strided quantity that is *assumed* to be initialized.

Since this makes the word “bytes” occur twice in `copyBytes(from:bytes:)`, we should drop the “Bytes” suffix and further rename the method to `copy(from:bytes:)`. Since `UnsafeMutableRawPointer` is inherently untyped, it is obvious that any memory transfer operation on it is a bytewise operation so the “Bytes” suffix adds only verbosity and no clarity. An unsized version of this method will also be added to `UnsafeMutableRawBufferPointer`.

We do not rename the `count` property on `UnsafeMutableRawBufferPointer` to `bytes` since this could be confused with the actual buffer data.

- **rename `count` in `UnsafeMutableRawBufferPointer.allocate(count:)` to `bytes` and add an `alignedTo` parameter to make it `UnsafeMutableRawBufferPointer.allocate(bytes:alignedTo:)`**

This brings it in line with the `UnsafeMutableRawPointer` allocator, and avoids the contradictory and inconsistent use of `count` to represent a byte quantity. Currently `UnsafeMutableRawBufferPointer.allocate(count:)` aligns to the size of `Int`, an assumption not shared by its plain variant.

- **fix the ordering of the arguments in `initializeMemory<Element>(as:at:count:to:)` and rename the argument `to:` to `repeating:` in all repeating memorystate functions**

The ordering of the `to:` and `count:` argument labels in the `initializeMemory<Element>(as:at:count:to:)` method on `UnsafeMutableRawPointer` contradicts the rest of the Swift pointer API, where `to:` precedes `count:`. 

Because the ordering `initializeMemory<Element>(as:at:to:count:)` conflicts with the use of `to:` as the argument label for a target type, this argument should be renamed to `repeating:`. The word `repeating:` is much more clear in terms of describing the methods’ behavior, and is consistent with the use of the word in the `Array` API.

- **add the sized memorystate functions `withMemoryRebound<Element, Result>(to:count:_:)` to `UnsafeMutableBufferPointer`, and `initializeMemory<Element>(as:at:repeating:count:)`, `initializeMemory<Element>(as:from:count:)` `moveInitializeMemory<Element>(as:from:count:)`, and `bindMemory<Element>(to:count:)` to `UnsafeMutableRawBufferPointer`**

Since buffer pointers track their own `count`, this value is a natural fit for the `count:` argument in most of the memorystate functions. However, since raw buffer pointers don’t inherently “know” how many instances of an arbitrary type fit in themselves, `initializeMemory<Element>(as:at:repeating:count:)` and `bindMemory<Element>(to:capacity:)` should retain their size parameters.

For similar reasons, `UnsafeMutableBufferPointer.withMemoryRebound<T, Result>(to:capacity:_:)` keeps its size parameter because `capacity` may be different from `count` with a differently laid out type.

- **add a `init(mutating:)` initializer to `UnsafeMutableBufferPointer`**

This makes it much easier to make a mutable copy of an immutable buffer pointer. Such an initializer already exists on `UnsafeMutableRawBufferPointer`, so adding one to `UnsafeMutableBufferPointer` is also necessary for consistency. The reverse initializer, from `UnsafeMutableBufferPointer` to `UnsafeBufferPointer` should also be added for completeness.

- **add mutable overloads to non-vacating memorystate method arguments on `UnsafeMutableBufferPointer` and `UnsafeMutableRawBufferPointer`**

Non vacating memorystate operations such as `assign(from:)` and `initialize(from:)` on `UnsafeMutableBufferPointer`, and `copy(from:)` and `initializeMemory(at:from:count:)` on `UnsafeMutableRawBufferPointer` currently take immutable source arguments. They should be overloaded to accept mutable source arguments to reduce the need for pointer immutability casts. Currently, for plain pointers, this is covered by a compiler subtyping relationship between `UnsafePointer` and `UnsafeMutablePointer`. No such relationship exists between `UnsafeBufferPointer` and `UnsafeMutableBufferPointer` or their raw counterparts.

- **finally deprecate `initialize<C>(from:)` from `UnsafeMutablePointer`**

This method was supposed to be deprecated per [SE-147](https://github.com/apple/swift-evolution/blob/master/proposals/0147-move-unsafe-initialize-from.md). Better late than never.


## What this proposal does not do 

- **add missing memorystate functions that take `Collection`s and `Sequence`s**

This proposal also does not address the missing `Collection`/`Sequence` memorystate functions, although it does call for (finally) removing `UnsafeMutablePointer.initialize<C>(from:)`. This is out of scope for this proposal, and the missing functions can always be filled in at a later date, as part of a purely additive proposal.

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

--- func initialize<C>(from:C)

+++ func assign(repeating:Pointee, count:Int = 1)

--- func assign(from:UnsafePointer<Pointee>, count:Int)
--- func moveAssign(from:UnsafeMutablePointer<Pointee>, count:Int)
--- func moveInitialize(from:UnsafeMutablePointer<Pointee>, count:Int)
--- func initialize(from:UnsafePointer<Pointee>, count:Int)
--- func initialize(to:Pointee, count:Int)
--- func deinitialize(count:Int)
--- func withMemoryRebound<T, Result>(to:T.Type, count:Int, _ body:(UnsafeMutablePointer<T>) -> Result)

+++ func assign(from:UnsafePointer<Pointee>, count:Int = 1)
+++ func moveAssign(from:UnsafeMutablePointer<Pointee>, count:Int = 1)
+++ func moveInitialize(from:UnsafeMutablePointer<Pointee>, count:Int = 1)
+++ func initialize(from:UnsafePointer<Pointee>, count:Int = 1)
+++ func initialize(repeating:Pointee, count:Int = 1)
+++ func deinitialize(count:Int = 1)
+++ func withMemoryRebound<T, Result>(to:T.Type, count:Int = 1, _ body:(UnsafeMutablePointer<T>) -> Result)
}

struct UnsafeMutableRawPointer
{
--- func deallocate(bytes _:Int, alignedTo _:Int)
+++ func deallocate()

--- func copyBytes(from:UnsafeRawPointer, count:Int)
+++ func copy(from:UnsafeRawPointer, bytes:Int)
--- func initializeMemory<T>(as:T.Type, at:Int, count:Int, to:T)
+++ func initializeMemory<T>(as:T.Type, at:Int, repeating:T, count:Int = 1)

--- func initializeMemory<C>(as:C.Element.Type, from:C)

--- func bindMemory<T>(to:T.Type, count:Int)
--- func initializeMemory<T>(as:T.Type, from:UnsafePointer<T>, count:Int)
--- func moveInitializeMemory<T>(as:T.Type, from:UnsafeMutablePointer<T>, count:Int)

+++ func bindMemory<T>(to:T.Type, count:Int = 1)
+++ func initializeMemory<T>(as:T.Type, from:UnsafePointer<T>, count:Int = 1)
+++ func moveInitializeMemory<T>(as:T.Type, from:UnsafeMutablePointer<T>, count:Int = 1)
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

+++ func assign(from:UnsafeBufferPointer<Element>)
+++ func assign(from:UnsafeMutableBufferPointer<Element>)
+++ func assign(repeating:Element)
+++ func moveAssign(from:UnsafeMutableBufferPointer<Element>)
+++ func moveInitialize(from:UnsafeMutableBufferPointer<Element>)
+++ func initialize(from:UnsafeBufferPointer<Element>)
+++ func initialize(from:UnsafeMutableBufferPointer<Element>)
+++ func initialize(repeating:Element)
+++ func deinitialize()
+++ func withMemoryRebound<T, Result>
+++ (to:T.Type, count:Int, _ body:(UnsafeMutableBufferPointer<T>) -> Result)
}

struct UnsafeMutableRawBufferPointer
{
--- static func allocate(count:Int) -> UnsafeMutableRawBufferPointer
+++ static func allocate(bytes:Int, alignedTo:Int) -> UnsafeMutableRawBufferPointer
    func deallocate()
+++ func bindMemory<Element>(to:Element.Type, count:Int)
--- func copyBytes(from:UnsafeRawBufferPointer)
+++ func copy(from:UnsafeRawBufferPointer)
+++ func copy(from:UnsafeMutableRawBufferPointer)
+++ func initializeMemory<Element>(as:Element.Type, at:Int, repeating:Element, count:Int)
+++ func initializeMemory<Element>(as:Element.Type, from:UnsafeBufferPointer<Element>, count:Int)
+++ func initializeMemory<Element>(as:Element.Type, from:UnsafeMutableBufferPointer<Element>, count:Int)
+++ func moveInitializeMemory<Element>(as:Element.Type, from:UnsafeMutableBufferPointer<Element>, count:Int)
}
```

## Source compatibility

Some parts of this proposal are source breaking. This proposal is significantly less source breaking than its [previous iteration](https://gist.github.com/kelvin13/a9c033193a28b1d4960a89b25fbffb06).

- **remove the `capacity` parameter from `deallocate(capacity:)` and `deallocate(bytes:alignedTo:)`**

This change is source-breaking, but this is a Good Thing™. The current API encourages incorrect code to be written, and sets us up for potentially catastrophic source breakage down the road should the implementations of `deallocate(capacity:)` and `deallocate(bytes:alignedTo:)` ever be “fixed”, so users should be forced to stop using them as soon as possible.

- **add unsized memory methods to `UnsafeMutableBufferPointer`**

This change is purely additive.

- **add an `assign(to:count:)` method to `UnsafeMutablePointer` and an `assign(to:)` method to `UnsafeMutableBufferPointer`**

This change is purely additive.

- **add a default value of `1` to all size parameters on `UnsafeMutablePointer` and applicable size parameters on `UnsafeMutableRawPointer`**

This change is purely additive.

- **rename `copyBytes(from:count:)` to `copy(from:bytes:)`**

This change is source breaking but can be trivially automigrated.

- **rename `count` in `UnsafeMutableRawBufferPointer.allocate(count:)` to `bytes` and add an `alignedTo` parameter to make it `UnsafeMutableRawBufferPointer.allocate(bytes:alignedTo:)`**

This change is source breaking but can be trivially automigrated. The `alignedTo:` parameter can be filled in with `MemoryLayout<Int>.stride`.

- **fix the ordering of the arguments in `initializeMemory<Element>(as:at:count:to:)` and rename the argument `to:` to `repeating:` in all repeating memorystate functions**

This change is source breaking but can be trivially automigrated.

- **add the sized memorystate functions `withMemoryRebound<Element, Result>(to:count:_:)` to `UnsafeMutableBufferPointer`, and `initializeMemory<Element>(as:at:repeating:count:)`, `initializeMemory<Element>(as:from:count:)` `moveInitializeMemory<Element>(as:from:count:)`, and `bindMemory<Element>(to:count:)` to `UnsafeMutableRawBufferPointer`**

This change is purely additive.

- **add a `init(mutating:)` initializer to `UnsafeMutableBufferPointer`**

This change is purely additive.

- **add mutable overloads to non-vacating memorystate method arguments on `UnsafeMutableBufferPointer` and `UnsafeMutableRawBufferPointer`**

This change is purely additive.

- **finally deprecate `initialize<C>(from:)` from `UnsafeMutablePointer`**

This change is source-breaking only for the reason that such code should never have compiled in the first place.

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
