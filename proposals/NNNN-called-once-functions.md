# `@once` functions

* Proposal: [SE-NNNN](NNNN-called-once-functions.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin), [Allan Shortlidge](https://github.com/tshortli)
* Review Manager: TBD
* Status: **Awaiting review**
* Bug: [swiftlang/swift#NNNNN](https://github.com/swiftlang/swift/issues/NNNNN)
* Experimental Feature Flag: `OnceFunctions`
* Previous Proposal: Revives [SE-0073](0073-noescape-once.md)
* Review: ([first pitch](https://forums.swift.org/t/89088)) ([second pitch](https://forums.swift.org/t/90515))

## Introduction

This proposal introduces a `@once` attribute for closures that execute exactly once and `@callable(once)` for closures that execute at most once. Making execution semantics visible to the compiler lets it diagnose incorrect uses of these functions, and it lets these closures safely consume noncopyable captures and form `sending` captures of non-`Sendable` values.

## Motivation

The Swift compiler currently has no visibility into the intended execution semantics of functions. It is not knowable whether a function should be executed at most once, exactly once, or perhaps multiple times. Without understanding programmer intent, it is not possible to diagnose incorrect implementations.

```swift
func executeOnce(fn callOnce: () -> Void) {
  callOnce()
  ...
  callOnce() // <- no error
}
```

Further, this deprives the compiler of information that could be used to better reason about the usage of captures. How many times a closure can be executed has implications for both concurrency and lifetime analyses. Right now, the compiler must always make the pessimistic assumption that a closure could be called more than once. This places artificial limits on code with non-`Sendable` captures:

```swift
class NonSendable {}

func sendAgain(_ ns: sending NonSendable) {}

func captureSending(_ ns: sending NonSendable) {
  Task {
    sendAgain(ns) // error: sending 'ns' risks causing data races
  }
}
```

An even more severe restriction is imposed for values of noncopyable types, which closures cannot consume at all:

```swift
struct NonCopyable: ~Copyable {
   consuming func use() {}
}

func executeOnce(_ fn: () -> Void) {
  fn()
}

func takeValue(_: consuming NonCopyable) { }

func testConsumption() {
  let nc = NonCopyable() // error: noncopyable 'nc' cannot be consumed when captured by an escaping closure or borrowed by a non-Escapable type

  executeOnce {
    takeValue(nc) // note: consumed here
  }
}
```

The same pessimism prevents escaping closures from capturing `self` implicitly. A closure that can be called repeatedly may form a long-lived reference cycle with `self`, so programmers must state their intent to capture `self` explicitly:

```swift
func executeLater(_ fn: @escaping () -> Void) { ... }

class Counter {
  var count = 0

  func incrementLater() {
    executeLater {
      count += 1 // error: reference to property 'count' in closure requires explicit use of 'self' to make capture semantics explicit
    }
  }
}
```

The `Task` initializers are exempt from this rule because they run their closures once and then release them, but the exemption is expressed with the compiler-internal `@_implicitSelfCapture` attribute, which is not part of the supported language.

All of these restrictions could be lifted for closures that are guaranteed to execute at most once.

Execution semantics for closures were proposed once before. [SE-0073](0073-noescape-once.md) proposed a `@noescape(once)` attribute in 2016, primarily so that a closure could initialize `let` variables captured from its parent scope, and the proposal was rejected. Since then, [SE-0390](0390-noncopyable-structs-and-enums.md) introduced noncopyable types, and [SE-0414](0414-region-based-isolation.md) and [SE-0430](0430-transferring-parameters-and-results.md) introduced region-based isolation and `sending` values. Both features make the number of times a closure executes relevant to far more code than definite initialization alone, and they provide the ownership model that this proposal builds on.

## Proposed solution

We propose that an exactly-once execution guarantee be expressed with a new `@once` attribute on a function type. A `@once` function type does not conform to `Copyable`, and calling a `@once` value is a consuming operation, making it an error to call the value more than once. Additionally, `@once` functions must be consumed on every path, either by being called or by being transferred to another owner, so they are never destroyed without being called.

An at-most-once execution guarantee is expressed with a new `@callable(once)` attribute on a function type. These function types also do not conform to `Copyable` and their values are consumed by calling them. Unlike `@once` functions, though, a `@callable(once)` value is not required to be consumed on every path, and therefore may be implicitly destroyed without being called.

For closures with these attributes, the compiler is no longer forced to make pessimistic assumptions about the lifetimes of captures and can relax some restrictions. These closures can consume captures that have unique ownership, since there's no risk of a second call needing to consume the value again. Additionally, `@once` and `@callable(once)` closures may form `sending` captures since it is guaranteed that those captures will no longer be referenced after the closure has been consumed. Finally, closures with these types may capture `self` implicitly since they are consumed when called and therefore are unlikely to introduce a reference cycle with their owned captures.

## Detailed design

### Syntax

`@once` and `@callable(once)` are new attributes that apply to function types:

```swift
func callOnce(_ c: @once () -> Void) { c() }
func callAtMostOnce(_ c: @callable(once) () -> Void) { }
```

Both attributes can also be written in the type position of a closure signature:

```swift
let onceClosure = { @once in }
let atMostOnceClosure = { @callable(once) in }
```

A function type may have at most one of `@once` and `@callable(once)`. `@callable` requires the `once` argument, and `@once` does not accept an argument. It is an error to apply either attribute to a non-function type.

### Called-once semantics

Both `@once` and `@callable(once)` function types are noncopyable. Calling a noncopyable function value consumes the value, so calling it more than once is an error:

```swift
func callExactlyOnceTwice(_ c: @once () -> Void) {
  c()
  c() // error: 'c' is consumed more than once
}

func callAtMostOnceTwice(_ c: @callable(once) () -> Void) {
  c()
  c() // error: 'c' is consumed more than once
}
```

As with values of other noncopyable types, passing these values to `consuming` parameters and returning them from functions are consuming operations, as is storing a `@callable(once)` value in a property.

Exiting a function without calling a `@once` function value is rejected, but `@callable(once)` values may be destroyed without being called:

```swift
func dropsTrivially(_ f: @once () -> Void) { // error: 'f' is not called on all paths
}

func dropsConditionally(_ f: @once () -> Void, _ condition: Bool) { // error: 'f' is not called on all paths
  if condition { return }
  f()
}

func throwsBeforeCalling(_ f: @once () -> Void) throws(Failure) { // error: 'f' is not called on all paths
  throw .someError
  f()
}

func dropsOK(_ f: @callable(once) () -> Void) { }
```

Paths that end in a call to a function that returns `Never`, such as `fatalError()`, are exempt from the requirement to call a `@once` function value:

```swift
func hasPrecondition(_ f: @once () -> Void, _ condition: Bool) {
  guard condition else {
    // ok, 'f' is not called but the program crashes
    fatalError("precondition failed")
  }
  f()
}
```

#### Limits of the exactly-once guarantee

The compiler enforces `@once` semantics by requiring every context that owns a `@once` value to consume it, either by calling it or by transferring ownership of it to another context. This is what the compiler can feasibly prove, and it means that "exactly once" must be understood as "exactly once, unless the value never reaches the point where it would be called." A `@once` value is not called if:

- the context that owns it fails to make forward progress because it loops forever or suspends indefinitely,
- the program exits (either normally or by trapping) before the owner consumes the value, or
- ownership of the value is transferred to a context that is never destroyed, such as a closure that is kept alive by a reference cycle or by a global variable.

The guarantee also depends on whether the value is escaping. A non-escaping `@once` value is guaranteed to have been called exactly once if the function that it was passed to returns or throws. An escaping `@once` value can outlive that function, so it is only guaranteed to have been called exactly once if no context still holds a reference to it.

### Parameter conventions

Parameters with noncopyable types typically must be explicitly declared `consuming`, `borrowing`, or `inout`. Since calling a `@once` or `@callable(once)` function always consumes it, parameters with these function types are implicitly `consuming`:

```swift
func callOnce(_ c: /*consuming*/ @once () -> Void) {
  c()
}
```

These parameters may instead be explicitly declared `borrowing`. As with other `borrowing` parameters of noncopyable types, the callee does not own the value and cannot consume it, so it cannot call the value, store it, or pass it to a `consuming` parameter. The callee may still use the value in ways that do not consume it, such as reading the `isolation` property of an `@isolated(any)` function or passing the value to another `borrowing` parameter:

```swift
func isolation(of job: borrowing @once @isolated(any) () async -> Void) -> (any Actor)? {
  job.isolation // ok, reading 'isolation' does not consume 'job'
}
```

A borrowed `@callable(once)` value may be passed to a `borrowing` parameter of a generic type that suppresses `Copyable`, but a borrowed `@once` value may not, since generic parameters are implicitly required to be `Deinitable`.

Attempting to call a borrowed `@once` or `@callable(once)` value is diagnosed:

```swift
func callBorrowed(_ job: borrowing @once () -> Void) {
  job() // error: 'job' is borrowed and cannot be called
}
```

Since a borrowing callee does not own a `@once` value, it is not obligated to call it. That obligation stays with the caller, which still owns the value after the callee returns and must consume it on every path.

Parameters with these function types may also be declared `inout`, and they follow the same rules as `inout` parameters of other noncopyable types. The callee may call the parameter, but if it does, it must reinitialize the parameter before it returns or throws:

```swift
func callAndReplace(_ f: inout @once () -> Void) {
  f()
  f = { ... } // ok, reinitializes 'f'
}

func callWithoutReplacing(_ f: inout @once () -> Void) { // error: missing reinitialization of inout parameter 'f' after consume
  f()
}
```

Since assigning to a variable destroys its previous value, the callee may not assign to an `inout` `@once` parameter that it has not consumed. A `@callable(once)` parameter may be reassigned without being called:

```swift
func replaceOnce(_ f: inout @once () -> Void) {
  f = { ... } // error: 'f' is reassigned without being first consumed
}

func replaceAtMostOnce(_ f: inout @callable(once) () -> Void) {
  f = { ... } // ok, the previous value of 'f' is destroyed without being called
}
```

The callee is not obligated to call an `inout` `@once` parameter. Whether or not the callee calls it, the caller owns the parameter's value after the callee returns, so the caller remains obligated to consume it.

Like ordinary function types in parameter positions, `@once` and `@callable(once)` types are not escaping unless the `@escaping` attribute is specified. As with ordinary function types, the types of `inout` parameters are always escaping.

### Implicit `self` capture

`@once` and `@callable(once)` closures are consumed when called, which also destroys their captures. This means that executing one of these closures will break any cycle that might have been formed between the closure and a value that it was temporarily stored in. For a cycle to persist, a closure that captures `self` and is stored in a property of `self` would have to never be called, which is possible but would usually constitute a programming mistake. As a result, escaping `@once` and `@callable(once)` closures are not required to capture `self` explicitly. The body of such a closure may refer to members of `self` without writing `self.`, just as the body of a non-escaping closure may. These attributes therefore subsume the role of the compiler-internal `@_implicitSelfCapture` attribute in APIs like `Task` creation.

### Closure captures

#### `consuming` captures

The guarantee that a closure is called at most once allows the closure to consume captured values that have unique ownership, so `@once` or `@callable(once)` closures are the only closures that may form consuming captures. Whether a capture is consuming is inferred from how the closure body uses it.

A capture of a noncopyable value is inferred to be consuming if the closure body applies a [consuming operation](0390-noncopyable-structs-and-enums.md#consuming-operations) to it, such as calling a `consuming` method or using the `consume` operator:

```swift
struct S: ~Copyable {
  consuming func call() {}
}

func completeOnce(_ completion: @callable(once) () -> Void) { completion() }

func consumingCapture(s: consuming S) {
  completeOnce {
    s.call() // 's' is consumed by the closure
  }
}
```

A closure takes ownership of its consuming captures when it's formed. If the closure is called, its body may consume its captures, transfer ownership of them elsewhere, or let them be destroyed implicitly. If the closure is not called, its captures are destroyed with it.

This consuming capture inference rule is independent of the existing `[v = consume s]` capture list syntax that consumes a value while forming the closure. That syntax moves the consumed value into a new binding at the point the closure literal is evaluated, regardless of what kind of closure it is. It can be combined with the inference above, though: once `v` is captured, whether the *body* is allowed to consume `v` still depends on the enclosing closure being `@once` or `@callable(once)`, exactly as it would for an implicit capture of `s`:

```swift
func consumingCapture(s: consuming S) {
  completeOnce { [v = consume s] in
    let otherV = v // 'v' is consumed by the closure, same as an implicit capture of 's' would be
    ...
  }
}
```

#### `sending` captures

The guarantee that a function is called at most once also allows the closure to send captured values with non-`Sendable` types to a different isolation region. A `@once` or `@callable(once)` closure may declare that a captured value is `sending`, allowing the closure body to perform operations that merge values in a disconnected region into an actor-isolated region or re-send captured values by passing them to a `sending` parameter:

```swift
class NS {}

// A hypothetical Task initializer that has adopted `@once`.
struct Task {
   init(_: @escaping @once () async -> Void)
}

@MainActor func mergeToMain(_ ns: NS) {}

func acceptSending(_ ns: sending NS) {}

func sendingCaptures() {
  let ns1 = NS()
  Task { [sending ns1] in
    await mergeToMain(ns1) // ok, merges 'ns1' into the main actor's region
  }

  let ns2 = NS()
  Task { [sending ns2] in
    acceptSending(ns2) // ok, sends 'ns2' again
  }
}
```

The grammar of capture specifiers now includes `sending`:

```
capture-specifier → weak | unowned | unowned(safe) | unowned(unsafe) | sending
```

A capture list item has at most one capture specifier, so `sending` cannot be combined with `weak` or `unowned`. It is an error to declare a `sending` capture in a closure that is not `@once` or `@callable(once)`.

The captures of `@once` and `@callable(once)` closures may also be inferred to be `sending` under the following circumstances:

- If the closure is non-escaping, then `sending` is inferred for each of its non-`Sendable` captures that the body of the closure sends. A captured value that the body does not send is still available to be used after the destruction of the closure.

- If the closure is `sending`, then all of its non-`Sendable` captures are jointly sent by default.

Sending inference may be overridden by explicitly declaring a capture without `sending` in the capture list.

Inference allows callers of non-escaping APIs that adopt `@once` or `@callable(once)` to send captured values without modifying their call sites.

### Type system impact

#### Deinitable protocol

In type theory, `@callable(once)` functions are examples of "affine" types because their values can either be consumed once or destroyed without being consumed. Swift models affine types using noncopyability and therefore `@callable(once)` function types are noncopyable. `@once` function types are noncopyable too, but they are also Swift's first instances of "linear" types. A value of a linear type must be consumed exactly once and cannot be implicitly destroyed.

A new invertible marker protocol named `Deinitable` models types in Swift whose values may be implicitly destroyed. All types in Swift except for `@once` function types implicitly conform to `Deinitable`. Linear types, such as `@once` function types, must suppress both `Copyable` and `Deinitable`, and they cannot have a `deinit`, since it would never be called. A value of a linear type must be consumed exactly once on every path.

`Deinitable` is declared in the standard library alongside the existing invertible protocols, `Copyable` and `Escapable`:

```swift
@_marker public protocol Copyable: Deinitable {}
@_marker public protocol Escapable {}
@_marker public protocol Deinitable {}
```

`Copyable` now refines `Deinitable`, so every copyable type is deinitable. This refinement limits the cost of introducing a third invertible protocol. Since a `Copyable` requirement implies a `Deinitable` requirement, the generic signatures of declarations that do not suppress `Copyable` are unchanged. Only generic parameters that suppress `Copyable` gain a separate implicit `Deinitable` requirement. The refinement is not essential to the model, and it could be removed in the future without affecting ABI or source compatibility.

This proposal does not allow developers to interact with the `Deinitable` protocol directly. Written references to `Deinitable` are always rejected, so creating arbitrary `~Deinitable` types or writing generic code in terms of `Deinitable` is not possible. These restrictions could be lifted in the future if Swift gains support for user-defined linear types.

#### Function conversions

Because `@once` and `@callable(once)` restrict how a function may be called, they adjust Swift's general function conversion rules as follows:

Let $f$ and $g$ be function types where $f'$ and $g'$ are the same function types with `@once` and `@callable(once)` attributes removed. Then $f$ is convertible to $g$ if $f'$ is convertible to $g'$ and one of the following is true:

* $f$ and $g$ are both ordinary, both `@callable(once)`, or both `@once`.
* $f$ is ordinary and $g$ is either `@callable(once)` or `@once`.
* $f$ is `@callable(once)` and $g$ is `@once`.

Otherwise, $f$ is not convertible to $g$. The following table summarizes these rules:

| From \ To         | Ordinary | `@callable(once)` | `@once` |
|-------------------|:--------:|:-----------------:|:-------:|
| Ordinary          | ✅       | ✅                | ✅      |
| `@callable(once)` | ❌       | ✅                | ✅      |
| `@once`           | ❌       | ❌                | ✅      |

Since these rules extend the general function conversion rules, they also apply contravariantly to parameters and covariantly to results when they are nested inside other function types. For example, `(@once () -> Void) -> Void` is convertible to `(() -> Void) -> Void`, but `() -> @once () -> Void` is not convertible to `() -> () -> Void`.

#### Protocol witnesses

In accordance with function conversion rules, a method or subscript witness for a protocol requirement may add `@once` or `@callable(once)` to a parameter, but it may not drop either attribute from a parameter where the requirement declares it. Conversely, a witness may return an ordinary function where the requirement declares a `@once` or `@callable(once)` result, but it may not return a `@once` or `@callable(once)` function where the requirement declares an ordinary result. The compiler synthesizes a thunk for any permitted mismatch. As with the existing allowances for `@escaping` and `@Sendable`, these differences are permitted only at the top level of a parameter or result type; the attributes must match exactly in nested function types. A property witness must also match the `@once` and `@callable(once)` attributes of its requirement exactly, since the type of a property witness must generally be the same as the type of its requirement.

```swift
protocol P {
  func apply(_ f: () -> Void)
  func applyOnce(_ f: @once () -> Void)
  func produceCallableOnce() -> @callable(once) () -> Void
  func produceCallable() -> () -> Void
  var callableOnce: @callable(once) () -> Void { get }
}

struct S: P {
  func apply(_ f: @once () -> Void) { ... } // ok
  func applyOnce(_ f: () -> Void) { ... } // error
  func produceCallableOnce() -> () -> Void { ... } // ok
  func produceCallable() -> @callable(once) () -> Void { ... } // error
  var callableOnce: () -> Void { ... } // error
}
```

#### Overrides

Overrides of class members may not vary in their use of `@once` and `@callable(once)`. An overriding method, property, or subscript must declare `@once` and `@callable(once)` in exactly the same positions as the declaration it overrides, even where the [function conversion rules](#function-conversions) would allow the difference:

```swift
class Base {
  func apply(_ f: () -> Void) { ... }
  func produceCallableOnce() -> @callable(once) () -> Void { ... }
}

class Derived: Base {
  override func apply(_ f: @once () -> Void) { ... } // error
  override func produceCallableOnce() -> () -> Void { ... } // error
}
```

#### Function overloading

Like `@escaping`, the `@once` and `@callable(once)` attributes are ignored when determining whether two declarations are valid overloads or invalid redeclarations. However, `@once` and `@callable(once)` parameters are implicitly `consuming`, and overloads may already differ in the ownership conventions of their parameters. As a result, an overload with a `@once` or `@callable(once)` parameter may coexist with an overload that has an ordinary function-typed parameter with the default convention. An existing API that takes an ordinary function can therefore gain an overload that accepts either a `@once` or a `@callable(once)` parameter.

When more than one overload is applicable, overload resolution prefers the most specific match. An ordinary function is convertible to a `@callable(once)` function, and either one is convertible to a `@once` function. An overload with an ordinary parameter is therefore more specific than an overload with a `@callable(once)` parameter, which is in turn more specific than an overload with a `@once` parameter. The same applies to `@autoclosure` parameters. A closure literal or an ordinary function value resolves to the ordinary overload, and only a `@callable(once)` or `@once` function value resolves to the `@once` overload:

```swift
func apply(_ f: () -> Void) { ... }
func apply(_ f: @once () -> Void) { ... }

func produceCallable() -> () -> Void { ... }
func produceAtMostOnce() -> @callable(once) () -> Void { ... }
func produceOnce() -> @once () -> Void { ... }

apply { ... }              // calls apply(_: () -> Void)
apply(produceCallable())   // calls apply(_: () -> Void)
apply(produceAtMostOnce()) // calls apply(_: @once () -> Void)
apply(produceOnce())       // calls apply(_: @once () -> Void)
```

As a result, introducing a `@once` or `@callable(once)` overload alongside an existing API does not change the overload that existing calls resolve to.

This is true even when the body of a closure literal requires at-most-once semantics, such as when it consumes a noncopyable capture or declares a `sending` capture. Unless the closure is explicitly marked `@once` or `@callable(once)`, it resolves to the ordinary overload and the call is rejected. See [Implications on adoption](#implications-on-adoption) for ways that a library can offer a new overload that closure literals resolve to.

Overloads can also differ in other ways, such as whether they are `async`. Execution semantics only make one overload more specific than another when the overloads are otherwise comparable. If execution semantics are the only reason that neither overload is more specific than the other, the overloads are compared as though their parameters had the same execution semantics:

```swift
func withValue(_ operation: @once () -> Void) { ... }
func withValue(_ operation: () async -> Void) async { ... }

func test() async {
  withValue { ... } // calls withValue(_: @once () -> Void)
}
```

A `@once` function is not convertible to an ordinary `async` function, and an `async` function is not convertible to a synchronous one, so without this rule neither overload would be more specific. When both overloads take ordinary functions, the synchronous overload is more specific. Ignoring execution semantics in this case means that adopting `@once` or `@callable(once)` in one overload of an API does not make existing calls ambiguous.

Overloads whose parameters differ only in execution semantics, and not in ownership conventions, are invalid redeclarations. This includes overloads that differ only in whether a parameter is `@once` or `@callable(once)` when both parameters have the same ownership convention. It also includes an overload with a `@once` or `@callable(once)` parameter and an overload with an ordinary escaping function-typed parameter that is explicitly `consuming`:

```swift
func apply(_ f: @once () -> Void) { ... }
func apply(_ f: @callable(once) () -> Void) { ... } // error: invalid redeclaration

func run(_ f: consuming @escaping () -> Void) { ... }
func run(_ f: @escaping @once () -> Void) { ... } // error: invalid redeclaration
```

Overloads also may not differ only in the execution semantics of their results. This is true even when one of the results is an ordinary function type, and it applies anywhere within the result type, such as in the wrapped type of an optional result:

```swift
func produce() -> () -> Void { ... }
func produce() -> @once () -> Void { ... } // error: invalid redeclaration

func produceHandler() -> @callable(once) () -> Void { ... }
func produceHandler() -> @once () -> Void { ... } // error: invalid redeclaration

func produceOptional() -> (() -> Void)? { ... }
func produceOptional() -> (@callable(once) () -> Void)? { ... } // error: invalid redeclaration
```

Subscripts follow the same rules as functions.

#### Unapplied references to `consuming` methods

`consuming` methods of noncopyable types are implicitly `@callable(once)`. This lifts the restriction on taking an unapplied reference to such a method:

```swift
struct Box<T: ~Copyable>: ~Copyable {
  var value: T
  consuming func take() -> T { value }
}

let box = Box<Int>(value: 10)
let fn /*: @callable(once) () -> Int*/ = box.take
```

### Safe conversions of `@once` to `@callable(once)`

Function conversion rules do not allow a `@once` function to be converted to a `@callable(once)` function, since the recipient of a `@callable(once)` function might not call it. Sometimes, though, the programmer knows something about the dynamic behavior of an API that the API's signature does not promise. For example, an API that reports its outcome by calling exactly one of two handlers cannot declare either handler `@once`, since each handler on its own might not be called. Instead, both handlers must be `@callable(once)`. A caller that has a `@once` completion handler knows that exactly one of the two handlers will be called, but it cannot call its completion handler from either of them, since a `@callable(once)` closure may be destroyed without being called and therefore cannot take ownership of a `@once` capture:

```swift
func fetch(
  onSuccess: @escaping @callable(once) (String) -> Void,
  onFailure: @escaping @callable(once) (any Error) -> Void
) { ... }

func fetch(completion: @escaping @once (Result<String, any Error>) -> Void) {
  fetch(
    onSuccess: { completion(.success($0)) }, // error: consumed capture 'completion' of 'Deinitable'-conforming closure has non-'Deinitable' type
    onFailure: { completion(.failure($0)) }  // error: consumed capture 'completion' of 'Deinitable'-conforming closure has non-'Deinitable' type
  )
}
```

To bridge this gap, a new standard library function modeled on the existing [`withoutActuallyEscaping(_:do:)`](https://docs.swift.org/latest/documentation/swift/withoutactuallyescaping(_:do:)/) allows `@once` values to be safely converted to `@callable(once)` values:

```swift
func withoutActuallyDeiniting<ClosureType, ResultType, Failure: Error>(
  _ closure: ClosureType,
  do body: (_ deinitableClosure: ClosureType) throws(Failure) -> ResultType
) throws(Failure) -> ResultType
```

Like `withoutActuallyEscaping(_:do:)`, the relationship between the types of the `closure` and `deinitableClosure` parameters of `withoutActuallyDeiniting(_:do:)` cannot be expressed in the type system, so the compiler type checks calls to it specially. The type of `closure` must be a `@once` function type, and the type of `deinitableClosure` is the same function type with `@once` replaced by `@callable(once)`. Passing a function that is not `@once` is an error.

Also like `withoutActuallyEscaping(_:do:)`, `withoutActuallyDeiniting(_:do:)` accepts `async` functions. `closure` may be an `async` function and `body` may be an `async` closure, and when `body` is `async`, the call must be marked with `await`:

```swift
func runAfterSetUp(_ work: @once () async -> Void) async {
  await withoutActuallyDeiniting(work) { deinitableWork in
    await setUp()
    await deinitableWork()
  }
}
```

The isolation of `body` is inferred like that of any other non-escaping closure, so a call to `withoutActuallyDeiniting(_:do:)` never changes the executor that `body` runs on. In an actor-isolated context, `body` has the same isolation as its context, unless the closure states a different isolation explicitly. In a `nonisolated(nonsending)` function, including a `nonisolated` `async` function when the `NonisolatedNonsendingByDefault` upcoming feature is enabled, an `async` `body` is `nonisolated(nonsending)`.

`withoutActuallyDeiniting(_:do:)` consumes `closure` and passes a `@callable(once)` wrapper of it to `body`. The wrapper may be used like any other `@callable(once)` value. The wrapper enforces the exactly-once requirement dynamically: if it is destroyed without being called, the program traps.

The `deinitableClosure` parameter of `body` has the same escapability as `closure`. If `closure` is non-escaping, then `deinitableClosure` is non-escaping too, and it must be called exactly once before `body` returns or throws. The program traps no later than the exit from `body` if it was not called. If `closure` is `@escaping`, then `deinitableClosure` is an `@escaping @callable(once)` function that may outlive `body`. This allows a `@once` function to be passed to an API that stores its `@callable(once)` argument and calls it later:

```swift
final class Scheduler {
  // Calls `work` at a later time, unless the scheduler is shut down first.
  func schedule(_ work: @escaping @callable(once) () -> Void) { ... }
}

func scheduleOnce(on scheduler: Scheduler, _ work: @escaping @once () -> Void) {
  withoutActuallyDeiniting(work) { deinitableWork in
    scheduler.schedule(deinitableWork) // ok, 'deinitableWork' escapes 'body'
  }
}
```

A `@callable(once)` value is noncopyable, so it can only be owned by one of the two handlers in the `fetch(onSuccess:onFailure:)` example above. To share it, the wrapper can be stored in a class instance that both handlers capture. Whichever handler runs takes the wrapper out of the class instance and calls it:

```swift
final class CompletionBox<Success, Failure: Error> {
  private var completion: (@callable(once) (Result<Success, Failure>) -> Void)?

  init(_ completion: @escaping @callable(once) (Result<Success, Failure>) -> Void) {
    self.completion = consume completion
  }

  func complete(_ result: Result<Success, Failure>) {
    if let completion = completion.take() {
      completion(result)
    }
  }
}

func fetch(completion: @escaping @once (Result<String, any Error>) -> Void) {
  withoutActuallyDeiniting(completion) { deinitableCompletion in
    let box = CompletionBox(deinitableCompletion)
    fetch(
      onSuccess: { box.complete(.success($0)) },
      onFailure: { box.complete(.failure($0)) }
    )
  }
}
```

If neither handler is ever called, the wrapper is destroyed when the last reference to `box` is released, and the program traps.

### Storage

#### `@callable(once)` storage restrictions

The rules governing storage of `@callable(once)` function values are the same rules that apply to noncopyable values in general. They may be bound to local `let` and `var` declarations and may be stored in the properties of classes, actors, and noncopyable structs and in the associated values of noncopyable enums. They may also be stored in global and static variables.

Calling a stored `@callable(once)` value consumes it, so it is subject to the existing rules for consuming noncopyable storage. A `consuming` method of a noncopyable type may call a stored `@callable(once)` property. On the other hand, a stored property of a class or a global variable cannot be consumed directly. The value must be moved out of the storage before it can be called, for example with `Optional.take()`:

```swift
final class Completion {
  var handler: (@callable(once) () -> Void)?

  func complete() {
    if let handler = handler.take() {
      handler()
    }
  }
}
```

#### `@once` storage restrictions

Because they are nondeinitable, `@once` values may only be bound to local `let` and `var` declarations. A `Deinitable` type cannot contain a nondeinitable value because destroying the container would destroy its properties implicitly, and all types in Swift besides `@once` function types are implicitly `Deinitable`. This includes generic types such as `Optional`, whose generic parameters are implicitly required to be `Deinitable`, so a type like `Optional<@once () -> Void>` cannot be formed.

An escaping `@once` value must be converted to a `@callable(once)` value with [`withoutActuallyDeiniting(_:do:)`](#safe-conversions-of-once-to-callableonce) before it can be stored:

```swift
final class Completion {
  var handler: (@callable(once) () -> Void)?

  func setHandler(_ f: @escaping @once () -> Void) {
    withoutActuallyDeiniting(f) { deinitableF in
      handler = consume deinitableF
    }
  }
}
```

In the future, [user-defined linear types](#user-defined-linear-types) could be allowed to store escaping `@once` values as properties.

### C, C++, and Objective-C interoperability

#### Importing `called_once` parameters

Clang's [`called_once`](https://clang.llvm.org/docs/AttributeReference.html#called-once) attribute specifies that a parameter of function pointer or block type is called exactly once on every execution path of the function or method that declares it. These are the same semantics as `@once`, so the Clang importer imports `called_once` parameters as `@once` function types:

```c
void performWork(void (^_Nonnull completion)(int result) __attribute__((called_once)));
```

```swift
func performWork(_ completion: @escaping @once (Int32) -> Void)
```

Since `Optional` requires its wrapped type to be `Deinitable` (see [Storage](#storage)), optional `@once` function types cannot be formed, so `called_once` parameters that are `_Nullable` or `_Null_unspecified` are imported as ordinary optional function types:

```c
void performOptionalWork(void (^_Nullable completion)(int result) __attribute__((called_once)));
```

```swift
func performOptionalWork(_ completion: ((Int32) -> Void)?)
```

Clang has no attribute that specifies at-most-once semantics, so no imported parameter is given a `@callable(once)` type.

Importing a parameter as `@once` is source-compatible for callers, since an ordinary function is convertible to a `@once` function. It is not source-compatible for existing Swift subclasses that override the imported method, or for existing Swift types that conform to an imported protocol, because the [override](#overrides) and [protocol witness](#protocol-witnesses) rules would require those declarations to add `@once`. To preserve source compatibility, an override or witness of an imported declaration that omits `@once` from a `called_once` parameter is diagnosed with a warning instead of an error.

#### Dynamic enforcement

Clang only diagnoses violations of `called_once` with warnings. To preserve memory safety for Swift code using `@once` functions, the compiler generates wrapper closures for values passed as arguments to `called_once` parameters that dynamically enforce that the closure is called exactly once. If the wrapper closure is called more than once or is destroyed without being called, the program traps.

#### Exposing Swift declarations to C and Objective-C

An `@objc` method, initializer, or subscript may have parameters with `@once` function types. In the generated header, a `@once` parameter is annotated with `__attribute__((called_once))`.

`@callable(once)` function types are not allowed anywhere in `@objc` declarations. Objective-C code can receive the argument of a top-level parameter, such as when it implements an `@objc` protocol requirement or overrides a `dynamic` method, and Clang has no attribute to express that the argument must not be called more than once. This restriction could be lifted in the future, either by wrapping the argument to enforce at-most-once semantics dynamically or if Clang gains an attribute to express these semantics.

`@once` and `@callable(once)` function types are not allowed in other positions of `@objc` declarations, such as result types, property types, or the parameters of nested function types. In these positions, Objective-C code would receive the function, and Clang has no way to express the restriction on how many times it may be called.

### Adoption in the standard library

Existing APIs in the standard library that accept closures which are called exactly once or at most once may adopt `@once` or `@callable(once)` for those arguments. For example, the initializers for `Task` should adopt `@once` and `Optional.map(_:)` should adopt `@callable(once)`. Since there are many standard library APIs that ought to be updated, adoption is expected to proceed incrementally following the introduction of the attributes. Every adoption must be done in a way that preserves both source and ABI compatibility.

Adopting `@once` or `@callable(once)` in an API that already calls its closure argument with the corresponding execution semantics does not change the behavior of the API. It only allows the compiler to check that the implementation keeps that promise and to accept more code at call sites. Such adoptions therefore do not require separate evolution proposals, including when ABI compatibility requires an adoption to introduce a new entry point alongside the existing one. Adoptions that would change the behavior of an API, rename it, or otherwise change how existing call sites are written will be proposed separately.

## Source compatibility

### Callers of adopting APIs

Narrowing the execution semantics of a function-typed parameter, such as by making an ordinary parameter `@callable(once)` or a `@callable(once)` parameter `@once`, is source-compatible for callers, since a function is convertible to any function type with narrower execution semantics. Widening the execution semantics of a parameter is source-breaking for callers, on the other hand, since fewer types of functions would be compatible with the new parameter type.

Introducing a `@once` or `@callable(once)` overload alongside an existing API does not change the overload that existing calls resolve to either. Neither does adopting the attributes in one overload of an API that has other overloads (see [Function overloading](#function-overloading)).

### Implementations of adopting APIs

In the implementation of the function that takes a function type parameter, the effects of narrowing and widening execution semantics are reversed. Narrowing the execution semantics of a function parameter adds new restrictions to the uses of the parameter and therefore is not source-compatible. For example, if the existing function body calls the parameter more than once, attempts to copy it, or passes it to another function that expects an ordinary closure, then that existing body would be rejected. Likewise, changing a `@callable(once)` parameter to `@once` would reject a body that does not consume the parameter on every path.

### Capture inference

[Consuming captures](#consuming-captures) and [`sending` captures](#sending-captures) are inferred in a way that preserves source compatibility for existing callers of APIs that adopt `@once` or `@callable(once)`:

- No closure can consume a noncopyable capture today. Since consuming captures are only inferred for captures that a closure body applies a consuming operation to, existing closure bodies are not affected.
- A non-escaping closure that is not `sending` cannot send any of its non-`Sendable` captures today. Since `sending` is only inferred for the captures that a closure body sends, the existing body of a closure passed to such a parameter is not affected, and uses of its captures after the call continue to be accepted.
- The non-`Sendable` captures of a `sending` closure are already sent jointly today, so adopting `@once` or `@callable(once)` does not change how those captures are treated.
- `sending` is never inferred for the captures of an escaping closure that is not `sending`.

### Imported `called_once` parameters

Importing `called_once` parameters as `@once` is source-compatible for callers for the same reasons that adopting the attribute on an existing function parameter is source-compatible. For existing Swift overrides of imported methods or for existing witnesses of imported protocol requirements, the mismatch is diagnosed with a warning instead of an error when they omit `@once` (see [Importing `called_once` parameters](#importing-called_once-parameters)).

## ABI compatibility

While adding `@once` or `@callable(once)` to an ordinary closure parameter of an existing public API is a source-compatible change, it is **not** an ABI-compatible one. Narrowing the execution semantics of a parameter changes the calling convention used to pass the argument from `borrowing` to `consuming`. See [Implications on adoption](#implications-on-adoption) for how libraries built with library evolution can adopt the attributes while preserving their existing entry points.

Switching a parameter or result between `@once` and `@callable(once)` is not ABI-compatible either, in any position. The compiler may assume that a `@once` closure is never destroyed without being called, so it would be unsafe for an existing client to pass a `@once` closure to a library that changed the parameter to `@callable(once)`. The two attributes are distinguished in the mangling of function types, so changing one to the other changes the symbol names of the declarations that use the type.

The execution semantics of a function type are recorded in its type metadata, and a new version of the runtime is required to demangle the names of function types with `@once` or `@callable(once)`. When code that uses these function types is deployed to an earlier runtime, the compiler emits calls to metadata accessor functions instead of relying on the runtime to demangle those names, so the code can still be back deployed.

## Implications on adoption

Adopting `@once` and `@callable(once)` does not require a new runtime, since code deployed to earlier runtimes avoids runtime demangling of these function types (see [ABI compatibility](#abi-compatibility)).

Code that is built without library evolution can freely adopt `@once` and `@callable(once)` for any existing API whose closure parameters already have the corresponding execution semantics. Libraries that are built with library evolution, on the other hand, must introduce new APIs in order to adopt the attributes, since modifying an existing API would break ABI compatibility. If the new APIs can be back deployed using `@backDeployed` or `@export(implementation)`, then those new APIs can subsume the existing ones for callers. The subsumed API only needs to be preserved as an ABI compatibility stub for existing clients, which can be done with a `@usableFromInline internal` copy that is renamed and preserves its symbol name with `@abi`. When back deploying replacement APIs is not possible, they must be introduced alongside the existing APIs instead, either as overloads or with entirely new names.

When a replacement is introduced as an overload, the existing overload is [more specific](#function-overloading), so a closure literal resolves to it even where the replacement is available. To make the replacement the only choice wherever it can be used, the existing API can be marked as obsoleted in the release that introduces the replacement:

```swift
@available(macOS, obsoleted: 27)
public func apply(_ f: () -> Void) { ... }

@available(macOS 27, *)
public func apply(_ f: @once () -> Void) { ... }
```

Calls in contexts where the replacement is unavailable continue to resolve to the existing API. Calls in contexts where the replacement is available resolve to it, including calls within an `if #available(macOS 27, *)` check. Since an ordinary function is convertible to a `@once` function, existing calls and references that resolve to the replacement continue to be accepted.

## Prior art

### Rust

Every Rust closure implements one or more of the `FnOnce`, `FnMut`, and `Fn` traits, depending on how its body uses its captures. The call method of each trait accesses the closure differently: `FnOnce::call_once` takes `self` by value, `FnMut::call_mut` takes `&mut self`, and `Fn::call` takes `&self`. Calling an `FnOnce` closure therefore consumes it, so its body may move captured values out of the closure. Calling an `FnMut` closure requires exclusive access to it, so its body may mutate its captures, while calling an `Fn` closure only requires shared access. The following table compares Swift function types with the most similar Rust closure traits:

| Swift function type          | Rust closure trait   |  Captures |     Number of calls     |
| ---------------------------- | -------------------- | :-------: | :---------------------: |
| `@Sendable () -> Void`       | `Fn() + Send + Sync` |  Borrowed |           Any           |
| `() -> Void`                 | `Fn()`               |  Borrowed |           Any           |
| —                            | `FnMut()`            | Exclusive | Any (never overlapping) |
| `@callable(once) () -> Void` | `FnOnce()`           |  Consumed |       At most one       |
| `@once () -> Void`           | —                    |  Consumed |       Exactly one       |

Rust has no counterpart to `@once`, since every Rust type can be implicitly dropped. Swift has no counterpart to `FnMut`, but one is described as a [future direction](#function-types-with-exclusive-captures).

### Kotlin

Kotlin's [contracts](https://kotlinlang.org/docs/whatsnew13.html#contracts) allow an inline function to declare how many times it invokes a lambda argument with `callsInPlace(block, InvocationKind.EXACTLY_ONCE)`, or with the `AT_MOST_ONCE` and `AT_LEAST_ONCE` invocation kinds. The compiler uses an `EXACTLY_ONCE` contract to allow the lambda to initialize a `val` declared outside of it, which is the capability described in [Allow non-escaping `@once` functions to initialize captured variables](#allow-non-escaping-once-functions-to-initialize-captured-variables). Unlike `@once`, contracts are trusted rather than checked: the compiler does not verify that the function honors its contract.

## Alternatives considered

### Only offer `@callable(once)` without `@once`

Allowing closure-taking APIs to capture noncopyable and non-`Sendable` values is the primary immediate benefit of introducing execution semantics for function types in Swift. That benefit could be achieved just as well by only offering `@callable(once)` function types, which would simplify the language. However, in the future Swift may offer user-defined linear types and only closures with `@once` semantics would be able to capture values of those types, introducing a similar usability gap all over again. While we could wait to introduce `@once` function types until that time, we anticipate that updating APIs throughout the Swift ecosystem to adopt execution semantics will take significant effort to complete and it would be better to only have to perform this migration once. Empirical evidence gathered by reviewing Apple's iOS 27 SDK suggests that `@once` semantics are significantly more common in APIs than `@callable(once)` semantics are, so the magnitude of a second migration to add exactly-once semantics later would be considerable.

Additionally, there are several smaller benefits to `@once` function types:

- Checking that a function calls its closure argument exactly once catches real bugs, even though it does not make new programs expressible.
- Interoperating with C, Objective-C, and C++ is cleaner if Swift has `@once` function types, since Clang's `called_once` attribute can only specify exactly-once semantics. Correctly implementing imported interfaces with `called_once` parameters in Swift requires enforcing exactly-once execution semantics.
- The compiler can optimize the size of code that works with `@once` functions more aggressively, since `@once` functions do not need a destructor that destroys captures in the event that the closure is destroyed without being called.
- In the future, non-escaping `@once` closures could be allowed to [initialize captured variables](#allow-non-escaping-once-functions-to-initialize-captured-variables).

### Only offer `@once` without `@callable(once)`

Since `@once` semantics are most common, Swift could only offer `@once` functions without also offering `@callable(once)`. However, this would forfeit the ability to improve noncopyable and non-`Sendable` type ergonomics for many widely used APIs that call a closure at most once, such as `Optional.map(_:)` and the `@autoclosure` right-hand operand of `&&`.

### Alternative attribute spellings

A few alternatives to `@once` and `@callable(once)` were considered:

- **`@called(exactlyOnce)` and `@called(atMostOnce)`:** These spellings clearly communicate execution semantics and also benefit from the symmetry of sharing a base `@called` attribute. This symmetry comes at the cost of the simplest, most obvious spelling for exactly-once execution semantics, which is `@once`.
- **`@once(exactly)` and `@once(atMost)`:** Variations of this spelling, such as `@once(must)` and `@once(may)`, share a base attribute like the `@called` spellings do while remaining shorter. A bare `@once` could also be reserved as shorthand for whichever variant turns out to be more common. These spellings read awkwardly, though, since they reverse the natural order of the words in phrases like "called at most once."
- **`@noncopyable` and `@nondeinitable`:** An alternative way to view execution semantics is that they are an emergent property of the function type's ownership constraints. Function types could therefore spell out those ownership constraints directly, either with attributes (`@noncopyable` for at-most-once and `@noncopyable @nondeinitable` for exactly-once) or even with conformance suppression syntax (`~Copyable` and `~Copyable & ~Deinitable`). This approach requires the reader to infer what the ownership of the type implies about the behavior of the function, though, which is less clear than describing the execution semantics directly.

Given the prevalence of APIs that take closures which are called exactly once, the attribute for those semantics deserves the most concise and obvious spelling, `@once`. The `callable` base name of `@callable(once)` describes a permission rather than an obligation: the function may be called once, but it need not be. The spelling also remains relatively concise. Finally, a parameterized `@callable` attribute can be extended to support other execution semantics in the future, such as [`@callable(sequentially)`](#function-types-with-exclusive-captures).

### Alternative names for `Deinitable`

The [`Deinitable`](#deinitable-protocol) protocol is introduced in this proposal primarily as an implementation detail of `@once` function types. Developers cannot use it directly, so its impact on the language will be minimal. It could even be renamed later without breaking source or ABI compatibility, since it is a marker protocol and its name is not part of any mangled symbol. However, the protocol name may appear in diagnostics and it should ideally be reused if user-defined linear types are introduced later, so its name matters now. The following alternatives were considered:

- **`Deinitializable`:** This carries exactly the same meaning as `Deinitable` but is more verbose. The "deinit" abbreviation is a term of art in Swift, so shortening `Deinitializable` does not harm clarity.

- **`Discardable`:** Allowing a value to be destroyed without being consumed could be thought of as implicitly discarding the value, and `@discardableResult` uses "discardable" in a similar sense. However, [SE-0390](0390-noncopyable-structs-and-enums.md) established `discard self` as the way to end a value's lifetime *without* running its `deinit`. The lifetime of a nondeinitable value can only end that way, so describing such a type as "non-discardable" would be a contradiction:

  ```swift
  struct ND: ~Copyable, ~Discardable {
    var x: Int
    consuming func consume() {
      discard self // contradicts ~Discardable
    }
  }
  ```

- **`Droppable`:** In Rust, the `drop` method is implicitly called on values of types that implement the `Drop` trait when those values go out of scope without being consumed, which is very similar to Swift's rules for calling `deinit` methods. It would be reasonable to refer to Swift types that cannot be implicitly destroyed as non-droppable. However, "deinit" is a more recognizable term for Swift developers. "Drop" has been used informally to describe this behavior in Swift, such as in [SE-0528](0528-noncopyable-continuation.md), but no Swift language feature uses the term.

- **`Destroyable` or `Destructible`:** Protocol names that evoke destruction would be misleading when inverted. Values of types that suppress the conformance are not immortal. They get destroyed explicitly by a consuming operation rather than implicitly.

- **`Implicitly`-prefixed names, such as `ImplicitlyDestructible`:** Prefixing any of the alternative names with `Implicitly` could increase clarity and resolve misleading implications of names like `Discardable` and `Destroyable`. However, this increase in verbosity is unnecessary for the chosen name `Deinitable` because calls to `deinit` methods are inherently implicit.

`Deinitable` is the best choice because it connects the capability described by the protocol directly to `deinit` methods, which are already familiar to Swift developers. Unlike `~Destroyable`, `~Deinitable` is not misleading when inverted. Values of nondeinitable types are still destroyed, but no `deinit` method ever runs for them. A `deinit` only runs when a value is destroyed implicitly, either when the value goes out of scope without being consumed or at the end of a `consuming` method that neither transfers ownership of `self` nor uses `discard self`. Nondeinitable values may do neither, so a nondeinitable type cannot have a `deinit` method.

### Ban overloading on execution semantics

Swift could ban overloads that differ in whether a parameter is an ordinary function type or a `@once` or `@callable(once)` function type. For libraries built with library evolution, this would mean that a new version of an API that adopts `@once` or `@callable(once)` would need to be back deployed to subsume all uses of the older API. Otherwise, the new version would need an entirely new name. Back deploying the replacement API is preferable, but it is not always feasible since the implementation details of many APIs cannot be exposed (see [Implications on adoption](#implications-on-adoption)). Requiring new names for existing APIs that just need to refine their execution semantics to improve ergonomics is too onerous for a migration that will affect as many APIs as this one does.

### Allow overloading on `@once` compared with `@callable(once)`

Swift could allow overloads that differ only in whether a parameter is `@once` or `@callable(once)`, which [Function overloading](#function-overloading) prohibits when the parameters have the same ownership convention. There isn't a clear use case for allowing this, though, since APIs are generally either obligated to call their arguments or not.

### Import completion handlers as `@once` by convention

Many C and Objective-C APIs take completion handler blocks that are called exactly once by convention, even though their parameters are not annotated with `called_once`. The Clang importer could infer `called_once` for these parameters, for example by using the heuristics that [SE-0297](0297-concurrency-objc.md) uses to identify completion handler parameters when importing methods as `async`. Existing APIs could then benefit from `@once` without any changes to their headers. However, the APIs that these heuristics identify are the same APIs that are imported with `async` alternatives, and typical Swift code is expected to call those alternatives instead, so improving the ergonomics of the completion-handler-based variants is of little value.

### Import nullable `called_once` parameters as optional `@callable(once)` function types

Since optional `@once` function types cannot be formed, nullable `called_once` parameters are [imported](#importing-called_once-parameters) as ordinary optional function types. They could instead be imported as optional `@callable(once)` function types, which would preserve the guarantee that the function is not called more than once and allow callers to pass closures that consume noncopyable captures or form `sending` captures.

However, Swift overrides and witnesses of these imported declarations would then need `@callable(once)` in their signatures, and those declarations are `@objc`. `@callable(once)` is [not allowed](#exposing-swift-declarations-to-c-and-objective-c) in `@objc` declarations because Clang has no attribute that specifies at-most-once semantics. Lifting that restriction would force the generated header to either annotate the parameter with `called_once`, promising stronger semantics than the Swift declaration guarantees, or omit the attribute, losing the semantics when the header is imported back into Swift. Nullable `called_once` parameters are uncommon, so the benefit does not justify this asymmetry. If `Optional` is generalized to allow a `~Deinitable` wrapped type, these parameters could be imported as optional `@once` function types instead (see [User-defined linear types](#user-defined-linear-types)).

### Model execution semantics with a library type or macro

A noncopyable type with a `consuming` call operation can already be called at most once:

```swift
struct CallableOnce<Result>: ~Copyable {
  private let body: () -> Result

  init(_ body: @escaping () -> Result) {
    self.body = body
  }

  consuming func callAsFunction() -> Result {
    body()
  }
}
```

APIs could accept a wrapper like this instead of a closure, and a macro could generate wrappers or insert dynamic checks that trap when a function is called more than once. However, these approaches only restrict how many times a wrapped function is called. The wrapped closure is still an ordinary closure, so its body still cannot consume noncopyable captures, form `sending` captures, or capture `self` implicitly. Those capabilities require the compiler to know the execution semantics of a closure while it type checks the closure's body, which only a language feature can provide. A library type also could not express exactly-once semantics without user-defined nondeinitable types, and it could not represent imported `called_once` parameters.

## Future directions

### User-defined linear types

This proposal does not allow developers to declare `~Deinitable` types or to write generic code over `~Deinitable`. Lifting these restrictions on [`Deinitable`](#deinitable-protocol) would allow developers to define their own linear types, whose values must be consumed exactly once on every path. For example, the `Continuation` type introduced by [SE-0528](0528-noncopyable-continuation.md) traps at runtime if it is destroyed without being resumed. If `Continuation` were nondeinitable, failing to resume it would be a compile-time error instead.

A nondeinitable type could also store an escaping `@once` value as a property, since the containing value could not be implicitly destroyed either:

```swift
struct Completion: ~Copyable, ~Deinitable {
  var handler: @once () -> Void

  consuming func complete() {
    handler()
  }
}
```

Generalizing `Optional` to allow a `~Deinitable` wrapped type would also make it possible to form optional `@once` function types. Nullable `called_once` parameters of C and Objective-C APIs, which are [currently imported](#importing-called_once-parameters) as ordinary optional function types, could then be imported as optional `@once` function types instead.

### Function types with exclusive captures

The addition of `@once` and `@callable(once)` to the language allows closures to consume their captures, which fills an important gap in the capabilities of function types in Swift. As demonstrated in the table below, though, Swift still lacks function types that can borrow captures exclusively:

| Function type                | Number of calls | Concurrent | Reentrant | Captures  | Deinitable |
| ---------------------------- | :-------------: | :--------: | :-------: | :-------: | :--------: |
| `@Sendable () -> Void`       |       Any       |     ✅      |     ✅     | Borrowed  |     ✅      |
| `() -> Void`                 |       Any       |     ❌      |     ✅     | Borrowed  |     ✅      |
| ???                          |       Any       |     ❌      |     ❌     | Exclusive |     ✅      |
| `@callable(once) () -> Void` |   At most one   |     —      |     —     | Consumed  |     ✅      |
| `@once () -> Void`           |   Exactly one   |     —      |     —     | Consumed  |     ❌      |

In the future, this capability could be added to the language using an attribute such as `@callable(sequentially)`, building on the `@callable` attribute introduced by this proposal. Calls to a `@callable(sequentially)` closure would never be allowed to overlap, so each call would have exclusive access to the closure's captures, just like a `mutating` method has exclusive access to `self`. The closure body could therefore consume a captured noncopyable value and reinitialize it before returning:

```swift
struct State: ~Copyable {
  consuming func next() -> State { ... }
}

func makeStepper(_ state: consuming State) -> @callable(sequentially) () -> Void {
  return {
    state = state.next() // ok, 'state' is reinitialized before the call returns
  }
}
```

With an ordinary `() -> Void` result type, this closure is rejected today because an escaping closure cannot consume a noncopyable capture, even temporarily.

### Allow non-escaping `@once` functions to initialize captured variables

Even with this proposal, closures are never allowed to initialize the variables that they capture. Assigning to an uninitialized `let` in a closure is rejected with the error "cannot assign to value: 'value' is a 'let' constant", and capturing an uninitialized `var` is rejected too. However, a non-escaping `@once` closure is guaranteed to be called exactly once before the function it is passed to returns, so this restriction could safely be lifted for those closures:

```swift
func withLock<R>(_ body: @once () -> R) -> R { ... }

let value: Int
withLock { value = compute() } // ok
print(value) // ok, 'value' is definitely initialized
```

A captured variable would only be considered initialized after the function that the closure is passed to returns normally. Control flow in the closure would need to be factored into this analysis.

This was the primary use case of [SE-0073](0073-noescape-once.md). This proposal defers it because integrating closure bodies into definite initialization analysis would add significant complexity to the compiler, and the same result can usually be achieved today by returning a value from the closure:

```swift
let value = withLock { compute() }
```

### Suppress dynamic enforcement for imported `called_once` parameters

As described in [Dynamic enforcement](#dynamic-enforcement), arguments passed to `called_once` parameters of imported C and Objective-C APIs are wrapped in closures that trap if the argument is called more than once or destroyed without being called. The wrapper preserves memory safety, but the checks it performs increase code size and add runtime overhead to every call. These costs may be unacceptable for performance-sensitive APIs.

In the future, the author of a C or Objective-C API could be given a way to assert that the implementation honors `called_once`, allowing Swift to pass arguments to it without incurring overhead from dynamic checks. The assertion could be expressed with a new Clang attribute. Ideally, Clang would enforce this assertion when it compiles the implementation of the API so that it does not risk introducing memory safety issues.

## Acknowledgments

Thank you to [Holly Borla](https://github.com/hborla) for authoring an initial draft of this proposal and for helpful discussion throughout its development. Thank you also to [Aviva Ruben](https://github.com/a-viv-a), [John McCall](https://github.com/rjmccall), and [Slava Pestov](https://github.com/slavapestov) for their feedback.
