# Move Operation + "Use After Move" Diagnostic

* Proposal: [SE-0366](0366-move-function.md)
* Authors: [Michael Gottesman](https://github.com/gottesmm), [Andrew Trick](https://github.com/atrick), [Joe Groff](https://github.com/jckarter)
* Review Manager: [Holly Borla](https://github.com/hborla)
* Status: **Active Review (July 25...August 8, 2022)**
* Implementation: Implemented on main as stdlib SPI (`_move` function instead of `move` keyword)
* Review: ([pitch](https://forums.swift.org/t/pitch-move-function-use-after-move-diagnostic)) ([review](https://forums.swift.org/t/se-0366-move-function-use-after-move-diagnostic/59202))
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/567fb1a66c784bcc5394491d24f72a3cb393674f/proposals/0366-move-function.md)

## Introduction

In this document, we propose adding a new operation, marked by the
context-sensitive keyword `move`, to the
language. `move` ends the lifetime of a specific local `let`,
local `var`, or `consuming` function parameter, and enforces this
by causing the compiler to emit a diagnostic upon any use after the
move. This allows for code that relies on **forwarding ownership**
of values for performance or correctness to communicate that requirement to
the compiler and to human readers. As an example:

```swift
useX(x) // do some stuff with local variable x

// Ends lifetime of x, y's lifetime begins.
let y = move x // [1]

useY(y) // do some stuff with local variable y
useX(x) // error, x's lifetime was ended at [1]

// Ends lifetime of y, destroying the current value.
move y // [2]
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

## Proposed solution: Move Operation + "Use After Move" Diagnostic

That is where the `move` operation comes into play. `move` consumes
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
  consumeFinalY(move y)

  // x will be unique again here.
  x.append(7)
}
```

This addresses both of the motivating issues above: `move` guarantees the
lifetime of `y` ends at the given point, allowing the compiler to generate
code to clean up or transfer ownership of `y` without relying on optimization.
Furthermore, if a future maintainer modifies the code in a way that extends
the lifetime of `y` past the expected point, then the compiler will raise an
error. For instance, if a maintainer later introduces an additional use of
`y` after the move, it will raise an error:

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
  consumeFinalY(move y)

  // ...and x will be unique again here...
  x.append(7)

  // ...but this additional use of y snuck in:
  useYAgain(y) // error: 'y' used after being moved
}
```

`move` only ends the lifetime of a specific movable binding.  It is not tied to
the lifetime of the value of the binding at the time of the move, or to any
particular object instance. If we declare another local constant `other` with
the same value of `x`, we can use that other binding after we end the lifetime
of `x`, as in:

```swift
func useX(_ x: SomeClassType) -> () {}

func f() {
  let x = ...
  useX(x)
  let other = x   // other is a new binding used to extend the lifetime of x
  move x // x's lifetime ends
  useX(other)     // other is used here... no problem.
  useX(other) // other is used here... no problem.
}
```

In fact, each movable binding's lifetime is tracked independently, and gets a
separate diagnostic if used after move. We can move `other` independently
of `x`, and get separate diagnostics for both variables:

```swift
func useX(_ x: SomeClassType) -> () {}

func f() {
  let x = ...
  useX(x)
  let other = x
  move x
  useX(move other)
  useX(other) // error: 'other' used after being moved
  useX(x) // error: 'x' used after being moved
}
```

If a local `var` is moved, then a new value can be assigned into
the variable after an old value has been moved out. One can
begin using the var again after one re-assigns to the var:

```swift
func f() {
  var x = getValue()
  move x
  useX(x) // error: no value in x
  x = getValue()
  useX(x) // ok, x has a new value here
}
```

This follows from move being applied to the binding (`x`), not the value in the
binding (the value returned from `getValue()`).

We also support `move` of function arguments:

```swift
func f(_ x: SomeClassType) {
    move x
    useX(x) // !! Error! Use of x after move
}
```

This includes `inout` function arguments. Like a `var`, an `inout` argument can
be reassigned after being moved from and used again; however, since the final
value of an `inout` argument is passed back to the caller, an `inout` argument
*must* be reassigned by the callee before it returns. This will raise an error
because `buffer` doesn't have a value at the point of return:

```swift
func f(_ buffer: inout Buffer) { // error: 'buffer' not reinitialized after move!
  let b = move buffer           // note: move was here
  b.deinitialize()
  ... write code ...
}                                // note: return without reassigning inout argument `buffer`
```

But we can reinitialize `buffer` by writing the following code:

```swift
func f(_ buffer: inout Buffer) {
  let b = move buffer
  b.deinitialize()
  // ... write code ...
  // We re-initialized buffer before end of function so the checker is satisfied
  buffer = getNewInstance()
}
```

`defer` can also be used to reinitialize an `inout` or `var` after a move,
in order to ensure that reassignment happens on any exit from scope, including
thrown errors or breaks out of loops. So we can also write:

```swift
func f(_ buffer: inout Buffer) {
  let b = move buffer
  // Ensure the buffer is reinitialized before we exit.
  defer { buffer = getNewInstance() }
  try b.deinitializeOrError()
  // ... write code ...
}
```

## Detailed design

At runtime, `move value` evaluates to the current value bound to `value`.
However, at compile time, the presence of a `move` forces
ownership of the argument to be transferred out of the binding at the given
point, and triggers diagnostics that prove that it is safe to do so.
The compiler flags any proceeding uses of the binding that are reachable from
the move.  The operand to `move` is required to be a reference to a *movable
binding*.  The following kinds of declarations can currently be referenced as
movable bindings:

- a local `let` constant in the immediately-enclosing function,
- a local `var` variable in the immediately-enclosing function,
- one of the immediately-enclosing function's parameters, or
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
  let y = move x
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
that are dominated by the reinitialization. Consider the
following example:

```swift
if condition {
  move x
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

`move` behaves as a contextual keyword. In order to avoid interfering
with existing code that calls functions named `move`, the operand to
`move` must begin with another identifier, and must consist of an
identifier or postfix expression:

```
move x // OK
move [1, 2, 3] // Syntax error
move(x) // Call to global function `move`, not a move operation
move x.y.z // Syntactically OK (although x.y.z is not currently a movable binding)
move x[0] // Syntactically OK (although x[0] is not currently a movable binding)
move x + y // Parses as (move x) + y
```

## Effect on ABI stability

`move` requires no ABI additions.

## Effect on API resilience

None, this is additive.

## Alternatives considered

### Alternative spellings

The [first reviewed revision](https://github.com/apple/swift-evolution/blob/567fb1a66c784bcc5394491d24f72a3cb393674f/proposals/0366-move-function.md)
of this proposal offered `move(x)` as a special
function with semantics recognized by the compiler. Based on initial feedback,
we pivoted to the contextual keyword spelling.
As a function, `move` would be rather unusual, since it only accepts certain
forms of expression as its argument, and it doesn't really have any runtime
behavior of its own, acting more as a marker for the compiler to perform
additional analysis.

Many have suggested alternative spellings that
also make `move`'s special nature more syntactically distinct, including:

- an expression attribute, like `useX(@move x)`
- a compiler directive, like `useX(#move x)`
- an operator, like `useX(<-x)`

### The name `move`

There are also potentially other names besides `move` that we could use. We're
proposing using the name `move` because it is an established term of art in
other programming language communities including C++ and Rust, as well as a
term that has already been used in other Swift standard library APIs such as
the `UnsafeMutablePointer.move*` family of methods that move a value out of
memory referenced by a pointer.

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

func foo(x: TwoStrings) {
  use(move x.first)
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

### Suppressing implicit copying

Another useful tool for programmers is to be able to suppress Swift's usual
implicit copying rules for a type, specific values, or a scope. The `move` function
as proposed is not intended to be a replacement for move-only types or for
"no-implicit-copy" constraints on values or scopes. The authors believe that
there is room in the language for both features; `move` is a useful incremental
annotation for code that is value type- or object-oriented which needs
minor amounts of fine control for performance. Suppressing implicit copies can
ultimately achieve the same goal, but requires adapting to a stricter
programming model and controlling ownership in order to avoid the need for
explicit copies or to eliminate copies entirely. That level of control
definitely has its place, but requires a higher investment than we expect
`move` to.

### `shared` and `owned` argument modifiers

The ownership convention used when passing arguments by value is usually
indefinite; the compiler initially tries passing arguments by borrow, so
that the caller is made to keep the value alive on the callee's behalf for
the duration of the call, with the exception of setters and initializers, where
it defaults to transferring ownership of arguments from the caller to the callee.
The optimizer may subsequently adjust these decisions if it sees opportunities
to reduce overall ARC traffic. Using `move` on an argument that ends up
passed by borrow can syntactically shorten the lifetime of the argument binding,
but can't actually shorten the lifetime of the argument at runtime, since the
borrowed value remains owned by the caller.

In order to guarantee the forwarding of a value's ownership across function
calls, `move` is therefore not sufficient on its own. We would also need to
guarantee the calling convention for the enclosing function transfers ownership
to the callee. We could add annotations which behave similar to `inout`. These
are currently implemented internally in the compiler as `__shared` and `__owned`,
and we could expose these as official language features:

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
  consumeFinalY(move y)

  // x will be unique again here.
  x.append(7)
}

// consumeFinalY declares its argument `owned`, ensuring it takes ownership
// of the argument from the caller.
func consumeFinalY(y: owned [Int]) {
  consumeYSomewhereElse(move y)
}
```

The presence of a `move` could be used as an optimizer hint to infer that
`owned` convention is desired within a module, but since the choice of `shared`
or `owned` affects ABI, we would need an explicit annotation for public API
to specify the desired ABI. There are also reasons to expose these
conventions beyond `move`. We leave it to a future dedicated proposal to
delve deeper into these modifiers.

## Acknowledgments

Thanks to Nate Chandler, Tim Kientzle, and Holly Borla for their help with this!

## Revision history

Changes from the [first revision](https://github.com/apple/swift-evolution/blob/567fb1a66c784bcc5394491d24f72a3cb393674f/proposals/0366-move-function.md):

- `move x` is now proposed as a contextual keyword, instead of a magic function
  `move(x)`.
- The proposal no longer mentions `__owned` or `__shared` parameters, which
  are currently an experimental language feature, and leaves discussion of them
  as a future direction. `move x` is allowed to be used on all function
  parameters.
- `move x` is allowed as a statement on its own, ignoring the return value,
  to release the current value of `x` without forwarding ownership without
  explicitly assigning `_ = move x`.
