# Compile-time Lifetime Dependency Annotations

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Andrew Trick](https://github.com/atrick), [Meghana Gupta](https://github.com/meg-gupta), [Tim Kientzle](https://github.com/tbkka)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Review: ([pitch](https://forums.swift.org/t/pitch-non-escapable-types-and-lifetime-dependency/69865))

## Introduction

We would like to propose extensions to Swift's function-declaration syntax that allow authors to specify lifetime dependencies between the return value and one or more of the parameters.
These would also be useable with methods that wish to declare a dependency on `self`.
To reduce the burden of manually adding such annotations, we also propose inferring lifetime dependencies in certain common cases without requiring any additional annotations.

This is a key requirement for the `StorageView` type (previously called `BufferView`) being discussed elsewhere, and is closely related to the proposal for `~Escapable` types.

#### See Also

* **TODO**: **** Forum thread discussing this proposal
* [Pitch Thread for StorageView](https://forums.swift.org/t/pitch-safe-access-to-contiguous-storage/69888)
* [Forum discussion of BufferView language requirements](https://forums.swift.org/t/roadmap-language-support-for-bufferview)
* [Proposed Vision document for BufferView language requirements (includes description of ~Escapable)](https://github.com/atrick/swift-evolution/blob/fd63292839808423a5062499f588f557000c5d15/visions/language-support-for-BufferView.md#non-escaping-bufferview) 

## Motivation

An efficient way to provide one piece of code with temporary access to data stored in some other piece of code is with a pointer to the data in memory.
Swift's `Unsafe*Pointer` family of types can be used here, but as the name implies, using these types can be error-prone.

For example, suppose `Array` had a property `unsafeBufferPointer` that returned an `UnsafeBufferPointer` to the contents of the array.
Here's an attempt to use such a property:

```swift
let array = getArrayWithData()
let buff = array.unsafeBufferPointer
parse(buff) // <== 🛑 NOT SAFE!
```

One reason for this unsafety is because Swift's standard lifetime rules only apply to individual values.
They cannot guarantee that `buff` will outlive the `array`, which means there is a risk that the compiler might choose to destroy `array` before the call to `parse`, which could result in `buff` referencing deallocated memory.
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

### Background: "Escapable" and “Nonescapable” Types

In order to avoid changing the meaning of existing code, we will introduce two complementary type constraints:
`Escapable` and `~Escapable`.
These constraints can appear in a type declaration as a protocol.

Normal Swift types are `Escapable` by default.
This implies that they can be returned, stored in properties, or otherwise "escape" the local context.
Conversely, types explicitly declared `~Escapable` are not allowed to escape the local context except in very specific circumstances.
A separate proposal explains the general syntax and semantics of `Escapable` and `~Escapable` types.

By themselves, `~Escapable` types have severe constraints on usage.
For example, consider a hypothetical `BufferReference` type that is similar to the standard library `UnsafeBufferPointer` or the `StorageView` type that is being proposed for inclusion in the standard library.
It simply holds a pointer and size and can be used to access data stored in a contiguous block of memory.
(We are not proposing this type; it is shown here merely for illustrative purposes.)

```swift
struct BufferReference<T>: ~Escapable {
  private var base: UnsafePointer<T>
  private var count: Int
}
```

Because this type is marked `~Escapable`, it cannot be returned from a function or even initialized without some way to relax the escapability restrictions.
This proposal provides a set of constraints that can tie the lifetime of a `~Escapable` value to the lifetime of some other value.
In the most common cases, these constraints can be inferred automatically.

### Explicit Lifetime Dependency Annotations

To make the semantics clearer, we’ll begin by describing how one can explicitly specify a lifetime constraint in cases where the default inference rules do not apply.

Let’s consider adding support for our hypothetical `BufferReference` type to `Array`.
Our proposal would allow you to declare an `array.bufferReference()` method as follows:

```swift
extension Array {
  borrowing func bufferReference() -> @dependsOn(self) BufferReference<Element> {
    ... construct a BufferReference ...
  }
}
```

The annotation `@dependsOn(self)` here indicates that the returned value must not outlive the array that produced it.
Conceptually, it is a continuation of the function's borrowing access:
the array is being borrowed by the function while the function executes and then continues to be borrowed by the `BufferReference` for as long as the return value exists.
Specifically, the `@dependsOn(self)` annotation in this example informs the compiler that:

* The array must not be destroyed until after the `BufferReference<Element>` is destroyed.
  This ensures that use-after-free cannot occur.
* The array must not be mutated while the  `BufferReference<Element>` value exists.
  This follows the usual Swift exclusivity rules for a borrowing access.

#### Scoped Lifetime Dependency

Let’s consider another hypothetical type: a `MutatingBufferReference<T>` type that could provide indirect mutating access to a block of memory.
Here's one way such a value might be produced:

```swift
func mutatingBufferReference(to: inout Array, count: Int) -> @dependsOn(to) MutatingBufferReference<Element> {
  ... construct a MutatingBufferReference ...
}
```

We’ve written this example as a free function rather than as a method to show how this annotation syntax can be used to express constraints that apply to a particular argument.
The `@dependsOn(to)` annotation indicates that the returned value depends on the argument named `to`.
Because `count` is not mentioned in the lifetime dependency, that argument does not participate.
Similar to the previous example:

* The array will not be destroyed until after the `MutatingBufferReference<Element>` is destroyed.
* No other read or write access to the array will be allowed for as long as the returned value exists.

In both this and the previous case, the lifetime of the return value is "scoped" to the lifetime of the original value.
Because lifetime dependencies can only be attached to `~Escapable` values, types that contain pointers will generally need to be `~Escapable` in order to provide safe semantics.
As a result, **scoped lifetime dependencies** are the only possibility whenever an `Escapable` value (such as an Array or similar container) is providing a `~Escapable` value (such as the `BufferReference` or `MutatingBufferReference` in these examples).

#### Copy Lifetime Dependency

The case where a `~Escapable` value is used to produce a different `~Escapable` value is somewhat different.
Here's a typical example that constructs a new `BufferReference` from an existing one:
```swift
struct BufferReference<T>: ~Escapable {
  ...
  consuming func drop(_: Int) -> @dependsOn(self) BufferReference<T> { ... }
  ...
}
```

In this examples, the `~Escapable` result depends on a `~Escapable` value.
Recall that `~Escapable` values such as these represent values that are already lifetime-constrained to another value.

For a `consuming` method, the return value cannot have a scoped lifetime dependency on the original value, since the original value no longer exists when the method returns.
Instead, the return value must "copy" the lifetime dependency from the original:
If the original `BufferReference` was borrowing some array, the new `BufferReference` will continue to borrow the same array.

This supports coding patterns such as this:
```swift
let a: Array<Int>
let ref1 = a.bufferReference() // ref1 cannot outlive a
let ref2 = ref1.drop(4) // ref2 also cannot outlive a
```

After `ref1.drop(4)`, the lifetime of `ref2` does not depend on `ref1`.
Rather, `ref2` has **inherited** or **copied** `ref1`’s dependency on the lifetime of `a`.

#### Allowed Lifetime Dependencies

The previous sections described **scoped lifetime dependencies** and **copied lifetime dependencies**
and showed how each type occurs naturally in different use cases.

Now let's look at the full range of possibilities for explicit constraints.
The syntax is somewhat different for functions and methods, though the basic rules are essentially the same.

**Functions:** A simple function with an explicit lifetime dependency annotation generally takes this form:

```swift
func f(arg: <parameter-convention> ArgType) -> @dependsOn(arg) ResultType
```

Where

*  *`parameter-convention`* is one of the ownership specifiers **`borrowing`**, **`consuming`**, or **`inout`**, (this may be implied by Swift’s default parameter ownership rules),
* `ResultType` must be `~Escapable`.

If the `ArgType` is `Escapable`, the return value will have a new scoped dependency on the argument.
(This is the only possibility, as an `Escapable` value cannot have an existing lifetime dependency,
so we cannot copy it.)
A scoped dependency ensures the argument will not be destroyed while the result is alive.
Also, access to the argument will be restricted for the lifetime of the result following Swift's usual exclusivity rules:

* A `borrowing` parameter-convention extends borrowing access, prohibiting mutations of the argument.
* An `inout` parameter-convention extends mutating access, prohibiting any access to the argument.
* A `consuming` parameter-convention is illegal, since that ends the lifetime of the argument immediately.

If the `ArgType` is `~Escapable`, then it can have a pre-existing lifetime dependency.
In this case, the semantics of `@dependsOn()` are slightly different:
* A `consuming` parameter-convention will copy the lifetime dependency from the argument to the result
* A `borrowing` or `inout` parameter-convention can either copy the lifetime dependency or create a new scoped lifetime dependency.
  In this case, for reasons explained earlier, we default to copying the lifetime dependency.
  If a scoped lifetime dependency is needed, it can be explicitly requested by adding the `scoped` keyword:
  
```swift
func f(arg: borrowing ArgType) -> @dependsOn(scoped arg) ResultType
```

**Methods:** Similar rules apply to `self` lifetime dependencies on methods.
Given a method of this form:

```swift
<mutation-modifier> func method(... args ...) -> @dependsOn(self) ResultType
```

The behavior depends as above on the mutation-modifier and whether the defining type is `Escapable` or `~Escapable`.

**Initializers:** An initializer can define lifetime dependencies on one or more arguments.
In this case, we use the same rules same as for “Functions” above
by using the convention that initializers can be viewed as functions that return `Self`:

```swift
init(arg: <parameter-convention> ArgType) -> @dependsOn(arg) Self
```

### Implicit Lifetime Dependencies

The syntax above allows developers to explicitly annotate lifetime dependencies in their code.
But because the possibilities are limited, we can usually allow the compiler to infer a suitable dependency.
The detailed rules are below, but generally we require that the return type be `~Escapable` and that there be one “obvious” source for the dependency.

In particular, we can infer a lifetime dependency on `self` for any method that returns a `~Escapable` type.
As above, the details vary depending on whether `self` is `Escapable` or `~Escapable`:

```swift
struct NonescapableType: ~Escapable { ... }
struct EscStruct {
  func f1(...) -> /* @dependsOn(self) */ NonescapableType
  borrowing func f2(...) -> /* @dependsOn(self) */ NonescapableType
  mutating func f3(...) -> /* @dependsOn(self) */ NonescapableType

  // Note: no lifetime dependency is inferred for a consuming method
  // on an `Escapable` type, since there is no legal option
  consuming func f4(...) -> NonescapableType
}

struct NEStruct: ~Escapable {
  func f1(...) -> /* @dependsOn(self) */ NonescapableType
  borrowing func f2(...) -> /* @dependsOn(self) */ NonescapableType
  mutating func f3(...) -> /* @dependsOn(self) */ NonescapableType

  // Note: A copy lifetime dependency is legal here
  consuming func f4(...) -> /* @dependsOn(self) */ NonescapableType
}
```

For free or static functions or initializers, we can infer a lifetime dependency when the return value is `~Escapable` and there is only one obvious argument that can serve as the source of the dependency.
For example:

```swift
struct NEType: ~Escapable { ... }

// If there is only one argument with an explicit parameter convention:
func f(..., arg1: borrowing Type1, ...) -> /* @dependsOn(arg1) */ NEType

// Or there is only one argument that is `~Escapable`:
func g(..., arg2: NEType, ...) -> /* @dependsOn(arg2) */ NEType

// If there are multiple possible arguments that we might depend
// on, we require an explicit dependency:
// 🛑 Cannot infer lifetime dependency since `arg1` and `arg2` are both candidates
func g(... arg1: borrowing Type1, arg2: NEType, ...) -> NEType
```

We expect these implicit inferences to cover most cases, with the explicit form only occasionally being necessary in practice.

## Detailed design

### Grammar

This new syntax adds an optional lifetime modifier just before the return type.
This modifies *function-result* in the Swift grammar as follows:

>
> *function-signature* → *parameter-clause* **`async`***?* **`throws`***?* *function-result**?* \
> *function-signature* → *parameter-clause* **`async`***?* **`rethrows`** *function-result**?*
> *function-result* → **`->`** *attributes?* *lifetime-modifiers?* *type*
> *lifetime-modifiers* **`->`** *lifetime-modifier* *lifetime-modifiers?*
> *lifetime-modifier* **`->`** **`@dependsOn`** **`(`** *lifetime-dependency* **`)`**
> *lifetime-dependency* **`->`** **`self`** | *local-parameter-name* | **`scoped self`** | **`scoped`** *local-parameter-name*
>

Here, the *lifetime-dependency* argument to the lifetime modifier must be one of the following:

* *local-parameter-name*: the local name of one of the function parameters, or
* the token **`self`**, or
* either of the above preceded by the **`scoped`** keyword

#### Initializers

Initializers can have arguments, and there are cases where users will want to specify a lifetime dependency between one or more arguments and the constructed value.
We propose allowing initializers to write out an explicit return clause for this case.
The return type must be exactly the token `Self` or the token sequence `Self?` in the case of a failable initializer:

```swift
struct S {
  init(arg1: Type1) -> @dependsOn(arg1) Self
  init?(arg2: Type2) -> @dependsOn(scoped arg2) Self?
}
```

> Grammar of an initializer declaration:
>
> *initializer-declaration* → *initializer-head* *generic-parameter-clause?* *parameter-clause* **`async`***?* **`throws`***?* *initializer-lifetime-modifier?* *generic-where-clause?* *initializer-body* \
> *initializer-declaration* → *initializer-head* *generic-parameter-clause?* *parameter-clause* **`async`***?* **`rethrows`** *initializer-lifetime-modifier?* *generic-where-clause?* *initializer-body*
> *initializer-lifetime-modifier* → `**->**` *lifetime-modifiers* ** **`Self`** \
> *initializer-lifetime-modifier* → `**->**` *lifetime-modifiers* ** **`Self?`**

### Inference Rules

If there is no explicit lifetime dependency, we will automatically infer one according to the following rules:

**For methods where the return type is `~Escapable`**, we will infer a dependency against self, depending on the mutation type of the function.
Note that this is not affected by the presence, type, or modifier of any other arguments to the method.

**For a free or static functions or initializers with at least one argument,** we will infer a lifetime dependency when all of the following are true:

* the return type is `~Escapable`,
* there is exactly one argument that satisfies any of the following:
** is either `~Copyable` or `~Escapable`
** is `Escapable` and `Copyable` and has an explicit `borrowing`, `consuming`, or `inout` convention specified

In this case, the compiler will infer a dependency on the unique argument identified by this last set of conditions.

**In no other case** will a function, method, or initializer implicitly gain a lifetime dependency.
If a function, method, or initializer has a `~Escapable` return type, does not have an explicit lifetime dependency annotation, and does not fall into one of the cases above, then that will be a compile-time error.

### Semantics

The previous sections detail how lifetime dependency between the return value of a function or method and a function argument, method argument, or `self` can be explicitly declared or implicitly inferred by the compiler.

When the dependency involves a function, method, or initializer argument,
if the corresponding argument is `borrowing` or `inout` then we can refer to that argument as the *source* of the dependency, and the return value then has a *scoped lifetime dependency* on the source.
When this occurs, the compiler may shorten the lifetime of the return value or extend the lifetime of the source value within the existing language rules in order to satisfy the requirements below.
Further, the compiler will issue diagnostics if these requirements cannot be satisfied:

* The return value must be destroyed before the source value.
  This can be obstructed if there are other factors (such as nested scopes, function returns, or closure captures) that contradict the lifetime dependency.
* For a borrowing argument, the source value cannot be mutated before the return value is destroyed.
* For an inout argument, the source value is accessed or mutated before the return value is destroyed.

The rules above apply with the obvious modifications for a method that explicitly or implicitly has a lifetime dependency between the return value and `self`.

If the `lifetime-kind` is `consume` or `copy`, then the return value from the function or method gains the same lifetime dependency as the function argument, method argument, or `self`.
In this case, we’ll refer to the argument or `self` as the *original* value.
In this case, the original value must itself must be `~Escapable`, and must in turn have a borrow or mutate lifetime dependency on some other source value.
The return value will then have a borrow or mutate lifetime dependency on that same source value that will be enforced by the compiler as above.

### Relation to ~Escapable

The lifetime dependencies described in this document can be applied only to `~Escapable` return values.
Further, any return value that is `~Escapable` must have a lifetime dependency.
In particular, this implies that the initializer for a non-escapable type must have at least one argument.

```swift
struct S: ~Escapable {
  init() {} // 🛑 Error: ~Escapable return type must have lifetime dependency
}
```

## Source compatibility

Everything discussed here is additive to the existing Swift grammar and type system.
It has no effect on existing code.

The tokens `-> dependsOn` in a function declaration might indicate the beginning of a borrowing lifetime annotation or could indicate that the function returns an existing type called `dependsOn`.
This ambiguity can be fully resolved in the parser by looking for an open parenthesis `(` after the `dependsOn` token.

## Effect on ABI stability

Lifetime dependency annotations may affect how values are passed into functions, and thus adding or removing one of these annotations should generally be expected to affect the ABI.

## Effect on API resilience

Adding a lifetime dependency constraint can cause existing valid source code to no longer be correct, since it introduces new restrictions on the lifetime of values that pre-existing code may not satisfy.
Removing a lifetime dependency constraint only affects existing source code in that it may change when deinitializers run, altering the ordering of deinitializer side-effects.

## Alternatives considered

### Different Position

We propose above putting the annotation on the return value, which we believe matches the intuition that the method or property is producing this lifetime dependence alongside the returned value.
It would also be possible to put an annotation on the parameters instead:

```swift
func f(@resultDependsOn arg1: Array<Int>) -> BufferReference<Int>
```

Depending on the exact language in use, it could also be more natural to put the annotation after the return value.
However, we worry that this hides this critical information in cases where the return type is longer or more complex.

```swift
func f(arg1: Array<Int>) -> BufferReference<Int> dependsOn(arg1)
```

### Different spellings

An earlier version of this proposal advocated using the existing `borrow`/`mutate`/`consume`/`copy` keywords to specify a particular lifetime dependency semantic:
```swift
func f(arg1: borrow Array<Int>) -> borrow(arg1) BufferReference<Int>
```
This was changed after we realized that there was in practice almost always a single viable semantic for any given situation, so the additional refinement seemed unnecessary.

## Future Directions

#### Lifetime Dependencies for Computed Properties

It might be useful to allow lifetime dependencies between `self` and the value returned by a computed property.
There is some ambiguity here, since resilience hides the distinction between a computed and stored property.
In particular, the resilience concern might prevent us from inferring lifetime dependencies for properties across module boundaries.
The notation for an explicit lifetime dependency on a property might look like the following:

```swift
struct Container {
  var view: ReturnType { borrowing get }
}

extension Type1 {
  var transformedView: Type1 { consuming get }
}
```

Where `borrowing` or `consuming` would indicate that the returned value has a lifetime dependency on `self`.
We expect that the lifetime notation would be mandatory for any property that provided a `~Escaping` value.

#### Lifetime Dependencies for Escapable Types

This proposal has deliberately limited the application of lifetime dependencies to return types that are `~Escapable`.
This simplifies the model by identifying `~Escapable` types as exactly those types that can carry such dependencies.
It also helps simplify the enforcement of lifetime constraints by guaranteeing that constrained values cannot escape before being returned.
Most importantly, this restriction helps ensure that the new semantics (especially lifetime dependency inference) cannot accidentally break existing code.
We expect that in the future, additional investigation can reveal a way to relax this restriction.

#### Lifetime Dependencies between arguments

A caller may need assurance that a callee will honor a lifetime dependency between two arguments.
For example, if a function is going to destroy a container and a reference to that container in the process of computing some result,
it needs to guarantee that the reference is destroyed before the container:
```swift
func f(container: consuming ContainerType, ref: @dependsOn(container) consuming RefType) -> ResultType
```

#### Lifetime Dependencies for Tuples

It should be possible to return a tuple where one part has a lifetime dependency.
For example:
```swift
func f(a: consume A, b: B) -> (consume(a) C, B)
```
We expect to address this in the near future in a separate proposal.

#### Lifetime Dependencies for containers and their elements

It should be possible to return containers with collections of lifetime-constrained elements.
For example, a container may want to return a partition of its contents:
```swift
borrowing func chunks(n: Int) -> @dependsOn(self) SomeList<@dependsOn(self) StorageView<UInt8>>
```
We're actively looking into ways to support these more involved cases and expect to address this in a future proposal.

#### Parameter index for lifetime dependencies

Internally, the implementation records dependencies based on the parameter index.
This could be exposed as an alternate spelling if there were sufficient demand.

```swift
func f(arg1: Type1, arg2: Type2, arg3: Type3) -> @dependsOn(0) ReturnType
```

## Acknowledgements

Dima Galimzianov provided several examples for Future Directions.
