# Single-yield functions

* Proposal: [SE-NNNN](NNNN-single-yield-functions.md)
* Authors: Meghana Gupta, Tim Kientzle
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: TBD
* Experimental Feature Flag: TBD
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

We propose introducing single-yield functions declared by writing `yield` in the result
position:

```swift
func f() -> yield T          // yields an owned value
func f() -> yield borrow T   // yields a borrowed value
func f() -> yield inout T    // yields a mutable value
```

A single-yield function is a coroutine that runs until it reaches a `yield` statement. It then yields a
value to its caller and suspends. When the caller is finished accessing the value, the coroutine resumes and runs to completion, performing any necessary cleanup.

## Motivation

### Yielding accessors

Swift has long supported accessors that yield. The standard library has used
the underscored `_read` and `_modify` accessors since Swift 5.0 and
[SE-0474](0474-yielding-accessors.md) made them an official part of the
language as `yielding borrow` and `yielding mutate`.

A yielding accessor is a single-yield coroutine. A `yielding borrow` accessor
yields a borrowed value. A `yielding mutate` accessor yields a mutable value,
which the caller can modify in place.

Because the accessor resumes after the caller is done, it can perform any
necessary cleanup, such as ending an exclusive access, deallocating
temporary memory or releasing a lock.

Some computed properties can only be expressed with a yielding accessor. One
example is a `~Copyable & ~Escapable` property such as `MutableSpan` over a
class's stored property. Accesses to class properties are dynamically checked
for exclusivity, so the exclusive access must stay open for as long as the
caller uses the `MutableSpan`, which requires an accessor that resumes after
the caller is done.

```swift
class StrawmanBuffer {
  private var _contents = ContiguousArray<UInt8>()

  var contents: MutableSpan<UInt8> {
    yielding borrow { ... }
    yielding mutate {
      var ms = _contents.mutableSpan // the exclusive access to `_contents` begins here
      yield &ms
      // Execution resumes here once the caller is done with the span.
      // The exclusive access ends here.
    }
  }
}
```

### Generalized single-yield functions

Today, `yield` is allowed only inside yielding accessors. However, many
operations that need to set up state and clean it up afterward are not
computed properties.

For example, an API like `getMappedRange` takes an offset and a size and
provides a `MutableSpan` over that part of the buffer. Because it takes
arguments, it has to be a function rather than a property. But an ordinary
function cannot keep the exclusive access to `_contents` open after it
returns:

```swift
class StrawmanBuffer {
  private var _contents = ContiguousArray<UInt8>()

  func getMappedRange(_ offset: Int, _ size: Int) -> MutableSpan<UInt8> {
    precondition(isValidRange(offset, size))

    var ms = _contents.mutableSpan
    // The span depends on the access scope of `_contents` which ends at the `return`.
    return ms.extracting(offset ..< offset + size) // error: lifetime-dependent value escapes its scope
  }
}
```

As a single-yield function, `getMappedRange` could validate its arguments,
begin the exclusive access to `_contents` and yield the `MutableSpan`,
suspending until the caller is done with it. The function would then resume
and end the exclusive access.

### Composition

Single-yield functions would also let yielding accessors compose with the
rest of the language. Today, a function can use a value yielded by an
accessor inside its own body but it cannot always pass that value up the
call stack.

For example, a method that looks up a row by name in a non-'Copyable' table of
non-'Copyable' rows cannot return it:

```swift
struct Row: ~Copyable {
  var name: String
  var count: Int
}

struct Table: ~Copyable {
  subscript(index: Int) -> Row {
    yielding borrow { ... }
    yielding mutate { ... }
  }

  borrowing func row(named name: String) -> Row {
    // The row is only borrowed and the borrow ends at the `return`.
    return self[index(of: name)] // error: 'self.subscript' is borrowed and cannot be consumed
  }
}
```

A `mutating` version cannot give the caller in-place mutable access either.

## Proposed solution

We propose introducing single-yield functions to the language. A single-yield function is declared by
writing `yield` after the `->` of its result, optionally followed by `borrow`
or `inout` to specify how the value is yielded:

```swift
func f() -> yield T          // yields an owned value of type T
func f() -> yield borrow T   // yields a borrowed value of type T
func f() -> yield inout T    // yields a mutable value of type T
```

