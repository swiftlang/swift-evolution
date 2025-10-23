# `@inline(always)` attribute

* Proposal: [SE-0496](0496-inline-always.md)
* Authors: [Arnold Schwaighofer](https://github.com/aschwaighofer)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Accepted**
* Implementation: [swiftlang/swift#84178](https://github.com/swiftlang/swift/pull/84178)
* Review: ([pitch](https://forums.swift.org/t/pitch-inline-always-attribute/82040)) ([review](https://forums.swift.org/t/se-0496-inline-always-attribute/82480)) ([acceptance](https://forums.swift.org/t/accepted-se-0496-inline-always-attribute/82825))

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
that the proposed `@inline(always)` attribute should emit an error diagnostic if
inlining is not possible in all optimization modes. However, this gets
complicated by the fact that the value of the function at a call site might be
determined dynamically at runtime:

- Calls through first class function values
  ```swift
  @inline(always) f() {...}

  func a() {
    let fv = f
    fv()
  }
  ```
- Calls through protocol values and protocol constraint generic types
  ```swift
  protocol P {
    func method()
  }
  struct S : P {
    @inline(always)
    func method() {...}
  }
  func a<T: P>(_ t: T) {
      t.method()
      let p : P = S()
      p.method()
  }
  ```
- Calls through class instance values and the method referenced is not `final`
  ```swift
  class C {
    @inline(always)
    func method() {...}
  }
  func a(c: C) {
    c.method()
  }
- Calls through `class` methods on `class` types and the method referenced
  is not `final`
  ```swift
  class C {
    @inline(always)
    class func method() {...}
  }
  func a(c: C.Type) {
    c.method()
  }
  ```

In such cases, the compiler cannot determine at a call site which function is
applied without doing non-local analysis: either dataflow, or class hiarchy
analysis.
These cases are in contrast to when the called function can statically be
determined purely by looking at the call site, we refer to this set as direct
function references in the following:

- Calls to free standing functions
- Calls to methods of `actor`, `struct`, `enum` type
- Calls to final methods, final `class` type methods of `class` type, and
  `static` type methods of `class` type

Therefore, in cases where the value of the function at a usage site is
dynamically derived we don't emit an error even if the dynamic value of the
applied function was annotated with `@inline(always)`. We only emit an error if
the annotated function is directly referenced and something would cause it to be
not inlined or if some property at the declaration site of the function would
make it not possible in the common case.

Listing the different scenarios that can occur for a function marked with
`@inline(always)`:

1. A function can definitely be inlined at the use site: direct function
   references barring recursion cycles
2. A function can never be always inlined at a use site and we diagnose an
   error: cycles in `@inline(always)` functions calling each other and all
   references are direct.
3. A function can not be inlined reliably and we diagnose an error at the
   declaration site: non-final method declaration
4. A function can not be inlined and we don't diagnose an error: calls through
   first class function values, protocol values, and protocol constraint generic
   types.

### Direct function references

Calls to freestanding functions, methods of `enum`, `struct`, `actor` types,
final methods of `class` types, and `static` (but not `class`) type methods of
`class` types don't dynamically dispatch to different implementations. Calls to
such methods can always be inlined barring the recursion limitation (see later).
(case 1)

```swift
struct S {
  @inline(always)
  final func method() {}
}

func f() {
    let s: S = ...
    s.method() // can definitely be inlined
}

class C {
  @inline(always)
  final func finalMethod() {}

  @inline(always)
  static func method() {}

  @inline(always)
  final class func finalTypeMethod()
}

class Sub : C {}

func f2() {
    let c: C = ...
    c.finalMethod() // can definitely be inlined
    let c2: Sub = ..
    c2.finalMethod() // can definitely be inlined
    C.method() // can definitely be inlined
    let c: C.Type = ...
    c.finalTypeMethod() // can definitely be inlined
}

@inline(always)
func freestanding() {}

func f3() {
    freestanding() // can definitely be inlined
}

```

### Non final class methods

Swift performs dynamic dispatch for non-final methods of classes and non final
`class` methods of classes based on the dynamic receiver type of the class
instance/class type value at a use site. Inferring the value of that dynamic
computation at compile time is not possible in many cases and the success of
inlining cannot be ensured. We treat a non-final method declaration with
`@inline(always)` as an declaration site error because we assume that the
intention of the attribute is that the method will be inlined in most cases and
this cannot be guaranteed (case 3).

```swift
class C {
    @inline(always) // error: non-final method marked @inline(always)
    func method() {}

    @inline(always) // error: non-final method marked @inline(always)
    class func class_method() {}
}

class C2 : C {
    @inline(always) // error: non-final method marked @inline(always)
    override func method() {}

    class func class_method() {}
}

func f(c: C, c2: C.Type) {
   c.method() // dynamic type of c might be C or C2, could not ensure success
              // of inlining in general
   c2.class_method() // dynamic type of c2 might be C.self or C2.self, could not
                     // ensure success of inlining in general
}
```

### Recursion

Repeatedly inlining `@inline(always)` functions calling each other would lead to
an infinite cycle of inlining. We can never follow the `@inline(always)`
semantics and diagnose an error (case 2).

```swift
@inline(always)
func callee() {
  ...
  if cond2 {
    caller() // error: caller is marked @inline(always) and would create an
             //        inlining cycle
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

### First class function values

Swift allows for functions as first class objects. They can be assigned to
variables and passed as arguments. The reference function of a function value
cannot be reliably be determined at the usage and is therefore not diagnosed as
an error (case 4).

```swift
@inline(always)
func callee() {}

func use(_ f: () -> ()) {
    f()
}
func useFunctionValue() {
  let f = callee
  ...
  f()         // function value use, may be inlined but not diagnosed if not
  use(callee) // function value use, may be inlined in `use()` but not diagnosed
              // if not
}
```

### Protocol methods

Protocol constraint or protocol typed values require a dynamic computation to
determine the eventual method called. Inferring the value of the eventual method
called at compile time is not possible in general and the success of inlining
cannot be ensured. We don't diagnose a usage site error if the underlying method
is marked with `@inline(always)` (case 4)

```swift
protocol P {
    func method()
}
struct S : P {
    @inline(always)
    func method() {}
}
final class C : P {
    @inline(always)
    func method() {}
}

@inline(always)
func generic<T: P> (_ t: T) {
    t.method()
}

func f() {
    let p: P = S()
    p.method() // might not get inlined, not diagnosed
    generic(S()) // might not get inlined, not diagnosed
    let p2: P = C()
    p2.method() // might not get inlined, not diagnosed
    generic(C()) // might not get inlined, not diagnosed
}
```

### Optimization control as optimization hint

A clever optimizer might be able to derive the dynamic value at the
call site, in such cases the optimizer shall respect the optimization control
and perform inlining.

In the following example the functions will be inlined when build with higher
optimization levels than `-Onone`.

```swift
@inline(always)
func binaryOp<T>(_ left: T, _ right: T, _ op: (T, T) -> T) -> T {
   op(left, right)
}

@inline(always)
func add(_ left: Int, _ right: Int) -> Int { left + right }

print(binaryOp(5, 10, add))
print(binaryOp(5, 10) { add($0, $1) })
```


### Interaction with `@inlinable`

`@inlinable` makes the function body available to clients (callers in other
modules) in library evolution mode. Functions with `open`, `public`, or
`package` level access cause emission of an ABI entry point for clients to call
but in the absence of aforementioned attributes do not make the body available
to the client.

`@inline(always)` intention is to be able to guarantee that inlining will happen
for any caller inside or outside the defining module therefore it makes sense to
require the use of an `@inlinable` attribute with them. This attribute could be
required to be explicitly stated. And for it to be an error when the attribute
is omitted.

```swift
@inline(always)
@inlinable
public func caller() { ... }

@inline(always) // error: a public function marked @inline(always) must be marked @inlinable
public func callee() {
}
```

Alternatively, the attribute could be implicitly implied by the usage of
`@inline(always)`. We take the position that it should be implied to avoid the
redundancy of spelling it out.

For access levels equal and lower than `internal` `@inlinable` is not implied.

As a consequence all the rules that apply to `@inlinable` also apply to
`public`/`open`/`package` declarations marked with `@inline(always)`.

```swift
internal func g() { ... }

@inline(always)
public func inlinableImplied() {
    g() // error: global function 'g()' is internal and cannot be referenced from an
    '@inlinable' function
}
```

### Interaction with `@usableFromInline`

A `public` `@inlinable` function can reference a function with `internal` access
if it is either `@inlinable` (see above) or `@usableFromInline`. `@usableFromInline`
ensures that there is a public entry point to the `internal` level function but
does not ensure that the body of the function is available to external
modules. Therefore, it is an error to combine `@inline(always)` with a
`@usableFromInline` function as we cannot guarantee that the function can
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

To mark `internal`, `private` and `fileprivate` function declarations
with `@inline(always)` does not imply the `@inlinable` attribute's semantics.
They can only be referenced from within the module. `internal` declarations can
be marked with `@inlinable` if this is required by the presence of other
`@inlinable` (or public `@inline(always)`) functions that reference them.


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
public func caller() {
  if coldPath {
    callee()
  }
}

public func otherCaller() {
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
would be displayed. The argument was made that this would ensure that authors
would be aware of the additional semantics implied by the attribute: the body is
exposed. This was juxtaposed by the argument that spelling both `@inlinable` and
`@inline(always)` is redundant.

## Acknowledgments

Thanks to [Jordan Rose](https://forums.swift.org/t/optimization-controls-and-optimization-hints/81612/7) for pointing out that inlining can't be always guaranteed, specifically the case of closures.
Thanks to [Xiaodi Wu](https://forums.swift.org/t/pitch-inline-always-attribute/82040/7) for proposing inferring `@inlinable`.
Thanks to [Tony Allevato](https://github.com/swiftlang/swift-evolution/pull/2958#discussion_r2379238582) for suggesting to error on on non-final methods and
providing editing feedback.
Thanks to [Doug Gregor](https://github.com/DougGregor), [Joe Groff](https://github.com/jckarter), [Tim Kientzle](https://github.com/tbkka), and [Allan Shortlidge](https://github.com/tshortli) for discussions related to the feature.
