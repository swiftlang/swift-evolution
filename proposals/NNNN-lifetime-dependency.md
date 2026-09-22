# Compile-time lifetime dependency annotations

* Proposal: [SE-NNNN](NNNN-lifetime-dependency.md)
* Authors: [Andrew Trick](https://github.com/atrick), [Meghana Gupta](https://github.com/meg-gupta), [Tim Kientzle](https://github.com/tbkka), [Joe Groff](https://github.com/jckarter/)
* Review Manager: TBD
* Status: **Implemented** in `main` branch, with the `Lifetimes` experimental feature flag (using underscored syntax `@_lifetime`)
* Review: ([pitch 1](https://forums.swift.org/t/pitch-non-escapable-types-and-lifetime-dependency/69865), [pitch 2](https://forums.swift.org/t/pitch-2-lifetime-dependencies-for-non-escapable-values/78821))

## Introduction

A "lifetime dependency" between two values indicates that one of them can only be mutated or destroyed *after* the other is destroyed.
This dependency is enforced entirely at compile time; it requires no run-time support.
We would like to propose an attribute for Swift function types that allow authors to specify lifetime dependencies from one or more of a function's parameters to one of its results.

This is deeply related to `~Escapable` types, as introduced in [SE-0446](0446-non-escapable.md). This proposal exposes the underlying mechanisms used by the standard library to implement [SE-0447](0447-span-access-shared-contiguous-storage.md)'s `Span` and [SE-0467](0467-MutableSpan.md)'s `MutableSpan` types, as well as the new APIs for creating instances of these types from standard library collections added in [SE-0456](0456-stdlib-span-properties.md), providing a consistent framework by which user-defined types and functions can also express lifetime dependencies.

- Motivation
- Proposed solution
  - Background: `Escapable` and non-`Escapable` types
  - Scoped lifetime dependency
  - Mutable scopes
  - Copied lifetime dependency
  - Dependent function results
  - Dependent 'inout' parameters
  - Dependent properties
  - Function type syntax
  - Conditional dependencies
  - Immortal lifetimes
- Detailed design
  - Basic Semantics
  - Grammar
  - Dependency type requirements
  - Dependency semantics examples
  - Implicit lifetime dependencies
  - Standard library extensions
- Source compatibility
- Effect on ABI stability
- Effect on API resilience
- Alternatives considered
  - Different spellings
  - `@lifetime(unchecked)` annotation
  - Lifetime requirements
- Future Directions
  - Protocol lifetime requirements
  - Nested lifetimes
  - Lifetime Dependencies for Tuples
  - First-class nonescaping functions
  - Closure capture dependency syntax
  - Fine-grained closure capture dependencies
  - Structural lifetime dependencies
  - Lifetime types

#### See Also

* [Documentation on 'main': @_lifetime annotation](https://github.com/swiftlang/swift/blob/main/docs/ReferenceGuides/LifetimeAnnotation.md)
* [Forum discussion of Non-Escapable Types and Lifetime Dependency](https://forums.swift.org/t/pitch-non-escapable-types-and-lifetime-dependency)
* [Pitch Thread for Span](https://forums.swift.org/t/pitch-safe-access-to-contiguous-storage/69888)
* [Forum discussion of BufferView language requirements](https://forums.swift.org/t/roadmap-language-support-for-bufferview)
* [Proposed Vision document for BufferView language requirements (includes description of ~Escapable)](https://github.com/atrick/swift-evolution/blob/fd63292839808423a5062499f588f557000c5d15/visions/language-support-for-BufferView.md#non-escaping-bufferview) 

## Motivation

An efficient way to provide one piece of code with temporary access to data stored in some other piece of code is with a pointer to the data in memory.
Swift's `Unsafe*Pointer` family of types can be used here, but as the name implies, using these types is not statically safe and can be error-prone.

For example, suppose `Array` had a property `unsafeBufferPointer` that returned an `UnsafeBufferPointer` to the contents of the array.
Here's an attempt to use such a property:

```swift
let array = ...
let buffer = array.unsafeBufferPointer
parse(buffer) // <== 🛑 NOT SAFE!
```

One reason for this unsafety is because Swift's standard lifetime rules only apply to individual values.
They cannot guarantee that `array` will outlive `buffer`, which means there is a risk that the compiler might choose to destroy `array` before the call to `parse`, which could result in `buffer` referencing deallocated memory.
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
let buffer = array.withUnsafeBufferPointer { $0 }
```

## Proposed solution

### Background: `Escapable` and non-`Escapable` types

[SE-0446](0446-non-escapable.md) introduced the `Escapable` protocol for controlling lifetime dependency of types.
Normal Swift types are `Escapable` by default.
This implies that they can be returned, stored in properties, or otherwise "escape" the local context.
Conversely, types can suppress this implicit assumption of escapability by being declared as `~Escapable`.
Values of types that are not known to be `Escapable` are not allowed to escape the local context except in very specific circumstances. Because lifetime dependencies can only be attached to non-`Escapable` values, types that contain pointers will generally need to be non-`Escapable` in order to provide safe semantics.

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
This proposal supersedes those special cases with a general-purpose mechanism for providing a set of constraints that can tie the lifetime of a non-`Escapable` value to the lifetime of other values. We refer to this as a lifetime dependency, and every non-`Escapable` value must carry a lifetime dependency. 

### Scoped lifetime dependency

Let's consider adding `Span` support to `Array`. Our proposal allows the `array.span` property to be declared as follows:

```swift
extension Array {
  var span: Span<Element> {
    @lifetime(borrow self)
    borrowing get {
        ... construct a Span ...
    }
  }
}
```

The annotation `@lifetime(borrow self)` indicates that `self` is the source of a dependency, and the returned `span` is the target of the dependency, or dependent value. Enforcement of a lifetime dependency happens independently in two directions: both in the body of the annotated function (the callee) and in each region of code that calls the annotated function (the caller). The callee guarantees that the non-`Escapable` dependent value remains valid as long as the dependency source is not mutated or destroyed. The caller guarantees that the dependency source will not be mutated or destroyed until after the dependent value is destroyed. The `borrow` specifier means that the caller enforces exclusive read-only access over the scope of the dependent value's uses.

In this case, the returned `span` value cannot outlive the array that produced it.
Furthermore, the originating array value behaves as if it is borrowed for the duration of the `span`'s lifetime, meaning not only that the array cannot be destroyed, but also that it cannot be modified while the `span` is alive.
Conceptually, the `span` acts as a continuation of the function's borrowing access:
the array is borrowed by the function while the function executes and then continues to be borrowed by the result of `span` for as long as the return value exists.
Specifically, the `@lifetime(borrow self)` annotation in this example informs the compiler that:

* The array must not be destroyed until after the `Span<Element>` is destroyed.
  This ensures that use-after-free cannot occur.
* The array must not be mutated while the  `Span<Element>` value exists.
  This follows the usual Swift exclusivity rules for mutation; mutation requires exclusive access, so cannot occur during a borrowing access.
  However, just like a variable can undergo multiple simultaneous borrowing accesses, so can multiple `Span`s depend on borrowing the same origin `array`.
  In this case, the `array` is borrowed until the end of the lifetimes of all of its borrow-dependent values.

### Mutable scopes

Let's now consider the `MutableSpan<T>` type from [SE-0467](0467-MutableSpan.md), which provides indirect mutating access to a block of memory.
Here's one way such a value might be produced from an owning array:

```swift
extension Array {
  @lifetime(&self)
  mutating func mutatingSpan(count: Int) -> MutatingSpan<Element> {
    ... construct a MutatingSpan ...
  }
}
```

The `@lifetime(&self)` annotation indicates that the returned value depends on `self`.
Because `count` is not mentioned in the lifetime dependency, that argument does not participate.
Instead of `borrow`, this annotation uses the `&` sigil to indicate that the returned span depends on **mutating** exclusive access to `self` rather than borrowed access.

Similar to the previous example:

* The array will not be destroyed until after the `MutableSpan<Element>` is destroyed.

However, in contrast with the previous `borrow` dependency:

* No other read or write access to the array will be allowed for as long as the returned value exists, since the dependency requires exclusivity.

In both the `borrow` and the `&` dependency case, the lifetime of the return value is "scoped" to an access into the lifetime of the original value.

### Copied lifetime dependency

Scoped lifetime dependencies are the only possibility whenever an `Escapable` value (such as a Array or similar container) provides a non-`Escapable` value (such as the `Span` or `MutatingSpan` in these examples).
But a non-`Escapable` value can also derive its dependency from another non-`Escapable` value.
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

In this example, the non-`Escapable` result does not depend on the first non-`Escapable` value that it was derived from.
Recall that non-`Escapable` values such as these represent values that are already lifetime-constrained to another value; in this case, the returned `Span` is ultimately dependent on the same owning value as the original `Span`.

To express this, the return value can "copy" the lifetime dependency from the original:
If the original `Span` was borrowing some array, the new `Span` will continue to borrow the same array.

This supports coding patterns such as this:
```swift
var a: [Int]
let ref1 = a.span // ref1 cannot outlive a
let ref2 = ref1.extracting(4 ..< ref1.count) // ref2 also cannot outlive a
```

After `ref1.extracting(4 ..< ref1.count)`, the lifetime of `ref2` does not depend on `ref1`.
The `extracting` method **copies** `ref1`s lifetime dependency onto `ref2`.
`ref2` effectively **inherits** the same lifetime dependency on `a` as `ref1`.
We may also refer to a lifetime dependency that has been copied from another value as an "inherited" dependency.
Since both `ref1` and `ref2` have borrowing scoped dependencies on `a`, they can be used simultaneously:

```swift
print(ref1[0])
print(ref2[0])
```

`ref2` can continue to be used after the end of `ref1`'s lifetime, as long as `a` remains valid:

```swift
_ = consume ref1 // explicitly end ref1's lifetime here
print(ref2[0]) // ✅ ref2 is still valid

_ = consume a // explicitly end a's lifetime here
print(ref2[0]) // 🛑 Error: ref2 cannot exceed a's lifetime
```

The variable `a` cannot be mutated or destroyed until both `ref1` and `ref2` have expired:

```swift
a.append(1) // 🛑 Error: 'a' is borrowed by 'ref1' and 'ref2'
_ = consume ref2
a.append(1) // 🛑 Error: 'a' is borrowed by 'ref1'
_ = consume ref1
a.append(1) // ✅
```

Note that non-`Escapable` values can still have scoped dependencies on other non-`Escapable` values as well.
This comes up frequently with `MutableSpan` due to its interaction with exclusivity.
Since there can only be one mutating reference to a mutable value at any time, `MutableSpan`'s version of the `extracting` method must pass off that responsibility to the extracted `MutableSpan` for the latter value's lifetime and prevent overlapping access through the base `MutableSpan` until the extracted `MutableSpan` is no longer usable. It can achieve this by giving the extracted `MutableSpan` a scoped dependency:

```swift
extension MutableSpan {
  @lifetime(&self)
  mutating func extracting(_ range: Range<Int>) -> MutableSpan<Element> {
    ...
  }
}
```

Since the return value of `extracting` has a scoped `inout` dependency on the original `MutableSpan`, the original cannot be accessed while the new value is active.
When the extracted `MutableSpan` ends its lifetime, the exclusive access to the original ends, making it available for use again, thereby allowing for the derivation of new `MutableSpan`s without violating exclusivity.

### Dependent function results

A simple function with an explicit lifetime dependency annotation generally takes this form:

```swift
@lifetime(<dependency-kind> arg)
func f(arg: [<parameter-convention>] ArgType) -> ResultType
```

Where

* *`dependency-kind`* is one of the dependency specifiers **`borrow`**, **`&`**, or **`copy`**
* `ResultType` is `~Escapable`.

And, according to the existing language rules:

* *`parameter-convention`* specifies the ownership of `arg`: **`borrowing`**, **`mutating`**, or **`consuming`**, or the ownership default is applied.

The `borrow` or `&` dependency specifiers indicate a scoped dependency on the argument. A scoped dependency must correspond to the argument's ownership:

* A `borrow` dependency specifier requires `borrowing` ownership. It extends borrowing access, prohibiting mutations of the argument, but allowing other simultaneous borrowing accesses.
* A `&` dependency specifier requires `inout` ownership. It extends mutating access, prohibiting any other access to the argument, whether borrowing or mutating.
* Neither scoped dependency specifier may be used with `consuming` ownership, since that ends the lifetime of the argument immediately.

The `copy` dependency specifier indicates a copied dependency, which requires the source type (`ArgType`) to non-`Escapable`. Because the lifetime of the incoming value is copied, the dependency is independent of the argument's ownership, which may be `borrowing`, `inout`, or `consuming`.

**Methods:** A method may have lifetime dependencies on it's arguments, which follow the same rules as regular functions. Additionally, methods may specify a lifetime dependency on `self`. Given a method of this form:

```swift
@lifetime(<dependency-kind> self)
<mutation-modifier> func method(... args ...) -> ResultType
```

If `Self` is `Escapable`, then the dependency-kind must be `borrow self` for a `borrowing` method, or `&self` for a `mutating` method. Lifetime dependencies are not allowed on `self` in a `consuming` method.

For a method of a non-`Escapable` type, the dependency-kind may be `copy self`.

**Initializers:** An initializer can also define lifetime dependencies on one or more arguments.
In this case, we use the same rules as for “Functions” above
by using the convention that initializers can be viewed as functions that return `Self`:

```swift
@lifetime(<dependency-kind> arg)
init(arg: ArgType)
```

#### Dependent 'inout' parameters

Normally, a lifetime dependency is required when a non-`Escapable` function result depends on an argument to that function. However, `inout` parameters of non-`Escapable` type also express an operation that results in a new non-`Escapable` value as a result of mutation by calling the function. The target of a dependency can be expressed before a colon in a `@lifetime` attribute:

```swift
@lifetime(target: <dependency-kind> source)
```

When the dependency `target` is elided, the target is the function's return value. `@lifetime(self:)` can also be used to indicate that a `mutating` method's implicit `self` depends on another parameter after being mutated.

Regular mutation copies the lifetime of the incoming value to the outgoing value:

```swift
@lifetime(span: copy span)
func mayDrop(span: inout MutableSpan<Int>) {
  span = span.extracting(...)
}
```

This is simply the default lifetime behavior for non-`Escapable` `inout` parameters, as discussed below in the "Implicit lifetime dependencies" section.

In the less common case of reassignment, an `inout` parameter depends on another argument to a function call.

```swift
@lifetime(span: borrow a)
func reassign(span: inout Span<Int>, to a: [Int]) {
  span = a.span
}
```

An `inout` parameter that is conditionally reassigned has two dependency sources:

```swift
@lifetime(span: copy span, copy another)
func mayReassign(span: inout Span<Int>, to another: Span<Int>) {
  span = (...) ? span : another
}
```

We've discussed how a non-`Escapable` result must be destroyed before the source of its lifetime dependence. Similarly, a dependent argument must be destroyed before (or at the same time as) all arguments that it depends on.

```swift
  let a1: [Int] = ...
  var span = a1.span
  let a2: [Int] = ...
  mayReassign(span: &span, to: a2.span)
  // 'span' now depends on both 'a1' and 'a2'.
```

#### Dependent properties

Structural composition is an important use case for non-`Escapable` types. Getting or setting a non-`Escapable` computed property requires lifetime dependence, just like a function result or an 'inout' parameter:

```swift
struct Wrapper<Element: ~Escapable>: ~Escapable {
  var element: Element {
    @lifetime(copy self) // DEFAULT
    get { ... }

    @lifetime(self: copy self, self: copy newValue)
    set { ... }
  }

  @lifetime(copy element) // DEFAULT
  init(element: Element) { ... }
}
```

Note that the lifetime annotations above are the natural defaults and therefore never need to be written explicitly.

### Function type syntax

In addition to function declarations, function types must support lifetime annotations so functions that return non-`Escapable` types can be passed as closures.

```
func foo(closure: @lifetime(borrow arg) (_ arg: Container) -> Span<T>) { ... }

@lifetime(borrow arg)
func bar(_ arg: Container) -> Span<T> { ... }

do {
  // ✅ a different argument name is not part of the canonical type
  let f: @lifetime(borrow a) (_ a: Container) -> Span<T> = bar
  foo(closure: f)
}
```

Function types typically omit parameter names, but they are required for any parameter referenced by the annotation.

#### Closure dependencies

Without an explicit `@lifetime` attribute, a nonescaping function that returns a non-`Escapable` type defaults to a copied dependency on the closure value itself, which in turn depends on its captures. In effect, a nonescaping closure borrows all its captured values. A value that depends on a closure ultimately depends on the borrow scopes of its captures. For example:

```swift
func foo(_: (Range<Int>) -> Span<Int>) {...}

let array = [0, 1]
let span = foo { array.span.extracting($0) } // ✅ 'span' is used within the closure's borrow of 'array'
_ = span
```

In the future, with additional syntax support, it may be possible for a function type to express dependenies simultaneously on both the closure value and its parameters. See "Closure capture dependency syntax".

It may also be possible in the future to model precise dependencies on individual closure captures, as described in "Fine-grained closure capture dependencies".

### Conditional dependencies

Conditionally `Escapable` types can also contain potentially non-`Escapable` elements:

```swift
struct Container<Element: ~Escapable>: ~Escapable {
  var element: Element

  @lifetime(copy element)
  init(element: Element) { self.element = element }

  @lifetime(copy self)
  func getElement() -> Element { element }
}

extension Container: Escapable where Element: Escapable { }
```

Here, `Container` is non-`Escapable` only when its element type is non-`Escapable`. Whenever `Container` is potentially non-`Escapable`, it inherits the lifetime of the single `element` argument to the initializer and propagates that lifetime to all uses of its `element` property or the `getElement()` function.

In some contexts, however, the `Element` is known to conform to `Escapable`, which in turn makes `Container<Element>` for that `Element` type `Escapable`. When generic substitution produces an `Escapable` type, any `@lifetime` dependencies applied to that type are ignored. For example, consider a container of `String` elements:

```swift
let s = "strings are immortal"
var s2: String
do {
    let c = Container<String>(element: s)
    s2 = c.getElement()
}
print(s2) // ✅ String is Escapable, so it isn't affected by the lifetime dependency
```

### Immortal lifetimes

In some cases, a non-`Escapable` value must be constructed without any object that can stand in as the source of a dependence. Consider the standard library `Optional` or `Result` types, which became conditionally `Escapable` in [SE-0465](0465-non-Escapable-stdlib-primitives.md):

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

### Depending on an `Escapable & BitwiseCopyable` value

The source of a lifetime dependency may be an `Escapable & BitwiseCopyable` value.
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

When the source of a dependency is escapable and `BitwiseCopyable`, then the operation must be marked as `@unsafe` when using strict memory safety as introduced in [SE-0458](0458-strict-memory-safety.md).
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

## Detailed design

### Basic Semantics

A lifetime dependency annotation creates a *lifetime dependency* between source and target values. The target of the dependency is the *dependent value*.
This relationship obeys the following requirements:

* The dependent value's lifetime must be no longer than that of the source value.

* The dependent value is treated as an ongoing access to the source value.
    Following Swift's usual exclusivity rules, the source value may not be mutated during the lifetime of the dependent value;
    if the access is a mutating access, the source value is further prohibited from being accessed at all during the lifetime of the dependent value.

The compiler must issue a diagnostic if any of the above cannot be satisfied.

### Grammar

This proposal adds a `@lifetime` attribute that can be applied to function, initializer, and property accessor declarations and to function types:

> *lifetime-attribute* → **`@`** **`lifetime`** **`(`** *lifetime-dependence-target-list* **`)`**
>
> *lifetime-dependence-target-list* → (*lifetime-dependence-target-name* **`:`**)? *lifetime-dependence-source-list*
>
> *lifetime-dependence-source-list* → *lifetime-dependence-source* (**`,`** *lifetime-dependence-source-list*)?
>
> *lifetime-dependence-source* → **`immortal`** | *dependency-kind* *lifetime-dependence-source-name*
>
> *lifetime-dependence-source-name* → **`self`** | *identifier*
>
> *lifetime-dependence-target-name* → **`self`** | *identifier*
>
> *dependency-kind* → **copy** | **borrow** | **&**

The *lifetime-dependence-target-name* and *lifetime-dependence-source-name* identify parameters by name. A parameter name is the "internal" name used to refer to the value in the function body rather than by its argument label. `self` can occur as a parameter name for methods.

A target parameter must either be an `inout` parameter or `self` in a `mutating` method. If no target parameter is specified, then the target is the declaration's return value.

### Dependency type requirements

The target of a lifetime dependency must be `~Escapable`:

```swift
struct Span<T>: ~Escapable {...}

@lifetime(...) // ✅ `Span<T>` is non-Escapable
func f<T>(...) -> Span<T>

@lifetime(...) // 🛑 Error: `R` is Escapable
func g<R>(...) -> R

@lifetime(...) // ✅ `R` is conditionally Escapable
func h<R: ~Escapable>(...) -> R
```

If the dependency target's type is conditionally Escapable, and its specialized type is Escapable, then the dependency will be ignored altogether.

The source of a scoped dependency (*depenency-kind* `borrow` or `&`) can be any type:

```swift
@lifetime(borrow a) // ✅ any `A` can be borrowed
func f<A, R: ~Escapable>(a: A) -> R
```

If the parameter passed into the function is not already borrowed, then the caller creates a new borrow scope, which limits the lifetime of the result.

Unlike a `borrow` dependency, a `copy` dependency requires a `~Escapable` parameter type:

```swift
@lifetime(copy span) // ✅ `Span<T>` is non-Escapable
func f<T, R: ~Escapable>(span: Span<T>) -> R

@lifetime(copy a) // 🛑 Error: `A` is Escapable
func g<A, R: ~Escapable>(a: A) -> R
```

If the specialized type of the copied dependency's source is Escapable, then the dependency target is unconstrained by the source.

### Dependency semantics examples

This section illustrates the semantics of lifetime dependence one example at a time for a number of interesting variations. The following helper functions will be useful:

```swift
extension Array {
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

`Array.span` creates a non-`Escapable` `Span` result with a scoped dependency to a `Array`, `copySpan` creates a new Span with a copied dependency from an existing `Span`, and `parse` uses a `Span`.
 
#### Scoped dependence on an immutable variable

```swift
let a: [Int] = ...
let span: Span<Int>
do {
  let a2 = a
  span = a2.span
}
parse(span) // 🛑 Error: 'span' escapes the scope of 'a2'
```

The get of `span` creates a scoped dependency on `a2`. A scoped dependency is determined by the lifetime of the variable, not the lifetime of the value assigned to that variable. So the lifetime of `span` cannot extend into the larger lifetime of `a`.

#### Copied dependence on an immutable variable

Let's contrast scoped dependence shown above with copied dependence on a variable. In this case, the value may outlive the variable it is copied from, as long as it is destroyed before the root of its inherited dependency goes out of scope. A chain of copied dependencies is always rooted in a scoped dependence.

An assignment that copies or moves a potentially non-`Escapable` value from one variable into another **copies** any lifetime dependency from the source value to the destination value. Thus, assigning `rhs` to a variable has the same lifetime copy semantics as passing an argument using a `@lifetime(copy rhs)` annotation. So, the statement `let temp = span` has identical semantics to `let temp = copySpan(span)`.

```swift
let a: [Int] = arg
let final: Span<Int>
do {
  let span = a.span
  let temp = span
  final = copySpan(temp)
}
parse(final) // ✅ Safe: still within lifetime of 'a'
```

Although the result of `copySpan` depends on `temp`, the result of the copy may be used outside of the `temp`'s lexical scope. Following the source of each copied dependency, up through the call chain if needed, eventually leads to the scoped dependency root. Here, `final` is the end of a lifetime dependence chain rooted at a scoped dependency on `a`:
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

A dependency may be copied from a mutable (`inout`) variable.
When this occurs, the dependency is inherited from whatever value the mutable variable held when the function was invoked.

```swift
let a: [Int] = ...
var prefix: Span<Int>
do {
  var temp = a.span
  prefix = temp.removePrefix(length: 1) // access 'temp' as 'inout'
  // 'prefix' depends on 'a', not 'temp'
}
parse(prefix) // ✅ Safe: still within lifetime of 'a'
```

#### Scoped dependence on `inout` access

Now, let's return to scoped dependence, this time on a mutable variable. This is where exclusivity guarantees come into play. A scoped dependency extends an access of the mutable variable across all uses of the dependent value. If the variable mutates again before the last use of the dependent, then it is an exclusivity violation.

```swift
let a: [Int] = ...
a[i] = ...
let span = a1.span
parse(span) // ✅ Safe: still within 'span's access on 'a'
a[i] = ...
parse(span) // 🛑 Error: simultaneous access of 'a'
```

Here, `a1.span` initiates a 'read' access on `a1`. The first call to `parse(span)` safely extends that read access. The read cannot extend to the second call because a mutation of `a1` occurs before it.

#### Dependency reassignment

We've described how a mutable variable can be the source of a lifetime dependency. Now, let's look at non-`Escapable` mutable variables. Being non-`Escapable` means they depend on another lifetime. Being mutable means that dependency may change during reassignment. Reassigning a non-`Escapable` `inout` sets its lifetime dependency from that point on, up to either the end of the variable's lifetime or its next subsequent reassignment.

```swift
func reassign(_ span: inout Span<Int>) {
  let a: [Int] = ...
  span = a.span // 🛑 Error: 'span' escapes the scope of 'a'
}
```

This means that an `inout` parameter `inoutArg` of potentially non-`Escapable` type can interact with lifetimes in three ways:

- as the source of a scoped dependency, as in `@lifetime([<target>:] &inoutArg)`
- as the source of a copied dependency, as in `@lifetime([<target>:] copy inoutArg)`
- as the target of a dependency, as in `@lifetime(inoutArg: <dependency>)`

So it is worth restating the behavior here to emphasize the distinctions.
A scoped dependency `@lifetime(&arg)` indicates that the target's lifetime is constrained by exclusive access to `arg`.
A copied dependency `@lifetime(copy arg)` indicates that the target copies its lifetime constraint from value of `arg` when the callee *begins* execution.
As the target of a dependency, `@lifetime(inoutArg: <dependency>)` indicates the lifetime constraint added to the value of `inoutArg` after the callee *ends* execution.

By composition, an `inout` parameter could appear as both the source and target of a dependency:

`@lifetime(inoutArg: copy inoutArg)` states that the value of `inoutArg` on return from the callee copies its dependency from the value of `arg` when the function began execution, in effect stating that the lifetime dependency does not change from the caller's perspective. This is the most common case for `inout` parameters and, as described in "Implicit lifetime dependencies", never requires explicit annotation. The `reassign` function above is therefore equivalent to:

```swift
@lifetime(span: copy span)
func reassign(_ span: inout Span<Int>) {...}
```

An `inout` parameter may, however, also be reassigned to another function parameter that provides the source of the dependency:

```swift
@lifetime(span: copy another)
func mayReassign(span: inout Span<Int>, to another: Span<Int>) {
  span = (...) ? span : another // ✅ `span` depends on its incoming value and `another`
}
```

Annotions on an `inout` target parameter are additive, so the annotation `@lifetime(span: copy another)` above is equivalent to `@lifetime(span: copy span, copy another)`. A copied `inout` dependency can only be suppressed with an explicit immortal dependency: `@lifetime(arg: immortal)`.

Composition also suggests the possibility `@lifetime(inoutArg: &inoutArg)`. This states that the value of `inoutArg` on return from the callee is dependent on exclusive access to the variable `inoutArg`.  This would have the net effect of making the argument to `inoutArg` inaccessible for the rest of its lifetime, since it is exclusively accessed by the value inside of itself. This is not useful and likely a programmer error. Therefore, we propose to disallow it.

#### Conditional reassignment creates conjoined dependencies

In the `mayReassign` example above, the `inout` argument copies its incoming dependency, while also inheriting a dependency from `another`. After the call, the variable passed to the `inout` argument has both its original dependency along with a new dependency on the argument that is the source of the argument dependency:

```swift
let a1: [Int] = arg
do {
  let a2: [Int] = arg
  var span = a1.span
  mayReassign(&span, a2.span) // creates a conjoined dependence
  parse(span) // ✅ within the lifetime of 'a1' & 'a2'
}
parse(span) // 🛑 Error: 'span' escapes the scope of 'a2'
```

#### Aggregation creates conjoined dependencies

Functions that aggregate non-`Escapable` values also create conjoined dependencies:

```swift
struct Pair<T: ~Escapable, U: ~Escapable>: ~Escapable {
    var first: T
    var second: U

    // A Pair cannot outlive the lifetime of either of its fields.
    // (This is semantically the same as the default implicit initializer).
    @lifetime(copy first, copy second)
    init(first: T, second: U) {
        self.first = first
        self.second = second
    }
}

let first = Span<Int>(...)
var pair = Pair(first: first, second: first)
do {
  pair.second = Span<Int>(...)
  _ = pair.first[0] ✅ 'pair' is within the lifetime of 'first' and 'second'
}
_ = pair.first[0] 🛑 Error: 'pair' escapes the scope of 'second'

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
  _ = pointer // ✅ pointer has no lifetime dependence
```

Internal mutation of `Escapable` properties does not create any new dependency and does not require any annotation:

```swift

  mutating func skipPrefix(length: Int) {
    self.base += length  // ✅ assigns `base` to a copy of the temporary value
    self.count -= length // ✅ assigns `count` to a copy of the temporary value
  }
```

### Implicit lifetime dependencies

To reduce the burden of manually adding `@lifetime` annotations, we propose implicit lifetime dependencies in certain common cases as described in the following default lifetime rules.

#### Same-type default lifetime

Given a function declaration:

`func foo<...>(..., a: A, ...) -> R { ... }`

Where `R: ~Escapable`, `A == R`, and `a` is not an `inout` parameter, default to `@lifetime(copy a)`.
For non-mutating methods, the same rule applies to implicit `Self` parameter.

This handles the obvious cases in which both the parameter and result are `~Escapable`. For example:

```swift
extension Span {
  /* DEFAULT: @lifetime(copy self) */
  func extracting(droppingLast k: Int) -> Self { ... }
}
```

Here we see how same-type lifetime requirement applies to type substitution and associated types:

```swift
protocol P {
  associatedtype T: ~Escapable
}

protocol Q {
  associatedtype U: ~Escapable
}

struct S<A: P, B: Q> {
  /* DEFAULT: @lifetime(copy a) */
  func foo(a: A.T) -> B.U where A.T == B.U
}
```

Note that lifetime dependencies are resolved at function declaration time, which determines the function's type. The generic context at the point of function invocation is not considered. For example, the following declaration of `foo` is invalid, because it's argument and result types don't match at the point of declaration, even though the argument and result do have the same type when invoked inside `bar`:

```swift
struct S<T: ~Escapable, U: ~Escapable> {
  static func foo(a: T) -> U // 🛑 Error: missing lifetime dependency
}

/* DEFAULT: @lifetime(copy a) */
func bar<T: ~Escapable>(a: T) -> T {
  S<T, T>.foo(a: a) // The same-type rule is satisfied in this context, but 'foo's declaration is invalid.
}
```

#### `inout` parameter default rule

The `inout` parameter default rule is:

- Default to `@lifetime(a: copy a)` for all `inout` parameters where `a` is  `~Escapable`.

- Default to `@lifetime(self: copy self)` on `mutating` methods where `self` is `~Escapable`.

Lifetime dependencies on `inout` parameters generally handle the incoming value like a normal parameter and the outgoing value as a normal function result. From this perspective, the `inout` rule would follow from the same-type default rule above. It is helpful, however, to define these as separate rules. Notably, an `inout` target does not implicitly depend on other parameters of the same type:

```swift
func cannotReassign(span: inout Span<Int>, to another: Span<Int>) {
  span = another // 🛑 Error: `another` escapes the function via `span`
}
```

Separating `inout` and same-type defaults is consistent with the fact that Swift APIs typically use `inout` for mutation of the parameter rather than its reassignment. If reassignment is expected, then it is helpful see an explicit `@lifetime` annotation. Unlike other default rules, the `inout` default rule applies even if an explicit `@lifetime` attribute already speficies the same `inout` parameter as a target.

```swift
@lifetime(span: copy another)
func mayReassign(span: inout Span<Int>, to another: Span<Int>) {
  span = (...) ? span : another // ✅ `span` depends on its incoming value and `another`
}
```

With the `inout` default rule, the annotation `@lifetime(span: copy another)` above is equivalent to `@lifetime(span: copy span, copy another)`. A copied `inout` dependency can only be suppressed with an explicit immortal dependency:


```swift
@lifetime(span: immortal)
func reinitialize(span: inout Span<Int>) {
  span = Span()
}
```

##### `inout` default examples

```swift
struct A: Escapable {
  let obj: AnyObject // ~BitwiseCopyable
}
struct NE: ~Escapable {...}

/* DEFAULT: @lifetime(a: copy a) */
func inoutNEParam_void(a: inout NE) -> ()

/* DEFAULT: @lifetime(a: copy a) */
func inoutNEParam_NEParam_void(a: inout NE, b: NE) -> ()

/* DEFAULT: @lifetime(a: copy a, copy b) */
@lifetime(copy b)
func inoutNEParam_NEParamLifetime_void(a: inout NE, b: NE) -> ()

/* DEFAULT: @lifetime(a: copy a) */
/* DEFAULT: @lifetime(b: copy b) */
func inoutNEParam_inoutNEParam_void(a: inout NE, b: inout NE) -> ()

/* DEFAULT: @lifetime(a: copy a) */
@lifetime(&a)
func inoutNEParam_NEResult(a: inout NE) -> NE

extension A /* Self: Escapable */ {
  /* DEFAULT: @lifetime(a: copy a) */
  func inoutNEParam_void(a: inout NE) -> ()

  /* DEFAULT: @lifetime(a: copy a) */
  mutating func mutating_inoutNEParam_void(a: inout NE) -> ()

  /* DEFAULT: @lifetime(a: copy A) */
  @lifetime(&self)
  func inoutNEParam_NEResult(a: inout NE) -> NE
}

extension NE /* Self: ~Escapable */ {
  /* DEFAULT: @lifetime(self: copy self) */
  mutating func mutating_noParam_void() -> ()

  /* DEFAULT: @lifetime(self: copy self) */
  mutating func mutating_oneParam_void(_: NE) -> ()

  /* DEFAULT: @lifetime(self: copy self) */
  /* DEFAULT: @lifetime(a: copy a) */
  mutating func mutating_inoutParam_void(a: inout NE) -> ()

  /* DEFAULT: @lifetime(self: copy self) */
  @lifetime(&self)
  mutating func mutating_noParam_NEResult() -> NE
}
```

#### Single parameter default rule

Given a function or method that returns a non-`Escapable` result, if that result's dependency does not have a same-type default, then:

- Default to `@lifetime(<scope> a)` for a `~Escapable` result on functions with a single parameter `a`.

- Default to `@lifetime(<scope> self)` for a `~Escapable` result on methods with no parameters.

| Type of parameter (`a` or `self`) | default lifetime dependency|
| ----------------- | ------------------------------ |
| `Escapable`       | `@lifetime(borrow param)`[^1] |
| `inout Escapable` | `@lifetime(&param)`[^1]       |
| `~Escapable`      | none[^2]                       |

[^1]: When the parameter is `BitwiseCopyable`, such as an integer or unsafe pointer, the single parameter default rule applies to function parameters but not to the implicit `self` parameter. Depending on a `BitwiseCopyable` value is a convenience for APIs that construct span-like values from an `UnsafePointer` passed as an argument. This creates a dependency on a local copy of the pointer variable with subtle semantics. User-defined `BitwiseCopyable` structs should generally avoid such subtle lifetime dependencies. If needed, the author of the data type should explicitly opt into them.

[^2]: When the single parameter is also `~Escapable`, the result must depend on it, but the dependency may either be scoped (`borrow` or `&`) or it may be copied (`copy`). `copy` is the obvious choice when the parameter and result are the same type, but it is not always correct. Furthermore, a lifetime dependency can only be copied from a generic type when result as the same generic type. This case is therefore handled by same-type default lifetime (discussed below) rather than as a default `@lifetime` rule.

Examples:

```swift
struct A: Escapable {
  let obj: AnyObject // ~BitwiseCopyable
}
struct NE: ~Escapable {...}

/* DEFAULT: @lifetime(borrow a) */
func oneParam_NEResult(a: A) -> NE

/* DEFAULT: @lifetime(&a) */
func oneInoutParam_NEResult(a: inout A) -> NE

extension A /* Self: Escapable */ {
  /* DEFAULT: @lifetime(borrow self) */
  func noParam_NEResult() -> NE

  /* DEFAULT: @lifetime(&self) */
  mutating func mutating_noParam_NEResult() -> NE
}
```

#### Implicit initializer and setter defaults

An implicit setter of a `~Escapable` stored property defaults to `@lifetime(self: copy self, copy newValue)`. This is always correct because the setter simply assigns the stored property to the newValue. Assigning a `~Escapable` variable copies the lifetime dependency.

Similarly, an implicit initializer of a non-`Escapable` struct defaults to `@lifetime(self: copy arg)` if all of the initializer arguments are `~Escapable`. This is equivalent to assigning each `~Escapable` stored property. If, however, any initializer arguments are `Escapable`, then no default lifetime is provided unless it is the sole argument, in which case the single parameter rule applies.

### `overrideLifetime` standard library extensions

The following helper functions will be added for implementing low-level data types:

```swift
/// Replace the current lifetime dependency of `dependent` with a new copied lifetime dependency on `source`.
///
/// Precondition: `dependent` has an independent copy of the dependent state captured by `source`.
@unsafe @lifetime(copy source)
func overrideLifetime<T: ~Copyable & ~Escapable, U: ~Copyable & ~Escapable>(
  _ dependent: consuming T, copying source: borrowing U)
  -> T { ... }

/// Replace the current lifetime dependency of `dependent` with a new scoped lifetime dependency on `source`.
///
/// Precondition: `dependent` depends on state that remains valid until either:
/// (a) `source` is either destroyed if it is immutable,
/// or (b) exclusive to `source` access ends if it is a mutable variable.
@unsafe @lifetime(borrow source)
func overrideLifetime<T: ~Copyable & ~Escapable, U: ~Copyable & ~Escapable>(
  _ dependent: consuming T, borrowing source: borrowing U)
  -> T {...}

/// Replace the current lifetime dependency of `dependent` with a new scoped lifetime dependency on `source`.
///
/// Precondition: `dependent` depends on state that remains valid until either:
/// (a) `source` is either destroyed if it is immutable,
/// or (b) exclusive to `source` access ends if it is a mutable variable.
@unsafe @lifetime(&source)
func overrideLifetime<T: ~Copyable & ~Escapable, U: ~Copyable & ~Escapable>(
  _ dependent: consuming T, mutating source: inout U)
  -> T {...}
```

These are useful for non-`Escapable` data types that are internally represented using `Escapable` types such as `UnsafePointer`. For example, some methods on `Span` will need to derive a new `Span` object that copies the lifetime dependency of `self`:

```swift
extension Span {
  consuming func dropFirst() -> Span<Element> {
    let local = Span(base: self.base + 1, count: self.count - 1)
    // 'local' can persist after 'self' is destroyed.
    return unsafe overrideLifetime(local, copying: self)
  }
}
```

Since `self.base` is an `Escapable` value, it does not propagate the lifetime dependency of its container. Without the call to `overrideLifetime`, `local` would be limited to the local scope of the value retrieved from `self.base`, and could not be returned from the method. In this example, `overrideLifetime` communicates that all of the dependent state from `self` has been *copied* into `local`, and, therefore, `local` can persist after `self` is destroyed.

`overrideLifetime` can also be used to construct an immortal value where the compiler cannot prove immortality by passing a `Void` value as the source of the dependency:

```swift
@lifetime(immortal)
init() {
  self.value = getGlobalConstant() // ✅ unchecked dependency.
  self = unsafe overrideLifetime(self, borrowing: ())
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

Previous revisions of this proposal introduced a `dependsOn` type modifier that would be placed syntactically closer to the return type or argument declaration subject to a dependency:

`func foo(a: A) -> dependsOn(a) R`

Feedback from early adopters convinced us that a separate `@lifetime` attribute improves API clarity and readability. The parenthesized-list syntax does not read well as a type modifier as a function signature scales in complexity.

Developers were also surprised by the new syntax for initializers that forces an explicit `Self` type:

```swift
init(arg: <parameter-convention> ArgType) -> dependsOn(arg) Self
```

And, since mutating methods don't have a `Self`, we would need a new syntax for adding dependencies as part of the method modifier, such as:

```swift
extension Span {
  mutating dependsOn(self: other) func reassign(other: Span<T>) {
    self = other
  }
}
```

The fact that these syntax special cases are so rare actually makes them more problematic because they are more surprising when developers run across them.

### `@lifetime(unchecked)` annotation

A `@lifetime(unchecked)` annotation could allow programmers to disable lifetime dependence checking for a function result or argument. For example, the programmer may want to compose a non-`Escapable` result from an immortal value that isn't visible to the compiler:

```swift
// Existing global function that is not lifetime-annotated
func getGlobalConstant() -> SomeType

@lifetime(immortal)
init() {
  self.value = getGlobalConstant() // 🛑 Error: immortal dependency on a temporary value
}
```

To avoid the error, the programmer could disable dependence checking on the function result altogether:

```swift
@unsafe @lifetime(unchecked)
init() {
  self.value = getGlobalConstant() // ✅ unchecked dependency.
}
```

This poses a few problems:

1. Declaring a result "unchecked" only affects checking within the function body; it doesn't affect checking in clients of the API, so really shouldn't be part of the API. In the example above, `lifetime(immortal)` has the correct semantics at the API level.

2. `lifetime(unchecked)` is a blunt tool for opting out of safety. Experience shows that such tools are overused as workarounds for compiler errors without fixing the problem. A safety workaround should more precisely identify the source of unsafety.

`overrideLifetime` is the proposed tool for disabling dependence checks. Passing `Void` as the dependency source is a reasonable way to convert a nonescaping value to an immortal value:


```swift
@lifetime(immortal)
init() dependsOn(immortal) {
  self.value = getGlobalConstant() // ✅ unchecked dependency.
  unsafe self = overrideLifetime(self, borrowing: ())
}
```

### Lifetime requirements

Adding a `@lifetime` annotation to a struct or enum declaration could add a *lifetime requirement* to the type:

```swift
@lifetime
struct A: ~Escapable {...}
```

A type declared with a lifetime requirement cannot conform to `Escapable`:

```
@lifetime
struct A<T: ~Escapable>: ~Escapable { ... }

extension A: Escapable where T: Escapable {}
    // 🛑 Error: 'A' requires a lifetime. It cannot conform to 'Escapable'.
```

A non-`Escapable` type that does *not* have a lifetime requirement must conditionally conform to Escapable:

```
struct A<T: ~Escapable>: ~Escapable { ... }

extension A: Escapable where T: Escapable {} // ✅

struct B<T: ~Escapable>: ~Escapable { ... }
    // 🛑 Error: must conditionally conform to Escapable.
    // NOTE: either add a `@lifetime` requirement or an extension for `B: Escapable`.
```

This makes the distinction betwen types that intrinsically require a lifetime dependency vs. types that inherit a lifetime requirements from from generic parameters. This distinction so fundamental to the type's behavior that it should be evident in the type's declaration. Forcing the explicit annotation also catches easy mistakes in both directions: (1) forgetting to add the `extension A: Escapable where` clause to conditionally escapable types, and (2) adding a `extension A: Escapable where` clause to types that intrinsically require a lifetime dependency.

As explained in the section "Protocol lifetime requirements", an explicit annotation also makes it possible to assume a lifetime requirements in a generic context.

The authors have not yet decided whether to impose this additional syntax requirement.

## Future directions

### Protocol lifetime requirements

Declarating a protocol with a lifetime requirement allows lifetimes to be required in a generic context. All conforming types must also declare a lifetime requirement.

```swift
@lifetime
protocol P: ~Escapable {...}

@lifetime
struct A: P & ~Escapable {...}

struct B: P & ~Escapable {...}
    // 🛑 Error: 'B' does not conform to 'P'. It lacks a '@lifetime' requirement.
```

#### Protocol lifetime requirement use case

This is useful for generic programming over any set of unconditionally non-`Escapable` types. For example:

```swift
@lifetime
protocol HasRawSpan: ~Escapable {
  var rawSpan: RawSpan
}

@lifetime
struct ViewA: HasRawSpan & ~Escapable {
  var rawSpan: RawSpan
}

@lifetime
struct ViewB: HasRawSpan & ~Escapable {
  var rawSpan: RawSpan
}

@lifetime
struct SubView {
  var span: RawSpan

  @lifetime(copy view)
  init<View: HasRawSpan & ~Escapable>(view: View) {
      span = view.rawSpan
  }
}
```

Note that the initializer above cannot be written without lifetime requirements because it is impossible to copy a lifetime dependency from a potentially Escapable type.

### Nested lifetimes

One crucial limitation of the lifetime dependency model proposed here is that it models every value as having at most one lifetime dependency, and it applies that one lifetime dependency not only to a non-escapable value but also to any non-escapable values that can be derived from it.
This fundamental limitation impacts our ability to fully address many of the future directions discussed here.

In the current design, aggregating multiple values merges their scopes:

```swift
struct Container<Element: ~Escapable>: ~Escapable {
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
  let c = Container(a: a, b: b)
  a = c.a
}
use(a) // 🛑 Error: `a` outlives `c`, which is constrained by the lifetime of both `a` and `b`
```

In the future, we want to be able to represent the dependencies of multiple stored properties independently. This might look something like this:

```swift
struct Container<Element: ~Escapable>: ~Escapable {
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
  let c = Container(a: a, b: b)
  a = c.a
}
use(a) // ✅ `a` copies its lifetime from `c.a`, which in turn copied it from the original `a`
```

Extraction operations could also declare that they copy the lifetime of one or more components:

```swift
extension Container where Element: ~Escapable {
  @lifetime(copy self.a)
  func getA() -> Element {
    return self.a
  }
}

var a = ...
{
  let b = ...
  let c = Container(a: a, b: b)
  a = c.getA()
}
use(a) // ✅ `getA()` copies its lifetime from `c.a`, which in turn copied it from the original `a`
```

The general form of the `@lifetime` syntax in this hypothetical could be thought of as:

> **`@lifetime`** **`(`** (*target*)? (**`.`** *component*)\* **`:`** *source* (**`.`** *component*) **`)`**

#### Nested lifetime requirements

Nested lifetimes are not always neatly tied to stored properties, and they must be part of a type's public interface. We need a syntax that extends a type declaration with nested lifetime requirements. This expands on the "Lifetime requirements" explained earlier by adding a lifetime identifier and accompanying type:

```
@lifetime(lifetime-name: Type)
struct S: ~Escapable {...}
```

The accompanying type can refer to any type in the declarations generic context. It primarily functions to support default lifetime rules so that nested lifetimes seldom need to be explicitly named.

Consider how this will support collections of non-`Escapable` elements that provide `Span`s. Under the current proposal, if `Array` and `Span` were extended to allow for non-`Escapable` element types, then `Span` would lose the distinction between its own lifetime dependency on the memory of the `Array` and the original dependencies of the elements themselves:

```
struct Element: ~Escapable {...}

let e1 = Element(...)
let e2 = Element(...)

var e: NE
do {
  // 'a' depends on 'e1' and 'e2'
  let a: [Element] = [e1, e2]

  // span depends on borrowing 'a'
  let span = a.span

  // 'e' copies the dependency from span, borrowing 'a'
  e = span[randomIndex()]
}

use(e) // 🛑 Error: 'e' depends on 'a' (even though the original 'e1' and 'e2' did not)
```

A `Span` with non-`Escapable` elements involves two interesting lifetime constraints: the lifetime of the memory being referenced, as well as the lifetime constraint of the referenced elements. This can be expressed be giving `Span` nested lifetime requirements:

```swift
@lifetime(storage: Self)
@lifetime(elements: Element)
struct Span<Element: ~Escapable>: ~Escapable {
  // Accessing an element forwards the lifetime(s) of the elements themselves
  subscript(i: Int) -> Element {
    @lifetime(copy self.element)
    borrow { ... }
  }
}
```

Now `Array` can be extended to support non-`Escapable` elements as follows:

```swift
@lifetime(elements: Element)
extension Array<Element: ~Escapable>: ~Escapable {
  // Accessing a span over the array forwards the lifetime(s) of its elements,
  // while its memory is dependent on accessing this array.
  var span: Span<Element> {
    @lifetime(.storage: borrow self, .elements: copy self.elements)
    get { ... }
  }
}
```

Note that all the explicit `@lifetime` annotations in the examples above can be elided in favor of default rules.

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

### First-class nonescaping functions

This proposal allows nonescaping function types to specify lifetime dependencies on their captures, parameters, and results. It does not, however, allow nonescaping functions to be used as a first-class non-`~Escapable` values.
Currently, nonescaping functions can only appear as parameters to other functions. They cannot be used as generic type arguments, and their values can only be used in limited circumstances. With the addition of `Escapable` as a general concept in the language, it would make sense for nonescaping closures to be considered to have non-`Escapable` types. This would be an extremely powerful language tool because it would allow composition of nonescaping closures with other types:

```swift
struct HasClosure: ~Escapable {
  var closure: @nonescaping () -> ()
}
```

For example, it would be natural to model a `TaskGroup` as a non-`Escapable` type, to statically enforce the currently dynamically-enforced variant that the task group not be used outside of a `withTaskGroup` block.
It would furthermore be natural to treat the argument to `addTask` as a nonescaping closure; the scope from which the closure cannot escape is not the immediate `addTask` call, but the `withTaskGroup` block as a whole:

```swift
struct TaskGroup: ~Escapable {
  func addTask(_ body: () -> ())
}
```

### Closure capture dependency syntax

The current proposal allows a function type to return a non-`Escapable` value. Without a `@lifetime` attribute, the function type defaults to a lifetime dependency on the closure's captures. A `@lifetime` attribute can explicitly specify a dependency on a closure parameter instead, and that overrides the dependency on the captures. There is, however, no fundamental reason that a closure can't return a result that that depends on both its captures and its arguments.

One option for supporting this would be to allow a function type's `@lifetime` attribute to refer to the parameter name from its outer declaration's context that identifies the closure value itself:

```swift
func foo(body: @lifetime(copy body, borrow arg) (arg: Arg) -> Span<T>) {...}
```

Dependency on closure value is always a `copy` dependency because the closure context is passed by copy. Ultimately, the lifetime of the closure's result is still restricted to the borrow scope of its captured variables.

This syntax is clear but incomplete. If we wish to support function type aliases, then we need a keyword that can be used as a dependency source to signify a closure's captures:

`typealias SpanGetter = @lifetime(<capture_keyword>, borrow arg) () -> Span<T>`

It is tempting to repurpose the `self` keyword here. After all, a method's `self` parameter is implicitly captured when passed as a closure. On the other hand, the `self` keyword would be ambiguous in a declaration context, and the dependency kind (`copy` vs. `borrow` could be confusing).

We could instead introduce a new keyword, such as `captures`, which would only be recognized in the context of a lifetime dependency source. A dependency kind would not be specified in this case.

Introducing a new `captures` keyword appears to be the best option. It is complete, clear, and unambiguous in all contexts.

### Fine-grained closure capture dependencies

The current proposal allows a closure's result to depend on borrows of all its captured variables. The closure definition syntax could be expanded to indicate which captures the closure result depends on. This has no effect on the partially applied closure's function type. For example, the closure could specify which captures have borrowed, copied, or mutable lifetimes.

```swift
func foo(_: () -> ()) {...}

let unrelated = ...
let array1 = [0, 1]
var span = array1.span
let array2 = [0, 1]
foo { @lifetime(span: borrow array2, copy span) in
  _ = unrelated
  span = (...) ? array2.span : span
}
```

Alternatively, we could rely on the compiler to infer fine-grained capture dependencies.

### Structural lifetime dependencies

A scoped dependency normally cannot escape the lexical scope of its source variable. It may, however, be convenient to escape the source of that dependency along with any values that dependent on its lifetime. This could be done by moving the ownership of the source into a structure that preserves any dependency relationships. A function that returns a non-`Escapable` type cannot currently depend on the scope of a consuming parameter. But we could lift that restriction provided that the consumed argument is moved into the return value, and that the return type preserves any dependency on that value:

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

`arrayToOwnedSpan` creates a span with a scoped dependency on an array, then moves both the array and the span into an `OwnedSpan`, which can be returned from the function. This converts the original lexically scoped dependency into a structural dependency.

### Lifetime types

The current proposal adds language support for expressing lifetime dependencies between a function's values. These dependencies are part the function type, but they define a fixed dependency relationship between a function's parameters and results. Lifetime information could instead be used as a type discriminator. We refer to this alternate approach as "lifetime types". Lifetime types builds on the concept of "nested lifetimes" described above. It could support an alternative syntax, but it would not affect the semantics of lifetime dependencies in most cases. Lifetime types would add a theoretical framework along with a corresponding layer of type checking not present in this proposal.

With lifetime types, every concrete non-`Escapable` type would have additional generic lifetime parameters. Two non-`Escapable` values of the same structural type (e.g. `Span<Int>`) would then take on different formal types whenever they have different lifetime constraints. In other words, every `~Escapable` variable declaration could potentially have a different formal type. The type system would perform automatic type coercion at function boundaries.

The advantage of lifetime types is its support for generic functions that are polymorphic over lifetime constraints. Consider a transformer function that takes a generic transform closure. In the currently proposed design, it can be written as follows:

```swift
@lifetime(copy arg)
func transformer<A: ~Escapable, R: ~Escapable>(
  arg: A,
  transform: @lifetime(copy arg) (_ arg: A) -> R
) -> R {
  return transform(arg)
}
```

This is fine for transforming across different shapes of the same dependent value, such as unwrapping an optional:

```swift
@lifetime(copy optionalSpan)
func foo(optionalSpan: Span<Int>?) -> Span<Int> {
  return transformer(optionalSpan) { optionalSpan! }
}
```

But the same transformer cannot be used to express dependencies on values other than the transformed argument. For example, the transform closure cannot return a captured value as follows:

```swift
@lifetime(copy anotherSpan)
func foo(optionalSpan: Span<Int>?, anotherSpan: Span<Int>) -> Span<Int> {
  return transformer(optionalSpan) { anotherSpan }
}
```

To handle both cases above, the transform closure must conservatively depend on both its argument and its captured values:

```
@lifetime(copy arg)
func transformer<A: ~Escapable, R: ~Escapable>(
  arg: A,
  transform: @lifetime(copy transform, copy arg) (_ arg: A) -> R)
-> R {
  return transform(arg)
}
```

If, on the other hand, lifetimes constraints are encapsulted by generic type, then normal type erasure allows generic functions to operate on `~Escapable` types without a-priori specifying depenency relationships. So, for example, the transformer no longer needs lifetime annotations:

```swift
func transformer<A: ~Escapable, R: ~Escapable>(
  arg: A,
  transform: (_ arg: A) -> R
) -> R {
  return transform(arg)
}
```

In the current proposal, the lifetime checker analyzes the lifetimes of all values in the `transformer` implementation. It checks that the returned value has a dependency on whichever argument are declared lifetime dependent sources. With lifetime types, on the other hand, the return value's lifetime cannot be checked because it has an abstract type parameterized on the function signature. Its dependencies won't be known until its type is fully specialized. That's not possible in Swift because generics are not compile-time monomorphised. The safety of this approach rests on the following principle: return values of abstract non-Escapable types are always safe because type substitution guarantees that they depend on a scope provided by the calling function. In other words, a function can always return a `~Escapable` value as long as the value's type does not include a concrete lifetime scope. Ultimately, the calling code that binds the generic types will resolve the abstract lifetime constraints to scopes available in the caller. The caller's concrete implementation could be written just it is as in the current proposal, but we'll use syntax simlar to Rust to distinguish the two approaches and make it obvious that the lifetimes affect the resulting types:

```swift
func foo<'a, 'b>(optionalSpan: Span<'a, Int>?, anotherSpan: Span<'b, Int>) -> Span<'b, Int> {
  return transformer(optionalSpan) { anotherSpan }
}
```

The consequences for compiler design are significant. In general, the compiler can no longer determine lifetime dependencies from an abstract function type. Resolving lifetime dependencies instead requires a mechanism for global type inferrence. Now, the compiler must infer the closure's dependencies from its implementation. Here, it resolves `transform`'s functions generic types `A => Span<'a, Int>, R => Span<'b, Int>`. 

Consider another example in which a function takes two non-`~Escapable` arguments and returns a value with the same structural type. In the current proposal this would be written as:

```swift
/* DEFAULT: @lifetime(copy a, copy b) */
func mergeElements<T: ~Escapable>(_ a: T, _ b: T, _ merge: (_ a: T, _ b: T) -> T) -> T {
  return merge(a, b)
}
```

All instantiations of `mergeElements` will then have the same dependency constraints:

```swift
// 'c' inherits lifetime constraints from both 'a' and 'b'
let c = mergeElements(a, b) { x, y in x }
```

With lifetime types, the function could be expressed with three generic parameters:

```swift
func mergeElements<A: ~Escapable, B: ~Escapable, R: ~Escapable>(
  _ a: A, _ b: B, _ merge: (_ a: A, _ b: B) -> R) -> R
{
  return merge(a, b)
}
```

Now different instantiations can apply different constraints:

```swift
// R == A
// 'c1' depends on 'a'
let c1 = mergeElements(a, b) { x, y in x }

// R == B
// 'c2' depends on 'b'
let c2 = mergeElements(a, b) { x, y in y }
}
```

Lifetime types would limit expressibility for some code patterns. In particular, value dependencies allow mutable variables to have flow-sensitive lifetime constraints.

```swift
@lifetime(borrow a2)
func foo(a1: [Int], a2: [Int]) -> Span<Int> {
  var span = a1.span
  ...
  span = a2.span
  return span
}
```

Another limitation of lifetime types is that there is no obvious way to support the aforementioned "Structural lifetime dependencies" feature.

## Acknowledgments

Aidan Hall designed function type lifetimes.

Dima Galimzianov provided several examples for Future Directions.

Thanks to Gabor Horvath, Michael Ilseman, Guillaume Lessard, and Karoy Lorentey for adopting this functionality in C++ interop and new standard library APIs and providing valuable feedback.
