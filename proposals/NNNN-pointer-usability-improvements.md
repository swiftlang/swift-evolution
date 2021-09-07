# Pointer API Usability Improvements

* Proposal: [SE-NNNN full proposal draft][proposal]
* Authors: [Guillaume Lessard](https://github.com/glessard), [Andrew Trick](https://github.com/atrick)
* Review Manager: TBD
* Status: [Draft pull request][draft-pr]
* Implementation: pending
* Bugs: [rdar://64342031](rdar://64342031), [SR-11156](https://bugs.swift.org/browse/SR-11156) ([rdar://53272880](rdar://53272880)), [rdar://22541346](rdar://22541346)
* Previous Revision: none

[proposal]: https://gist.github.com/glessard/ca662b89c070d279f8eb298850260b0c
[draft-pr]: https://github.com/apple/swift/pull/39639
[pitch-thread]: https://forums.swift.org/t/52736

## Introduction

This proposal introduces some quality-of-life improvements for `UnsafePointer` and its `Mutable` and `Raw` variants.

1. Add an API to obtain an `UnsafeRawPointer` instance that is advanced to a given alignment from its starting point.
2. Add an API to obtain a pointer to a stored property of an aggregate `T`, given an `UnsafePointer<T>`.
3. Rename the unchecked subscript of `Unsafe[Mutable]Pointer` to include the argument label `unchecked`.
4. Add the ability to compare pointers of any two types.

Swift-evolution thread: [Discussion][pitch-thread]

## Motivation

The everyday use of `UnsafePointer` and its variants comes with many difficulties unrelated to the unsafeness of the type.
We can improve the ergonomics of these types without hiding the unsafeness.

For example, if one needs to advance a pointer to a given alignment,
there is no need to force the programmer to derive the proper calculation
(or consult a textbook, or copy an answer from stack overflow.)
An API that provides this utility would not take away from the fact that the type is called "unsafe".

Similarly, it is rather difficult to pass a pointer to a property of a struct to (e.g.) a C function.
In such cases, the poor ergonomics lead to code that is less safe than it should be.

From another perspective, the integer subscript on `UnsafePointer` is different from other subscripts in Swift.
Normally, similar-looking subscripts perform bounds checking.
The `UnsafePointer` version does not warn that it does not check its parameter,
even though it looks similar to a `Collection` subscript at the point of use.
It would be an improvement to give a name to the way that subscript is unsafe: it is **unchecked**.

Finally, when dealing with pointers of different types,
we can often get in situations where Swift's type system gets in the way.
Regardless of their type, pointers represent one unique storage location in memory.
As such, casting the type of a pointer in order to be able to compare it to another is not a useful exercise.


## Proposed solution

#### Ability to obtain a pointer properly aligned to store a given type

When using pointers into untyped (raw) memory,
it is often desirable to obtain another pointer that is advanced to a given alignment,
rather than advanced by a particular offset.
The current API provides no help in performing this task,
even though the calculation isn't entirely obvious.
The programmer should not need to derive the proper calculation, or to consult a textbook.

For example, consider implementing a complex data structure whose nodes include atomic pointers to other nodes in the graph.
In order to avoid two allocations per node, we allocate a range of raw memory and manually bind subranges of the allocation.
Our example node allocates space for one atomic pointer value and one value of type `T`:
```swift
import SwiftAtomics

struct Node<T>: RawRepresentable, AtomicValue, AtomicOptionalWrappable {
  typealias AtomicRepresentation = AtomicRawRepresentableStorage<Self>
  typealias AtomicOptionalRepresentation =
                                   AtomicOptionalRawRepresentableStorage<Self>
  typealias NodeStorage = (AtomicOptionalRepresentation, T)

  let rawValue: UnsafeMutableRawPointer

  init(_ element: T) {
    rawValue = .allocate(byteCount: MemoryLayout<NodeStorage>.size,
                         alignment: MemoryLayout<NodeStorage>.alignment)

    // bind and initialize atomic storage
    rawValue.initializeMemory(as: AtomicOptionalRepresentation.self,
                              repeating: AtomicOptionalRepresentation(nil),
                              count: 1)
    // bind and initialize payload storage
    let tMask   = MemoryLayout<T>.alignment - 1
    let tOffset = (MemoryLayout<AtomicOptionalRepresentation>.size + tMask) & ~tMask
    let t = rawValue.advanced(by: tOffset)
                    .initializeMemory(as: T.self, repeating: element, count: 1)
  }
}
```

The calculation of `tOffset` above is overly complex.
Calculating the offset between the start of the data structure to the field of type `T` should be straightforward!

We propose to add a function to help perform this operation on raw pointer types:
```swift
extension UnsafeRawPointer {
  public func alignedUp<T>(for: T.type) -> Self
}
```

This function will round the current pointer up to the next address properly aligned to access an instance of `T`.
When applied to a `self` already aligned for `T`, `UnsafeRawPointer.aligned(for:)` will return `self`.

The new function would make identifying the storage location of `T` much more straightforward than in the example above:
```swift
  init(_ element: T) {
    rawValue = .allocate(byteCount: MemoryLayout<NodeStorage>.size,
                         alignment: MemoryLayout<NodeStorage>.alignment)

    // bind and initialize atomic storage
    rawValue.initializeMemory(as: AtomicOptionalRepresentation.self,
                              repeating: AtomicOptionalRepresentation(nil),
                              count: 1)
    // bind and initialize payload storage
    rawValue.advanced(by: MemoryLayout<AtomicOptionalRepresentation>.size)
            .alignedUp(for: T.self)
            .initializeMemory(as: T.self, repeating: element, count: 1)
  }
```

Along with `alignedUp(for:)`, we also propose to add `alignedDown(for:)`,
as well as a pair of corresponding functions that take an integer argument:
`alignedUp(toMultipleOf:)` and `alignedDown(toMultipleOf:)`.


#### Ability to obtain a pointer to a member of an aggregate value

When using a pointer to a struct with multiple stored properties,
it isn't obvious how to obtain pointers to more than one of the stored properties.
For example, consider using the pthreads library, a major C API.
The pthreads library uses the return value to indicate error conditions,
and modifies values through pointers it receives as parameters.
It has many APIs with multiple pointer arguments.
One would query a thread's scheduling parameters using `pthread_getschedparam`,
which has the following prototype:
```C
int pthread_getschedparam(pthread_t tid, int *policy, struct sched_param *param);
```

A swift user, concerned with keeping related data packaged together,
might have elected to define a struct thusly:
```swift
struct ThreadSchedulingParameters {
  var policy: Int
  var parameters: sched_param
  var priority: Int { parameters.sched_priority }
}
```

Updating a `ThreadSchedulingParameters` instance using the above C function is not obvious:
```swift
var scheduling = ThreadSchedulingParameters()
var tid = pthread_create(...)
var e = withUnsafeMutableBytes(of: &scheduling) { bytes in
  let o1 = MemoryLayout<ThreadSchedulingParameters>.offset(of: \.policy)!
  let policy_p = bytes.baseAddress!.advanced(by: o1).assumingMemoryBound(to: Int32.self)
  let o2 = MemoryLayout<ThreadSchedulingParameters>.offset(of: \.parameters)!
  let params_p = bytes.baseAddress!.advanced(by: o2).assumingMemoryBound(to: sched_param.self)
  return pthread_getschedparam(thread, policy_p, params_p)
}
```

We must first reach for the non-obvious `withUnsafeMutableBytes` rather than for `withUnsafePointer`.
In so doing, we suppress statically-known type information,
only to immediately assert the type using `assumingMemoryBound`.
We can use `KeyPath` to do better.
We shall add a new function to `UnsafePointer` and `UnsafeMutablePointer` to perform this task:
```swift
extension UnsafeMutablePointer {
  func pointer<Property>(to property: WritableKeyPath<Pointee, Property>) -> UnsafeMutablePointer<Property>?
}
```

The return value of this function must be optional,
because whether any given `KeyPath` represents a stored or computed property is not represented in its type.
If the `KeyPath` represents a computed property,
there is no corresponding pointer, and we must return `nil`.

With this new function, a correct call to `pthread_getschedparam` becomes the much simpler:
```swift
var e = withUnsafeMutablePointer(to: &scheduling) {
  pthread_getschedparam(thread,
                        $0.pointer(to: \.policy)!,
                        $0.pointer(to: \.parameters)!)
}
```


#### Add `unchecked` argument label to `UnsafePointer`'s integer subscript

In Swift, it is customary for subscripts to have a precondition that their argument be valid.
It is reasonable and expected that `UnsafePointer` should have a less-safe subscript.
Unfortunately, the unsafe usage is unmarked at the point of use.

We propose to replace (via deprecation) the existing subscript of `UnsafePointer`
with a subscript that adds an argument label (`unchecked`).
The label will help visually distinguish the unchecked pointer subscript from a "normal" (checked) subscript.
```swift
extension UnsafeMutablePointer {
  public subscript(unchecked i: Int) -> Pointee { get set }
}
```

There is precedent for using of the word "unchecked" in the standard library.
It is frequently used in internal names:
the word currently appears as part of a Swift symbol on 197 lines of the standard library source code.
It is also used to indicate unchecked preconditions in these public API:
`@unchecked Sendable`, `Range.init(uncheckedBounds:)` and `ClosedRange.init(uncheckedBounds:)`.

<!-- find stdlib/public -type f -exec egrep unchecked {} \; | grep -v // -->


#### Allow comparisons of pointers of any type

Pointers are effectively an index into the fundamental collection that is the computer's memory.
Regardless of their type, they represent a unique storage location in memory.
As such, having to cast the type of a pointer in order to be able to compare it to another is not a useful exercise.

It's very common to end up with a combination of `Mutable` and non-`Mutable` pointers into the same buffer,
and the programmer needs to write conversions that satisfy the compiler but have no real effect in the generated code.

To remedy this, we propose to add the following static functions, scoped to the existing `_Pointer` protocol:
```swift
extension _Pointer {
  public static func == <Other: _Pointer>(lhs: Self, rhs: Other) -> Bool

  public static func <  <Other: _Pointer>(lhs: Self, rhs: Other) -> Bool
  public static func <= <Other: _Pointer>(lhs: Self, rhs: Other) -> Bool
  public static func >  <Other: _Pointer>(lhs: Self, rhs: Other) -> Bool
  public static func >= <Other: _Pointer>(lhs: Self, rhs: Other) -> Bool
}
```

Note that it is always possible to enclose both pointers in a conversion to `UnsafeRawPointer`.
This addition simply removes the necessity to insert conversions that are _always_ legal.


## Detailed design

#### API to obtain a pointer properly aligned to store a given type

```swift
extension UnsafeRawPointer {
  /// Obtain the next pointer properly aligned to store a value of type `T`.
  ///
  /// If `self` is properly aligned for accessing `T`,
  /// this function returns `self`.
  ///
  /// - Parameters:
  ///   - type: the type to be stored at the returned address.
  /// - Returns: a pointer properly aligned to store a value of type `T`.
  public func alignedUp<T>(for type: T.Type) -> UnsafeRawPointer

  /// Obtain the preceding pointer properly aligned to store a value of type `T`.
  ///
  /// If `self` is properly aligned for accessing `T`,
  /// this function returns `self`.
  ///
  /// - Parameters:
  ///   - type: the type to be stored at the returned address.
  /// - Returns: a pointer properly aligned to store a value of type `T`.
  public func alignedDown<T>(for type: T.Type) -> UnsafeRawPointer

  /// Obtain the next pointer whose bit pattern is a multiple of `alignment`.
  ///
  /// If the bit pattern of `self` is a multiple of `alignment`,
  /// this function returns `self`.
  ///
  /// - Parameters:
  ///   - alignment: the alignment of the returned pointer, in bytes.
  ///     `alignment` must be a whole power of 2.
  /// - Returns: a pointer aligned to `alignment`.
  public func alignedUp(toMultipleOf alignment: Int) -> UnsafeRawPointer

  /// Obtain the preceding pointer whose bit pattern is a multiple of `alignment`.
  ///
  /// If the bit pattern of `self` is a multiple of `alignment`,
  /// this function returns `self`.
  ///
  /// - Parameters:
  ///   - alignment: the alignment of the returned pointer, in bytes.
  ///     `alignment` must be a whole power of 2.
  /// - Returns: a pointer aligned to `alignment`.
  public func alignedDown(toMultipleOf alignment: Int) -> UnsafeRawPointer
}
```

```swift
extension UnsafeMutableRawPointer {
  /// Obtain the next pointer properly aligned to store a value of type `T`.
  ///
  /// If `self` is properly aligned for accessing `T`,
  /// this function returns `self`.
  ///
  /// - Parameters:
  ///   - type: the type to be stored at the returned address.
  /// - Returns: a pointer properly aligned to store a value of type `T`.
  public func alignedUp<T>(for type: T.Type) -> UnsafeMutableRawPointer

  /// Obtain the preceding pointer properly aligned to store a value of type `T`.
  ///
  /// If `self` is properly aligned for accessing `T`,
  /// this function returns `self`.
  ///
  /// - Parameters:
  ///   - type: the type to be stored at the returned address.
  /// - Returns: a pointer properly aligned to store a value of type `T`.
  public func alingedDown<T>(for type: T.Type) -> UnsafeMutableRawPointer

  /// Obtain the next pointer whose bit pattern is a multiple of `alignment`.
  ///
  /// If the bit pattern of `self` is a multiple of `alignment`,
  /// this function returns `self`.
  ///
  /// - Parameters:
  ///   - alignment: the alignment of the returned pointer, in bytes.
  ///     `alignment` must be a whole power of 2.
  /// - Returns: a pointer aligned to `alignment`.
  public func alignedUp(toMultipleOf alignment: Int) -> UnsafeMutableRawPointer

  /// Obtain the preceding pointer whose bit pattern is a multiple of `alignment`.
  ///
  /// If the bit pattern of `self` is a multiple of `alignment`,
  /// this function returns `self`.
  ///
  /// - Parameters:
  ///   - alignment: the alignment of the returned pointer, in bytes.
  ///     `alignment` must be a whole power of 2.
  /// - Returns: a pointer aligned to `alignment`.
  public func alignedDown(toMultipleOf alignment: Int) -> UnsafeMutableRawPointer
}
```

#### API to obtain a pointer to a member of an aggregate value

```swift
extension UnsafePointer {
  /// Obtain a pointer to the stored property referred to by a key path.
  ///
  /// If the key path represents a computed property,
  /// this function will return `nil`.
  ///
  /// - Parameter property: A `KeyPath` whose `Root` is `Pointee`.
  /// - Returns: A pointer to the stored property represented
  ///            by the key path, or `nil`.
  public func pointer<Property>(
    to property: KeyPath<Pointee, Property>
  ) -> UnsafePointer<Property>?
}

extension UnsafeMutablePointer {
  /// Obtain a pointer to the stored property referred to by a key path.
  ///
  /// If the key path represents a computed property,
  /// this function will return `nil`.
  ///
  /// - Parameter property: A `KeyPath` whose `Root` is `Pointee`.
  /// - Returns: A pointer to the stored property represented
  ///            by the key path, or `nil`.
  public func pointer<Property>(
    to property: KeyPath<Pointee, Property>
  ) -> UnsafePointer<Property>?

  /// Obtain a mutable pointer to the stored property referred to by a key path.
  ///
  /// If the key path represents a computed property,
  /// this function will return `nil`.
  ///
  /// - Parameter property: A `WritableKeyPath` whose `Root` is `Pointee`.
  /// - Returns: A mutable pointer to the stored property represented
  ///            by the key path, or `nil`.
  public func pointer<Property>(
    to property: WritableKeyPath<Pointee, Property>
  ) -> UnsafeMutablePointer<Property>?
}
```


#### Add `unchecked` argument label to `UnsafePointer`'s integer subscript

```swift
extension UnsafePointer {
  @available(*, deprecated, renamed: "subscript(unchecked:)")
  public subscript(i: Int) -> Pointee { get }

  /// Accesses the pointee at the specified unchecked offset from this pointer.
  ///
  /// For a pointer `p`, the memory at `p + i` must be initialized.
  ///
  /// - Parameter i: The offset from this pointer at which to access an
  ///   instance, measured in strides of the pointer's `Pointee` type.
  public subscript(unchecked i: Int) -> Pointee { get }
}

extension UnsafeMutablePointer {
  @available(*, deprecated, renamed: "subscript(unchecked:)")
  public subscript(i: Int) -> Pointee { get set }

  /// Accesses the pointee at the specified unchecked offset from this pointer.
  ///
  /// For a pointer `p`, the memory at `p + i` must be initialized when reading
  /// the value by using the subscript. When the subscript is used as the left
  /// side of an assignment, the memory at `p + i` must be initialized or
  /// the pointer's `Pointee` type must be a trivial type.
  ///
  /// Do not assign an instance of a nontrivial type through the subscript to
  /// uninitialized memory. Instead, use an initializing method, such as
  /// `initialize(repeating:count:)`.
  ///
  /// - Parameter i: The offset from this pointer at which to access an
  ///   instance, measured in strides of the pointer's `Pointee` type.
  public subscript(unchecked i: Int) -> Pointee { get set }
}
```


#### Allow comparisons of pointers of any type

```swift
  /// Returns a Boolean value indicating whether the first pointer references
  /// a memory location earlier than the second pointer references.
  ///
  /// - Parameters:
  ///   - lhs: A pointer.
  ///   - rhs: Another pointer.
  /// - Returns: `true` if `lhs` references a memory address
  ///            earlier than `rhs`; otherwise, `false`.
  public static func < <Other: _Pointer>(lhs: Self, rhs: Other) -> Bool

  /// Returns a Boolean value indicating whether the first pointer references
  /// a memory location earlier than or same as the second pointer references.
  ///
  /// - Parameters:
  ///   - lhs: A pointer.
  ///   - rhs: Another pointer.
  /// - Returns: `true` if `lhs` references a memory address
  ///            earlier than or the same as `rhs`; otherwise, `false`.
  public static func <= <Other: _Pointer>(lhs: Self, rhs: Other) -> Bool

  /// Returns a Boolean value indicating whether the first pointer references
  /// a memory location later than the second pointer references.
  ///
  /// - Parameters:
  ///   - lhs: A pointer.
  ///   - rhs: Another pointer.
  /// - Returns: `true` if `lhs` references a memory address
  ///            later than `rhs`; otherwise, `false`.
  public static func > <Other: _Pointer>(lhs: Self, rhs: Other) -> Bool

  /// Returns a Boolean value indicating whether the first pointer references
  /// a memory location later than or same as the second pointer references.
  ///
  /// - Parameters:
  ///   - lhs: A pointer.
  ///   - rhs: Another pointer.
  /// - Returns: `true` if `lhs` references a memory address
  ///            later than or the same as `rhs`; otherwise, `false`.
  public static func >= <Other: _Pointer>(lhs: Self, rhs: Other) -> Bool
}
```


## Source compatibility

Most of the proposed changes are additive, and therefore are source-compatible.
The existing pointer subscript would be deprecated, producing a warning.
A fixit will support an easy transition to the new version of the subscript.

## Effect on ABI stability

We intend to implement these changes in an ABI-neutral manner.

## Effect on API resilience

The proposed additions will be public API,
and will all be marked `@_alwaysEmitIntoClient` to support back-deployability.

The deprecated integer subscript will remain in place,
and will therefore support pre-existing binaries.


## Alternatives considered

#### API to obtain a pointer properly aligned to store a given type

Instead of the proposed function that takes a type argument,
we could only add an API that simply takes an integer,
and rounds the value of the pointer to a multiple of that number.
We believe that having a type parameter is the correct default.
Since it is not currently possible to define a type whose alignment is greater than 16,
we also include versions that take an integer argument.

The name of the function could simply be `advanced<T>(toAlignmentOf: T.type)`.
This pairs well with the existing pointer advancement functions,
but implies that it the returned value is always different from `self`.

There is a pre-existing internal API to obtain pointers aligned with a type's alignment,
consisting of static members of `MemoryLayout<T>` whose names start with `_roundingUp`.
We believe that the functionality is a more natural fit as methods of `Unsafe[Mutable]RawPointer`.
The name `roundedUp` was the name originally pitched for this functionality,
but it is a strange fit for an operation that is entirely about integer values.

Ultimately we are proposing `alignedUp(for:)` and `alignedDown(for:)`.
These names have the important property of not being misleading.
There is no clear best choice for the preposition to be used as an argument label,
though we note that the argument label `for` meshes well with the parameter name `type`,
which is visible in documentation, including auto-completion.


#### API to obtain a pointer to a member of an aggregate value

We originally proposed to use a subscript instead of a function to provide this functionality:
```swift
subscript<Property>(property: KeyPath<Pointee, Property>) -> UnsafePointer<Property>? { get }
```
It was pointed out that a subscript generally implies direct access to the property,
whereaes this one would only provide access to a pointer to the property.
Furthermore, since there is no need for a setter (lvalue),
the functionality can be provided just as well with a function.

It might be possible to use the `@dynamicMemberLookup` functionality to make the subscript approach even more elegant.
This seemed to imply even more strongly a direct access to the property,
as well as being deemed "too magical".


#### Add `unchecked` argument label to `UnsafePointer`'s integer subscript

The community could decide not to do this.
The authors believe that unsafe API would be improved by indicating the nature of their unsafety at the point of use,
and this pitch is a first step for such improvements.

In addition to changing the `UnsafePointer` subscript,
we could also add a subscript to `UnsafeBufferPointer` that includes the `unchecked` argument label.
The behaviour of this additional subscript would be different from the behaviour of the existing integer subscript,
and would _not_ be a replacement.
As a reminder, `UnsafeBufferPointer.subscript(_ i: Int)` performs bounds-checking in debug mode,
and skips bounds-checking in release mode.
This behaviour leads to optimization issues when there are three compilation units
(the standard library, user code, and a third-party library that uses `UnsafeBufferPointer`),
limiting the optimizations available to the library code.

Adding an `unchecked` subscript to `UnsafeBufferPointer` could help the ultimate performance of such third-party libraries.
Changing the default behaviour of `UnsafeBufferPointer`'s subscript with regards to bounds-checking is out of scope for this proposal.


#### Allow comparisons of pointers of any type

Compiler performance is a concern, and operator overloads have been the cause of performance issues in the past.
Preliminary compiler performance testing [suggests][performance-test] that this addition does not appreciably affect performance.

[performance-test]: https://github.com/apple/swift/pull/39635#issuecomment-939353928


## Acknowledgements

Thanks to Kyle Macomber and the Swift Standard Library team for valuable feedback.
