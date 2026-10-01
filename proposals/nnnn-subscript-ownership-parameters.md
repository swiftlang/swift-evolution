# Ownership for Subscript Parameters

* Proposal: [SE-NNNN](NNNN-subscript-ownership-parameters.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#91992](https://github.com/swiftlang/swift/pull/91992)
* Experimental Feature Flag: `SubscriptParametersWithOwnership`
* Review: ([pitch](https://forums.swift.org/...))

## Summary of changes

This proposal introduces support for `inout`, `borrowing`, and `consuming` on parameters of subscripts. It brings the capabilities of subscript parameters in line with functions and initializers.

## Motivation

Unlike with functions and initializers, subscript parameters have never been able to be `inout`:

```swift
struct X {
  subscript(oldValue: inout Int) -> Int { // error: 'inout' may only be used on function or initializer parameters
    get {
      // ...
    }
    
    set {
      oldValue = newValue
      // set newValue
    }
  }
}
```

With the introduction of non-copyable types, the existing limitation grew larger: it's not possible to have a subscript parameter of non-copyable type, because neither `borrowing` nor `consuming` parameters are supported for subscripts.

The primary motivation for this proposal is consistency: subscript parameters should be able to work the same way as function parameters unless there is a specific reason for them not to. The need for this feature also came up in the context of extending keypaths to support noncopyable root types, but that's an implementation detail rather than a motivation for the language itself.

## Proposed solution

This proposal lifts this restriction on subscript parameters, bringing them into line with functions and initializers. The code in the "Motivation" section will be accepted. Additionally, one can also use a non-copyable type as a parameter, either borrowing it:

```swift
struct Y1 {
  subscript(resourceHandle: borrowing Resource) -> Data {
    get { ... }
    set { ... }
  }
}

struct Y2 {
  subscript(resourceHandle: borrowing Resource) -> Data {
    borrow { ... }
    mutate { ... }
  }
}
```

Or consuming it:

```swift
struct Z {
  subscript(resourceHandle: consuming Resource) -> Span<UInt>{
    borrow { ... }
    mutate { ... }
  }
}
```

## Detailed design

The most interesting aspect of the design for this feature centers on the access to the arguments themseves. For example, when passing an argument with some kind of ownership specifier (`inout`, `borrowing`, `consuming`), the argument must remain fixed while the function call happens. For example, when calling a function and passing a local variable to an `inout`, nothing else can access that local variable for the duration of the call. Doing so will produce an "exclusivity violation", like this:

```swift
func doSomething<T>(on value: inout T, body: () -> Void) { }
var x = 17
doSomething(on: &x) { _ in print(x) } // error: exclusivity violation
```

Subscripts make this more interesting, because using a subscript might involve more than one call. For example:

```swift
struct MyMapping {
  subscript(i: Int) -> String { 
    get { ... }
    set { ... }
  }
}

var mapping = MyMapping(...)
doSomething(on: &mapping[17]) { ... }
```

To pass `mapping[17]` as `inout` , Swift will first call the subscript's `get` operation and store the result in a temporary. The address of that temporary is then passed down to `doSomething(on:)`. Once that function returns, Swift calls the subscript's `set` operation, providing it with the temporary value.

For an integer parameter that receives a copy, the same value `i` is passed both times. However, when the subscript argument is `borrowing` or `inout`, the argument must remain fixed for the duration of the call to `doSomething(on:)`, so that the same index value is provided to both the `get` and the `set`. Consider another case with a borrowing subscript argument:

```swift
struct NC: ~Copyable { }

struct A {
  subscript(nc: borrowing NC) -> Int {
    get { ... }
    set { ... }
  }
}

func f<T, U>(_: inout T, _: inout U) { }

var a = A()
var nc = NC()
f(&a[nc], &nc) // error: exclusivity conflict because "nc" is borrowed by the subscript, mutated by the inout
```

### Consuming subscript parameters are incompatible with get/set accessors

When the subscript argument is `consuming`, the subscript cannot define both a `get` and `set` accessor. An `inout` access to such a subscript would first call the `get`, which would consume the argument. Then, there would be no argument that remains when the subscript access has completed and the `set` needs to get called.

```swift
struct C1 {
  subscript(c: consuming NC) -> Int { // error: 'consuming' may not be used on the parameter of a subscript whose read and write go through separate accessors
    get { ... }
    set { ... }
  }
}
```

`get`-only subscript accessors may have `consuming` parameters, as can the coroutine accessors (`borrow` or `mutate`, whether `yielding` or not), because in such cases there is only a single accessor call. For example:

```swift
struct C2 {
  subscript(cg: consuming NC) -> Int { // okay, there is no set
    get { ... }
  }
}

struct C3 {
  subscript(cg: consuming NC) -> Int { // okay, coroutine accessor
    borrow { ... }
    mutate { ... }
  }
}

struct C4 {
  subscript(cg: consuming NC) -> Int { // okay, coroutine accessor
    yielding borrow { ... }
    yielding mutate { ... }
  }
}
```

## Source compatibility

This is a pure language extension with no effect on source compatibility.

## ABI compatibility

This feature's ABI is derived from that of functions with ownership specifiers. It does not affect the ABI of existing subscripts.

## Future Directions

### Allow different conventions on different accessors

The limitation on `consuming` parameters for subscripts that support `get` and `set` could be lifted by allowing different ownership on `get` vs. `set`. For example, `get` could borrow the argument and then `set` could consume it. One might make a similar distinction between the `borrow` and `mutate` accessors if, for example, the argument is meant to be consumed as part of changing the value.

This feature would be a pure extension. The hardest part about designing this extension is defining the syntax, because subscript declarations have a single parameter list and this extension necessarily requires us to have the ownership be different between different declarations. It's only worth extending the language syntax if there are enough sufficiently-compelling use cases.

### Producing non-escapable results that depend on subscript arguments

At the time of this writing, Swift's lifetimes feature is still experimental. However, the combination of this proposal with lifetimes implies that one can produce a non-escapable result from a subscript whose lifetime depends on one of its arguments. For example:

```swift
struct SomeType {
  subscript (index: borrowing NonCopyableType) -> OtherNonCopyableType {
    @_lifetime(copy index)
    get { ... }
  }
}
```

This feature is expected to work with whatever lifetime system is finalized for Swift.
