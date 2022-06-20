# Add an `offset(of:)` method to `MemoryLayout`

* Proposal: [SE-0210](0210-key-path-offset.md)
* Authors: [Joe Groff](https://github.com/jckarter)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 4.2)**
* Implementation: [apple/swift#15519](https://github.com/apple/swift/pull/15519)

## Introduction

This proposal introduces the ability for Swift code to query the in-memory
layout of stored properties in aggregates using key paths. Like the
`offsetof` macro in C, `MemoryLayout<T>.offset(of:)` returns the distance in
bytes between a pointer to a value and a pointer to one of its fields.

Swift-evolution thread: [Pitch: “offsetof”-like functionality for stored property key paths](https://forums.swift.org/t/pitch-offsetof-like-functionality-for-stored-property-key-paths/11309/13)

## Motivation

Many graphics and math libraries accept input data in arbitrary input formats,
which the user has to describe to the API when setting up their input buffers.
For example, OpenGL lets you describe the layout of vertex buffers using
series of calls to the `glVertexAttribPointer` API. In C, you can use the
standard `offsetof` macro to get the offset of fields within a struct, allowing
you to use the compiler's knowledge of a type's layout to fill out these
function calls:

```c
// Layout of one of our vertex entries
struct MyVertex {
  float position[4];
  float normal[4];
  uint16_t texcoord[2];
};

enum MyVertexAttribute { Position, Normal, TexCoord };

glVertexAttribPointer(Position, 4, GL_FLOAT, GL_FALSE,
                      sizeof(MyVertex), (void*)offsetof(MyVertex, position));
glVertexAttribPointer(Normal, 4, GL_FLOAT, GL_FALSE,
                      sizeof(MyVertex), (void*)offsetof(MyVertex, normal));
glVertexAttribPointer(TexCoord, 2, GL_UNSIGNED_BYTE, GL_TRUE,
                      sizeof(MyVertex), (void*)offsetof(MyVertex, texcoord));
```

There's currently no equivalent to `offsetof` in Swift, so users of these kinds
of APIs must either write those parts of their code in C or else do Swift
memory layout in their heads, which is error-prone if they ever change their
data layout or the Swift compiler implementation changes its layout algorithm
(which it reserves the right to do).

## Proposed solution

Key paths now provide a natural way to refer to fields in Swift. We can add
an API to the `MemoryLayout` type to ask for the offset of the field
represented by a key path.

## Detailed design

A new API is added to `MemoryLayout`:

```swift
extension MemoryLayout {
  public static func offset(of key: PartialKeyPath<T>) -> Int?
}
```

If the given `key` refers to inline storage within the
in-memory representation of `T`, and the storage is directly
addressable (meaning that accessing it does not need to trigger any
`didSet` or `willSet` accessors, perform any representation changes
such as bridging or closure reabstraction, or mask the value out of
overlapping storage as for packed bitfields), then the return value
is a distance in bytes that can be added to a pointer of type `T` to
get a pointer to the storage accessed by `key`. In other words, if the return
value is non-nil, then these formulations are equivalent:

```swift
var root: T, value: U
var key: WritableKeyPath<T, U>
// Mutation through the key path...
root[keyPath: \.key] = value
// ...is exactly equivalent to mutation through the offset pointer...
withUnsafePointer(to: &root) {
  (UnsafeMutableRawPointer($0) + MemoryLayout<T>.offset(of: \.key))
    // ...which can be assumed to be bound to the target type
    .assumingMemoryBound(to: U.self).pointee = value
}
```

One possible set of answers for a Swift struct might look like this:

```swift
struct Point {
  var x, y: Double
}

struct Size {
  var w, h: Double

  var area: Double { return w*h }
}

struct Rect {
  var origin: Point
  var size: Size
}

MemoryLayout<Rect>.offset(of: \.origin.x) // => 0
MemoryLayout<Rect>.offset(of: \.origin.y) // => 8
MemoryLayout<Rect>.offset(of: \.size.w) // => 16
MemoryLayout<Rect>.offset(of: \.size.h) // => 24
MemoryLayout<Rect>.offset(of: \.size.area) // => nil
```

In Swift today, only key paths that refer to
struct fields would support taking their offset, though if support for tuple
elements in key paths were added in the future, tuple elements could
as well. Class properties are always stored out-of-line, and require runtime
exclusivity checking to access, so their offsets would not be available by this
mechanism.

## Source compatibility

This is an additive change to the API of `MemoryLayout`.

## Effect on ABI stability

`KeyPath` objects already encode the offset information for stored properties
necessary to implement this, so this has no additional demands from the ABI.

## Effect on API resilience

Clients of an API could potentially use this functionality to dynamically
observe whether a public property is implemented as a stored property from
outside of the module. If a client assumes that a property will always be
stored by force-unwrapping the optional result of `offset(of:)`, that could
lead to compatibility problems if the library author changes the property to
computed in a future library version. Client code using offsets should be
careful not to rely on the stored-ness of properties in types they don't
control.

## Alternatives considered

Instead of a new static method on `MemoryLayout`, this functionality could also
be expressed as an `offset` property on `KeyPath`. All of the information
necessary to answer the offset question is in the `KeyPath` value itself.
Nonetheless, `MemoryLayout` seems like the natural place to put this API.

A related API that might be useful to build on top of this functionality would
be to add methods to `UnsafePointer` and `UnsafeMutablePointer` for projecting
a pointer to a field from a pointer to a base value, for example:

```swift
extension UnsafePointer {
  subscript<Field>(field: KeyPath<Pointee, Field>) -> UnsafePointer<Field> {
    return (UnsafeRawPointer(self) + MemoryLayout<Pointee>.offset(of: field))
      .assumingMemoryBound(to: Field.self)
  }
}

extension UnsafeMutablePointer {
  subscript<Field>(field: KeyPath<Pointee, Field>) -> UnsafePointer<Field> {
    return (UnsafeRawPointer(self) + MemoryLayout<Pointee>.offset(of: field))
      .assumingMemoryBound(to: Field.self)
  }

  subscript<Field>(field: WritableKeyPath<Pointee, Field>) -> UnsafeMutablePointer<Field> {
    return (UnsafeMutableRawPointer(self) + MemoryLayout<Pointee>.offset(of: field))
      .assumingMemoryBound(to: Field.self)
  }
}
```
