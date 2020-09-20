# Extend Property Wrappers to Function and Closure Parameters

* Proposal: [SE-NNNN](NNNN-extend-property-wrappers-to-function-and-closure-parameters.md)
* Authors: [Holly Borla](https://github.com/hborla), [Filip Sakel](https://github.com/filip-sakel)
* Review Manager: TBD
* Status: **Awaiting implementation**


## Introduction

Property Wrappers were [introduced in Swift 5.1](https://github.com/apple/swift-evolution/blob/master/proposals/0258-property-wrappers.md), and have since become a popular feature abstracting away common accessor patterns for properties. Currently, applying a property wrapper is solely permitted on properties inside of a type context. However, with increasing adoption demand for extending _where_ property wrappers can be applied has emerged.


## Motivation

Property wrappers have undoubtably been very successful. For one, applying a property wrapper to a property is enabled by an incredibly lightweight and expressive syntax. Therefore, library authors can expose complex behavior through easily understandable property-wrapper types in an efficient manner. For instance, frameworks such as [SwiftUI](https://developer.apple.com/documentation/swiftui/) and [Combine](https://developer.apple.com/documentation/combine) introduce property wrappers such as [`State`](https://developer.apple.com/documentation/swiftui/state), [`Binding`](https://developer.apple.com/documentation/swiftui/binding) and [`Published`](https://developer.apple.com/documentation/combine/published) respectively to expose elaborate behavior through a succint interface, helping craft majestic APIs. However, property wrappers are only applicable to type properties, shattering the illusion that they helped realize in the first place:

```swift
@propertyWrapper
struct Clamped<Value: Comparable> {
  init(
    wrappedValue: Value,
    to range: Range<Value>
  ) { ... }
  
  var wrappedValue: Value { 
    get { ... }
    set { ... }
  }
}

struct Percentage {
  @Clamped(to: 0 ... 100)
  var percent = 100
     
  func increment() {
    percent += 1
    // Great!
  }
}

func increment(percent: Clamped<Int>) {
  percent.wrappedValue = ...
  //   ^~~~~~~~~~~~ 
  // Unfortunately, we can't
  // use `@Clamped` here.
}
```

As seen in the above example, it quite akward and unintuitive that property wrappers cannot be applied to function parameters. This is only emphasized by the fact that property wrappers originally sought out to abstract away such accessor patterns.  As a result, elegant APIs are undermined by this limitation. Not only, is this limiting users by forcing them to rigidly follow API guidelines, which may not cover a specific use case, but it also limits API authors in what they can create. That is, API authors can't use property-wrapper types in closure parameters nor can code be seperated into functions that accept property wrapper syntax:

```swift

extension Percentage {
  func modify(
    inSeconds seconds: Int,
    block: @escaping (Clamped<Int>) -> Void
  ) { ... }
}

let myPercentage = Percentage(percent: 50)

myPercentage
  .modify(inSeconds: 3) { percent in
    percent.wrappedValue = 100
    //    ^~~~~~~~~~~~ 
    // Again, we have to 
    // access count through
    // `wrappedValue`.
  }
```

In fact, establishing custom behavior on closure parameters is really powerful. For example, if such a feature were supported, it could be used in conjunction with [Function Builders](https://github.com/apple/swift-evolution/blob/master/proposals/0289-function-builders.md) to expose data managed by a 'component' type. For instance, in SwiftUI [`ForEach`](https://developer.apple.com/documentation/swiftui/foreach) could exploit this feature to expose the mutable state of its data source to its 'content' closure. Thus, instead of manually mutating the data source, as is done here:

```swift
struct MyView: View {
  // A simple Shopping Item that includes
  // a 'quantity' and a 'name' property.
  @State 
  private var shoppingItems: [Item]

  var body: some View {
    ForEach(0 ..< shoppingItems.count) { index in
  
      Text(shoppingItems[index].name)
        .onTapGesture {
          // We increase the item's quantity 
          // when the user taps the item. 
          // Unfortunately, to mutate the item
          // we have to manually index our
          // data source.
          shoppingItems[index].quanity += 1
        }
      
    }
  }
}
```

with an appropriate initializer we would be able to simplify the above code, therefore reducing boilerplate:

```swift
struct MyView: View {
  @State 
  private var shoppingItems: [Item]

  var body: some View {
    ForEach($shoppingItems) { @Binding shoppingItem in
    
      Text(shoppingItem.name)
        .onTapGesture {
          shoppingItem.quanity += 1
        }
      
    }
  }
}
```


## Proposed solution

We propose to extend the contexts were application of property-wrapper types is allowed. Namely, application of such types will be allowed on function and closure parameters:

```swift
@propertyWrapper
struct Clamped<Value: Comparable> {
  ...
    
  var projectedValue: Self {
    self
  }
}

func increment(
  @Clamped(to: 0 ... 100) percent: Int = 100
) { ... }

myPercentage
  .modify(inSeconds: 3) { @Clamped percent in
    percent = 100 
  }
```


## Detailed design

Property wrappers are essentially sugar wrapping a given property with compiler synthesized code. This proposal retains this principle employing the following rules for transformation.

### Rules for Function Parameters

Function parameters marked with a property wrapper type must conform to a set of rules:

1. For a default value to be included, the wrapper type must define an initializer with a first parameter labeled "wrappedValue".
2. If any of the transformed functions share their signature with another function, the compiler will consider one of the two a redeclaration of the other.

The transformation that will take place is as follows:

1. The parameter name will be prefixed with an underscore.
2. A synthesized computed property representing  `wrappedValue` will be created and named per the original (non-prefixed) parameter name. The accessors will mirror the `wrappedValue`'s ones, except for mutating ones.
3. A synthesized computed property representing  `projectedValue` will be created and named per the original parameter name prefixed with a dollar sign (`$`). The accessors will mirror the `projectedValue`'s ones, except for the mutating ones.
4. If a parameter's wrapper-type defines an initializer with a first parameter labeled "wrappedValue", then the parameter's label will be prefixed with an underscore and the parameter will be bound to the wrapper type.
5. If 4 does not apply, then the parameter's label is retained as is and the parameter is bound to the type of `wrappedValue`.

#### Transformation Examples: 

1. Reference Semantics Wrapper
```swift
@propertyWrapper
struct Reference<Value> {
  init(getter: () -> Value, setter: (Value) -> Void) 
    
  var wrappedValue: Value {
    get 
    nonmutating set
  }
    
  var projectedValue: Self {
    self
  }
}

func a(@Reference foo: Int) { ... }
```

    Becomes:

```swift
func a(foo _foo: Reference<Int>) {
  var foo: Int {
    get { 
      _foo.wrappedValue 
    }
    set { 
      _foo.wrappedValue = newValue
    }
  }
    
  var $foo: Int {
    get { 
      _foo.projectedValue 
    }
  }
    
  ...
}
```

2. Value Semantics Wrapper
```swift
@propertyWrapper
struct Wrapper<Value> {
  init(wrappedValue: Value) 
    
  var wrappedValue: Value {
    get 
    set
  }
}

func b(@Wrapper foo: Int = 0) { ... }

b(foo: 5)
```

    Becomes:

```swift
func b(_foo: Wrapper<Int> = Wrapper(wrappedValue: 0) {
  var foo: Int { 
    _foo.wrappedValue
  }
  // Notice that there's no setter,
  // since `wrappedValue` is mutating.
}

b(_foo: Wrapper(wrappedValue: 5))
```


### Rules for Closure Parameters

Applying wrapper types to closure parameters in the declaration is not allowed. Instead when the compiler sees a closure that takes a wrapper type it will autocomplete with the wrapper type applied. Thus, the application of a wrapper type will be up to the user of the closure. As for the transformation, these are the rules:

1. The parameter name will be prefixed with an underscore.
2. A synthesized computed property representing  `wrappedValue` will be created and named per the original (non-prefixed) parameter name. The accessors will mirror the `wrappedValue`'s ones - except for a mutating setter which requires that the parameter be marked `inout`.
3. A synthesized computed property representing  `projectedValue` will be created and named per the original parameter name prefixed with a dollar sign (`$`). The accessors will mirror the `projectedValue`'s ones - except for a mutating setter which requires that the parameter be marked `inout`.

#### Transformation Examples: 

1. Reference Semantics Wrapper
```swift
@propertyWrapper
struct Reference<Value> {
  init(getter: () -> Value, setter: (Value) -> Void) 
    
  var wrappedValue: Value {
    get 
    nonmutating set
  }
    
  var projectedValue: Self {
    self
  }
}

typealias A = (Reference<Int>) -> Void

let a: A = { @Reference foo in
  ...
}
```

    Becomes:

```swift
let a: A = { _foo in
  var foo: Int {
    get { 
      _foo.wrappedValue 
    }
    set { 
      _foo.wrappedValue = newValue
    }
  }

  var $foo: Int {
    get { 
      _foo.projectedValue 
    }
  }
    
  ...
}
```

2. Value Semantics Wrapper

```swift
@propertyWrapper
struct Wrapper<Value> {
  init(wrappedValue: Value) 
    
  var wrappedValue: Value {
    get 
    set
  }
}

typealias B = (inout Wrapper<Int>) -> Void

let b: B = { @Wrapper foo in
  ...
}
```

    Becomes:

```swift
let b: B = { _foo in
  var foo: Int {
    get { 
      _foo.wrappedValue 
    }
    set { 
      _foo.wrappedValue = newValue
    }
    // Since the paramter is marked `inout`
    // we are allowed to have a mutating setter.
  }
  
  ...
}
```

3. Value Semantics Wrapper with Special Initializer

```swift
@propertyWrapper
class WrapperObject<Value> {
  init(wrappedValue: Value) 
    
  var wrappedValue: Value {
    get 
    set 
    // Not actually mutating
    // because `WrapperObject` is
    // a class.
  }
}

typealias C = (WrapperObject<Int>) -> Void

let c: C = { @WrapperObject foo in
  ...
}
```

    Becomes:

```swift
let c: C = { _foo in
  var foo: Int {
    get { 
      _foo.wrappedValue 
    }
    set { 
      _foo.wrappedValue = newValue
    }
    // Since `WrapperObject` has reference
    // semantics we can include a setter.
  }

  ...
}
```


## Source compatibility

This is an additive change with _no_ impact on **source compatibility**.


## Effect on ABI stability

This is an additive change with _no_ impact on **ABI stability**.


## Effect on API resilience

This is an additive change with _no_ impact on **API resilience**.


## Alternatives Considered

### Infer Property Wrappers in Closure Parameters 

TBD


### Support `@autoclosure` and `@escaping` in Function Parameters

TBD


## Future Directions

### Support Property Wrapper Initialization from a Projected Value

Today, a property wrapper can be initialized from an instance of its `wrappedValue` type if the wrapper provides a suitable `init(wrappedValue:)`. The same initialization strategy is used in this proposal for property wrapper parameters to allow users to pass a wrapped value as a property wrapper argument. We could extend this model to support initializing a property wrapper from an instance of its `projectedValue` type by allowing property wrappers to define an `init(projectedValue:)` that follows the same rules as `init(wrappedValue:)`. This could allow users to additionally pass a projected value as a property wrapper argument, like so:

```swift
@propertyWrapper
struct Clamped<Value: Comparable> {
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


### Add Support for `inout` Wrapped Parameters is Functions

This proposal doesn't currently support marking function parameters to which wrapper types have been applied `inout`. We deemed that this functionality would be better tackled by another proposal due to its implementation complexity. However, such a feature would be really useful for wrapper types with value semantics and it would simplify the mental model. Furthermore, it could alleviate some confusion for users that don't understand the difference between a setter with value semantics and one with reference semantics.


### Accessing Enclosing Self from Wrapper Types

There's currently no public feature that allows a wrapper to access its enclosing `Self` type:

```
@propertyWrapper
struct Mirror<
  EnclosingSelf, 
  Value, 
  Path: KeyPath<EnclosingSelf, Value>
> { 
  let keyPath: Path 

  init(of keyPath: Path) { ... }
}

struct Point {
  private var _vector: SIMD2<Double>
  
  init(x: Double, y: Double) {
    self._vector = SIMD2(x: x, y: y)
  }
  
  @Mirror(of: \._vector.x)
  var x
  
  @Mirror(of: \._vector.y)
  var y
}
// ❌ In the above use, we'd access the enclosing
// type's '_vector' property through the provided
// keyPath. However, today that's invalid.
```

Furthermore, extending this feature's availability to function and closure parameters be really powerful:

```
func valueAndIdPair<Value>(
  @Mirror of property: Value
) -> (value: Value, id: Int) {
  (value: property, id: $property.keyPath.hashValue)
}
```

It's important to note that allowing use of such a feature in function parameters would entail some limitations. For example, a parameter makred with a wrapper type referencing enclosing `Self` would not be initializable with the sugared function call that utilizes `init(wrappedValue: ...)`. That's because it would require access to the enclosing `Self`; however, in the case of calling a function this would be undefined.


### Add Wrapper Types in the Standard Library

TBD
