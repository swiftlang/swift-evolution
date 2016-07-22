# Cleaning up stdlib Pointer and Buffer Routines

* Proposal: [SE-0127](0127-cleaning-up-stdlib-ptr-buffer.md)
* Author: [Charlie Monroe](https://github.com/charlieMonroe)
* Status: **Active Review July 20...24**
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

This proposal deals with three routines and one class related to pointers and buffers.
The goal of this proposal is to update the API to match new API guidelines and remove 
redundant identifiers.

Swift-evolution thread: [Cleaning up stdlib Pointer and Buffer Routines](http://thread.gmane.org/gmane.comp.lang.swift.evolution/23093)

## Motivation

The Swift standard library has been thoroughly updated to follow the new API guidelines and these are
the few places that need to be updated in pointer and buffer APIs:

- `withUnsafe[Mutable]Pointer`'s `arg` argument should have a `to:` label ([SR-1937](https://bugs.swift.org/browse/SR-1937))
- `withUnsafePointer`'s `arg` argument should no longer be `inout` as it requires 
creation of temporary `var`s ([SR-1956](https://bugs.swift.org/browse/SR-1956)).
- `unsafeAddressOf` should be removed since there is a limited number of use cases and there are better alternatives to it ([SR-1957](https://bugs.swift.org/browse/SR-1937)).
- `ManagedProtoBuffer` should be removed. It is a superclass of `ManagedBuffer` and its
sole purpose is to conceal the `header` property during invocation of the closure 
creating the initial header in `ManagedBuffer.create` since the `header` isn't 
initialized at that point. This adds unnecessary complexity to the API in order to
prevent something that should be considered programmer's error.

## Proposed solution

`withUnsafe[Mutable]Pointer` methods will now include `to:` argument label:

```
withUnsafePointer(to: x) { (ptr) -> Void in
	// ...
}
```

---

Also, the non-mutable `withUnsafePointer`'s arguments will no longer be `inout`, 
allowing the following:

```
// This needs to be var in Swift 2.x
let x = NSObject() 

withUnsafePointer(to: x) { (ptr) -> Void in
	/// ...
}
```

---

`unsafeAddressOf` is removed, in favor of adding a `unsafeAddress` field on `ObjectIdentifier`.
`ObjectIdentifier` already contains a raw pointer in the internal `_value` field and 
can be initialized with `AnyObject` just like the argument of `unsafeAddressOf`.

```
let obj = NSObject()
let ptr = ObjectIdentifier(obj).unsafeAddress // instead of unsafeAddress(of: obj)
```

---

The class `ManagedProtoBuffer` is removed as mentioned in motivation. All its members
will be moved onto `ManagedBuffer` instead.


## Impact on existing code

`withUnsafe[Mutable]Pointer` usage will need to be updated to include the `to:` label
and the non-mutable version will need to have the `&` reference removed since it will
no longer be `inout`.

Use of `unsafeAddressOf(x)` will need to be changed to `ObjectIdentifier(x).unsafeAddress`
 instead.

Since `ManagedProtoBuffer` doesn't have any accessible initializers, it can only be
referenced in the code as an explicit type. Such occurrences can be renamed to
`ManagedBuffer` instead.

## Alternatives considered

- Keeping the argument of `withUnsafePointer` as `inout`.
- Remove `unsafeAddressOf` and use `Unmanaged.takeUnretainedValue(_:)` instead. This,
however, requires the caller to deal with retain logic for something as simple as
getting an object address.
- Alternative names for the `unsafeAddress` property on `ObjectIdentifier` - `value`,
`pointerValue`, `pointer`.
- Instead of removing `ManagedProtoBuffer`, rename it to `ManagedBufferBase`.
