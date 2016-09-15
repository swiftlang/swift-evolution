# Remove `NonObjectiveCBase` and `isUniquelyReferenced`

* Proposal: [SE-0125](0125-remove-nonobjectivecbase.md)
* Author: [Arnold Schwaighofer](https://github.com/aschwaighofer)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000261.html)
* Bug: [SR-1962](http://bugs.swift.org/browse/SR-1962)

## Introduction

Remove `NonObjectiveCBase` and
`isUniquelyReferenced<T: NonObjectiveCBase>(_ object: T)`.
`isUniquelyReferenced` can be replaced by
`isUniquelyReferencedNonObjC<T: AnyObject>(_ object: T)`. This
replacement is as performant as the call to `isUniquelyReferenced` in cases
where the compiler has static knowledge that the type of `object` is a native
Swift class and dyamically has the same semantics for native swift classes.
This change will remove surface API.
Rename `isUniquelyReferencedNonObjC` to `isKnownUniquelyReferenced` and no
longer promise to return false for `@objc` class instances.
Cleanup the `ManagedBufferPointer` API by renaming `holdsUniqueReference` to
`isUniqueReference` and removing `holdsUniqueOrPinnedReference`.

- Swift-evolution thread: [Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160718/024806.html)
- Branch with change to stdlib: [remove_nonobjectivecbase_2]
  (https://github.com/aschwaighofer/swift/commits/remove_nonobjectivecbase_2)

## Motivation

Today we have `isUniquelyReferenced` which only works on subclasses of
NonObjectiveCBase, and we have `isUniquelyReferencedNonObjC` which also works on
`@objc` classes.

```swift
class SwiftKlazz : NonObjectiveCBase {}
class ObjcKlazz : NSObject {}

expectTrue(isUniquelyReferenced(SwiftKlazz()))
expectFalse(isUniquelyReferencedNonObjC(ObjcKlazz()))

// Would not compile:
expectFalse(isUniquelyReferenced(ObjcKlazz()))
```

In most cases we expect developers to be using the ManagedBufferPointer type.
In cases where they want to use a custom class they would use
`isUniquelyReferenced` today and can use `isUniquelyReferencedNonObjC` which
will be renamed `isKnownUniquelyReferenced` in the future.

```swift
class SwiftKlazz {}

expectTrue(isKnownUniquelyReferenced(SwiftKlazz()))
```

Removing `isUniquelyReferenced<T : NonObjectiveCBase>`  will allow us to remove
the `NonObjectiveCBase` class from the standard library thereby further
shrinking API surface.

Renaming `isUniquelyReferencedNonObjC` to `isKnownUniquelyReferenced` makes
sense since "NonObjC" makes no sense on platforms without Objective-C
interoperability. `isKnownUniquelyReferenced` will no longer promise to return
false for `@objc` class instances. The intent of this API is to support
copy-on-write implementations.

Renaming `ManagedBufferPointer` API `holdsUniqueReference` to
`isUniqueReference` makes it clearer that is has the same semantics as the
`isKnownUniquelyReferenced` check.

We also propose to remove the `holdsUniqueOrPinnedReference` API because there
could not be any uses of it since the pinning API is not public.

## Proposed solution

Remove `isUniquelyReferenced<T : NonObjectiveCBase>` and remove the
`NonObjectiveCBase` class from the standard library. Clients of the the
`isUniquelyReferenced` API can be migrated to use
`isUniquelyReferencedNonObjC`. In cases -- where the type of the `object`
parameter is statically known to be a native non-`@objc` class -- the resulting
code will have identical performance characteristics. In fact, the current
implementation boils down to the same builtin call. Based on the static type of
the `object` operand the compiler can emit more efficient code when the static
type is known to be of a non-`@objc` class.

Rename `isUniquelyReferencedNonObjC` to `isKnownUniquelyReferenced` such
that the API makes sense on platforms without Objective-C and stop promising to
return `false` for `@objc` objects.

Rename `ManagedBufferPointer.holdsUniqueReference` to
`ManagedBufferPointer.isUniqueReference` to avoid confusion.

Remove `ManagedBufferPointer.holdsUniqueOrPinnedReference` because there is no
public pinning API so having this public API is not necessary.

## Detailed design

Todays APIs that can be used to check uniqueness is the family of
`isUniquelyReferenced` functions.

```swift
/// Returns `true` iff `object` is a non-`@objc` class instance with
/// a single strong reference.
///
/// * Does *not* modify `object`; the use of `inout` is an
///   implementation artifact.
/// * If `object` is an Objective-C class instance, returns `false`.
/// * Weak references do not affect the result of this function.
///
/// Useful for implementing the copy-on-write optimization for the
/// deep storage of value types:
///
///     mutating func modifyMe(_ arg: X) {
///       if isUniquelyReferencedNonObjC(&myStorage) {
///         myStorage.modifyInPlace(arg)
///       }
///       else {
///         myStorage = self.createModified(myStorage, arg)
///       }
///     }
public func isUniquelyReferencedNonObjC<T : AnyObject>(_ object: inout T) -> Bool
public func isUniquelyReferencedNonObjC<T : AnyObject>(_ object: inout T?) -> Bool

/// A common base class for classes that need to be non-`@objc`,
/// recognizably in the type system.
public class NonObjectiveCBase {
  public init() {}
}

public func isUniquelyReferenced<T : NonObjectiveCBase>(
  _ object: inout T
) -> Bool
```

And the somewhat higher level APIs that can be used to model a storage with
several elements `ManagedBufferPointer`.

```swift

/// Contains a buffer object, and provides access to an instance of
/// `Header` and contiguous storage for an arbitrary number of
/// `Element` instances stored in that buffer.
///
/// For most purposes, the `ManagedBuffer` class works fine for this
/// purpose, and can simply be used on its own.  However, in cases
/// where objects of various different classes must serve as storage,
/// `ManagedBufferPointer` is needed.
///
/// A valid buffer class is non-`@objc`, with no declared stored
///   properties.  Its `deinit` must destroy its
///   stored `Header` and any constructed `Element`s.
/// `Header` and contiguous storage for an arbitrary number of
/// `Element` instances stored in that buffer.
public struct ManagedBufferPointer<Header, Element> : Equatable {
  /// Create with new storage containing an initial `Header` and space
  /// for at least `minimumCapacity` `element`s.
  ///
  /// - parameter bufferClass: The class of the object used for storage.
  /// - parameter minimumCapacity: The minimum number of `Element`s that
  ///   must be able to be stored in the new buffer.
  /// - parameter initialHeader: A function that produces the initial
  ///   `Header` instance stored in the buffer, given the `buffer`
  ///   object and a function that can be called on it to get the actual
  ///   number of allocated elements.
  ///
  /// - Precondition: `minimumCapacity >= 0`, and the type indicated by
  ///   `bufferClass` is a non-`@objc` class with no declared stored
  ///   properties.  The `deinit` of `bufferClass` must destroy its
  ///   stored `Header` and any constructed `Element`s.
  public init(
    bufferClass: AnyClass,
    minimumCapacity: Int,
    initialHeader: @noescape (buffer: AnyObject, capacity: @noescape (AnyObject) -> Int) throws -> Header
  ) rethrows

  /// Returns `true` iff `self` holds the only strong reference to its buffer.
  ///
  /// See `isUniquelyReferenced` for details.
  public mutating func holdsUniqueReference() -> Bool

  /// Returns `true` iff either `self` holds the only strong reference
  /// to its buffer or the pinned has been 'pinned'.
  ///
  /// See `isUniquelyReferenced` for details.
  public mutating func holdsUniqueOrPinnedReference() -> Bool

  internal var _nativeBuffer: Builtin.NativeObject
}

/// A class whose instances contain a property of type `Header` and raw
/// storage for an array of `Element`, whose size is determined at
/// instance creation.
public class ManagedBuffer<Header, Element>
  : ManagedProtoBuffer<Header, Element> {

  /// Create a new instance of the most-derived class, calling
  /// `initialHeader` on the partially-constructed object to
  /// generate an initial `Header`.
  public final class func create(
    minimumCapacity: Int,
    initialHeader: @noescape (ManagedProtoBuffer<Header, Element>) throws -> Header
  ) rethrows -> ManagedBuffer<Header, Element> {

    let p = try ManagedBufferPointer<Header, Element>(
      bufferClass: self,
      minimumCapacity: minimumCapacity,
      initialHeader: { buffer, _ in
        try initialHeader(
          unsafeDowncast(buffer, to: ManagedProtoBuffer<Header, Element>.self))
      })

    return unsafeDowncast(p.buffer, to: ManagedBuffer<Header, Element>.self)
  }
}

```

We propose to remove the `NonObjectiveCBase` class and
`isUniquelyReferenced<T: NonObjectiveCBase>(_ object: T>` and rename
`isUniquelyReferencedNonObjC` to `isKnownUniquelyReferenced`.

Code that was written as the following.

```swift
class ClientClass : NonObjectiveCBase { }
class ClientClass2 : NonObjectiveCBase { }

var x: NonObjectiveCBase = pred ? ClientClass() : ClientClass2()

if isUniquelyReferenced(x) { ...}
```

Can be changed to the following with exactly the same performance characteristic
and semantics.

```swift
class CommonNonObjectiveCBase {}
class ClientClass : CommonNonObjectiveCBase { }
class ClientClass2 : CommonNonObjectiveCBase { }

var x: CommonNonObjectiveCBase = pred ? ClientClass() : ClientClass2()

if isKnownUniquelyReferenced(x) { ...}
```

The new API will be as follows.

```swift
/// Returns `true` iff `object` is class instance with a single strong
/// reference.
///
/// * Does *not* modify `object`; the use of `inout` is an
///   implementation artifact.
/// * Weak references do not affect the result of this function.
///
/// Useful for implementing the copy-on-write optimization for the
/// deep storage of value types:
///
///     mutating func modifyMe(_ arg: X) {
///       if isKnownUniquelyReferenced(&myStorage) {
///         myStorage.modifyInPlace(arg)
///       }
///       else {
///         myStorage = self.createModified(myStorage, arg)
///       }
///     }
public func isKnownUniquelyReferenced<T : AnyObject>(_ object: inout T) -> Bool
public func isKnownUniquelyReferenced<T : AnyObject>(_ object: inout T?) -> Bool
```

```swift
/// Contains a buffer object, and provides access to an instance of
/// `Header` and contiguous storage for an arbitrary number of
/// `Element` instances stored in that buffer.
///
/// For most purposes, the `ManagedBuffer` class works fine for this
/// purpose, and can simply be used on its own.  However, in cases
/// where objects of various different classes must serve as storage,
/// `ManagedBufferPointer` is needed.
///
/// A valid buffer class is non-`@objc`, with no declared stored
///   properties.  Its `deinit` must destroy its
///   stored `Header` and any constructed `Element`s.
/// `Header` and contiguous storage for an arbitrary number of
/// `Element` instances stored in that buffer.
public struct ManagedBufferPointer<Header, Element> : Equatable {
  /// Create with new storage containing an initial `Header` and space
  /// for at least `minimumCapacity` `element`s.
  ///
  /// - parameter bufferClass: The class of the object used for storage.
  /// - parameter minimumCapacity: The minimum number of `Element`s that
  ///   must be able to be stored in the new buffer.
  /// - parameter initialHeader: A function that produces the initial
  ///   `Header` instance stored in the buffer, given the `buffer`
  ///   object and a function that can be called on it to get the actual
  ///   number of allocated elements.
  ///
  /// - Precondition: `minimumCapacity >= 0`, and the type indicated by
  ///   `bufferClass` is a non-`@objc` class with no declared stored
  ///   properties.  The `deinit` of `bufferClass` must destroy its
  ///   stored `Header` and any constructed `Element`s.
  public init(
    bufferClass: AnyClass,
    minimumCapacity: Int,
    initialHeader: @noescape (buffer: AnyObject, capacity: @noescape (AnyObject) -> Int) throws -> Header
  ) rethrows

  /// Returns `true` iff `self` holds the only strong reference to its buffer.
  ///
  /// See `isUniquelyReferenced` for details.
  public mutating func isUniqueReference() -> Bool
}
```

## Impact on existing code

Existing code that uses `isUniquelyReferenced` will need to remove the
`NonObjectiveCBase` base class and replace calls to `isUniquelyReferenced` by
`isKnownUniquelyReferenced`. The old API will be marked unavailable to help
migration.


## Alternatives considered

Leave the status quo and pay for type safety with additional API surface.
Another alternative we considered -- the first version of this proposal -- was
to replace the `isUniquelyReferenced` API by an
`isUniquelyReferencedUnsafe<T: AnyObject>(_ object: T)` API that would assume
the `object` to be a non-@objc class and only check this precondition under
-Onone. There is however no good reason to keep this API given that the
`isUniquelyReferencedNonObjC` is as performant when the type is statically known
to be non-`@objc` class.
