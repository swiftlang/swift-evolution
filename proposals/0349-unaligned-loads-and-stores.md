# Unaligned Loads and Stores from Raw Memory

* Proposal: [SE-0349](0349-unaligned-loads-and-stores.md)
* Authors: [Guillaume Lessard](https://github.com/glessard), [Andrew Trick](https://github.com/atrick)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Implemented (Swift 5.7)**
* Implementation: [apple/swift#41033](https://github.com/apple/swift/pull/41033)
* Review: ([pitch](https://forums.swift.org/t/55036/)) ([review](https://forums.swift.org/t/se-0349-unaligned-loads-and-stores-from-raw-memory/56423)) ([acceptance](https://forums.swift.org/t/accepted-se-0349-unaligned-loads-and-stores-from-raw-memory/56748))

## Introduction

Swift does not currently provide a clear way to load data from an arbitrary source of bytes, such as a binary file, in which data may be stored without respect for in-memory alignment. This proposal aims to rectify the situation, making workarounds unnecessary.

## Motivation

The method `UnsafeRawPointer.load<T>(fromByteOffset offset: Int, as type: T.Type) -> T` requires the address at `self+offset` to be properly aligned to access an instance of type `T`. Attempts to use a combination of pointer and byte offset that is not aligned for `T` results in a runtime crash. Unfortunately, in general, data saved to files or network streams does not adhere to the same restrictions as in-memory layouts do, and tends to not be properly aligned. When copying data from such sources to memory, Swift users therefore frequently encounter aligment mismatches that require using a workaround. This is a longstanding issue reported in e.g. [SR-10273](https://bugs.swift.org/browse/SR-10273).

For example, given an arbitrary data stream in which a 4-byte value is encoded between byte offsets 3 through 7:

```swift
let data = Data([0x0, 0x0, 0x0, 0xff, 0xff, 0xff, 0xff, 0x0])
```

In order to extract all the `0xff` bytes of this stream to an `UInt32`, we would like to be able to use `load(as:)`, as follows:

```swift
let result = data.dropFirst(3).withUnsafeBytes { $0.load(as: UInt32.self) }
```

However, that will currently crash at runtime, because in this case `load` requires the base pointer to be correctly aligned for accessing `UInt32`. A workaround is required, such as the following:

```swift
let result = data.dropFirst(3).withUnsafeBytes { buffer -> UInt32 in
  var storage = UInt32.zero
  withUnsafeMutableBytes(of: &storage) {
    $0.copyBytes(from: buffer.prefix(MemoryLayout<UInt32>.size))
  }
  return storage
}
```

The necessity of this workaround (or of others that produce the same outcome) is unsatisfactory for two reasons; firstly it is tremendously non-obvious. Secondly, it requires two copies instead of the expected single copy: the first to a correctly-aligned raw buffer, and then to the final, correctly-typed variable. We should be able to do this with a single copy.

The kinds of types for which it is important to improve loads from arbitrary alignments are types whose values can be copied bit for bit, without reference counting operations. These types are commonly referred to as "POD" (plain old data) or "trivial" types. We propose to restrict the use of the unaligned loading operation to those types.

## Proposed solution

We propose to add an API `UnsafeRawPointer.loadUnaligned(fromByteOffset:as:)` to support unaligned loads from `UnsafeRawPointer`, `UnsafeRawBufferPointer` and their mutable counterparts. These will be explicitly restricted to POD types. Loading a non-POD type remains meaningful only when the source memory is another live object where the memory is, by construction, already correctly aligned. The original API (`load`) will continue to support this case. The new API (`loadUnaligned`) will assert that the return type is POD when run in debug mode.

`UnsafeMutableRawPointer.storeBytes(of:toByteOffset:)` is documented to only be meaningful for POD types. However, at runtime it enforces storage to an offset correctly aligned to the source type. We propose to remove that alignment restriction and instead enforce the documented POD restriction. The API will otherwise be unchanged, though its documentation will be updated. Please see the ABI stability section for a discussion of binary compatibility with this approach.

The `UnsafeRawBufferPointer` and `UnsafeMutableRawBufferPointer` types will receive matching changes.

## Detailed design

```swift
extension UnsafeRawPointer {
  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  ///
  /// This function only supports loading trivial types,
  /// and will trap if this precondition is not met.
  /// A trivial type does not contain any reference-counted property
  /// within its in-memory representation.
  /// The memory at this pointer plus `offset` must be laid out
  /// identically to the in-memory representation of `T`.
  ///
  /// - Note: A trivial type can be copied with just a bit-for-bit copy without
  ///   any indirection or reference-counting operations. Generally, native
  ///   Swift types that do not contain strong or weak references or other
  ///   forms of indirection are trivial, as are imported C structs and enums.
  ///
  /// - Parameters:
  ///   - offset: The offset from this pointer, in bytes. `offset` must be
  ///     nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes at
  ///   `offset`. The returned instance isn't associated
  ///   with the value in the range of memory referenced by this pointer.
  public func loadUnaligned<T>(fromByteOffset offset: Int = 0, as type: T.Type) -> T
}
```

```swift
extension UnsafeMutableRawPointer {
  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  ///
  /// This function only supports loading trivial types,
  /// and will trap if this precondition is not met.
  /// A trivial type does not contain any reference-counted property
  /// within its in-memory representation.
  /// The memory at this pointer plus `offset` must be laid out
  /// identically to the in-memory representation of `T`.
  ///
  /// - Note: A trivial type can be copied with just a bit-for-bit copy without
  ///   any indirection or reference-counting operations. Generally, native
  ///   Swift types that do not contain strong or weak references or other
  ///   forms of indirection are trivial, as are imported C structs and enums.
  ///
  /// - Parameters:
  ///   - offset: The offset from this pointer, in bytes. `offset` must be
  ///     nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes at
  ///   `offset`. The returned instance isn't associated
  ///   with the value in the range of memory referenced by this pointer.
  public func loadUnaligned<T>(fromByteOffset offset: Int = 0, as type: T.Type) -> T

  /// Stores the given value's bytes into raw memory at the specified offset.
  ///
  /// The type `T` to be stored must be a trivial type. The memory
  /// must also be uninitialized, initialized to `T`, or initialized to
  /// another trivial type that is layout compatible with `T`.
  ///
  /// After calling `storeBytes(of:toByteOffset:as:)`, the memory is
  /// initialized to the raw bytes of `value`. If the memory is bound to a
  /// type `U` that is layout compatible with `T`, then it contains a value of
  /// type `U`. Calling `storeBytes(of:toByteOffset:as:)` does not change the
  /// bound type of the memory.
  ///
  /// - Note: A trivial type can be copied with just a bit-for-bit copy without
  ///   any indirection or reference-counting operations. Generally, native
  ///   Swift types that do not contain strong or weak references or other
  ///   forms of indirection are trivial, as are imported C structs and enums.
  ///
  /// If you need to store a copy of a value of a type that isn't trivial into memory,
  /// you cannot use the `storeBytes(of:toByteOffset:as:)` method. Instead, you must know
  /// the type of value previously in memory and initialize or assign the
  /// memory. For example, to replace a value stored in a raw pointer `p`,
  /// where `U` is the current type and `T` is the new type, use a typed
  /// pointer to access and deinitialize the current value before initializing
  /// the memory with a new value.
  ///
  ///     let typedPointer = p.bindMemory(to: U.self, capacity: 1)
  ///     typedPointer.deinitialize(count: 1)
  ///     p.initializeMemory(as: T.self, repeating: newValue, count: 1)
  ///
  /// - Parameters:
  ///   - value: The value to store as raw bytes.
  ///   - offset: The offset from this pointer, in bytes. `offset` must be
  ///     nonnegative. The default is zero.
  ///   - type: The type of `value`.
  public func storeBytes<T>(of value: T, toByteOffset offset: Int = 0, as type: T.Type)
}
```



`UnsafeRawBufferPointer`  and `UnsafeMutableRawBufferPointer` receive a similar addition of a `loadUnaligned` function. It enables loading from an arbitrary offset with the buffer, subject to the usual index validation rules of `BufferPointer` types: indexes are checked when client code is compiled in debug mode, while indexes are unchecked when client code is compiled in release mode.

```swift
extension Unsafe{Mutable}RawBufferPointer {
  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  ///
  /// This function only supports loading trivial types.
  /// A trivial type does not contain any reference-counted property
  /// within its in-memory stored representation.
  /// The memory at `offset` bytes into the buffer must be laid out
  /// identically to the in-memory representation of `T`.
  ///
  /// - Note: A trivial type can be copied with just a bit-for-bit copy without
  ///   any indirection or reference-counting operations. Generally, native
  ///   Swift types that do not contain strong or weak references or other
  ///   forms of indirection are trivial, as are imported C structs and enums.
  ///
  /// You can use this method to create new values from the buffer pointer's
  /// underlying bytes. The following example creates two new `Int32`
  /// instances from the memory referenced by the buffer pointer `someBytes`.
  /// The bytes for `a` are copied from the first four bytes of `someBytes`,
  /// and the bytes for `b` are copied from the next four bytes.
  ///
  ///     let a = someBytes.load(as: Int32.self)
  ///     let b = someBytes.load(fromByteOffset: 4, as: Int32.self)
  ///
  /// The memory to read for the new instance must not extend beyond the buffer
  /// pointer's memory region---that is, `offset + MemoryLayout<T>.size` must
  /// be less than or equal to the buffer pointer's `count`.
  ///
  /// - Parameters:
  ///   - offset: The offset, in bytes, into the buffer pointer's memory at
  ///     which to begin reading data for the new instance. The buffer pointer
  ///     plus `offset` must be properly aligned for accessing an instance of
  ///     type `T`. The default is zero.
  ///   - type: The type to use for the newly constructed instance. The memory
  ///     must be initialized to a value of a type that is layout compatible
  ///     with `type`.
  /// - Returns: A new instance of type `T`, copied from the buffer pointer's
  ///   memory.
  public func loadUnaligned<T>(fromByteOffset offset: Int = 0, as type: T.Type) -> T
}
```

Additionally, the semantics of  `UnsafeMutableBufferPointer.storeBytes(of:toByteOffset)` will be changed in the same way as its counterpart `UnsafeMutablePointer.storeBytes(of:toByteOffset)`, no longer enforcing alignment at runtime. Again, the index validation behaviour is unchanged: indexes are checked when client code is compiled in debug mode, while indexes are unchecked when client code is compiled in release mode.

```swift
extension UnsafeMutableRawBufferPointer {
  /// Stores a value's bytes into the buffer pointer's raw memory at the
  /// specified byte offset.
  ///
  /// The type `T` to be stored must be a trivial type. The memory must also be
  /// uninitialized, initialized to `T`, or initialized to another trivial
  /// type that is layout compatible with `T`.
  ///
  /// The memory written to must not extend beyond the buffer pointer's memory
  /// region---that is, `offset + MemoryLayout<T>.size` must be less than or
  /// equal to the buffer pointer's `count`.
  ///
  /// After calling `storeBytes(of:toByteOffset:as:)`, the memory is
  /// initialized to the raw bytes of `value`. If the memory is bound to a
  /// type `U` that is layout compatible with `T`, then it contains a value of
  /// type `U`. Calling `storeBytes(of:toByteOffset:as:)` does not change the
  /// bound type of the memory.
  ///
  /// - Note: A trivial type can be copied with just a bit-for-bit copy without
  ///   any indirection or reference-counting operations. Generally, native
  ///   Swift types that do not contain strong or weak references or other
  ///   forms of indirection are trivial, as are imported C structs and enums.
  ///
  /// If you need to store a copy of a value of a type that isn't trivial into memory,
  /// you cannot use the `storeBytes(of:toByteOffset:as:)` method. Instead, you must know
  /// the type of value previously in memory and initialize or assign the memory.
  ///
  /// - Parameters:
  ///   - offset: The offset in bytes into the buffer pointer's memory to begin
  ///     reading data for the new instance. The buffer pointer plus `offset`
  ///     must be properly aligned for accessing an instance of type `T`. The
  ///     default is zero.
  ///   - type: The type to use for the newly constructed instance. The memory
  ///     must be initialized to a value of a type that is layout compatible
  ///     with `type`.
  public func storeBytes<T>(of value: T, toByteOffset offset: Int = 0, as: T.Type)
}
```



## Source compatibility

This proposal is source compatible. The proposed API modifications relax existing restrictions and keep the same signatures, therefore the changes are compatible. The API additions are source compatible by definition.

## Effect on ABI stability

Existing binaries that expect the old behaviour of `storeBytes` will not be affected by the relaxed behaviour proposed here, as we will ensure that the old symbol (with its existing semantics) will remain.

New binaries that require the new behaviour will correctly backwards deploy by the use of the `@_alwaysEmitIntoClient` attribute. The new API will likewise use the `@_alwaysEmitIntoClient` attribute.

## Effect on API resilience

If the added API were removed in a future release, the change would be source-breaking but not ABI-breaking, because the proposed additions will always be inlined.

## Alternatives considered

#### Use a marker protocol to restrict unaligned loads to trivial types

We could enforce the use of unaligned loads at compile time by declaring a new marker protocol for trivial types, and require conformance to this protocol for types loaded through a function that can load from unaligned offsets. While this may be the ideal outcome, we believe this option would take too long to be realized. The approach proposed here can be a stepping stone on the way there.

#### Relax the alignment restriction on the existing `load` API

Arguably, user expectations are that the `load` API supports unaligned loads, but since that is not the case with the existing API, source-compatibility considerations dictate that the behaviour of the existing API should not change. If its preconditions were relaxed, a developer would encounter runtime crashes when deploying to a server using Swift 5.5, having tested using a newer toolchain.

For that reason, we chose to leave the existing API untouched.

Other programming languages have chosen whether loading from bytes is aligned or unaligned by default depending on their focus. For example, Go's [binary](https://pkg.go.dev/encoding/binary@go1.18) package privileges decoding data from a stream, and accordingly its various `Read` functions perform unaligned loads. [binary](https://pkg.go.dev/encoding/binary@go1.18)'s package documentation acknowledges privileging simplicity over efficiency. On the other hand, Rust's [raw pointer](https://doc.rust-lang.org/core/primitive.pointer.html) primitive type includes both [`read`](https://doc.rust-lang.org/core/ptr/fn.read.html) and [`read_unaligned`](https://doc.rust-lang.org/core/ptr/fn.read_unaligned.html) functions, where the default (with the "good" name) is more strict and more efficient. We believe that Swift's goals align well with having the more performant function (aligned load) be the default one.

#### Add a separate unaligned store API

Adding a separate unaligned store API would avoid ABI stability concerns, but the old API would become redundant. The risk of removing the restriction on `storeBytes` is less than it is for `load`, as the restriction is implemented using `_debugPrecondition`, which is compiled away in release mode.

#### Rename `storeBytes` to `storeUnaligned`, or call `loadUnaligned` `loadFromBytes` instead.

The idea of making the "load" and the "store" operations have more symmetric names is compelling, however there is a fundamental asymmetry in the operation itself. When a `load` operation completes, a new value is created to be managed by the Swift runtime. On the other hand the `storeBytes` operation is completely transparent to the runtime: the destination is a container of bytes that is _not_ managed by the Swift runtime. For this reason, the "store" operation has the word "bytes" in its name.

## Acknowledgments

Thanks to the Swift Standard Library team for valuable feedback and discussion.
