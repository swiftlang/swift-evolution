# Extend Property Wrappers to Function and Closure Parameters

* Proposal: [SE-0293](0293-extend-property-wrappers-to-function-and-closure-parameters.md)
* Authors: [Holly Borla](https://github.com/hborla), [Filip Sakel](https://github.com/filip-sakel)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Active Review (December 1, 2020 ... December 13, 2020)**
* Implementation: [apple/swift#34272](https://github.com/apple/swift/pull/34272)

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
    ForEach($shoppingItems) { (@Binding item) in
      TextField(item.name, $item.name)
    }
  }

}
```

## Detailed design

Property wrappers are essentially sugar wrapping a given property with compiler-synthesized code. This proposal retains this principle, employing the following transformation.

### Function body transformation

The transformation of function with a property-wrapper parameter will be performed as such:

1. For regular functions, the argument label will remain unchanged. 
2. The parameter name will be prefixed with an underscore.
3. The type of the parameter will be the backing property-wrapper type.
4. A local computed property representing the `wrappedValue` of the innermost property wrapper will be synthesized with the same name as the original, unprefixed parameter name. If the innermost `wrappedValue` defines a setter, a setter will be synthesized for the local property if the mutability of the composed setter is `nonmutating`. The mutability computation is specified below.
5. If the outermost property wrapper defines a `projectedValue` property, a local computed property representing the outermost `projectedValue` will be synthesized and named per the original parameter name prefixed with a dollar sign (`$`). If the outermost `projectedValue` defines a setter, a setter for the local computed property will be synthesized if the `projectedValue` setter is `nonmutating`, or if the outermost wrapper is a reference type.

#### Mutability of composed `wrappedValue` accessors

The computation for mutability of a wrapped parameter's composed `wrappedValue` accessors will be the same as it is today for wrapped properties. The computation starts with the mutability of the outermost wrapper's `wrappedValue` accessor, and then iterates over the chain of composed property wrappers, "composing" the mutability of each `wrappedValue` accessor along the way using the following rules, which are the same for getters and setters:

* If the next `wrappedValue` accessor is `nonmutating`, then the mutability of the composed accessor is the same as the previous composed getter. If the wrapper is a reference type, the accessor is considered `nonmutating`.
* If the next `wrappedValue` accessor is `mutating`, then the composed accessor is `mutating` if the previous composed getter _or_ setter is `mutating`, since both are needed to perform a writeback cycle.

If any of the property wrappers do not define a `wrappedValue` setter, then the wrapped property/parameter does not have a setter.

### Call-site transformation

When passing an argument to a function with a property-wrapper parameter using the original argument label with no prefix, the compiler will wrap the argument in a call to `init(wrappedValue:)`. This transformation does _not_ apply to closures, because closures are not called with argument labels.

#### Overload resolution of `init(wrappedValue)`

Since the property wrapper is initialized at the call-site, this means that the argument type can impact overload resolution of `init(wrappedValue:)`. For example, if a property wrapper defines overloads of `init(wrappedValue:)` with different generic constraints and that wrapper is used on a function parameter, e.g.:

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

#### Unapplied references to functions with property-wrapper parameters

Functions that accept property-wrapper parameters are transformed to accept the backing wrapper type. Consider the `postUrl` function from earlier:

```swift
func postUrl(@Lowercased urlString: String) { ... }
```

The type of `postUrl` is `(Lowercased) -> Void`. These semantics can be observed when working with an unapplied reference to `postUrl`:

```swift
let fn: (Lowercased) -> Void = postUrl
fn(Lowercased(wrappedValue: "mySite.org/termsOfService"))
```

### Transformation examples:

Consider the `postUrl` example from earlier:

```swift
@propertyWrapper
struct Lowercased {

  init(wrappedValue: String) { ... }
    
    
  var wrappedValue: String {
    get { ... }
    set { ... }
  }
  
}

func postUrl(@Lowercased urlString: String) { ... }


postUrl(urlString: "mySite.xyz/myUnformattedUsErNAme")
```

In the above code, the `postUrl(urlString:)` function and its caller are equivalent to:

```swift
func postUrl(urlString _urlString: Lowercased) {
  var urlString: String {
    get { _ urlString.wrappedValue }
  }

  ...
}


postUrl(urlString: Lowercased(wrappedValue: "mySite.xyz/myUnformattedUsErNAme"))
```

A setter for the local computed property `urlString` is _not_ synthesized because the setter of `Lowercased.wrappedValue` is `mutating`.

Now, consider the following `Reference` property wrapper, which is composed with `Lowercased` and used on a closure parameter:

```swift
@propertyWrapper
struct Reference<Value> {
    
  var wrappedValue: Value {
    get 
    nonmutating set
  }
    
