# Modify and read accessors

* Proposal: [SE-NNNN](NNNN-modify-and-read-accessors.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift), [Nate Chandler](https://github.com/nate-chandler)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: Partially available on main behind the frontend flag `-enable-experimental-feature CoroutineAccessors`
* Pitch: https://forums.swift.org/t/pitch-modify-and-read-accessors/75627
* Previous Pitch: https://forums.swift.org/t/modify-accessors/31872

## Introduction

We propose the introduction of two new keywords--`modify` and `read`--for implementing computed properties and subscripts, alongside the current `get` and `set`.

The body of a `modify` or `read` implementation will be a coroutine, and it will introduce a new contextual keyword, `yield`, that will be used to lend a potentially mutable value back to the caller as the coroutine runs.
When the caller resumes the coroutine, its execution will continue from after that `yield`.

These coroutine accessors enable values to be accessed and changed without requiring a copy.
This is essential for noncopyable types and generally desirable elsewhere for performance.

This feature has been available (but not supported) since Swift 5.0 via the `_modify` and `_read` keywords.
Additionally, the feature is available via `read` and `modify` on recent main with the flag `-enable-experimental-feature CoroutineAccessors`.

## Motivation

### Modify<a name="modify-motivation"/>

Swift's `get`/`set` syntax allows users to expose computed properties and subscripts that behave as l-values.
This powerful feature allows for the creation of succinct idiomatic APIs, such as this use of `Dictionary`'s defaulting subscript:

```swift
var wordFrequencies: [String:Int] = [:]
wordFrequencies["swift", default: 0] += 1
// wordFrequencies == ["swift":1]
```

While this provides the illusion of "in-place" mutation, this is actually implemented as three separate operations:
1. a `get` of a copy of the value
2. the mutation on that returned value
3. finally, a `set` replacing the original value with the mutated copy.

This can be seen by performing side-effects within the getter and setter as in this sample code:

```swift
struct GetSet {
  var x: String =  "👋🏽 Hello"

  var property: String {
    get { print("Getting",x); return x }
    set { print("Setting",newValue); x = newValue }
  }
}

var getSet = GetSet()
getSet.property.append(", 🌍!")
// prints:
// Getting 👋🏽 Hello
// Setting 👋🏽 Hello, 🌍!
```

When the value being mutated is noncopyable, however, this is invalid:
the very first step makes a copy!

For example, `get` and `set` can't be used to wrap access to a noncopyable value:

```swift
struct UniqueString : ~Copyable {...}

struct UniqueGetSet : ~Copyable {
  var x: UniqueString

  var property: UniqueString {
    get { // error: 'self' is borrowed and cannot be consumed
        x
    }
    set { x = newValue }
  }
}
```

The problem is that `get` borrows `self` and _gives_ `x` to its caller.
We need [an accessor](#design-modify) that borrows `self` and _lends_ `x` mutably to its caller.

#### Performance

When the property or subscript is of copyable type, this simulation of in-place mutation does work well for user ergonomics.
It has a major performance shortcoming, however.

This can be seen in even our simple `GetSet` type above.
Strings in Swift aren't bitwise-copyable types.
Once they grow beyond a small fixed size, they allocate a reference-counted buffer to hold their contents.
Mutation is handled via the usual copy-on-write technique:
When you make a copy of a string, only the reference to the buffer is copied, not the buffer itself.
Then, when either copy of the string is mutated, it checks if the buffer is uniquely referenced.
If it isn't (because the string has been copied), it first duplicates the buffer before mutating it, preserving the value semantics of `String` while avoiding unnecessary eager copies.

Given this, we can see the performance problem when appending to `GetSet.property` in our example above:

- `GetSet.property { get }` is called, and returns a copy of `x`.
- Because a copy is returned, the buffer backing the string is no longer uniquely referenced.
- The append operation must therefore duplicate the buffer before mutating it.
- `GetSet.property { set }` writes this copy back over the top of `x`, destroying the original string.
- The original buffer's reference count drops to zero, and it's destroyed too.

So, despite looking like in-place mutation, every mutating operation on `x` made through `property` is actually causing a full copy of `x`'s backing buffer.
This is a linear operation.
If we were doing something like appending to this property in a loop, this loop would end up being quadratic in complexity.
This is likely very surprising to the developer and is frequently a major performance pitfall.

As in the noncopyable case, [an accessor](#design-modify) which only _lends_ the value to the caller is needed to avoid copying.

### Read<a name="read-motivation"/>

For properties and subscripts of noncopyable type, the current official accessors aren't merely insufficient for mutating,
they're insufficient even for _inspecting_.

Even without the `set` from our simple `UniqueGetSet` type above, we still hit the same error.

```swift
struct UniqueString : ~Copyable {...}

struct UniqueGet : ~Copyable {
  var x: UniqueString

  var property: UniqueString {
    get { // error: 'self' is borrowed and cannot be consumed
        return x
    }
  }
}
```

The problem is that `UniqueGet.property { get }` borrows the receiver and, executing like a normal function, transfers ownership of its result to the caller.

This particular error could be addressed by marking the getter `consuming`:

```swift
struct UniqueString : ~Copyable {...}

struct UniqueConsumingGet : ~Copyable {
  var x: UniqueString

  var property: UniqueString {
    consuming get {
        return x
    }
  }
}
```

Now the getter takes ownership of the `UniqueConsumingGet`.
That enables it to destructively extract `x` and transfer ownership of it to the caller.
Here's how that looks in the caller:

```swift
let container = UniqueConsumingGet()
let x = container.property // consumes container!
// container is no longer valid
```

While for some things, this is desirable, for many typical uses of properties and subscripts, it is not.
For example, if the container holds a number of noncopyable fields, it should be possible to inspect each in turn.
Doing so wouldn't be possible if inspecting any one of them consumed the container.

Similar to the mutating case, what's needed here is [an accessor](#design-read) which _borrows_ `self` and which _lends_ `x`--this time immutably--to the caller.

## Proposed solution

We propose two new accessor kinds:
- `modify`, to enable mutating a value without first copying it
- `read`, to enable inspecting a value without copying it.

## Detailed design

### Read<a name="design-read"/>

[`UniqueGet`](#read-motivation) could allow its clients to inspect its field non-destructively with `read`:

```swift
struct UniqueString : ~Copyable {...}

struct UniqueRead : ~Copyable {
  var x: UniqueString

  var property: UniqueString {
    read {
        yield x
    }
  }
}
```

The `UniqueRead.property { read }` accessor is a "yield-once coroutine".
When it is called, it borrows `self`.
It runs until reaching a `yield` at which point it suspends, lending the yielded value back to the caller.
Once the caller is finished with the value, it resumes the accessor.
The accessor continues running where it left off, just after the `yield` where it suspended.

If a `read` is provided, a `get` cannot also be provided.

### Read as a protocol requirement

Such accessors should be usable on values of generic and existential type.
To indicate that a protocol provides immutable access to a property or subscript via a `read` coroutine,
we propose allowing `read` to appear where `get` does today:

```swift
protocol Containing {
  var property: UniqueString { read }
}
```

If `read` is specified, `get` cannot also be specified.

A `read` requirement can be witnessed by a stored property, a `read` accessor, a getter, or an unsafe addressor.

### Get of noncopyable type as a protocol requirement

Note that it is not so easy to satisfy a `get` requirement whose type is noncopyable:

```swift
protocol Producing {
  var property: UniqueString { get }
}
```

To fulfill such a requirement, the conforming type must provide a getter.
Specifically, the requirement cannot be witnessed by a stored property, a `read` accessor, or an unsafe addressor[^2].

[^2]: While the compiler does currently accept such code currently, it does so by interpreting that `get` as a `read`, which is a bug.

The reason is that a getter produces an owned value while only borrowing `self`.
Producing an owned value from a `read` accessor, or an unsafe addressor would require copying its result.
Producing an owned value from a stored property would require copying the value or consuming `self`.

If the type of the `get` requirement is copyable, however, the compiler can synthesize the getter from the other accessor kinds by introducing a copy.

### Modify<a name="design-modify"/>

The `GetSet` type [above](#modify-motivation) could be implemented with `modify` as follows:

```swift
struct GetModify {
  var x: String =  "👋🏽 Hello"

  var property: String {
    get { print("Getting", x); return x }
    modify {
      print("Yielding", x)
      yield &x
      print("Post yield", x)
    }
  }
}

var getModify = GetModify()
getModify.property.append(", 🌍!")
// prints:
// Yielding 👋🏽 Hello
// Post yield 👋🏽 Hello, 🌍!
```

Like `UniqueRead.property { read }` above, `GetModify.property { modify }` is a yield-once coroutine.
Unlike it, however, the modify accessor lends `x` to the caller _mutably_.

Things to note about this example:
* the `get` is never called — the property access is handled entirely by the `modify` call
* the `yield` is similar to a `return`, but control returns to the `modify` after the `append` completes
* there is no more `newValue` – the yielded value is modified by `append`
* because it's granting _mutable_ access to the caller, the `yield` uses the `&` sigil, similar to passing an argument `inout`

Unlike the `get`/`set` pair, the `modify` accessor is able to safely provide access to the yielded value without copying it.
This can be done safely because the accessor owns the value until it has completely finished running:
When it yields the value, it only lends it to the caller.
The caller is borrowing the value yielded by the coroutine.

The `get` is still used in the case of only fetching, not modifying, the property:

```swift
_ = getModify.property
// prints:
// Getting 👋🏽 Hello, 🌍!
```

A modify is sufficient to allow assignment to a property:

```
getModify.property = "Hi, 🌍, 'sup?"
// prints:
// Yielding 👋🏽 Hello, 🌍!
// Post yield Hi, 🌍, 'sup?
```

It is, however, also possible to supply _both_ a `modify` and a `set`.
The `set` will be called in the case of bare assignment, which may be more efficient than first fetching/creating a value to then be overwritten:

```swift
struct GetSetModify {
  var x: String =  "👋🏽 Hello"

  var property: String {
    get { x }
    modify { yield &x }
    set { print("Setting",newValue); x = newValue }
  }
}
var getSetModify = GetSetModify()
getSetModify.property = "Hi 🌍, 'sup?"
// prints:
// Setting Hi 🌍, 'sup?
```

### Pre- and post-processing in modify

As with `set`, `modify` gives the property or subscript author an opportunity to perform some post-processing on the new value.

Consider the following implementation of an enhanced version of `Array.first` that allows the user to modify the first value of the array:

```swift
extension Array {
  var first: Element? {
    get { isEmpty ? nil : self[0] }
    modify {
      var tmp: Optional<Element>
      if isEmpty {
        tmp = nil
        yield &tmp
        if let newValue = tmp {
          self.append(newValue)
        }
      } else {
        tmp = self[0]
        yield &tmp
        if let newValue = tmp {
          self[0] = newValue
        } else {
          self.removeFirst()
        }
      }
    }
  }
}
```

This implementation takes the same approach as `Swift.Dictionary`'s key-based subscript.

If the entry was not there, it adds it.
If `nil` is assigned, it removes it.
Otherwise, it mutates it.

Because the fetch and update code are all contained in one block, the `isEmpty` check is not duplicated (unlike with a `get`/`set` pair).
Instead, whether the array was empty or not is part of the accessor's state which is still present when the accessor is resumed.

Notice that there are _two_ yields in this `modify` implementation, for the empty and non-empty branches.
Exactly one can be executed on any path through the accessor.

In general, the rules for yields in yield-once coroutines are similar to those of deferred initialization of `let` variables:
it must be possible for the compiler to guarantee there is exactly one yield on every path.
In other words, there must not be a path through the yield-once coroutine's body with either zero[^1] or more than one yield.
This is the case in this example, as there is a yield in both the `if` and the `else`.
More complex cases where the compiler cannot guarantee this will need refactoring, or use of `fatalError()` to assert code paths to be unreachable.

[^1]: Note that it is legal for a path without any yields to terminate in a `fatalError`.  Such a path is not _through_ the function.

### Yielding and exclusive access

The optional return value of `first` in the code above means that, even with a `modify`, we have introduced the problem of triggering copy-on-write when mutating via our `first` property.
We cannot yield the value in the array's buffer directly because it needs to be placed inside an optional.
That act of placing the value inside the optional (i.e. `tmp = self[0]`) creates a copy.

We can work around this with some lower-level unsafe code.
If the implementation of `Array.first` has access to its underlying buffer, it can move that value directly into the optional, yield it, and then move it back:

```swift
extension Array {
  var first: Element? {
    modify {
      var tmp: Optional<Element>
      if isEmpty {
        // Unchanged
      } else {
        // Illustrative code only, Array's real internals are fiddlier.
        // _storage is an UnsafeMutablePointer<Element> to the Array's storage.

        // Move first element in _storage into a temporary, leaving that slot
        // in the storage buffer as uninintialized memory.
        tmp = _storage.move()

        // Yield that moved value to the caller
        yield &tmp

        // Once the caller returns, restore the array to a valid state
        if let newValue = tmp {
          // Re-initialize the storage slot with the modified value
           _storage.initialize(to: newValue)
        } else {
          // Element removed. Slide other elements down on top of the
          // uninitialized first slot:
          _storage.moveInitialize(from: _storage + 1, count: self.count - 1)
          self.count -= 1
      }
    }
  }
}
```

While the `modify` coroutine is suspended after yielding, the array is in an invalid state: the memory location where the first element is stored is left uninitialized, and must not be accessed.
This is safe thanks to Swift's rules preventing conflicting access to memory.
For the full duration of the coroutine, the call to `modify` has exclusive access to the array.
Unlike a `get`, the `modify` is guaranteed to have an opportunity to put the element back (or to remove the invalid memory if the entry is set to `nil`) after the caller resumes it, restoring the array to a valid state in all circumstances before any other code can access it.

### Throwing callers<a name="throwing-callers"/>

The `Array.first { modify }` implementation above is correct even if the caller throws while the coroutine is suspended.

```swift
try? myArray.first?.throwingMutatingOp()
```

Thanks to Swift's rules ensuring `inout` arguments are initialized at function exit, the element must be a valid value when `throwingMutatingOp` throws.
When `throwingMutatingOp` does throw, control returns back to the caller.
The body of `Array.first { modify }` is resumed, and `tmp` is a valid value.
Then the code after the `yield` executes.
This results in the coroutine cleaning up as usual, writing the updated temporary value in `tmp` back into the storage buffer.

## Source compatibility

The following code is legal today:

```swift
func read<T>(_ c : () -> T) -> T { c() }
var reader : Int {
  read {
    fatalError()
  }
}
```

Currently, the code declares a property `reader` with an implicit getter.
The implicit getter has an implicit return.
The expression implicitly returned is a call to the function `read` with a trailing closure.

An analogous situation exists for `modify`.

We are proposing an alternate interpretation for this code:
that it declare a property `reader` with a `read` accessor.

To do so without breaking source compatibility, the feature may have to be gated on a language version.

## ABI compatibility

Adding a new modify accessor to an existing subscript or computed property has the same ABI implications as adding a getter, setter or function. It must be guarded by availability on ABI-stable platforms.

Renaming the current `_modify` (as used by the standard library, e.g.) to `modify` is an ABI additive change: a new `modify` symbol will be added.
When the compiler sees a `modify` with an early enough availability, the compiler will synthesize a corresponding `_modify` whose body will just call `modify`.
This is required for ABI stability: code compiled against an older standard library which calls `_modify` will continue to do so.
Meanwhile, code compiled against a newer standard library will call the new `modify`.
The same applies to renaming `_read` to `read`.

## Implications on adoption

The new ABI will require runtime support which would need to be back deployed in order to be used on older deployment targets.

## Future directions

### Yield-once functions

Further ergonomic enhancements to the language may be needed over time to make the most of this feature.
For example, coroutine accessors do not compose well with functions because functions cannot themselves currently yield values.
In the future, it may be desirable to enable functions to yield once:

```swift
var value: C { modify { ... } }
func updateValue(...) yields_once inout C {
  yield &self.value
  additionalWork(value)
}
```

### Permitting both forward consuming and borrowing accesses

When a property or subscript has a `consuming get`, a caller can take ownership of the field at the expense of destroying the object.
When a property or subscript has a `read` accessor, a caller can borrow the field to inspect it at the expense of not taking ownership of it.

As proposed here, it's not possible for a single field to provide both of these behaviors to different callers.
Since both of these behaviors have their uses, it may be desirable in the future to allow a single field to provide both:

```swift
subscript(index: Int) -> Value {
  consuming get {...}
  read {...}
}
```

### Permitting producing both owned and borrowed values

When an API comes into existence, its authors may not want to commit to it producing an owned value:

```swift
subscript(index: Int) -> Value {
  read {...}
}
```

As the module matures, however, it may become clear that such a commitment is worthwhile.
In this proposal, having both `read` and `get` is banned.
To support this use-case, in the future, it may be desirable to permit promoting `read` to `get`:

```swift
subscript(index: Int) -> Value {
  @available(*, deprecated)
  read {...}
  get {...}
}
```

That would enable the module to evolve to a greater commitment while preserving ABI.
It could make sense to require that the `read` be deprecated or have earlier availability than `get`.

### Borrowing a field

A `read` accessor lends to its caller the value it yields.
The caller only borrows that value until it resumes the coroutine.
After the `read` is resumed, it has the opportunity to clean up.
This enables a `read` to do interesting work like construct aggregates from its base object's fields:

```swift
struct Pair<Left : ~Copyable, Right : ~Copyable> : ~Copyable {
  var left: Left
  var right: Right

  var reversed: Pair<Right, Left> {
    mutating read {
      let result = Pair<Right, Left>(left: right, right: left)
      yield result
      self = .init(left: result.right, right: result.left)
    }
  }
}
```

That the borrow ends when the coroutine is resumed means that the lifetime of the lent value is strictly shorter than that of the base value.
In the example above, the lifetime of `reversed` is shorter than that of the `Pair` it is called on.

When a value is merely being projected from the base object, this is undesirably limiting:
a value projected from a base naturally has _the same_ lifetime as the base.

This is especially problematic in the context of composition.
Consider the following wrapper type[^3]:

[^3]: This example involves writing out a `read` accessor.  The same issue exists when the compiler synthesizes a `read` accessor for a stored property exported from a resilient module.

```swift
struct Wrapper<Stuffing : ~Copyable & ~Escapable> : ~Copyable & ~Escapable {
  var _stuffing: Stuffing

  var stuffing: Stuffing {
    read {
      yield _stuffing
    }
  }
}
```

When the instance of `Wrapper` is local to a function, the strict nesting of lifetimes may not be a problem:

```swift
{
  let wrapper: Wrapper<Stuffing> = ...
  borrowStuffing(wrapper.stuffing)
  // lifetime of wrapper.stuffing ends (at coroutine resumption)
  // lifetime of wrapper ends
}
```

When `Wrapper` is not local to a function such as when it's a parameter, the `read` accessor becomes limiting:

```swift
@lifetime(borrow wrapper)
func getStuffing<Stuffing : ~Copyable & ~Escapable>(from wrapper: borrowing Wrapper<Stuffing>) -> Stuffing {
  return wrapper.stuffing // error
}
```

The issue is that the lifetime of `stuffing` ends _within_ `getStuffing`, when the `read` coroutine is resumed.
That fact prevents `stuffing` from being returned.
Considering that the lifetime of `stuffing` is naturally the same as that of `wrapper`, this limitation is artificial.

To address use cases like this, in the future, it may be desirable to introduce another accessor kind that returns a borrowed value:

```swift
var stuffing: Stuffing {
  borrow {
    return _stuffing
  }
}
```

That `read` has this limitation weighs against sprinkling it onto types and protocols for speculative performance benefits.
Doing so will impose constraints on callers that will become unnecessary if and when `borrow` is introduced.
Until that time, if profiling indicates that a copy resulting from a `get` is an issue, `read` can be used to avoid it, but at the cost of this constraint.
The `read` accessor is best suited to cases where cleanup is performed after the yield as in `reversed` above.

## Alternatives considered

### Unwinding the accessor when an error is thrown in the caller

The previous version of this proposal specified that if an error is thrown in a coroutine caller while a coroutine is suspended, the coroutine is to "unwind" and the code after the `yield` is not to run.
In the [example above](#throwing-callers), the code after the `yield` would not run if `throwingMutatingOp` threw an error.

This approach was tied up with the idea that a `modify` accessor would cleanup differently if an error was thrown in the caller.
The intervening years of experience with the feature have not borne that out.
If an error is thrown in a caller into which a value has been yielded, the _caller_ must put the yielded mutable value back into a consistent state.
As with `inout` function arguments, the compiler enforces this:
it is an error to consume the value yielded from a `modify` accessor without reinitializing it before resuming the `modify` accessor.
When there are higher-level invariants which the value being modified must satisfy, in general, only the caller will be in a position to ensure that they are satisfied on the throwing path.

Once that basis has been removed, there is no longer a reason to enable a coroutine to "unwind" when an error was thrown in the caller.
It should always finish execution the same way.

## Acknowledgments

