# A Vision for Accessors in Swift

Swift properties are implemented by providing one or more “accessors” which are able to provide or update the value of a property.  Most Swift developers should be familiar with the `get` and `set` accessors that are used to implement computed properties:

```swift
struct Foo {
  var value: Int {
    get { ... provide a value ... }
    set { ... accept a value ... }
  }
}
```

In this case, the `get` accessor gets compiled into a special kind of method that returns a value, the `set` accessor gets compiled into a method that accepts a new value as an argument.  Reading or writing such a property is compiled into a call to the corresponding method.  Swift provides resilience for stored properties by automatically generating `get` and `set` accessor methods so that clients can be compiled the same way regardless of whether the property is actually written as a stored or computed property.

> The description of “methods” here explains what happens when you access resilient stored properties that are defined in a separate module.  When accessing stored properties from within the *same* module, Swift typically uses efficient direct property access.

However, `get` and `set` accessors have significant limitations.  For example, because the `get` and `set` accessors transfer the value as a method argument or return value, they generally require the value to be copyable, which is no longer universally true in Swift.  This copying also adds significant overhead for large or complex values.  As an additional complication, more complex APIs, such as the subscript access for `Dictionary`, need to construct a temporary value and then clean up that value at the end of the access.

These limitations have led Swift to add a variety of other accessors, including several experimental forms that have never been officially standardized through the Swift Evolution process.  Recent work on noncopyable support and an expanded interest in new kinds of collections has made it important to provide a complete standard set of accessors to support future work.  This document will explain the various accessors that currently exist or might be proposed in the near future and how they will provide the full set of capabilities needed for different applications.

> Note:  Accessors are also used to implement subscripts; the only real difference is that a subscript operation can have additional arguments.  This document will discuss property accesses and subscript operations interchangeably.

## Two Dimensions of Access

There are a wide variety of theoretically possible accessors, varying in what kind of access they provide and what mechanism they use to provide it.  Different programming languages support different combinations.  For Swift, there are three fundamental kinds of access that we are interested in:

* Read access.
* Write or “set” access.
* Update access.

Write and update access differ in that write access can create a value that did not exist before, while update access requires there be a pre-existing value.  For example, consider how the dictionary write operation `myDictionary["newKey"] = value` can create a value that did not exist before. In contrast, `myDictionary["existingKey"] += 1` modifies a value that must necessarily already exist.

For each kind of access, there are multiple ways that the access might be provided.  The Swift implementation today supports three different possible mechanisms, although not all of these are currently supported by accessors:

* Copying.  The value might be copied between the caller and the callee.
* Borrowing.  The callee might provide access to the value without actually copying it.  This can be implemented by having the callee provide a pointer or reference to the value *in situ.*
* Yielding.  Each of the above is typically provided by calling a function.  The value or pointer is passed as an argument or return value from that function.  It’s also possible for the callee to start a *coroutine* whose execution is interleaved with that of the caller.  This allows the callee to resume after the caller is finished, which is not possible for a function- or method-based accessor.

## Six of Nine Fundamental Accessors

Combining the possibilities above gives us a 3x3 matrix of possible accessors:

|              |Read   |Write  |Update |
|---           |---    |---    |---    |
|**Copying**   |       |       |✗      |
|**Borrowing** |       |✗      |       |
|**Yielding**  |       |✗      |       |

Three of these combinations turn out to be either impossible or not useful:

* “Copying Update” is unnecessary.  A copying update would by definition copy the value into the caller and then copy the updated value back, which is easily achieved by using a “Copying Read” followed by a “Copying Write”
* “Borrowing Write” and “Yielding Write” are simply impossible.  Both borrowing and yielding require an existing value.  As such, they provide “update” access.

## Existing and Proposed Standard Accessors

Based on the discussion above, we are left with six combinations that are both possible and useful.  The following table gives each one a name:

|              |Read   |Write |Update |
|---           |---    |---   |---    |
|**Copying**   |get    |set   |✗      |
|**Borrowing** |borrow |✗     |mutate |
|**Yielding**  |read   |✗     |modify |

Some of the above exist in the current Swift language, others we expect to be proposed in the near future.  Here is a slightly more detailed explanation of each one:

