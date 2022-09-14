# `borrow` and `take` parameter ownership modifiers

* Proposal: [SE-NNNN](NNNN-parameter-ownership-modifiers.md)
* Authors: [Michael Gottesman](https://github.com/gottesmm), [Joe Groff](https://github.com/jckarter)
* Review Manager: TBD
* Status: **Implemented**, using the internal names `__shared` and `__owned`
* Pitch v1: [https://github.com/gottesmm/swift-evolution/blob/consuming-nonconsuming-pitch-v1/proposals/000b-consuming-nonconsuming.md](https://github.com/gottesmm/swift-evolution/blob/consuming-nonconsuming-pitch-v1/proposals/000b-consuming-nonconsuming.md)

<!--
*During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction

We propose new `borrow` and `take` parameter modifiers to allow developers to
explicitly choose the ownership convention that a function uses to receive
immutable parameters. This allows for fine-tuning of performance by reducing
the number of ARC calls or copies needed to call a function, and provides a
necessary prerequisite feature for move-only types to specify whether a function
consumes a move-only value or not.

Pitch threads:

- First pitch thread: [https://forums.swift.org/t/pitch-formally-defining-consuming-and-nonconsuming-argument-type-modifiers](https://forums.swift.org/t/pitch-formally-defining-consuming-and-nonconsuming-argument-type-modifiers)
- Second pitch thread: [https://forums.swift.org/t/borrow-and-take-parameter-ownership-modifiers/59581](https://forums.swift.org/t/borrow-and-take-parameter-ownership-modifiers/59581)

## Motivation

Swift uses automatic reference counting to manage the lifetimes of reference-
counted objects. There are two broad conventions that the compiler uses to
maintain memory safety when passing an object by value from a caller to a
callee in a function call:

* The callee can **borrow** the parameter. The caller
  guarantees that its argument object will stay alive for the duration of the
  call, and the callee does not need to release it (except to balance any
  additional retains it performs itself).
* The callee can **take** the parameter. The callee
  becomes responsible for either releasing the parameter or passing ownership
  of it along somewhere else. If a caller doesn't want to give up its own
  ownership of its argument, it must retain the argument so that the callee
  can take the extra reference count.

These two conventions generalize to value types, where a "retain"
becomes an independent copy of the value, and "release" the destruction and
deallocation of the copy. By default Swift chooses which convention to use 
based on some rules informed by the typical behavior of Swift code:
initializers and property setters are more likely to use their parameters to
construct or update another value, so it is likely more efficient for them to
*take* their parameters and forward ownership to the new value they construct.
Other functions default to *borrowing* their parameters, since we have found
this to be more efficient in most situations.

These choices typically work well, but aren't always optimal.
Although the optimizer supports "function signature optimization" that can
change the convention used by a function when it sees an opportunity to reduce
overall ARC traffic, the circumstances in which we can automate this are
limited. The ownership convention becomes part of the ABI for public API, so
cannot be changed once established for ABI-stable libraries. The optimizer
also does not try to optimize polymorphic interfaces, such as non-final class
methods or protocol requirements. If a programmer wants behavior different
from the default in these circumstances, there is currently no way to do so.

Looking to the future, as part of our [ongoing project to add ownership to Swift](https://forums.swift.org/t/manifesto-ownership/5212), we will eventually have
move-only values and types. Since move-only types do not have the ability to
be copied, the distinction between the two conventions becomes an important
part of the API contract: functions that *borrow* move-only values make
temporary use of the value and leave it valid for further use, like reading
from a file handle, whereas functions that *take* a move-only value consume
it and prevent its further use, like closing a file handle. Relying on
implicit selection of the parameter convention will not suffice for these
types.

## Proposed solution

We give developers direct control over the ownership convention of
parameters by introducing two new parameter modifiers `borrow` and `take`.

## Detailed design

`borrow` and `take` become contextual keywords inside parameter type
declarations.  They can appear in the same places as the `inout` modifier, and
are mutually exclusive with each other and with `inout`. In a `func`,
`subscript`, or `init` declaration, they appear as follows:

```swift
func foo(_: borrow Foo)
func foo(_: take Foo)
func foo(_: inout Foo)
```

In a closure:

```swift
bar { (a: borrow Foo) in a.foo() }
bar { (a: take Foo) in a.foo() }
bar { (a: inout Foo) in a.foo() }
```

In a function type:

```swift
let f: (borrow Foo) -> Void = { a in a.foo() }
let f: (take Foo) -> Void = { a in a.foo() }
let f: (inout Foo) -> Void = { a in a.foo() }
```

Methods can using the `taking` or `borrowing` modifier to indicate that they
take ownership of their `self` parameter, or they borrow it. These modifiers
are mutually exclusive with each other and with the existing `mutating` modifier:

```swift
struct Foo {
  taking func foo() // `take` ownership of self
  borrowing func foo() // `borrow` self
  mutating func foo() // modify self with `inout` semantics
}
```

`take` cannot be applied to parameters of nonescaping closure type, which by
their nature are always borrowed:

```swift
// ERROR: cannot `take` a nonescaping closure
func foo(f: take () -> ()) {
}
```

`take` or `borrow` on a parameter do not affect the caller-side syntax for
passing an argument to the affected declaration, nor do `taking` or
`borrowing` affect the application of `self` in a method call. For typical
Swift code, adding, removing, or changing these modifiers does not have any
source-breaking effects. (See "related directions" below for interactions with
other language features being considered currently or in the near future which
might interact with these modifiers in ways that cause them to break source.)

Protocol requirements can also use `take` and `borrow`, and the modifiers will
affect the convention used by the generic interface to call the requirement.
The requirement may still be satisfied by an implementation that uses different
conventions for parameters of copyable types:

```swift
protocol P {
  func foo(x: take Foo, y: borrow Foo)
}

// These are valid conformances:

struct A: P {
  func foo(x: Foo, y: Foo)
}

struct B: P {
  func foo(x: borrow Foo, y: take Foo)
}

struct C: P {
  func foo(x: take Foo, y: borrow Foo)
}
```

Function values can also be implicitly converted to function types that change
the convention of parameters of copyable types among unspecified, `borrow`,
or `take`:

```swift
let f = { (a: Foo) in print(a) }

let g: (borrow Foo) -> Void = f
let h: (take Foo) -> Void = f

let f2: (Foo) -> Void = h
```

## Source compatibility

Adding `take` or `borrow` to a parameter in the language today does not
otherwise affect source compatibility. Callers can continue to call the
function as normal, and the function body can use the parameter as it already
does. A method with `take` or `borrow` modifiers on its parameters can still
be used to satisfy a protocol requirement with different modifiers. The
compiler will introduce implicit copies as needed to maintain the expected
conventions. This allows for API authors to use `take` and `borrow` annotations
to fine-tune the copying behavior of their implementations, without forcing
clients to be aware of ownership to use the annotated APIs. Source-only
packages can add, remove, or adjust these annotations on copyable types
over time without breaking their clients.

This will change if we introduce features that limit the compiler's ability
to implicitly copy values, such as move-only types, "no implicit copy" values
or scopes, and `take` or `borrow` operators in expressions. Changing the
parameter convention changes where copies may be necessary to perform the call.
Passing an uncopyable value as an argument to a `take` parameter ends its
lifetime, and that value cannot be used again after it's taken.

## Effect on ABI stability

`take` or `borrow` affects the ABI-level calling convention and cannot be
changed without breaking ABI-stable libraries (except on "trivial types"
for which copying is equivalent to `memcpy` and destroying is a no-op; however,
`take` or `borrow` also has no practical effect on parameters of trivial type).

## Effect on API resilience

`take` or `borrow` break ABI for ABI-stable libraries, but are intended to have
minimal impact on source-level API. When using copyable types, adding or
changing these annotations to an API should not affect its existing clients.

## Alternatives considered

### Making `take` parameter bindings mutable inside the callee

It is likely to be common for functions that `take` ownership of their
parameters to want to modify the value of the parameter they received. Taking
ownership of a COW value type allows for a caller with the only reference to
a COW buffer to transfer ownership of that unique reference, and the callee
can then take advantage of that ownership to do in-place mutation of the
parameter, allowing for efficiency while still presenting a "pure" functional
interface externally:

```swift
extension String {
  // Append `self` to another String, using in-place modification if
  // possible
  taking func plus(_ other: String) -> String {
    // Transfer ownership of the `self` parameter to a mutable variable
    var myself = take self
    // Modify it in-place, taking advantage of uniqueness if possible
    myself += other
    return myself
  }
}

// This is amortized O(n) instead of O(n^2)!
let helloWorld = "hello ".plus("cruel ").plus("world")
```

If this is common enough, we could consider making it so that the parameter
binding inside a function body for a `take` parameter, or for the `self`
parameter of a `taking func`, is mutable out of the gate, removing the need
to reassign it to a local `var`:

```swift
extension String {
  // Append `self` to another String, using in-place modification if
  // possible
  taking func plus(_ other: String) -> String {
    // Modify it in-place, taking advantage of uniqueness if possible
    self += other
    return self
  }
}
```

This does make changing a `take` parameter to `borrow`, or removing the
`take` annotation from a parameter, potentially source-breaking, but in a
purely localized way, since the parameter binding inside the function would
only become immutable again. There is also still the potential for confusion
from users who mutate parameters within the function and expect those mutations
to persist in the caller, which is part of why we removed the ability to declare
a parameter `var` from early versions of Swift. This might be less of a concern
when using `take` with move-only types, since without the ability for the caller
to copy its argument, there's no way for the caller to see the argument after
the callee takes it and modifies it.

### Naming

We have considered alternative naming schemes for these modifiers:

- The current implementation in the compiler uses `__shared` and `__owned`,
  and we could remove the underscores to make these simply `shared` and
  `owned`. These names refer to the way a borrowed parameter receives a
  "shared" borrow (as opposed to the "exclusive" borrow on an `inout`
  parameter), whereas a taken parameter becomes "owned" by the callee.
  found that the "shared" versus "exclusive" language for discussing borrows,
  while technically correct, is unnecessarily confusing for explaining the
  model.
- A previous pitch used the names `nonconsuming` and `consuming`. The current
  implementation also uses `__consuming func` to notate a method that takes
  ownership of its `self` parameter.

The names `take` and `borrow` arose during [the first review of
SE-0366](https://forums.swift.org/t/se-0366-move-function-use-after-move-diagnostic/59202).
These names also work well as names for operators that explicitly
transfer ownership of a variable or borrow it in place, discussed below as the
`take` and `borrow` operators under Related Directions. We think it is helpful
to align the naming of those operators with the naming of these parameter
modifiers, since it helps reinforce the relationship between the calling
conventions and the expression operators: to explicitly transfer ownership
of an argument in a call site to a parameter in a function, use `foo(take x)`
at the call site, and use `func foo(_: take T)` in the function declaration.

### Effect on call sites and uses of the parameter

This proposal designs the `take` and `borrow` modifiers to have minimal source
impact when applied to parameters, on the expectation that, in typical Swift
code that isn't using move-only types or other copy-controlling features,
adjusting the convention is a useful optimization on its own without otherwise
changing the programming model, letting the optimizer automatically minimize
copies once the convention is manually optimized.

It could alternatively be argued that explicitly stating the convention for
a value argument indicates that the developer is interested in guaranteeing
that the optimization occurs, and having the annotation imply changed behavior
at call sites or inside the function definition, such as disabling implicit
copies of the parameter inside the function, or implicitly taking an argument
to a `take` parameter and ending its lifetime inside the caller after the
call site. We believe that it is better to keep the behavior of the call in
expressions independent of the declaration (to the degree possible with
implicitly copyable values), and that explicit operators on the call site
can be used in the important, but relatively rare, cases where the default
optimizer behavior is insufficient to get optimal code.

## Related directions

### Caller-side controls on implicit copying

There are a number of caller-side operators we are considering to allow for
performance-sensitive code to make assertions about call behavior. These
are closely related to the `take` and `borrow` parameter modifiers and so
share their names. See also the
[Selective control of implicit copying behavior](https://forums.swift.org/t/selective-control-of-implicit-copying-behavior-take-borrow-and-copy-operators-noimplicitcopy/60168)
thread on the Swift forums for deeper discussion of this suite of features

#### `take` operator

Currently under review as
[SE-0366](https://github.com/apple/swift-evolution/blob/main/proposals/0366-move-function.md),
it is useful to have an operator that explicitly ends the lifetime of a
variable before the end of its scope. This allows the compiler to reliably
destroy the value of the variable, or transfer ownership, at the point of its
last use, without depending on optimization and vague ARC optimizer rules.
When the lifetime of the variable ends in an argument to a `take` parameter,
then we can transfer ownership to the callee without any copies:

```swift
func consume(x: take Foo)

func produce() {
  let x = Foo()
  consume(x: take x)
  doOtherStuffNotInvolvingX()
}
```

#### `borrow` operator

Relatedly, there are circumstances where the compiler defaults to copying
when it is theoretically possible to borrow, particularly when working with
shared mutable state such as global or static variables, escaped closure
captures, and class stored properties. The compiler does
this to avoid running afoul of the law of exclusivity with mutations. In
the example below, if `callUseFoo()` passed `global` to `useFoo` by borrow
instead of passing a copy, then the mutation of `global` inside of `useFoo`
would trigger a dynamic exclusivity failure (or UB if exclusivity checks
are disabled):

```swift
var global = Foo()

func useFoo(x: borrow Foo) {
  // We need exclusive access to `global` here
  global = Foo()
}

func callUseFoo() {
  // callUseFoo doesn't know whether `useFoo` accesses global,
  // so we want to avoid imposing shared access to it for longer
  // than necessary, and we'll pass a copy of the value. This:
  useFoo(x: global)

  // will compile more like:

  /*
  let globalCopy = copy(global)
  useFoo(x: globalCopy)
  destroy(globalCopy)
   */
}
```

It is difficult for the compiler to conclusively prove that there aren't
potential interfering writes to shared mutable state, so although it may
in theory eliminate the defensive copy if it proves that `useFoo`, it is
unlikely to do so in practice. The developer may know that the program will
not attempt to modify the same object or global variable during a call,
and want to suppress this copy. An explicit `borrow` operator could allow for
this:

```swift
var global = Foo()

func useFooWithoutTouchingGlobal(x: borrow Foo) {
  /* global not used here */
}

func callUseFoo() {
  // The programmer knows that `useFooWithoutTouchingGlobal` won't
  // touch `global`, so we'd like to pass it without copying
  useFooWithoutTouchingGlobal(x: borrow global)
}
```

If `useFooWithoutTouchingGlobal` did in fact attempt to mutate `global`
while the caller is borrowing it, an exclusivity failure would be raised.

#### Move-only types, uncopyable values, and related features

The `take` versus `borrow` distinction becomes much more important and
prominent for values that cannot be implicitly copied. We have plans to
introduce move-only types, whose values are never copyable, as well as
attributes that suppress the compiler's implicit copying behavior selectively
for particular variables or scopes. Operations that borrow
a value allow the same value to continue being used, whereas operations that
take a value destroy it and prevent its continued use. This makes the
convention used for move-only parameters a much more important part of their
API contract:

```swift
moveonly struct FileHandle { ... }

// Operations that open a file handle return new FileHandle values
func open(path: FilePath) throws -> FileHandle

// Operations that operate on an open file handle and leave it open
// borrow the FileHandle
func read(from: borrow FileHandle) throws -> Data

// Operations that close the file handle and make it unusable take
// the FileHandle
func close(file: take FileHandle)

func hackPasswords() throws -> HackedPasswords {
  let fd = try open(path: "/etc/passwd")
  // `read` borrows fd, so we can continue using it after
  let contents = try read(from: fd)
  // `close` takes fd from us, so we can't use it again
  close(fd)

  let moreContents = try read(from: fd) // compiler error: use after take

  return hackPasswordData(contents)
}
```

### `set`/`out` parameter convention

By making the `borrow` and `take` conventions explicit, we mostly round out
the set of possibilities for how to handle a parameter. `inout` parameters get
**exclusive access** to their argument, allowing them to mutate or replace the
current value without concern for other code. By contrast, `borrow` parameters
get **shared access** to their argument, allowing multiple pieces of code to
share the same value without copying, so long as none of them mutate the
shared value. A `take` parameter consumes a value, leaving nothing behind, but
there still isn't a parameter analog to the opposite convention, which would
be to take an uninitialized argument and populate it with a new value. Many
languages, including C# and Objective-C when used with the "Distributed
Objects" feature, have `out` parameter conventions for this, and the Val
programming language calls this `set`.

In Swift up to this point, return values have been the preferred mechanism for
functions to pass values back to their callers. This proposal does not propose
to add some kind of `out` parameter, but a future proposal could.

### Destructuring methods

Move-only types would allow for the possibility of value types with custom
`deinit` logic that runs at the end of a value of the type's lifetime.
Typically, this logic would run when the final owner of the value is finished
with it, which means that a function which `take`s an instance, or a
`taking func` method on the type itself, would run the deinit if it does not
forward ownership anywhere else:

```
moveonly struct FileHandle {
  var fd: Int32

  // close the fd on deinit
  deinit { close(fd) }
}

func dumpAndClose(to fh: take FileHandle, contents: Data) {
  write(fh.fd, contents)
  // fh implicitly deinit-ed here, closing it
}
```

However, this may not always be desirable, either because the function performs
an operation that invalidates the value some other way, making it unnecessary
or incorrect for the deinit logic to run on it, or because it wants to be able
to take ownership of parts away from the value:

```
extension FileHandle {
  // Return the file descriptor back to the user for manual management
  // and disable automatic management with the FileHandle value.

  taking func giveUp() -> Int32 {
    return fd
    // How do we stop the deinit from running here?
  }
}
```

Rust has the magic function `mem::forget` to suppress destruction of a value,
though `forget` in Rust still does not allow for the value to be destructured
into parts. We could come up with a mechanism in Swift that both suppresses
implicit deinitialization, and allows for piecewise taking of its components.
This doesn't require a new parameter convention (since it fits within the
ABI of a `take T` parameter), but could be spelled as a new `take x`-like operator
inside of a `taking func`:

```
extension FileHandle {
  // Return the file descriptor back to the user for manual management
  // and disable automatic management with the FileHandle value.

  taking func giveUp() -> Int32 {
    // `deinit fd` is strawman syntax for consuming a value without running
    // its initializer. it is only allowed inside of `taking func` methods
    // on the type
    return (deinit self).fd
  }
}

moveonly struct SocketPair {
  var input, output: FileHandle

  deinit { /* ... */ }

  // Break the pair up into separately-managed FileHandles
  taking func split() -> (input: FileHandle, output: FileHandle) {
    // Break apart the value without running the standard deinit
    let (input, output) = deinit self
    return (input, output)
  }
}
```

## Acknowledgments

Thanks to Robert Widmann for the original underscored implementation of
`__owned` and `__shared`: [https://forums.swift.org/t/ownership-annotations/11276](https://forums.swift.org/t/ownership-annotations/11276).
