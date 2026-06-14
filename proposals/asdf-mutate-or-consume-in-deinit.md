# Mutation and consumption in non-`Copyable` type `deinit`s

* Proposal: [SE-ASDF](asdf-mutate-or-consume-in-deinit.md)
* Authors: [Joe Groff](https://github.com/jckarter)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [TBD](https://github.com/swiftlang/swift/pull/TBD)
* Review: ([pitch](TBD))

## Introduction

Non-`Copyable` types can define a `deinit` to clean up owned resources
at the end of their lifetime; however, `self` is restricted to be
immutable and borrowable only within the body of `deinit` up to this point.
We propose to allow `deinit` to mutate and/or consume `self` or its
parts.

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

Or a type may provide a `consuming` method for more configurable cleanup, and
express its `deinit` in terms of calling that method with standard parameters:

```swift
struct BufferedFile: ~Copyable {
  let file: File
  let buffer: Buffer
  
  consuming func close(flush: Bool) {
    if flush {
      buffer.flush(to: file)
    }
    buffer.release()
    file.close()

    discard self
  }

  deinit {
    // Flush the buffer by default
    close(flush: true)
  }
}
```

Along similar lines, `deinit` may want to use code factored into `mutating`
methods as part of the cleanup process.

## Proposed solution

We propose that `deinit`s should be allowed to mutate and consume `self`.
This includes either partial or entire mutation of the value.

## Detailed design

### "Resurrection" and accidental recursion hazards

`deinit` in a noncopyable type is unique among contexts that have
ownership of a value: any other owning context would implicitly destroy the value
by invoking `deinit`, whereas `deinit` itself of course cannot. `deinit` only
destroys the component stored properties or inhabited enum case of the value.

This creates a wrinkle when `deinit` is allowed to pass `self` to a
consuming or mutating operation. In the callee, the value is "resurrected", and
the callee will invoke `deinit` again if it ends the value's lifetime. This could
make it easy to accidentally induce an infinite loop:

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

Generally, a `consuming` method usable from a `deinit` would use
`discard self` to prevent the implicit call back into `deinit`:

```swift
struct Foo: ~Copyable {
  deinit {
    self.foo()
  }

  consuming func foo() {
    doCleanup()
    discard self
  }
}
```

On the other hand, aside from accidental recursion, resurrection of a noncopyable
value doesn't create fundamental semantic problems, and there are situations where
it would be useful for `deinit` to transfer ownership of the value.
For instance, if cleaning up a value is time-consuming, it may make sense to
enqueue a dying value to be cleaned up later rather than immediately during
`deinit`:

```swift
let deferredCleanupValues: ConcurrentQueue<DeferredCleanup>

struct DeferredCleanup: ~Copyable {
  deinit {
    // Instead of cleaning up the value immediately, push it into the queue
    // to be cleaned up later
    deferredCleanupValues.push(self)
  }

  consuming func runTimeConsumingCleanup() async { ... }
}

func runDeferredCleanups() async {
  while let value = deferredCleanupValues.pop() {
    await value.runTimeConsumingCleanup()
  }
}
```

Rather than foreclose on potentially useful expressivity in the hope of
making mistakes impossible, this proposal chooses not to impose any restrictions
on performing `mutating` or `consuming` operations from `deinit`. 

### Remaining restrictions

It is still not allowed to capture `self` in a closure during `deinit`.

### Cleanup of partially-consumed `self`

If any components of `self` have not been consumed at the point `deinit` returns,
those remaining components are implicitly destroyed. This includes running `deinit`
of any non-`Copyable` components.

## Source compatibility

This proposal changes the behavior of `self` so that it behaves like an owned
mutable binding (like a `consuming` function parameter), where it previously behaved
like an immutable `borrowing` parameter. This could affect overload resolution in
rare situations where an extension provides a `mutating` variation of a name that
was previously `borrowing`. We expect this sort of situation to be unlikely in
practice.

## ABI compatibility

This proposal has no impact on ABI.

## Implications on adoption

This feature can be freely adopted and un-adopted in source
code with no deployment constraints and without affecting source or ABI
compatibility.

## Alternatives considered

There are various restrictions we could impose on operations inside of
a non-`Copyable` `deinit` to prevent or reduce the likelihood of resurrection
or recursion into `deinit`:

### Only allow partial mutation and consumption

An easy way to prevent resurrection or `deinit` recursion would be to allow
mutation and consumption of the stored properties or cases of a value, but
not of the value as a whole. However, this would completely preclude the
ability to factor cleanup logic into utility methods, which is a major
motivation for allowing mutation or consumption in a `deinit` to begin with.

### Annotate "deinit-safe" methods

We could limit what operations a `deinit` is allowed to apply to a whole value
to methods that opt into being "deinit-safe" in some fashion. `consuming` methods so annotated
would be required to `discard self`, and `mutating` methods would be prevented
from fully reassigning `self`.

### Limit `deinit` to invoking locally-defined methods on `self`

Instead of an explicit annotation, we could limit `deinit` to only be able to
mutate or consume `self` via methods defined in the original type definition
alongside `deinit`, or within the same module. This would make it possible for
file- or module-local analysis to detect places where methods invoked from
`deinit` potentially call back into `deinit`.

## Acknowledgments

Kavon Favardin originally noted the potential problems of resurrection and
accidental recursion if `deinit` was allowed to arbitrarily mutate or consume
`self`.
