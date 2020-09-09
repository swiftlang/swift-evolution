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
struct Wrapper<Value> {
    var wrappedValue: Value
}

struct Foo {
    @Wrapper
    var count = 0
     
    func increase() {
        count += 1
        // Great!
    }
}

func foo(count: Wrapper<Int>) {
    count.wrappedValue = ...
    //   ^~~~~~~~~~~~ 
    // Unfortunately, we can't
    // use `@Wrapper` here.
}
```

As seen in the above example, it quite akward and unintuitive that property wrappers cannot be applied to function parameters. This is only emphasized by the fact that property wrappers originally sought out to abstract away such accessor patterns.  As a result, elegant APIs are undermined by this limitation. Not only, is this limiting users by forcing them to rigidly follow API guidelines, which may not cover a specific use case, but it also limits API authors in what they can create. That is, API authors can't use property-wrapper types in closure parameters nor can code be seperated into functions that accept property wrapper syntax:

```swift
func fooInClosure(
    _ block: (Wrapper<Int>) -> Void
) { ... }

fooInClosure { count in 
    count.wrappedValue = 2
    //    ^~~~~~~~~~~~ 
    // Again, we have to 
    // access count through
    // `wrappedValue`.
}
```

In fact, establishing custom behavior on closure parameters is really powerful. For example, if such a feature were supported, it could be used in conjunction with [Function Builders](https://github.com/apple/swift-evolution/blob/master/proposals/0289-function-builders.md) to expose data managed by a 'component' type. Moreover, property wrappers in escaping closures could be used to expose data available at the time the closure is executed in a simple and intuitive manner.

## Proposed solution

We propose to extend the contexts were application of property-wrapper types is allowed. Namely, application of such types will be allowed on function and closure parameters:

```swift
@propertyWrapper
struct Wrapper<Value> {
    var wrappedValue: Value
    
    var projectedValue: Self {
        self
    }
}

func foo(@Wrapper count: Int = 0) {
    ...
}

func fooInClosure(
    _ block: (Wrapper<Int>) -> Int
) { ... }

struct Foo {
    @Wrapper
    var count = 0
    
    func bar() {
        foo(count: $count)
        
        fooInClosure { @Wrapper count in
            ...
        }
    }
}
```


## Detailed design

Property wrappers are essentially sugar wrapping a given property with compiler synthesized code. This proposal retains this principle employing the following rules for transformation.

### Rules for Function Parameters

Function parameters marked with a property wrapper type must conform to a set of rules:

1. For a default value to be included, the wrapper type must define an initializer with a first parameter labeled "wrappedValue".
2. Marking a property-wrapping paramter `inout` is required and only allowed when the wrapper type's `wrappedValue` property defines a mutating setter.
3. If any of the transformed functions share their signature with another function, the compiler will consider one of the two a redeclaration of the other.

The transformation that will take place is as follows:

1. The parameter name will be prefixed with an underscore.
2. A synthesized computed property representing  `wrappedValue` will be created and named per the original (non-prefixed) parameter name. The accessors will mirror the `wrappedValue`'s ones.
3. A synthesized computed property representing  `projectedValue` will be created and named per the original parameter name prefixed with a dollar sign (`$`). The accessors will mirror the `projectedValue`'s ones - except if a mutating setter is defined and the parameter isn't `inout`.
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

func b(@Wrapper foo: inout Int) { ... }

var myInt = 0
b(foo: &myInt)
```

    Becomes:

```swift
func b(_foo: inout Wrapper<Int>) {
    var foo: Int { ... }
}

// with the overload:

func b(foo: inout Int) {
    var _foo: Wrapper<Int> {
        get {
            Wrapper(wrappedValue: foo)
        }
        set {
            foo = newValue.wrappedValue
        }
    }

    c(_foo: _foo)
}
```

3. Reference Semantics Wrapper with Special Initializer

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
```

    Becomes:

```swift
func c(_foo: WrapperObject<Int>) {
    var foo: Int { 
        _foo.wrappedValue 
    }
}
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

typealias B = (Wrapper<Int>) -> Void

let b: B = { @Wrapper foo in
    ...
}
```

    Becomes:

```swift
let b: B = { _foo in
    var foo: Int {
        _foo.wrappedValue 
    }
    // No setter is allowed,
    // since foo isn't inout.

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

**TBD**


## Future Directions

### Add Wrapper Types in the Standard Library 

TBD
