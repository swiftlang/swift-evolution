# Accessing an Array's Uninitialized Buffer

* Proposal: [SE-0223](0223-array-uninitialized-initializer.md)
* Author: [Nate Cook](https://github.com/natecook1000)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Withdrawn**
* Next Proposal: [SE-0245](0245-array-uninitialized-initializer.md)
* Decision Notes: [Returned for revision](https://forums.swift.org/t/se-0223-accessing-an-arrays-uninitialized-buffer/15194/41)
* Implementation: [apple/swift#17389](https://github.com/apple/swift/pull/17389)
* Bug: [apple/swift#45677](https://github.com/apple/swift/issues/45677)

## Introduction

This proposal suggests a new initializer and method for `Array` and `ContiguousArray`
that provide access to an array's uninitialized storage buffer.

Swift-evolution thread: [https://forums.swift.org/t/array-initializer-with-access-to-uninitialized-buffer/13689](https://forums.swift.org/t/array-initializer-with-access-to-uninitialized-buffer/13689)

## Motivation

Some collection operations require working on a fixed-size buffer of uninitialized memory.
For example, one O(*n*) algorithm for performing a stable partition of an array is as follows:

1. Create a new array the same size as the original array.
2. Iterate over the original array,
   copying matching elements to the beginning of the new array
   and non-matching elements to the end.
3. When finished iterating, reverse the slice of non-matching elements.

Unfortunately, the standard library provides no way to create an array
of a particular size without allocating every element,
or to copy elements to the end of an array's buffer
without initializing every preceding element.
Even if we avoid initialization by manually allocating the memory using an `UnsafeMutableBufferPointer`,
there's no way to convert that buffer into an array without copying the contents.
There simply isn't a way to implement this particular algorithm with maximum efficiency in Swift.

We also see this limitation when working with C APIs
that fill a buffer with an unknown number of elements and return the count.
The workarounds are the same as above:
either initialize an array before passing it
or copy the elements from an unsafe mutable buffer into an array after calling.

## Proposed solution

Adding a new `Array` initializer
that lets a program work with an uninitialized buffer,
and a method for accessing an existing array's buffer
of both initialized and uninitialized memory,
would fill in this missing functionality.

The new initializer takes a closure that operates on an `UnsafeMutableBufferPointer`
and an `inout` count of initialized elements.
This closure has access to the uninitialized contents
of the newly created array's storage,
and must set the intialized count of the array before exiting.

```swift
var myArray = Array<Int>(unsafeUninitializedCapacity: 10) { buffer, initializedCount in
    for x in 1..<5 {
        buffer[x] = x
    }
    buffer[0] = 10
    initializedCount = 5
}
// myArray == [10, 1, 2, 3, 4]
```

With this new initializer, it's possible to implement the stable partition
as an extension to the `Collection` protocol, without any unnecessary copies:

```swift
func stablyPartitioned(by belongsInFirstPartition: (Element) throws -> Bool) rethrows -> [Element] {
    return try Array<Element>(unsafeUninitializedCapacity: count) { 
        buffer, initializedCount in
        var low = buffer.baseAddress!
        var high = low + buffer.count
        do {
            for element in self {
                if try belongsInFirstPartition(element) {
                    low.initialize(to: element)
                    low += 1
                } else {
                    high -= 1
                    high.initialize(to: element)
                }
            }
            
            let highIndex = high - buffer.baseAddress!
            buffer[highIndex...].reverse()
            initializedCount = buffer.count
        } catch {
            let lowCount = low - buffer.baseAddress!
            let highCount = (buffer.baseAddress! + buffer.count) - high
            buffer.baseAddress!.deinitialize(count: lowCount)
            high.deinitialize(count: highCount)
            throw error
        }
    }
}
```

## Detailed design

The new initializer and method are added to both `Array` and `ContiguousArray`.

```swift
/// Creates an array with the specified capacity, then calls the given closure
/// with a buffer covering the array's uninitialized memory.
///
/// The closure must set its second parameter to a number `c`, the number 
/// of elements that are initialized. The memory in the range `buffer[0..<c]`  
/// must be initialized at the end of the closure's execution, and the memory 
/// in the range `buffer[c...]` must be uninitialized.
///
/// - Note: While the resulting array may have a capacity larger than the
///   requested amount, the buffer passed to the closure will cover exactly
///   the requested number of elements.
///
/// - Parameters:
///   - unsafeUninitializedCapacity: The number of elements to allocate space
///     for in the new array.
///   - initializer: A closure that initializes elements and sets the count of
///     the new array.
///     - Parameters:
///       - buffer: A buffer covering uninitialized memory with room
///         for the specified number of of elements.
///       - initializedCount: The count of the array's initialized elements.
///         After initializing any elements inside `initializer`, update 
///         `initializedCount` with the new count for the array.
public init(
    unsafeUninitializedCapacity: Int,
    initializingWith initializer: (
        _ buffer: inout UnsafeMutableBufferPointer<Element>,
        _ initializedCount: inout Int
    ) throws -> Void
) rethrows

/// Calls the given closure with a buffer of the array's mutable contiguous 
/// storage, reserving the specified capacity if necessary.
///
/// The closure must set its second parameter to a number `c`, the number 
/// of elements that are initialized. The memory in the range `buffer[0..<c]`  
/// must be initialized at the end of the closure's execution, and the memory 
/// in the range `buffer[c...]` must be uninitialized.
///
/// - Parameters:
///   - capacity: The capacity to guarantee for the array. `capacity` must
///     be greater than or equal to the array's current `count`.
///   - body: A closure that can modify or deinitialize existing
///     elements or initialize new elements.
///     - Parameters:
///       - buffer: An unsafe mutable buffer of the array's storage, covering
///         memory for the number of elements specified by the `capacity`
///         parameter. The elements in `buffer[0..<initializedCount]` are
///         initialized, the memory in `buffer[initializedCount..<capacity]`
///         is uninitialized.
///       - initializedCount: The count of the array's initialized elements.
///         If you initialize or deinitialize any elements inside `body`,
///         update `initializedCount` with the new count for the array.
/// - Returns: The return value, if any, of the `body` closure parameter.
public mutating func withUnsafeMutableBufferPointerToStorage<Result>(
    capacity: Int,
    _ body: (
        _ buffer: inout UnsafeMutableBufferPointer<Element>,
        _ initializedCount: inout Int
    ) throws -> Result
) rethrows -> Result
```

### Specifying a capacity

Both the initializer and the mutating method take
the specific capacity that a user wants to work with as a parameter.
In each case, the buffer passed to the closure has a count
that is exactly the same as the specified capacity,
even if the ultimate capacity of the new or existing array is larger.
This helps avoid bugs where a user assumes that the capacity they observe
before calling the mutating method would match the size of the buffer.

The method requires that the capacity specified be at least the current `count` of the array
to prevent nonsensical operations,
like reducing the size of the array from the middle.
That is, this will result in a runtime error:

```swift
var a = Array(1...10)
a.withUnsafeMutableBufferPointerToStorage(capacity: 5) { ... }
```

### Guarantees after throwing

If the closure parameter to either the initializer
or the mutating method throws,
the `initializedCount` value at the time an error is thrown is assumed to be correct.
This means that a user who needs to throw from inside the closure has one of two options.
Before throwing, they must:

1. deinitialize any newly initialized instances or re-initialize any deinitialized instances, or
2. update `initializedCount` to the new count.

In either case,
the postconditions that `buffer[0..<initializedCount]` are initialized
and `buffer[initializedCount...]` are deinitialized still hold.

### Naming considerations

The names of these new additions are definitely a little on the long side!
Here are the considerations used when selecting these names.

#### `init(unsafeUninitializedCapacity:initializingWith:)`

There are two important details of this API that led to the proposed spelling.
First, the initializer is *unsafe*,
in that the user must be sure to properly manage the memory
addressed by the closure's buffer pointer parameter.
Second, the initializer provides access to the array's *uninitialized* storage,
unlike the other `Array.withUnsafe...` methods that already exist.
Because trailing closures are commonly used,
it's important to include those terms in the initial argument label,
such that they're always visible at the use site.

#### `withUnsafeMutableBufferPointerToStorage(capacity:_:)`

The mutating method is closely linked to the existing methods
for accessing an array's storage via mutable buffer pointer,
but has the important distinction of including access
to not just the elements of the array,
but also the uninitialized portion of the array's storage.
Extending the name of the closest existing method (`withUnsafeMutableBufferPointer`)
to mark the distinction makes the relationship (hopefully) clear.

**Suggested alternatives:**

- `withUnsafeMutableBufferPointerToReservedCapacity(_:_:)`
- `withUnsafeMutableBufferPointer(reservingCapacity:_:)`
- `withUnsafeMutableBufferPointerToFullCapacity(capacity:_:)`

#### Unused terminology

This proposal leaves out wording that would reference two other relevant concepts:

- *reserving capacity*:
Arrays currently have a `reserveCapacity(_:)` method,
which is somewhat akin to the first step of the initializer.
However, that method is used for the sake of optimizing performance when adding to an array, 
rather than providing direct access to the array's capacity.
In fact, as part of the `RangeReplaceableCollection` protocol,
that method doesn't even require any action to be taken by the targeted type.
For those reasons,
the idea of "reserving" capacity doesn't seem as appropriate
as providing a specific capacity that will be used.

- *unmanaged*:
The proposed initializer is unusual in that it converts
the lifetime management of manually initialized instances to be automatically managed,
as elements of an `Array` instance.
The only other type that performs this kind of conversion is `Unmanaged`,
which is primarily used at the border of Swift and C interoperability,
particularly with Core Foundation.
Additionally, `Unmanaged` can be used to maintain and manage the lifetime of an instance
over a long period of time,
while this initializer performs the conversion as soon as the closure executes.
As above, this term doesn't seem appropriate for use with this new API.


## Source compatibility

This is an additive change to the standard library,
so there is no effect on source compatibility.

## Effect on ABI stability

This addition has no effect on ABI stability.

## Effect on API resilience

The additional APIs will be a permanent part of the standard library,
and will need to remain public API. 

## Alternatives considered

### Returning the new count from the initializer closure

An earlier proposal had the initializer's closure return the new count,
instead of using an `inout` parameter.
This proposal uses the parameter instead,
so that the method and initializer use the same closure type.

In addition, the throwing behavior described above requires that
the initialized count be set as an `inout` parameter instead of as a return value.
Not every `Element` type can be trivially initialized,
so a user that deinitializes some elements and then needs to throw an error would be stuck.
(This is only an issue with the mutating method.)
Removing the `throws` capability from the closure
would solve this problem and simplify the new APIs' semantics,
but would be inconsistent with the other APIs in this space
and would make them more difficult to use as building blocks
for higher-level operations like `stablyPartitioned(by:)`.

### Creating an array from a buffer

An `Array` initializer that simply converts an `UnsafeMutableBufferPointer`
into an array's backing storage seems like it would be another solution.
However, an array's storage includes information
about the count and capacity at the beginning of its buffer,
so an `UnsafeMutableBufferPointer` created from scratch isn't usable.

## Addendum

You can Try This At Home™ with this extension,
which provides the semantics
(but not the copy-avoiding performance benefits)
of the proposed additions:

```swift
extension Array {
    public init(
        unsafeUninitializedCapacity: Int,
        initializingWith initializer: (
            _ buffer: inout UnsafeMutableBufferPointer<Element>,
            _ initializedCount: inout Int
        ) throws -> Void
    ) rethrows {
        self = []
        try self.withUnsafeMutableBufferPointerToStorage(capacity: unsafeUninitializedCapacity, initializer)
    }

    public mutating func withUnsafeMutableBufferPointerToStorage<Result>(
        capacity: Int,
        _ body: (
            _ buffer: inout UnsafeMutableBufferPointer<Element>,
            _ initializedCount: inout Int
        ) throws -> Result
    ) rethrows -> Result {
        var buffer = UnsafeMutableBufferPointer<Element>.allocate(capacity: capacity)
        buffer.initialize(from: self)
        var initializedCount = self.count
        defer {
            buffer.baseAddress?.deinitialize(count: initializedCount)
            buffer.deallocate()
        }
        
        let result = try body(&buffer, &initializedCount)
        self = Array(buffer[..<initializedCount])
        self.reserveCapacity(capacity)
        return result
    }
}
```