  var projectedValue: Self {
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

  var $reference: Int {
    get { 
      _reference.projectedValue
    }
  }
    
  ...
}
```

Since both the getter and setter of `Reference.wrappedValue` are `nonmutating`, a setter can be synthesized for `var reference`, even though `Lowercased.wrappedValue` has a `mutating` setter. `Reference` also defines a `projectedValue` property, so a local computed property called `$reference` is synthesized in the closure, but it does _not_ have a setter, because `Reference.projectedValue` only defines a getter.

### Restrictions on property-wrapper parameters

The composed mutability of the innermost `wrappedValue` getter must be `nonmutating`.

> **Rationale**: If the composed `wrappedValue` getter is `mutating`, then the local computed property for a property-wrapper parameter must mutate the backing wrapper, which is immutable.

Property-wrapper parameters cannot have an `@autoclosure` type.

> **Rationale**: `@autoclosure` is unnecessary for the wrapped value, because the wrapped-value argument at the call-site will always be wrapped in a call to `init(wrappedValue:)`, which can _already_ support `@autoclosure` arguments.

Property wrappers on function parameters must support `init(wrappedValue:)`.

> **Rationale**: This is an artificial limitation to prevent programmers from writing functions with an argument label that cannot be used to call the function.

Property-wrapper parameters cannot have additional arguments in the wrapper attribute.

> **Rationale**: Arguments on the wrapper attribute are expected to never be changed by the caller. However, it is not possible to enforce this today; thus, property-wrapper parameters cannot support additional arguments in the attribute until there is a mechanism for per-declaration shared state for property wrappers.

Non-instance methods cannot use property wrappers that require the enclosing `self` subscript.

> **Rationale**: Non-instance methods do _not_ have an enclosing `self` instance, which is required for the local computed property that represents `wrappedValue`.


## Source compatibility

This is an additive change with no impact on source compatibility.

## Effect on ABI stability

This is an additive change with no impact on the existing ABI.

## Effect on API resilience

This proposal introduces the need for property-wrapper custom attributes to become part of public API. This is because a property wrapper applied to a function parameter changes the type of that parameter in the ABI, and it changes the way that function callers are compiled to pass an argument of that type. Thus, adding or removing a property wrapper on a public function parameter is an ABI-breaking change.

## Alternatives considered

### Callee-side property wrapper application

Instead of initializing the backing property wrapper using the argument at the call-site of a function that accepts a wrapped parameter, another approach is to initialize the backing property wrapper using the parameter in the function body. One benefit of this approach is that annotating a parameter with a property-wrapper attribute would not change the type of the function, and therefore adding or removing a wrapper attribute would be a resilient change.

Under these semantics, using a property-wrapper parameter is effectively the same as using a local property wrapper that is initialized from a parameter. This implies that:

1. A property-wrapper parameter _cannot_ be used to opt into property-wrapper syntax in the body of a closure that has a parameter with a property-wrapper type.
2. The type of the argument provided at the call-site cannot affect the overload resolution of `init(wrappedValue:)`.
3. This feature cannot be extended to allow the call-site to initialize the backing wrapper using a mechanism other than `init(wrappedValue:)`, which is later discussed as a future direction. This further implies that property-wrapper parameters can _only_ be used with property wrappers that support `init(wrappedValue:)`.

One of the main use-cases for property-wrapper parameters is opting into property-wrapper syntax in the body of a closure, which makes this approach unviable.

## Future directions

### Additional calling syntax using `$`

In this proposal, a property-wrapper argument is wrapped in a call to `init(wrappedValue:)` when the call-site uses the original, unprefixed argument label. We could extend this model to support a different initialization mechanism for the backing wrapper, or to pass the backing wrapper directly, by using the original argument label prefixed with `$`, e.g.:

```swift
func postUrl(@Lowercased urlString: String) { ... }

postUrl($urlString: Lowercased(...))
```

### Property-wrapper attribute inference for closure parameters using `$`

Many closures have a contextual type, which means the backing property-wrapper type can be inferred from context. So, spelling out the backing property-wrapper type in the custom attribute is repeating unnecessary type information. Instead, we could allow the `$` syntax on a closure parameter to infer the wrapper attribute:

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

This syntax could also potentially be used on parameter declarations that want to use property wrappers that do not support `init(wrappedValue:)`. This would allow such property wrappers to be used on function parameters without declaring the function with an argument label that cannot be used to call the function:

```swift
func createItemRowView($item: Binding<Item>) -> some View {
  TextField(item.name, $item.name)
}

createItemRowView($item: binding)
```

It’s important to note, however, that the above syntax has quite a few shortcomings. Namely, one notable drawback is that this syntax is reminiscent of property wrappers' projected value and, thus, may be confusing. Furthermore, auto-complete could be a better solution here, as it would aid the user in writing the property-wrapper attribute, while still retaining expressiveness. Nevertheless, this idea could be expanded upon in the future.

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

This is left as a future direction because it is a source breaking change.

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
