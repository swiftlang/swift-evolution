# `@inline(always)` attribute

* Proposal: [SE-NNNN](NNNN-inline-always.md)
* Authors: [Arnold Schwaighofer](https://github.com/aschwaighofer)
* Implementation: [swiftlang/swift#84178](https://github.com/swiftlang/swift/pull/84178)
* Pitch thread: https://forums.swift.org/t/pitch-inline-always-attribute/82040

## Introduction

The Swift compiler performs an optimization that expands the body of a function
into the caller called inlining. Inlining exposes the code in the callee to the
code in the caller. After inlining, the Swift compiler has more context to
optimize the code across caller and callee leading to better optimization in
many cases. Inlining can increase code size. To avoid unnecessary code size
increases, the Swift compiler uses heuristics (properties of the code) to
determine whether to perform inlining. Sometimes these heuristics tell the
compiler not to inline a function even though it would be beneficial to do so.
The proposed attribute `@inline(always)` instructs the compiler to always inline
the annotated function into the caller giving the author explicit control over
the optimization.

## Motivation

Inlining a function referenced by a function call enables the optimizer to see
across function call boundaries. This can enable further optimization. The
decision whether to inline a function is driven by compiler heuristics that
depend on the shape of the code and can vary between compiler versions.

In the following example the decision to inline might depend on the number of
instructions in `callee` and on detecting that the call to callee is frequently
executed because it is surrounded by a loop. Inlining this case would be
beneficial because the compiler is able to eliminate a store to a stack slot in
the `caller` after inlining the `callee` because the function's `inout` calling
convention ABI that requires an address no longer applies and further
optimizations are enabled by the caller's function's context.

```swift
func callee(_ result: inout SomeValue, _ cond: Bool) {
  result = SomeValue()
  if cond {
    // many lines of code ...
  }
}

func caller() {
  var cond: Bool = false
  var x : SomeValue = SomeValue()
  for i in 0 ..< 1 {
    callee(&x, cond)
  }
}

func callerAfterInlining(_ cond: Bool {
  var x : SomeValue = SomeValue()
  var cond: Bool = false
  for i in 0 ..< 1 {
    // Inlined `callee()`:
                    // Can keep `SomeValue()` in registers because no longer
                    // passed as an `inout` argument.
    x = SomeValue() // Can  hoist `x` out of the loop and perform constant
                    // propagation.
    if cond {       // Can remove the code under the conditional because it is
                    // known not to execute.
       // many lines of code ...
    }
  }
}
```

The heuristic might fail to detect that code is frequently executed (surrounding
loop structures might be several calls up in the call chain) or the number of
instructions in the callee might be to large for the heuristic to decide that
inlining is beneficial.
Heuristics might change between compiler versions either directly or indirectly
because some properties of the internal representation of the optimized code
changes.
To give code authors reliable control over the inlining process we propose to
add an `@inline(always)` function attribute.

This optimization control should instruct the compiler to inline the referenced
function or emit an error when it is not possible to do so.

```swift
@inline(always)
func callee(_ result: inout SomeValue, _ cond: Bool) {
  result = SomeValue()
  if cond {
    // many lines of code ...
  }
}
```

## Proposed solution

We desire for the attribute to function as an optimization control. That means
that the proposed `@inline(always)` attribute should emit an error if inlining
cannot be guaranteed in all optimization modes. The value of the function at a
call site can might determined dynamically at runtime. In such cases the
compiler cannot determine a call site which function is applied without doing
global analysis. In these cases we don't guarantee inlining even if the dynamic
value of the applied function was annotated with `@inline(always)`.
We only guarantee inlining if the annotated function is directly referenced and
not derived by some function value computation such as method lookup or function
value (closure) formation and diagnose errors if this guarantee cannot be
upheld.

A sufficiently clever optimizer might be able to derive the dynamic value at the
call site, in such cases the optimizer shall respect the optimization control
and perform inlining.

```swift
protocol SomeProtocol {
    func mightBeOverriden()
}

class C : SomeProtocol{
    @inline(always)
    func mightBeOverriden() {
    }
}

@inline(always)
func callee() {
}

func applyFunctionValues(_ funValue: () -> (), c: C, p: SomeProtocol) {
    funValue() // function value, not guaranteed
    c.mightBeOverriden() // dynamic method lookup, not guaranteed
    p.mightBeOverriden() // dynamic method lookup, not guaranteed
    callee() // directly referenced, guaranteed
}

func caller() {
  applyFunctionValue(callee, C())
}

caller()
```

Code authors shall be able to rely on that if a function is marked with
`@inline(always)` and directly referenced from any context (within or outside of
the defining module) that the function can be inlined or an error is emitted.


## Detailed design

We want to diagnose an error if a directly referenced function is marked with
`@inline(always)` and cannot be inlined. What are the cases where this might not
be possible?

### Interaction with `@inlinable`

`@inlinable` and `@_alwaysEmitIntoClient` make the function body available to
clients (callers in other modules) in library evolution mode. `@inlinable` makes
the body of the function available to the client and causes an ABI entry point
in the vending module to vended. `@_alwaysEmitIntoClient` makes the body of the
function available for clients but does not cause emission of an ABI entry
point. Functions with `open`, `public`, or `package` level access cause emission
of an ABI entry point for clients to call but in the absence of aforementioned
attributes do not make the body available to the client.

`@inline(always)` intention is to be able to guarantee that inlining will happen
for any caller inside or outside the defining module therefore it makes sense to
require the use some form of "inline-ability" attribute with them. This
attribute could be required to be explicitly stated. And for it to be an error
when the attribute is omitted.

```swift
@inline(always)
@inlinable // or @_alwaysEmitIntoClient
public func caller() { ... }

@inline(always) // error: a public function marked @inline(always) must be marked @inlinable
public func callee() {
}
```

Alternatively, the attribute could be implicitly implied by the usage of
`@inline(always)`. In this proposal, we take the position that it should be
implied to avoid the redundancy of spelling this out. The intention of
`@inline(always)` is for it to inline in all contexts. Instead of an error in the
absence of the attribute we should imply "inline-ability". The question is what
should we default to?

`@_alwaysEmitIntoClient`'s semantics seems preferable for new functions. We
intend for the function to be always inlined, why should there be an ABI entry
point?

`@inlinable` semantics allows for annotating existing functions with
`@inline(always)` without breaking ABI compatibility. `@inlinable` keeps an
entry point in the vending module for older code that assumed the existence of
an entry point.

This proposals takes the position to give `@inline(always)` the semantics of
`@inlineable` and provide an alternative spelling for the case when we desire
`@_alwaysEmitIntoClient` semantics: `@inline(only)`.

For access levels equal and lower than `internal` `@inlinable` should not be
implied.


### Interaction with `@usableFromInline`

A `public` `@inlinable` function can reference a function with `internal` access
if it is either `@inlinable` (see above) or `@usableFromInline`. `@usableFromInline`
ensures that there is a public entry point to the `internal` level function but
does not ensure that the body of the function is available to external
modules. Therefore, it is an error to combine `@inline(always)` with a
`@usableFromInline` function as we cannot guaranteed that the function can
always be inlined.

```swift
@inline(always) // error: an internal function marked with `@inline(always)` and
                          `@usableFromInline` could be referenced from an
                          `@inlinable` function and must be marked inlinable
@usableFromInline
internal func callee() {}

@inlinable
public func caller() {
    callee() // could not inline callee into external module
}
```

### Module internal access levels

It is okay to mark `internal`, `private` and `fileprivate` function declarations
with `@inline(always)` in cases other than the ones mention above without the
`@inlinable` attribute as they can only be referenced from within the module.


```swift
public func caller() {
    callee()
}

@inline(always) // okay because caller would force either `@inlinable` or
                // `@usableFromInline` if it was marked @inlinable itself
internal func callee() {
}


@inline(always) // okay can only referenced from within the module
private func callee2() {
}
```

#### Infinite recursion during inlining

We will diagnose if inlining cannot happen due to calls within a
[strongly connected component](https://en.wikipedia.org/wiki/Strongly_connected_component)
marked with `@inline(always)` as errors.

```swift
@inline(always)
func callee() {
  ...
  if cond2 {
    caller()
  }
}

@inline(always)
func caller() {
  ...
  if cond {
    callee()
  }
}
```

### Dynamic function values

As outlined earlier the attribute does not guarantee inlining or diagnose the
failure to inline when the function value is dynamic at a call site: a function
value is applied, or the function value is obtained via class method lookup or
protocol lookup.

```swift
@inline(always)
func callee() {}
func useFunctionValue() {
  let f = callee
  ...
  f() // function value use, not guaranteed to be inlined
}

class SomeClass : SomeProto{
  @inline(always)
  func nonFinalMethod() {}

  @inline(always)
  func method() {}
}

protocol SomeProto {
  func method()
}


func dynamicMethodLookup() {
  let c = SomeClass()
  ...
  c.nonFinalMethod() // method lookup, not guaranteed to be inlined

  let p: SomeProto = SomeClass()
  p.method() // method lookup, not guaranteed to be inlined
}

class A {
  func finalInSub() {}
  final func finalMethod() {}
}
class B : A {
  overrided final func finalInSub() {}
}

func noMethodLookup() {
    let a = A()
    a.finalMethod() // no method lookup, guaranteed to be inlined

    let b = B()
    b.finalInSubClass() // no method lookup, guaranteed to be inlined
}
```


## Source compatibility

This proposal is additive. Existing code has not used the attribute. It has no
impact on existing code. Existing references to functions in libraries that are
now marked with `@inline(always)` will continue to compile successfully with the
added effect that functions will get inlined (that could have happened with
changes to inlining heuristic).

## ABI compatibility

The addition of the attribute has no effect on ABI compatibility. We chose to
imply `@inlinable` for `public` (et al.) declarations which will continue to
emit an entry point for existing binary clients.

## Implications on adoption

This feature can be freely adopted and un-adopted in source
code with no deployment constraints and without affecting source or ABI
compatibility.

## Future directions

`@inline(always)` can be too restrictive in cases where inlining is only
required within a module. For such cases we can introduce an `@inline(module)`
attribute in the future.


```swift
@inlinable
public caller() {
  if coldPath {
    callee()
  }
}

public otherCaller() {
    if hotPath {
        callee()
    }
}

@inline(module)
@usableFromInline
internal func callee() {
}
```

## Alternatives considered

We could treat `@inline(always)` as an optimization hint that does not need to
be enforced or applied at all optimization levels similar to how the existing
`@inline(__always)` attribute functions and not emit errors if it cannot be
guaranteed to be uphold when the function is directly referenced.
This would deliver less predictable optimization behavior in cases where authors
overlooked requirements for inlining to happen such as not marking a public
function as `@inlinable`.

With respect to `@inlinable` an initial draft of the proposal suggested to
require spelling the `@inlinable` attribute on `public` declarations or an error
would be displayed. The argument was that this would ensure that authors would
be aware of the additional semantics implied by the attribute: the body is
exposed.

## Acknowledgments

TODO: ....
