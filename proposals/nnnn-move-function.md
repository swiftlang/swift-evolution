# Move Function + "Use After Move" Diagnostic

* Proposal: [SE-NNNN](nnnn-move-function.md)
* Authors: [Michael Gottesman](https://github.com/gottesmm), [Andrew Trick](https://github.com/atrick), [Joe Groff](https://github.com/jckarter)
* Review Manager: TBD
* Status: Implemented on main as stdlib SPI (`_move` instead of `move`)

<!--
*During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction

In this document, we propose adding a new function called `move` to the swift
standard library, which ends the lifetime of a specific local `let`,
local `var`, or `consuming` function parameter, and which enforces this
by causing the compiler to emit a diagnostic upon any uses that are after the
move function. This allows for code that relies on **forwarding ownership**
of values for performance or correctness to communicate that requirement to
the compiler and to human readers. As an example:

```swift
useX(x) // do some stuff with local variable x

// Ends lifetime of x, y's lifetime begins.
let y = move(x) // [1]

useY(y) // do some stuff with local variable y
useX(x) // error, x's lifetime was ended at [1]

// Ends lifetime of y, destroying the current value
// since it is explicitly thrown away assigning to `_`
_ = move(y) // [2]
useX(x) // error, x's lifetime was ended at [1]
useY(y) // error, y's lifetime was ended at [2]
```

## Motivation

Swift uses reference counting and copy-on-write to allow for developers to
write code with value semantics, without normally having to worry too much
about performance or memory management. However, in performance sensitive code,
developers want to be able to control the uniqueness of COW data structures and
reduce retain/release calls in a way that is future-proof against changes to
the language implementation or source code. Consider the following array/uniqueness
example:

```swift
func test() {
  var x: [Int] = getArray()
  
  // x is appended to. After this point, we know that x is unique. We want to
  // preserve that property.
  x.append(5)
  
  // We create a new variable y so we can write an algorithm where we may
  // change the value of y (causing a COW copy of the buffer shared with x).
  var y = x
  longAlgorithmUsing(&y)
  consumeFinalY(y)

  // We no longer use y after this point. Ideally, x would be guaranteed
  // unique so we know we can append again without copying.
  x.append(7)
}
```

In the example above, `y`'s formal lifetime extends to the end of
scope. When we go back to using `x`, although the compiler may optimize
the actual lifetime of `y` to release it after its last use, there isn't
a strong guarantee that it will. Even if the optimizer does what we want,
programmers modifying this code in the future
may introduce new references to `y` that inadvertently extend its lifetime
and break our attempt to keep `x` unique. There isn't any indication in the
source code that that the end of `y`'s use is important to the performance
characteristics of the code.

Swift-evolution pitch thread: [https://forums.swift.org/t/pitch-move-function-use-after-move-diagnostic](https://forums.swift.org/t/pitch-move-function-use-after-move-diagnostic)

## Proposed solution: Move Function + "Use After Move" Diagnostic

That is where the `move` function comes into play. The `move` function consumes
a **movable binding**, which is either
an unescaped local `let`, unescaped local `var`, or function argument, with
no property wrappers or get/set/read/modify/etc. accessors applied. It then
 provides a compiler guarantee that the binding will
be unable to be used again locally. If such a use occurs, the compiler will
emit an error diagnostic. We can modify the previous example to use `move` to
explicitly end the lifetime of `y` when we're done with it:

```swift
func test() {
  var x: [Int] = getArray()
  
  // x is appended to. After this point, we know that x is unique. We want to
  // preserve that property.
  x.append(5)
  
  // We create a new variable y so we can write an algorithm where we may
  // change the value of y (causing a COW copy of the buffer shared with x).
  var y = x
  longAlgorithmUsing(&y)
  // We no longer use y after this point, so move it when we pass it off to
  // the last use.
  consumeFinalY(move(y))

  // x will be unique again here.
  x.append(7)
}
```

This addresses both of the motivating issues above: `move` guarantees the
lifetime of `y` ends at the given point, allowing the compiler to generate
code to clean up or transfer ownership of `y` without relying on optimization.
Furthermore, if a future maintainer modifies the code in a way that extends
the lifetime of `y` past the expected point, then the compiler will raise an
error. For instance, if we try:

```swift
func test() {
  var x: [Int] = getArray()
  
  // x is appended to. After this point, we know that x is unique. We want to
  // preserve that property.
  x.append(5)
  
  // We create a new variable y so we can write an algorithm where we may
  // change the value of y (causing a COW copy of the buffer shared with x).
  var y = x
  longAlgorithmUsing(&y)
  // We think we no longer use y after this point...
  consumeFinalY(move(y))

  // ...and x will be unique again here...
  x.append(7)

  // ...but this additional use of y snuck in:
  useYAgain(y)
}
```

In this case, we get the following output from the compiler as expected:

```swift
test.swift:10:7: error: 'y' used after being moved
  var y = x
      ^
test.swift:13:17: note: move here
  consumeFinalY(move(y))
                ^
test.swift:19:13: note: use here
  useYAgain(y)
            ^
```

Note how the compiler gives all of the information that we need to resolve
this: it says where the move was and where the later uses that
cause the problem are, alerting the programmer to what parts of the code are
trying to extend the lifetime of the value beyond our expected endpoint.

Note that `move` only ends the lifetime of a specific movable binding.
It is not tied to the lifetime of the value of the binding or to any particular
object instance. If we declare another local constant `other` with the same
value of `x`, we can use that other binding after we end the lifetime of `x`,
as in:

```swift
func useX(_ x: SomeClassType) -> () {}
func consumeX(_ x: __owned SomeClassType) -> () {}

func f() {
  let x = ...
  useX(x)
  let other = x   // other is a new binding used to extend the lifetime of x
  _ = move(x) // x's lifetime ends
  useX(other)     // other is used here... no problem.
  consumeX(other) // other is used here... no problem.
}
```

In fact, each movable binding's lifetime is tracked independently, and gets a separate
diagnostic if used after move. If we try to compile this:

```swift
func useX(_ x: SomeClassType) -> () {}
func consumeX(_ x: __owned SomeClassType) -> () {}

func f() {
  let x = ...
  useX(x)
  let other = x
  let _ = move(x)
  useX(move(other))
  consumeX(other)
  useX(x)
}
```

we get separate diagnostics for each variable:

```swift
test.swift:7:15: error: 'x' used after being moved
  let x = ...
          ^
test.swift:10:11: note: move here
  let _ = move(x)
          ^
test.swift:13:3: note: use here
  useX(x)
  ^
test.swift:9:7: error: 'other' used after being moved
  let other = x
      ^
test.swift:11:8: note: move here
  useX(move(other))
       ^
test.swift:12:3: note: use here
  consumeX(other)
  ^
```

If one applies move to a local `var`, then a new value can be assigned into
the variable after an old value has been moved out. One can
begin using the var again after one re-assigns to the var:

```swift
func f() {
  var x = getValue()
  let _ = move(x)
  useX(x) // error: no value in x
  x = getValue()
  useX(x) // ok, x has a new value here
}
```

This follows from move being applied to the binding (`x`), not the value in the
binding (the value returned from `getValue()`).

We also support applying the move operation to consuming function arguments:

```swift
func f(_ x: __owned SomeClassType) {
    let _ = move(x)
    useX(x) // !! Error! Use of x after move
}
```

Normal arguments are passed by borrow, meaning that the lifetime of the value
is managed by the caller. Although we could allow `move` on these arguments,
shortening the syntactic lifetime of the variable, doing so would have no
practical effect on the value's lifetime at runtime, so we choose to leave this
disallowed for now, in order to avoid potentially misleading developers who
might expect the value to be destroyed at the point of the move.

On the other hand, one can `move` out of an `inout`
function argument. Like a `var`, the `inout` argument can be reassigned after
being moved from and used again; however, since the final value of an
`inout` argument is passed back to the caller, an `inout` argument *must* be
reassigned by the callee before it returns. This will raise an error because
`buffer` doesn't have a value at the point of return:

```swift
func f(_ buffer: inout Buffer) { // error: 'buffer' not reinitialized after move!
  let b = move(buffer)           // note: move was here
  b.deinitialize()
  ... write code ...
}                                // note: return without reassigning inout argument `buffer`
```

But we can reinitialize `buffer` by writing the following code:

```swift
func f(_ buffer: inout Buffer) {
  let b = move(buffer)
  b.deinitialize()
  // ... write code ...
  // We re-initialized buffer before end of function so the checker is satisfied
  buffer = getNewInstance()
}
```

`defer` can also be used to reinitialize an `inout` or `var` after a move.
So we can also write the above as:

```swift
func f(_ buffer: inout Buffer) {
  let b = move(buffer)
  // Ensure the buffer is reinitialized before we exit.
  defer { buffer = getNewInstance() }
  try b.deinitialize()
  // ... write code ...
}
```

## Detailed design

We declare `move` as follows:

```swift
/// This function ends the lifetime of the passed in binding.
func move<T>(_ value: __owned T) -> T
```

At runtime, the function returns `value` unmodified back to its caller.
However, at compile time, the presence of a call to `move` forces
ownership of the argument to be transferred out of the binding at the given
point, and triggers diagnostics that prove that it is safe to do so,
by flagging any proceeding uses of the binding that are reachable from the move.
The argument to `move` is required to be a reference to a *movable binding*.
The following kinds of declarations can currently be referenced as movable
bindings:

- a local `let` constant in the immediately-enclosing function,
- a local `var` variable in the immediately-enclosing function,
- one of the immediately-enclosing function's parameters that
  has the `__owned` or `inout` ownership modifier, or
- the `self` parameter in a `mutating` or `__consuming` method.

A movable binding also must satisfy the following requirements:

- it cannot be captured by an `@escaping` closure or nested function,
- it cannot have any property wrappers applied,
- it cannot have any accessors attached, such as `get`, `set`,
  `didSet`, `willSet`, `_read`, or `_modify`,
- it cannot be an `async let`.

Possible extensions to the set of movable bindings are discussed under
Future Directions. It is an error to pass `move` an argument that doesn't
reference a movable binding.

Given a valid movable binding, the compiler ensures that there are no other
references to the binding after it is moved. The analysis is
flow sensitive, so one is able to end the lifetime of a value conditionally:

```swift
if condition {
  let y = move(x)
  // I can't use x anymore here!
  useX(x) // !! ERROR! Use after move.
} else {
  // I can still use x here!
  useX(x) // OK
}
// But I can't use x here.
useX(x) // !! ERROR! Use after move.
```

If the binding is a `var`, the analysis additionally allows for code to
conditionally reinitialize the var and thus be able to use it in positions
that are dominated by the reinitialization.  continuation path. Consider the
following example:

```swift
if condition {
  let _ = move(x)
  // I can't use x anymore here!
  useX(x) // !! ERROR! Use after move.
  x = newValue
  // But now that I have re-assigned into x a new value, I can use the var
  // again.
  useX(x) // OK
} else {
  // I can still use x here, since it wasn't moved on this path!
  useX(x) // OK
}
// Since I reinitialized x along the `if` branch, and it was never moved
// from on the `else` branch, I can use it here too.
useX(x) // OK
```

Notice how in the above, we are able to use `x` both in the true block AND the
code after the `if` block, since over both paths through the `if`, `x` ends up
with a valid value before proceeding.

For an `inout` parameter, the analysis behaves the same as for a `var`, except
that all exits from the function (whether by `return` or by `throw`) are
considered to be uses of the parameter. Correct code therefore *must* reassign
inout parameters after they are moved from.

## Source compatibility

This is additive. If a user already in their module has a function called
"move", they can call the Stdlib specific move by calling Swift.move.

## Effect on ABI stability

`move` will use the `@_alwaysEmitIntoClient` attribute, so that it adds no
ABI requirements to the standard library or clients.

## Effect on API resilience

None, this is additive.

## Alternatives considered

### Alternative spellings

As a function, `move` is rather unusual, since it only accepts certain forms of
expression as its argument, and it doesn't really have any runtime behavior
of its own, acting more as a marker for the compiler to perform additional
analysis. As such, many have suggested alternative spellings that make `move`'s
special nature more syntactically distinct, including:

- a contextual keyword operator, like `useX(move x)`
- an expression attribute, like `useX(@move x)`
- a compiler directive, like `useX(#move(x))`

There are also potentially other names besides `move` that we could use. We're
proposing using the name `move` because it is an established term of art in
other programming language communities including C++ and Rust, as well as a
term that has already been used in other Swift standard library APIs such as
the `UnsafeMutablePointer.move*` family of methods that move a value out of
memory referenced by a pointer.

Declaring `move` as a function also minimizes the potential impact to the
language syntax. We've introduced new contextual keywords without breaking
compatibility before, like `some` and `any` for types. But to do so, we've had
to impose constraints on their use, such as not allowing the constraints
modified by `some` or `any` to be parenthesized to avoid the result looking
like a function call. Although that would be acceptable for `move` given its
current constraints, it might be premature to assume we won't expand the
capabilities of `move` to include more expression forms.

### `drop` function

We could also introduce a separate `drop` function like languages like Rust does
that doesn't have a result like `move` does. We decided not to go with this
since in Swift the idiomatic way to throw away a value is to assign to `_`
implying that the idiomatic way to write `drop` would be:

```swift
_ = move(x)
```

suggesting adding an additional API would not be idiomatic. We do not propose
making `move` use the `@discardableResult` attribute, so that this kind of
standalone drop is syntactically explicit in client code.


## Future directions

### Dynamic enforcement of `move` for other kinds of bindings

In the future, we may expand the set of movable bindings to include globals,
escaped local variables, and class stored properties, although doing so in full
generality would require dynamic enforcement in addition to static checking to
ensure that shared state is not read from once it is moved, similar to how we
need to dynamically enforce exclusivity when accessing globals and class stored
properties. Since this dynamic enforcement turns misuse of `move`s into runtime
errors rather than compile-time guarantees, we might want to make those dynamic
cases syntactically distinct, to make the possibility of runtime errors clear.

### Piecewise `move` of frozen structs and tuples

For frozen structs and tuples, both aggregates that the compiler can statically
know the layout of, we could do finer-grained analysis and allow their
individual fields to be moved independently:

```swift
struct TwoStrings {
  var first: String
  var second: String
}

func foo(x: __owned TwoStrings) {
  use(move(x.first))
  // ERROR! part of x was moved out of
  use(x)
  // OK, this part wasn't
  use(x.second)
}
```

### `move` of computed properties, property wrappers, properties with accessors, etc.

It would potentially be useful to be able to move variables and properties with
modified access behavior, such as computed properties, properties with
didSet/willSet observers, property wrappers, and so on. Although we could do
move analysis on these properties, we wouldn't be able to get the full
performance benefits from consuming a computed variable without allowing
for some additional accessors to be defined, such as a "consuming getter" that
can consume its `self` in order to produce the property value, and an
initializer to reinitialize `self` on reassignment after a `move`.

## Acknowledgments

Thanks to Nate Chandler, Tim Kientzle, and Holly Borla for their help with this!
