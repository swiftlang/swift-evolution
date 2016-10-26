# Cleaning up stdlib Pointer and Buffer Routines

* Proposal: [SE-0127](0127-cleaning-up-stdlib-ptr-buffer.md)
* Author: [Charlie Monroe](https://github.com/charlieMonroe)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000262.html)
* Bugs: [SR-1937](https://bugs.swift.org/browse/SR-1937),
        [SR-1955](https://bugs.swift.org/browse/SR-1955),
        [SR-1957](https://bugs.swift.org/browse/SR-1957)

## Introduction

This proposal deals with three routines and one class related to pointers and buffers.
The goal of this proposal is to update the API to match new API guidelines and remove 
redundant identifiers.

Swift-evolution thread: [Cleaning up stdlib Pointer and Buffer Routines](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160704/023518.html)

## Motivation

The Swift standard library has been thoroughly updated to follow the new API guidelines and these are
the few places that need to be updated in pointer and buffer APIs:

- `withUnsafe[Mutable]Pointer`'s `arg` argument should have a `to:` label ([SR-1937](https://bugs.swift.org/browse/SR-1937))
- `withUnsafe[Mutable]Pointers` (multiple pointers) functions should be removed.
- `unsafeAddressOf` should be removed since there is a limited number of use cases and there are 
better alternatives to it ([SR-1957](https://bugs.swift.org/browse/SR-1957)).
- `ManagedProtoBuffer` should be removed. It is a superclass of `ManagedBuffer` and its
sole purpose is to conceal the `header` property during invocation of the closure 
creating the initial header in `ManagedBuffer.create` since the `header` isn't 
initialized at that point. This adds unnecessary complexity to the API in order to
prevent something that should be considered programmer's error.

## Proposed solution

`withUnsafe[Mutable]Pointer` methods will now include `to:` argument label:

```
withUnsafePointer(to: &x) { (ptr) -> Void in
	// ...
}
```

---

The multiple-pointer variations of the methods (`withUnsafe[Mutable]Pointers`) should
be removed since the use cases in which they can be used are very limited and their use can be
easily worked around by using nested calls to the single-pointer variants:

```
var x = NSObject() 
var y = NSObject() 

withUnsafePointer(to: &x) { (ptrX) -> Void in
	withUnsafePointer(to: &y) { (ptrY) -> Void in
		/// ...
	}
}
```

---

`unsafeAddressOf` is removed. Suggested replacement is to use `Unmanged.passUnretained`.

```
let obj = NSObject()
let ptr = Unmanaged.passUnretained(obj) // instead of unsafeAddress(of: obj)
```

---

The class `ManagedProtoBuffer` is removed as mentioned in motivation. All its members
will be moved onto `ManagedBuffer` instead.


## Impact on existing code

`withUnsafe[Mutable]Pointer` usage will need to be updated to include the `to:` label
and the multi-pointer versions will need to be removed by the user and nested calls to single-pointer 
variants need to be used instead.

Use of `unsafeAddressOf(x)` will need to be changed to `Unmanaged.passUnretained(x)`
 instead.

Since `ManagedProtoBuffer` doesn't have any accessible initializers, it can only be
referenced in the code as an explicit type. Such occurrences can be renamed to
`ManagedBuffer` instead.

## Alternatives considered

- `withUnsafePointer`'s argument is currently marked as `inout` which allows the function
to provide the same address even for non-object values that are passed in as reference.
This, however, may lead to unnecessary creation of `var` variables, instead of keeping
them as immutable (`let`). Discussion on the mailing list brought up two suggestions:
	- eliminate `withUnsafePointer` altogether and only keep the mutable `withUnsafeMutablePointer`
	  variant since it can be used instead of the immutable variant in all use cases. This change
	  would, however, conceal the caller's intention of what is going to be done with the pointer.
	- The second suggestion was to introduce two variants of `withUnsafePointer` - one that maintains
	  current behavior and one that that doesn't require `inout` argument. This has been viewed on as 
	  an additive change not in scope for Swift 3.
- Instead of removing `ManagedProtoBuffer`, rename it to `ManagedBufferBase`.