* `get` and `set` - These are the original standard accessors, which compile into methods that return or accept a value of the indicated type.
* `borrow` and `mutate` - These borrowing accessors are not yet implemented, but we expect to propose them for Swift Evolution at some point in the future.  These provide access to the value without copying by relying on Swift’s “borrow” implementation which avoids pointer overhead for simple types.  In particular, these can be used for non-copyable and non-escapable values.  (In various discussions, the proposed `mutate` accessor has been called `inout`.)
* `read` and `modify` -  These exist today as experimental `_read` and `_modify` implementations and we expect to propose a revised final form without the underscored names in the near future. They compile into coroutines that “yield” the value.  In effect, each such accessor becomes two functions:  The “top half of the coroutine” creates a value if necessary and then provides the caller with a pointer to this value.  The “bottom half of the coroutine” cleans up the value.  In effect, callers invoke the top half to obtain a pointer to the value, use the pointer to read and/or modify the value, then call the bottom half to give the property a chance to clean itself up.

In the process of developing the above, a number of other approaches have been explored.  Some of the following are currently supported in the compiler, but none are expected to go through Swift Evolution

* `unsafeAddress` and `unsafeMutableAddress` - These are implemented but are not expected to ever go through Swift Evolution.  They compile into methods that return a pointer to the value in question.  This pointer value is explicit in the property implementation but is not visible in the Swift source code of the client.  This does not require copying the value, but does require that the value already be present somewhere in memory.  This was an early form of the idea behind `borrow` and `mutate` but based on unsafe constructs.
* `unsafeRawAddress` and `unsafeRawMutableAddress` - These are not yet implemented and may not ever go through Swift Evolution.  These are similar to the above but allow the property implementation to work directly with an untyped “raw” pointer while the caller sees an access to typed data in memory.  This document will refer to these and the previous two collectively as `unsafe*Address`.
* `_read` and `_modify` - These were the early experimental forms of `read` and `modify`.  They will likely continue to be supported in order to avoid breaking existing code, but users should migrate to `read` and `modify` once they are finalized.

## Distinguishing Features

These accessors vary in how they treat both the property value and the containing value.  In this section, we’ll explore the forms that variation takes:

### Copying vs. Borrowing

A key distinction is whether a particular accessor copies the property value or whether it provides access to the value without copying it.  The `get` and `set` accessors copy the value by returning it as a method result or accepting it as a method argument.  Other accessors provide access to a value without copying:

*  `unsafe*Address` have the accessor provide an explicit pointer
* `read`/`modify` *yield* access to a value from a coroutine.  This can be a directly stored value, or a constructed value stored temporarily in a coroutine execution frame.
* `borrow` and `mutate` allow the client to *borrow* the value.  Following the existing Swift ABI rules, this may involve passing a pointer or “bitwise borrowing” the value to avoid pointer overhead for small values.  (Note that bitwise borrowing can be used even for noncopyable values since it is not formally a copy.)

The `unsafe*Address` and `borrow`/`mutate` can avoid copying because the property value is already in memory within the containing value.  The compiler needs to ensure that the containing value is not destroyed or modified until after the pointer or borrow reference is no longer in use.

A `read` or `modify` accessor can usually avoid a copy, but not always:  In practice, the implementation cannot delay the bottom half of the coroutine indefinitely.  This can lead to situations where the value is still needed after the coroutine ends, which requires copying the value from the coroutine’s execution frame into the calling context.  When this happens, a `_read` or `_modify` accessor is generally slower than a regular `get`, since it incurs copy overhead similar to a `get` in addition to the coroutine execution overhead.  This also limits the use of `read` or `modify` with property values that are not copyable.

### Exposing transformed temporary values

The `read` and `modify` accessors provide the ability to expose a transformed version of a stored value. This is important for dictionary mutation, which in the current API exposes the value as an Optional which is `nil` if the value is not currently set.  This allows a dictionary update such as `dict[key]?.modify()` to copy the dictionary value into a constructed optional in the top half of the accessor, then run the method call directly on the value, then run the bottom half to deconstruct the optional and store the result back into the dictionary storage.

