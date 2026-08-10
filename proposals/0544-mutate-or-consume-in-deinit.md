# Mutation and consumption in non-`Copyable` type `deinit`s

* Proposal: [SE-0544](0544-mutate-or-consume-in-deinit.md)
* Author: [Joe Groff](https://github.com/jckarter)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Active Review (August 10th...24th, 2026)**
* Implementation: [swiftlang/swift#90836](https://github.com/swiftlang/swift/pull/90836)
* Review: ([first pitch](https://forums.swift.org/t/mutation-and-consumption-in-non-copyable-type-deinit-s/82390)) ([second pitch](https://forums.swift.org/t/pitch-2-allowing-for-partial-mutation-and-consumption-inside-of-non-copyable-type-deinit/88437)) ([review](https://forums.swift.org/t/se-0544-mutation-and-consumption-in-non-copyable-type-deinits/88903))

## Introduction

Non-`Copyable` types can define a `deinit` to clean up owned resources
at the end of their lifetime; however, prior to this proposal, `self` was
restricted to be immutable and borrowable only within the body of `deinit` up to
this point. We propose to allow `deinit` to mutate and/or consume the fields
of `self`, but still prevent the mutation or consumption of `self` as an entire
value in order to avoid problems with value resurrection.

## Motivation

Many non-copyable type implementations are composed of other noncopyable
values which own resources. It is natural to want to control how those
components get consumed during the aggregate's cleanup:

```swift
struct File: ~Copyable {
  consuming func close() {...}
}

struct Buffer: ~Copyable {
  borrowing func flush(to file: borrowing File) {...}
  consuming func release() {...}
}

struct BufferedFile: ~Copyable {
  let file: File
  let buffer: Buffer
  
  deinit {
    // Flush then close the buffer
    buffer.flush(to: file)
    buffer.release()
    // Then close the file
    file.close()
  }
}
```

Along similar lines, `deinit` may want to use code factored into `mutating`
methods as part of the cleanup process.

## Proposed solution

We propose that `deinit`s should be allowed to mutate and consume the 
fields of `self`.

## Detailed design

### Avoiding "resurrection" and accidental recursion hazards

`deinit` in a noncopyable type is unique among contexts that have
ownership of a value: any other owning context would implicitly destroy the
value by invoking `deinit`, whereas `deinit` itself of course cannot. `deinit`
only destroys the component stored properties or inhabited enum case of the
value.

If `deinit` were allowed to pass `self` to a consuming or
mutating operation, then the value would be "resurrected" in the callee, since
the callee will invoke `deinit` again at the end of the value's lifetime. This
would make it easy to accidentally induce an infinite loop:

```swift
struct Foo: ~Copyable {
  deinit {
    self.foo()
  }

  consuming func foo() {
    // oops, implicitly calls back into `deinit`
  }
}

struct Bar: ~Copyable {
  deinit {
    self.bar()
  }

  mutating func bar() {
    // oops, implicitly calls `deinit` on the old value of `self`
    // before reassigning it
    self = Bar()
  }
}
```

This proposal disallows the mutation or consumption of `self` as an entire
value in order to avoid these problems. We believe that in most cases this
is an acceptable limitation. However, one consequence of the limitation is
that `deinit` cannot call out to `mutating` or `consuming` methods on the
same type. `deinit` can however still share logic with other methods via
`static` methods that operate on the fields, for instance:

```swift
struct Resource: ~Copyable {
  var resourceID: Int
  
  // Shared logic for releasing the underlying resource by ID.
  // The release operation may surface error conditions, but these can be
  // ignored in normal use.
  private static func release(resourceID: Int) throws {...}
  
  // Consuming method that releases the resource, surfacing errors to be
  // handled
  consuming func release() throws {
    try Self.release(resourceID: self.resourceID)
    discard self
  }
  
  // Deinit that implicitly closes the resource, swallowing errors
  deinit {
    do {
      try Self.release(resourceID: self.resourceID)
    } catch {
      // Ignore the error
    }
  }
}
```

There may also be situations where it would be useful for `deinit` to transfer
ownership of an entire value. For instance, if cleaning up a value is
time-consuming, it may make sense to enqueue a dying value to be cleaned up
later rather than immediately during `deinit`. Since `deinit` is always defined
inside of a type's original declaration, it always has access to the layout of
the `struct` and its memberwise initializer, so the value can be explicitly
resurrected by passing the fields of `self` to the memberwise initializer:

```swift
let deferredCleanupValues: ConcurrentQueue<DeferredCleanup>

struct DeferredCleanup: ~Copyable {
  var resource1: Resource1
  var resource2: Resource2

  deinit {
    // Instead of cleaning up this value's resources immediately, push an
    // equivalent value into the queue to be cleaned up later
    let newSelf = Self(resource1: self.resource1, resource2: self.resource2)
    deferredCleanupValues.push(newSelf)
  }

  consuming func runTimeConsumingCleanup() async { ... }
}

func runDeferredCleanups() async {
  while let value = deferredCleanupValues.pop() {
    await value.runTimeConsumingCleanup()
  }
}
```

### Other restrictions

It is still not allowed to capture `self` in a closure during `deinit`.

### Cleanup of partially-consumed `self`

If any components of `self` have not been consumed at the point `deinit`
returns, those remaining components are implicitly destroyed. This includes
running `deinit` of any non-`Copyable` components.

## Source compatibility

This proposal changes the behavior of `self` so that it behaves like an owned
mutable binding (like a `consuming` function parameter), where it previously
behaved like an immutable `borrowing` parameter. This could affect overload
resolution in rare situations where an extension provides a `mutating` variation
of a name that was previously `borrowing`. We expect this sort of situation to
be unlikely in practice.

## ABI compatibility

This proposal has no impact on ABI.

## Implications on adoption

This feature can be freely adopted and un-adopted in source
code with no deployment constraints and without affecting source or ABI
compatibility.

## Alternatives considered

If the restriction on mutating or consuming `self` as an entire value proves
to be too onerous in practice, we are open to exploring lifting that restriction. There are various ways we might still mitigate the resurrection
hazard:

### Introduce a `resurrect self` operation

`deinit`s in this proposal can manually resurrect `self` by
memberwise-initializing a new value from its fields, but this is verbose.
If it becomes a common occurrence, we could introduce a shorthand syntax for it.
This could be seen as the opposite of `discard self`, which disables `self`'s
implicit `deinit` and disallows further use of `self` as an entire value, since
it would effectively re-enable `self`'s implicit `deinit` and allow it to be
treated as a whole value again.

### Annotate "deinit-safe" methods

We could limit what operations a `deinit` is allowed to apply to a whole value
to methods that opt into being "deinit-safe" in some fashion. `consuming`
methods so annotated would be required to `discard self`, and `mutating` methods
with the annotation would be prevented from fully reassigning `self`.

### Limit `deinit` to invoking locally-defined methods on `self`

Instead of an explicit annotation, we could limit `deinit` to only be able to
mutate or consume `self` via methods defined in the original type definition
alongside `deinit`, or within the same module. This would make it possible for
file- or module-local analysis to detect places where methods invoked from
`deinit` potentially call back into `deinit`.

### Require explicit consumption or discarding of `self` after mutation

In the first pitch thread, [ellie20 noted](https://forums.swift.org/t/mutation-and-consumption-in-non-copyable-type-deinit-s/82390/2)
that "a value, after it's mutated, is in some sense a different value,"
and made the argument that, after a mutating use of
`self` as a whole value, we should require the subsequent value to be
explicitly `discard`-ed or `consume`-d, since the value at that point
is no longer the original value being `deinit`-ed:

```swift
struct A: ~Copyable {
  deinit {
    self.replace()
    // explicitly indicate that the replaced `self` is discarded, rather than
    // deinit-ed
    discard self
  }

  mutating func replace() { ... }
}

struct B: ~Copyable {
  deinit {
    self.replace()
    // explicitly indicate that the replaced `self` is consumed, causing deinit
    // to run again on the new value
    _ = consume self
  }

  mutating func replace() { ... }
}
```

## Acknowledgments

Kavon Favardin originally noted the potential problems of resurrection and
accidental recursion if `deinit` was allowed to arbitrarily mutate or consume
`self`.
