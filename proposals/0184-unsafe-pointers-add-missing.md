# Unsafe[Mutable][Raw][Buffer]Pointer: add missing methods, adjust existing labels for clarity, and remove deallocation size

* Proposal: [SE-0184](0184-unsafe-pointers-add-missing.md)
* Author: [Kelvin Ma (“Taylor Swift”)](https://github.com/kelvin13)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 4.1)**
* Implementation: [apple/swift#12200](https://github.com/apple/swift/pull/12200)
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20171002/040248.html)


## Introduction

*This document is a spin-off from a much larger [original proposal](https://github.com/kelvin13/swift-evolution/blob/e888af466c9993de977f6999a131eadd33291b06/proposals/0184-unsafe-pointers-add-missing.md), which covers only those aspects of SE-1084 which do not deal with partial buffer memory state. Designing the partial buffer memory state API clearly requires more work, and has been left out of the scope of this document.*

Swift’s pointer types are an important interface for low-level memory manipulation, but the current API design is not very consistent, complete, or convenient. In some places, poor naming choices and overengineered function signatures compromise memory safety by leading users to believe that they have allocated or freed memory when in fact, they have not. This proposal seeks to improve the Swift pointer API by ironing out naming inconsistencies, adding missing methods, and reducing excessive verbosity, offering a more convenient, more sensible, and less bug-prone API. 

Swift-evolution threads: [Pitch: Improved Swift pointers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170710/038013.html), [Pitch: More Improved Swift pointers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170717/038121.html)

Implementation branch: [`kelvin13:se-0184a`](https://github.com/kelvin13/swift/tree/se-0184a)

## Background 

There are four binary memorystate operations: *initialization*, *move-initialization*, *assignment*, and *move-assignment*, and two unary memorystate operations: *deinitialization* and *type rebinding*. The binary operations can be grouped according to how they affect the source buffer and the destination buffer. **Copy** operations only read from the source buffer, leaving it unchanged. **Move** operations deinitialize the source memory, decrementing the reference count by 1 if the memory type is not a trivial type. **Retaining** operations initialize the destination memory, incrementing the reference count by 1 if applicable. **Releasing** operations deinitialize the destination memory before reinitializing it with the new values, resulting in a net change in the reference count of 0, if applicable.

|                    | Copy (+0)  | Move (−1)       |
| -------------:     |----------: | ---------:      |
| **Retaining (+1)** | initialize | move-initialize |
| **Releasing (+0)** | assign     |  move-assign    |

Raw pointers also have a unique operation, *bytewise-copying*, which we will lump together with the memorystate functions, but does not actually change a pointer’s memory state. 

Most of these operations become more relevant in the discussion of partial buffer memory state, which is not in the scope of this document. This document only proposes changes related to memory allocation, type-rebinding, and two special *unary* forms of initialization and assignment which initialize memory to a fixed, repeating value.

## Motivation

Right now, `UnsafeMutableBufferPointer` is kind of a black box when it comes to producing and modifying instances of it. Much of the API present on `UnsafeMutablePointer` is absent on its buffer variant. To create, bind, allocate, initialize, and deallocate them, you have to extract `baseAddress`es and `count`s. This is unfortunate because `UnsafeMutableBufferPointer` provides a handy container for tracking the size of a memory buffer, but to actually make use of this information, the buffer pointer must be disassembled. In practice, this means the use of memory buffers requires frequent (and annoying) conversion back and forth between buffer pointers and base address–count pairs. For example, buffer allocation requires the creation of a temporary `UnsafeMutablePointer` instance. This means that the following “idiom” is very common in Swift code:

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

The `?` is sometimes exchanged with an `!` depending on the personality of the author, as normally, neither operator is meaningful here — the `baseAddress` is never `nil` if the buffer pointer was created around an instance of `UnsafeMutablePointer`. 

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

Finally, some of the naming choices in the current API deserve a second look. While the original API intended to introduce a naming convention where `bytes` refers to uninitialized memory, `capacity` to uninitialized elements, and `count` to initialized elements, the actual usage of the three words does not always agree. In `copyBytes(from:count:)`, `count` refers to the number of *bytes*, which may or may not be initialized. Similarly, the `UnsafeMutableRawBufferPointer` `allocate(count:)` type method includes a `count` argument which actually refers to uninitialized bytes. The argument label `to:` is also excessively overloaded; sometimes it refers to a type `T.Type`, and sometimes it refers to a repeated value parameter. This becomes problematic when both parameters appear in the same method, as in `initializeMemory<T>(as:at:count:to)`.

## Proposed solution

The ultimate goal of the API redesign is to bring all of the functionality in `UnsafeMutablePointer` and `UnsafeMutableRawPointer` to their buffer types, `UnsafeMutableBufferPointer` and `UnsafeMutableRawBufferPointer`. Operations which are covered by this proposal are in **bold**.

The full toolbox of methods that we could possibly support includes:

 - **allocation**
 - **deallocation** 
 
 - initialization 
 - move-initialization 
 
 - assignment 
 - move-assignment 
 
 - deinitialization 
 
 - **type rebinding** 
 - bytewise copying 

Because copy operations (initialization and assignment) don’t mutate the source argument, they can also come in a form which takes a repeated-value source instead of a buffer source.

 - **initialization (repeated-value)**
 - **assignment (repeated-value)**
 
`UnsafeMutablePointer` and `UnsafeMutableRawPointer` already contain repeated-value methods for initialization in the form of `initialize(to:count:)` and `initializeMemory<T>(as:at:count:to:)`. This proposal will add the assignment analogues. For reasons explained later, the argument label for the repeated-value parameter will be referred to as `repeating:`, not `to:`.

### `UnsafePointer<Pointee>`

``` 
func deallocate()
func withMemoryRebound<T, Result>(to:capacity:_:) -> Result
```

`UnsafePointer` does not get an allocator static method, since you almost always want a mutable pointer to newly allocated memory. Its type rebinding method is also written as a decorator, taking a trailing closure, for memory safety.

Most immutable pointer types currently do not have a deallocation method. This proposal adds them, fixing [SR-3309](https://bugs.swift.org/browse/SR-3309). Note, immutable raw buffer pointers already support this API.

### `UnsafeMutablePointer<Pointee>`

``` 
static 
func allocate<Pointee>(capacity:) -> UnsafeMutablePointer<Pointee>
func deallocate()

func initialize(repeating:count:)
func initialize(to:)

func assign(repeating:count:)

func withMemoryRebound<T, Result>(to:capacity:_:) -> Result
```

Like `UnsafePointer`, `UnsafeMutablePointer`’s type rebinding method is written as a decorator. 

Previously, the single-element repeated-initialization case was supported by a default argument of `1` on `initialize(repeating:count:)`’s `count:` parameter, but it was decided this was too confusing in terms of API readability. For example, calls to `initialize(repeating:count:)` and its corresponding method on `UnsafeMutableBufferPointer` were prone to look the same. 

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
func allocate(byteCount:alignment:) -> UnsafeMutableRawPointer
func deallocate()

func initializeMemory<T>(as:repeating:count:) -> UnsafeMutablePointer<T>

func bindMemory<T>(to:capacity:) -> UnsafeMutablePointer<T>
```

Currently, `UnsafeMutableRawPointer`’s methods take an `at:` offset argument that is interpreted in strides. This argument is not currently in use in the entire Swift standard library, and we believe that it is not useful in practice. 

Unlike `UnsafeMutablePointer`, we do not add a single-instance initialize method to `UnsafeMutableRawPointer`, as such a method would probably not be useful. However, we still remove the default argument of `1` from the `count:` argument in `initializeMemory<T>(as:repeating:count:)` to prevent confusion with calls to its buffer variant.

### `UnsafeBufferPointer<Element>`

``` 
func deallocate()
func withMemoryRebound<T, Result>(to:_:) -> Result
```

The buffer type rebind method dynamically computes the new count by performing multiplication and integer division, since the target type may have a different stride than the original type. This is in line with existing precedent in the generic buffer method `initializeMemory<S>(as:from:)` on `UnsafeMutableRawBufferPointer`.

> Note: **calling `deallocate()` on a buffer pointer is only defined behavior if the buffer pointer references a complete heap memory block**. This operation may become supported in a wider variety of cases in the future if Swift gets a more sophisticated heap allocation backend.

### `UnsafeMutableBufferPointer<Element>`

``` 
static 
func allocate<Element>(capacity:) -> UnsafeMutableBufferPointer<Element>
func deallocate()

func initialize(repeating:)

func assign(repeating:)

func withMemoryRebound<T, Result>(to:_:) -> Result
```

The buffer type rebind method works the same way as in `UnsafeBufferPointer`. (Type rebinding never cares about mutability.)

### `UnsafeRawBufferPointer`

``` 
func deallocate()

func bindMemory<T>(to:) -> UnsafeBufferPointer<T>
```

### `UnsafeMutableRawBufferPointer`

``` 
static 
func allocate(byteCount:alignment:) -> UnsafeMutableRawBufferPointer
func deallocate()

func initializeMemory<T>(as:repeating:) -> UnsafeMutableBufferPointer<T>

func bindMemory<T>(to:) -> UnsafeMutableBufferPointer<T>
```

> note: `initializeMemory(as:repeating:)` performs integer division on `self.count` (just like `bindMemory(to:)`) 

> note: the return value of `initializeMemory(as:repeating:)` should be marked as `@discardableResult`. 

We also make several miscellaneous changes to the API in order to tidy things up. 

- **rename `copyBytes(from:count:)` and `copyBytes(from:)` to `copyMemory(from:byteCount:)` and `copyMemory(from:)`**

This brings the method names in line with the rest of the raw pointer API.

- **add an `init(mutating:)` initializer to `UnsafeMutableBufferPointer`**

This makes it much easier to make a mutable copy of an immutable buffer pointer. Such an initializer already exists on `UnsafeMutableRawBufferPointer`, so adding one to `UnsafeMutableBufferPointer` is also necessary for consistency. The reverse initializer, from `UnsafeMutableBufferPointer` to `UnsafeBufferPointer` should also be added for completeness.

- **deprecate the sized deallocation API**

Removing `capacity` from `deallocate(capacity:)` will end the confusion over what `deallocate()` does, making it obvious that `deallocate()` will free the *entire* memory block at `self`, just as if `free()` were called on it.

The old `deallocate(capacity:)` method should be marked as `deprecated` and eventually removed since it currently encourages dangerously incorrect code. This avoids misleading future users, encourages current users to address this potentially catastrophic memory bug, and leaves the possibility open for us to add a `deallocate(capacity:)` method in the future, or perhaps even a `reallocate(toCapacity:)` method.

Along similar lines, the `bytes` and `alignedTo` parameters should be removed from the `deallocate(bytes:alignedTo:)` method on `UnsafeMutableRawPointer` and `UnsafeRawPointer`.

As discussed earlier, an unsized `deallocate()` method should be added to all pointer types, even immutable ones, as Swift’s memory model does not require memory to be mutable for deallocation. 

> note: the deallocation size parameters were originally included in early versions of Swift in order to support a more sophisticated hypothetical heap allocator backend that we wanted to have in the future. (Swift currently calls `malloc(_:)` and `free()`.) While such a backend would theoretically run more efficiently than the C backend, overengineering Swift to support it in the future has proven to be a detriment to users right now. By removing the size parameters now, we make it easier and safer to reintroduce such an API in the future without inadvertently causing silent source breakage.

> note: changes to deallocation methods are not listed in the type-by-type overview below. All items in the following list are either non-source breaking, or trivially automigratable.

### `UnsafePointer<Pointee>`

#### Existing methods 

``` 
func withMemoryRebound<T, Result>(to:capacity:_:) -> Result
```

#### New methods 

```diff 
+++ func deallocate()
```

### `UnsafeMutablePointer<Pointee>`

#### Existing methods 

``` 
static 
func allocate<Pointee>(capacity:) -> UnsafeMutablePointer<Pointee>

func withMemoryRebound<T, Result>(to:capacity:_:) -> Result
```

#### Renamed methods 

```diff 
--- func initialize(to:count:)
+++ func initialize(repeating:count:)
```

#### New methods 

```diff 
+++ func deallocate()

+++ func initialize(to:)
+++ func assign(repeating:count:)
```

### `UnsafeRawPointer`

#### Existing methods 

``` 
func bindMemory<T>(to:capacity:) -> UnsafePointer<T>
```

#### New methods 

```diff 
+++ func deallocate()
```

### `UnsafeMutableRawPointer`

#### Existing methods 

``` 
func bindMemory<T>(to:capacity:) -> UnsafeMutablePointer<T>
```

#### New methods 

```diff 
+++ func deallocate()
```

#### Renamed methods and dropped arguments

```diff 
--- static 
--- func allocate(bytes:alignedTo:) -> UnsafeMutableRawPointer

+++ static 
+++ func allocate(byteCount:alignment:) -> UnsafeMutableRawPointer

--- func initializeMemory<T>(as:at:count:to:) -> UnsafeMutablePointer<T>
+++ func initializeMemory<T>(as:repeating:count:) -> UnsafeMutablePointer<T>

--- func copyBytes(from:count:) 
+++ func copyMemory(from:byteCount:)
```

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
+++ func assign(repeating:)

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
+++ func allocate(byteCount:alignment:) -> UnsafeMutableRawBufferPointer

--- func copyBytes(from:) 
+++ func copyMemory(from:)
```

#### New methods 

```diff 
+++ func initializeMemory<T>(as:repeating:) -> UnsafeMutableBufferPointer<T>

+++ func bindMemory<T>(to:) -> UnsafeMutableBufferPointer<T>
```

## What this proposal does not do 

- **attempt to fully partial initialization**

This proposal does not attempt to fill in most of the memory state APIs for buffer pointers, as doing so necessitates designing a partial initialization system, as well as a possible buffer slice rework.

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
+++ func initialize(to:Pointee)
    func initialize(from:UnsafePointer<Pointee>, count:Int)
    func moveInitialize(from:UnsafeMutablePointer<Pointee>, count:Int)

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
+++ func allocate(byteCount:Int, alignment:Int) -> UnsafeMutableRawPointer
--- func deallocate(bytes:Int, alignedTo:Int)
+++ func deallocate()

--- func initializeMemory<T>(as:T.Type, at:Int = 0, count:Int = 1, to:T) -> UnsafeMutablePointer<T>
+++ func initializeMemory<T>(as:T.Type, repeating:T, count:Int) -> UnsafeMutablePointer<T>

    func initializeMemory<T>(as:T.Type, from:UnsafePointer<T>, count:Int) -> UnsafeMutablePointer<T>
    func moveInitializeMemory<T>(as:T.Type, from:UnsafeMutablePointer<T>, count:Int) 
         -> UnsafeMutablePointer<T>

    func bindMemory<T>(to:T.Type, count:Int) -> UnsafeMutablePointer<T>

--- func copyBytes(from:UnsafeRawPointer, count:Int)
+++ func copyMemory(from:UnsafeRawPointer, byteCount:Int)
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
+++ func assign(repeating:Element)

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
+++ static func allocate(byteCount:Int, alignment:Int) -> UnsafeMutableRawBufferPointer
    func deallocate()

+++ func initializeMemory<T>(as:T.Type, repeating:T) -> UnsafeMutableBufferPointer<T>

+++ func bindMemory<T>(to:T.Type) -> UnsafeMutableBufferPointer<T>

--- func copyBytes(from:UnsafeRawBufferPointer)
+++ func copyMemory(from:UnsafeRawBufferPointer)
}
```

## Source compatibility

Everything is additive except the following. Can we deprecate all of
the original functions in Swift 5, then drop those from the binary
later in Swift 6?

- **add `deallocate()` to all pointer types, replacing any existing deallocation methods**

The migrator needs to drop the existing `capacity` and `alignedTo` arguments.

- **in `UnsafeMutableRawPointer.allocate(count:alignedTo:)` rename `count` to `byteCount` and `alignedTo` to `alignment`**

- **in `UnsafeMutableRawBufferPointer.allocate(count:)` rename `count` to `byteCount` and add an `alignment` parameter**

This change is source breaking but can be trivially automigrated. The
`alignment:` parameter can be filled in with `MemoryLayout<UInt>.stride`.

- **fix the arguments to `initialize(repeating:Pointee, count:Int)`**

Note: initialize(to:Pointee) is backward compatible whenever the
caller relied on a default `count = 1`.

An annotation could otherwise rename `to` to `repeating`, but we don't
want that to interfere with the default count case, so this might need to be a migrator rule.

- **fix the ordering of the arguments in `initializeMemory<Element>(as:at:count:to:)`, rename `to:` to `repeating:`, and remove the `at:` argument**

This change is source breaking but can be trivially automigrated. The
`to` argument changes position and is relabeled as `repeating`.

The migrator could be taught to convert the `at:` argument into
pointer arithmetic on `self`. However, we found no code on Github that
uses the `at:` argument, so it is low priority.

- **rename `copyBytes(from:count:)` to `copyMemory(from:byteCount:)`**

This change is source breaking but can be trivially automigrated.

## Effect on ABI stability

Removing sized deallocators changes the existing ABI, as will renaming some of the methods and their argument labels. 

## Effect on API resilience

Some proposed changes in this proposal change the public API.

Removing sized deallocators right now will break ABI, but offers increased ABI and API stability in the future as reallocator methods can be added in the future without having to rename `deallocate(capacity:)` which currently occupies a “reallocator” name, but has “`free()`” behavior.

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
