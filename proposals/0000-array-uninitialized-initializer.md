# Accessing an Array's Uninitialized Buffer

* Proposal: [SE-NNNN](NNNN-array-uninitialized-buffer.md)
* Author: [Nate Cook](https://github.com/natecook1000)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: *Exists as an underscored API*
* Bug: [SR-3087](https://bugs.swift.org/browse/SR-3087)

## Introduction

This proposal suggests a new initializer for `Array` and `ContiguousArray`
that would provide access to a newly created array's uninitialized storage buffer.

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

## Proposed solution

Adding a new `Array` initializer
that lets a program work with the uninitialized buffer
would fill in this missing functionality.
This new initializer takes a closure that operates on an `UnsafeMutableBufferPointer`
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
func stablyPartitioned(by belongsInFirstPartition: (Element) -> Bool) -> [Element] {
    let result = Array<Element>(unsafeUninitializedCapacity: count) { buffer, initializedCount in
        var low = buffer.baseAddress!
        var high = low + buffer.count
        for element in self {
            if belongsInFirstPartition(element) {
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
    }
    return result
}
```

## Detailed design

The new initializer is added to both `Array` and `ContiguousArray`.

```swift
/// Creates an array with the specified capacity, then calls the given
/// closure with a buffer covering the array's uninitialized memory.
///
/// Inside the closure, set the `initializedCount` parameter to the number of
/// elements that are initialized by the closure. The memory in the range
/// `buffer[0..<initializedCount]` must be initialized at the end of the
/// closure's execution, and the memory in the range
/// `buffer[initializedCount...]` must be uninitialized.
///
/// - Note: While the resulting array may have a capacity larger than the
///   requested amount, the buffer passed to the closure will cover exactly
///   the requested number of elements.
///
/// - Parameters:
///   - unsafeUninitializedCapacity: The number of elements to allocate
///     space for in the new array.
///   - initializer: A closure that initializes elements and sets the count
///     of the new array.
///     - Parameters:
///       - buffer: A buffer covering uninitialized memory with room for the
///         specified number of of elements.
///       - initializedCount: The count of initialized elements in the array,
///         which begins at zero. Set `initializedCount` to the number of
///         elements you initialize.
@inlinable
public init(
    unsafeUninitializedCapacity: Int,
    initializingWith initializer: (
        _ buffer: inout UnsafeMutableBufferPointer<Element>,
        _ initializedCount: inout Int
    ) throws -> Void
) rethrows
```

In particular, 
note that the buffer is guaranteed to address only the specified capacity, 
though the final array may have a capacity greater than that as an optimization.

## Source compatibility

This is an additive change to the standard library,
so there is no effect on source compatibility.

## Effect on ABI stability

This addition has no effect on ABI stability.

## Effect on API resilience

The additional APIs will be a permanent part of the standard library,
and will need to remain public API. 

## Alternatives considered

### Creating an array from a buffer

An `Array` initializer that simply converts an `UnsafeMutableBufferPointer`
into an array's backing storage seems like it would be another solution.
However, an array's storage includes information
about the count and capacity at the beginning of its buffer,
so an `UnsafeMutableBufferPointer` created from scratch isn't usable.

### Mutable version

A draft version of this proposal centered around
a mutating `withFullCapacityUnsafeMutableBufferPointer` method
instead of the initializer.
However, that approach poses a problem: 
the buffer passed to the closure might have an unpredictable size.

```swift
let c = myArray.capacity
myArray.withFullCapacityUnsafeMutableBufferPointer { buffer, initializedCount in
    // If `myArray` is shared, the storage gets cloned before here, so
    // `buffer.count` may be greater than, less than, or equal to `c`.
}

myArray.reserveCapacity(100)
myArray.withFullCapacityUnsafeMutableBufferPointer { buffer, initializedCount in
    // `buffer.count` may be greater than 100 due to padding
    // or when `myArray.count` is greater than 100.
}
```

Trying to solve this problem by providing
an explicit capacity as a parameter to the mutating method
leads to even more verbose and potentially confusing names,
without entirely removing the unpredictability.
An API with these characteristics seems quite difficult to understand and use properly.

### Naming considerations

There are two important details of this API that led to the proposed spelling.
First, the initializer is *unsafe*,
in that the user must be sure to properly manage the memory
addressed by the closure's buffer pointer parameter.
Second, the initializer provides access to the array's *uninitialized* storage,
unlike the other `Array.withUnsafe...` methods that already exist.
Because trailing closures are commonly used,
it's important to include those terms in the initial argument label,
such that they're always visible at the use site.

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


## Addendum

You can Try This At Home™ with this extension,
which provides the semantics
(but not the performance benefits)
of the proposed initializer:

```swift
extension Array {
    public init(
        unsafeUninitializedCapacity: Int,
        initializingWith initializer: (
            _ buffer: inout UnsafeMutableBufferPointer<Element>,
            _ initializedCount: inout Int
        ) throws -> Void
    ) rethrows {
        var buffer = UnsafeMutableBufferPointer<Element>.allocate(capacity: unsafeUninitializedCapacity)
        defer { buffer.deallocate() }
        var initializedCount = 0
        try initializer(&buffer, &initializedCount)
        self = Array(buffer[0..<initializedCount])
    }
}
```
