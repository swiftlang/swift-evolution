# Allow Property Wrappers on Let Declarations

* Proposal: [SE-NNNN](NNNN-allow-let-property-wrapper.md)
* Authors: [Amritpan Kaur](https://github.com/amritpan), [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: [Xiaodi Wu](https://github.com/xwu)
* Status: **Awaiting review**
* Implementation: [apple/allow-let-property-wrapper](https://github.com/apple/swift/pull/62342) 

## Introduction

[SE-0258 Property Wrappers](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md) models both mutable and immutable variants of a property wrapper but does not allow wrapped properties explicitly marked as a `let`. This proposal builds on the original vision by expanding property wrapper usage to include let declared properties with a wrapper attribute.

## Motivation

Allowing property wrappers to be applied to `let` properties improves Swift language consistency and expressivity.

Today, a property wrapper can be applied to a property of any type but the rules for declaring these wrapped properties are varied and singular to property wrappers. For example, a struct instance without the property wrapper attribute can be declared with either a `var` or a `let` property. However, mark the struct as a property wrapper type and the compiler no longer allows it to be written as a `let` wrapped property:
```swift
@propertyWrapper
struct Wrapper {
  var wrappedValue: Int { 0 }
  init(wrappedValue: Int) {}
}

struct S {
  @Wrapper let value: Int // error: property wrapper can only be applied to a ‘var’
}
```
Permitting wrapped properties to mimic the rules for other type instances that can be written with either a `var` or a `let` will simplify the Swift language. Additionally, `let` wrapped properties would expand property wrapper usage to allow `nonisolated` wrapped properties and simplify property wrappers usage where the backing type is a reference type.  


## Proposed solution

We propose to allow the application of property wrappers to let declared properties, which will permit the wrapper type to be initialized only once without affecting the implementation of the backing storage.

For example, the following is the implementation for a `@BoilingPoint` property wrapper:
```swift
@propertyWrapper
struct BoilingPoint<T> {
  init(wrappedValue: T) {
    self.wrappedValue = wrappedValue
  }

  var wrappedValue: T
  var projectedValue: T
  
  func toFarenheit() {}
}

struct Temperature {
  @BoilingPoint var water: Double = 373.1
}
```

The initial value for `water` is set using the `init(wrappedValue:)` initializer of the `BoilingPoint` property wrapper type. To ensure that `water` is not changed again, we could add logic to the `wrappedValue` setter to check if the property was already initialized and prevent re-assignment. However, this is an inconvenient solution.

Instead, we could declare the `water` property with a `let`, synthesize a local `let` constant for the backing storage property (prefixed with an underscore), and only allow the property wrapper to be initialized once, passing the assigned value to `init(wrappedValue:)`. Now, rewriting `Temperature`’s properties as `let` constants will translate to:
```swift
struct Temperature {
  @BoilingPoint let water: Double = 373.1

  // ... introduces _water stored property
  private let _water: BoilingPoint<Double> = BoilingPoint<Double>(wrappedValue: 373.1)
  
  // ... getter-only computed property
  @BoilingPoint var water: Double {
    get { return self._water.wrappedValue }
  }
  
  // ... getter-only projectedValue property
  internal var $water: Double {
    get { return self._water.projectedValue }
  }
}
```

Declaring a `let` wrapped property of `water` of type `BoilingPoint` generates a `let` declared storage property of `_water`, a getter-only computed property that assigns the declared value to the backing property wrapper's `wrappedValue`. A let declared wrapped property also generates `$water`, a getter-only projectedValue property.

The `let` declared property can also be initialized once via the generated storage property. For example, reusing the above example:
```swift
  @BoilingPoint let water: Double
  
  init() {
    _water = BoilingPoint(wrappedValue: 373.1)
  }
```

After the `let` declared property has been initialized, attempting to reassign it will show an error. Clients can continue to manipulate the projection just like with `var` declared properties.
```swift
  temperature.water = 400.0 // error: cannot assign to property: 'water' is a 'let' constant
  temperature.$water.toFarenheit() // converts to 212.0
```

Property wrappers with `let` declarations will be allowed both as members and local declarations, as envisioned by [SE-0258](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md) for `var` declared property wrappers. All other property wrapper traits also remain unchanged from SE-0258.

## Detailed Design

Marking a property wrapped declaration with a `let` makes that property a getter-only computed property and introduces a `let` synthesized stored property whose type is the wrapper type. This expands where and how property wrappers can be used in Swift.

### Nonisolated property wrappers

Actor methods and properties, which are inherently isolated to that actor, can be marked `nonisolated` to allow them to be accessed from outside their actor context. At this time, the `nonisolated` keyword cannot be used on property wrappers because `var` declared property wrappers generates a `var` declared backing property that is not safe from race conditions and so cannot be `nonisolated`.
```swift
@propertyWrapper
struct Wrapper {
  var wrappedValue: Int { .zero }
  var projectedValue: Int { .max }
}

@MainActor
class C {
  @Wrapper nonisolated var value // error: `nonisolated` is not supported on `var` declared property wrappers
}
```

Let declared property wrappers will now allow us to write nonisolated property wrappers as the backing property will also be stored `let` property. 
```swift
@MainActor
class C {
  @Wrapper nonisolated let value: Int
  
  nonisolated func test() {
    _ = value
    _ = $value
  }
}
```

### Property wrappers with backing reference types

A `let` wrapped property could be useful for reference types like a property wrapper class. Typically property wrappers are written for value types but occasionally a protocol like `NSObject` may require the use of a class. For example:
```swift
@propertyWrapper
class WrapperClass<T> : NSObject {
  var wrappedValue: T

  init(wrappedValue: T) {
    self.wrappedValue = wrappedValue
  }
}

class C {
  @WrapperClass let value: Int

  init(v: Int) {
    value = v
  }
}
```
Even though  `value` is declared with a class type property wrapper, it can only be assigned once, preventing any future unintentional changes to the property wrapper class instance in this context. 


### SwiftUI 

SwiftUI property wrappers may also benefit from a let declaration. For example, `@ScaledMetric` in its simplest usage can be written with a `let`:
```swift
struct ContentView: View {
  @ScaledMetric let imageSize = 10

  var body: some View {
    Image(systemName: "heart.fill")
    .resizable()
    .frame(width: imageSize, height: imageSize)
  }
}
```

Similarly, other SwiftUI property wrappers could be `let` declared when they do not require more than a single initialization.

## Alternatives considered

### @State and @Binding property wrappers with `nonmutating set`

Currently, SwiftUI offers two property wrappers,  [`@State`](https://developer.apple.com/documentation/swiftui/state/wrappedvalue) and [`@Binding`](https://developer.apple.com/documentation/swiftui/binding/wrappedvalue), that have a `wrappedValue` property with a `nonmutating set`. This allows the backing types to preserve the reference semantics of the `wrappedValue` implementation.

A `var` declared `@State` property currently generates a nonmutating set that reflects `@State`'s reference based storage:

```swift
@State var weekday: String = "Monday"

private var _weekday: State<String> = State<String>(wrappedValue: "Monday")
var weekday : String {
  get { 
    return _weekday.wrappedValue 
  }
  nonmutating set {
    self._weekday.wrappedValue = value
  }
  nonmutating _modify { 
    yield () 
  }
}
```

Declaring the `@State` property with a `let` will remove the nonmutating setter:

```swift
@State let weekday: String = "Monday"

private let _weekday: State<String> = State<String>(wrappedValue: "Monday")
var weekday : String {
  get { 
    return _weekday.wrappedValue 
  }
}
```

[There is an argument to be made](https://forums.swift.org/t/pitch-allow-property-wrappers-on-let-declarations/61750/20) in favor of retaining the `nonmutating set` for let declared `@State` and `@Binding` to signify their reference based storage. Afterall, a property wrapper's `wrappedValue` could be assigned via the `_weekday` backing property, even if `weekday` was marked with a `let` instead of a `var`.

However, we have elected to remove the `nonmutating set` for `let` declared `@State` or `@Binding` to maintain language consistency. Since property wrapper is just a struct or class with an attribute and a `wrappedValue`, a struct with a backing type of a class would not generate a nonmutating setter for its instances. For example:

```swift
class A {
  init () {}
}

struct B {
  var num: A

  init(n: A) {
    self.num = n
  }
}

struct Test {
  let b: B // note: change 'let' to 'var' to make it mutable
  
  var test: A {
    get { b.num }
    nonmutating set { b.num = newValue } // error: cannot assign to property: 'b' is a 'let' constant
  }
}
```

Should SwiftUI or general property wrapper usage evolve in a different direction in the future, this decision can be reconsidered to propagate backing type traits to property wrapper declarations.

## Effect on ABI stability/API resilience

This is an additive change that does not impact source compatibility, does not compromise ABI stability or API resilience, and requires no runtime support for back deployment.
