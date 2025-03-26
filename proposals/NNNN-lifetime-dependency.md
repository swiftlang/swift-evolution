# Compile-time Lifetime Dependency Annotations

* Proposal: [SE-NNNN](NNNN-lifetime-dependency.md)
* Authors: [Andrew Trick](https://github.com/atrick), [Meghana Gupta](https://github.com/meg-gupta), [Tim Kientzle](https://github.com/tbkka), [Joe Groff](https://github.com/jckarter/)
* Review Manager: TBD
* Status: **Implemented** in `main` branch, with the `LifetimeDependence` experimental feature flag
* Review: ([pitch 1](https://forums.swift.org/t/pitch-non-escapable-types-and-lifetime-dependency/69865))

## Introduction

We would like to propose an attribute for Swift function, initializer, method, and property accessor declarations that allow authors to specify lifetime dependencies between a declaration's return value and one or more of its parameters.

This is deeply related to `~Escapable` types, as introduced in [SE-0446](0446-non-escapable.md). This proposal exposes the underyling mechanisms used by the standard library to implement [SE-0447](0447-span-access-shared-contiguous-storage.md)'s `Span` and [SE-0467](0467-MutableSpan.md)'s `MutableSpan` types, as well as the new APIs for creating instances of these types from standard library collections added in [SE-0456](0456-stdlib-span-properties.md), providing a consistent framework by which user-defined types and functions can also express lifetime dependencies.

**Edited** (March 20, 2025):

- Replaced `dependsOn` return type modifier with a declaration-level `@lifetime` attribute.
    Removed dependency inference rules.
- Integrated links to proposals SE-0446 (`Escapable`), SE-0447 (`Span`), SE-0456 (`Span`-producing properties), and SE-0467 (`MutableSpan`) that have undergone review.
- Added SE-0458 `@unsafe` annotations to the `_overrideLifetime` standard library functions, and added `@unsafe` as a requirement for APIs using `BitwiseCopyable` lifetime dependencies under strict memory safety.

**Edited** (April 12, 2024): Changed `@dependsOn` to `dependsOn` to match the current implementation.

**Edited** (May 2, 2024): Changed `StorageView` and `BufferReference` to `Span` to match the sibling proposal.

**Edited** (May 30, 2024): Added the following new sections:

- Dependent parameters
- Dependent properties
- Conditional dependencies
- Immortal lifetimes
- Depending on immutable global variables
- Depending on an escapable BitwiseCopyable value
- Standard library extensions
- unsafeLifetime helper functions
- Dependency semantics by example
- Future directions
  - Value component lifetime
  - Abstract lifetime components
  - Protocol lifetime requirements
  - Structural lifetime dependencies

**Edited** (June 9, 2024):

- New section: Immortal requirements
- New alternative considered: dependsOn(unchecked) to disable lifetime dependence checking
- Updated future direction: component lifetime syntax
- New example: Escapable properties in a nonescapable type

**Edited** (July 31, 2024)

- New alternative considered: @lifetime annotation
- New alternative considered: where clause
- Simplified implicit lifetime dependencies and added same-type rule

**Edited** (Aug 13, 2024)
- Revised the same-type rule

**Edited** (Aug 19, 2024)
- Update Future Direction: Lifetime dependence for closures

#### See Also

* [Forum discussion of Non-Escapable Types and Lifetime Dependency](https://forums.swift.org/t/pitch-non-escapable-types-and-lifetime-dependency)
* [Pitch Thread for Span](https://forums.swift.org/t/pitch-safe-access-to-contiguous-storage/69888)
* [Forum discussion of BufferView language requirements](https://forums.swift.org/t/roadmap-language-support-for-bufferview)
* [Proposed Vision document for BufferView language requirements (includes description of ~Escapable)](https://github.com/atrick/swift-evolution/blob/fd63292839808423a5062499f588f557000c5d15/visions/language-support-for-BufferView.md#non-escaping-bufferview) 
* [First pitch thread for lifetime dependencies](https://forums.swift.org/t/pitch-non-escapable-types-and-lifetime-dependency/69865)

## Motivation

An efficient way to provide one piece of code with temporary access to data stored in some other piece of code is with a pointer to the data in memory.
Swift's `Unsafe*Pointer` family of types can be used here, but as the name implies, using these types is not statically safe and can be error-prone.

For example, suppose `ContiguousArray` had a property `unsafeBufferPointer` that returned an `UnsafeBufferPointer` to the contents of the array.
Here's an attempt to use such a property:

```swift
let array = getContiguousArrayWithData()
let buff = array.unsafeBufferPointer
parse(buff) // <== 🛑 NOT SAFE!
```

One reason for this unsafety is because Swift's standard lifetime rules only apply to individual values.
They cannot guarantee that `array` will outlive `buff`, which means there is a risk that the compiler might choose to destroy `array` before the call to `parse`, which could result in `buff` referencing deallocated memory.
(There are other reasons that this specific example is unsafe, but the lifetime issue is the one that specifically concerns us here.)

Library authors trying to support this kind of code pattern today have a few options, but none are entirely satisfactory:

* The client developer can manually insert `withExtendedLifetime` and similar annotations to control the lifetime of specific objects.
  This is awkward and error-prone.
  We would prefer a mechanism where the library author can declare the necessary semantics and have the compiler automatically enforce them.
* The library author can store a back-reference to the container as part of their "pointer" or "slice" object.
  However, this incurs reference counting overhead which sacrifices some of the performance gains that pointer-based designs are generally intended to provide.
  In addition, this approach is not possible in environments that lack support for dynamic allocation.
* The library author can make the pointer information available only within a scoped function, but this is also unsafe, as demonstrated by well-meaning developers who extract the pointer out of such functions using code like that below.
  Even when used correctly, scoped functions can lead to a pyramid of deeply-indented code blocks.

```swift
// 🛑 The following line of code is dangerous!  DO NOT DO THIS!
let buff = array.withUnsafeBufferPointer { $0 }
```

## Proposed solution

A "lifetime dependency" between two objects indicates that one of them can only be destroyed *after* the other.
This dependency is enforced entirely at compile time; it requires no run-time support.
These lifetime dependencies can be expressed in several different ways, with varying trade-offs of expressiveness and ease-of-use.

### Background: `Escapable` and Non-`Escapable` Types

[SE-0446](0446-non-escapable.md) introduced the `Escapable` protocol for controlling lifetime dependency of types.
Normal Swift types are `Escapable` by default.
This implies that they can be returned, stored in properties, or otherwise "escape" the local context.
Conversely, types can be suppress this implicit assumption of escapability by being declared as `~Escapable`.
Values of types that are not known to be `Escapable` are not allowed to escape the local context except in very specific circumstances.

By themselves, non-`Escapable` types have severe constraints on usage.
For example, consider the `Span` type from [SE-0447](0447-span-access-shared-contiguous-storage.md). It simply holds a pointer and size and can be used to access data stored in a contiguous block of memory.

```swift
// This is not necessarily the exact definition from the standard library, but
// is close enough to serve as an example.
public struct Span<T>: ~Escapable {
  private var base: UnsafePointer<T>
  private var count: Int
}
```

Because the `Span` type is marked as unconditionally `~Escapable`, it cannot be returned from a function or even initialized without some way to relax the escapability restrictions.
[SE-0456](0456-stdlib-span-properties.md) imbued `span` accessors on certain standard library types with specific lifetime relationships that allowed for only those accessors to return `Span` instances, and [SE-0467](0467-MutableSpan.md) subsequently did the same for `mutableSpan` accessors on those same types.
This proposal supersedes those special cases with a general-purpose mechanism for providing a set of constraints that can tie the lifetime of a non-`Escapable` value to the lifetime of other values.

### Lifetime Dependency Annotations

Let's consider adding support for our hypothetical `Span` type to `ContiguousArray`.
Our proposal will allow you to declare an `array.span` property as follows:

```swift
extension ContiguousArray {
  var span: Span<Element> {
    @lifetime(borrow self)
    borrowing get {
        ... construct a Span ...
    }
  }
}
```

The annotation `@lifetime(borrow self)` here indicates that the returned value must not outlive the array that produced it.
Futhermore, the originating array value behaves as if it is borrowed for the duration of the `span`'s lifetime, meaning not only that the array cannot be destroyed, but also cannot be modified while the `span` is alive.
Conceptually, the `span` acts as a continuation of the function's borrowing access:
the array is borrowed by the function while the function executes and then continues to be borrowed by the result of `span` for as long as the return value exists.
Specifically, the `@lifetime(borrow self)` annotation in this example informs the compiler that:

* The array must not be destroyed until after the `Span<Element>` is destroyed.
  This ensures that use-after-free cannot occur.
* The array must not be mutated while the  `Span<Element>` value exists.
  This follows the usual Swift exclusivity rules for mutation; mutation requires exclusive access, so cannot occur during a borrowing access.
  However, just like a variable can undergo multiple simultaneous borrowing accesses, so can multiple `Span`s depend on borrowing the same origin `array`.
  In this case, the `array` is borrowed until the end of the lifetimes of all of its borrow-dependent values.

#### Scoped Lifetime Dependency

Let's now consider the `MutableSpan<T>` type from [SE-0467](0467-MutableSpan.md), which provides indirect mutating access to a block of memory.
Here's one way such a value might be produced from an owning array:

```swift
@lifetime(inout to)
func mutatingSpan<Element>(to: inout ContiguousArray<Element>, count: Int) -> MutatingSpan<Element> {
  ... construct a MutatingSpan ...
}
```

We’ve written this example as a free function rather than as a method to show how this annotation syntax can be used to express constraints that apply to a particular parameter other than `self`.
The `@lifetime(inout to)` annotation indicates that the returned value depends on the argument named `to`.
Because `count` is not mentioned in the lifetime dependency, that argument does not participate.
Instead of `borrow`, this annotation uses the `inout` keyword to indicate that the returned span depends on **mutating** exclusive access to the `to` parameter rather than borrowed access.

Similar to the previous example:

* The array will not be destroyed until after the `MutableSpan<Element>` is destroyed.

However, by contrast with the previous `borrow` dependency:

* No other read or write access to the array will be allowed for as long as the returned value exists, since the dependency requires exclusivity.

In both the `inout` and the `borrow` dependency case, the lifetime of the return value is "scoped" to an access into the lifetime of the original value.
Because lifetime dependencies can only be attached to non-`Escapable` values, types that contain pointers will generally need to be non-`Escapable` in order to provide safe semantics.
As a result, **scoped lifetime dependencies** are the only possibility whenever a non-`Escapable` value (such as `Span` or `MutableSpan`) gets its dependency from an `Escapable` value (such as `ContiguousArray` or similar container).

#### Copied Lifetime Dependency

A non-`Escapable` value can also derive its dependency from another non-`Escapable` value, but this case is somewhat different.
For instance, `Span` has an `extracting` method that returns another `Span` referring to a subrange of the same memory referenced by the original `Span`.
This method can be declared as follows:

```swift
struct Span<T>: ~Escapable {
    @lifetime(copy self)
    func extracting(_ range: Range<Int>) -> Span<T> {
        ...make derived span...
    }
}
```

In this example, the non-`Escapable` result doesn't depend on the first non-`Escapable` value that it was derived from.
Recall that non-`Escapable` values such as these represent values that are already lifetime-constrained to another value; in this case, the returned `Span` is ultimately dependent on the same owning value as the original `Span`.

To express this, the return value can "copy" the lifetime dependency from the original:
If the original `Span` was borrowing some array, the new `Span` will continue to borrow the same array.

This supports coding patterns such as this:
```swift
var a: ContiguousArray<Int>
let ref1 = a.span // ref1 cannot outlive a
let ref2 = ref1.extracting(4 ..< ref1.count) // ref2 also cannot outlive a
```

After `ref1.extracting(4 ..< ref1.count)`, the lifetime of `ref2` does not depend on `ref1`.
The `extracting` method **copies** `ref1`s lifetime depenence onto `ref2`.
`ref2` effectively **inherits** the same lifetime dependency on `a` as `ref1`.
We may also refer to a lifetime dependence that has been copied from another value as an "inherited" dependence.
Since both `ref1` and `ref2` have borrowing scoped dependencies on `a`, they can be used simultaneously:

```
print(ref1[0])
print(ref2[0])
```

`ref2` can continue to be used after the end of `ref1`'s lifetime, as long as `a` remains valid:

```
_ = consume ref1 // explicitly end ref1's lifetime here
print(ref2[0]) // OK, ref2 is still valid

_ = consume a // explicitly end a's lifetime here
print(ref2[0]) // error: ref2 cannot exceed a's lifetime
```

`a` cannot be mutated or destroyed until both `ref1` and `ref2` have expired:

```
a.append(1) // error: 'a' is borrowed by 'ref1' and 'ref2'
_ = consume ref2
a.append(1) // error: 'a' is borrowed by 'ref1'
_ = consume ref1
a.append(1) // OK
```

Note that non-`Escapable` values can still have scoped dependencies on other non-`Escapable` values as well.
This comes up frequently with `MutableSpan` due to its interaction with exclusivity.
Since there can only be one mutating reference to a mutable value at any time, `MutableSpan`'s version of the `extracting` method must pass off that responsibility to the extracted `MutableSpan` for the latter value's lifetime and prevent overlapping access through the base `MutableSpan` until the extracted `MutableSpan` is no longer usable. It can achieve this by giving the extracted `MutableSpan` a scoped dependency:

```
extension MutableSpan {
  @lifetime(inout self)
  mutating func extracting(_ range: Range<Int>) -> MutableSpan<Element> {
    ...
  }
}
```

Since the return value of `extracting` has a scoped `inout` dependency on the original `MutableSpan`, the original cannot be accessed while the new value is active.
When the extracted `MutableSpan` ends its lifetime, the exclusive access to the original ends, making it available for use again, thereby allowing for the derivation of new `MutableSpan`s without violating exclusivity.

### Allowed Lifetime Dependencies

The previous sections described **scoped lifetime dependencies** and **copied lifetime dependencies** and showed how each type occurs naturally in different use cases.

Now let's look at the full range of possibilities for explicit constraints.
The syntax is somewhat different for functions and methods, though the basic rules are essentially the same.

**Functions:** A simple function with an explicit lifetime dependency annotation generally takes this form:

```swift
@lifetime(<dependency-kind> arg)
func f(arg: ArgType) -> ResultType
```

Where

*  *`dependency-kind`* is one of the dependency specifiers **`borrow`**, **`inout`**, or **`copy`**, and
* `ResultType` must be non-`Escapable`.

If the `ArgType` is `Escapable`, the dependency specifier must be `borrow` or `inout` and return value will have a new scoped dependency on the argument.
(This is the only possibility, since an `Escapable` value cannot have an existing lifetime dependency, so we cannot copy its lifetime dependency.)
The specifier must further correspond to the ownership of `arg`: if `arg` has no ownership specified, or is explicitly `borrowing`, then the dependency must be `borrow`.
On the other hand, if `arg` is `inout`, the dependency must also be `inout`.
(A scoped dependency cannot be formed on a `consuming` parameter.)

A scoped dependency ensures that the argument will not be destroyed while the result is alive.
Also, access to the argument will be restricted for the lifetime of the result following Swift's usual exclusivity rules:

* A `borrowing` parameter-convention extends borrowing access, prohibiting mutations of the argument, but allowing other simultaneous borrowing accesses.
* An `inout` parameter-convention extends mutating access, prohibiting any other access to the argument f, whether borrowing or mutating.
* A `consuming` parameter-convention is illegal, since that ends the lifetime of the argument immediately.

If the `ArgType` is non-`Escapable`, then it can have a pre-existing lifetime dependency.
In this case, in addition to `borrow` or `inout`, a `copy` dependency-kind is allowed, to indicate that the returned value has the same dependency as the argument.
`borrow` and `inout` dependency kinds continue to work as for `Escapable` types, and indicate that the returned value has a scoped lifetime dependency based on an access to the argument, making the returned value even further lifetime-constrained than the argument going in.

**Methods:** Similar rules apply to lifetime dependencies on `self` in methods.
Given a method of this form:

```swift
@lifetime(<dependency-kind> self)
<mutation-modifier> func method(... args ...) -> ResultType
```

The behavior depends as above on the dependency-kind and whether the defining type is `Escapable`.
For a method of an `Escapable` type, the dependency-kind must be `borrow self` for a `borrowing` method, or `inout self` for a `mutating` method, and lifetime dependencies are not allowed on `self` in a `consuming` method.
For a method of a non-`Escapable` type, the dependency-kind may additionally be `copy self`.

**Initializers:** An initializer can also define lifetime dependencies on one or more arguments.
In this case, we use the same rules as for “Functions” above
by using the convention that initializers can be viewed as functions that return `Self`:

```swift
@lifetime(<dependency-kind> arg)
init(arg: ArgType)
```

#### Dependent Parameters

Normally, lifetime dependence is required when a non-`Escapable` function result depends on an argument to that function. However, `inout` parameters of non-`Escapable` type also express an operation that results in a new non-`Escapable` value as a result of mutation by calling the function, so that function parameter may also depend on another argument to a function call. The target of a dependency can be expressed before a colon in a `@lifetime` attribute:

```swift
@lifetime(span: borrow a)
func mayReassign(span: inout Span<Int>, to a: ContiguousArray<Int>) {
  span = a.span
}
```

`@lifetime(self:)` can also be used to indicate that a `mutating` method's implicit `self` depends on another parameter after being mutated.

```swift
extension Span {
  @lifetime(self: copy other)
  mutating func reassign(other: Span<T>) {
    self = other
  }
}
```

We've discussed how a non-`Escapable` result must be destroyed before the source of its lifetime dependence. Similarly, a dependent argument must be destroyed before an argument that it depends on. The difference is that the dependent argument may already have a lifetime dependence when it enters the function. The new function argument dependence is additive, because the call does not guarantee reassignment. Instead, passing the 'inout' argument is like a conditional reassignment. After the function call, the dependent argument carries both lifetime dependencies.

```swift
  let a1: ContiguousArray<Int> = ...
  var span = a1.span
  let a2: ContiguousArray<Int> = ...
  mayReassign(span: &span, to: a2)
  // 'span' now depends on both 'a1' and 'a2'.
```

The general form of a `@lifetime` attribute is:

```swift
@lifetime(target: <dependency-kind> source)
```

where `target` can be elided to refer to the return value of the declaration.

#### Dependent properties

Structural composition is an important use case for non-`Escapable` types. Getting or setting a non-`Escapable` computed property requires lifetime dependence, just like a function result or an 'inout' parameter:

```swift
struct Container<Element>: ~Escapable {
  var element: Element {
    @lifetime(copy self)
    get { ... }

    @lifetime(self: copy newValue)
    set { ... }
  }

  @lifetime(copy element)
  init(element: Element) { ... }
}
```

### Conditional lifetime dependencies

Conditionally non-`Escapable` types can also contain potentially non-`Escapable` elements:

```swift
struct Container<Element: ~Escapable>: ~Escapable {
  var element: Element

  @lifetime(copy element)
  init(element: Element) { self.element = element }

  @lifetime(copy self)
  func getElement() -> Element { element }
}

extension Container: Escapable where Element: Escapable { }
}
```

Here, `Container` is non-`Escapable` only when its element type is non-`Escapable`. Whenever `Container` is potentially non-`Escapable`, it inherits the lifetime of the single `element` argument to the initializer and propagates that lifetime to all uses of its `element` property or the `getElement()` function.

In some contexts, however, the `Element` is known to conform to `Escapable`, which in turn makes `Container<Element>` for that `Element` type `Escapable`. When generic substitution produces an `Escapable` type, any `@lifetime` dependencies applied to that type are ignored.

```
let s = "strings are immortal"
var s2: String
do {
    let c = Container<String>(element: s)
    s2 = c.getElement()
}
print(s2) // OK, String is Escapable, so it isn't affected by the lifetime dependency
```

### Immortal lifetimes

In some cases, a non-`Escapable` value must be constructed without any object that can stand in as the source of a dependence. Consider the standard library `Optional` or `Result` types, which became conditionally `Escapable` in [SE-0465](0465-nonescapable-stdlib-primitives.md):

```swift
enum Optional<Wrapped: ~Escapable>: ~Escapable {
  case none, some(Wrapped)
}

extension Optional: Escapable where Wrapped: Escapable {}

enum Result<Success: ~Escapable, Failure: Error>: ~Escapable {
  case failure(Failure), success(Success)
}

extension Result: Escapable where Success: Escapable {}
```

When constructing an `Optional<NotEscapable>.none` or `Result<NotEscapable>.failure(error)` case, there's no lifetime to assign to the constructed value in isolation, and it wouldn't necessarily need one for safety purposes, because the given instance of the value doesn't store any state with a lifetime dependency. Instead, the initializer for cases like this can be annotated with `@lifetime(immortal)`:

```swift
extension Optional where Wrapped: ~Escapable {
  @lifetime(immortal)
  init(nilLiteral: ()) {
    self = .none
  }
}
```

The constructed instance is returned to the caller without any lifetime dependence. The caller can pass that instance
along as an argument to other functions, but those functions cannot escape it. The instance can only be returned further
up the call stack by chaining multiple `@lifetime(immortal)` functions.

#### Depending on immutable global variables

Another place where immortal lifetimes might come up is with dependencies on global variables. When a value has a scoped dependency on a global let constant, that constant lives for the duration of the process and is effectively perpetually borrowed, so one could say that values dependent on such a constant have an effectively infinite lifetime as well. This will allow returning a value that depends on a global by declaring the function's return type with `@lifetime(immortal)`:

```swift
let staticBuffer = ...

@lifetime(immortal)
func getStaticallyAllocated() -> BufferReference {
  staticBuffer.bufferReference()
}
```

#### Immortal requirements

`@lifetime(immortal)` requires the programmer to compose the dependent value from something that, in fact, has an immortal lifetime:

```swift
@lifetime(immortal)
init() {
  self.value = <global constant>
}
```

`<global constant>` must be valid over the entire program.

`@lifetime(immortal)` is not a way to suppress dependence in cases where the source value has unknown
lifetime.
Composing the result from a transient value, such as an UnsafePointer, is incorrect:

```swift
@lifetime(immortal)
init(pointer: UnsafePointer<T>) {
  self.value = pointer // 🛑 Incorrect
}
```

We could run into the same problem with any transient value, like a file descriptor, or even a class object:

```swift
@lifetime(immortal)
init() {
  self.value = Object() // 🛑 Incorrect
}
```

### Depending on an escapable `BitwiseCopyable` value

The source of a lifetime dependence may be an escapable `BitwiseCopyable` value.
This is useful in the implementation of data types that internally use `UnsafePointer`:

```swift
struct Span<T>: ~Escapable {
  ...
  // The caller must ensure that `unsafeBaseAddress` is valid over all uses of the result.
  @unsafe
  @lifetime(borrow unsafeBaseAddress)
  init(unsafeBaseAddress: UnsafePointer<T>, count: Int) { ... }
  ...
}
```

When the source of a dependence is escapable and `BitwiseCopyable`, then the operation must be marked as `@unsafe` when using strict memory safety as introduced in [SE-0458](0458-strict-memory-safety.md).
By convention, the argument label should also include the word `unsafe` in its name, as in `unsafeBaseAddress` above.
This communicates to anyone who calls the function that they are reponsible for ensuring that the value that the result depends on is valid over all uses of the result.
The compiler can't guarantee safety because `BitwiseCopyable` types do not have a formal point at which the value is destroyed.
Specifically, for `UnsafePointer`, the compiler does not know which object owns the pointed-to storage.

```swift
var span: Span<T>?
let buffer: UnsafeBufferPointer<T>
do {
  let storage = Storage(...)
  buffer = storage.buffer
  span = unsafe Span(unsafeBaseAddress: buffer.baseAddress!, count: buffer.count)
  // 🔥 'storage' may be destroyed
}
decode(span!) // 👿 Undefined behavior: dangling pointer
```

Normally, `UnsafePointer` lifetime guarantees naturally fall out of closure-taking APIs that use `withExtendedLifetime`:

```swift
extension Storage {
  @unsafe
  public func withUnsafeBufferPointer<R>(
    _ body: (UnsafeBufferPointer<Element>) throws -> R
  ) rethrows -> R {
    withExtendedLifetime (self) { ... }
  }
}

let storage = Storage(...)
unsafe storage.withUnsafeBufferPointer { buffer in
  let span = unsafe Span(unsafeBaseAddress: buffer.baseAddress!, count: buffer.count)
  decode(span) // ✅ Safe: 'buffer' is always valid within the closure.
}
```

### Standard library extensions

#### `_overrideLifetime` helper functions

The following helper functions will be added for implementing low-level data types:

```swift
/// Replace the current lifetime dependency of `dependent` with a new copied lifetime dependency on `source`.
///
/// Precondition: `dependent` has an independent copy of the dependent state captured by `source`.
@unsafe @lifetime(copy source)
func _overrideLifetime<T: ~Copyable & ~Escapable, U: ~Copyable & ~Escapable>(
  dependent: consuming T, copying source: borrowing U)
  -> T { ... }

/// Replace the current lifetime dependency of `dependent` with a new scoped lifetime dependency on `source`.
///
/// Precondition: `dependent` depends on state that remains valid until either:
/// (a) `source` is either destroyed if it is immutable,
/// or (b) exclusive to `source` access ends if it is a mutable variable.
@unsafe @lifetime(borrow source)
func _overrideLifetime<T: ~Copyable & ~Escapable, U: ~Copyable & ~Escapable>(
  dependent: consuming T, borrowing source: borrowing U)
  -> T {...}

/// Replace the current lifetime dependency of `dependent` with a new scoped lifetime dependency on `source`.
///
/// Precondition: `dependent` depends on state that remains valid until either:
/// (a) `source` is either destroyed if it is immutable,
/// or (b) exclusive to `source` access ends if it is a mutable variable.
@unsafe @lifetime(inout source)
func _overrideLifetime<T: ~Copyable & ~Escapable, U: ~Copyable & ~Escapable>(
  dependent: consuming T, mutating source: inout U)
  -> T {...}
```

These are useful for non-`Escapable` data types that are internally represented using `Escapable` types such as `UnsafePointer`. For example, some methods on `Span` will need to derive a new `Span` object that copies the lifetime dependence of `self`:

```swift
extension Span {
  consuming func dropFirst() -> Span<Element> {
    let local = Span(base: self.base + 1, count: self.count - 1)
    // 'local' can persist after 'self' is destroyed.
    return unsafe _overrideLifetime(dependent: local, dependsOn: self)
  }
}
```

Since `self.base` is an `Escapable` value, it does not propagate the lifetime dependence of its container. Without the call to `_overrideLifetime`, `local` would be limited to the local scope of the value retrieved from `self.base`, and could not be returned from the method. In this example, `_overrideLifetime` communicates that all of the dependent state from `self` has been *copied* into `local`, and, therefore, `local` can persist after `self` is destroyed.

`_overrideLifetime` can also be used to construct an immortal value where the compiler cannot prove immortality by passing a `Void` value as the source of the dependence:

```swift
@lifetime(immortal)
init() {
  self.value = getGlobalConstant() // OK: unchecked dependence.
  self = unsafe _overrideLifetime(dependent: self, dependsOn: ())
}
```

## Detailed design

### Relation to `Escapable`

The lifetime dependencies described in this document can be applied only to potentially non-`Escapable` return values.
Further, any return value that is potentially non-`Escapable` must declare a lifetime dependency.
In particular, this implies that the initializer for a non-`Escapable` type must have at least one argument or else specify `@lifetime(immortal)`.

```swift
struct S: ~Escapable {
  init() {} // 🛑 Error: ~Escapable return type must have lifetime dependency
}
```

In generic contexts, `~Escapable` indicates that a type is *not required* to be `Escapable`, but the type may be conditionally `Escapable` depending on generic substitutions.
This proposal refers to types in these situations as "potentially non-`Escapable`" types.
Declarations with return types that are potentially non-`Escapable` require lifetime dependencies to be specified, but when those declarations are used in contexts where their result becomes `Escapable` due to the type arguments used, then those lifetime dependencies have no effect:

```swift
// `Optional` is `Escapable` only when its `Wrapped` type is `Escapable`, and
// is not `Escapable` when its `Wrapped` type is not.
//
// In a generic function like `optionalize` below, `T?` is potentially
// non-`Escapable`, so we must declare its lifetime dependency.
@lifetime(copy value)
func optionalize<T: ~Escapable>(_ value: T) -> T? {
    return value
}

// When used with non-Escapable types, `optionalize`'s dependencies are imposed.
var maybeSpan: Span<Int>? = nil
do {
  let a: ContiguousArray<Int> = ...
  
  maybeSpan = optionalize(a.span)
  // `maybeSpan` is now dependent on borrowing `a`, copying the dependency from
  // `a.span` through `optionalize`.
}
print(maybeSpan?[0]) // error, `maybeSpan` used outside of lifetime constraint

// But when used with Escapable types, the dependencies lose their effect.
var maybeString: String? = 0
do {
    let s = "strings are eternal"
    maybeString = optionalize(s)
}
print(maybeString) // OK, String? is `Escapable`, so has no lifetime constraint.
```

### Basic Semantics

A lifetime dependency annotation creates a *lifetime dependency* between a *dependent value* and a *source value*.
This relationship obeys the following requirements:

* The dependent value must be potentially non-`Escapable`.

* The dependent value's lifetime must be as long as or shorter than that of the source value.

* The dependent value is treated as an ongoing access to the source value.
    Following Swift's usual exclusivity rules, the source value may not be mutated during the lifetime of the dependent value;
    if the access is a mutating access, the source value is further prohibited from being accessed at all during the lifetime of the dependent value.

The compiler must issue a diagnostic if any of the above cannot be satisfied.

### Grammar

This proposal adds a `@lifetime` attribute that can be applied to function, initializer, and property accessor declarations:

> *lifetime-attribute* → **`@`** **`lifetime`** **`(`** *lifetime-dependence-list* **`)`**
>
> *lifetime-dependence-list* → (*lifetime-dependence-target-name* **`:`**)? *lifetime-dependence-source* **`,`** *lifetime-dependent-list* **`,`**?
>
> *lifetime-dependence-source* → **`immortal`** | *dependency-kind* *lifetime-dependence-source-name*
>
> *lifetime-dependence-source-name* → **`self`** | *identifier*
>
> *lifetime-dependence-target-name* → **`self`** | *identifier*
>
> *dependency-kind* → **copy** | **borrow** | **inout**

This modifier declares a lifetime dependency for the specified target.
If no *lifetime-dependence-target-name* is specified, then the target is the declaration's return value.
Otherwise, the target is the parameter named by the *lifetime-dependence-target-name*.
The target value must be potentially non-`Escapable`.
Additionally, a parameter used as a target must either be an `inout` parameter or `self` in a `mutating` method.

The source value of the resulting dependency can vary.
For a `borrow` or `inout` dependency, the source value will be the named parameter or `self` directly.
However, if the named parameter or `self` is non-`Escapable`, then that value will itself have an existing lifetime dependency, and a `copy` dependency will copy the source of that existing dependency.

### Dependency semantics by example

This section illustrates the semantics of lifetime dependence one example at a time for each interesting variation. The following helper functions will be useful: `ContiguousArray.span` creates a non-`Escapable` `Span` result with a scoped dependence to a `ContiguousArray`, `copySpan` creates a new Span with a copied dependence from an existing `Span`, and `parse` uses a `Span`.

```swift
extension ContiguousArray {
  var span: Span<Element> {
    @lifetime(borrow self)
    get {
      ...
    }
  }
}

// The returned span copies dependencies from 'arg'.
@lifetime(copy arg)
func copySpan<T>(_ arg: Span<T>) -> Span<T> { arg }

func parse(_ span: Span<Int>) { ... }
```

#### Scoped dependence on an immutable variable

```swift
let a: ContiguousArray<Int> = ...
let span: Span<Int>
do {
  let a2 = a
  span = a2.span
}
parse(span) // 🛑 Error: 'span' escapes the scope of 'a2'
```

The get of `span` creates a scoped dependence on `a2`. A scoped dependence is determined by the lifetime of the variable, not the lifetime of the value assigned to that variable. So the lifetime of `span` cannot extend into the larger lifetime of `a`.

#### Copied dependence on an immutable variable

Let's contrast scoped dependence shown above with copied dependence on a variable. In this case, the value may outlive the variable it is copied from, as long as it is destroyed before the root of its inherited dependence goes out of scope. A chain of copied dependencies is always rooted in a scoped dependence.

An assignment that copies or moves a potentially non-`Escapable` value from one variable into another **copies** any lifetime dependence from the source value to the destination value. Thus, assigning `rhs` to a variable has the same lifetime copy semantics as passing an argument using a `@lifetime(copy rhs)` annotation. So, the statement `let temp = span` has identical semantics to `let temp = copySpan(span)`.

```swift
let a: ContiguousArray<Int> = arg
let final: Span<Int>
do {
  let span = a.span
  let temp = span
  final = copySpan(temp)
}
parse(final) // ✅ Safe: still within lifetime of 'a'
```

Although the result of `copySpan` depends on `temp`, the result of the copy may be used outside of the `temp`'s lexical scope. Following the source of each copied dependence, up through the call chain if needed, eventually leads to the scoped dependence root. Here, `final` is the end of a lifetime dependence chain rooted at a scoped dependence on `a`:
`a -> span -> temp -> {copySpan argument} -> final`. `final` is therefore valid within the scope of `a` even if the intermediate copies have been destroyed.

#### Copied dependence on a mutable value

First, let's add a mutable method to `Span`:

```swift
extension Span {
  @lifetime(copy self)
  mutating func removePrefix(length: Int) -> Span<T> {
    let prefix = extracting(0..<length)
    self = extracting(length..<count)
    return prefix
  }
}
```

A dependence may be copied from a mutable (`inout`) variable.
When this occurs, the dependence is inherited from whatever value the mutable variable held when the function was invoked.

```swift
let a: ContiguousArray<Int> = ...
var prefix: Span<Int>
do {
  var temp = a.span
  prefix = temp.removePrefix(length: 1) // access 'temp' as 'inout'
  // 'prefix' depends on 'a', not 'temp'
}
parse(prefix) // ✅ Safe: still within lifetime of 'a'
```

#### Scoped dependence on `inout` access

Now, let's return to scoped dependence, this time on a mutable variable. This is where exclusivity guarantees come into play. A scoped depenendence extends an access of the mutable variable across all uses of the dependent value. If the variable mutates again before the last use of the dependent, then it is an exclusivity violation.

```swift
let a: ContiguousArray<Int> = ...
a[i] = ...
let span = a1.span
parse(span) // ✅ Safe: still within 'span's access on 'a'
a[i] = ...
parse(span) // 🛑 Error: simultaneous access of 'a'
```

Here, `a1.span` initiates a 'read' access on `a1`. The first call to `parse(span)` safely extends that read access. The read cannot extend to the second call because a mutation of `a1` occurs before it.

#### Dependence reassignment

We've described how a mutable variable can be the source of a lifetime dependence. Now, let's look at non-`Escapable` mutable variables. Being non-`Escapable` means they depend on another lifetime. Being mutable means that dependence may change during reassignment. Reassigning a non-`Escapable` `inout` sets its lifetime dependence from that point on, up to either the end of the variable's lifetime or its next subsequent reassignment.

```swift
func reassign(_ span: inout Span<Int>) {
  let a: ContiguousArray<Int> = ...
  span = a.span // 🛑 Error: 'span' escapes the scope of 'a'
}
```

#### Reassignment with argument dependence

If a function takes a non-`Escapable` `inout` parameter, it may only reassign that parameter if it is marked dependent on another function parameter that provides the source of the dependence.

```swift
@lifetime(span: borrow arg)
func reassignWithArgDependence(_ span: inout Span<Int>, _ arg: ContiguousArray<Int>) {
  span = arg.span //  ✅ OK: 'span' already depends on 'arg' in the caller's scope.
}
```

This means that an `inout` parameter of potentially non-`Escapable` type can interact with lifetimes in three ways:

- as the source of a scoped dependency, as in `@lifetime([<target>:] inout x)`
- as the source of a copied dependency, as in `@lifetime([<target>:] copy x)`
- as the target of a dependency, as in `@lifetime(x: <dependency>)`

so it is worth restating the behavior here to emphasize the distinctions.
A scoped dependency `@lifetime(inout x)` indicates that the target's lifetime is constrained by exclusive access to `x`.
A copied dependency `@lifetime(copy x)` indicates that the target copies its lifetime constraint from value of `x` when the callee *begins* execution.
As the target of a dependency, `@lifetime(x: <dependency>)` indicates the lifetime constraint added to the value of `x` after the callee *ends* execution.

By composition, an `inout` parameter could appear as both the source and target of a dependency, though it is not useful:

- `@lifetime(x: inout x)` states that the value of `x` on return from the callee is dependent on exclusive access to the variable `x`.
    This would have the net effect of making the argument to `x` inaccessible for the rest of its lifetime, since it is exclusively accessed by the value inside of itself.
- `@lifetime(x: copy x)` states that the value of `x` on return from the callee copies its dependency from the value of `x` when the function began execution, in effect stating that the lifetime dependency does not change.

#### Conditional reassignment creates conjoined dependence

`inout` argument dependence behaves like a conditional reassignment. After the call, the variable passed to the `inout` argument has both its original dependence along with a new dependence on the argument that is the source of the argument dependence.

```swift
let a1: ContiguousArray<Int> = arg
do {
  let a2: ContiguousArray<Int> = arg
  var span = a1.span
  testReassignArgDependence(&span, a2) // creates a conjoined dependence
  parse(span) // ✅ OK: within the lifetime of 'a1' & 'a2'
}
parse(span) // 🛑 Error: 'span' escapes the scope of 'a2'
```

#### Explicit conjoined dependence

A declaration can also express a conjoined dependence explicitly by applying multiple lifetime dependencies to the same target:

```swift
struct Pair<T: ~Escapable, U: ~Escapable>: ~Escapable {
    var first: T
    var second: U

    // A Pair cannot outlive the lifetime of either of its fields.
    @lifetime(copy first, copy second)
    init(first: T, second: U) {
        self.first = first
        self.second = second
    }
}
```

#### `Escapable` properties in a non-`Escapable` type

A non-`Escapable` type inevitably contains `Escapable` properties.
In our `Span` example, the `base` pointer and `count` length are both `Escapable`.
There is no dependence after accessing an `Escapable` property:

```swift
  let pointer: UnsafePointer<T>
  do {
    let span = Span(unsafeBaseAddress: pointer, count: 1)
    pointer = span.base
  }
  _ = pointer // ✅ OK: pointer has no lifetime dependence
```

Internal mutation of `Escapable` properties does not create any new dependence and does not require any annotation:

```swift

  mutating func skipPrefix(length: Int) {
    self.base += length  // ✅ OK: assigns `base` to a copy of the temporary value
    self.count -= length // ✅ OK: assigns `count` to a copy of the temporary value
  }
```

## Source compatibility

Everything discussed here is additive to the existing Swift grammar and type system.
It has no effect on existing code.

## Effect on ABI stability

Lifetime dependency annotations may affect how values are passed into functions, and thus adding or removing one of these annotations should generally be expected to affect the ABI.

## Effect on API resilience

Adding a lifetime dependency constraint can cause existing valid source code to no longer be correct, since it introduces new restrictions on the lifetime of values that pre-existing code may not satisfy.
Removing a lifetime dependency constraint only affects existing source code in that it may change when deinitializers run, altering the ordering of deinitializer side-effects.

## Alternatives considered

### Different spellings

Previous revisions of this proposal introduced a `dependsOn` modifier that would be placed syntactically closer to the return type or argument declarations subject to a dependency.
The authors believe that a more integrated syntax like that is the ultimate right choice for this feature, especially as we develop future directions involving types with multiple lifetime dependencies.
However, as an attribute, `@lifetime` provides room for experimentation without invasive changes to the language grammar, allowing us to incrementally develop and iterate on the underlying model and implementation.
Therefore, we think this attribute is the best approach for the current experimental status of lifetime dependencies as a feature.
Whatever model we ultimately stabilize on ought to support a superset of the functionality proposed here, and it should be possible to mechanically migrate code using `@lifetime` to use the final syntax when it is ready.

### `@lifetime(unchecked)` to disable lifetime dependence checking

A `@lifetime(unchecked)` annotation could allow programmers to disable lifetime dependence checking for a function result or argument. For example, the programmer may want to compose a non-`Escapable` result from an immortal value that isn't visible to the compiler:

```swift
// Existing global function that is not lifetime-annotated
func getGlobalConstant() -> SomeType

@lifetime(immortal)
init() {
  self.value = getGlobalConstant() // 🛑 ERROR: immortal dependence on a temporary value
}
```

To avoid the error, the programmer could disable dependence checking on the function result altogether:

```swift
@unsafe @lifetime(unchecked)
init() {
  self.value = getGlobalConstant() // OK: unchecked dependence.
}
```

This poses a few problems:

1. Declaring a result "unchecked" only affects checking within the function body; it doesn't affect checking in clients of the API, so really shouldn't be part of the API. In the example above, `lifetime(immortal)` has the correct semantics at the API level.

2. `lifetime(unchecked)` is a blunt tool for opting out of safety. Experience shows that such tools are overused as workarounds for compiler errors without fixing the problem. A safety workaround should more precisely identify the source of unsafety.

`_overrideLifetime` is the proposed tool for disabling dependence checks. Passing `Void` as the dependence source is a reasonable way to convert a nonescaping value to an immortal value:


```swift
@lifetime(immortal)
init() dependsOn(immortal) {
  self.value = getGlobalConstant() // OK: unchecked dependence.
  unsafe self = _overrideLifetime(dependent: self, dependsOn: ())
}
```

### Parameter index for lifetime dependencies

Internally, the implementation records dependencies canonically based on parameter index.
This could be exposed as an alternate spelling if there were sufficient demand.

```swift
@lifetime(borrow 0) // same as `@lifetime(borrow arg1)`
func f(arg1: Type1, arg2: Type2, arg3: Type3) -> ReturnType
```

## Future Directions

### Component lifetimes

One crucial limitation of the lifetime dependency model proposed here is that it models every value as having at most one lifetime dependency, and it applies that one lifetime dependency not only to a non-escapable value but also to any non-escapable values that can be derived from it.
This fundamental limitation impacts our ability to fully address many of the future directions discussed here.

In the current design, aggregating multiple values merges their scopes:

```swift
struct Container<Element>: ~Escapable {
  var a: Element
  var b: Element

  @lifetime(copy a, copy b)
  init(a: Element, b: Element) -> Self {...}
}
```

This has the effect of narrowing the lifetime scope of some components:

```swift
var a = ...
{
  let b = ...
  let c = Container<Element>(a: a, b: b)
  a = c.a
}
use(a) // 🛑 Error: `a` outlives `c`, which is constrained by the lifetime of both `a` and `b`
```

In the future, we want to be able to represent the dependencies of multiple stored properties independently. This might look something like this:

```swift
struct Container<Element>: ~Escapable {
  var a: Element
  var b: Element

  @lifetime(.a: copy arg1, .b: copy arg2)
  init(arg1: Element, arg2: Element) {
    ...
  }
}
```

This would then allow for the parts of `Component` to be extracted preserving their individual lifetimes:

```swift
var a = ...
{
  let b = ...
  let c = Container<Element>(a: a, b: b)
  a = c.a
}
use(a) // 🛑 OK: `a` copies its lifetime from `c.a`, which in turn copied it from the original `a`
```

Extraction operations could also declare that they copy the lifetime of one or more components:

```swift
extension Container {
  @lifetime(copy self.a)
  func getA() -> Element {
    return self.a
  }
}

var a = ...
{
  let b = ...
  let c = Container<Element>(a: a, b: b)
  a = c.getA()
}
use(a) // 🛑 OK: `getA()` copies its lifetime from `c.a`, which in turn copied it from the original `a`
```

The general form of the `@lifetime` syntax in this hypothetical could be thought of as:

> **`@lifetime`** **`(`** (*target*)? (**`.`** *component*)\* **`:`** *source* (**`.`** *component*) **`)`**

### Abstract lifetime components

A similar situation comes up when considering collections of non-`Escapable` elements and `Span`.
Under the current proposal, if `[Contiguous]Array` and `Span` were extended to allow for non-`Escapable` element types, then `Span` would lose the distinction between its own lifetime dependency on the memory of the `Array` and the original dependencies of the elements themselves:

```
let e1 = NonEscapable(...)
let e2 = NonEscapable(...)

// a is dependent on e1 and e2
var e: NonEscapable
do {
  let a: ContiguousArray = [e1, e2]

  // span is dependent on borrowing a
  let span = a.span

  // e copies the dependency from span, borrowing a
  e = span[randomIndex()]
}

use(e) // error: e depends on `a` (even though the original e1 and e2 didn't)
```

Lifetime dependence in this case is not neatly tied to stored properties as in the previous example.
The interesting lifetimes in the case of a `Span` with non-`Escapable` elements are the lifetime of the memory being referenced, as well as the lifetime constraint on the referenced elements.
We could declare these as abstract lifetime members of `Span`, and allow those member to be referenced in lifetime dependency declarations:

```swift
@lifetimes(element: Element, memory)
struct Span<Element: ~Escapable>: ~Escapable {
  // Accessing an element forwards the lifetime(s) of the elements themselves
  subscript(i: Int) -> Element {
    @lifetime(copy self.element)
    borrow { ... }
  }
}

@lifetimes(element: Element)
extension ContiguousArray<Element: ~Escapable>: ~Escapable {
  // Accessing a span over the array forwards the lifetime(s) of its elements,
  // while its memory is dependent on accessing this array.
  var span: Span<Element> {
    @lifetime(.memory: borrow self, .element: copy self.element)
    get { ... }
  }
}
```

### Lifetime Dependencies for Tuples

It should be possible to return a tuple in which one or more parts has a lifetime dependency.
Tuples would benefit greatly from component lifetimes to be able to express the potentially independent lifetimes of the elements.
For example:

```swift
struct A {}
struct B: ~Escapable {}
struct C: ~Escapable {}

@lifetime(.0: borrow a, .1: copy b)
func f(a: A, b: B) -> (C, B)
```

### Function type syntax

This proposal introduces `@lifetime` as a declaration attribute, but does not yet allow the attribute on function types.
Therefore, a function that returns a non-`Escapable` type cannot currently be passed as a closure because its dependence information would be lost.

```swift
@lifetime(borrow arg)
func f(arg: ArgType) -> NEType

func g1(closure: (ArgType) -> NEType)

do {
  g1(closure: f) // 🛑 ERROR: function type mismatch 
}
```

To address this shortcoming, the `@lifetime(...)` attribute could be extended to function types as well as declarations.
Since parameter names are not canonical, function types have no canonical parameter names, so the parameter position would need to be canonically identified by an integer literal:

```swift
func g2(closure: @lifetime(borrow 0) (ArgType) -> NEType) { ... }

do {
  g2(closure: f) // ✅ OK
}
```

Internal argument names could potentially be allowed as type sugar:

```
func g2(closure: @lifetime(borrow arg) (_ arg: ArgType) -> NEType) { ... }

do {
  // OK, different argument name is not part of the canonical type
  let f1: @lifetime(borrow a) (_ a: ArgType) -> NEType = f
  g2(closure: f1)

  // Also OK
  let f2: @lifetime(borrow 0) (ArgType) -> NEType = f
  g2(closure: f2)
}
```

The parameter index syntax is consistent with how dependencies are represented internally and in mangled names.

We expect most closures that return non-`Escapable` types to be dependent on the closure context rather than a closure
parameter--this will be the normal case for passing methods as nonescaping closures.
A dependence on context dependence will not affect the spelling of the function type.

### More complex lifetime dependencies for functions

Introducing `@lifetime` annotations onto function types is the bare minimum to allow for the use of nonescapable types in function values; however, there are also far more intricate lifetime relationships that function parameters may want to express among their parameters, returns, and those of the outer function.
The dependencies of their closure context may be nontrivial as well. 
For example, it would be natural to model a `TaskGroup` as a non-`Escapable` type, to statically enforce the currently dynamically-enforced variant that the task group not be used outside of a `withTaskGroup` block.
It would furthermore be natural to treat the argument to `addTask` as a nonescaping closure; however, the scope which the closure cannot escape is not the immediate `addTask` call, but the `withTaskGroup` block as a whole.

In order to express this, function types would likely require a predefined schema of lifetime components in order to express the lifetime constraint of the closure.

```
struct TaskGroup: ~Escapable {
  @lifetime(body.context: self)
  func addTask(_ body: () -> ())

}
```

### Structural lifetime dependencies

A scoped dependence normally cannot escape the lexical scope of its source variable. It may, however, be convenient to escape the source of that dependence along with any values that dependent on its lifetime. This could be done by moving the ownership of the source into a structure that preserves any dependence relationships. A function that returns a non-`Escapable` type cannot currently depend on the scope of a consuming parameter. But we could lift that restriction provided that the consumed argument is moved into the return value, and that the return type preserves any dependence on that value:

```swift
struct OwnedSpan<T>: ~Copyable {
  let owner: any ~Copyable
  @lifetime(borrow owner)
  let span: Span<T>

  @lifetime(span: borrow owner)
  init(owner: consuming any ~Copyable, span: Span<T>) {
    self.owner = owner
    self.span = span
  }
}

func arrayToOwnedSpan<T>(a: consuming [T]) -> OwnedSpan<T> {
  OwnedSpan(owner: a, span: a.span)
}
```

`arrayToOwnedSpan` creates a span with a scoped dependence on an array, then moves both the array and the span into an `OwnedSpan`, which can be returned from the function. This converts the original lexically scoped dependence into a structural dependence.

## Acknowledgments

Dima Galimzianov provided several examples for Future Directions.

Thanks to Gabor Horvath, Michael Ilseman, Guillaume Lessard, and Karoy Lorentey for adopting this functionality in C++ interop and new standard library APIs and providing valuable feedback.