Another example:  Providing a `Span` over the contents of a String will require that we somehow handle the case where a short String is stored inline.

### Access Scope

The `get`/`set` accessors conceptually represent “instantaneous” access of the value.  After the `get` accessor returns, there is no relation between the returned copy of the property value and the containing value.  Each of the other accessors implies that the containing value must continue to exist for some period.  This period is generally fairly short, but optimization can extend this interval in order to simplify other operations:

* `unsafe*Address` accessors return pointers into the containing value.  This is safe for the caller of these accessors because the compiler knows about this relationship and can extend the lifetime of the containing value as needed.  (These accessors are nominally “unsafe” because their implementation requires constructing an unsafe pointer and there are no checks to ensure that the pointer so constructed is in fact valid.)
* `read`/`modify` expose a value for the lifetime of a coroutine. Coroutines enforce that the containing value remains alive for the duration of the coroutine.  Note that in current Swift, the coroutines are generally quite short-lived and the compiler copies the value into or out of the coroutine fairly aggressively.  In the future, the compiler will likely become more adept at expanding the coroutine lifetime to reduce such copying.
* `borrow`/`mutate` return a borrow of the property value.  This borrow has an implied dependence on the containing value, and the compiler must guarantee that the containing value outlives the property access.

### Ownership of the containing value

All of the above accessors include a reading variant (`get`, `read`, `borrow`) and a writing variant (`set`, `modify`, `mutate`).  By default, the reading variant is not considered to be a mutation of the enclosing value.  The writing variant conversely is considered to be a write access of the enclosing value and the usual Swift exclusivity rules apply to limit the scope of such access.

However, a reading accessor can be explicitly marked as `mutating`.  This relaxes checks on the accessor implementation so that it can mutate the containing value, and also causes the caller to treat this as a write access requiring exclusivity enforcement.  This is commonly used for caching or bookkeeping:

```swift
struct Foo {
  private var accessCount: Int
  private var _cachedBaz: Baz?
  var baz: Baz {
     mutating get {
       accessCount += 1 // OK because of `mutating`
       if _cachedBaz == nil {
         _cachedBaz = computeBazPropertyValue() // OK because of `mutating`
       }
       return _cachedBaz
     }
  }
}
```

Conversely, writing accessors can be marked as `nonmutating`, though this is not generally useful in practice as it would require that the accessor not in fact mutate the containing value.  This could only be useful for modeling non-property operations as setters.

Accessors can also be `consuming`.  This indicates that the containing object must end its lifetime once this access is complete.  This is useful for representing certain types of object transformations:

```swift
struct Values {
  var dropOldest: Values {
    consuming get {
       let newValues = ... everything but the oldest ...
       return newValues
       // Current value will end it's lifetime after this returns
    }
  }
}

let v = Values()
let v2 = v.dropOldest
// `v` is no longer alive here
```

Note that `consuming` makes no sense for setters — there is no point to changing a property on a value and then immediately ending the lifetime of that value.  Similarly, `consuming` makes no sense for `borrow` or `unsafeAddress` accessors — those require that the containing value survive for the duration of the returned borrow access or address, so it does not make sense to explicitly terminate the value lifetime immediately.

This only leaves `consuming get` and `consuming read` as meaningful combinations.  A `consuming get` can be used for operations such as the `dropOldest` example above that model a transformation by creating a new value and terminating the old one.  The `consuming read` variant can be used similarly.  Unlike `borrow`, the `read` operation coroutine structure forces the containing value to live for a certain period of time, the value is consumed only at the end of that coroutine.

## Some Observations

Based on the above considerations, we can make a few useful observations about how these different accessors complement one another:

#### Diversity is needed

No one pair of accessors suffices to cover the needs of the language:

* `get`/`set` require the property value to be copyable.
* `unsafeAddress`/`unsafeMutableAddress` and `borrow`/`mutate` require the value to be already available in memory.  In particular, the mutating forms cannot be used to store a new value into a collection such as `Dictionary`, since the storage for such a value would not already be initialized.
* `read`/`modify` exposes the value only for the lifetime of a coroutine, which is itself limited by implementation restrictions.

