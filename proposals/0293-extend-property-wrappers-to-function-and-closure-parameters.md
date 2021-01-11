# Extend Property Wrappers to Function and Closure Parameters

* Proposal: [SE-0293](0293-extend-property-wrappers-to-function-and-closure-parameters.md)
* Authors: [Holly Borla](https://github.com/hborla), [Filip Sakel](https://github.com/filip-sakel)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Awaiting review**
* Implementation: [apple/swift#34272](https://github.com/apple/swift/pull/34272)
* Decision Notes: [Review #1](https://forums.swift.org/t/returned-for-revision-se-0293-extend-property-wrappers-to-function-and-closure-parameters/42953)
* Previous versions: [Revision #1](https://github.com/apple/swift-evolution/blob/e5b2ce1fd6c1c2617a820a1e6f2b53a00e54fdce/proposals/0293-extend-property-wrappers-to-function-and-closure-parameters.md)

## Contents

+ [Introduction](#introduction)
+ [Motivation](#motivation)
+ [Proposed solution](#proposed-solution)
+ [Detailed design](#detailed-design)
  - [Function-body semantics](#function-body-semantics)
  - [Call-site semantics](#call-site-semantics)
    - [Passing a projected value argument](#passing-a-projected-value-argument)
    - [Arguments in the property-wrapper attribute](#arguments-in-the-property-wrapper-attribute)
    - [Overload resolution of backing property-wrapper initializer](#overload-resolution-of-backing-property-wrapper-initializer)
  - [Closures and unapplied function references](#closures-and-unapplied-function-references)
  - [Restrictions on property-wrapper parameters](#restrictions-on-property-wrapper-parameters)
+ [Source compatibility](#source-compatibility)
+ [Effect on ABI stability](#effect-on-abi-stability)
+ [Effect on API resilience](#effect-on-api-resilience)
+ [Alternatives considered](#alternatives-considered)
  - [Callee-side property wrapper application](#callee-side-property-wrapper-application)
+ [Future Directions](#future-directions)
+ [Revisions](#revisions)
  - [Changes from the first reviewed version](#changes-from-the-first-reviewed-version)
+ [Appendix](#appendix)
  - [Mutability of composed `wrappedValue` accessors](#mutability-of-composed-wrappedValue-accessors)


## Introduction

Property Wrappers were [introduced in Swift 5.1](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md), and have since become a popular mechanism for abstracting away common accessor patterns for properties. Currently, applying a property wrapper is solely permitted on local variables and type properties. However, with increasing adoption, demand for extending _where_ property wrappers can be applied has emerged. This proposal aims to extend property wrappers to function and closure parameters.


## Motivation

Property wrappers have undoubtably been very successful. Applying a property wrapper to a property is enabled by an incredibly lightweight and expressive syntax. For instance, frameworks such as [SwiftUI](https://developer.apple.com/documentation/swiftui/) and [Combine](https://developer.apple.com/documentation/combine) introduce property wrappers such as [`State`](https://developer.apple.com/documentation/swiftui/state), [`Binding`](https://developer.apple.com/documentation/swiftui/binding) and [`Published`](https://developer.apple.com/documentation/combine/published) to expose elaborate behavior through a succinct interface, helping craft expressive yet simple APIs. However, property wrappers are only applicable to local variables and type properties, shattering the illusion that they helped realize in the first place when working with parameters.

### Memberwise initialization

Currently, property-wrapper attributes on struct properties interact with function parameters through the struct's synthesized memberwise initializer. However, property-wrapper attributes are _not_ supported on function parameters. This leads to complicated and nuanced rules for which type, between the wrapped-value type and the backing property-wrapper type, the memberwise initializer accepts.

The compiler will choose the wrapped-value type to offer a convenience to the call-site when the property wrapper has an initializer of the form `init(wrappedValue:)` accepting the wrapped-value type, as seen here:

```swift
import SwiftUI


struct TextEditor {

  @State var document: Optional<URL>
  
}


func openEditor(with swiftFile: URL) -> TextEditor {
  TextEditor(document: swiftFile) 
  // The wrapped type is accepted here.
}
```

However, this can take flexibility away from the call-site if the property wrapper has other `init` overloads, because the call-site _cannot_ choose a different initializer. Further, if the property wrapper is explicitly initialized via `init()`, then the memberwise initializer will choose the backing-wrapper type, even if the wrapper supports `init(wrappedValue:)`. This results in unnecessary boilerplate at call-sites that _do_ want to use `init(wrappedValue:)`:

```swift
import SwiftUI


struct TextEditor {

  @State() var document: Optional<URL>
  
}


func openEditor(with swiftFile: URL) -> TextEditor {
  TextEditor(document: State(wrappedValue: swiftFile))
  // The wrapped type isn't accepted here; instead we have 
  // to use the backing property-wrapper type: 'State'.
}
```

Note also that the argument label does not change when the memberwise initializer uses the backing wrapper type instead of the wrapped-value type.

If the generated memberwise initializer always accepted the backing wrapper type while still allowing the call-site the convenience of automatically initializing the backing wrapper via a wrapped-value type, the mental model for property wrapper initialization would be greatly simplified. Moreover, this would provide more control over the backing-wrapper initialization at the call-site.

### Function parameters with property wrapper type

Using property-wrapper types for function parameters also results in boilerplate code, both in the function body and at the call-site:

```swift
@propertyWrapper
struct Lowercased {

  init(wrappedValue: String) { ... }


  var wrappedValue: String {
    get { ... }
    set { ... }
  }
  
}


func postUrl(urlString: Lowercased) {
  guard let url = URL(string: urlString.wrappedValue) else { return }
    //                                 ^~~~~~~~~~~~~
    // We must access 'wrappedValue' manually.
  ...
}


postUrl(urlString: Lowercased(wrappedValue: "mySite.xyz/myUnformattedUsErNAme"))
//                 ^~~~~~~~~~
// We must initialize `Lowercased` manually,
// instead of automatically initializing
// from its wrapped value type.
```

In the above example, the inability to apply property wrappers to function parameters prevents the programmer from removing unnecessary details from the code. The call-site of `postUrl` is forced to initialize an instance of `Lowercased` manually using `init(wrappedValue:)`, even though this initailization is automatic when using `@Lowercased` on a local variable or type property. Further, manually accessing `wrappedValue` in the function body can be distracting when trying to understand the implementation. These limitations are emphasized by the fact that property wrappers were originally sought out to eliminate such boilerplate.

### Closures accepting property-wrapper types

Consider the following SwiftUI code, which uses [`ForEach`](https://developer.apple.com/documentation/swiftui/foreach) over a collection:

```swift
struct MyView : View {

  // A simple Shopping Item that includes
  // a 'quantity' and a 'name' property.
  @State
  private var shoppingItems: [Item]

  var body: some View {
    ForEach(0 ..< shoppingItems.count) { index in
      TextField(shoppingItems[index].name, $shoppingItems[index].name)
    }
  }

}
```

Working with `shoppingItems` in the closure body is painful, because the code must manually index into the original wrapped property, rather than working with collection elements directly in the closure. The manual indexing would be alleviated if the closure accepted `Binding`s to collection elements:

```swift
struct MyView : View {

  // A simple Shopping Item that includes
  // a 'quantity' and a 'name' property.
  @State
  private var shoppingItems: [Item]

  var body: some View {
    ForEach($shoppingItems) { itemBinding in
      TextField(itemBinding.wrappedValue.name, itemBinding.name)
    }
  }

}
```

However, now we observe the same boilerplate code in the closure body because the property-wrapper syntax cannot be used with the closure parameter.

## Proposed solution

We propose to allow application of property wrappers on function and closure parameters.

Using property-wrapper parameters, the above `postUrl` example becomes:

```swift
func postUrl(@Lowercased urlString: String) {
  guard let url = URL(string: urlString) else { return }
  ...
}

postUrl(urlString: "mySite.xyz/myUnformattedUsErNAme")
```

In the above SwiftUI example, if collection elements could be accessed via `Binding`s in the `ForEach` closure, property-wrapper parameters could be used to enable property-wrapper syntax in the closure body:

```swift
struct MyView: View {

  @State
  private var shoppingItems: [Item]

  var body: some View {
    ForEach($shoppingItems) { $item in
      TextField(item.name, $item.name)
    }
  }

}
```

## Detailed design

Property wrappers are essentially sugar wrapping a given declaration with compiler-synthesized code. This proposal retains this principle. Annotating a parameter declaration with a property-wrapper attribute allows the call-site to pass a wrapped value or a projected value, and the compiler will automatically initialize the backing wrapper to pass to the function. The function author can also use the property-wrapper syntax for accessing the backing wrapper and the projected value in the body of the function.

### Function-body semantics

Attaching a property wrapper to a parameter makes that parameter a computed variable local to the function body, and changes the parameter type to the backing wrapper type. The type of the parameter is only observable in compiled code - [unapplied references to functions with property-wrapped parameters](#closures-and-unapplied-function-references) will not use the backing wrapper type.

The transformation of function with a property-wrapped parameter will be performed as such:

1. The argument label will remain unchanged. 
2. The parameter name will be prefixed with an underscore.
3. The type of the parameter will be the backing property-wrapper type.
4. A local computed property representing the `wrappedValue` of the innermost property wrapper will be synthesized with the same name as the original, unprefixed parameter name. If the innermost `wrappedValue` defines a setter, a setter will be synthesized for the local property if the mutability of the composed setter is `nonmutating`. The mutability computation is specified in the [appendix](#appendix).
5. If the outermost property wrapper defines a `projectedValue` property, a local computed property representing the outermost `projectedValue` will be synthesized and named per the original parameter name prefixed with a dollar sign (`$`). If the outermost `projectedValue` defines a setter, a setter for the local computed property will be synthesized if the `projectedValue` setter is `nonmutating`, or if the outermost wrapper is a reference type.

Consider the following function with a property-wrapped parameter using the `@Validated` property wrapper:

```swift
func insert(@Validated(.nonEmpty) text: String?) { ... }
```

The compiler will synthesize computed `text` and `$text` variables in the body of `insert`:

```swift
func insert(text _text: Validated<String?>) { 
  var text: String? {
    get { _text.wrappedValue }
  }

  var $text: Result<String, ValidationResult> {
    get { _text.projectedValue }
  }

  ...
}
```

### Call-site semantics

When passing an argument to a function with a property-wrapped parameter, the compiler will wrap the argument in a call to the appropriate initializer depending on the argument label. When using the original argument label (or no argument label), the compiler will wrap the argument in a call to `init(wrappedValue:)`. When using the argument label prefixed with `$` (or `$_` in the case of no argument label), the compiler will wrap the argument in a call to `init(projectedValue:)`. 

Consider the following property wrapper that implements both `init(wrappedValue:)` and `init(projectedValue:)`:

```swift
struct Projection<Value> { ... }

@propertyWrapper
public struct Wrapper<Value> {

  public init(wrappedValue: Value) { ... }

  public init(projectedValue: Projection<Value>) { ... }

  public var wrappedValue: Value

  public var projectedValue: Projection<Value> { ... }

}
```

A function with a `@Wrapped` parameter can be called with either a wrapped value or a projected value:

```swift
func useWrapper<Value>(@Wrapper arg: Value) { ... }

let projection: Projection<Int> = ...
useWrapper(arg: 10)
useWrapper($arg: projection)
```

The compiler will inject a call to the appropriate property-wrapper initializer into each call to `useWrapper` based on the argument label:

```swift
useWrapper(arg: Wrapper(wrappedValue: 10))
useWrapper(arg: Wrapper(projectedValue: projection))
```

Wrapped parameters with no argument label can still be passed a projection using the syntax `$_:`, as shown in the following example:

```swift
func useWrapper<Value>(@Wrapper _ arg: Value) { ... }

let projection: Projection<Int> = ...
useWrapper(10)
useWrapper(_: 10)
useWrapper($_: projection)
```

This transformation at the call-site only applies when calling the function directly using the declaration name. The semantics of closures and unapplied function references are specified [in a later section](#closures-and-unapplied-function-references).

#### Passing a projected value argument

Property wrappers must support initialization through a wrapped value to be used with function parameters. Property wrappers can opt into support for passing a projected value by implementing an initializer of the form `init(projectedValue:)`. This initializer must have a single parameter of the same type as the `projectedValue` property and have the same access level as the property-wrapper type itself. The initializer may have additional parameters as long as they have default arguments. Presence of `init(projectedValue:)` enables passing a projected value via the `$` calling syntax.

#### Arguments in the property-wrapper attribute

Arguments in the property-wrapper attribute as well as other default arguments to `init(wrappedValue:)` and `init(projectedValue:)` have the same semantics as default arguments. These arguments are injected into the initializer call at the call-site, and therefore are evaluated by the caller. The same restrictions applied to default arguments are also applied to property-wrapper attribute arguments.

#### Overload resolution of backing property-wrapper initializer

Since the property wrapper is initialized at the call-site, this means that the argument type can impact overload resolution of `init(wrappedValue:)` and `init(projectedValue:)`. For example, if a property wrapper defines overloads of `init(wrappedValue:)` with different generic constraints and that wrapper is used on a function parameter, e.g.:

```swift
@propertyWrapper
struct Wrapper<Value> {

  init(wrappedValue: Value) { ... }

  init(wrappedValue: Value) where Value : Collection { ... }
  
}

func generic<T>(@Wrapper arg: T) { ... }
```

Then, overload resolution will choose which `init(wrappedValue:)` to call based on the static type of the argument at the call-site:

```swift
generic(arg: 10) // calls the unconstrained init(wrappedValue:)

generic(arg: [1, 2, 3]) // calls the constrained init(wrappedValue:)
                        // because the argument conforms to Collection.
```

### Closures and unapplied function references

By default, closures and unapplied references to functions that accept property-wrapped parameters use the wrapped-value type in the parameter list, and the compiler will generate a thunk to initialize the backing wrapper and call the function.

Consider the following function using the `@Clamped` property wrapper:

```swift
func reportProgress(@Clamped(to: 0...100) percent: Int) { ... }
```

The type of `reportProgress` is `(Int) -> Void`. These semantics can be observed when working with an unapplied reference to `reportProgress`:

```swift
let fnRef: (Int) -> Void = reportProgress
fnRef(10)
```

The compiler will generate a thunk when referencing `reportProgress` to take in the wrapped-value type and initialize the backing property wrapper:

```swift
let fnRef: (Int) -> Void =  { reportProgress(percent: Clamped(wrappedValue: $0, to: 0...100) }
```

The type of a closure or unapplied function reference can be changed to instead take in the projected-value type using `$` in front of the parameter name in a closure or in front of the argument label in a function reference. Consider the following `UnsafeMutableReference` property wrapper that projects an `UnsafeMutablePointer` and implements `init(projectedValue:)`:

```swift
@propertyWrapper
struct UnsafeMutableReference<Value> {

  init(projectedValue: UnsafeMutablePointer<Value>) { ... }

}
```
The above property wrapper can be used for closure parameteres of type `UnsafeMutablePointer` using `$` to prefix the parameter name:

```swift
withUnsafeMutablePointer(to: &value) { @UnsafeMutableReference $value in
  ...
}
```

For closure parameters, the property-wrapper attribute is not necessary if the backing property wrapper and the projected value have the same type:


```swift
struct MyView: View {

  @State
  private var shoppingItems: [Item]

  var body: some View {
    ForEach($shoppingItems) { $item in
      TextField(item.name, $item.name)
    }
  }

}
```

### Restrictions on property-wrapper parameters

The composed mutability of the innermost `wrappedValue` getter must be `nonmutating`.

> **Rationale**: If the composed `wrappedValue` getter is `mutating`, then the local computed property for a property-wrapper parameter must mutate the backing wrapper, which is immutable.

Property-wrapper parameters cannot have an `@autoclosure` type.

> **Rationale**: `@autoclosure` is unnecessary for the wrapped value, because the wrapped-value argument at the call-site will always be wrapped in a call to `init(wrappedValue:)` or `init(projectedValue:)`, which can _already_ support `@autoclosure` arguments.

Property wrappers on function parameters must support `init(wrappedValue:)`.

> **Rationale**: This is an artificial limitation to prevent programmers from writing functions with an argument label that cannot be used to call or reference the function.

Non-instance methods cannot use property wrappers that require the enclosing `self` subscript.

> **Rationale**: Non-instance methods do _not_ have an enclosing `self` instance, which is required for the local computed property that represents `wrappedValue`.


## Source compatibility

This is an additive change with no impact on source compatibility.

## Effect on ABI stability

This is an additive change with no impact on the existing ABI.

## Effect on API resilience

This proposal introduces the need for property-wrapper custom attributes to become part of public API. This is because a property wrapper applied to a function parameter changes the type of that parameter in the ABI, and it changes the way that function callers are compiled to pass an argument of that type. Thus, adding or removing a property wrapper on a public function parameter is an ABI-breaking change (but not a source-breaking change). Like default arguments, arguments in wrapper attributes are emitted into clients and are not part of the ABI.

## Alternatives considered

### Callee-side property wrapper application

Instead of initializing the backing property wrapper using the argument at the call-site of a function that accepts a wrapped parameter, another approach is to initialize the backing property wrapper using the parameter in the function body. One benefit of this approach is that annotating a parameter with a property-wrapper attribute would not change the type of the function in the ABI, and therefore adding or removing a wrapper attribute would be a resilient change.

Under these semantics, using a property-wrapper parameter is effectively the same as using a local property wrapper that is initialized from a parameter. This implies that:

1. This feature cannot support passing a projected-value argument via `init(projectedValue:)`, unless there is an additional ABI entry point that acceps the projected-value type. This can only be achieved with either an exponential number of overloads, or an artificial restriction that all property-wrapper arguments must either be the wrapped-value type or the projected-value type.
2. The type of the argument provided at the call-site cannot affect the overload resolution of `init(wrappedValue:)`.
3. Arguments in the wrapper attribute and other default arguments to the property-wrapper initializers become resilient and are also evaluated in the callee rather than the caller.

One of the motivating use-cases for property-wrapper parameters is the ability to pass a projected value, which makes this approach unviable with out a significant type-checking performance impact or unintuitive restrictions. Further, making arguments in the wrapper attribute resilient is inconsistent with default arguments. Finally, caller-side property wrapper application has useful semantics. For example, for property wrappers that capture the file and line number to log a message or assert a precondition, it's much more useful to capture the location where the argument is provided rather than the location of the parameter declaration.

## Future directions

### Property-wrapper parameters in synthesized memberwise initializers

Synthesized memberwise initializers could use property-wrapper parameters for stored properties with attached property wrappers:

```swift
struct MyView {

  @State() var document: Optional<URL>

  // Synthesized memberwise init
  init(@State document: Optional<URL>) { ... }

}

func openEditor(with swiftFile: URL) -> TextEditor {
  TextEditor(document: swiftFile)
}
```

### Add support for `inout` wrapped parameters in functions

This proposal doesn't currently support marking property-wrapped function parameters `inout`. We deemed that this functionality would be better tackled by another proposal, due to its implementation complexity. Nonetheless, such a feature would be useful for mutating a `wrappedValue` argument when the wrapper has a `mutating` setter.

### Add wrapper types in the standard library

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

withUnsafePointer(to: ...) { (@UnsafePointer value) in
  print(value) // 0
  
  $value.withMemoryRebound(to: UInt64.self) {
    ... 
  }
}
```

As a result, unsafe code is not dominated by visually displeasing accesses to `pointee` members; rather, more natural and clear code is enabled.

## Revisions

### Changes from the first reviewed version

* Passing a projected value using the `$` calling syntax is supported via `init(projectedValue:)`.
* The type of the unapplied function reference uses the wrapped-value type by default. Referencing the function using the projected-value type is supported by writing `$` in front of the argument label, or `_` if there is no argument label.
* Closures with property-wrapper parameters have the same semantics as unapplied function references.
* Additional arguments in the wrapper attribute are supported, and these arguments have the same semantics as default function arguments.

## Appendix

#### Mutability of composed `wrappedValue` accessors

The algorithm is computing the mutability of the synthesized accessors for a wrapped parameter (or property) with _N_ attached property wrapper attributes. Attribute 1 is the outermost attribute, and attribute _N_ is the innermost. The accessor mutability is the same as the mutability of the _N_ th .wrappedValue access, e.g. _param.wrappedValue<sub>1</sub>.wrappedValue<sub>2</sub>. [...] .wrappedValue<sub>N</sub>

The mutability of the _N_ th access is defined as follows:

* If _N = 1_, the mutability of the access is the same as the mutability of the wrappedValue accessor in the 1st property wrapper.
Otherwise:
  * If the wrappedValue accessor in the _N_ th property wrapper is nonmutating, then the _N_ th access has the same mutability as the _N - 1_ th get access.
  * If the wrappedValue accessor in the _N_ th property wrapper is mutating, then the _N_ th access is mutating if the _N - 1_ th get or set access is mutating.

**Example**: Consider the following `Reference` property wrapper, which is composed with `Lowercased` and used on a closure parameter:

```swift
@propertyWrapper
struct Reference<Value> {
    
  var wrappedValue: Value {
    get 
    nonmutating set
  }
    
  var projectedValue: Reference<Value> {
    self
  }
  
}

let useReference = { (@Reference @Lowercased reference: String) in
  ...
}
```

In the above example, the closure `useReference` is equivalent to:

```swift
let useReference = { (_reference: Reference<Lowercased>) in
  var reference: String {
    get { 
      _reference.wrappedValue.wrappedValue
    }
    set { 
      _reference.wrappedValue.wrappedValue = newValue
    }
  }

  var $reference: Reference<Lowercased> {
    get { 
      _reference.projectedValue
    }
  }
    
  ...
}
```

Since both the getter and setter of `Reference.wrappedValue` are `nonmutating`, a setter can be synthesized for `var reference`, even though `Lowercased.wrappedValue` has a `mutating` setter. `Reference` also defines a `projectedValue` property, so a local computed property called `$reference` is synthesized in the closure, but it does _not_ have a setter, because `Reference.projectedValue` only defines a getter.
