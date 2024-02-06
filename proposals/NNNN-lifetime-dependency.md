# Compile-time Lifetime Dependency Annotations

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Andrew Trick](https://github.com/atrick), [Meghana Gupta](https://github.com/meg-gupta), [Tim Kientzle](https://github.com/tbkka)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Review: ([pitch](https://forums.swift.org/t/pitch-non-escapable-types-and-lifetime-dependency/69865))

## Introduction

We would like to propose extensions to Swift's function-declaration syntax that allow authors to specify lifetime dependencies between the return value and one or more of the arguments.
These would also be useable with methods that wish to declare a dependency on `self`.
To reduce the burden of manually adding such annotations, we also propose inferring lifetime dependencies in certain common cases without requiring any additional annotations.

This is a key requirement for the `BufferView` type being discussed elsewhere, and is closely related to the proposal for `~Escapable` types.

#### See Also

* **TODO**: **** Forum thread discussing this proposal
* [Forum discussion of BufferView language requirements](https://forums.swift.org/t/roadmap-language-support-for-bufferview)
* [Proposed Vision document for BufferView language requirements (includes description of ~Escapable)](https://github.com/atrick/swift-evolution/blob/fd63292839808423a5062499f588f557000c5d15/visions/language-support-for-BufferView.md#non-escaping-bufferview) 

## Motivation

An efficient way to provide one piece of code with temporary access to data stored in some other piece of code is with a pointer to the data in memory.
Swift's `Unsafe*Pointer` family of types can be used here, but as the name implies, using these types can be error-prone.

For example, suppose `Array` had a property `unsafeBufferPointer` that returned an `UnsafeBufferPointer` to the contents of the array.
Here's an attempt to use such a property:

```
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

```
// 🛑 The following line of code is dangerous!  DO NOT DO THIS!
let buff = array.withUnsafeBufferPointer { $0 }
```

## Proposed solution

A "lifetime dependency" between two objects indicates that one of them can only be destroyed *after* the other.
This dependency is enforced entirely at compile time; it requires no run-time support.
These lifetime dependencies can be expressed in several different ways, with varying trade-offs of expressiveness and ease-of-use.

### “Non-Escapable” Types

In order to avoid changing the meaning of existing code, we will introduce a new type constraint spelled `~Escapable`.
This type constraint can appear in a type declaration as a protocol.
Consider a hypothetical `BufferReference` type that is similar to the standard library `UnsafeBufferPointer` or the `BufferView` type that is being proposed for inclusion in the standard library.
It simply holds a pointer and size and can be used to access data stored in a contiguous block of memory.
(We are not proposing this type; it is shown here merely for illustrative purposes.)

```
struct BufferReference<T>: ~Escapable {
  private var base: UnsafePointer<T>
  private var count: Int
}
```

Because this type is marked `~Escapable`, any function that returns this type must specify a lifetime constraint on the return value, using one of the methods described in the following sections.
In the most common cases, these constraints can be inferred automatically.
However, to make the semantics clearer, we’ll begin by describing how one can explicitly specify a lifetime constraint in cases where the default inference rules do not apply.

**Note**: A full proposal for `~Escapable` will be submitted elsewhere.
The above is intended to cover just the minimal features of `~Escapable` required by this proposal.

### Explicit Lifetime Dependency Annotations

We propose new return value annotations to explicitly describe lifetime dependencies.
For example, let’s consider adding support for our hypothetical `BufferReference` type to `Array`.
Our proposal would allow you to declare an `array.bufferReference()` method as follows:

```
extension Array {
  borrowing func bufferReference() -> borrow(self) BufferReference<Element> {
    ... construct a BufferReference ...
  }
}
```

The annotation `borrow(self)` indicates that the returned value has "borrowed" the contents of the array (`self`).
This is because the returned `BufferReference<Element>` has read-only access to the stored contents of the array.
Note how this return type aligns with the `borrowing func` declaration that declares read-only borrowed access to the array for the lifetime of the function.
In essence, the `borrow(self)` annotation extends that borrowed access beyond the function lifetime to include the lifetime of the returned value.
Specifically, the `borrow(self)` annotation informs the compiler that:

* The array must not be destroyed until after the `BufferReference<Element>` is destroyed.
  This ensures that use-after-free cannot occur.
* The array must not be mutated while the  `BufferReference<Element>` value exists.
  This enforces the usual Swift exclusivity rules.

In addition to `borrow(self)`, we also propose supporting three other lifetime dependency annotations:

#### `mutate(self)`  or  `mutate(arg)`

Let’s consider another hypothetical type: a `MutatingBufferReference<T>` type that could provide indirect mutating access to a block of memory.
This would need to be exposed slightly differently, since it provides *write* access:

```
func mutatingBufferReference(to: inout Array) -> mutate(to) MutatingBufferReference<Element> {
  ... construct a MutatingBufferReference ...
}
```

We’ve written this example as a free function rather than as a method to show how this annotation syntax can be used to express constraints that apply to a particular argument.
The `mutate(to)` annotation indicates that the returned value has exclusive read/write access to the contents of the array, which is passed as the `inout` argument `to`.This means that no other read or write access to the argument will be allowed for as long as the returned value exists.

#### `consume(self)  or  consume(arg)`

In addition to allowing `BufferReference` values to be constructed directly from arrays, the author of our hypothetical type would also want to control the lifetimes of `BufferReference` values constructed from pre-existing `BufferReference` values.
There are two different situations:

We might want to create a new `BufferReference` while destroying a pre-existing one.
For example, we may want a method that provides a new reference that excludes the initial items:

```
extension BufferReference {
  consuming func drop(first: Int) -> consume(self) BufferReference<Element> { ... }
}
```

This supports code like the following;

```
let a: Array<Int>
let ref1 = a.bufferReference() // ref1 cannot outlive a
let ref2 = ref1.drop(4) // ref2 also cannot outlive a
```

Note that in `ref1.drop(4)`, the lifetime of `ref2` does not depend on `ref1`.
Rather, `ref2` has inherited `ref1`’s dependency on the lifetime of `a`.

#### `copy(self)`  or  `copy(arg)`

A similar concern arises even when the source is not being consumed.

```
extension BufferReference {
  func dropping(first: Int) -> copy(self) BufferReference<Element> { ... }
}
```

As with the `consume(self)` example above, the new `BufferReference` will inherit the lifetime of the original.

The annotations can be combined in various ways to express complex lifetime interactions between the return value and the arguments:

```
func complexView(data: Array<Item>, statistics: Array<Statistics>, other: Int)
     -> borrow(data) mutate(statistics) ComplexReferenceType
{ ... }
```

#### Allowed Lifetime Dependencies

Only certain types of lifetime dependencies make sense, depending on the type of argument.
The syntax is somewhat different for functions and methods, though the basic rules are essentially the same.

**Functions:** A function with a lifetime dependency annotation generally takes this form:

```
func f(arg: <parameter-convention> ArgType) -> <lifetime-type>(arg) ResultType
```

Where

*  *`parameter-convention`* is one of the ownership specifiers **`borrowing`**, **`consuming`**, or **`inout`**, (this may be implied by Swift’s default parameter ownership rules),
* *`lifetime-type`* is one of the lifetime dependency annotations **`copy`**, **`borrow`**, **`consume`**, or **`mutate`**.
* `ResultType` must be `~Escapable`.

Further:

* `borrow` lifetime-type is only permitted with a `borrowing` parameter-convention
* `mutate` lifetime-type is only permitted with an `inout` parameter-convention
* `consume` lifetime-type is only permitted with a `consuming` parameter-convention
* `copy` lifetime-type is only permitted with `borrowing` or `inout` parameter-convention

**Methods:** Similar rules apply to `self` lifetime dependencies on methods.
Given a method of this form:

```
<mutation-modifier> func method(... args ...) -> <lifetime-type>(self) ResultType
```

We only permit

* A `borrow(self)` lifetime dependency with a `borrowing` mutation-modifier
* A `mutate(self)` lifetime dependency with a `mutating` mutation-modifier
* A `consume(self)` lifetime dependency with a `consuming` mutation-modifier
* A `copy(self)` lifetime dependency with a `borrowing` or `inout` mutation-modifier

The rules above apply regardless of whether the parameter-convention or mutation-modifier is explicitly written or is implicit.

**Initializers:** An initializer can define a lifetime dependency on one of its arguments.
In this case, the rules are the same as for “Functions” above:

```
init(arg: <parameter-convention> ArgType) -> <lifetime-type>(arg) Self
```

### Implicit Lifetime Dependencies

The syntax above allows developers to explicitly annotate lifetime dependencies in their code.
But because the possibilities are limited, we can usually allow the compiler to infer the dependency.
The detailed rules are below, but generally we require that the return type be `~Escapable` and that there be one “obvious” source for the dependency.

In particular, for methods, whenever there is an explicit mutation type, we can infer the matching lifetime dependency on `self`:

```
struct NonEscapableType: ~Escapable { ... }
struct S {
  borrowing func f(...) -> /* borrow(self) */ NonEscapableType
  mutating func f(...) -> /* mutate(self) */ NonEscapableType
  consuming func f(...) -> /* consume(self) */ NonEscapableType
```

For free or static functions or initializers, we can infer when there is one obvious argument to serve as the source of the dependency.
Specifically, we’ll do this when there is one argument that is `~Escapable` or `~Copyable` (these are the types that already have lifetime restrictions, so are the natural types to expect for this role) and has an explicit parameter convention.
For example:

```
struct Type1: ~Copyable /* Or: ~Escapable */ /* Or: ~Copyable & ~Escapable */
struct Type2: ~Escapable { ... }
func f(..., arg1: borrowing Type1, ...) -> /* borrow(arg1) */ Type2
func f(..., arg1: consuming Type1, ...) -> /* consume(arg1) */ Type2
func f(..., arg1: inout Type1, ...) -> /* mutate(arg1) */ Type2
```

We expect these implicit inferences to cover most cases, with the explicit form only occasionally being necessary in practice.

## Detailed design

### Grammar

This new syntax adds an optional lifetime modifier just before the return type.
This modifies *function-result* in the Swift grammar as follows:

>
> *function-signature* → *parameter-clause* **`async`***?* **`throws`***?* *function-result**?* \
> *function-signature* → *parameter-clause* **`async`***?* **`rethrows`** *function-result**?* \
> *function-result* → **`->`** *attributes**?* *lifetime-modifiers**?* *type*
> *lifetime-modifiers* **`->`** *lifetime-modifier* *lifetime-modifiers**?*
> *lifetime-modifier* **`->`** *lifetime-modifier-type* **`(`** **`self`** `**)**` \
> *lifetime-modifier* **`->`** *lifetime-modifier-type* **`(`** *external-parameter-name* `**)**` \
> *lifetime-modifier* **`->`** *lifetime-modifier-type* **`(`** *parameter-index* `**)**` 
> *lifetime-modifier-type* **`->`** **`copy`** | **`borrow`** | **`mutate`** | **`consume`**
>

Here, the argument to the lifetime modifier must be one of the following:

* *external-parameter-name:* the external name of one of the function parameters,
* *parameter-index:* a numeric index of one of the parameters in the *parameter-clause* (the first parameter is number zero), or
* the token **`self`**.

Additionally, the argument referred to by the *external-parameter-name* or *parameter-index* must have an explicit *parameter-modifier* of `inout`, `borrowing`, or `consuming`.
If the *lifetime-modifier* is the token `**self**`**,** then the method must have a *mutation-modifier* of `mutating`, `borrowing`, or `consuming`.

#### Initializers

Initializers can have arguments, and there are cases where users will want to specify a lifetime dependency between one or more arguments and the constructed value.
We propose allowing initializers to write out an explicit return clause for this case:

```
struct S {
  init(arg1: Type1) -> borrow(arg1) Self
}
```

This syntax will be rejected if the return type is not exactly the token `Self`.

> Grammar of an initializer declaration:
>
> *initializer-declaration* → *initializer-head* *generic-parameter-clause?* *parameter-clause* **`async`***?* **`throws`***?* *initializer-lifetime-modifier?* *generic-where-clause?* *initializer-body* \
> *initializer-declaration* → *initializer-head* *generic-parameter-clause?* *parameter-clause* **`async`***?* **`rethrows`** *initializer-lifetime-modifier?* *generic-where-clause?* *initializer-body*
> *initializer-lifetime-modifier* → `**->**` *lifetime-modifiers* ** **`Self`**

### Inference Rules

If there is no explicit lifetime dependency, we will automatically infer one according to the following rules:

**For methods where the return type is `~Escapable` and there is an explicit mutation type**, we will infer a dependency against self, depending on the mutation type of the function.
Note that this is not affected by the presence, type, or modifier of any other arguments to the method.
Specifically, we will infer:

* a `borrow` lifetime dependency for a method that borrows `self`
* a `mutate` lifetime dependency for a method that is `mutating` on self
* a `consume` lifetime dependency for a method that is `consuming` on self

**For a free or static functions or initializers with at least one argument,** we will infer a lifetime dependency when all of the following are true:

* the return type is `~Escapable`,
* there is exactly one argument that is either `~Copyable` or `~Escapable`
* that argument has an explicit `borrowing`, `consuming`, or `inout` convention specified

In this case, the compiler will infer:

* a `borrow` lifetime dependency for a function whose only `~Escapable` or `~Copyable` argument is `borrowing` 
* a `mutate` lifetime dependency for a function whose only `~Escapable` or `~Copyable` argument is `inout`
* a `consume` lifetime dependency for a function whose only `~Escapable` or `~Copyable` argument is `consuming`

**In no other case** will a function, method, or initializer implicitly gain a lifetime dependency.
If a function, method, or initializer has a `~Escapable` return type, does not have an explicit lifetime dependency annotation, and does not fall into one of the cases above, then that will be a compile-time error.

### Semantics

The syntax above declares a lifetime dependency between the return value of a function or method and a function argument, method argument, or `self`.

If the `lifetime-modifier` (either specified or inferred) is `borrow` or `mutate`, then we can refer to the argument or `self` as the *source* of the dependency, and the return value then has respectively a *borrow* *lifetime dependency* or a *mutate lifetime dependency* ** on the source.
When this occurs, the compiler may shorten the lifetime of the return value or extend the lifetime of the source value within the existing language rules in order to meet the requirement.
Further, the compiler will issue diagnostics in the following cases:

* If the return value cannot be destroyed before the source value.
This can happen if there are other factors (such as nested scopes, function returns, or closure captures) that contradict the lifetime dependency.
* For a borrow lifetime dependency, if the source value is mutated before the return value is destroyed.
* For a mutate lifetime dependency, if the source value is accessed or mutated before the return value is destroyed.

If the `lifetime-modifier` is `consume` or `copy`, then the return value from the function or method gains the same lifetime dependency as the function argument, method argument, or `self`.
In this case, we’ll refer to the argument or `self` as the *original* value.
In this case, the original value must itself must be `~Escapable`, and must in turn have a borrow or mutate lifetime dependency on some other source value.
The return value will then have a borrow or mutate lifetime dependency on that same source value that will be enforced by the compiler as above.

### Relation to ~Escapable

The lifetime dependencies described in this document can be applied only to `~Escapable` return values.
Further, any return value that is `~Escapable` must have a lifetime dependency.
In particular, this implies that the initializer for a non-escapable type must have at least one argument.

```
struct S: ~Escapable {
  init() {} // 🛑 Error: ~Escapable return type must have lifetime dependency
}
```

## Source compatibility

Everything discussed here is additive to the existing Swift grammar and type system.
It has no effect on existing code.

The tokens `-> borrowing` in a function declaration might indicate the beginning of a borrowing lifetime annotation or could indicate that the function returns an existing type called `borrowing`.
This ambiguity can be fully resolved in the parser by looking for an open parenthesis `(` after the `borrowing`, `mutating`, `copy`, or `consume` token.

## Effect on ABI stability

Lifetime dependency annotations may affect how values are passed into functions, and thus adding or removing one of these annotations should generally be expected to affect the ABI.

## Effect on API resilience

Adding a lifetime dependency constraint can cause existing valid source code to no longer be correct, since it introduces new restrictions on the lifetime of values that pre-existing code may not satisfy.
Removing a lifetime dependency constraint only affects existing source code in that it may change when deinitializers run, altering the ordering of deinitializer side-effects.

## Alternatives considered

### Different Position

We propose above putting the annotation on the return value, which we believe matches the intuition that the method or property is producing this lifetime dependence alongside the returned value.
It would also be possible to put an annotation on the parameters instead:

```
func f(@resultDependsOn arg1: Array<Int>) -> BufferReference<Int>
```

Depending on the exact language in use, it could also be more natural to put the annotation after the return value.
However, we worry that this hides this critical information in cases where the return type is longer or more complex.

```
func f(arg1: Array<Int>) -> BufferReference<Int> dependsOn(arg1)
```

### Different spellings

We propose above using the existing `borrow`/`mutate`/`consume`/`copy` keywords, since we feel the new behaviors have a substantial similarity to how similar keywords are used elsewhere in the language.

Other alternatives considered include:

```
func f(arg1: Array<Int>) -> @dependsOn(arg1) BufferReference<Int>
```

The above syntax states the dependency, but could require elaboration to clarify the type of dependency.
As illustrated by the inference rules above, there is often only one reasonable lifetime dependency type for a particular situation.
But `copy` and “Downgraded dependencies” described below complicate this somewhat.

```
func f(arg1: Array<Int>) -> @scoped(arg1) BufferReference<Int>
```

Lifetime dependencies are sometimes referred to as “scoped access.” We find this terminology less natural in practice.

#### Implicit argument convention or method mutation modifier

The Detailed design above requires that any function, method, or property that returns a `~Escapable` type must have an implicit or explicit lifetime constraint.
Further, it requires that any lifetime constraint refer to an argument with an *explicit* mutation convention or `self` where the method has an *explicit* mutation modifier.
For example:

```
func f(arg1: Type1) -> borrow(arg1) NonEscapableType // 🛑 `arg1` must be marked `borrowing`

... Type ... {
  func f() -> borrow(self) Self // 🛑 method must be marked `borrowing`
}
```

Requiring an explicit mutation specification seems to us to improve readability, but could potentially be dropped by relying on Swift’s usual default argument and method conventions.

## Future Directions

#### Lifetime Dependencies for Computed Properties

It might be useful to allow lifetime dependencies between `self` and the value returned by a computed property.
There is some ambiguity here, since resilience hides the distinction between a computed and stored property, and it’s not clear that there is any use for lifetime dependencies when returning stored properties.
In particular, the resilience concern might prevent us from inferring lifetime dependencies for properties across module boundaries.
The notation for an explicit lifetime dependency on a property might look like the following:

```
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
We expect that in the future, additional investigation can reveal a way to relax this restriction.

#### Downgraded Dependencies

```
// This is forbidden by the current proposal, but could be supported in theory
func f(arg1: inout Array<Int>) -> borrow BufferReference<Int>
```

Our current proposal requires that `inout` arguments only be used with `mutate` lifetime dependencies (or `copy` if the argument is itself `~Escapable`).
It may be useful to permit “downgrading” the access so that the function can have mutating access to the argument while it is running, but only extends read-only `borrow` access to the return value.
We are not confident that we can make this fully safe today:  With our current diagnostic work, we cannot prevent the implementor of `f` from “sneaking” read-write access into the returned value.
We hope to expand these diagnostics in the future, at which point we may be able to safely lift this restriction.

#### Lifetime Dependencies between arguments

A caller may need assurance that a callee will honor a lifetime dependency between two arguments.
For example, if a function is going to destroy a container and a reference to that container in the process of computing some result,
it needs to guarantee that the reference is destroyed before the container:
```
func f(container: consuming ContainerType, ref: borrow(container) consuming RefType) -> ResultType
```