As with yielding accessors, when the function reaches the `yield`, it
suspends and yields the value to its caller. The caller then uses the value
and the function resumes once the caller is done accessing it.

With this feature, `getMappedRange` can be written directly:

```swift
class StrawmanBuffer {
  private var _contents = ContiguousArray<UInt8>()

  func getMappedRange(_ offset: Int, _ size: Int) -> yield MutableSpan<UInt8> {
    precondition(isValidRange(offset, size))

    var ms = _contents.mutableSpan          // exclusive access to `_contents` begins
    yield ms.extracting(offset ..< offset + size)
    // Execution resumes here after the last use of the yielded span.
    // The access to `_contents` ends here.
  }
}
```

`Table` can also yield its rows by name:

```swift
extension Table {
  borrowing func row(named name: String) -> yield borrow Row {
    yield self[index(of: name)]
  }

  mutating func mutableRow(named name: String) -> yield inout Row {
    yield &self[index(of: name)]
  }
}
```

### Yielding owned values by default

A function declared with a bare `-> yield T` yields an **owned** value in
the same way that a function declared with `-> T` returns one. The caller
therefore receives the same kind of value from a yielding call as from an
ordinary call and it can bind the value to a `var`, mutate it or consume
it. The difference is that the function resumes when the caller's access
ends, which lets it do cleanup work that an ordinary function cannot.

The `getMappedRange` example above needs an owned yield. A borrowed yield
would not let the caller write through the `MutableSpan` and a mutable yield would
give the caller mutable access to the span but would not let the caller
consume it. 

### Yielding borrowed and mutable values

A single-yield function can also yield a scoped value to its caller, just as
the `yielding borrow` and `yielding mutate` accessors do.

A function declared with `-> yield borrow T` yields a borrowed value, which
allows the function to yield a value without copying it. The caller can read
the borrowed value but cannot consume or mutate it.

A function declared with `-> yield inout T` yields a mutable value. The
caller can modify the value in place and the function sees the result when
it resumes. As in a `yielding mutate` accessor, the yielded value is marked
with `&`.

In both cases, the caller's access to the yielded value lasts only as long as
the coroutine scope. If `T` is `Copyable` and `Escapable`, the caller can copy
the value and use the copy after the coroutine scope ends. Otherwise, the
caller's use of the value is confined to the coroutine scope.

## Detailed design

### Grammar

The function result grammar is extended to allow a `yield` clause:

```
function-result → '->' attributes? type
function-result → '->' 'yield' yield-ownership? attributes? type

yield-ownership → 'borrow' | 'inout'
```

The function type grammar is extended the same way:

```
function-type → attributes? function-type-argument-clause throws-clause? '->' 'yield' yield-ownership? type
```

A declaration whose result has a `yield` clause is a *single-yield function*.
This applies to `func` declarations including methods, static methods and
local functions. Initializers, deinitializers and closures are not covered.

### Yield conventions

| Declaration          | `yield` statement | What the caller receives |
|----------------------|-------------------|--------------------------|
| `-> yield T`         | `yield expr`      | An owned value. The caller is responsible for destroying or consuming it. |
| `-> yield borrow T`  | `yield expr`      | A borrow of a value that the coroutine keeps alive while it's suspended. |
| `-> yield inout T`   | `yield &lvalue`   | Exclusive, mutable access to storage that the coroutine keeps valid while it's suspended. |

For owned yields, `expr` is evaluated as if it were being passed to a
`consuming` parameter. Copyable values are copied as needed and non-'Copyable'
values must be consumable at the `yield`.

For borrowed yields, `expr` is evaluated as if it were being passed to a
`borrowing` parameter. It may refer to stored properties, parameters, locals,
temporaries or the result of another accessor or single-yield function.
Temporaries are kept alive until the coroutine is resumed.

For `inout` yields, `&lvalue` follows the same rules as passing an `inout`
argument. The lvalue must be mutable and the access to it lasts until the
coroutine is resumed. As with `inout` arguments, the caller must leave the
value initialized when the access ends.

### The single-yield rule

As with yielding accessors, every path through the body of a single-yield
function must execute exactly one `yield` and the compiler enforces this
statically.

### Throwing single-yield functions

A single-yield function can be declared `throws` or `throws(E)` and the
caller marks the call with `try` as with any other throwing call:

