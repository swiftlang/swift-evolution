# Extend Property Wrappers to Function and Closure Parameters

* Proposal: [SE-0293](0293-extend-property-wrappers-to-function-and-closure-parameters.md)
* Authors: [Holly Borla](https://github.com/hborla), [Filip Sakel](https://github.com/filip-sakel)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Scheduled for review (January 27...February 8, 2021)**
* Implementation: [apple/swift#34272](https://github.com/apple/swift/pull/34272)
* Decision Notes: [Review #2](https://forums.swift.org/t/returned-for-revision-2-se-0293-extend-property-wrappers-to-function-and-closure-parameters/44832), [Review #1](https://forums.swift.org/t/returned-for-revision-se-0293-extend-property-wrappers-to-function-and-closure-parameters/42953)
* Previous versions: [Revision #2](https://github.com/apple/swift-evolution/blob/bdf12b26d15d63ab7e58dab635a55ffeca841389/proposals/0293-extend-property-wrappers-to-function-and-closure-parameters.md), [Revision #1](https://github.com/apple/swift-evolution/blob/e5b2ce1fd6c1c2617a820a1e6f2b53a00e54fdce/proposals/0293-extend-property-wrappers-to-function-and-closure-parameters.md)

## Contents

+ [Introduction](#introduction)
+ [Motivation](#motivation)
  - [Applying a common behavior via property wrapper](#applying-a-common-behavior-via-property-wrapper)
  - [Arguments with auxiliary values via property wrapper projection](#arguments-with-auxiliary-values-via-property-wrapper-projection)
+ [Proposed solution](#proposed-solution)
+ [Detailed design](#detailed-design)
  - [Passing a projected value argument](#passing-a-projected-value-argument)
  - [Inference of API-level property wrappers](#inference-of-api-level-property-wrappers)
  - [Implementation-detail property wrappers](#implementation-detail-property-wrappers)
    - [Arguments in the property-wrapper attribute](#arguments-in-the-property-wrapper-attribute)
  - [API-level property wrappers](#api-level-property-wrappers)
    - [Function-body semantics](#function-body-semantics)
    - [Call-site semantics](#call-site-semantics)
    - [Semantics of function expressions](#semantics-of-function-expressions)
      - [Unapplied function references](#unapplied-function-references)
      - [Closures](#closures)
  - [Overload resolution of backing property-wrapper initializer](#overload-resolution-of-backing-property-wrapper-initializer)
  - [Restrictions on property-wrapper parameters](#restrictions-on-property-wrapper-parameters)
+ [Source compatibility](#source-compatibility)
+ [Effect on ABI stability](#effect-on-abi-stability)
+ [Effect on API resilience](#effect-on-api-resilience)
+ [Alternatives considered](#alternatives-considered)
  - [Preserving property wrapper parameter attributes in the type system](#preserving-property-wrapper-parameter-attributes-in-the-type-system)
  - [Only allow implementation-detail property wrappers on function parameters](#only-allow-implementation-detail-property-wrappers-on-function-parameters)
  - [Passing a property-wrapper storage instance directly](#passing-a-property-wrapper-storage-instance-directly)
+ [Future directions](#future-directions)
  - [The impact of formalizing separate property wrapper models](#the-impact-of-formalizing-separate-property-wrapper-models)
  - [Explicit spelling for API-level property wrappers](#explicit-spelling-for-api-level-property-wrappers)
  - [Library-defined diagnostic notes for understanding API wrapper restrictions](#library-defined-diagnostic-notes-for-understanding-api-wrapper-restrictions)
  - [API Property wrappers in protocol requirements](#api-property-wrappers-in-protocol-requirements)
  - [Generalized property-wrapper initialization from a projection](#generalized-property-wrapper-initialization-from-a-projection)
  - [Extending property wrappers to patterns](#extending-property-wrappers-to-patterns)
  - [Property-wrapper parameters in member-wise initializers](#property-wrapper-parameters-in-member-wise-initializers)
  - [Support `inout` in wrapped function parameters](#support-inout-in-wrapped-function-parameters)
  - [Wrapper types in the standard library](#wrapper-types-in-the-standard-library)
+ [Revisions](#revisions)
  - [Changes from the second reviewed version](#changes-from-the-second-reviewed-version)
  - [Changes from the first reviewed version](#changes-from-the-first-reviewed-version)
+ [Appendix](#appendix)
  - [Mutability of composed `wrappedValue` accessors](#mutability-of-composed-wrappedValue-accessors)
+ [Acknowledgements](#acknowledgements)


## Introduction

Property Wrappers were [introduced in Swift 5.1](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md), and have since become a popular mechanism for abstracting away common accessor patterns for properties. Currently, applying a property wrapper is solely permitted on local variables and type properties. However, with increasing adoption, demand for extending _where_ property wrappers can be applied has emerged. This proposal aims to extend property wrappers to function and closure parameters.


## Motivation

Property wrappers have undoubtably been very successful. Applying a property wrapper to a property is enabled by an incredibly lightweight and expressive syntax. For instance, frameworks such as [SwiftUI](https://developer.apple.com/documentation/swiftui/) and [Combine](https://developer.apple.com/documentation/combine) introduce property wrappers such as [`State`](https://developer.apple.com/documentation/swiftui/state), [`Binding`](https://developer.apple.com/documentation/swiftui/binding) and [`Published`](https://developer.apple.com/documentation/combine/published) to expose elaborate behavior through a succinct interface, helping craft expressive yet simple APIs. However, property wrappers are only applicable to local variables and type properties, shattering the illusion that they helped realize in the first place when working with parameters.

Property wrappers attached to parameters have a wide variety of use cases. We present a few examples here.

### Applying a common behavior via property wrapper

Property wrappers are often used as sugar for applying a common behavior to a value, such as asserting a precondition, transforming the value, or logging the value. Such behaviors are also valuable to apply to function parameters. For example, using `Validation` from [`PropertyKit`](https://github.com/SvenTiigi/ValidatedPropertyKit), we can abstract various preconditions into a property wrapper:

```swift
@propertyWrapper
struct Asserted<Value> {
  init(
    wrappedValue: Value, 
    validation: Validation<Value>,
  ) { ... }

  var wrappedValue: Value { ... }
}
```

It would be useful to apply `@Asserted` to parameters to assert certain preconditions on argument values. For example, the following code asserts that the argument passed to the `quantity` parameter is greater than or equal to 1:

```swift
func buy(
  @Asserted(.greaterOrEqual(1)) quantity: Int,
  of product: Product,
) { ... }
```

Similarly, one could write an `@Logged` property wrapper to be used as a light-weight debugging tool to see the arguments passed to a function each time that function is called:

```swift
@propertyWrapper
struct Logged<Value> {
  init(wrappedValue: Value) {
    print(wrappedValue)
    self.wrappedValue = wrappedValue
  }

  var wrappedValue: Value {
    didSet {
      print(wrappedValue)
    }
  }
}

// Every time `runAnimation` is called, the `duration` argument
// will be logged by the property wrapper.
func runAnimation(@Logged withDuration duration: Double) { ... }
```

### Arguments with auxiliary values via property wrapper projection

Consider the following property wrapper, inspired by `@Traceable` from [David Piper's blog post](https://medium.com/better-programming/creating-a-history-with-property-wrappers-in-swift-5-1-4c0202060a7f), which tracks the history of a value:

```swift
struct History<Value> { ... }

@propertyWrapper
struct Traceable<Value> {
  init(wrappedValue value: Value) { ... }
  init(projectedValue: History<Value>) { ... }

  private var history: History<Value>

  var wrappedValue: Value {
    get {
      history.currentValue
    }
    set {
      history.append(newValue)
    }
  }

  var projectedValue: History<Value> {
    history
  }
}
```

This property wrapper provides the history of the traced value via its projection, and it can be initialized with a value to be traced, or with an existing history of a traced value. Now consider the following model for a simple text editor that supports change tracking:

```swift
struct TextEditor {
  @Traceable var dataSource: String
}
```

Currently, property-wrapper attributes on struct properties interact with function parameters through the struct's synthesized member-wise initializer. Because the `@Traceable` property wrapper supports initialization from a wrapped value via `init(wrappedValue:)`, the member-wise initializer for `TextEditor` will take in a `String`. However, the programmer may want to initialize `TextEditor` with a string value that already has a history. Today, this behavior can be achieved with overloads, which can greatly impact compile-time performance and impose boilerplate on the programmer. Another approach is to expose the `Traceable` type through the `TextEditor` initializer, which is unfortunate since the backing storage is meant to be implementation detail.

## Proposed solution

We propose to allow application of property wrappers on function and closure parameters, allowing the call-site to pass a wrapped value, or a projected value if appropriate, which will be used to automatically initialize the backing property wrapper.

It's clear from a survey of the use cases for property wrappers on parameters that there are two kinds of property wrappers. The first kind of property wrapper is an abstraction of a common behavior on a value, such as logging, transforming, or caching a value. For these property wrappers, you use the wrapped value generally the same way as you would if the value did not have the wrapper attached, and the wrapper itself is implementation detail. Callers that provide the value to initialize the property wrapper will always pass an instance of the wrapped-value type.

The second kind of property wrapper attaches additional semantics to the value being wrapped that are fundamental to understanding how the wrapped value can be used. These wrappers tend to attach auxiliary API through the wrapper's `projectedValue`, and many of these wrappers cannot be initialized from an instance of the wrapped-value type.

The natural model for these two kinds of wrappers is different when applied to parameters, because the second model must allow the caller to pass a different type of argument. We propose to formalize the difference between API-level property wrappers that have an external effect on the function and implementation-detail property wrappers. The compiler will determine whether a property wrapper must have an external effect on the function by analyzing the property wrapper's initializers.

Annotating a parameter declaration with a property-wrapper attribute allows the call-site to pass a wrapped value, or a projected value if supported by the wrapper, and the compiler will automatically initialize the backing wrapper. The function author can also use the property-wrapper syntax for accessing the backing wrapper and the projected value within the body of the function.

## Detailed design

### Passing a projected value argument

Property-wrapper projections are designed to allow property wrappers to provide a representation of the storage type that can be used outside of the context that owns the property-wrapper storage. Typically, projections either expose the backing property wrapper directly, or provide an instance of a separate type that vends more restricted access to the functionality of the property wrapper.

When a property-wrapper has a projection, it's often necessary to use the projection alongside the wrapped value. In such cases, the projection is equal in importance to the wrapped value in the API of the wrapped property, which is reflected in the access control of synthesized projection properties. With respect to function parameters, it's equally important to support passing a projection.

Property wrappers can opt into passing a projected-value argument to a property-wrapped parameter. To enable passing a property-wrapper projection to a function with a wrapped parameter, property wrappers must declare `var projectedValue`, and implement an `init(projectedValue:)` that meets the following requirements:

- The first parameter of this initializer must be labeled `projectedValue` and have the same type as the `var projectedValue` property.
- The initializer must have the same access level as the property-wrapper type.
- The initializer must not be failable.
- Any additional parameters to the initializer must have default arguments.

This method of initialization is not mandatory for functions using supported wrapper types, and it can be disabled by providing arguments in the wrapper attribute, including empty attribute arguments: `func log(@Traceable() _ value: Value) { ... }`.

### Inference of API-level property wrappers

For a given property wrapper attached to a parameter, the compiler will infer whether that wrapper is part of the function signature based on whether the wrapper must have an external effect on the argument at the call-site. This proposal limits external argument effects to the case where the property wrapper allows the caller to pass an instance of the projected-value type, which means the property wrapper [supports projected-value initialization](#passing-a-projected-value-argument) via `init(projectedValue:)` and there are no arguments in the wrapper attribute.

A property wrapper will only be inferred as API if `init(projectedValue:)` is declared directly in the nominal property wrapper type. This is to ensure that the same decision is always made regardless of which module the property wrapper is applied in. This is also the same strategy that is used today to determine whether a computed projection property with the `$` prefix should be synthesized when a property wrapper is applied, and whether a property wrapper supports initialization from a wrapped value.

### Implementation-detail property wrappers

By default, property wrappers are implementation detail. Attaching an implementation-detail property wrapper attribute to a parameter will synthesize the following local variables in the function body:

* A local `let`-constant representing the backing storage will be synthesized with the name of the parameter prefixed with an underscore. The backing storage is initialized by passing the parameter to `init(wrappedValue:)`.
* A local computed variable representing the `wrappedValue` of the innermost property wrapper will be synthesized with the same name as the original, unprefixed parameter name. If the innermost `wrappedValue` defines a setter, a setter will be synthesized for the local property if the mutability of the composed setter is `nonmutating`. The mutability computation is specified in the [appendix](#appendix).
* If the outermost property wrapper defines a `projectedValue` property with a `nonmutating` getter, a local computed variable representing the outermost `projectedValue` will be synthesized and named per the original parameter name prefixed with a dollar sign (`$`). If the outermost `projectedValue` defines a setter, a setter for the local computed variable will be synthesized if the `projectedValue` setter is `nonmutating`.


Consider the following code, which attaches the `@Logged` property wrapper to a parameter.

```swift
func insert(@Logged text: String) { ... }
```

The above code is sugar for:

```swift
func insert(text: String) {
  let _text: Logged<String> = Logged(wrappedValue: text)

  var text: String { _text.wrappedValue }
}
```

Note that the backing storage is a let-constant, and the local `text` property does not have a setter.

> **Rationale**: It would be confusing if it appears that a user can mutate a parameter, because those changes will not be reflected in the caller once the function returns.

Implementation-detail property wrappers on parameters must support initialization from a wrapped value, and the parameter type must be equal to the wrapped value type of the wrapper.

##### Arguments in the property-wrapper attribute

Property-wrapper attributes with arguments applied to parameters are always implementation-detail property wrappers, even if the property wrapper supports initialization from a projected value.

> **Rationale**: Arguments in the wrapper attribute only apply to `init(wrappedValue:)`. To ensure that these arguments never change, the property wrapper must always be initialized via `init(wrappedValue:)` and pass the additional attribute arguments.

Because property wrappers with attribute arguments are always implementation-detail, this means the arguments will always be evaluated in the function body.

The remainder of the Detailed design section describes the semantics of applying an API-level property wrapper to a parameter.

### API-level property wrappers

Property wrappers that declare an `init(projectedValue:)` initializer are inferred to be API-level wrappers. These wrappers become part of the function signature, and the property wrapper is initialized at the call-site of the function.

#### Function-body semantics

Attaching an API-level property wrapper to a parameter makes that parameter a computed variable local to the function body, and changes the parameter type to the backing wrapper type. The type of the parameter is only observable in compiled code; [unapplied references to functions with property-wrapped parameters](#unapplied-function-references) will not use the backing-wrapper type.

The transformation of functions with a property-wrapped parameter will be performed as such:

* The argument label will remain unchanged.
* The parameter name will be prefixed with an underscore.
* The type of the parameter will be the backing property-wrapper type.
* A local computed variable representing the `wrappedValue` of the innermost property wrapper will be synthesized with the same name as the original, unprefixed parameter name. If the innermost `wrappedValue` defines a setter, a setter will be synthesized for the local property if the mutability of the composed setter is `nonmutating`. The mutability computation is specified in the [appendix](#appendix).
* If the outermost property wrapper defines a `projectedValue` property with a `nonmutating` getter, a local computed variable representing the outermost `projectedValue` will be synthesized and named per the original parameter name prefixed with a dollar sign (`$`). If the outermost `projectedValue` defines a setter, a setter for the local computed variable will be synthesized if the `projectedValue` setter is `nonmutating`.

Consider the following function which has a parameter with the `@Traceable` property wrapper attached:

```swift
func copy(@Traceable text: String) { ... }
```

The compiler will synthesize computed `text` and `$text` variables in the body of `copy(text:)`:

```swift
func copy(text _text: Traceable<String>) {
  var text: String {
    get { _text.wrappedValue }
  }

  var $text: History<String> {
    get { _text.projectedValue }
  }

  ...
}
```

#### Call-site semantics

When passing an argument to a parameter with an API-level property wrapper, the compiler will wrap the argument in a call to the appropriate initializer depending on the argument label. When using the original argument label (or no argument label), the compiler will wrap the argument in a call to `init(wrappedValue:)`. When using the argument label prefixed with `$` (or `$_` in the case of no argument label), the compiler will wrap the argument in a call to `init(projectedValue:)`.

Consider the `@Traceable` property wrapper that implements both `init(wrappedValue:)` and `init(projectedValue:)`:

```swift
struct History<Value> { ... }

@propertyWrapper
struct Traceable<Value> {
  init(wrappedValue value: Value)
  init(projectedValue: History<Value>)

  var wrappedValue: Value
  var projectedValue: History<Value>
}
```

A function with an `@Traceable` parameter can be called with either a wrapped value or a projected value:

```swift
func log<Value>(@Traceable value: Value) { ... }

let history: History<Int> = ...

log(value: 10)
log($value: history)
```

The compiler will inject a call to the appropriate property-wrapper initializer into each call to `log` based on the argument label, so the above code is transformed to:

```swift
log(value: Traceable(wrappedValue: 10))
log(value: Traceable(projectedValue: history))
```

Wrapped parameters with no argument label can still be passed a projection using the syntax `$_:`, as shown in the following example:

```swift
func log<Value>(@Traceable _ value: Value) { ... }

let history: History<Int> = ...

log(10)
log(_: 10)
log($_: history)
```

For composed property wrappers, initialization of the backing wrapper via wrapped value will contain a call to `init(wrappedValue:)` for each property-wrapper attribute in the composition chain. However, initialization via projected value will only contain one call to `init(projectedValue:)` for the outermost wrapper attribute, because property wrapper projections are not composed. For example: 

```swift
func log(@Traceable @Traceable text: String) { ... }

let history: History<Traceable<String>> = ...

log(text: "Hello!")
log($text: history)
```

The above calls to `log` are transformed to:

```swift
log(text: Traceable(wrappedValue: Traceable(wrappedValue: "Hello!"))
log(text: Traceable(projectedValue: history))
```

This transformation at the call-site only applies when calling the function directly using the declaration name. The semantics of closures and unapplied function references are specified [in a later section](#semantics-of-function-expressions).

#### Semantics of function expressions

##### Unapplied function references

By default, unapplied references to functions that accept property-wrapped parameters use the wrapped-value type in the parameter list, and the compiler will generate a thunk to initialize the backing wrapper and call the function.

Consider the `log` function from above, which uses the `@Traceable` property wrapper:

```swift
func log<Value>(@Traceable value: Value) { ... }
```

The type of `log` is `(Value) -> Void`. These semantics can be observed when working with an unapplied reference to `log`:

```swift
let logReference: (Int) -> Void = log
logReference(10)

let labeledLogReference: (Int) -> Void = log(value:)
labeledLogReference(10)
```

The compiler will generate a thunk when referencing `log` to take in the wrapped-value type and initialize the backing property wrapper. Both references to `log` in the above example are transformed to:

```swift
{ log(value: Traceable(wrappedValue: $0) }
```

The type of an unapplied function reference can be changed to instead take in the projected-value type using `$` in front of the argument label. Since `Traceable` implements `init(projectedValue:)`, the `log` function can be referenced in a way that takes in `History` by using `$` in front of `value`:

```swift
let history: History<Int> = ...
let logReference: (History<Int>) -> Void = log($value:)
logReference(history)
```

If the property-wrapped parameter in `log` omitted its argument label, the function could still be referenced to take in the projected-value type using `$_`:

```swift
func log<Value>(@Traceable _ value: Value) { ... }

let history: History<Int> = ...
let logReference: (History<Int>) -> Void = log($_:)
logReference(history)
```

##### Closures

Closures have the same semantics as unapplied function references, albeit with different syntax because the property-wrapper attribute needs to be specified on the closure parameter declaration. The above `log` function can be implemented as a closure that takes in the wrapped-value type:

```swift
let log: (Int) -> Void = { (@Traceable value) in
  ...
}
```

The closure can be implemented to instead take in the projected-value type by using the `$` prefix in the parameter name:

```swift
let log: (History<Int>) -> Void { (@Traceable $value) in
  ...
}
```

For closures that take in a projected value, the property-wrapper attribute is not necessary if the backing property wrapper and the projected value have the same type, such as the [`Binding`](https://developer.apple.com/documentation/swiftui/binding) property wrapper from SwiftUI. If `Binding` implemented `init(projectedValue:)`, it could be used as a property-wrapper attribute on closure parameters without explicitly writing the attribute:

```swift
let useBinding: (Binding<Int>) -> Void = { $value in
  ...
}
```

Since property-wrapper projections are not composed, this syntax will only infer one property-wrapper attribute. To use property-wrapper composition, the attributes must always be explicitly written.

#### Overload resolution of backing property-wrapper initializer

For both implementation-detail and API property wrappers, the type of the wrapped parameter (not the argument) is used for overload resolution of `init(wrappedValue:)` and `init(projectedValue:)`. For example, if a property wrapper defines overloads of `init(wrappedValue:)` with different generic constraints and that wrapper is used on a function parameter, e.g.:

```swift
@propertyWrapper
struct Wrapper<Value> {
  init(wrappedValue: Value) { ... }

  init(wrappedValue: Value) where Value : Collection { ... }
}

func generic<T>(@Wrapper value: T) { ... }
```

Overload resolution will choose which `init(wrappedValue:)` to call based on the static type of the parameter at the declaration of the property wrapper attribute. Because the type of the parameter `value` is an unconstrained generic type parameter, the unconstrained `init(wrappedValue:)` will always be called:

```swift
// Both of the following calls use the unconstrained 'init(wrappedValue:)'
generic(value: 10)
generic(value: [1, 2, 3])
```

However, `generic` could be overloaded where `T : Collection` to allow the constrained `init(wrappedValue:)` to be called:

```swift
func generic<T>(@Wrapper value: T) { ... }
func generic<T : Collection>(@Wrapper value: T) { ... }

generic(value: 10)        // calls the unconstrained init(wrappedValue:)
generic(value: [1, 2, 3]) // calls init(wrappedValue:) where Value : Collection
```

### Restrictions on property-wrapper parameters

The composed mutability of the innermost `wrappedValue` getter must be `nonmutating`.

> **Rationale**: If the composed `wrappedValue` getter is `mutating`, then the local computed property for a property-wrapper parameter must mutate the backing wrapper, which is immutable.

Property-wrapper parameters cannot have an `@autoclosure` type.

> **Rationale**: A wrapped value cannot have an `@autoclosure` type. If `init(wrappedValue:)` needs to accept an `@autoclosure`, a warning will be emitted with a fix-it to use a regular `@autoclosure` parameter and a local property wrapper instead.

API property-wrapper parameters cannot also have an attached result builder attribute.

> **Rationale**: Result-builder attributes can be applied to the parameters in `init(wrappedValue:)` and `init(projectedValue:)`. If there is a result builder attached to a property-wrapper parameter that already has a result builder in `init(wrappedValue:)`, it's unclear which result builder should be applied.

Non-instance methods cannot use property wrappers that require the [enclosing `self` subscript](0258-property-wrappers.md#referencing-the-enclosing-self-in-a-wrapper-type).

> **Rationale**: Non-instance methods do _not_ have an enclosing `self` instance, which is required for the local computed property that represents `wrappedValue`.

API property wrapper attributes can only be used on parameters in overridden functions or protocol witnesses if the original has the same property wrapper attributes.

> **Rationale**: This restriction ensures that the call-site transformation is always the same for families of dynamically dispatched functions.

API property wrappers must match the access level of the enclosing function.

> **Rationale**: These property wrappers have an external effect on the argument at the call-site, so they must be accessible to all callers.

## Source compatibility

This is an additive change with no impact on source compatibility.

## Effect on ABI stability

This is an additive change with no impact on the existing ABI.

## Effect on API resilience

Implementation-detail property wrappers have no impact on API resilience. These property wrappers will not be preserved in the generated Swift interface for the module, so they are entirely implementation detail.

However, API-level property wrappers applied to function parameters are part of the API and ABI of that function. This is because a property wrapper applied to a function parameter changes the type of that parameter, which is reflected in the ABI; it also changes the way that function callers are compiled to pass an argument of that type. Thus, adding or removing a property wrapper on an ABI-public function parameter is not a resilient change. Furthermore, similar to the existing behavior of default arguments, arguments in wrapper attributes are emitted into clients and are therefore not a part of the ABI.

Finally, property wrappers changing between implementation-detail and API-level is not a resilient change. For example, consider a property wrapper that is implementation-detail when applied to a parameter. Adding an `init(projectedValue:)` initializer to this property wrapper is a source-breaking change for clients that use this property wrapper in a function that is a protocol witness, and it is an ABI breaking change for any code that uses this property wrapper on a parameter. We expect this case to be very rare, and clients can work around the source and ABI break by either adding an argument to the wrapper attribute or using a local wrapped variable instead.

## Alternatives considered

### Preserving property wrapper parameter attributes in the type system

One approach to achieving the expected semantics for higher-order functions with property wrappers in the parameter list is to preserve property wrapper attributes in parameter types. While this is feasible for plain property wrapper attributes, it is not feasible in the case where the property wrapper attribute has attribute arguments, because type equality cannot be dependent on expression equivalence.

### Only allow implementation-detail property wrappers on function parameters

Only allowing implementation-detail property wrappers on function parameters would eliminate the need for the API-level versus implementation-detail distinction for functions, because the property wrapper would never have an external effect on the argument. However, allowing property wrappers to have an external effect on the wrapped declaration is part of what makes the feature so powerful and applicable to a wide variety of use cases. One fairly common class of property wrappers are those which provide an abstracted reference to a value, such as the [`Ref` / `Box` example](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md#ref--box) from the SE-0258 proposal, and [`Binding`](https://developer.apple.com/documentation/swiftui/binding) from SwiftUI. It's common to pass these property wrappers around as projections, and there isn't currently a nice way to achieve the property wrapper sugar in a function body that uses such a property wrapper. The best way to achieve this currently is to use a local property wrapper and initialize the backing storage directly, e.g.

```swift
func useReference(reference: Ref<Int>) {
  @Ref var value: Int
  _value = reference
}
```

Furthermore, property wrappers can already have an external effect on the wrapped declaration today. For example, the compiler may change the type of the accessors of the wrapped declaration based on the mutability of the property wrapper's `wrappedValue` accessors, and the synthesized member-wise initializer of a type containing wrapped properties can change based on which initializers the property wrapper provides. Formalizing the distinction can only help the compiler provide the programmer with more tools to understand code that uses such property wrappers.

### Passing a property-wrapper storage instance directly

A previous revision of this proposal supported passing a property-wrapper storage instance to a function with a wrapped parameter directly because the type of such a function was in terms of the property-wrapper type. A big point of criticism during the first review was that the backing storage type should be an artifact of the function implementation, and not exposed to function callers through the type system.

Exposing the property-wrapper storage type through the type system has the following implications, summarized by [Frederick Kellison-Linn](https://forums.swift.org/u/jumhyn):

* The addition/removal of a property-wrapper attribute on a function parameter is a source-breaking change for any code that references or curries the function.
* It prohibits the use of initializer arguments in the wrapper attribute. There's no point in declaring a wrapper as `@Asserted(.greaterOrEqual(1))` if any client can simply pass an `Asserted` instance with a completely different validation.
* It removes API control from both the property wrapper author and the author of the wrapped-argument function.

Keeping the property-wrapper storage type private is consistent with how property wrappers work today. Unless a property wrapper projects its storage type via `projectedValue`, the storage type itself is meant to be a private implementation detail inaccessible to API clients.

## Future directions

### The impact of formalizing separate property wrapper models

The design of this property wrapper extension includes a formalized distinction between property wrappers that are implementation detail and property wrappers that are API. These two kinds of wrappers will need to be modeled differently in certain places in the language. This section explores the impact that introducing two separate models for property wrappers will have on the language and the future design space for property wrappers.

The property wrapper model inside the declaration context of the wrapped property will remain the same between these two kinds of property wrappers. Whether the property wrapper is API or implementation detail, the auxiliary declaration model is fundamental to programmers' understanding of how property wrappers work and how to use them, and this model should not be changed in any future enhancement to the property wrapper feature. Property wrappers are and will always be syntactic sugar for code that the programmer can write manually using exactly the strategy that the compiler uses - auxiliary variables and custom accessors on the wrapped property. Any enhancements to property wrappers that add capabilities to the auxiliary declarations, such as access to the enclosing `self` instance or delegating to an existing stored property, will not be impacted by the API versus implementation detail distinction.

The distinction of API versus implementation detail _will_ have an impact outside of the enclosing context of the wrapped declaration. Conceptually, the API versus implementation-detail distinction should only impact the parts of the language where an abstraction that contains a property wrapper attribute is used.

Across module boundaries, implementation-detail property wrappers become invisible, because these wrappers are purely a detail of how the module is implemented. Clients have no knowledge of these wrappers, so property wrapper attributes that appear in the module must be API property wrappers.

The modeling difference between implementation-detail and API property wrappers is only observable when both are used within the same module, and the difference is mainly observable in the language restrictions on the use of API versus implementation-detail wrappers. These two models are designed such that nearly all observable semantics of property wrapper application do not differ based on where the wrapper is applied. The only observable semantic difference that the proposal authors can think of is evaluation order among property wrapper initialization and other arguments that are passed to the API, and the proposal authors believe it is extremely unlikely that this evaluation order will have any impact on the functionality of the code. For evaluation order to have a functional impact, both the property wrapper initializer _and_ another function argument would both need to call into a separate function that has some side effect. For example:

```swift
func hasSideEffect() -> Int {
  struct S {
    static var state = 0
  }

  S.state += 1
  return S.state
}

@propertyWrapper
struct Wrapper {
  var wrappedValue: Int

  init(wrappedValue: Int) {
    self.wrappedValue = wrappedValue + hasSideEffect()
  }
}

func demonstrateEvaluationOrder(@Wrapper arg1: Int, arg2: Int) {
  print(arg1, arg2)
}

demonstrateEvaluationOrder(arg1: 1, arg2: hasSideEffect())
```

If the property wrapper initializer is evaluated in the caller, the output of this code is `2, 2`. If the property wrapper initializer is evaluated in the callee, the output of the code is `3, 1`.

The proposal authors believe that these two kinds of property wrappers already exist today, and formalizing the distinction is a first step in enhancing programmers' understanding of such a complex feature. Property wrappers are very flexible to cover a wide variety of use cases. Formalizing the two broad categories of use cases opens up many interesting possibilities for the language and compiler to enhance library documentation when API wrappers are used, provide better guidance to programmers, and even allow library authors to augment the guidance given to programmers on invalid code.

### Explicit spelling for API-level property wrappers

The scope of what is considered an API-level property wrapper is very limited in this proposal, and the external effect of an API-level property wrapper may be useful for wrappers that don't fit the current definition. The `@propertyWrapper` attribute could have an explicit `apiLevel` option that allows library authors to define whether the property wrapper has an external effect on the wrapped declaration:

```swift
@propertyWrapper(apiLevel)
struct Asserted<Value> {
  init(
    wrappedValue: Value,
    _ assertion: (Value) -> Bool,
    file: StaticString = #file,
    line: UInt = #line
  ) { ... }
}
```

### Library-defined diagnostic notes for understanding API wrapper restrictions

API property wrappers on parameters have more restrictions than implementation detail property wrappers, because they have an external effect to the function. One very nice thing about property wrappers as custom attributes is that the documentation for that attribute is defined by the library author. Extend this principle, we could allow library authors to also define custom diagnostic notes to help explain restrictions that exist due to the external effects the wrapper imposes on the function.

A custom diagnostic framework may also be useful for API-level property wrappers that are applied to properties, because such wrappers often change the semantics of the wrapped declaration in a way that fundamentally changes how the declaration can be used. For instance, a property wrapper may change the accessor mutability of the wrapped property, which may cause unexpected and unhelpful diagnostics when the programmer accesses the property incorrectly. The compiler cannot help explain _why_ there is a difference in mutability when the wrapper is attached, because the compiler does not understand how the property wrapper may change the behavior of the wrapped value.

### API property wrappers in protocol requirements

Protocol requirements that include property wrappers was [pitched](https://forums.swift.org/t/property-wrapper-requirements-in-protocols/33953) a while ago, but there was a lot of disagreement about whether property wrappers are implementation detail or API. With this distinction formalized, we could allow only API-level property wrappers in protocol requirements.

### Generalized property-wrapper initialization from a projection

This proposal adds `init(projectedValue:)` as a new property-wrapper initialization mechanism from a projected value for function arguments. This mechanism could also be used to support definite initialization from a projected value for properties and local variables:

```swift
struct TextEditor {
  @Traceable var dataSource: String

  init(history: History<String>) {
    // treated as _dataSource = Traceable(projectedValue: history)
    $dataSource = history 
  }
}
```

### Extending property wrappers to patterns

Passing a property-wrapper storage instance directly to a property-wrapped closure parameter was supported in first revision. One suggestion from the core team was to imagine this functionality as an orthogonal feature to allow pattern matching to "unwrap" property wrappers. Though this proposal revised the design of closures to match the behavior of unapplied function references, extending property wrappers to all patterns is still a viable future direction.

Enabling the application of property wrappers in value-binding patterns would facilitate using the intuitive property-wrapper syntax in native language constructs, as shown below:

```swift
enum Review {
  case revised(Traceable<String>)
  case original(String)
}

switch Review(fromUser: "swiftUser5") {
case .revised(@Traceable let reviewText),
     .original(let reviewText):
  // do something with 'reviewText'
}
```

### Property-wrapper parameters in member-wise initializers

Synthesized member-wise initializers could use property-wrapper parameters for stored properties with attached property wrappers:

```swift
struct TextEditor {
  @Traceable var dataSource: String

  // Synthesized memberwise init
  init(@Traceable dataSource: String) { ... }
}

func copyDocument(in editor: TextEditor) -> TextEditor {
  TextEditor($dataSource: editor.$dataSource)
}
```

### Support `inout` in wrapped function parameters

This proposal doesn't currently support marking property-wrapped function parameters `inout`. We deemed that this functionality would be better tackled by another proposal, due to its implementation complexity. Nonetheless, such a feature would be useful for mutating a `wrappedValue` argument when the wrapper has a `mutating` setter.

### Wrapper types in the standard library

Adding wrapper types to the standard library has been discussed for types [such as `@Atomic`](https://forums.swift.org/t/atomic-property-wrapper-for-standard-library/30468) and [`@Weak`](https://forums.swift.org/t/should-weak-be-a-type/34032), which would facilitate certain APIs. Another interesting standard library wrapper type could be `@UnsafePointer`, which would be quite useful, as access of the `pointee` property is quite common:

```swift
let myPointer: UnsafePointer<UInt8> = ...

myPointer.pointee 
//        ^~~~~~~ 
// This is the accessor pattern property 
// wrappers were devised to tackle.
```

Instead of writing the above, in the future one might be able to write the following:

```swift
let myInt = 0

withUnsafePointer(to: ...) { $value in
  print(value) // 0
  
  $value.withMemoryRebound(to: UInt64.self) {
    ... 
  }
}
```

As a result, unsafe code is not dominated by visually displeasing accesses to `pointee` members; rather, more natural and clear code is enabled.

## Revisions

### Changes from the second reviewed version

* The distinction between API wrappers and implementation-detail wrappers is formalized, and determined by the compiler based on whether the property wrapper type allows the call-site to pass a different type of argument.
* Implementation-detail property wrappers on parameters use callee-side application of the property wrapper, and have no external effect on the function.
* API property wrappers on parameters use caller-side application of the property wrapper, and are part of the function signature.
* Overload resolution for property wrapper initializers will always be done at the property wrapper declaration.

### Changes from the first reviewed version

* Passing a projected value using the `$` calling syntax is supported via `init(projectedValue:)`.
* The type of the unapplied function reference uses the wrapped-value type by default. Referencing the function using the projected-value type is supported by writing `$` in front of the argument label, or by writing `$_` if there is no argument label.
* Closures with property-wrapper parameters have the same semantics as unapplied function references.
* Additional arguments in the wrapper attribute are supported, and these arguments have the same evaluation semantics as default function arguments.

## Appendix

#### Mutability of composed `wrappedValue` accessors

The algorithm is computing the mutability of the synthesized accessors for a wrapped parameter (or property) with _N_ attached property wrapper attributes. Attribute 1 is the outermost attribute, and attribute _N_ is the innermost. The accessor mutability is the same as the mutability of the _N_ th .wrappedValue access, e.g. _param.wrappedValue<sub>1</sub>.wrappedValue<sub>2</sub>. [...] .wrappedValue<sub>N</sub>

The mutability of the _N_ th access is defined as follows:

* If _N = 1_, the mutability of the access is the same as the mutability of the wrappedValue accessor in the 1st property wrapper.
Otherwise:
  * If the wrappedValue accessor in the _N_ th property wrapper is nonmutating, then the _N_ th access has the same mutability as the _N - 1_ th get access.
  * If the wrappedValue accessor in the _N_ th property wrapper is mutating, then the _N_ th access is mutating if the _N - 1_ th get or set access is mutating.

**Example**: Consider the following `Reference` property wrapper, which is composed with `Asserted` and used on a function parameter:

```swift
@propertyWrapper
struct Reference<Value> {
  var wrappedValue: Value {
    get { ... }
    nonmutating set { ... }
  }
  var projectedValue: Reference<Value> {
    self
  }
}

func useReference(@Reference @Logged reference: String) {
  ...
}
```

In the above example, the function `useReference` is equivalent to:

```swift
func useReference(reference _reference: Reference<Logged<String>>) {
  var reference: String {
    get { 
      _reference.wrappedValue.wrappedValue
    }
    set { 
      _reference.wrappedValue.wrappedValue = newValue
    }
  }

  var $reference: Reference<Logged<String>> {
    get {
      _reference.projectedValue
    }
  }
    
  ...
}
```

Since both the getter and setter of `Reference.wrappedValue` are `nonmutating`, a setter can be synthesized for `var reference`, even though `Asserted.wrappedValue` has a `mutating` setter. `Reference` also defines a `projectedValue` property, so a local computed property called `$reference` is synthesized in the function body, but it does _not_ have a setter, because `Reference.projectedValue` only defines a getter.

## Acknowledgements

This proposal was greatly improved as a direct result of feedback from the community. [Doug Gregor](https://forums.swift.org/u/douglas_gregor) and [Dave Abrahams](https://forums.swift.org/u/dabrahams) surfaced more use cases for property-wrapper parameters. [Frederick Kellison-Linn](https://forums.swift.org/u/jumhyn) proposed the idea to change the behavior of unapplied function references based on argument labels, and provided [ample justification](#passing-a-property-wrapper-storage-instance-directly) for why the semantics in the first revision were unintuitive. [Lantua](https://forums.swift.org/u/lantua) pushed for the behavior of closures to be consistent with that of functions, and proposed the idea to use `$` on closure parameters in cases where the wrapper attribute is unnecessary. Finally, ideas from [Jens Jakob Jensen](https://forums.swift.org/u/jjj) and [John McCall](https://forums.swift.org/u/john_mccall) were combined to produce the 'inference of external property wrapper' design in its current form.

Many others participated throughout the several pitches and first review. This feature would not be where it is today without the thoughtful contributions from folks across our community.
