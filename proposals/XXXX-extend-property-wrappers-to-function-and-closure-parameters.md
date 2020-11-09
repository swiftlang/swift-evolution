# Extend Property Wrappers to Function and Closure Parameters

* Proposal: [SE-NNNN](NNNN-extend-property-wrappers-to-function-and-closure-parameters.md)
* Authors: [Holly Borla](https://github.com/hborla), [Filip Sakel](https://github.com/filip-sakel)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [apple/swift#34272](https://github.com/apple/swift/pull/34272)


## Introduction

Property Wrappers were [introduced in Swift 5.1](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md), and have since become a popular feature abstracting away common accessor patterns for properties. Currently, applying a property wrapper is solely permitted at local and type context. However, with increasing adoption, demand for extending _where_ property wrappers can be applied has emerged. This proposal aims to extend property wrappers to function and closure parameters.


## Motivation

Property wrappers have undoubtably been very successful. Applying a property wrapper to a property is enabled by an incredibly lightweight and expressive syntax. Therefore, library authors can expose complex behavior through easily understandable property-wrapper types in an efficient manner. For instance, frameworks such as [SwiftUI](https://developer.apple.com/documentation/swiftui/) and [Combine](https://developer.apple.com/documentation/combine) introduce property wrappers such as [`State`](https://developer.apple.com/documentation/swiftui/state), [`Binding`](https://developer.apple.com/documentation/swiftui/binding) and [`Published`](https://developer.apple.com/documentation/combine/published) respectively, to expose elaborate behavior through a succinct interface, helping craft expressive yet simple APIs. However, property wrappers are only applicable to local variables and type properties, shattering the illusion that they helped realize in the first place when working with parameters.

### Memberwise initialization

Currently, property wrappers on stored struct properties already interact with parameters through the generated memberwise initializer for the struct. However, property wrapper attributes are not supported on parameters, which leads to really complicated and nuanced rules for which type the generated memberwise initializer should accept.

The compiler will choose the wrapped value type to offer a convenience to the call-site when the property wrapper supports initalization through the wrapped value type via `init(wrappedValue:)`:

```swift
import SwiftUI

struct TextEditor {
  @State var document: Optional<URL>
}

func openEditor(with swiftFile: URL) -> TextEditor {
  TextEditor(document: swiftFile)
}
```

However, this can take flexibility away from the call-site if the property wrapper has other `init` overloads, because the call-site can cannot choose a different initializer. Further, if the property wrapper is default initialized in the struct, then the memberwise initializer will choose the backing wrapper type, even if the wrapper supports `init(wrappedValue:)`. This creates unnecessary boilerplate at call-sites that do want to use `init(wrappedValue:)`:

```swift
import SwiftUI

struct TextEditor {
  @State() var document: Optional<URL>
}

func openEditor(with swiftFile: URL) -> TextEditor {
  TextEditor(document: State(wrappedValue: swiftFile))
}
```

If the generated memberwise initializer always accepted the backing wrapper type while still allowing the call-site the convenience of automatically initializing the backing wrapper via a wrapped value type, this would greatly simplify the mental model for property wrapper initialization. This would also provide more control over the backing wrapper initialization at the call-site, which is more consistent with initailization of non-wrapped properties.

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

In the above example, it is quite awkward and unintuitive that property wrappers cannot be applied to function parameters, and it prevents the programmer from removing unnecessary details from the code. The call-site of `postUrl` is forced to initialize an instance of `Lowercased` manually using `init(wrappedValue:)`, even though this initailization is automatic when using `@Lowercased` on a local variable or type property. Further, manually accessing `wrappedValue` in the function body can be distracting when trying to understand the implementation. These limitations in expressivity are emphasized by the fact that property wrappers were originally sought out to abstract away such patterns.

### Closures accepting property wrapper types

The same boilerplate code in function bodies also applies to closures accepting property-wrapper types.
 In fact, establishing custom behavior on closure parameters is really powerful. For example, in SwiftUI, [`ForEach`](https://developer.apple.com/documentation/swiftui/foreach) could leverage this feature to expose elements from its data source to its `content` closure directly. This would enable users to more easily work with the data source itself inside the closure instead of accessing the original property, which is particularly painful when working with collections, as shown in this example:

```swift
struct MyView : View {

  // A simple Shopping Item that includes
  // a 'quantity' and a 'name' property.
  @State 
  private var shoppingItems: [Item]

  var body: some View {
    ForEach(0 ..< shoppingItems.count) { index in
      TextField("Enter the item's name...", $shoppingItems[index].name)
    }
  }
  
}
```

## Proposed solution

We propose to extend the contexts where application of property-wrapper types is permitted. Namely, application of such types will be allowed on function and closure parameters.

Using property-wrapper parameters, the above `postUrl` example becomes:

```swift
func postUrl(@Lowercased urlString: String) {
  guard let url = URL(string: urlString) else { return }
  ...
}

postUrl(urlString: "mySite.xyz/myUnformattedUsErNAme")
```

If `Binding` conforms to `RandomAccessCollection`, property-wrapper parameters can be used with `ForEach` to access collection elements directly in the `content` closure and enable property wrapper syntax in the closure body:

```swift
struct MyView: View {

  @State 
  private var shoppingItems: [Item]

  var body: some View {
    ForEach($shoppingItems) { (@Binding shoppingItem) in
      TextField("Enter the item's name...", $shoppingItem.name)
    }
  }
  
}
```


## Detailed design

Property wrappers are essentially sugar wrapping a given property with compiler synthesized code. This proposal retains this principle, employing the following rules and transformation.

### Property-wrapper parameter attribute rules

A function parameter marked with property-wrapper custom attributes must conform to the following rules:

1. Property-wrapper function parameters must support initialization through their `wrappedValue` type. Therefore, all property-wrapper types must provide an `init(wrappedValue:)` that allows the caller to only pass the `wrappedValue` argument.
2. Each `wrappedValue` getter must be `nonmutating`.
3. Default arguments must be expressed in terms the `wrappedValue` type of the innermost property wrapper.

Closure parameters marked with a set of property-wrapper custom attributes must conform to the following rules:

1. Each `wrappedValue` getter must be `nonmutating`.
2. Any contextual type for the parameter must match the outermost backing-wrapper type.

### Function body transformation

The transformation of function with a property-wrapper parameter will be performed as such:

1. For regular functions, the argument label will remain unchanged. 
2. The parameter name will be prefixed with an underscore.
3. The type of the parameter will be the backing property-wrapper type.
4. A local computed property representing the `wrappedValue` of the innermost property wrapper will be synthesized by the compiler and named per the original, unprefixed parameter name. If the innermost `wrappedValue` defines a setter,  a setter will be synthesized for the local property if the `wrappedValue` setter is `nonmutating`, or if the wrapper is a reference type.
5. If the outermost property wrapper defines a `projectedValue` property, a local computed property representing the outermost `projectedValue` will be synthesized and named per the original parameter name prefixed with a dollar sign (`$`). If the outermost `projectedValue` defines a setter, a setter for the local computed property will be synthesized if the `projectedValue` setter is `nonmutating`, or if the wrapper is a reference type.

### Call site transformation

When passing an argument to a function with a property-wrapper parameter using the original argument label with no prefix, the compiler will wrap the argument in a call to `init(wrappedValue:)`. This transformation does not apply to closures, because closures are not called with argument labels.

Since the property wrapper is initialized at the call site, this means that the argument type can impact overload resolution of `init(wrappedValue:)`. For example, if a property wrapper defines overloads of `init(wrappedValue:)` with different generic constraints and that wrapper is used on a function parameter, e.g.:

```swift
@propertyWrapper
struct Wrapper<Value> {
  init(wrappedValue: Value) { ... }

  init(wrappedValue: Value) where Value: Collection { ... }
}

func generic<T>(@Wrapper arg: T) { ... }
```

Then overload resolution will choose which `init(wrappedValue:)` to call based on the static type of the argument at the call site:

```swift
generic(arg: 10) // calls the unconstrained init(wrappedValue:)

generic(arg: [1, 2, 3]) // calls the constrained init(wrappedValue:)
                        // because the argument conforms to Collection.
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

A setter for the local `urlString` computed property is not synthesized because the setter of `Lowercased.wrappedValue` is `mutating`.

Consider the following `Reference` property wrapper, which is used on a closure parameter:

```swift
@propertyWrapper
struct Reference<Value> {

  init(
    getter: @escaping () -> Value,
    setter: @escaping (Value) -> Void
  ) { ... }
    
    
  var wrappedValue: Value {
    get 
    nonmutating set
  }
    
  var projectedValue: Self {
    self
  }
  
}

typealias A = (Reference<Int>) -> Void

let a: A = { (@Reference reference) in
  ...
}
```

In the above example, the closure `a` is equivalent to:

```swift
let a: A = { (_reference: Reference<Int>) in

  var reference: Int {
    get { 
      _reference.wrappedValue
    }
    set { 
      _reference.wrappedValue = newValue
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

A setter is synthesized for the local `reference` computed property because the setter of `Reference.wrappedValue` is `nonmutating`. Since `Reference` defines a `projectedValue` property, a local computed property called `$reference` is synthesized in the closure, but it does not have a setter because `Reference.projectedValue` only defines a getter.

### Restrictions on property-wrapper parameters

Property-wrapper parameters cannot have an `@autoclosure` type.

> **Rationale**: `@autoclosure` is unnecessary for the wrapped value, because the wrapped-value argument at the call-site will always be wrapped in a call to `init(wrappedValue:)`, which can already support `@autoclosure` arguments.

Property-wrapper parameters cannot have additional arguments in the wrapper attribute.

> **Rationale**: Arguments on the wrapper attribute are expected to never be changed by the caller. However, it is not possible to enforce this today, so property-wrapper parameters cannot support additional arguments in the attribute until there is a mechanism for for per-declaration shared state for property wrappers.

Non-instance methods cannot use property wrappers that require the enclosing self subscript.

> **Rationale**: Non-instance methods do not have an enclosing `self` instance, which is required for the local computed property that represents `wrappedValue`.


## Source compatibility

This is an additive change with no impact on source compatibility.

## Effect on ABI stability

This is an additive change with no impact on the existing ABI.

## Effect on API resilience

This proposal introduces the need for property-wrapper custom-attributes to become part of public API. Therefore, a property wrapper applied to a function parameter changes the type of that parameter in the ABI, and it changes the way that function callers are compiled to pass an argument of that type. Thus, adding or removing a property wrapper on a public function-parameter is an ABI-breaking change.

## Alternatives considered

### Callee-side property wrapper application

Instead of initializing the backing property-wrapper using the argument at the call-site of a function that accepts a wrapped parameter, another approach is to initialize the backing property-wrapper using the parameter in the function body. One benefit of this approach is that annotating a parameter with a property-wrapper attribute would not change the type of the function, and therefore adding or removing a wrapper attribute would be a resilient change.

Under these semantics, using a property-wrapper parameter is effectively the same as using a local property-wrapper that is initialized from a parameter. This implies that:

1. A property-wrapper parameter cannot be used to opt into property-wrapper syntax in the body of a closure that has a parameter with a property-wrapper type.
2. The type of the argument provided at the call-site cannot affect the overload resolution of `init(wrappedValue:)`.
3. This feature cannot be extended to allow the call-site to initialize the backing wrapper using a mechanism other than `init(wrappedValue:)`, which is later discussed as a future direction. This further implies that property-wrapper parameters can only be used with property wrappers that support `init(wrappedValue:)`.

One of the main use cases for property-wrapper parameters is opting into property-wrapper syntax in the body of a closure, which makes this approach unviable.

### Property-wrapper attributes as type attributes

One approach for marking closure parameters as property wrappers is to allow property-wrapper custom-attributes to be applied to types, such as:

```swift
func useReference(
  _ closure: (@Reference Int) -> Void
) { ... }


useReference { reference in
  ...
}
```

This approach enables inference of the wrapper attribute on the closure parameter from context. However, this breaks the property-wrapper declaration-model, and would force callers to use the property-wrapper syntax. This approach, also, raises questions about anonymous closure-parameters that have an inferred property-wrapper custom-attribute. That is, if an anonymous closure parameter `$0` has the `wrappedValue` type, accessing the backing wrapper and projected value would naturally use `_$0` and `$$0`, which are _far_ from readable. Furthermore, suppose `$0` is bound to the backing wrapper-type; this would mean that naming the parameter would cause the value to change types, which would be very unexpected from a user standpoint. All in all, the property-wrapper syntax is purely an implementation detail for the closure body, which does _not_ belong to the API signature.


## Future directions

### Support property-wrapper initialization from a projected value

Today, a property wrapper can be initialized from an instance of its `wrappedValue` type if the wrapper provides a suitable `init(wrappedValue:)`. The same initialization strategy is used in this proposal for property wrapper parameters to allow users to pass a wrapped value as a property wrapper argument. We could extend this model to support initializing a property wrapper from an instance of its `projectedValue` type by allowing property wrappers to define an `init(projectedValue:)` that follows the same rules as `init(wrappedValue:)`. This could allow users to additionally pass a projected value as a property wrapper argument, like so:

```swift
@propertyWrapper
struct Clamped<Value : Comparable> {

  ...
  

  init(projectedValue: Self) { ... }
  
}

func distanceFromUpperBound(
  @Clamped clamped: Int
) { ... }


distanceFromUpperBound(
  $clamped: Clamped(to: 0 ... 100, wrappedValue: 30)
) // returns: 70
```


### Add support for `inout` wrapped parameters in functions

This proposal doesn't currently support marking function parameters to which wrapper types have been applied `inout`. We deemed that this functionality would be better tackled by another proposal due to its implementation complexity. However, such a feature would be really useful for wrapper types with value semantics and it would simplify the mental model. Furthermore, it could alleviate some confusion for users that don't understand the difference between a setter with value semantics and one with reference semantics.

### Add wrapper types in the standard library

Adding wrapper types to the standard library has been discussed for types [such as `@Atomic`](https://forums.swift.org/t/atomic-property-wrapper-for-standard-library/30468) and [`@Weak`](https://forums.swift.org/t/should-weak-be-a-type/34032), which would facilitate certain APIs. Another interesting standard library wrapper type could be `@UnsafePointer`, which would be quite useful, as access of the `pointee` property is quite common:

```swift
let myPointer: UnsafePointer<UInt8> = ...

myPointer.pointee 
//        ^~~~~~~ 
// This is the accessor pattern property 
// wrappers were devised to tackle.
```

Instead of writing the above, in the future one might be able to write this:

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

What's more, a `@Lazy` type could be added so as to alleviate the need for custom behavior built into the compiler. Instead, `@Lazy` would act as more comprehensible, easy to maintain type, that would also allow for a more streamlined way of resetting its storage:

```
struct Size {
    
    private mutating func _reset() {
        $__lazy_storage_$_area = nil
    }
    
    var width: Double {
        didSet {
            _reset()
        }
    }
  
    var height: Double {
        didSet {
            _reset()
        }
    }
  
  
    // Mutation of 'width' and 'height' are rare;
    // therefore, it is sensible that the commonly
    // accessed 'area' property be lazy.
    lazy var area = width * height
  
}
```

The above code shows how one would currently implement a `Size` type with such semantics. With `@Lazy`, though, it would be simplified to:

```
struct Size {
    
  @Lazy {
    width * height
  }
  var area: Double


  var width: Double {
    didSet {
      $area.reset()
    }
  }

  var height: Double {
    didSet {
      $area.reset()
    }
  }
  
}
```

Here, resetting of `area`'s underlying storage is very clear and easily accessible through `@Lazy`'s projected value.  
