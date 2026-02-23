# `discard self` for types with non-`BitwiseCopyable` members

* Proposal: [SE-AOEU](aoeu-discard-nontrivial-self.md)
* Authors: [Joe Groff](https://github.com/jckarter)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [TBD](TBD)
* Review: ([pitch (TBD)](TBD))

## Introduction

This proposal extends the `discard self` special form to allow for its
use in all non-`Copyable` types with user-defined `deinit`s.

## Motivation

When [SE-0390] introduced non-`Copyable` types, we gave
these types the ability to declare a `deinit` that runs at the end of
their lifetime, as well as the ability for `consuming` methods to
use `discard self` to clean up a value without invoking
the standard `deinit` logic:

```swift
struct Phial {
  var phialDescriptor: Int = 0
  
  deinit {
    print("automatically closed") }
  }

  consuming func close() {
    print("manually closed")

    discard self
  }
}

do {
  let p1 = Phial()
  // only prints "automatically closed"
}

do {
  let p2 = Phial()
  p2.close()
  // only prints "manually closed"
}
```

At the time, we restricted `discard self` to only support types whose
members are all `BitwiseCopyable` in order to limit the scope of the
initial proposal. However, `discard self` is also useful for types
with non-`BitwiseCopyable` members.

## Proposed solution

We propose allowing `discard self` to be used inside of `consuming`
methods which are defined inside of the original type declaration of
any non-`Copyable` type with a `deinit`. `discard self` immediately
ends the lifetime of `self`, destroying any components of `self` that
have not yet been consumed at the point of `discard self`'s execution.

## Detailed design

### Remaining restrictions on `discard self`

This proposal preserves the other restrictions on the use of `discard self`:

- `discard self` can only appear in methods on a non-`Copyable` type that has
  a `deinit`.
- `discard self` can only be used in `consuming` methods declared in that type's
  original definition (not in any extensions).
- If `discard self` is used on any code path within a method, then every code
  path must either use `discard self` or explicitly destroy the value normally
  using `_ = consume self`.

As noted in SE-0390, these restrictions ensure that `discard self` cannot be
used to violate an API author's control over a type's cleanup behavior, and
reduce the likelihood of oversights where implicit exits out of a method
unintentionally implicitly invoke the default `deinit` again, so we think
they should remain in place.

### Partial consumption and `discard self`

A type with a `deinit` cannot typically be left in a partially consumed state.
However, partial consumption of `self` is allowed when the remainder of `self`
is `discard`-ed. At the point `discard self` executes, any remaining parts of
`self` which have not yet been consumed immediately get destroyed. This allows
for a `consuming` method to process and transfer ownership of some components
of `self` while leaving the rest to be cleaned up normally.

```swift
struct NC: ~Copyable {}

struct FooBar: ~Copyable {
  var foo: NC, bar: NC

  deinit { ... }

  consuming func takeFooOrBar(_ which: Bool) -> NC {
    var taken: NC
    if which {
      taken = self.foo
      discard self // destroys self.bar
    } else {
      taken = self.bar
      discard self // destroys self.foo
    }

    return taken
  }
}
```

## Source compatibility

This proposal generalizes `discard self` without changing its behavior in
places where it was already allowed, so should be fully compatible with
existing code.

## ABI compatibility

This proposal has no effect on ABI.

## Implications on adoption

This proposal should make it easier to use noncopyable types as a resource
management tool by composing them from existing noncopyable types, since
`consuming` methods on the aggregate will now be able to release ownership
of the noncopyable components in a controlled way.

## Alternatives considered

### `discard` only disables `deinit` but doesn't immediately

An alternative design of `discard` is possible, in which `discard self`
by itself only disables the implicit `deinit`, but otherwise leaves the
properties of `self` intact, allowing them to be used or consumed
individually after the `deinit` has been disabled. This could allow for
more compact code in branch-heavy cleanup code, where different branches
want to use different parts of the value. For example, the `FooBar.takeFooOrBar`
example from above could be written more compactly under this model:

```swift
struct FooBar: ~Copyable {
  var foo: NC, bar: NC

  deinit { ... }

  consuming func takeFooOrBar(_ which: Bool) -> NC {
    discard self // disable self's deinit

    // Since self now has no deinit, but its fields are still initialized,
    // we can ad-hoc return them below:
    if which {
      return self.foo    
    } else {
      return self.bar
    }
  }
}
```

However, we believe that it is more intuitive for discard to immediately end the life of self, even if this leads to more verbosity. Being able to place discard self at the beginning of a method and forgetting about it could also make code harder to read and make it easy to forget that the default deinit has been disabled when tracing through it.

### `discard` recursively leaks properties without cleaning them up

In Rust, `mem::forget` completely forgets a value, bypassing not only the
value's own `drop()` implementation (the equivalent of our `deinit`) but
also the cleanup of any of its component fields. We could in theory
define `discard` the same way, having it discard the value without even
cleaning up its remaining properties. However, this would make it very
easy to accidentally leak memory.

Recursively leaking fields also creates a backdoor for breaking
the ordering of `deinit` cleanups with lifetime dependencies, which the
original `discard self` design. Despite the prohibition on using
`discard self` outside of a type's original definition, someone could
wrap the type in their own type and use `discard self` to leak the value:

```swift
struct Foo: ~Copyable {
  deinit { ... }
}

struct Bar: ~Copyable {
  var foo: Foo

  consuming func leakFoo() {
    // If this discarded `self.foo` without running its deinit,
    // it would be as if we'd externally added a method to
    // `Foo` that discards self
    discard self
  }
}
```

Particularly with `~Escapable` types, many safe interfaces rely on having
a guarantee that the `deinit` for a lifetime-dependent type ends inside of
the access in order to maintain their integrity. Having this capability
could be necessary in some situations, but it should not be the default
behavior, and if we add it in the future, it should be an unsafe operation.

## Acknowledgments

Kavon Favardin wrote the initial implementation of `discard self`, and helped
inform the design direction taken by this proposal.
