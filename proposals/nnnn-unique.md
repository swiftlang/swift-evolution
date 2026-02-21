# Unique

* Proposal: [SE-NNNN](nnnn-unique.md)
* Authors: [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [swiftlang/swift#86336](https://github.com/swiftlang/swift/pull/86336)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

We propose to introduce a new type in the standard library `Unique` which is a
smart pointer type that uniquely owns a value on the heap.

## Motivation

Sometimes in Swift it's necessary to manually put something on the heap when it
normally wouldn't be located there. Types such as `InlineArray` or a custom
struct with lots of fields are stored on the stack or in registers which can
lead to a code size increase if they're being passed around frequently.
Indirecting these values through an allocation may be more performant in some
cases.

A common way of doing something like this today is by using pointers directly:

```swift
let ptr = unsafe UnsafeMutablePointer<[512 of Int]>.allocate(capacity: 1)

// Make sure to perform cleanup at the end of the scope!
defer {
  unsafe ptr.deinitialize()
  unsafe ptr.deallocate()
}


// Must initialize the pointer the first
unsafe ptr.initialize(to: [...])

// Now we can access 'pointee' and read/write to our '[512 of Int]'
unsafe ptr.pointee[15] += 123

...

// 'ptr' gets deallocated here
```

Using pointers like this is extremely unsafe and error prone. We previously
couldn't make wrapper types over this pattern because we couldn't perform the
cleanup happening in the `defer` in structs. It wasn't until recently that we
gained noncopyable types that allowed us to have `deinit`s in structs. A common
pattern in Swift is to instead wrap an instance in a class to get similar
cleanup behavior:

```swift
class Box<T> {
  var value: T

  init(value: T) {
    self.value = value
  }
}
```

This is much nicer and safer than the original pointer code, however this
construct is more of a shared pointer than a unique one. Classes also come with
their own overhead on top of the pointer allocation leading to slightly worse
performance than using pointers directly.

## Proposed solution

The standard library will add a new noncopyable type `Unique` which is a safe
smart pointer that uniquely owns some instance on the heap.

```swift
// Storing an inline array on the heap
var box = Unique<[3 of _]>([1, 2, 3])

print(box.value) // [1, 2, 3]

box.value.swapAt(0, 2)

print(box.value) // [3, 2, 1]
```

It's smart because it will automatically clean up the heap allocation when the
unique box is no longer being used:

```swift
struct Foo: ~Copyable {
  func bar() {
    print("bar")
  }

  deinit {
    print("foo")
  }
}

func main() {
  let box = Unique(Foo())

  box.value.bar() // "bar"

  print("baz") // "baz"

  // "foo"
}
```

## Detailed design

```swift
/// A smart pointer type that uniquely owns an instance of `Value` on the heap.
public struct Unique<Value: ~Copyable>: ~Copyable {
  /// Initializes a value of this unique box with the given initial value.
  ///
  /// - Parameter initialValue: The initial value to initialize the unique box
  ///                           with.
  public init(_ initialValue: consuming Value)
} 

extension Unique: Sendable where Value: Sendable & ~Copyable {}

extension Unique where Value: ~Copyable {
  /// Dereferences the unique box allowing for in-place reads and writes to the
  /// stored `Value`.
  public var value: Value {
    borrow
    mutate
  }

  /// Consumes the unqiue box and returns the instance of `Value` that was
  /// within the box.
  public consuming func consume() -> Value
}

extension Unique where Value: ~Copyable {
  /// Returns a single element span reference to the instance of `Value` stored
  /// within this unique box.
  public var span: Span<Value> {
    get
  }

  /// Returns a single element mutable span reference to the instance of `Value`
  /// stored within this unique box.
  public var mutableSpan: MutableSpan<Value> {
    mutating get
  }
}

extension Unique where Value: Copyable {
  /// Copies the value within the unique box and returns it in a new unique
  /// instance.
  public func clone() -> Unique<Value>
}
```

`Unique` provides a stable address to the value allocated on the heap. While
a value of this type can still be freely moved by the compiler, a move of an
instance of it does not move the value it allocated; the physical address of the
pointer remains stable. This proposal does not introduce an API to get this
pointer from a `Unique` instance as we leave that for a future direction.

## Source compatibility

`Unique` is a brand new type in the standard library, so source should still
be compatible.

## ABI compatibility

The API introduced in this proposal is purely additive to the standard library's
ABI; thus existing ABI is compatible.

## Implications on adoption

`Unique` is a new type within the standard library, so adopters must use at
least the version of Swift that introduced this type.

## Alternatives considered

### Name this type `Box`

An earlier version of this proposal proposed `Box` as the name for this type,
but unfortunately that name is very common in the Swift ecosystem and is being
used for a similar but different construct (something more akin to
`std::shared_ptr` than what is being proposed which is akin to `std::unique_ptr`).

### Name this type `UniqueBox` or `UniquePtr`

Following C++'s `std::unique_ptr`, a natural name for this type could be
`UniquePtr`. However, there's a strong precedent of Swift developers reaching for
the `Box` name to manually put something on the heap. While C++ uses
`std::unique_ptr`, Rust does name their unique smart pointer type `Box`, so
there is prior art for both potential names. Another decent option is taking a
note from both languages and using `UniqueBox`. This proposal suggests `Unique`
as the succinct and simple name.

### Use an empty subscript for dereferencing instead of a named property

```swift
var box = Unique<[3 of _]>([1, 2, 3])
box.value.swapAt(0, 2) // [3, 2, 1]
```

An earlier version of this proposal suggested using an empty subscript instead
of a named property to access the underlying value:

```swift
box[].swapAt(0, 2)
```

The use of the empty subscript is unprecedented in the standard library or quite
frankly in Swift in general which led us to drop this approach. It is worth
noting however that one can currently dereference pointers in Swift with an
indexed subscript:

```swift
pointer[0].swapAt(0, 2)
```

### Rename `consume` to `take` or `move`

There a plenty of good names that could be used here like `take` or `move`.
`take` comes from `Optional.take()` and `move` from `UnsafeMutablePointer.move()`.
Both of those methods don't actually consume the parent instance they are called
on however unlike `consume`. Calling `consume` ends the lifetime of `Unique`
and it is immediately deallocated after returning the instance stored within.

## Future directions

### Add a `std::shared_ptr` alternative

This proposal only introduces the uniquely owned smart pointer type, but there's
also the shared smart pointer construct. C++ has this with `std::shared_ptr` and
Rust calls theirs `Arc`. While the unique pointer is able to make copyable types
noncopyable, the shared pointer is able to make noncopyable types into
copyable ones by keeping track of a reference count similar to classes in Swift.

### Introduce a `Clonable` protocol

`Unique` comes with a `clone` method that will effectively copy the unique box
and its contents entirely returning a new instance of it. We can't make `Unique`
a copyable type because we need to be able to customize deinitialization and for
performance reasons wouldn't want the compiler to implicitly add copies of it
either. So `Unique` is a noncopyable type, but when its contents are copyable
we can add explicit ways to copy the instance into a new allocation.

`Unique.clone()` is only available when the underlying `Value` is `Copyable`,
but there is a theoretical other protocol that this is relying on which is
`Clonable`. `Unique` itself can conform to `Clonable` by providing the explicit
`clone()` operation, but itself not being `Copyable`. If this method were
conditional on `Value: Clonable`, then you could call `clone()` on something
like `Unique<Unique<T>>`.

Rust has a hierarchy very similar to this:

```swift
public protocol Clonable {
  func clone() -> Self
}

public protocol Copyable: Clonable {}
```

where conforming to `Copyable` allows the compiler to implicitly add copies
where needed.

We are not suggesting that we make all `Copyable` types inherit from a
`Clonable` in the future, but simply demonstrating another language's approach
to how they handle explicit copyability and implicit copyability.

### Add an API to get the pointer of a `Unique`

Because `Unique` has stable address guarantees, API such as the following:

```swift
extension Unique where Value: ~Copyable {
  public func unsafeAddress() -> UnsafePointer<Value>

  public mutating func unsafeMutableAddress() -> UnsafeMutablePointer<Value>
}
```

could be entirely reasonable to have on `Unique`. This proposal chooses to leave
this as a future direction because a similar but distinct API `leak` could be
introduced with new language features:

```swift
extension Unique where Value: ~Copyable {
  public consuming func leak() -> Inout<Value>
}
```

where `Inout` is some hypothetical type that captures exclusive mutable access
to a value. `leak` wouldn't solve use cases that require pointers like calling C
APIs, but we feel it would be more appropriate to propose those API in addition
to `leak`.

### Implement something similar to Rust's `Deref` trait

While this proposal is suggesting `value` as the named property to access the
underlying value, there is a potential future direction that could help
eliminate the need for this entirely. `Unique` should simply be just a vehicle
with which you can manually manage where a value lives versus being this
cumbersome wrapper type you have to plumb through to access the inner value.

Consider uses of `std::unique_ptr`:

```cpp
class A {
public:
  void foo() const {
    std::println("Foo");
  }
};

int main() {
  auto a = std::make_unique<A>();

  a->foo();
}
```

All members of the boxed instance can be referenced through C++'s usual arrow
operator `->` behaving exactly like some `A*`. C++ is able to do this via their
operator overloading of `->`.

Taking a look at Rust too:

```rust
struct A {}

impl A {
  fn foo() {
    println!("foo");
  }
}

fn main() {
  let a = Box::new(A {});

  a.foo();
}
```

there's no ceremony at all and all members of `A` are immediately accessible
from the box itself.

Rust achieves this with a special `Deref` trait (or protocol in Swift terms).

This trait allows types to access members of another unrelated type if it's able
to produce a borrow (or a safe pointer) of said unrelated type. Here's what
`Deref` looks like in Rust:

```rust
pub trait Deref {
  type Target: ?Sized;

  fn deref(&self) -> &Self::Target;
}
```

It's a very simple protocol that defines an associated type `Target` (let's
ignore the `?Sized`) with a method requirement `deref` that must return a borrow
of `Target`.

This trait is known to the Rust compiler to achieve these special
semantics, but Swift could very well define a protocol very similar to this
today. While we don't have borrows, I don't believe this protocol definition in
Swift would require it either.

Without getting too into specifics, array like data structures in Rust also
conform to `Deref` with their `Target` being a type similar to `Span<Element>`.
This lets them put shared functionality all on `Span` while leaving data
structure specific behaviors on the data structure itself. E.g. `swap` is
implemented on `MutableSpan<Element>` and not `Array` in Swift terms. This is
being mentioned because if we wanted to do something similar for our array like
types, they wouldn't want to return a borrow of `Span`, but instead the span
directly. Rust does this because their span type is spelt `&[T]` while the `[T]`
is an unsized (hence the `?Sized` for `Target`), so returning a borrow of `[T]`
naturally leads them to returning `&[T]` (span) directly.

It could look something like the following in Swift for `Unique`:

```swift
public protocol Deref {
  associatedtype Target

  var value: Target { borrow }
}

extension Unique: Deref where Value: ~Copyable {
  var value: Target {
    borrow {
      ...
    }
  }
}
```

which could allow for call sites to look like the following:

```swift
var box = Unique<[3 of _]>([1, 2, 3])
box.swapAt(0, 2) // [3, 2, 1]
```
