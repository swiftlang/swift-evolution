# Removing `var` from Function Parameters and Pattern Matching

* Proposal: [SE-0003](https://github.com/apple/swift-evolution/blob/master/proposals/0003-remove-var-parameters-patterns.md)
* Author(s): [David Farler](https://github.com/bitjammer)
* Status: **Accepted**
* Review manager: [Joe Pamer](https://github.com/jopamer)

## Introduction

Value types are a major asset to the Swift language, affording safety and the
ability to reason about the effects of mutation by working with a locally copied
instance. When you want to create a *mutable* copy of a value, you create a
*variable*, marked with the `var` keyword. Not only can you create variables as
explicit declarations, you can override bindings that are normally immutable
*constants* by marking them with `var` too.

Function parameters are immutable by default:

```swift
func foo(i: Int) {
  i += 1 // illegal
}

func foo(var i: Int) {
  i += 1 // OK
}
```

So-called *refutable pattern* matches, that will bind an optional value and
provide the binding to a body of code are also immutable by default:

```swift
if let x = getOptionalFoo() {
  x.mutatingMethod() // illegal
}

if var x = getOptionalFoo() {
  x.mutatingMethod() // OK
}
```

```swift
while let x = gen.next() {
  x.mutatingMethod() // illegal
}

while var x = gen.next() {
  x.mutatingMethod() // OK
}
```

```swift
guard let x = gen.next() else {
  return
}
x.mutatingMethod() // illegal

guard var x = gen.next() else {
  return
}
x.mutatingMethod() // OK
```

```swift
switch optionalInt {
  case .None: return
  case .Some(let x):
    x += 1 // illegal
    return x
}

switch optionalInt {
  case .None: return
  case .Some(var x):
    x += 1 // OK
    return x
}
```

For-in statements also allow variable bindings:

```swift
for x in sequence {
  x.mutatingMethod() // illegal
}

for var x in sequence {
  x.mutatingMethod() // OK
}
```

Using `var` annotations on function parameters and pattern bindings in if-,
while-, guard-, case-, and for-in statements have limited utility, optimizing
for a line of code at the cost of confusion. To emphasize the fact these values
are unique copies, we should not allow use of `var` in these places.

## Motivation

`var` allows one to reassign and call mutating methods on value types, but there
is an *implicit* local copy of the value, yet there can be confusion that `var`
somehow makes values types have *reference semantics* or *inout semantics*. To
make it very clear, we want to require a separated, *explicit* `var` declaration
and make bindings of function parameters and pattern matches *always* their
default - immutable constants.

### Function Parameters

```swift
func doSomethingWithVar(var x: Int) {
  x = 2 // The caller of this function can't observe this assignment.
}
```

Here, the *local copy* of `x` mutates but the write does not propagate back to
the original value that was passed, so the caller can never observe the change
directly.  For that to happen to value types, you have to mark the parameter
with `inout`:

```swift
func doSomethingWithInout(inout i: Int) {
  i = 2 // This will have an effect on the caller's Int that was passed.
}

var x = 1
print(x) // 1

doSomethingWithVar(x)
print(x) // 1

doSomethingWithInout(&x)
print(x) // 2
```

### `var` Bindings in Pattern Matching

This problem can also manifest in the local scopes wherever pattern matching is
allowed:

```swift
func getOptionalNumber() -> Int? {
  return 1
}

var x = getOptionalNumber()

if var x = x {
  x = doSomethingWith(x) // Whoops! Doesn't affect the original `x`!
}

print(x) // 1
```

In summary, the problems that motivate this change are:

- `var` is often confused with `inout` in function parameters.
- `var` is often confused to make value types have reference semantics.
- Use of `var` at these sites don't make the intention of creating a unique,
  local, mutable copy as explicit and clear as it could be.

## Proposed solution

- All function parameters are either unannotated constants or are marked with `inout`.
- Only `if let` is allowed, not `if var`.
- Only `guard let` is allowed, not `guard var`.
- Only `while let` is allowed, not `while var`.
- Only `case .Some(let x)` is allowed, not `case .Some(var x)`.
- Only `for x in` is allowed, not `for var x in`.

## Design

The above changes can be made almost entirely in the parser, triggering error
diagnostics.  Function parameters explictly marked with `let` will be a warning
because they are immutable by default. In addition, the compiler will stop
suggesting `var` when trying to directly mutate function arguments.

## Impact on existing code

As a purely mechanical migration away from these uses of `var`, a temporary
variable can be immediately introduced that shadows the immutable copy in all of
the above uses. For example:

```swift
if let x = getOptionalInt() {
  var x = x
  x += 1
  return x
}
```

However, uses of these variable bindings often indicate an anti-pattern or
misunderstanding of the scope of mutation of value types. For example:

```swift
func mkdtemp(var prefix: String?) -> Path {
  if prefix == nil {
    prefix = getenv("TMPDIR") ?? "/tmp"
  }

  return Path(prefix, getUniqueSuffix())
}
```

`prefix` is only ever assigned once so the following code suffices and
only uses immutable values:

```swift
func mkdtemp(prefix: String) -> Path {
  return Path(prefix ?? getenv("TMPDIR") ?? "/tmp", getUniqueSuffix())
}
```

So, we expect users of Swift to rethink some of their existing code where these
are used.

## Alternatives considered

This is the best approach to alternate/new syntax or terminology because:

- It removes confusion by offering only one "switch" to flip to get a mutable
  value.
- It makes use of mutable variables stand out as an explicit line of code
  instead of being embedded in other syntax.
- It promotes use of immutable constants.
- It makes the language smaller.

