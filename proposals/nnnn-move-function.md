# Move Function + "Use After Move" Diagnostic

* Proposal: [SE-NNNN](nnnn-move-function.md)
* Authors: [Michael Gottesman](https://github.com/gottesmm), [Andrew Trick](https://github.com/atrick)
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
local `var`, or `consuming` parameter. In order to enforce this, the compiler will
emit a flow-sensitive diagnostic upon any uses that are after the move
function. As an example:

```
useX(x) // do some stuff with local variable x

// Ends lifetime of x, y's lifetime begins.
let y = move(x) // [1]

useY(y) // do some stuff with local variable y
useX(x) // error, x's lifetime was ended at [1]

// Ends lifetime of y. Since _ is no-op, we perform an actual release here.
let _ = move(y) // [2]
useX(x) // error, x's lifetime was ended at [1]
useY(y) // error, y's lifetime was ended at [2]
```

This allows the user to influence the uniqueness of COW data structures
and reduce retain/release calls in a way that is future-proof against changes
to the language implementation or changes to the source code that unexpectedly
extend the lifetime of moved variables. Consider the following array/uniqueness
example:

```
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

in the example above, without `move`, `y`'s formal lifetime extends to the end of
scope. When we go back to using `x`, although the compiler may optimize
the actual lifetime of `y` to release it after its last use, there isn't
a strong guarantee that it will. Even if the optimizer does what we want,
programmers modifying this code in the future
may introduce new references to `y` that inadvertently extend its lifetime
and break our attempt to keep `x` unique.

Swift-evolution pitch thread: [https://forums.swift.org/t/pitch-move-function-use-after-move-diagnostic](https://forums.swift.org/t/pitch-move-function-use-after-move-diagnostic)


## Proposed solution: Move Function + "Use After Move" Diagnostic

That is where the `move` function comes into play. The `move` function is a new
generic stdlib function that when given a local let, local var, or parameter
argument provides a compiler guarantee to the programmer that the binding will
be unable to be used again locally. If such a use occurs, the compiler will emit
an error diagnostic. We can modify the previous example to use `move` to
explicitly end the lifetime of `y` when we're done with it:

```
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

```
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

```
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

Note that `move` only ends the lifetime of a specific local variable binding.
It is not tied to the lifetime of the underlying value or any particular
object instance. If we assign another binding `other` to the same value of `x`,
we can use that other binding after we end the lifetime of `x`, as in:

```
func useX(_ x: SomeClassType) -> () {}
func consumeX(_ x: __owned SomeClassType) -> () {}

func f() -> () {
  let x = ...
  useX(x)
  let other = x   // other is a new binding used to extend the lifetime of x
  _ = move(x) // x's lifetime ends
  useX(other)     // other is used here... no problem.
  consumeX(other) // other is used here... no problem.
}
```

In fact, each variable's lifetime is tracked independently, and gets a separate
diagnostic if used after move. If we try to compile this:

```
func useX(_ x: SomeClassType) -> () {}
func consumeX(_ x: __owned SomeClassType) -> () {}

func f() -> () {
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

```
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

```
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

```
func f(_ x: __owned SomeClassType) {
    let _ = move(x)
    useX(x) // !! Error! Use of x after move
}
```

Normal arguments are passed by borrow, meaning that the lifetime of the value
is managed by the caller. Although we could allow `move` on these arguments,
shortening the syntactic lifetime of the variable, doing so would have no
practical effect on the value's lifetime at runtime, so we choose to leave this
disallowed for now.

On the other hand, one can `move` out of an `inout`
function argument. Like a `var`, the `inout` argument can be reassigned after
being moved from and used again; however, since the final value of an
`inout` argument is passed back to the caller, an `inout` argument *must* be
reassigned by the callee before it returns:

```
func f(_ buffer: inout Buffer) { // error: 'buffer' not reinitialized after move!
  let b = move(buffer)           // note: move was here
  b.deinitialize()
  ... write code ...
}                                // note: return without reassigning inout argument `buffer`
```

But we can to re-initialize `buffer` by writing the following code:

```
func f(_ buffer: inout Buffer) {
  let b = move(buffer)
  b.deinitialize()
  // ... write code ...
  // We re-initialized buffer before end of function so the checker is satisfied
  buffer = getNewInstance()
}
```

Move analysis understands that `defer` statements run before every scope exit,
so `defer` can also be used to reinitialize an `inout` or `var` after a move.
So we can also write the above as:

```
func f(_ buffer: inout Buffer) {
  let b = move(buffer)
  // Ensure the buffer is reinitialized before we exit.
  defer { buffer = getNewInstance() }
  b.deinitialize()
  // ... write code ...
}
```


In the future, we may add support for globals and stored properties, although
doing so in full generality would require dynamic enforcement in addition to
static checking to ensure that shared state is not read from once it is moved,
similar to how we need to dynamically enforce exclusivity when accessing
globals and class stored properties. For now, `move` will raise an error when
applied to something we cannot statically analyze, so this code:

```
var global = SomeClassType()
func f() {
  let _ = move(global)
}
```

would complain:

```
test.swift:9:11: error: move applied to value that the compiler does not support checking
  let _ = move(global)
          ^
```

## Detailed design

We define move as follows:

```
/// This function ends the lifetime of the passed in binding.
@_transparent
@alwaysEmitIntoClient
func move<T>(_ t: __owned T) -> T {
  Builtin.move(t)
}
```

Builtin.move is a hook in the compiler to force emission of special SIL "move"
instructions. These move instructions trigger in the SILOptimizer two special
diagnostic passes that prove that the underlying binding does not have any uses
that are reachable from the move using a flow sensitive dataflow. Since it is
flow sensitive, one is able to end the lifetime of a value conditionally:

```
if (...) {
  let y = move(x)
  // I can't use x anymore here!
} else {
  // I can still use x here!
}
// But I can't use x here.
```

This works because the diagnostic passes are able to take advantage of
control-flow information already tracked by the optimizer to identify all places
where a variable use could possible following passing the variable to as an
argument to `move()`.

In practice, the way to think about this dataflow is to think about paths
through the program. Consider our previous example with some annotations:

```
let x = ...
// [PATH1][PATH2]
if (...) {
  // [PATH1] (if true)
  let _ = move(x)
  // I can't use x anymore here!
} else {
  // [PATH2] (else)
  // I can still use x here!
}
// [PATH1][PATH2] (continuation)
// But I can't use x here.
```

in this example, there are only 2 program paths, the `[PATH1]` that goes through
the if true scope and into the continuation and `[PATH2]` through the else into
the continuation. Notice how the move only occurs along `[PATH1]` but that since
`[PATH1]` goes through the continuation that one can not use x again in the
continuation despite `[PATH2]` being safe.

If one works with vars, the analysis is exactly the same except that one can
conditionally re-initialize the var and thus be able to use it in the
continuation path. Consider the following example:

```
var x = ...
// [PATH1][PATH2]
if ... {
  // [PATH1] (if true)
  let _ = move(x)
  // I can't use x anymore here!
  useX(x) // !! ERROR! Use after move.
  x = newValue
  // But now that I have re-assigned into x a new value, I can use the var
  // again.
} else {
  // [PATH2] (else)
  // I can still use x here!
}
// [PATH1][PATH2] (continuation)
// Since I reinitialized x along [PATH1] I can reuse the var here.
```

Notice how in the above, we are able to use `x` both in the true block AND the
continuation block since over all paths, x now has a valid value.

The value based analysis uses Ownership SSA to determine if values are used
after the move and handles non-address only lets. The address based analysis is
an SSA based analysis that determines if any uses of an address are reachable
from a move. All of these are already in tree and can be used today by invoking
the stdlib non-API function `_move` on a local let or move. *NOTE* This function
is always emit into client and transparent so there isn't an ABI impact so it is
safe to have it in front of a flag.

## Source compatibility

This is additive. If a user already in their module has a function called
"move", they can call the Stdlib specific move by calling Swift.move.

## Effect on ABI stability

None, move will always be a transparent always emit into client function.

## Effect on API resilience

None, this is additive.

## Alternatives considered

### Alternative spellings

As a function, `move` is rather unusual, since it only accepts certain forms of
variable bindings as its argument, and doesn't really have any runtime behavior
of its own, acting more as a marker for the compiler to perform additional
analysis. As such, many have suggested alternative spellings that make `move`'s
special natural more syntactically distinct, including:

- a contextual keyword operator, like `useX(move x)`
- an expression attribute, like `useX(@move x)`
- a compiler directive, like `useX(#move(x))`

There are also potentially other names besides `move` that we could use. We're
proposing using the name `move` because it is an established term of art in
other programming language communities including C++ and Rust, as well as a
term that has already been used in other Swift standard library APIs such as
the `UnsafeMutablePointer.move*` family of methods that move a value out of
memory referenced by a pointer. Declaring it as a function also minimizes the
potential impact to the language syntax. We are however open to discussing
alternative names and syntaxes during the evolution process.

### `drop` function

We could also introduce a separate `drop` function like languages like Rust does
that doesn't have a result like `move` does. We decided not to go with this
since in Swift the idiomatic way to throw away a value is to assign to `_`
implying that the idiomatic way to write `drop` would be:

```
_ = move(x)
```

suggesting adding an additional API would not be idiomatic.

## Acknowledgments

Thanks to Nate Chandler, Tim Kientzle, Joe Groff for their help with this!
