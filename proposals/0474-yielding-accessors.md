# Yielding accessors

* Proposal: [SE-0474](0474-yielding-accessors.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift), [Nate Chandler](https://github.com/nate-chandler), [Joe Groff](https://github.com/jckarter/)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Accepted**
* Vision: [A Prospective Vision for Accessors in Swift](https://github.com/rjmccall/swift-evolution/blob/accessors-vision/visions/accessors.md)
* Implementation: Partially available on main behind the frontend flag `-enable-experimental-feature CoroutineAccessors`
* Review: ([pitch 1](https://forums.swift.org/t/modify-accessors/31872)), ([pitch 2](https://forums.swift.org/t/pitch-modify-and-read-accessors/75627)), ([pitch 3](https://forums.swift.org/t/pitch-3-yielding-coroutine-accessors/77956)), ([review](https://forums.swift.org/t/se-0474-yielding-accessors/79170)), [Acceptance](https://forums.swift.org/t/accepted-se-0474-yielding-accessors/80273)

## Introduction

We propose the introduction of two new accessors, `yielding mutate` and `yielding borrow`, for implementing computed properties and subscripts alongside the current `get` and `set`.

By contrast with `get` and `set`, whose bodies behave like traditional methods, the body of a `yielding` accessor will be a coroutine, using a new contextual keyword `yield` to pause the coroutine and lend access of a value to the caller.
When the caller ends its access to the lent value, the coroutine's execution will continue after `yield`.

These `yielding` accessors enable values to be accessed and modified without requiring a copy.
This is essential for noncopyable types and often desirable for performance even with copyable types.

This feature has been available (but not supported) since Swift 5.0 via the `_modify` and `_read` keywords.
Additionally, the feature is available via `read` and `modify` on recent builds from the compiler's `main` branch using the flag `-enable-experimental-feature CoroutineAccessors`.

## Motivation

### `yielding mutate`<a name="modify-motivation"/>

Swift's `get`/`set` syntax allows users to expose computed properties and subscripts that behave as l-values.
This powerful feature allows for the creation of succinct idiomatic APIs, such as this use of `Dictionary`'s defaulting subscript:

```swift
var wordFrequencies: [String:Int] = [:]
wordFrequencies["swift", default: 0] += 1
// wordFrequencies == ["swift":1]
```

While this provides the illusion of "in-place" mutation, it actually involves three separate operations:
1. a `get` of a copy of the value
2. the mutation, performed on that returned value
3. finally, a `set` replacing the original value with the mutated temporary value.

This can be seen by performing side effects inside of the getter and setter; for example:

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

#### Performance

When the property or subscript is of copyable type, this simulation of in-place mutation works well for user ergonomics but has a major performance shortcoming, which can be seen even in our simple `GetSet` type above.
Strings in Swift aren't bitwise-copyable types; once they grow beyond a small fixed size, they allocate a reference-counted buffer to hold their contents.
Mutation is handled via the copy-on-write technique:
When you make a copy of a string, only the reference to the buffer is copied, not the buffer itself.
Then, when either copy of the string is mutated, the mutation operation checks if the buffer is uniquely referenced.
If it isn't (because the string has been copied), it first duplicates the buffer before mutating it, preserving the value semantics of `String` while avoiding unnecessary eager copies.

Given this, we can see a performance problem when appending to `GetSet.property` in our example above:

- `GetSet.property { get }` is called and returns a copy of `x`.
- Because a copy is returned, the buffer backing the string is no longer uniquely referenced.
- The append operation must therefore duplicate the buffer before mutating it.
- `GetSet.property { set }` writes this copy back over the top of `x`, destroying the original string.
- The original buffer's reference count drops to zero, and it's destroyed too.

So, despite looking like in-place mutation, every mutating operation on `x` made through `property` is actually causing a full copy of `x`'s backing buffer.
This is a linear-time operation.
If we appended to this property in a loop, that loop would end up being quadratic in complexity.
This is likely very surprising to the developer and is a frequent performance pitfall.

[An accessor](#design-modify) which _lends_ a value to the caller in place, without producing a temporary copy, is desirable to avoid this quadratic time complexity while preserving Swift's ability for computed properties to provide expressive and ergonomic APIs.

#### Non-`Copyable` types

When the value being mutated is noncopyable, the common `get`/`set` pattern often becomes impossible to implement:
the very first step of mutation makes a copy!
Thus, `get` and `set` can't be used to wrap access to a noncopyable value:

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

`get` borrows `self` but then tries to _give_ ownership of `x` to its caller. Since `self` is only borrowed, it cannot give up ownership of its `x` value, and since `UniqueString` is not `Copyable`, `x` cannot be copied either, making `get` impossible to implement.
Therefore, to provide computed properties on noncopyable types with comparable expressivity, we again need [an accessor](#design-modify) that borrows `self` and _lends_ access to `x` to its caller without implying independent ownership.

### `yielding borrow`<a name="read-motivation"/>

For properties and subscripts of noncopyable type, the current official accessors are insufficient not only for mutating, but even for _inspecting_.
Even if we remove `set` from our `UniqueGetSet` type above, we still hit the same error in its getter:

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

As discussed above, `UniqueGet.property { get }` borrows `self` but attempts to transfer ownership of `self.x` to the caller, which is impossible.

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

This allows the getter to take ownership of the `UniqueConsumingGet`,
allowing it to destructively extract `x` and transfer ownership to the caller.
Here's how that looks in the caller:

```swift
let container = UniqueConsumingGet()
let x = container.property // consumes container!
// container is no longer valid
```

This might sometimes be desirable, but for many typical uses of properties and subscripts, it is not. If a container holds a number of noncopyable fields, it should be possible to inspect each field in turn, but doing so wouldn't be possible if inspecting one consumes the container.

Similar to the mutating case, what's needed here is [an accessor](#design-read) which _borrows_ `self` and which _lends_ `x`--this time immutably--to the caller.

## Proposed solution

We propose two new accessor kinds:
- `yielding mutate`, to enable mutating a value without first copying it
- `yielding borrow`, to enable inspecting a value without copying it.

## Detailed design

### `yielding borrow`<a name="design-read"/>

[`UniqueGet`](#read-motivation) can now allow its clients to inspect its field non-destructively with `yielding borrow`:

```swift
struct UniqueString : ~Copyable {...}

struct UniqueBorrow : ~Copyable {
  var x: UniqueString

  var property: UniqueString {
    yielding borrow {
        yield x
    }
  }
}
```

The `UniqueBorrow.property { yielding borrow }` accessor is a "yield-once coroutine".
When called, it borrows `self`, and then runs until reaching a `yield`, at which point it suspends, lending the yielded value back to the caller.
Once the caller is finished accessing the value, it resumes the accessor's execution.
The accessor continues running where it left off after the `yield`.

If a a property or subscript provides a `yielding borrow`, it cannot also provide a `get`.

#### `yielding borrow` as a protocol requirement

Such accessors should be usable on values of generic and existential type.
To indicate that a protocol provides immutable access to a property or subscript via a `yielding borrow` coroutine, we propose allowing `yielding borrow` to appear where `get` does today:

```swift
protocol Containing {
  var property: UniqueString { yielding borrow }
}
```

A protocol requirement cannot specify both `yielding borrow` and `get`.

A `yielding borrow` requirement can be witnessed by a stored property, a `yielding borrow` accessor, or a getter.

#### `get` of noncopyable type as a protocol requirement

Property and subscript requirements in protocols have up to this point only been able to express readability in terms of `get` requirements.
This becomes insufficient when the requirement has a noncopyable type:

```swift
protocol Producing {
  var property: UniqueString { get }
}
```

To fulfill such a requirement, the conformance must provide a getter, meaning its implementation must be able to produce a value whose ownership can be transferred to the caller.
In practical terms, this means that the requirement cannot be witnessed by a stored property or a `yielding borrow` accessor when the result is of noncopyable type,[^2] since the storage of a stored property is owned by the containing aggregate and the result of a `yielding borrow` is owned by the suspended coroutine, and it would be necessary to copy to provide ownership to the caller.
However, if the type of the `get` requirement is copyable, the compiler can synthesize the getter from the other accessor kinds by introducing copies as necessary.

[^2]: While the compiler does currently accept such code, it does so by interpreting that `get` as a `yielding borrow`, which is a bug.

### `yielding mutate`<a name="design-modify"/>

The `GetSet` type [above](#modify-motivation) could be implemented with `yielding mutate` as follows:

```swift
struct GetMutate {
  var x: String =  "👋🏽 Hello"

  var property: String {
    get { print("Getting", x); return x }
    yielding mutate {
      print("Yielding", x)
      yield &x
      print("Post yield", x)
    }
  }
}

var getMutate = GetMutate()
getMutate.property.append(", 🌍!")
// prints:
// Yielding 👋🏽 Hello
// Post yield 👋🏽 Hello, 🌍!
```

Like `UniqueBorrow.property { yielding borrow }` above, `GetMutate.property { yielding mutate }` is a yield-once coroutine.
However, the `yielding mutate` accessor lends `x` to the caller _mutably_.

Things to note about this example:
* `get` is never called — the property access is handled entirely by the `yielding mutate` accessor
* the `yield` is similar to a `return`, but control returns to the `yielding mutate` after the `append` completes
* there is no more `newValue` – the yielded value is modified by `append`
* because it's granting _mutable_ access to the caller, `yield` uses the `&` sigil, similar to passing an argument `inout`

Unlike the `get`/`set` pair, the `yielding mutate` accessor is able to safely provide access to the yielded value without copying it.
This can be done safely because the accessor preserves ownership of the value until it has completely finished running:
When it yields the value, it only lends it to the caller.
The caller is exclusively borrowing the value yielded by the coroutine.

`get` is still used when only fetching, not modifying, the property:

```swift
_ = getMutate.property
// prints:
// Getting 👋🏽 Hello, 🌍!
```

`yielding mutate` is sufficient to allow assignment to a property:

```
getMutate.property = "Hi, 🌍, 'sup?"
// prints:
// Yielding 👋🏽 Hello, 🌍!
// Post yield Hi, 🌍, 'sup?
```

It is, however, also possible to supply _both_ a `yielding mutate` and a `set` accessor.
The `set` accessor will be favored in the case of a whole-value reassignment, which may be more efficient than preparing and yielding a value to be overwritten:

```swift
struct GetSetMutate {
  var x: String =  "👋🏽 Hello"

  var property: String {
    get { x }
    yielding mutate { yield &x }
    set { print("Setting",newValue); x = newValue }
  }
}
var getSetMutate = GetSetMutate()
getSetMutate.property = "Hi 🌍, 'sup?"
// prints:
// Setting Hi 🌍, 'sup?
```

#### Pre- and post-processing in `yielding mutate`

As with `set`, `yielding mutate` gives the property or subscript implementation an opportunity to perform some post-processing on the new value after assignment. Even in these cases, `yielding mutate` can often allow for a more efficient implementation than a traditional `get`/`set` pair would provide.
Consider the following implementation of an enhanced version of `Array.first` that allows the user to modify the first value of the array:

```swift
extension Array {
  var first: Element? {
    get { isEmpty ? nil : self[0] }
    yielding mutate {
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

This implementation takes a similar approach to `Swift.Dictionary`'s key-based subscript:
if there is no `first` element, the accessor appends one.
If `nil` is assigned, the element is removed.
Otherwise, the element is updated to the value from the assigned `Optional`'s payload.

Because the fetch and update code are all contained in one block, the `isEmpty` check is not duplicated; if the same logic were implemented with a `get`/`set` pair, `isEmpty` would need to be checked independently in both accessors. With `yielding mutate`, whether the array was initially empty is part of the accessor's state, which remains present until the accessor is resumed and completed.

#### Taking advantage of exclusive access

The optional return value of `first` in the code above means that, despite using `yielding mutate`, we have reintroduced the problem of triggering copy-on-write when mutating through the `first` property.
That act of placing the value in the array inside of an `Optional` (namely, `tmp = self[0]`) creates a copy.

Like a `set` accessor, a `yielding mutate` accessor in a `struct` or `enum` property is `mutating` by default (unless explicitly declared a `nonmutating yielding mutate`).
This means that the `yielding mutate` accessor has exclusive access to `self`, and that exclusive access extends for the duration of the accessor's execution, including its suspension after `yield`-ing.
Since the implementation of `Array.first { yielding mutate }` has exclusive access to its underlying buffer, it can move the value of `self[0]` directly into the `Optional`, yield it, and then move the result back after being resumed:

```swift
extension Array {
  var first: Element? {
    yielding mutate {
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

While the `yielding mutate` coroutine is suspended after yielding, the `Array` is left in an invalid state: the memory location where the first element is stored is left uninitialized, and must not be accessed.
However, this is safe thanks to Swift's rules preventing conflicting access to memory.
Unlike a `get`, the `yielding mutate` is guaranteed to have an opportunity to put the element back (or to remove the invalid memory if the entry is set to `nil`) after the caller resumes it, restoring the array to a valid state in all circumstances before any other code can access it.

### The "yield once" rule

Notice that there are _two_ yields in this `Array.first { yielding mutate }` implementation, for the empty and non-empty branches.
Nonetheless, exactly one `yield` is executed on any path through the accessor.
In general, the rules for yields in yield-once coroutines are similar to those of deferred initialization of `let` variables:
it must be possible for the compiler to guarantee there is exactly one yield on every path.
In other words, there must not be a path through the yield-once coroutine's body with either zero[^1] or more than one yield.
The `Array.first` example is valid since there is a `yield` in both the `if` and the `else` branch.
In cases where the compiler cannot statically guarantee this, refactoring or use of `fatalError()` to assert unreachable code paths may be necessary.

[^1]: Note that it is legal for a path without any yields to terminate in a `fatalError`.  Such a path is not _through_ the function.

### Throwing callers<a name="throwing-callers"/>

The `Array.first { yielding mutate }` implementation above is correct even if the caller throws while the coroutine is suspended.

```swift
try? myArray.first?.throwingMutatingOp()
```

Thanks to Swift's rule that `inout` arguments be initialized at function exit, the element must be a valid value when `throwingMutatingOp` throws.
When `throwingMutatingOp` does throw, control returns back to the caller.
The body of `Array.first { yielding mutate }` is resumed, and `tmp` is a valid value.
Then the code after the `yield` executes.
The coroutine cleans up as usual, writing the updated temporary value in `tmp` back into the storage buffer.

## Source compatibility

The following code is legal today:

```swift
func borrow<T>(_ c : () -> T) -> T { c() }
var reader : Int {
  borrow {
    fatalError()
  }
}
```

Currently, the code declares a property `reader` with an implicit getter.
The implicit getter has an implicit return.
The expression implicitly returned is a call to the function `borrow` with a trailing closure.

An analogous situation exists for `mutate`.

This proposal takes the identifiers `borrow` and `mutate` as contextual keywords
as part of the `yielding borrow` and `yielding mutate` accessor declarations.
By themselves, these two new accessor forms do not immediately require a source break; however, as the [accessors vision](https://github.com/rjmccall/swift-evolution/blob/accessors-vision/visions/accessors.md) lays out, we will more than likely want to introduce non-`yielding` variants of `borrow` and `mutate` in the near future as well.

Therefore, we propose an alternate interpretation for this code:
that it declare a property `reader` with a `borrow` accessor.
Although such an accessor does not yet exist, making the syntax change now will prepare the language for subsequent accessors we introduce in the near future.

If this presents an unacceptable source compatibility break, the change may have to be gated on a language version.

## ABI compatibility

Adding a `yielding mutate` accessor to an existing read-only subscript or computed property has the same ABI implications as adding a setter; it must be guarded by availability on ABI-stable platforms.
The stable ABI for mutable properties and subscripts provides `get`, `set`, and `_modify` coroutines, deriving `set` from `_modify` or vice versa if one is not explicitly implemented.
Therefore, adding or removing `yielding mutate`, adding or removing `set`, replacing a `set` with a `yielding mutate`, or replacing `yielding mutate` with `set` are all ABI-compatible changes, so long as the property or subscript keeps at least one of `set` or `yielding mutate`, and those accessors agree on whether they are `mutating` or `nonmutating` on `self`.

By contrast, `yielding borrow` and `get` are mutually exclusive. Replacing one with the other is always an ABI-breaking change.
Replacing `get` with `yielding borrow` is also an API-breaking change for properties or subscripts of noncopyable type.

Renaming the current `_modify` (as used by the standard library, e.g.) to `yielding mutate` is an ABI additive change: a new `yielding mutate` symbol will be added.
When the compiler sees a `yielding mutate` with an early enough availability, the compiler will synthesize a corresponding `_modify` whose body will just forward to `yielding mutate`.
This is required for ABI stability: code compiled against an older standard library which calls `_modify` will continue to do so.
Meanwhile, code compiled against a newer standard library will call the new `yielding mutate`.
The same applies to renaming `_read` to `yielding borrow`.

## Implications on adoption

### Runtime support

The new ABI will require runtime support which would need to be back deployed in order to be used on older deployment targets.

### When to favor coroutines over `get` and `set`

Developers will need to understand when to take advantage of `yielding` accessors, and we should provide some guidance:

#### `yielding mutate`

`yielding mutate` is desirable when the value of a property or subscript element is likely to be subject to frequent in-place modifications, especially when the value's type uses copy-on-write and the temporary value created by a `get`-update-`set` sequence is likely to trigger full copies of the buffer that could otherwise be avoided.
Additionally, if the mutation operation involves complex setup and teardown that requires persisting state across the operation, `yielding mutate` allows for arbitrary state to be preserved across the access.

For noncopyable types, implementing `yielding mutate` is necessary to provide in-place mutation support if the value of the property or subscript cannot be read using a `get`.

Even in cases where `yielding mutate` is beneficial, it is often still profitable to also provide a `set` accessor for whole-value reassignment. `set` may be able to avoid setup necessary to support an arbitrary in-place mutation and can execute as a standard function call, which may be more efficient than a coroutine.

#### `yielding borrow`<a name="read-implications"></a>

For read-only operations on `Copyable` types, the performance tradeoffs between `get` and `yielding borrow` are more subtle.
`borrowing yield` can avoid copying a result value that is stored as part of the originating value.
On the other hand, `get` can execute as a normal function without the overhead of a coroutine.
(As part of the implementation work for this proposal, we are implementing a more efficient coroutine ABI that should be significantly faster than the implementation used by `_read` and `_modify` today; however, a plain function call is likely to remain somewhat faster.)
`yielding borrow` may nonetheless be preferable for providing access to large value types in memory that would be expensive to copy as part of returning from a `get`.

`yielding borrow` also introduces the ability to perform both setup work before and teardown work after the caller has accessed the value, whereas `get` can at best perform setup work before returning control to the caller.
Particularly in conjunction with non-`Escapable` types, which could eventually be lifetime-bound to their access, a `yielding borrow` accessor producing a non-`Escapable` value could provide limited access to a resource in a similar manner to `withSomething { }` closure-based APIs, without the "pyramid of doom" or scoping limitations of closure-based APIs.

For properties and subscripts with noncopyable types, the choice between `yielding borrow` and `get` will often be forced by whether the API contract specifies a borrowed or owned result.
An operation that provides temporary borrowed access to a component of an existing value without transferring ownership, when that value is expected to persist after the access is complete, must be implemented using `yielding borrow`.
An operation that computes a new value every time is best implemented using `get`.
(Such an operation can in principle also be implemented using `yielding borrow`; it would compute the temporary value, yield a borrow to the caller, and then destroy the temporary value when the coroutine is resumed.
This would be inefficient, and would furthermore prevent the caller from being able to perform consuming operations on the result.)

For polymorphic interfaces such as protocol requirements and overridable class members that are properties or subscripts of noncopyable type, the most general requirement is `yielding borrow`, since a `yielding borrow` requirement can be satisfied by either a `yielding borrow` or a `get` implementation (in the latter case, by wrapping the getter in a synthesized `yielding borrow` that invokes the getter, yields a borrow the result, then destroys the value on resume).
Using `yielding borrow` in polymorphic or ABI-stable interfaces may thus desirable to allow for maximum evolution flexibility if being able to consume the result is never expected to be part of the API contract.

## Future directions

### Yield-once functions

Further ergonomic enhancements to the language may be needed over time to make the most of this feature.
For example, coroutine accessors do not compose well with functions because functions cannot themselves currently yield values.
In the future, it may be desirable to also support yield-once functions:

```swift
var value: C { yielding mutate { ... } }
yielding func updateValue(...) -> inout C {
  yield &self.value
  additionalWork(value)
}
```

### Forwarding both consuming and borrowing accesses to the same declaration

When a property or subscript has a `consuming get`, a caller can take ownership of the field at the expense of also destroying the rest of object.
When a property or subscript has a `yielding borrow` accessor, a caller can borrow the field to inspect it without taking ownership of it.

As proposed here, it's not yet possible for a single field to provide both of these behaviors to different callers.
Since both of these behaviors have their uses, and many interfaces want to provide "perfect forwarding" where any of consuming, mutating, or borrowing operations on a wrapper can be performed by passing through the same operation to an underlying value, it may be desirable in the future to allow a single field to provide both a `yielding borrow` and a `consuming get`:

```swift
subscript(index: Int) -> Value {
  consuming get {...}
  yielding borrow {...}
}
```

The rules that Swift currently uses to determine what accessor(s) to use in order to evaluate an expression are currently only defined in terms of whether the access is mutable or not, so these rules would need further elaboration to distinguish non-mutating accesses by whether they are consuming or borrowing in order to determine which accessor to favor.

### Transitioning between owned and borrowed accessors for API evolution<a name="ownership-evolution"></a>

When a noncopyable API first comes into existence, its authors may not want to commit to it producing an owned value. As discussed [above](#read-implications), providing a `yielding borrow` accessor is often the most conservative API choice for noncopyable properties and subscripts:

```swift
subscript(index: Int) -> Value {
  yielding borrow {...}
}
```

As their module matures, however, the authors may decide that committing to providing a consumable value is worthwhile.
To support this use-case, in the future, it may be desirable to allow for forward-compatible API and ABI evolution by promoting a `yielding borrow` accessor to `get`:

```swift
subscript(index: Int) -> Value {
  // Deprecate the `yielding borrow`
  @available(*, deprecated)
  yielding borrow {...}

  // Favor the `get` for new code
  get {...}
}
```


That would enable the module to evolve to a greater commitment while preserving ABI.

For APIs of copyable type, the reverse evolution is also a possibility; an API could originally be published using a `get` and later decide that a `yielding borrow` accessor is overall more efficient.

Since it would typically be ambiguous whether the `yielding borrow` or `get` should be favored at a use site, it would make sense to require that one or the other accessor be deprecated or have earlier availability than the other in order to show that one is unambiguously preferred over the other for newly compiled code with recent enough availability.

### Non-`yielding` `borrow` and `mutate` accessors

A `yielding` accessor lends the value it yields to its caller.
The caller only has access to that value until it resumes the coroutine.
After the coroutine is resumed, it has the opportunity to clean up.
This enables a `yielding borrow` or `mutate` to do interesting work, such as constructing a temporary aggregate from its base object's fields:

```swift
struct Pair<Left : ~Copyable, Right : ~Copyable> : ~Copyable {
  var left: Left
  var right: Right

  var reversed: Pair<Right, Left> {
    yielding mutate {
      let result = Pair<Right, Left>(left: right, right: left)
      yield &result
      self = .init(left: result.right, right: result.left)
    }
  }
}
```

That the access ends when the coroutine is resumed means that the lifetime of the lent value is strictly shorter than that of the base value.
In the example above, the lifetime of `reversed` is shorter than that of the `Pair` it is called on.

As discussed in the [accessors vision](https://github.com/rjmccall/swift-evolution/blob/accessors-vision/visions/accessors.md), when a value is merely being projected from the base object and does not need any cleanup after being accessed, this is undesirably limiting:
a value projected from a base naturally has _the same_ lifetime as the base.

This is especially problematic in the context of composition with non-`Escapable` types.
Consider the following wrapper type[^3]:

[^3]: This example involves writing out a `yielding borrow` accessor.  The same issue exists when the compiler synthesizes a `yielding borrow` accessor for a stored property exported from a resilient module.

```swift
struct Wrapper<Stuffing : ~Copyable & ~Escapable> : ~Copyable & ~Escapable {
  var _stuffing: Stuffing

  var stuffing: Stuffing {
    yielding borrow {
      yield _stuffing
    }
  }
}
```

When the instance of `Wrapper` is local to a function, the strict nesting of lifetimes may not immediately be a problem:

```swift
{
  let wrapper: Wrapper<Stuffing> = ...
  borrowStuffing(wrapper.stuffing)
  // lifetime of wrapper.stuffing ends (at coroutine resumption)
  // lifetime of wrapper ends
}
```

But when `Wrapper` is a parameter, or otherwise nonlocal to the function, it is natural to expect to return the `Stuffing` back to the source of the `Wrapper`, but the `yielding borrow` accessor artificially limits its lifetime:

```swift
@lifetime(borrow wrapper)
func getStuffing<Stuffing : ~Copyable & ~Escapable>(from wrapper: borrowing Wrapper<Stuffing>) -> Stuffing {
  return wrapper.stuffing // error
}
```

The issue is that the lifetime of `stuffing` ends _within_ `getStuffing`, when the `yielding borrow` coroutine is resumed, which prevents `stuffing` from being returned.

To address use cases like this, in the future, it may be desirable to introduce a variant of `borrow` and `mutate` accessors that immediately `return`s the borrowed or mutable value without involving a coroutine:

```swift
var stuffing: Stuffing {
  borrow {
    return _stuffing
  }
}
```

A non-`yielding` `borrow` or `mutate` accessor would be limited to returning values that can be accessed immediately and which do not require any cleanup (implicit or explicit) when the access ends. As such, the `yielding` variants would still provide the most flexibility in implementation, at the cost of the additional lifetime constraint of the coroutine. Similar to the [discussion around evolving `yielding borrow` accessors into `get` accessors](#ownership-evolution), there is also likely to be a need to allow for APIs initially published in terms of `yielding` accessors to transition to their corresponding non-`yielding` accessors in order to trade stronger implementation guarantees for more flexibility in the lifetime of derived `~Escapable` values.

## Alternatives considered

### Unwinding the accessor when an error is thrown in the caller

A previous version of this proposal specified that if an error is thrown in a coroutine caller while a coroutine is suspended, the coroutine is to "unwind" and the code after the `yield` is not to run.
In the [example above](#throwing-callers), the code after the `yield` would not run if `throwingMutatingOp` threw an error.

This approach was tied up with the idea that a `yielding mutate` accessor might clean up differently if an error was thrown in the caller.
The intervening years of experience with the feature have not borne out the need for this.
If an error is thrown in a caller into which a value has been yielded, the _caller_ must put the yielded mutable value back into a consistent state.
As with `inout` function arguments, the compiler enforces this:
it is an error to consume the value yielded from a `yielding mutate` accessor without reinitializing it before resuming the `yielding mutate` accessor.
When there are higher-level invariants which the value being modified must satisfy, in general, only the caller will be in a position to ensure that they are satisfied on the throwing path.

Once that basis has been removed, there is no longer a reason to enable a coroutine to "unwind" when an error was thrown in the caller.
It should always finish execution the same way.

### Naming scheme

These coroutine accessors have been a long-standing "unofficial" feature of the Swift compiler under the names `_read` and `_modify`.
Previous revisions of this proposal merely dropped the underscore and proposed the coroutine accessors be provided under the name `read` and `modify`.
However, as we have continued to build out Swift's support for ownership and lifetime dependencies with `~Copyable` and `~Escapable` types, we have since identified the need for non-coroutine accessors that can produce borrowed and/or mutable values without imposing a lifetime dependency on a coroutine access.

In order to avoid a proliferation of unrelated-seeming accessor names, this revision of the proposal uses the name `yielding borrow` instead of `read` and `yielding mutate` instead of `modify`.
We feel these names better connect the accessors to what ownership of the result is given:
a `borrow` accessor gives `borrowing` access to its result, and a `mutate` accessor gives `mutating` (in other words, `inout`) access.
Using `yielding` as an added modifier relates these accessors to potential non-coroutine variants of the accessors that could exist in the future; a `borrow` accessor (without `yielding`) would in the future be an accessor that returns a borrow without involving a coroutine.
The same `yielding` modifier could also be used in other places in the future, such as `func` declarations, to allow for yield-once coroutines to be defined as regular functions outside of accessors.

## Acknowledgments

John McCall and Arnold Schwaighofer provided much of the original implementation of accessor coroutines. Tim Kientzle and John McCall authored the accessors vision document this proposal serves as part of the implementation of.