#### Some combinations are nonsensical

* Providing both a `mutate` and a `modify` for the same property doesn’t make sense.  If `mutate` is possible, then you can provide the value without making a copy, which means `modify` is unnecessary and redundant.

#### We need to support existing APIs

The current Swift API seems to require the following:

* `set` is needed to be able to initialize new values for subscript operations.  `modify` is capable of doing this for types that can be trivially initialized, but there can be considerable overhead to construct an empty placeholder, expose it for mutation, and then record the final result.
* Either `borrow` or `read` is needed to provide safe reading of noncopyable values
* Either `mutate` or `modify` is needed to provide safe mutation of noncopyable values
* We have `Dictionary` APIs (among others) that expose values as a different type than they are stored.  These can be supported using `read`/`modify` and storing the transformed value in the coroutine frame for the duration of the access.  They could also be supported using `get` to return a transformed value, but that would require a more expensive read-modify-write cycle for modifications.
* Because `read`/`modify` have constraints on the lifetime of the access, they cannot fully replace `borrow`/`mutate`.

#### Address accessors are redundant with borrow/mutate

The `unsafe*Address` accessors should be unnecessary once we have safe `borrow` and `mutate` to replace them.   But it may take a while to implement the latter, so the former are important interim tools for now.

#### Minimal sets of accessors

The above considerations allow us to outline a possible minimal set of accessors:

* The `borrow`, `mutate`, and `set` accessors provide the absolute minimum required for performant property access.
* In addition, there are a few APIs (especially Dictionary) that expose transformed values; those require `modify` for performant update operations.
* Providing a freshly-constructed value on each access requires `get`.

#### Roadmap

Combining the above, we expect that Swift will converge on a standard set of six accessors — `get`, `set`, `read`, `modify`, `borrow`, and `mutate` — over the next couple of years.

In the interim, the `unsafe*Address` accessors will continue to be needed and useful for implementing many types of containers.

The legacy `_read` and `_modify` accessors will continue to be supported by the compiler for ABI compatibility but should not be used by new code.

## Recommended Usage

Based on the above, we can make some concrete recommendations for how each of these accessors should be used.

#### `get`

This should be used when the access constructs and returns a new value or is part of a resilient interface which might be changed to operate this way at some point in the future.  Note that this works correctly even for non-copyable types when the value truly is returned fresh from each access and not being stored locally.

Use `mutating get` when you need to implement a `get` operation that might cache the value or otherwise update mutable state on the containing object.

Use `consuming get` to model transmutation operations, where the original instance is being transformed into some other type, dissolving it in the process. One use case of this is unwrapping box types, where the returned instance is extracted from the box, destroying it in the process.

#### `set`

As above, this is the only reasonable way to implement subscript operations that create new entries.  It can be used with copyable or noncopyable property values.

#### `unsafe*Address`

These are not recommended for general use, as they require working with unsafe pointer types.  However, until `borrow`/`mutate` can be implemented, they will be the only good choice for containers that need to flexibly provide access to non-copyable values.

```swift
struct MyContainer<T> {
  subscript(i: Int) -> T {
    unsafeAddress {
      baseAddress! + i * MemoryLayout<T>.stride
    }
  }  
}

let contents = MyContainer<Foo>
let x = contents[0]

```

> Important:  The above example uses unsafe pointer operations in the `subscript` implementation, but the use of pointers is completely invisible to the client source code.

#### `read`

> This is currently implemented as `_read` with slightly different semantics than described here.  In particular `_read` will not always run the “bottom half” if there is a thrown error in the caller during the scope of the coroutine.


Read accessors expose direct access to a value, allowing that value to be created on demand for the duration of the access, and destroyed at the end of it. The caller is only given borrow access to the entity — it is not allowed to mutate or consume it.

The result is scoped to a narrow, unique lifetime tied to the specific access, rather than the instance on which the property was invoked.  Because it is implemented as a scoped coroutine, this lifetime cannot extend past the end of an accessing function:

