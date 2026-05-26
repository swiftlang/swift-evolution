# `Optional` noncopyable improvements and generalizations

* Proposal: [SE-0532](0532-optional-noncopyable-improvements.md)
* Author: [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Active review (May 26th...June 8th, 2026)**
* Implementation: [swiftlang/swift#88505](https://github.com/swiftlang/swift/pull/88505)
* Review: ([pitch](https://forums.swift.org/t/pitch-optional-noncopyable-improvements-and-generalizations/86656)) ([review](https://forums.swift.org/t/se-0532-optional-noncopyable-improvements-and-generalizations/86941))

## Summary of changes

Introduces three new methods on `Optional` to help support noncopyable wrapped
values: `borrow()`, `mutate()`, and `insert()`. Also generalizes `map`,
`flatMap`, and `unsafelyUnwrapped`.

## Motivation

Since Swift 6.0 where [we generalized parts of the standard library to support
storing noncopyable values](0437-noncopyable-stdlib-primitives.md), working with
noncopyable optionals has been quite cumbersome. It's very common to want to
inspect the contents within the optional, maybe pass it to a function that wants
to borrow the payload, but you don't want to consume the optional. Perhaps you
need to continue using the optional, or you simply don't have an owned optional
in the first place (you were passed `borrowing T?` for example). Consider the
following example trying to peek at the optional's contents:

```swift
if let payload = optional {
  
}

foo(optional) // error: use after consume!
```

This has been a constant pitfall with no clear workaround. Fortunately with
[noncopyable switches](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0432-noncopyable-switch.md),
we can make control flow borrow the optional's contents:

```swift
switch optional {
case .some(let wrapped):
  // wrapped is borrowed!

default:
  break
}

foo(optional) // ok
```

However, writing that switch is not very intuitive if you're used to `if let` or
even `guard let`.

If you wanted to mutate the optional's payload without consuming it, there's
only a handful of ways to achieve this. For simple property mutations or calling
mutating methods, the `?.` chaining is sufficient, but if you needed to
conditionally pass the payload to some function taking it `inout` you could
write:

```swift
if someStruct.x != nil {
  foo(&someStruct.x!)
}
```

Or the more verbose and unintuitive way by consuming the optional in a switch
and reinitializing it:

```swift
func foo(_: inout NoncopyableString) {}

func bar(_ x: inout NoncopyableString?) {
  switch consume x {
  case .some(var string):
    foo(&string)
    x = consume string

  default:
    x = nil
  }
}
```

------

Similarly, there are a number of API on `Optional` that are not available for
noncopyable wrapped values such as `map`, `flatMap` and `unsafelyUnwrapped`.

Missing out on `map` and `flatMap` has lead to many workarounds needing to
manually stamp out switch statements everywhere and rewriting code to work with
noncopyable wrapped values being more verbose than its predecessor.

## Proposed solution

We introduce two new methods on `Optional`: `borrow()` and `mutate()`. These will
return references to the inner wrapped payload if there is one and `nil`
otherwise.

```swift
func bar(_ x: borrowing SomeNoncopyable) {
  ...
}

if let payload = optional.borrow() {
  bar(payload.value) // 'bar' gets passed a 'borrowing Wrapped'
}

foo(optional) // ok
```

```swift
func baz(_ x: inout SomeNoncopyable) {
  ...
}

if var payload = optional.mutate() {
  baz(&payload.value) // 'baz' can mutate the payload in place!
}

foo(optional) // ok
```

These two methods provide an idiomatic way to conditionally access the
wrapped value of an optional without having ownership of the optional.

We also propose generalizing the following `Optional` methods to support
noncopyable and nonescapable wrapped types:

* `map`
* `flatMap`
* `unsafelyUnwrapped`

```swift
let optAtomicInt: Optional<Atomic<Int>> = ...
let optInt: Optional<Int> = optAtomicInt.map {
  $0.load(ordering: .relaxed)
}

let optInlineArray: Optional<[0 of Atomic<Int>]> = []
let optInt2: Optional<Int> = optInlineArray.flatMap {
  $0.isEmpty ? nil : $0[0].load(ordering: .relaxed)
}

let optMutex: Optional<Mutex<Int>> = ...
let mutex: Mutex<Int> = optMutex.unsafelyUnwrapped
optMutex?.withLock { ... } // error: use of 'optMutex' after consume
```

------

A quality of life API we're also proposing is `Optional.insert`. Consider the
following pattern:

```swift
struct Cache: ~Copyable {
  var opt: UniqueArray<Int>?
}

var cache = Cache()

// do some computation

var items: UniqueArray<Int> = fooBar()
cache.opt = items

// more calculations, maybe some
// API calls

let newItem = await retrieveNewItem()

cache.opt!.append(newItem)
```

The use of `!` here is really unnecessary because we already know there's a value
in the optional. In some cases, this `!` may not get optimized away if
you're calling into a non-inlined function taking `Cache` because it can't make
any assumptions about the values that exist in it. We can safely model an `insert`
method that returns a direct mutable reference to the payload of an optional
given a new item to put into the optional:

```swift
struct Cache: ~Copyable {
  var opt: UniqueArray<Int>?
}

var cache = Cache()

// do some computation

let items: UniqueArray<Int> = fooBar()
var itemsRef = cache.opt.insert(items)

// more calculations, maybe some
// API calls

let newItem = await retrieveNewItem()
itemsRef.value.append(newItem)
```

## Detailed design

### `borrow()` and `mutate()`

```swift
extension Optional where Wrapped: ~Copyable & ~Escapable {
  /// Returns a borrowed reference to the payload within the optional, if there
  /// is one.
  @lifetime(borrow self)
  public func borrow() -> Ref<Wrapped>?
}

extension Optional where Wrapped: ~Copyable {
  /// Returns the mutable reference to the payload within the optional, if there
  /// is one.
  @lifetime(&self)
  public mutating func mutate() -> MutableRef<Wrapped>?
}
```

Conceptually, these methods effectively move the ownership of the optional and
its payload. In order to call `borrow()`, for example, you must have at least
a `borrowing Optional<T>` which, if you squint hard enough, is `Ref<Optional<T>>`.
`borrow()` takes this `Ref<Optional<T>>` and produces `Optional<Ref<T>>` which
moved the reference inside the optional meaning we get back an owned value we
can mutate, consume, or simply have exclusive access to.

The same is true for `mutate()`. It takes at least `inout Optional<T>` to be able to
perform the call which can look like `MutableRef<Optional<T>>` into an owned
`Optional<MutableRef<T>>` value.

### `insert()`

```swift
extension Optional where Wrapped: ~Copyable {
  /// Sets the value of the optional to the passed in new value while returning
  /// a mutable reference to that value inside the optional.
  ///
  /// If there's already a value within the optional, that value is destroyed.
  ///
  /// - Parameter new: The new payload value to put into the optional.
  /// - Returns: A mutable reference inside the optional to its newly inserted
  ///   payload.
  @lifetime(&self)
  public mutating func insert(_ new: consuming Wrapped) -> MutableRef<Wrapped>
}
```

### `unsafelyUnwrapped` generalization

```swift
extension Optional where Wrapped: ~Copyable & ~Escapable {
  public var unsafelyUnwrapped: Wrapped {
    consuming get
  }
}
```

### `map()` and `flatMap()` generalizations

```swift
extension Optional where Wrapped: ~Copyable & ~Escapable {
  @lifetime(copy self)
  public consuming func map<Result: ~Copyable & ~Escapable, E: Error>(
    _ transform: (consuming Wrapped) throws(E) -> Result
  ) throws(E) -> Result?

  @lifetime(copy self)
  public consuming func flatMap<Result: ~Copyable & ~Escapable, E: Error>(
    _ transform: (consuming Wrapped) throws(E) -> Result?
  ) throws(E) -> Result?
}
```

We were hesitant to eagerly generalize these back in [SE-0437](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0437-noncopyable-stdlib-primitives.md#enum-optional)
because there are technically three forms of `map` and `flatMap` that can occur
with noncopyable wrapped values. One can choose to consume the optional entirely
being passed the owned value of the payload in the closure, borrow the optional
and get passed a borrowing reference to the payload, or mutate the optional
and get passed an `inout` reference to the payload. All three variants are useful,
but we don't currently have a way to distinguish between them
if we named them all `map` due to overloading rules/limitations. By making these
generalizations always consuming by default, `borrow()` and `mutate()` actually
help us achieve the other variations by giving us owned optionals values:

```swift
func foo(x: consuming Optional<UniqueArray<String>>) -> Optional<String> {
  x.map {
    $0[0]
  }
}

func bar(x: borrowing Optional<Atomic<Int>>) -> Optional<Int> {
  x.borrow().map { // ok!
    $0.value.load(ordering: .relaxed) &+ 1
  }
}

func baz(x: inout Optional<UniqueArray<Int>>) -> Optional<Int> {
  x.mutate().map {
    // Update the array while mapping over it
    $0.value.append(123)
    return $0.value.count
  }
}
```

## Source compatibility

`Optional.borrow()`, `Optional.mutate()`, and `Optional.insert()` are new
methods so they shouldn't introduce any source compatibility issues.

The proposed overloads of `map` and `flatMap` are less-specialized overloads of
the existing functions. Noting that any existing uses of `Optional.map` have a
`Copyable` wrapped value, all existing callers will resolve to the existing `map`
where `Wrapped: Copyable`, as it is a more specialized overload. The same applies
to `flatMap`. We therefore expect no source compatibility issues with these
generalized functions."


`unsafelyUnwrapped` is purely a generalization and cause no source compatibility
issues.

## ABI compatibility

The new methods on `Optional` are new API to the standard library that also don't
come with any ABI. The generalizations of `map`, `flatMap`, and `unsafelyUnwrapped`
don't come with any new ABI nor break any old ABI.

## Implications on adoption

The `Optional.borrow()`, `Optional.mutate()`, and `Optional.insert()`
methods will have the same availability as `Ref` and `MutableRef`. The rest of
the generalizatons will be marked as always available.

## Future directions

### Borrow and inout bindings

A potential future if we decide that borrow/inout bindings makes sense is to
augment the compiler to recognize `if borrow`/`if inout` patterns for optionals
to provide conditionally scoped access to the payload:

```swift
if borrow x = optional {
  
}

foo(optional) // ok
```

If we decided this was a better direction than the `borrow()` and `mutate()`
story, then we'd need to rethink how we want to generalize `map`, `flatMap`, and
`unsafelyUnwrapped` because they can no longer be always consuming. We can provide
`consumingMap`, `borrowingMap`, `mutatingMap`, etc. which is one solution, but
not a pleasant one because we would see this multiplication of API for `map`,
`flatMap`, etc.

### Generalize `Optional: Equatable` and `Optional: Hashable`

Now that [SE-0499](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0499-support-non-copyable-simple-protocols.md)
generalized protocols like `Equatable` and `Hashable` to support noncopyable
and nonescapable conformers, it seems obvious that we should just generalize
`Optional`'s conformances to support those suppressed wrapped types.

Unfortunately, we don't have a way to say that a particular conformance was
generalized at some availability. We need to prevent the scenario where accidentally
calling into the generic `==` or `hash(into:)` for `Optional` on an older ABI
stable OS copies the wrapped payload.

### Automatic dereferencing for `Ref` and `MutableRef`

In the proposed solution, the examples using `borrow()` and `mutate()` to do a
`map` needed to explicitly access the `.value` property on these reference
types. This isn't quite as ergonomic as the existing `map` on `Optional` that
let's you interact with the passed parameter as the type itself. We could give
`Ref` and `MutableRef` a special behavior in the future to automatically
dereference themselves when accessing member properties or methods on them:

```swift
func bar(x: borrowing Optional<Atomic<Int>>) -> Optional<Int> {
  x.borrow().map { // ok!
    // No more '.value.'
    $0.load(ordering: .relaxed) &+ 1
  }
}
```

Automatic dereferences like this greatly improve working with these types. If we
had this for `Ref`/`MutableRef`, we could extend this functionality generically
to other types through a protocol based solution like [`Deref`](https://doc.rust-lang.org/std/ops/trait.Deref.html)
which would be useful for `UniqueBox` as well.

## Alternatives considered

### Change the default ownership of Optional bindings

In the motivation for some of the methods of this proposal, it's stated that we
need methods like `borrow()` and `mutate()` to allow for borrowing versions of
control flow. We could instead change the default ownership of these `if let`
scenarios to be borrowing by default. However, this would be a source-breaking
change for code that expects optional binding to be consuming.

### `Optional.ref` and `Optional.mutableRef` properties

Instead of the `borrow()` and `mutate()` method names, we could have properties
that returned the same value like the various `.span` and `.mutableSpan`
properties.

However, we feel that the nature of the verbs `borrow` and `mutate` fit quite
well in API usage especially for things like `opt.borrow().map { ... }`. It also
mimics the recently accepted [Borrow Accessors SE-0507](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0507-borrow-accessors.md)
names.
