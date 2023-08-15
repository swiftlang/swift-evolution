# Non-`Copyable` `Optional` types

* Proposal: [SE-ABCD](ABCD-noncopyable-optional.md)
* Authors: [Joe Groff](https://github.com/jckarter/)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: https://github.com/apple/swift/pull/67695
* Upcoming Feature Flag: `NonCopyableOptional`

## Introduction

This proposal adds support for using the `Optional` type and its
basic operations to wrap noncopyable types.

## Motivation

`Optional` is a fundamental type used to represent potentially-missing values,
a need that extends to noncopyable types. Because `Optional` is a generic type,
and noncopyable types are not currently allowed to be used as generic arguments,
this is not currently supported, leaving noncopyable types susceptible to
suboptimal design choices such as using sentinel values or type-specific
optional-like types to represent unavailable cases. For noncopyable
values, Swift furthermore imposes the constraint that values can't be used
after being consumed, but sometimes it is necessary to consume a value in
situations where it cannot be statically proven safe to do so, such as when the
value is owned by an actor, object, or global variable.  `Optional` serves a role
in the analogous situation with initialization, where a `nil` value can be
used to stand in for a value that will be initialized later in cases where
Swift's static initialization requirements can't express, and `Optional` could
also enable dynamic consumption, allowing a `nil` value to stand in for
a value after it's been consumed.

A complete design for noncopyable generics ought to include the
ability to retrofit existing currency types from the standard library to support
their use with noncopyable types, such as `Optional`, `Array`, and so
on, and also allow external libraries to extend their existing APIs to support
noncopyable types. However, we think `Optional` is important enough to support
ahead of fully general noncopyable generics.  `Optional` also has a lot of
special support built into the language, and we need to design and specify how
those features interact with noncopyable types irrespective of the general
noncopyable generics design. Even after noncopyable generics are implemented,
it is likely that proposals specific to other standard library types will follow
describing how those types should support noncopyable type arguments.

## Proposed solution

We propose to extend the `Optional` type to support being parameterized by
a noncopyable type, making the `Optional` type itself noncopyable. Noncopyable
types can be used with all of the builtin operations for unwrapping and
manipulating `Optional`s, including `x!`, `x?`, `if let`, `if case`,
and `switch`. Additionally, we introduce a `take()` method on `Optional`,
which can be used to mutate an `Optional` value to `nil` while giving up
ownership of the value previously inside of it.

## Detailed design

### `Optional` of noncopyable type

`Optional` is allowed to wrap a noncopyable type. The resulting `Optional<T>`
type is itself also noncopyable when this occurs. Noncopyable `Optional`
types may be inferred, or spelled explicitly using any of the sugar syntaxes
provided for `Optional`, including implicitly-unwrapped `Optional`s.

```
struct File: ~Copyable { ... }

let maybeFile: File? = ...
let maybeFile2: File! = ...
let maybeFile3: Optional<File> = ...
let maybeFile4: Optional = File(...) // type parameter `File` inferred from context
```

Noncopyable `Optional` types are subject to the same constraints as other
noncopyable types. A parameter of noncopyable `Optional` type must explicitly
specify whether it uses a `borrowing`, `consuming`, or `inout` ownership
convention:

```
func maybeClose(_ file: File?) // error: no ownership specifier
func maybeClose(_ file: consuming File?) // OK
```

Generics still require copyability, so a noncopyable `Optional`
type does not conform to any protocols, cannot be stored in an existential, and
cannot be passed to functions or methods generic over `Optional`:

```
let any: Any = maybeFile // error: maybeFile isn't copyable

func foo<T>(_ optional: Optional<T>) {}
foo(maybeFile) // error: can't substitute noncopyable type File for T

protocol P {}
extension Optional: P {}

func bar<T: P>(_ p: P)
bar(maybeFile) // error: noncopyable type 'File?' does not conform to P
```

Unconstrained extensions to `Optional` are implicitly generic over the
`Wrapped` type parameter, and therefore are also unavailable on noncopyable
types:

```
extension Optional {
    func bas() {}
}

maybeFile.bas() // error: can't substitute noncopyable type File for Wrapped
```

Extensions constrained to a specific noncopyable type are however allowed and
can be used on values of the matching type:

```
extension Optional<File> {
    consuming func maybeClose() { self?.close() }
}

maybeFile.maybeClose() // OK
```

### Operations on noncopyable `Optional`

The language-builtin operations for `Optional` work with noncopyable values.
Both the force-unwrap operator `x!` and chaining operator `x?` can be any of
borrowing, mutating, or consuming, yielding access to the unwrapped value in
the following postfix expression:

```
struct File: ~Copyable {
    borrowing func write()
    mutating func redirect(to: borrowing File)
    consuming func close()
}

let f1: File? = File(...)
f1?.write() // OK to borrow
f1?.write() // OK to borrow again
f1?.redirect(to: File(...)) // error, mutation of read-only value

var f2: File? = File(...)
f2?.write() // OK to borrow
f2?.redirect(to: f1!) // OK to mutate
f2?.close() // OK to consume
f2?.write() // error, use after consume
```

The implicit unwrapping of an implicitly-unwrapped Optional is similarly
borrowing, mutating, or consuming, depending on how the unwrapped value is used.

```
let f3: File! = File(...)
f3.write() // OK to borrow
f3.close() // OK to consume after
f3.write() // error, use after consume
```

`if let`, `if case`, and `switch` can be used with noncopyable `Optional` values. These are
currently consuming operations, and as when other noncopyable types are
pattern matched, they must be explicitly `consume`-d when doing so for now:

```
let f1: File? = File(...)

if let f = consume f1 { // consumes f1 to bind f
    f.close() // OK to consume f
}

f1?.close() // error, use after consume
```

When borrowing binding and pattern matching forms are implemented, they will
be supported for `Optional` as well.

Noncopyable `Optional` values may be constructed containing a value using
implicit conversion from the wrapped type, the `.some` enum
case, and/or the `Optional(x)` initializer. These all consume the value, moving
it inside of the `Optional` wrapper. Empty `Optional` values may be constructed
using the `nil` literal or `.none`.

### The `take()` method

One important use case for noncopyable optionals is to dynamically move or
consume values from an owner for which consumption cannot be statically proven
safe. If an object or actor owns a noncopyable value, for example, it must own
a valid value for the object's entire lifetime. It is
normally not possible to consume values owned by objects:

```
class FileOwner {
    var file: File


    // We would like to be able to give up ownership of the file, but
    // that would leave the object in an invalid state.
    func giveUpFile() -> File {
        return file // error: can't move `file` to return it
    }
}
```

We can mutate the `file` in place, leaving another valid file behind
after moving the old file out, but that requires having a dummy file or
sentinel value:

```
extension File {
    mutating func replaceWithDummy() {
        // We can consume the current `self` in a mutating method...
        let result = consume self
        // ...but we need to leave a new value behind before we return back
        self = File("/dev/null")
        return result
    }
}

class FileOwner {
    var file: File


    func giveUpFile() -> File {
        return file.replaceWithDummy()
    }
}
```

If we wrap the value in `Optional`, then we can use `nil` to safely represent
the absence of a value after it's been moved away. If we had support for
noncopyable generics, then we could write this as a mutating method on
`Optional`:

```
extension Optional where Wrapped: ~Copyable {
    mutating func take() -> Wrapped? {
        let result = consume self
        self = nil
        return result
    }
}

class FileOwner {
    var file: File?

    func giveUpFile() -> File {
        // Now we can use take() to dynamically take the file away from
        // the object, leaving nil behind (or raising a fatal error if
        // someone else already did)
        return file.take()!
    }
}
```

We propose to support the `take()` method generically
on noncopyable types as a special case, which will be subsumed by a normal
method once noncopyable generics are fully supported, since it is otherwise
difficult to express using the builtin operations on `Optional` that are
supported.

## Source compatibility

This proposal ought to be purely additive, not affecting the behavior of
existing code. This proposal is also intended to be forward-compatible with
a future version of Swift that does support noncopyable generics in the general
case.  We do not expect the semantics of noncopyable `Optional` operations to
differ from those that we would implement given fully general noncopyable
generics support. Also, although this proposal leaves methods generic over
`Optional<T>` and unconstrained extensions on `Optional` as requiring
copyability, it is almost certain that we would need to do for source
compatibility even with noncopyable generics support, since existing generic
implementations and extensions can assume that their arguments are copyable.
Therefore, we expect that generic functions accepting noncopyable Optional
types will require some sort of opt-in syntax, such as `extension Optional
where Wrapped: ~Copyable`, and therefore the lack of generics support in this
proposal is not a future source compatibility concern.

## ABI compatibility

`Optional` wraps noncopyable types using the same layout mechanisms as it does
for copyable types, and nongeneric noncopyable types do not require runtime
support, so there are no ABI compatibility or back deployment concerns with
enabling support for noncopyable `Optional` for concrete noncopyable types.

## Implications on adoption

There should be no backward compatibility or deployment limitations adopting
noncopyable `Optional` types.

## Alternatives considered

### Should `take` return a non-`Optional`?

Since the primary intended purpose of `take` is to allow for dynamic consumption
of a value, one could argue that it should return the unwrapped value as a
non-`Optional`, and raise a fatal error if no value is available to take:

```
extension Optional where Wrapped: ~Copyable {
    mutating func take() -> Wrapped {
        let result = consume self!
        self = nil
        return result
    }
}
```

Our proposal favors returning the `Optional` value as is, because we feel that
is the more compositional approach. The caller may call `take()` and
choose whether force-unwrapping, throwing an error, falling back to a default
value, or choosing some other arbitrary execution path is appropriate.

### What should `take` be named?

`take()` could be named something tying it more closely to other noncopyable
type concepts, such as `move()` or `consume()`. However, we want to make sure
that there is a clear distinction between what `x.take()` does, which
is to *dynamically* reset `x` to `nil`, from what `consume x` does, which is to
*statically* end the lifetime of `x`. We hope that using a distinct term like
`take` makes this difference easier to understand and discuss. The name
`take` is also [used in Rust for the same operation](https://doc.rust-lang.org/std/option/enum.Option.html#method.take).

### Providing fully generic `swap` and/or `replace` operations

`Optional.take` can be looked at as a special case of the more general need
to replace a noncopyable value with a new value access while taking ownership
of the old value. The standard library already contains a global function
`swap<T>(_: inout T, _: inout T)` that can be used for this purpose; if it
were generalized to allow for noncopyable types, then the same effect as
`Optional.take()` could be had with:

```
var oldValue = nil
swap(&someObject.optional, &oldValue) // swap in nil, swap out the old value
```

A variation where the replacement value is passed in by value and the old value
is returned, which Rust calls `replace`, might be more fluent in many cases:

```
let oldValue = replace(&someObject.optional, with: nil)
```

Both or either of these APIs could be added and allowed for noncopyable types
in addition or instead of the `take` method specific to `Optional`.

## Future directions

### Noncopyable generics

General support for noncopyable generics would subsume the special case
behavior for `Optional` and the `take()` method, and enable us to make more
of `Optional`'s library interface available for noncopyable types.

### Borrowing pattern matching

We plan to add support for borrowing forms of `if let` unwrapping and pattern
matching, which would be directly applicable to `Optional`.
