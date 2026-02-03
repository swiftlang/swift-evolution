# `Borrow` and `Inout` types for safe, first-class references

* Proposal: [SE-AOEU](AOEU-borrow-inout-types.md)
* Authors: [Joe Groff](https://github.com/jckarter), [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: TBD
* Status: **Awaiting implementation**
<!-- * Implementation: [swiftlang/swift#NNNNN](https://github.com/swiftlang/swift/pull/NNNNN) or [swiftlang/swift-evolution-staging#NNNNN](https://github.com/swiftlang/swift-evolution-staging/pull/NNNNN)
* Upcoming Feature Flag: *if applicable* `MyFeatureName`
* Previous Revision: *if applicable* [1](https://github.com/swiftlang/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Review: ([pitch](https://forums.swift.org/...)) -->

## Summary of changes

Two new standard library types, `Borrow` and `Inout`, represent safe
references to another value, with shared (immutable) or
exclusive (mutable) access respectively.

## Motivation

Swift can provide temporary access to a value as part of a function call:

- An `inout` parameter receives temporary exclusive access to a value from
  by the caller. The callee can modify the parameter, and even consume its
  current value (so long as it gets replaced with a new value), and the caller
  reclaims ownership once the callee returns.
- A `borrowing` parameter receives temporary shared access to a value from
  the caller. Since there may be other ongoing accesses to the same value, the
  callee can generally only read the value, but it can do so without needing
  an independent copy of the value.

However, it is useful to be able to form these sorts of references outside of
the confines of a function call, as local variable bindings, as members of
other types, in generic containers, and so on. Developers can use classes
to box values and pass references to a common holder object around, but in
doing so they introduce allocation, reference counting, and dynamic exclusivity
checking overhead. `UnsafePointer` is, of course, unsafe, and interacts
awkwardly with Swift's high-level semantics, requiring extreme care to use
properly.

## Proposed solution

We introduce two new generic types to the standard library to represent
references as first-class, non-`Escapable` types. `Borrow`
represents a shared borrow of another value, which can be used to read the
target value but not consume or modify its contents:

```swift
public struct Borrow<Value: ~Copyable>: Copyable & ~Escapable {
  @_lifetime(borrow target)
  public init(_ target: borrowing Value)

  public var value: Value { borrow }
}
```

`Inout<T>` represents an exclusive access to another value, granting the
owner of the `Inout` the ability to modify the target value and assume
exclusive use of the target value for as long as the `Inout` value is active:

```swift
public struct Inout<Value: ~Copyable>: ~Copyable & ~Escapable {
  @_lifetime(&target)
  public init(_ target: inout Value)

  public var value: Value { borrow; mutate }
}
```

Note that these types' interfaces use [lifetime dependencies](https://github.com/swiftlang/swift-evolution/pull/2750) to be able to
construct `~Escapable` values, and also use [`borrow` and `mutate` accessors](https://forums.swift.org/t/se-0507-borrow-and-mutate-accessors/84376) to
provide efficient access to the target value without unnecessary limitations on the scope
of the access.

References are formed by passing the target to one of the `Borrow.init` or
`Inout.init` initializers. Once formed, the target value can be accessed
through the reference's `value` property. Using these types, developers can
bind a local reference to a nested value once for repeated operations:

```swift
func updateTotal(in dictionary: inout [String: Int], for key: String,
                 with values: [Int]) {
  // Project a key out of a dictionary once...
  var entry = Inout(&dictionary[key, default: 0])

  // ...and then repeatedly modify it, without repeatedly looking into the
  // hash table
  for value in values {
    entry.value += value
  }
}
```

Using the experimental lifetimes feature, developers can write functions that
return references:

```swift
struct Vec3 {
  var x, y, z: Double

  @_lifetime(&self)
  mutating func at(index: Int) -> Inout<Double> {
    switch index {
    case 0: return Inout(&x)
    case 1: return Inout(&y)
    case 2: return Inout(&z)
    default:
      fatalError("out of bounds")
    }
  }
}
```

`Borrow` and `Inout` can also appear as fields of other non-`Escapable` types:

```swift
// A struct-of-arrays of people records.
struct People {
  var names: [String]
  var ages: [Int]

  subscript(i: Int) -> Person {
    @_lifetime(&self)
    mutating get {
      return Person(name: &names[i], age: &ages[i])
    }
  }
}

// A mutable reference to a single person.
struct Person: ~Copyable, ~Escapable {
  var name: Inout<String>
  var age: Inout<Int>
}
```

`Borrow` and `Inout` furthermore allow for references to be used as generic
parameters, allowing containers and wrappers which support non-`Escapable` types
to contain references:

```
@_lifetime(&array)
func element(of array: inout [Int], at: Int) -> Inout<Int>? {
  if at >= 0 && at < array.count {
    return &array[at]
  } else {
    return nil
  }
}
```
 
## Detailed design

### Lifetime dependence

Both `Borrow` and `Inout` are non-`Escapable` types. Once formed, they carry
a lifetime dependency on their target, so can be used only as long as the
target value can remain borrowed (in the case of `Borrow`) or exclusively
accessed (in the case of `Inout`). Conversely, the target undergoes a borrow
or exclusive access for the duration of the reference's lifetime, so the
target may only undergo other borrowing accesses while a dependent `Borrow`
is in use, and cannot be used directly at all while a dependent `Inout` has
exclusive access to it.

```swift
var totals = [17, 38]

do {
  let apples = Borrow(totals[0])

  print(apples.value) // prints 17

  apples.value += 2 // ERROR, Borrow.value is read only

  totals[1] += 1 // ERROR, cannot mutate `totals` while borrowed

  print(totals[1]) // prints 38. we can still borrow `totals` again
  print(apples.value) // prints 17
}

do {
  var bananas = Inout(&totals[1])

  bananas.value += 2 // we can mutate the value through `Inout`

  print(bananas.value) // prints 40

  print(totals[1]) // ERROR, totals is exclusively accessed by `bananas`

  bananas.value += 2
  print(bananas.value) // prints 42
}

print(totals) // prints [17, 42]
```

This behavior is analogous to the interaction between an `Array` and dependent
`Span` or `MutableSpan` values accessed through its `span` and `mutableSpan`
properties. (Indeed, one could look at `Borrow` and `Inout` as being the
single-value analogs to the multiple-value-referencing `Span` and `MutableSpan`,
respectively.)

### Interaction with nontrivial accesses

A `Borrow` can target any value, and `Inout` can target any mutable location,
including properties or subscripted values produced as the result of `get`/`set`
pairs, yielded by `yielding` coroutine accessors, guarded by dynamic exclusivity
checks, or observed by `didSet`/`willSet` accessors. In these situations,
the access will first be initiated to form the target value (invoking the
getter, starting the `yielding borrow` or `yielding mutate` coroutine, etc.).
The `Borrow` or `Inout` reference will then be formed targeting that value.
When the reference's lifetime ends, the access will be ended (invoking the
setter, resuming the `yielding` coroutine, invoking `willSet` and/or `didSet`
observers).

```swift
struct NoisyCounter {
  private var _value: Int

  var value: Int {
    get {
      print("counted \(_value)")
      return _value
    }
    set {
      print("updating counter to \(newValue)")
      _value = newValue
    }
  }
}

var counter = NoisyCounter(67)
do {
  var counterRef = Inout(&counter.value) // begins access to `counter.value`, prints "counted 67"
  counterRef.value += 1
  counterRef.value += 1
  // access to `counter.value` ends, prints "updating counter to 69"
}
```

Note that `Borrow` and `Inout` are *dependent on* the access; they only
reference the target value and do not capture any context in order to end the
access themselves. Therefore, a `Borrow` or `Inout` derived from a nontrivial
access generally cannot have its lifetime extended beyond its immediate caller,
since the caller must execute the code to end the access at the end of the
reference's lifetime.

```swift
@_lifetime(&target)
func noisyCounterRef(from target: inout NoisyCounter) -> Inout<Int> {
  // ERROR, would extend the lifetime of `Inout` outside of the formal access
  return Inout(&target.value)
}
```

Direct accesses to `struct` stored properties, direct accesses to immutable
`class` stored properties, or accesses that go through `borrow` or `mutate`
accessors do not require any code execution at the end of the access, so
`Borrow` and `Inout` values targeting those are only limited by the parent
access from which the property or subscript was projected.

### Representation of `Borrow`

Reading the following section is not necessary to use `Borrow`, but is
of interest to understand its type layout and implementation.

Depending on the properties of the `Value` type
parameter, `Borrow<Value>` may either be represented as a pointer to the
target value in memory, or as a bitwise copy of the target value's representation.
The pointer representation is used if `Value` meets any of the following
criteria:

- `MemoryLayout<Value>.size` is greater than `4 * MemoryLayout<Int>.size`; or
- `Value` is not *bitwise-borrowable*; or
- `Value` is *addressable-for-dependencies*.

The size threshold aligns with the Swift calling convention's threshold for
passing and returning values in registers, to avoid wasteful
bitwise-copying of very large values while ensuring that `Borrow`s can be passed
and returned across function boundaries without being dependent on temporary
stack allocations.

The emphasized terms are defined below:

#### Bitwise borrowability

An `Int` value has the same meaning no matter where it appears in
memory, so even if one is passed as a `borrowing` parameter, Swift will avoid
indirection and pass an `Int` by value at the machine calling convention level.
Similarly, an object reference's pointer value is equivalent anywhere in memory,
so even though the act of copying a strong reference requires increasing the object's
reference count, the underlying pointer can be passed by value. We refer to these
types as **bitwise-borrowable**, since a borrow can be passed across functions
by bitwise copy.

As such, immutable values of *bitwise-borrowable* type do not have a stable address.
However, with the introduction of `Borrow` values, it ought to be possible to
define functions that, given a borrow of a value, returns a `Borrow` (or,
more usefully, a type containing a `Borrow`) with the same lifetime as that
borrow:

```swift
@_lifetime(borrow target)
func refer<T>(to target: T) -> Borrow<T> {
  // This ought to be allowed
  Borrow(target)
}
```

If `Borrow` always used a pointer-to-target representation, then forming a
`Borrow` targeting a bitwise-borrowable value would require storing that value
in memory, possibly in a temporary stack allocation. A temporary stack
allocation would mean that functions would be unable to receive a borrowed
parameter, form a `Borrow` of it, and return that value, since the `Borrow`
would depend on the function's own stack frame:

```swift
@_lifetime(borrow target)
func refer(to target: AnyObject) -> Borrow<AnyObject> {
  // This ought to be allowed, so `target` can't be spilled to a local
  // temporary allocation
  Borrow(target)
}
```

Therefore, a `Borrow` of a small *bitwise-borrowable* type takes on the representation
of the value itself, unless the type is also *addressable-for-dependencies*
(described below).

#### Addressability for dependencies

Some types are bitwise-borrowable, but also provide interfaces that produce
lifetime-dependent values such as `Span`s that need to have pointers into
their in-memory representation. `InlineArray` is one such example; it is
bitwise-borrowable when its element type is, but its `span` property produces
a `Span` with a pointer to the array's elements, which is expected to have a
lifetime constrained by borrowing the `InlineArray`:

```swift
@_lifetime(borrow array)
func span(over array: [2 of Int8]) -> Span<Int8> {
  // This ought to be allowed
  return array.span
}
```

Swift classifies `InlineArray`, as well as any type containing an `InlineArray`
within its inline storage, as **addressable-for-dependencies**. Values of
such types are always passed indirectly as a parameter to a function call
whose return value has a lifetime dependency on that parameter. In the example
above, this ensures that in the call to `span(over:)`, the `array` parameter 
exists in memory that outlives the call, allowing the `Span` to be safely
formed and returned to the caller.

`Borrow` should not interfere with the lifetime of dependent values projected
from the target through the `Borrow`, so when the `Value` type is
*addressable-for-dependencies*, `Borrow` uses the pointer representation.

```swift
@_lifetime(copy borrow)
func span(over borrow: Borrow<[2 of Int8]>) -> Span<Int8> {
  // This also ought to be allowed
  return borrow.target.span
}
```

Since the calling convention rules pass *addressable-for-dependencies*
types by pointer when there is a returned dependency, and any `Borrow` value
returned would be a dependency, `Borrow` using the pointer representation does
not interfere with forming and returning a `Borrow` from a borrowed parameter:

```swift
@_lifetime(borrow target)
func refer(to target: [2 of Int8]) -> Borrow<[2 of Int8]> {
  // This ought to be allowed. `target` is received by pointer, so
  // `Borrow<[2 of Int8]>` using the pointer representation can point to the
  // caller's memory.
  Borrow(target)
}
```

`struct`, `union`, and `class` types imported from C, Objective-C, and C++ are
always considered to be *addressable-for-dependencies*. This is intended to make
it easier for `Borrow` types to interact with data types in those languages
that use pointers and/or C++ references to represent relationships between values.

### Representation of `Inout`

`inout` parameters are always passed by address at the machine calling convention
level, so `Inout` can use a pointer representation in all cases without limiting
its ability to be passed across function call boundaries.

## Source compatibility

This proposal adds two new top-level declarations to the standard library,
`Borrow` and `Inout`. According to GitHub code search, existing code
that declares a [`struct Borrow`](https://github.com/search?q=%22struct+Borrow%22+language%3ASwift&type=code&ref=advsearch)
or [`struct Inout`](https://github.com/search?q=%22struct+Inout%22+language%3ASwift&type=code&ref=advsearch) is rare, though not nonexistent. Swift's name lookup
rules favor locally-defined and explicitly-imported names over standard
library names, so existing code should continue to compile and behave as
it used to.

## ABI compatibility

This proposal is additive and does not affect the ABI of existing code.

## Implications on adoption

Generic support for `Borrow` requires new runtime type layout functionality,
which may limit the availability of these types when targeting older Swift
runtimes.

## Future directions

### `~Escapable` target types

As proposed here, `Borrow` and `Inout` both require their target type to
be `Escapable`. There are implementation limitations in the compiler that
prevent implementing references to non-`Escapable` types. With the limitations
of the current lifetime system, the non-`Escapable` `value` projected from
a `Borrow` or `Inout` would also be artificially lifetime-constrained to the
lifetime of the reference, since the current model lacks the ability to track
multiple lifetimes per value.

### A borrowing reference type that is always represented as a pointer

As discussed in the "Representation of `Borrow`" section, `Borrow<Value>`
will use a value representation for some `Value` types, rather than a pointer.
This should be transparent to most native Swift code, but in some situations,
particularly when doing manual data layout or interoperating with other
languages, it may be interesting to have a variant that is always represented
as a pointer. That type would sometimes be forced to have a shorter maximum
lifetime than `Borrow` can provide if the target needs to have a temporary
memory location formed to point to.

### Generalized single-yield coroutines

As discussed in the "Interaction with nontrivial accesses" section, when a
`Borrow` or `Inout` targets a value that is referenced through a nontrivial
access (such as a `get`/`set` pair, a `yielding` coroutine accessor, a stored
property with dynamic exclusivity checking, etc.), the reference's lifetime is
confined to the caller that initiated the access, since that same caller must
end the access after the reference's lifetime ends. However, if we allowed
arbitrary functions and methods to be defined as single-yield coroutines, not
only accessors, that could provide a way to define functions that compute
references depending on nontrivial accesses:

```swift
yielding func noisyCounterRef(from target: inout NoisyCounter) -> Inout<Int> {
  // this would be OK, since we're yielding `Inout` to the caller without
  // ending the current execution context
  yield Inout(&target.value)
}
```

### Access-capturing reference types

Another possible tool for handling references into nontrivial accesses might
be to introduce a "fat reference" that can capture the suspended execution
contexts of any accesses to be passed along with the value reference itself.
Such a type would naturally use more space and incur more execution overhead
to use, but may be useful in some circumstances.

### Primitive reference bindings in more places

Using `Borrow` and `Inout`, developers can form reference bindings anywhere
a variable or property can be declared, reaching beyond the limited places in
the language that references can be formed. However, as distinct types with their
own interface, these types introduce indirection overhead in forming and
dereferencing the references separate from the target values. It may still be
valuable to introduce primitive reference binding syntax to the language (which
could be viewed as sugar over forming an explicit `Borrow` or `Inout`):

```swift
// Explicitly-formed reference
let x = Borrow(y)
x.value.foo()

// Reference binding sugar
borrow x = y
x.foo()
```

### Implicit dereferencing or member forwarding

Along similar lines, we might consider giving `Borrow` or `Inout` dynamic
member lookup capabilities, or introducing something like Rust's `Deref` trait
to automatically forward name lookups from `Borrow` or `Inout` to the target
`value`. This would somewhat reduce the syntactic overhead of working with
these types, though any such mechanism will be imperfect, since `Borrow` and
`Inout`'s own members will shadow any forwarding mechanism.

### `exclusive` ownership or reborrowing for `Inout.value`

`Inout` shares an ergonomic problem with `MutableSpan`: for safety, mutation
of the target `value` through `Inout` requires exclusive access to the `Inout` value.
In Swift today, this exclusive access can only be exercised through mutable
bindings, which will force `Inout` values to be assigned to `var` bindings even
if the `Inout` value itself is never mutated, and prevent expressions returning
`Inout` values from being used directly in mutation expressions:

```swift
var source = #"print("Hello World")"#

let ref = Inout(&source)
// ERROR, mutating `value` requires mutable access to `ref`
ref.value += #"; print("Goodbye Universe")"#

func getRef(from: inout String) -> Inout<String> { return Inout(&from) }

// ERROR, mutating `value` requires mutable access to temporary value
getRef(from: &source).value += #"; print("...except for that guy")"#
```

Any of the remedies we are considering for `MutableSpan` are also applicable
to `Inout`:

- A new `exclusive` ownership mode, which is applicable to values that
  are exclusively owned either because they offer mutable access or because they
  are owned immutable values, would allow for temporary and immutable `Inout`
  values to be projected safely.
- Alternatively, a mechanism similar to Rust's "reborrowing" mechanism, whereby
  mutable references are consumed by projection operations but can be re-formed
  after those dependent projections are completed, could also be made to work
  with `Inout` values and derived projections.

## Alternatives considered

### Naming the `Inout` type

Our usual naming conventions might argue that the proper spelling of the
`inout`-capturing reference type would be `InOut`, capitalizing both words.
The authors subjectively find this odd-looking, and hard to type, and see
`inout` in its specialized usage as a keyword as more akin to a single word than a true
compound of its components.

There has been talk in the past of possibly superseding `inout` with the
`mutating` keyword, to bring it in line with the `mutating` modifier on
methods and fit it into the `borrowing`/`consuming` naming scheme for the
other parameter ownership modifiers. That might suggest `Mutable` or something
along those lines as the name of the reference type.

### Naming the `value` property

We propose giving `Borrow` and `Inout` a property named `value` to
access the target value. This aligns with the interface of the [proposed `Unique` type](https://forums.swift.org/t/pitch-box/84014). Some other possibilities we
considered include:

- using a `subscript` with no parameters, so that `reference[]` dereferences
  the value
- using a more reference-specific name such as `target`
- introducing a dedicated dereference operator akin to C's `*x`
