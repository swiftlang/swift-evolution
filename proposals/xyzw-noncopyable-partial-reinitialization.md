# Partial reinitialization of noncopyable values

* Proposal: [SE-XYZW](xyzw-noncopyable-partial-reinitialization.md)
* Authors: [Joe Groff](https://github.com/jckarter)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: TBD
* Review: ([pitch](TBD))

## Introduction

This proposal introduces the ability to reinitialize noncopyable
values that have been partially consumed.

## Motivation

[SE-0429](0429-partial-consumption.md) introduced **partial consumption**
for noncopyable values. This gives programmers the ability to 
apply consuming operations individually to fields of a noncopyable struct, tuple, or
enum:

```swift
struct File: ~Copyable {
  consuming func close() { ... }
}

struct Buffer: ~Copyable { ... }

struct BufferedFile: ~Copyable {
  var file: File
  var buffer: Buffer

  consuming func takeBufferAndCloseFile() -> Buffer {
    // Consume the file by closing it:
    file.close()

    // And then consume the buffer by returning it to the caller:
    return buffer
  }
}
```

However, prior to this proposal, as soon as any part of an
aggregate is consumed, there is no way to make the value whole again, other
than to initialize an entirely new value:

```swift
extension BufferedFile {
  mutating func switchFile(to: consuming File) {
    // Consume the old file...
    file.close()

    // We'd like to do this, but it's an error today:
    /*ERROR*/ file = to

    // So we have to do something awkward like this instead:
    self = BufferedFile(file: to, buffer: self.buffer)
  }
}
```

This makes it awkward to perform operations that require replacing noncopyable
components of an aggregate.

## Proposed solution

We propose allowing **partial reinitialization**, giving mutable stored
properties of noncopyable aggregates the ability to be
reinitialized after they've been consumed. When a partially-consumed aggregate
has all of its consumed components reinitialized, the entire value becomes
valid again:

```swift
extension BufferedFile {
  mutating func switchFile(to: consuming File) {
    // Consume the old file...
    file.close()

    // This should become valid:
    file = to
    // Reinitializing `file` makes `self` whole again, allowing us to
    // safely return from this `mutating` method
  }
}
```

## Detailed design

### Maintaining API integrity

As with partial consumption, it is important that partial reinitialization
does not allow clients of an API to bypass invariants set up by the API
author. The author of a noncopyable type can define initializers to ensure
something occurs whenever a new value of the type is constructed,
implement a deinitializer and `consuming` methods to ensure something occurs
when those values' lifetimes end, and use `let` properties or private
setters to limit how the value's state can be changed by client code.
Types also expect to be able to add or remove stored properties from their
representation as long as they maintain their public API.
It is important that partial reinitialization does not give clients the
ability to bypass the API boundary or create new implicit library evolution
constraints. Partial consumption was already designed with API integrity in mind, and some
of the considerations for that proposal also need to apply to partial
reinitialization.

### Restrictions on non-`@frozen` public types

For code to be able to either partially consume or reinitialize a property,
the code in question needs to know that the properties being consumed and
reinitialized are stored properties,
so like partial consumption, partial reinitialization is limited to values
of types defined in the current module, or `public` types from other modules
which have been explicitly marked `@frozen`:

```swift
// Module A
public struct NC: ~Copyable {}
func consume(_: consuming NC)

@frozen
public struct Frozen: ~Copyable {
  public var a: NC, b: NC
}

public struct Nonfrozen: ~Copyable {
  public var a: NC, b: NC
}
```

```swift
// Module B
import A

struct SameModule: ~Copyable {
  var a: NC, b: NC
}

func test(f: inout Frozen, nf: inout Nonfrozen, sm: inout SameModule) {
  // OK, f is explicitly frozen
  consume(f.a)
  f.a = NC()

  // ERROR, nf is not frozen and is from a different module
  consume(nf.a)
  nf.a = NC()

  // OK, sm's type is defined in the same module as us
  consume(sm.a)
  sm.a = NC()
}
```

### Correspondence between partial reinitialization and assignment

Partial reinitialization should not allow for clients to bypass a type's
initializers and construct values in a state that the public API would otherwise
prevent. With no restrictions at all, partial consumption combined with
reinitialization would allow for a client to consume all of a struct's field
and then reinitialize them, effectively creating a new instance bypassing
any initializers or deinitializer provided by the type:

```swift
func replace(_ value: consuming Frozen) -> Frozen {
  // Consume all of the fields of the original value...
  consume(value.a)
  consume(value.b)

  // ...then replace them with new values
  value.a = NC()
  value.b = NC()

  // `value` has now been changed to have the same state as if we had
  // called `SameModule(a: NC(), b: NC())`, but without going through
  // any of SameModule's inits or deinit
  return value
}
```

However, given the nature of structs, it is already possible to completely replace
an instance if you are able to reassign each of its fields:

```swift
func replace(_ value: consuming Frozen) -> Frozen {
  // We can simply reassign each field in turn
  value.a = NC()
  value.b = NC()

  // `value` has now been changed to have the same state as if we had
  // called `SameModule(a: NC(), b: NC())`, but without going through
  // any of SameModule's inits or deinit
  return value
}
```

So, in the case of a simple struct like `Frozen` above, partial reinitialization
does not create new possibilities that mere assignment couldn't already achieve.
To prevent this sort of total replacement by reassignment, the author of a struct
can restrict what mutations client code can perform by using immutability
(with `let` properties) and access control (with private setters on properties):

```swift
// Module A

@frozen
public struct FrozenSemiImmutable: ~Copyable {
  public let var a: NC
  public private(set) var b: NC

  public init(a: NC, b: NC) {
    print("very important initialization behavior here")
    self.a = a
    self.b = b
  }
}
```

```swift
// Module B
import A

func attemptReplace(_ value: consuming FrozenSemiImmutable)
  -> FrozenSemiImmutable
{
  // We can't reassign either field, so we can't fully replace the value
  // without going through the initializer.
  value.a = NC() // ERROR: `a` is immutable
  value.b = NC() // ERROR: `b` has a private setter

  return value
}
```

One can think of a partial
consumption followed by reinitialization of the same field as being a
decomposed reassignment of that field, with the erasing of the old
value and moving of the new value separated into two stages. Therefore,
we restrict partial reinitialization of a property so that it is only
allowed in contexts that would allow ordinary assignment of that property:

```swift
func attemptReplace(_ value: consuming FrozenSemiImmutable)
  -> FrozenSemiImmutable
{
  consume(value.a)
  consume(value.b)
  
  // We can't reassign either field, so we aren't allowed to reinitialize
  // them either:
  value.a = NC() // ERROR: `let` property `a` cannot be reinitialized
  value.b = NC() // ERROR: `b` has a private setter so cannot be reinitialized

  return value
}
```

This ensures that partial reinitialization cannot violate API boundaries
and mutate values in ways that would not otherwise be allowed.

### Values cannot be elementwise initialized from nothing

The analogy to assignment only works when the code already has a complete
value to start with. It is not allowed to partially initialize a variable
that did not have a value to begin with:

```swift
do {
  var foo: Frozen

  foo.a = NC() // ERROR: cannot initialize a single property of an uninitialized value
}
```

Doing so would allow for the type's initializers to be bypassed in forming
a new value. Similarly, a value cannot be partially initialized after being
fully consumed:

```swift
do {
  var foo = Frozen(a: NC(), b: NC())
  consume(foo)

  foo.a = NC() // ERROR: cannot initialize a single property of an uninitialized value
}
```

A consuming operation on `foo` will potentially trigger its `deinit`, and will
at the very least transfer the responsibility of invoking the current value's
`deinit` to someone else, so allowing for partial reinitialization after
full value consumption would also allow for the formation of a new value with
independent ownership outside of the API's control.

### Partial consumption and reinitialization of types with `deinit`

Partial consumption has, prior to this proposal, been disallowed for types
with a user-defined `deinit`, since `deinit` requires a complete value to
tear down, and being able to consume a value by consuming each of its
individual properties would give client code the ability to destroy that
value while bypassing the `deinit`. However, since this proposal adds
the ability to reinitialize the properties of a partially-consumed value,
we can now allow for partial consumption of values with `deinit`s,
but only when the partially-consumed properties are reinitialized before
the end of the value's lifetime:

```swift
var instanceCount = 0

struct Counted: ~Copyable {
  var a = NC(), b = NC()
  
  init() { instanceCount += 1 }
  deinit { instanceCount -= 1 }
}

func test1(_ x: consuming Counted) {
  // OK, x is fully reinitialized before its lifetime ends
  consume(x.a)

  x.a = NC()
}

func test2(_ x: consuming Counted) {
  consume(x.a)
  
  // ERROR: x is not reinitialized before the end of its lifetime
}
```
 
## Source compatibility

This proposal introduces new capabilities for noncopyable types without
changing the behavior of any existing syntax, so is fully compatible with
existing Swift source.

## ABI compatibility

This functionality can be added to the compiler with no changes to the
Swift runtime or type layout, so this proposal has no impact on ABI.

## Implications on adoption

This proposal has been designed to improve the ergonomics of working
with noncopyable values without creating new API design concerns, so that
API authors do not need to be concerned about their clients adopting
this feature, nor do clients need anything from API authors to take
advantage of the feature.

## Future directions

### Noncopyable tuples

It would be reasonable to support noncopyable tuples. When we do,
it should be possible to partially consume and reinitialize them.
Since tuples are always a straightforward combination of their
elements, with no API abstraction or nontrivial initialization/deinitialization
behavior, it should be possible to consume and reinitialize their
elements without restriction.

### Explicit partial consumption and reinitialization of copyable properties

Reading copyable stored properties will typically copy the property's value.
It would make sense to allow the `consume` operator to apply to stored properties
of consumable bindings, which would allow for partial consumption and reinitialization
of copyable fields. Aside from the explicit `consume` operator, the behavior should
be the same for `Copyable` and non-`Copyable` types, including the ability to reinitialize
them after being consumed.

### Elementwise initialization from scratch for types with trivial memberwise initializers

This proposal bans partial initialization from scratch, since it would allow for
values to be formed without using the value's published initializers. However, many
structs have only simple memberwise initializers that do not meaningfully restrict
what values callers can form. We could provide a way in the future for these types
to opt in to allowing for partial initialization from scratch.

## Alternatives considered

### Do nothing

As noted in the detailed design, this proposal does not allow clients of
an API to do things they could not already do with noncopyable types. Developers
today can, with enough effort, use regular assignment, `inout` parameters, or
initialization of new values to express the same things as partial reassignment.
Nonetheless, it is often awkward or nonobvious to do so, and we think the
ergonomic improvement provided by this proposal is worth it.