```swift
extension Foo {
  var noncopyable: NonCopyableType {
    read {
      let temp = ... transform existing value to construct `temp` ...
      yield temp
      ... clean up `temp`, possibly restoring the original value ...
    }
  }
}

func access(foo: Foo) -> NonCopyableType {
  // Coroutine starts before accessing the property.
  // The coroutine `yield` provides this code with
  // a reference to the temp value stored in the
  // coroutine execution frame.
  return foo.noncopyable
  // Note: If this function were to do more with the value,
  // then the end of the coroutine can be delayed until
  // the last operation.
  // But note that coroutines _must_ end before the
  // function does, so the return in this case must
  // be transferred out of the coroutine frame.
  // Problem: coroutine still owns the temp value,
  // so it can't be transferred here without copying
}
```

If the example above were implemented as a `get` operation, we could return the constructed non-copyable temporary value  but that would not give the `Foo` object any opportunity to clean up the temporary.

#### `modify`

When a property needs to be exposed for mutation with a fundamentally different type than is being stored, `modify` is the only practical choice.

#### `borrow`

When it becomes available, `borrow` will be the preferred way to provide read access to values that are either noncopyable or expensive to copy (for example, because they are large).  This includes values with generic type that might be either noncopyable or expensive to copy.

Compare how the above example would work with a `borrow` implementation:

```swift
extension Foo {
  var noncopyable: borrowing NonCopyableType {
    borrow {
      return ... value stored in some structure ...
    }
  }
}

func access(foo: Foo) -> borrowing NonCopyableType {
  return foo.noncopyable
}
```

Unlike the `read` version, this form has no problems returning the borrowed value.  This requires a new “borrowing returns” language feature which would track the reliance on `foo` and ensure that `foo` was not modified for as long as the value borrowed from it was being accessed.

Compared to `unsafeAddress`, `borrow` provides the same functionality without the need to do any explicit pointer manipulation.  The subscript implementation here is written as if it returned the value, but the implementation only uses safe constructs:

```swift
struct MyContainer<T> {
  subscript(i: Int) -> borrowing T {
    borrow {
      return innerContainer[i]
    }
  }  
}
```

> Note:  Swift’s implementation of borrowing uses “bitwise borrowing” whenever that would be more efficient than accessing through a pointer.  Formally, “bitwise borrowing” works by invalidating the original value, sharing a copy of that value, then resuscitating the original value when the copy is no longer in use.  Since “invalidating the original value” and “resuscitating the original value” are no-ops at runtime, this can provide the same functionality as “borrow by pointer” while ensuring that borrowing is never less efficient than copying.

#### `mutate`

A `mutate` accessor can be thought of as a “reverse `inout`”.  In fact, some discussions have advocated using the term “inout” for this accessor.  As with `read`, this requires a new return capability that internally returns a reference to the stored value and tracks the lifetime of that reference against the lifetime of the containing value:

```swift
extension Foo {
  var noncopyable: mutating NonCopyableType {
    mutate {
      return ... value stored in some structure ...
    }
  }
}

func access(foo: Foo) -> mutating NonCopyableType {
  return foo.noncopyable
}
```

## Status and Next Steps

The current status of the accessors described above is:

* `get`/`set` are fully supported, standard parts of the Swift language.
* `_read` / `_modify` have been implemented in the compiler for some time as an experimental form of `read`/`modify`.  The underscored forms will continue to be supported in the compiler for the foreseeable future until all existing users have migrated.
* `read`/`modify` will be the final standard form.  We expect to have these implemented in the compiler and ready for Swift Evolution review in the coming months.
* `unsafeAddress`, `unsafeMutableAddress` are implemented in the compiler today (with some limitations).  We do not expect to ever submit them for Swift Evolution review.
* We hope to have experimental implementations of `borrow` and `mutate` in another year or two and submit them for Swift Evolution at that time.

There are a number of open questions that will need to be resolved in the process of implementing the above:

* Protocols can specify `get` and `set` requirements for properties.  We will want them to be able to specify other accessor types as well.
* The current experimental `_read` and `_modify` implementation has some performance problems with certain types of generic code.  We will want to resolve this for the final `read` and `modify` implementation.
* The `borrow` and `mutate` accessor implementations will require new return value conventions to be fully useful.

Of course, everything in this document is subject to community review through the Swift Evolution process.
