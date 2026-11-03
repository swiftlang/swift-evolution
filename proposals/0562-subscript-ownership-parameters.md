# Ownership for Subscript Parameters

* Proposal: [SE-0562](0562-subscript-ownership-parameters.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Active Review (November 3...17, 2026)**
* Implementation: [swiftlang/swift#91992](https://github.com/swiftlang/swift/pull/91992)
* Experimental Feature Flag: `SubscriptParametersWithOwnership`
* Review: ([pitch](https://forums.swift.org/t/pitch-ownership-for-subscript-parameters/89461))([review](https://forums.swift.org/t/se-0562-ownership-for-subscript-parameters/90429))

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
struct FileHandle: ~Copyable { /* ... */ }

struct A {
  subscript(file: borrowing FileHandle) -> Int {
    get { ... }
    set { ... }
  }
}

func f<T, U>(_: inout T, _: inout U) { }

var a = A()
var file = FileHandle()
f(&a[file], &file) // error: exclusivity conflict because "file" is borrowed by the subscript, mutated by the inout
```

### Consuming subscript parameters require single-call access paths

When the subscript argument is `consuming`, any permissible access pattern (read, write, `inout`) must be implementable with a single accessor call. For example, if the subscript has `borrow` and `mutate` accessors, the `borrow` accessor can be used for reading while the `mutate` accessor can be used for writing a value or passing it `inout`. On the other hand, if a subscript has only `get` and `set` accessors, the only way to provide `inout` access is to call `get` into a temporary value, pass the address of the temporary as `inout`, and then call `set` with the updated temporary value. However, when the subscript argument is `consuming`, there is a problem: the call to `get` consumes the argument, so there is no argument for the paired call to `set`. Therefore, this combination is prohibited: 

```swift
struct C1 {
  subscript(c: consuming FileHandle) -> Int { // error: 'consuming' may not be used on the parameter of a subscript with only 'get' and 'set' accessors
    get { ... }
    set { ... }
  }
}
```

The easiest fix here is to also introduce a `yielding mutate` operation, which can be provided [in addition to `get` and `set`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0474-yielding-accessors.md#yielding-mutate-1). It will be used for `inout` access, while `set` will be used when writing the whole value:

```swift
struct C1Fixed {
  subscript(c: consuming FileHandle) -> Int {
    get { ... }
    set { ... }
    yielding mutate { ... }
  }
}
```

`get`-only subscript accessors may have `consuming` parameters, as can the coroutine accessors (`borrow` or `mutate`, whether `yielding` or not), because in such cases there is only a single accessor call for any access pattern. For example:

```swift
struct C2 {
  subscript(cg: consuming FileHandle) -> Int { // okay, there is no set
    get { ... }
  }
}

struct C3 {
  subscript(cg: consuming FileHandle) -> Int { // okay, coroutine accessor
    borrow { ... }
    mutate { ... }
  }
}

struct C4 {
  subscript(cg: consuming FileHandle) -> Int { // okay, coroutine accessor
    yielding borrow { ... }
    yielding mutate { ... }
  }
}
```

Here are the potential combinations accessors when at least one of the subscript arguments is `consuming`:

| Readaccessor          | Write accessor | inout accessor        | Can parameter be `consuming`? |
| --------------------- | -------------- | --------------------- | ----------------------------- |
| `get`                 |                |                       | ✅                             |
| `get`                 | `set`          |                       | ❌                             |
| `get`                 | `set`          | `yielding mutate`     | ✅                             |
| `get`                 |                | (`yielding`) `mutate` | ✅                             |
| (`yielding`) `borrow` |                |                       | ✅                             |
| (`yielding`) `borrow` |                | (`yielding`) `mutate` | ✅                             |
| (`yielding`) `borrow` | `set`          |                       | ❌                             |
| (`yielding`) `borrow` | `set`          | (`yielding`) `mutate` | ✅                             |

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
