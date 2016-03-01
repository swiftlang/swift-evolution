# Mixins

* Proposal: [SE-NNNN](https://github.com/Anton3/swift-evolution/blob/mixins/proposals/NNNN-mixins.md)
* Author(s): [Anton3](https://github.com/Anton3)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Add [mixins](https://en.wikipedia.org/wiki/Mixin), which contain both protocol requirements and stored properties. Mixins will subsume abstract class functionality and allow similar functionality on structs. They will also allow for safe multiple inheritance, defining standard "bricks" carrying interface, implementation and state, which can be reused in multiple types.

Swift-evolution thread: [link](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160222/011220.html) (the threads are broken, search for "Mixins")

## Motivation

### World objects example

Consider the following code (this could be part of a game):

```swift
struct Enemy {
  var position: CGPoint
  var speed: CGVector = CGVector()

  init(position: CGPoint) {
    self.position = position
    // ...
  }
  mutating func move(timeElapsed: CGFloat) {
    position = CGPoint(x: position.x + timeElapsed * speed.dx, y: position.y + timeElapsed * speed.dy)
  }
  // ...
}

struct Arrow {
  var position: CGPoint
  var speed: CGVector

  init(position: CGPoint, speed: CGVector) {
    self.position = positon
    self.speed = speed
    // ...
  }
  mutating func move(timeElapsed: CGFloat) {
    position = CGPoint(x: position.x + timeElapsed * speed.dx, y: position.y + timeElapsed * speed.dy)
  }
  // ...
}
```

We can clearly see DRY violation: `position`, `speed`, `move`, part of `init` are all repeated. We can improve our code using protocols:


```swift
protocol MovingObject {
  var position: CGPoint { get set }
  var speed: CGVector { get set }
}
extension MovingObject {
  mutating func move(timeElapsed: CGFloat) {
    position = CGPoint(x: position.x + timeElapsed * speed.dx, y: position.y + timeElapsed * speed.dy)
  }
}

struct Enemy: MovingObject {
  var position: CGPoint
  var speed: CGVector = CGVector()

  init(position: CGPoint) {
    self.position = position
    // ...
  }
  // ...
}

struct Arrow: MovingObject {
  var position: CGPoint
  var speed: CGVector

  init(position: CGPoint, speed: CGVector) {
    self.position = positon
    self.speed = speed
    // ...
  }
  // ...
}
```

We have factored out `move()`, but definitions of `position` and `speed` are still causing significant code bloat.

An obvious solution is changing `MovingObject` to be a `class`. It will then be able to contain stored properties `position` and `speed`, as well as their initialization. However, it could more logical for `Enemy` and `Arrow` to remain value types (structs) in a particular context.

There is a more strong reason. In game development, objects are often broken down into simple pieces (traits), so along with `MovingObject`, there would be `RenderableObject`, `TexturedObject`. Such code structure is currently impossible in Swift, because multiple inheritance is prohibited. A pseudo-solution would be to repeat the same fields used by these traits, in each world object. Mixins would provide a more clean solution.

### Example with logging

Consider a logging library, which has a `Logger` class and a convenience base class `LoggingObject`:

```swift
class Logger {
  init(logLevel: Int) { /*...*/ }
  func log(message: String, logLevel: Int) { /*...*/ }
}

class LoggingObject {
  var logger: Logger
  init(logger: Logger) { self.logger = logger }
}

class SomeComputer: LoggingObject {
  init(logger: Logger) {
    super.init(logger)
  }
  func compute() {
    logger.log("Starting", 1)
    if someCondition {
      logger.log("Error", 3)
    }
    logger.log("Ending", 1)
  }
}
```

The problem with such design is that it prohibits all classes using logging from participating in any other class hierarchy.

One of "solutions" would be to inherit all base classes from `LoggingObject`. It leads to a situation, where most to all classes, even not actually using logging, contain `logger` property with corresponding runtime overhead.

## Proposed solution

Introduce mixins, which are basically protocols with ability to contain members of classes, including, most importantly, stored properties.

Mixins can contain:
- Method, property, subscript, initializer requirements, analogous to protocols
- Method, property, subscript, initializer definitions, analogous to classes

Methods, computed properties, subscripts, initializer definitions can be declared in their extensions.

Mixins can be inherited from, or mixed in, in the body declaration of a struct or class. This type must satisfy all the requirements, and will get all defined members of the mixin.

### World objects example

```swift
mixin MovingObject {
  var position: CGPoint
  var speed: CGVector

  init(position: CGPoint, speed: CGVector) {
    self.position = position
    self.speed = speed
  }

  mutating func move(timeElapsed: CGFloat) {
    position = CGPoint(x: position.x + timeElapsed * speed.dx, y: position.y + timeElapsed * speed.dy)
  }
}

struct Enemy: MovingObject {
  init(position: CGPoint) {
    MovingObject.super.init(position: position, speed: CGVector())
    // ...
  }
  // ...
}

struct Arrow: MovingObject {
  init(position: CGPoint, speed: CGVector) {
    MovingObject.super.init(position: position, speed: speed)
    // ...
  }
  // ...
}
```

The code is as DRY as possible, and our data types still can be structs. Moreover, multiple inheritance is allowed for mixins, so adding other parts of behaviour is not a problem:

```swift
mixin MovingObject { /*...*/ }
mixin AnimatedObject { /*...*/ }

struct Enemy: MovingObject, AnimatedObject { /*...*/ }
struct Arrow: MovingObject { /*...*/ }
```

### Example with logging

`LoggingObject` is not a class of objects in the original meaning. It is more like a feature, or behavior of a data type. Using mixins, we can free the road for other parent classes (or other mixins) in the hierarchy:

```swift
class Logger { /*...*/ }

mixin LoggingObject {
  var logger: Logger
  init(logger: Logger) { self.logger = logger }
}

class GenericComputer {
  var result: String? = nil
  init(options: Options) { /*...*/ }
  // ...
}

class SomeComputer: GenericComputer, LoggingObject {
  init(logger: Logger, options: Options) {
    LoggingObject.super.init(logger)
    super.init(logger)
  }
  
  override func compute() {
    logger.log("Starting", 1)
    if someCondition {
      logger.log("Error", 3)
    }
    logger.log("Ending", 1)
  }
}
```

## Detailed design

### Mixin members 

Property requirements:

```swift
var name: Type { get set }
```

Property definitions:

```swift
var name: Type
```

Method requirements:

```swift
func name(arg: Type) -> Result
```

Method definitions:

```swift
func name(arg: Type) -> Result { }
```

There is no notion of default methods in mixins. Methods of mixins require `override` to redefine them in types and can be `final`. 

Mixins consider themselves as value types, as protocols and structs. Every member and requirement, which needs to mutate `self`, needs to be declared as `mutating`.

Subscript requirements and definitions.

Initializer requirements:

```swift
init(name: Type)
```

Initializer definitions:

```swift
init(name: Type) { }
```

Properties can be immediately initialized: `var name: Type = initializer`

These initialized properties are prepended to all initializers. If no initializers are defined, an implicit default initializer is created.

### Initializers

Mixins can have implemented initializers. They act like initializers of classes. `super` initializer calls are prefixed with parent protocol name for disambiguation purposes. `super` initializer must be explicitly called in initializer of subtype. The syntax for that is `SuperMixinName.super.init()`:

```swift
mixin A {
  init(newPath: String) { }
}

mixin B: A {
  override init(newPath: String) { }
}
```

Default `super` initializers also need to be called explicitly. In multiple inheritance, it is a responsibility of subtype to ensure that initialization order matches semantics of mixins it mixes in:

```swift
mixin A { }
mixin B { }

mixin C: A, B {
  init() {
    A.super.init()
    B.super.init()
  }
}
```

### Mixin inheritance

Problem of members with same signatures inherited from two different places results in compile error.

```swift
mixin A { var x: Int = 0 }
mixin B { var x: Int = 1 }
mixin C : A, B { }  // error
```

Diamond problem is solved by keeping only one copy of mixins mixed-in in the final struct/class. Example:

```swift
mixin A { var x: Int = 1 }
mixin B: A { }
mixin C: A { }
struct D: B, C { }  // contains a single copy of x
```

It works as if bodies of all mixins indirectly mixed-in into `D` were merged directly into `D`:

```swift
mixin ASelf { var x: Int = 1 }
mixin BSelf { }
mixin CSelf { }
struct D: ASelf, BSelf, CSelf { }
```

### Multiple inheritance support summarized

- Protocols can inherit from multiple protocols
- Enums     can inherit from multiple prototols
- Mixins    can inherit from multiple protocols and mixins
- Structs   can inherit from multiple protocols and mixins
- Classes   can inherit from multiple protocols and mixins, and a single class

### Support for associated types

Mixins support genericity through associated types the same way protocols do.

### Support for dynamic dispatch

Mixins without `Self` or associated types support dynamic dispatch the same way protocols do.

That said, I want to underline that the primary goal of mixins is to aid in constructing new types. 

When designing an API, it is a good pattern to not require conformance to a mixin, but to require conformance to a protocol and provide a mixin to aid in implementing a common case. This will provide user of your API as much freedom as possible.

```swift
// Create a protocol with what you require from the mixin
protocol Interface {
  var propertyRequirement: Int { get set }
  func methodRequirement()
}

// Adopt the protocol in the mixin
mixin PartialImplementation: Interface {
  var propertyRequirement: Int = 0
  func methodRequirement() { /*...*/ }
  
  // Requirement used to implement Interface requirements
  func requiredPiece()
}

// Code smell: Relying of implementation
func apiFunc(obj: PartialImplementation) { /*...*/ }

// Much better
func apiFunc(obj: Interface) { /*...*/ }
```

This pattern helps preserve [UAC](https://en.wikipedia.org/wiki/Uniform_access_principle).

### Limitations of mixins, compared to protocols

- Mixins must be declared in the declaration of a subtype. Mixins *cannot* be mixed-in in extensions, retroactively.
- Subtypes *must* add `override` to be reimplement methods of a mixin, while default methods of protocols do not require that.
- Multiple inheritance of mixins is limited, by comparison with protocols. Duplicate member definitions *cannot* occur.

### Impact on OOP and POP

Currently, POP has strictly less abilities at its disposal than OOP. Mixins are intended to extend the power of POP to be equal (or greater due to multiple inheritance) than power of OOP. The only significant difference between abilities of structs and classes in Swift will be that classes have reference semantics and structs have value semantics.

## Impact on existing code

`mixin` will be taken as a keyword or a local keyword, so `mixin` names will no longer be available in some to all places.

## Future directions

### Conflict resolving

When including mixins containing the same property or function, we could allow to disambiguate the implementation by some means:

```swift
mixin A {
  func f() { print(1) }
  var x: Int = 1
}
mixin B {
  func f() { print(2) }
  var x: Int = 2
}
mixin C: A, B {
  func f() { A.f() }
  var x: Int = B.x
}
```

### `class` mixins and `deinit`

In analogy with protocols, give mixins the ability to become applicable for classes only via "inheriting" from `class` keyword.
Such mixins would be able to define `deinit`.

```swift
mixin HelloOnDeinit: class {
  deinit { print("Hello") }
}
```

In case of multiple inheritance, the order of `deinit` of neighbor mixins is undefined, but submixins are deinited first:

```swift
mixin A { deinit { print(0) } }
mixin B: A { deinit { print(1) } }
mixin C: A { deinit { print(2) } }
struct D: B, C { }

do {
  _ = D()
}  // 120 and 210 are valid outputs
```

### `@objc` mixins

Mixins can be bridged to Objective-C the same way Swift `@objc` classes do. `@objc` on mixin would imply `class`.

## Alternatives considered

### Add described features directly to protocols

Mixins are not just protocols with stored properties, this difference is described under "Limitations of mixins". If mixins and protocols are defined using the same keyword, then these "protocols" will create errors because this kind of protocols can't be used where usual protocols can. This would aggravate the situation currently present with dynamically dispatched protocols and protocols with `Self` or associated types.

### Allow implicit overriding in multiple inheritance

That is, the following code:

```swift
mixin A { var x: Int = 1 }
mixin B { var x: Int = 2 }
struct C: A, B { }
let c = C()
print(c.x)
```

would print 2, using definition `B.x`, because `B` goes later in the multiple inheritance list.

This implicit behavior is natural in script languages, but would look alien in Swift, which intends to be safe where possible.

### Prepend method requirements with `abstract`

Mixins lean more towards protocols and not classes. Therefore, it is logical to inherit syntax for defining requirements from protocols.

### Use term `trait` instead of `mixin`

Mixins allow implicit overriding in multiple inheritance, while traits do not. Swift's mixins will actually be closer to traits in this regard.

On the other hand, traits originally do not carry state, but mixins do.

"Mixins", as suggested, will not be purely mixins or purely traits, but rather a combination of both.

Historically, the name "mixins" was used throughout the discussion on swift-evolution.

### Add abstract classes

Although abstract classes case is covered by mixins, they can still be added in a separate proposal, duplicating a subset of functionality of mixins with a different syntax.