```swift
class StrawmanBuffer {
  private var _contents = ContiguousArray<UInt8>()

  func getMappedRange(_ offset: Int, _ size: Int) throws(RangeError) -> yield MutableSpan<UInt8> {
    guard isValidRange(offset, size) else {
      throw RangeError()   // throws without yielding
    }

    var ms = _contents.mutableSpan
    yield ms.extracting(offset ..< offset + size)
  }
}

var span = try buffer.getMappedRange(offset, size)
```

If the function throws, it doesn't yield. The error propagates to the
caller as it would from an ordinary function and the caller receives the
error instead of a value. The coroutine has finished at that point, so there
is nothing to resume.

Once the function has yielded, it cannot throw. The caller resumes the
coroutine implicitly when the coroutine scope ends. 

If the caller throws while the coroutine is suspended, the coroutine still
resumes. As with
[yielding accessors](0474-yielding-accessors.md#throwing-callers), an error
thrown in the caller during the coroutine scope doesn't unwind the
coroutine. The coroutine is resumed as the error propagates out of the
coroutine scope and runs the code after the `yield` to completion, exactly
as it would on the normal path. 

### Lifetime dependence of yielded values

If the yielded type is non-'Escapable', the yielded value may depend on
anything the coroutine keeps alive until it resumes: its parameters, the
accesses it has begun or its local variables.

From the caller's side, the yielded value depends on the *coroutine
scope*. The compiler can extend the coroutine scope to cover uses of the value, any use outside the scope is diagnosed.

### Protocol requirements and overrides

A single-yield function can be a protocol requirement. The yield convention is
part of the requirement. A requirement can only be witnessed by a single-yield
function with the same yield convention. The same rules govern which overrides are allowed in subclasses.

### Overloading

Two declarations that differ only in whether or how they yield conflict with
each other. For example, `-> T` and `-> yield T` conflict, as do
`-> yield borrow T` and `-> yield inout T`.

## Source compatibility

This proposal is purely additive.

`yield` becomes a contextual keyword only directly after the `->` of a
function result or function type and only when followed by a type. `borrow`
becomes a contextual keyword only directly after that `yield`. `inout` is
already a keyword.

The `yield` statement becomes valid inside single-yield functions. Because
single-yield functions are new, this doesn't change the meaning of any
existing code.

## ABI compatibility

### The coroutine ABI

<!--
The original underscored `_read` and `_modify` accessors use a single-yield
coroutine ABI with these properties:

- The caller provides a fixed-size buffer of four pointer-sized words for
  the coroutine's frame.
- If the callee's frame doesn't fit in that buffer, the callee heap-allocates
  it.
- The callee returns a continuation function along with the yielded values.
  The caller later invokes the continuation to resume, passing a flag that
  says whether to resume normally or unwind.

In practice, many non-trivial coroutines don't fit in the fixed buffer, so
every call to one has a heap allocation.

The `yielding borrow` and `yielding mutate` accessors of [SE-0474](0474-yielding-accessors.md) use a new
coroutine ABI that addresses these costs:

- **Coroutine function pointers.** A coroutine is referenced through a
  *coroutine function pointer*, a small record that holds a relative
  reference to the function's code alongside the size of its fixed
  frame. Because the caller knows the frame
  size before the call, it can allocate a frame of exactly the right
  size, usually on its own stack.
- **Caller-provided allocators.** The caller passes the coroutine an
  allocator to use for any dynamic allocation it needs. Depending on the
  caller's context, this allocator uses the caller's stack, the current
  task's allocator in `async` contexts or `malloc`. A coroutine called
  from an `async` function therefore allocates on the task allocator
  instead of the heap and a coroutine called synchronously can often
  avoid heap allocation entirely.
- **No unwinding.** [SE-0474](0474-yielding-accessors.md) specifies that a coroutine always runs to
  completion when resumed, even if the caller threw. The new ABI doesn't
  have to support a separate unwind path into the coroutine.
--> 
Single-yield functions use the coroutine ABI introduced for [SE-0474](0474-yielding-accessors.md). Outside of the experimental
`@yield_once` syntax used in automatic differentiation, functions could not previously be coroutines, so no existing ABI is affected.

### Evolution of single-yield functions

The yield convention is part of a function's type and therefore of its
mangled name and calling convention. This has the following consequences for
library evolution:

- Changing a function between `-> T` and `-> yield T`, in either direction,
  is ABI-breaking.
- Changing between `-> yield T`, `-> yield borrow T` and `-> yield inout T`
  is ABI-breaking. Changing to a convention that promises less to the caller
  is also source-breaking. For example, changing `-> yield T` to
  `-> yield borrow T` breaks callers that consume the value.
- Adding a single-yield function or a protocol requirement with a default
  implementation is ABI-additive, just as with ordinary functions.

## Implications on adoption

The new coroutine ABI requires runtime support.
On platforms with a stable ABI, single-yield functions can only be used
when deploying to a runtime that provides this support. Calls to
single-yield functions are therefore subject to availability checking.

Library authors can adopt single-yield functions for new APIs, subject to the
availability requirement above.

### Choosing between an ordinary result and a yield

A call to a single-yield function costs more than an ordinary call, because the
caller makes two calls into the coroutine: one to start it and one to resume
it. The new ABI makes this much cheaper than the original `_read`/`_modify`
ABI, but a plain return is still faster when the call isn't inlined. Guidance:

- Use `-> T` when the function computes a value and has nothing to do after
  the caller is finished with it.
- Use `-> yield T` when the caller needs to own the value, but the function
  has to keep an access or resource open while the value is in use. 
- Use `-> yield borrow T` or `-> yield inout T` when the function yields a
  component of existing storage without copying it and has work to do before
  and after the caller's access.

## Future directions

### Async single-yield functions

A future proposal could allow single-yield functions to be declared `async`.
Such a function could suspend with `await` before it yields, for example to
wait for a resource to become available. The caller would mark the call with
`await`, as with any other `async` call:

```swift
extension MappedFile {
  func contents() async throws(MappingError) -> yield Span<UInt8> {
    let mapping = try await mapIntoMemory()  // may suspend, may fail
    yield mapping.span
    mapping.unmap()                          // runs once the caller is done
  }
}

let bytes = try await file.contents()
checksum(bytes)
// `contents()` resumes and unmaps the file after the last use of `bytes`
```

The code after the `yield` would still run on the function's own isolation.
If the function is isolated to an actor and the caller isn't, resuming the
coroutine would hop to the actor's executor, run the code after the `yield`
and hop back.

### Relaxed requirement matching

This proposal requires a single-yield protocol requirement to be witnessed by
a single-yield function with exactly the same yield convention and applies
the same rule to overrides. A future proposal could relax this to allow a
witness or override whose convention gives the caller at least as much as
the requirement promises. The compiler would bridge the difference with a
thunk.

### Multi-yield coroutines

This proposal covers only single-yield coroutines. Multi-yield coroutines and
generators would let a function yield a sequence of values. They are a
substantially larger design and are left to a future proposal.

## Alternatives considered

### A `yielding func` modifier

Earlier sketches, including [SE-0474](0474-yielding-accessors.md)'s
[future directions](0474-yielding-accessors.md#yield-once-functions) and
[SE-0519](0519-ref-mutableref-types.md)'s
["Generalized single-yield coroutines"](0519-ref-mutableref-types.md#generalized-single-yield-coroutines),
spell single-yield functions with a declaration modifier:

```swift
yielding func updateValue() -> inout C { ... }
yielding func noisyCounterRef(from target: inout NoisyCounter) -> MutableRef<Int> { ... }
```

This would split what the caller receives across two places: whether the
function is a coroutine goes on the declaration and the ownership of the
result goes in the result type. It also doesn't carry over to function types
without a separate attribute. With `yield` in the result position,
everything a caller needs to know about the result appears in one place
and the same spelling works in function types:

```swift
let f: (Int) -> yield borrow Element
```

### A `yields` effect

For automatic differentiation, the compiler has an alternative syntax for
single-yield functions:

```swift
@yield_once func coro(_ x: inout Float) yields (inout Float) -> () { ... }
```

This syntax also provides a way to specify a result type.
This proposal doesn't provide an option for that.

## Acknowledgments

Anton Korobeynikov's work to support yield-once functions for automatic
differentiation lays out fundamental compiler support for single-yield
functions. This proposal builds directly on the coroutine accessors and the
new coroutine ABI designed and implemented for [SE-0474](0474-yielding-accessors.md) by Nate Chandler.
John McCall and Arnold Schwaighofer have done significant work on yielding accessors on which this proposal is based. The proposal uses motivating examples from Geoff Garen.
