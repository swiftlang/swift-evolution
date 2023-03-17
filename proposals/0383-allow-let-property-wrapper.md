# Allow Property Wrappers on Let Declarations

* Proposal: [SE-038N](NNNN-filename.md)
* Authors: [Amritpan Kaur](https://github.com/amritpan), [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/allow-let-property-wrapper](https://github.com/apple/swift/pull/62342) 

## Introduction

[SE-0258 Property Wrappers](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md) models both mutable and immutable variants of a property wrapper but does not allow wrapped properties explicitly marked as a `let`. This proposal builds on the original vision by expanding property wrapper usage to include let declared properties with a wrapper attribute.

## Motivation

Allowing property wrappers to be applied to `let` properties improves Swift language consistency and code safety.

Today, a property wrapper can be applied to a property of any type but the rules for declaring these wrapped properties are varied and singular to property wrappers. For example, a struct instance without the property wrapper attribute can be declared with either a `var` or a `let` property. However, mark the struct as a property wrapper type and the compiler no longer allows it to be written as a `let` wrapped property:
```swift
@propertyWrapper
struct Wrapper {
  var wrappedValue: Int { 0 }
  init(wrappedValue: Int) {}
}

struct S {
  @Wrapper let value: Int // Error: Property wrapper can only be applied to a ‘var’
}
```
Permitting wrapped properties to mimic the rules for other type instances that can be written with either a `var` or a `let` will simplify the Swift language.

Additionally, `let` wrapped properties add code safety where a user wants to expressly remove access to a property’s mutators after initializing the property once or simply does not need a mutable property wrapper. This could be useful for property wrappers that do not change or are reference types.

## Proposed solution

We propose to allow the application of property wrappers to let declared properties, which will permit the wrapper type to be initialized only once without affecting the implementation of the backing storage.

For example, [_The Swift Programming Language_](https://docs.swift.org/swift-book/LanguageGuide/Properties.html#ID617) defines a `SmallNumber` property wrapper and applies it to `UnitRectangle` properties:
```swift
@propertyWrapper
struct SmallNumber {
  private var maximum: Int
  private var number: Int

  var wrappedValue: Int {
    get { return number }
    set { number = min(newValue, maximum) }
  }

  init(wrappedValue: Int) {
    maximum = 12
    number = min(wrappedValue, maximum)
  }
}

struct UnitRectangle {
  @SmallNumber var height: Int = 1
  @SmallNumber var width: Int = 1
}
```
Initial values for `height` and `width` are set using the `init(wrappedValue:)` initializer of the `SmallNumber` property wrapper type. To ensure that `height` and `width` are not changed again, we could add logic to the `wrappedValue` setter to check if the property was already initialized and prevent re-assignment. However, this is an inconvenient solution.

Instead, we could declare these properties with a `let`, synthesize a local `let` constant for the backing storage property (prefixed with an underscore), and only allow the property wrapper to be initialized once, passing the assigned value to `init(wrappedValue:)`. Now, rewriting `UnitRectangle`’s properties as `let` constants will translate to:
```swift
private let _height: SmallNumber = SmallNumber(wrappedValue: 1)
var height: Int {
  get { return _height.wrappedValue }
}

private let _weight: SmallNumber = SmallNumber(wrappedValue: 1)
var weight: Int {
  get { return _weight.wrappedValue }
}
```
and results in code that is easy to write and understand:
```swift
struct UnitRectangle {
  @SmallNumber let height: Int = 1
  @SmallNumber let width: Int = 1
}
```

Property wrappers with `let` declarations will be allowed both as members and local declarations, as envisioned by SE-0258 for `var` declared property wrappers. All other property wrapper traits also remain unchanged from SE-0258.

## Detailed design

Here are three examples of how a `let` wrapped property can make current iterations more effortless.

The `Clamping` property wrapper from [SE-0258 Property Wrappers](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md#clamping-a-value-within-bounds) can be rewritten to use `let` as its storage and implementation do not change, no matter its application.
```swift
struct Color {
  @Clamping(min: 0, max: 255) let purple: Int = 127
}
```

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
Here, `WrapperClass` can be made an immutable property wrapper class instance, preventing any future unintentional changes to the property wrapper class type in this context.

SwiftUI property wrappers may also benefit from a let declaration. For example, `@ScaledMetric` in its simplest usage can be written with a `let` instead:
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

### Property wrappers with `nonmutating set`

Property wrappers that have a `wrappedValue` property with a `nonmutating set` (e.g., SwiftUI's [`@State`](https://developer.apple.com/documentation/swiftui/state/wrappedvalue) and [`@Binding`](https://developer.apple.com/documentation/swiftui/binding/wrappedvalue)) will preserve the reference semantics of the `wrappedValue` implementation even when marked as a `let` declaration. For example:  

```swift
@State let weekday: String = "Monday"
```
Here, `weekday` is an immutable instance of the `@State` property wrapper, but its `wrappedValue` storage will retain its mutability and reference type traits. This will translate to:
```swift
private let _weekday: State<String> = State<String>(wrappedValue: "Monday")
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
var $weekday: Binding<String> {
  get { return _weekday.projectedValue }
}
```

Marking `weekday` as a let declared property will not remove access to its `wrappedValue`'s nonmutating set and the `wrappedValue` can be assigned via the backing property, `_weekday`:

```swift
_weekday.wrappedValue = "Tuesday"
```

However, this does not affect the immutability of `weekday`, which can only be assigned to once like any ordinary let wrapped property. Any attempt to reassign `weekday` will result in an error:

```swift
weekday = "Wednesday" // Error: Cannot assign to value: 'weekday' is a 'let' constant
```

## Source compatibility

This is an additive feature that does not impact source compatibility.

## Effect on ABI stability

This is an additive change that has no direct impact that compromises ABI stability.

## Effect on API resilience

This is an additive change that has no impact on API resilience.
