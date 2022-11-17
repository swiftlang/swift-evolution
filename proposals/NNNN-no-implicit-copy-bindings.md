# `@noImplicitCopy` variable bindings and parameters

* Proposal: [SE-NNNN](NNNN-no-implicit-copy-bindings.md)
* Authors: [Joe Groff](https://github.com/jckarter), [Andrew Trick](https://github.com/swiftdev)
* Review Manager: TBD
* Status: **Implemented** as `@_noImplicitCopy`

## Introduction

We propose to introduce an attribute, `@noImplicitCopy`, which can be
applied to variable bindings and function parameters to suppress the
language's ability to copy the value bound to the variable.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

Swift normally automatically manages the lifetime of values; value semantics
allow for common types to be transparently copied as needed to preserve language
semantics, and ARC is used to manage the lifetime of heap-allocated objects.
This provides a high-level programming model, but performance sensitive code
wants to reliably minimize these copies, and developers have
found it challenging both to eliminate copies from a block of code in the first
place, and to ensure that innocuous-looking changes don't reintroduce copies as
the code evolves.

Although mechanisms exist for developers to take manual control of copying, reference
counting, and memory management, they are largely
unsafe, such as `Unmanaged` and `Unsafe*Pointer`, and often require rewriting
APIs to expose unsafety to clients. We plan to introduce
move-only types, which can never be copied, but making a type move-only affects
all values of that type, and making an existing type move-only just to get
control of its copying behavior will be a very disruptive API change.
Other language features like the
[`take` operator](0366-move-function.md) can provide spot control for some
copies, but developers should also have the means to take complete control of
copying behavior in sensitive parts of their code bases without compromising on
safety or imposing nonlocal changes to their APIs.

## Proposed solution

We propose introducing an attribute, `@noImplicitCopy`, to prevent the compiler
from introducing implicit copies in certain situations. To begin with, we
propose allowing `@noImplicitCopy` to be applied to local `let` bindings and to
non-`inout` function parameters, to prevent the value bound to the attributed
binding from being implicitly copied. We also propose a contextual keyword
operator, `copy x`, which can be used to explicitly allow a copy.

For example: 

```swift
func uncopyableParameter(@noImplicitCopy x: String) {
  // ERROR: copying x to mutated variable y
  var y = x
  y += x
  print(y)
}

func uncopyableLocalVariable(x: String) {
  // OK
  var y = x
  y += x
  print(y)

  // ERROR: copying x2 to mutated variable y2
  @noImplicitCopy let x2 = x
  var y2 = x2
  y2 += x2
  print(y2)
}
```

## Detailed design

The `@noImplicitCopy` attribute can be applied to local `let` bindings
(but not `var`) or to parameters that have `borrow` or `take` ownership (but
not `inout`). (Extending to mutable bindings is discussed as a future direction.)

### Non-transitivity

One key property of the `@noImplicitCopy` annotation is that it is
*non-transitive*. Only the binding with the attribute is restricted, but
its value can be moved into other bindings, or passed in an argument to other
functions, and those other bindings are not affected by the constraint.

```swift
// This is fine, `value` is implicitly copyable
func duplicate<T>(_ value: T) -> (T, T) { return (value, value) }

func foo(@noImplicitCopy x: String) {
  // We can pass `x` into `duplicate` even though it copies `value` internally
  let (y, z) = duplicate(x)
}
```

This allows for `@noImplicitCopy` to be used selectively without globally
affecting code that doesn't require the constraint.

### "Eager-move" lifetime semantics

Swift will normally copy values as needed to maintain the apparent formal
lifetime of a binding. However, if a binding cannot be copied, we can no longer
do this, so `@noImplicitCopy` bindings have
additional restrictions on their lifetime that normal bindings do not.
We call these **eager-move semantics** to distinguish from normal binding
lifetime behavior.

When a binding has eager-move semantics, then its value is moved immediately
when there is a **consuming use** of the binding, and the binding cannot
be used after it is consumed. The following operations are
consuming uses (TODO: but this is not currently a complete list):

- assigning the binding to a new binding, or setting an existing variable or
  property to the binding:

    ```swift
    @noImplicitCopy let x = getValue()
    let y = x
    use(x) // ERROR: x consumed by assignment to `y`
    ```

    ```swift
    var y = getValue()
    @noImplicitCopy let x = getValue()
    y = x
    use(x) // ERROR: x consumed by assignment to `y`
    ```

    ```swift
    class C {
      var property = getValue()
    }

    let c = C()
    @noImplicitCopy let x = getValue()
    c.property = x
    use(x) // ERROR: x consumed by assignment to `c.property`
    ```

- capturing the binding into an escaping closure:

    ```swift
    @noImplicitCopy let x = getValue()
    someView.doOldFashionedAsynchronousThing(completion: { use(x) })
    use(x) // ERROR: x consumed by capture into closure
    ```

- passing the binding as an argument to a `take` parameter of a function:

    ```swift
    func consume(_: take Value) {}

    @noImplicitCopy let x1 = getValue()
    consume(x1)
    use(x1) // ERROR: x1 consumed by call to `consume`
    ```

- passing the binding as a parameter to an `init` that is not explicitly
  `borrow`-ing:

    ```swift
    struct S {
      var x: Value, y: Int
    }

    @noImplicitCopy let x = getValue()
    let s = S(x: x, y: 219)
    use(x) // ERROR: x consumed by `init` of struct `S`
    ```

- invoking a `taking` method on the value, or accessing a property of the value
  through a `taking get` or `taking set` accessor:

    ```swift
    extension Value {
      taking func consume()
    }

    @noImplicitCopy let x = getValue()
    x.consume()
    use(x) // ERROR: x consumed by method `consume`
    ```

- explicitly consuming the binding with the `take` operator:

    ```swift
    @noImplicitCopy let x = getValue()
    _ = take x
    use(x) // ERROR: x consumed by explicit `take`
    ```

- pattern-matching a value with `switch`, `if let`, or `if case`:

    ```swift
    @noImplicitCopy let x: Optional = getValue()
    if let y = x { ... }
    use(x) // ERROR: x consumed by `if let`
    ```

- iterating a `Sequence` with a `for` loop:

    ```swift
    @noImplicitCopy let xs = [1, 2, 3]
    for x in xs {}
    use(xs) // ERROR: xs consumed by `for` loop
    ```

This is similar to the situations in which the `take` operator can transfer
ownership of a value.

Consuming is flow-sensitive, so if one branch of an `if` or other control flow
consumes a `@noImplicitCopy` binding, then other branches where the binding
is not consumed may continue using it:

```swift
@noImplicitCopy let x = getValue()

guard let condition = getCondition() else {
  consume(x)
}

// We can continue using x here, since only the exit branch of the guard
// consumed it
use(x)
```

### Borrowing uses

Another consequence of not being able to implicitly copy a binding is that
the effect of *borrowing* the value becomes much more apparent. We have already
established the "law of exclusivity" for `inout` bindings, which *exclusively
borrow* a storage location for the purposes of mutation, preventing any other
code from reading or writing the same storage location while the exclusive
borrow is in place. Less apparent in the language up to this point, *reading*
a value from a storage location performs a *shared borrow* on the location,
allowing other readers to also borrow the same storage to read from, but
preventing any exclusive accesses that might mutate the value. Both forms
of borrow also keep the storage location alive for the duration of the borrow,
preventing it from being consumed.

Shared borrows are less evident in typical Swift code because, for copyable
types, borrowing a copy of a value is almost indistinguishable from
borrowing the original, aside from the overhead of the copy, so the compiler
will introduce copies in any places a borrow violation would be evident. For
instance, a copyable value can normally be passed as an argument to the same
function multiple times, or even both by
`borrow` and by `take` in the same call, and the compiler will copy as
necessary to make all of the function's parameters valid according to their
ownership specifiers:

```
func borrow(_: borrow Value, and _: borrow Value) {}
func consume(_: take Value, butBorrow _: borrow Value) {}

let x = getValue()
borrow(x, and: x) // this is fine, multiple borrows can share
consume(x, butBorrow: x) // also fine, we'll copy x to let a copy be consumed
                         // while the other is borrowed
```

`@noImplicitCopy`, however, forbids this copying behavior. Therefore, passing a
`@noImplicitCopy` binding by borrow means it *must* be borrowed without
copying, and so the binding's lifetime cannot be ended by a consume for the
duration of the borrow, making the above `consume(_:butBorrow:)` call an error:

```
@noImplicitCopy let x = getValue()
borrow(x, and: x) // still OK to borrow multiple times
consume(x, butBorrow: x) // ERROR: consuming use of `x` would end its lifetime
                         // while being borrowed
```

More generally, *any* consuming use of a `@noImplicitCopy` binding is not
allowed while it is being borrowed:

```
func consume(_: take Value) -> Value { ... }

@noImplicitCopy let x = getValue()
borrow(x, and: consume(x)) // ERROR: `x` consumed while being borrowed
```

The following operations are borrowing uses (TODO: not a complete list):

- Passing an argument to a `func` or `subscript` parameter that does not
  have an ownership modifier, or an argument to any `func`, `subscript`, or
  `init` parameter which is explicitly marked `borrow`. The
  argument is borrowed for the duration of the callee's execution.
- Borrowing a stored property of a struct or class borrows the struct or
  object reference for the duration of the access to the stored property.
- Borrowing an element of a tuple borrows only that element from the tuple.
- Invoking a `borrowing` method on a value, or a method which is not annotated
  as any of `borrowing`, `taking` or `mutating`, borrows the `self` parameter
  for the duration of the callee's execution.
- Accessing a computed property through `borrowing` or `nonmutating` getter
  or setter borrows the `self` parameter for the duration of the accessor's
  execution.
- Capturing a local binding into a nonescaping closure borrows the binding
  for the duration of the callee that receives the nonescaping closure.

### `copy` operator

The `copy` operator can be used to allow for a binding's value to be copied,
even if it's annotated with `@noImplicitCopy`.
`copy` takes the value of the binding and produces an independent
copy of the value, which can then be borrowed or consumed from without affecting
the original binding. (The compiler may still optimize out the actual copy if
it ends up unnecessary.)

`copy` can generally be used to suppress errors raised because of borrow
violations or eager-move consumption of a value, by offering a copy of the
value to be consumed or borrowed from in place of the `@noImplicitCopy`
original:

```
@noImplicitCopy let x = getValue()
let y = copy x
use(x) // This is OK, we consumed a copy of `x` instead of the original `x`


func consume(_: take Value, butBorrow _: borrow Value) {}
// This is OK, because we consume the copy of x and leave the original to be
// borrowable.
consume(copy x, butBorrow: x) 
```

## Source compatibility

Using `@noImplicitCopy` locally within a function
does not affect code outside of the function or scope where `@noImplicitCopy`
bindings were declared. Adding or removing the attribute to parameters does
not affect how callers interact with the function.

However, implementation code that uses
`@noImplicitCopy` may be more susceptible to breaking if it in turn uses
functions that change their [ownership
modifiers](0377-parameter-ownership-modifiers.md). For instance, this will
compile successfully:

```swift
func foo(_: String) {}
func bar(_: String) {}
func bas(_: String) {}

func process(@noImplicitCopy value: String) {
  foo(value)
  bar(value)
  bas(value)
}
```

However, if either `foo` or `bar` is later changed to `take` ownership of its
parameter, then the call inside of `process(value:)` will end the lifetime
of `value` according to "eager move" rules, making further references an error:

```swift
func foo(_: String) {}
func bar(_: take String) {}
func bas(_: String) {}

func process(@noImplicitCopy value: String) {
  foo(value)
  bar(value) // consumes `value`
  bas(value) // ERROR: `value` used after being consumed
}
```

## Effect on ABI stability

`@noImplicitCopy` does not outwardly affect the ABI of a function it is used
in. It is safe to add or remove it to parameters or local variables within
the function without affecting callers.

## Effect on API resilience

As noted above, adding or removing `@noImplicitCopy` to parameters does not
affect how callers interact with the function.

## Alternatives considered

### The name of `@noImplicitCopy`

The name `noImplicitCopy` is descriptive, but awkward. We're open to better
names.

### The form and spelling of `copy`

We propose `copy` to be a contextual keyword operator, to align it with the
related [`take` operator](0366-move-function.md) and `borrow` operator. However,
without any special language handling at all, it could also be defined as a
standard library function:

```swift
func copy<T>(_ value: T) -> T { return value }
```

Some reasons not to do this are that `copy` is a fairly common name that the
standard library global function would then be sitting on (or else need
to be qualified as `Swift.copy(x)` when shadowed). It is likely that code
using `@noImplicitCopy` will need to introduce manual copies frequently, so
we want the operation to be concise and consistently spelled.

## Future directions

### Expanding `@noImplicitCopy`'s applicability

The `@noImplicitCopy` attribute can be useful in more contexts than we
initially propose to support, including:

#### `var` bindings and `inout` parameters

Mutable variables and `inout` parameters could also be marked as `@noImplicitCopy`.
This could be taken to mean that the current value bound to the variable cannot
be implicit copied, but it can be taken or replaced with a new value, which
would then also be restricted from being copied out of the variable.

#### Scopes

Since a motivating use case for this feature is performance control in
critical sections or hot parts of code, it could be useful to apply a blanket
"no implicit copies" constraint to a scope, instead of having to individually
annotate every binding used in the scope.

#### Types

A type may need to be copyable, in order to satisfy protocol requirements or
just because it does have a copy operation that makes sense, but it may be
undesirable to copy it in most situations. Therefore, `@noImplicitCopy` may
make sense as a type-level annotation as a way to suppress implicit copying
any values that are statically of the type, while still allowing the type
to be copyable in a way compatible with other copyable types. (An alternative
might be to have the type be move-only but conform to some `ManuallyCopyable`
protocol, but such types would not be able to interact generically with
existing Swift APIs using built-in copyability..)

#### Properties

It would be useful to tag properties of a struct or class, or cases of an enum,
as `@noImplicitCopy`. This would have the consequence of preventing accesses
to the property from introducing implicit copies.

### Variations of language features that borrow instead of consume

It is obviously not ideal for basic operations like binding new variables,
pattern-matching values, and iterating sequences to always consume their
value. We plan to extend the language with the ability to perform these
operations on borrowed and/or `inout` exclusively accessed values:

- `borrow` and `inout` bindings can reference a value without copying,
  respectively borrowing a read-only view of the value or exclusively accessing
  it for mutation:

    ```
    @noImplicitCopy let x = getValue()
    do {
      borrow y = x // not a copy, but a borrow

      use(x) // we can use both x and y
      use(y)

      consume(x) // ERROR: but we can't consume x while y is borrowing it
      use(y)
    }
    ```

- Pattern matching operations should also exist to project out of `Optional`
  values and other enums without consuming the enum:

    ```
    @noImplicitCopy let x: Optional = getValue()

    if borrow y = x {}

    // We can still use x because we only borrowed its payload

    switch x {
    case .some(borrow y):
      break
    }

    use(x)
    ```

- `for` loops should be able to iterate through borrows of value type
  collections without needing to consume the collection, as well as
  iterate through an `inout` collection to mutate elements as it goes.

