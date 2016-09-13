# Change `Unmanaged` to use `UnsafePointer`

* Proposal: [SE-0017](0017-convert-unmanaged-to-use-unsafepointer.md)
* Author: [Jacob Bandes-Storch](https://github.com/jtbandes)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000133.html)
* Bug: [SR-1485](https://bugs.swift.org/browse/SR-1485)

## Introduction

The standard library [`Unmanaged<Instance>` struct](https://github.com/apple/swift/blob/master/stdlib/public/core/Unmanaged.swift) provides a type-safe object wrapper that does not participate in ARC; it allows the user to make manual retain/release calls.

[Swift Evolution Discussion](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/001046.html), [Proposed Rewrite Discussion](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/003243.html), [Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160425/016034.html)

## Motivation

The following methods are provided for converting to/from Unmanaged:

```swift
static func fromOpaque(value: COpaquePointer) -> Unmanaged<Instance>
func toOpaque() -> COpaquePointer
```

However, C APIs that accept `void *` or `const void *` are exposed to Swift as `UnsafePointer<Void>` or `UnsafeMutablePointer<Void>`, rather than `COpaquePointer`. In practice, users must convert `UnsafePointer` → `COpaquePointer` → `Unmanaged`, which leads to bloated code such as

```swift
someFunction(context: UnsafeMutablePointer(Unmanaged.passUnretained(self).toOpaque()))

info.retain = { Unmanaged<AnyObject>.fromOpaque(COpaquePointer($0)).retain() }
info.copyDescription = {
    Unmanaged.passRetained(CFCopyDescription(Unmanaged.fromOpaque(COpaquePointer($0)).takeUnretainedValue()))
}
```

## Proposed solution

In the `Unmanaged` API, replace the usage of `COpaquePointer` with `UnsafePointer<Void>` and `UnsafeMutablePointer<Void>`.

The affected functions are `fromOpaque()` and `toOpaque()`. Only very minor modification is required from the [current implementation](https://github.com/apple/swift/blob/0287ac7fd94af0fb860b5444e1bd26faded88e39/stdlib/public/core/Unmanaged.swift#L32-L54):

```swift
@_transparent
@warn_unused_result
public static func fromOpaque(value: UnsafePointer<Void>) -> Unmanaged {
    // Null pointer check is a debug check, because it guards only against one
    // specific bad pointer value.
    _debugPrecondition(
      value != nil,
      "attempt to create an Unmanaged instance from a null pointer")

    return Unmanaged(_private: unsafeBitCast(value, Instance.self))
}

@_transparent
@warn_unused_result
public func toOpaque() -> UnsafeMutablePointer<Void> {
    return unsafeBitCast(_value, UnsafeMutablePointer<Void>.self)
}
```

Note that values of type `UnsafeMutablePointer` can be passed to functions accepting either `UnsafePointer` or `UnsafeMutablePointer`, so for simplicity and ease of use, we choose `UnsafePointer` as the input type to `fromOpaque()`, and `UnsafeMutablePointer` as the return type of `toOpaque()`.

The example usage above no longer requires conversions:

```swift
someFunction(context: Unmanaged.passUnretained(self).toOpaque())

info.retain = { Unmanaged<AnyObject>.fromOpaque($0).retain() }
info.copyDescription = {
    Unmanaged.passRetained(CFCopyDescription(Unmanaged.fromOpaque($0).takeUnretainedValue()))
}
```

## Impact on existing code

Code previously calling `Unmanaged` API with `COpaquePointer` will need to change to use `UnsafePointer`. The `COpaquePointer` variants can be kept with availability attributes to aid the transition, such as:

    @available(*, unavailable, message="use fromOpaque(value: UnsafeMutablePointer<Void>) instead")
    @available(*, unavailable, message="use toOpaque() -> UnsafePointer<Void> instead")

[Code that uses `COpaquePointer`](https://github.com/search?q=COpaquePointer&type=Code) does not seem to depend on it heavily, and would not be significantly harmed by this change.

## Alternatives considered

- Make no change. However, it has been [said on swift-evolution](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/001096.html) that `COpaquePointer` is vestigial, and better bridging of C APIs is desired, so we do want to move in this direction.

