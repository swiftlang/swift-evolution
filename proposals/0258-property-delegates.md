# Property Delegates

* Proposal: [SE-0258](0258-property-delegates.md)
* Authors: [Doug Gregor](https://github.com/DougGregor), [Joe Groff](https://github.com/jckarter)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Active review (April 15...23, 2019)**
* Implementation: [PR #23701](https://github.com/apple/swift/pull/23701), [Ubuntu 16.04 Linux toolchain](https://ci.swift.org/job/swift-PR-toolchain-Linux/223/artifact/branch-master/swift-PR-23701-223-ubuntu16.04.tar.gz), [macOS toolchain](https://ci.swift.org/job/swift-PR-toolchain-osx/287//artifact/branch-master/swift-PR-23701-287-osx.tar.gz)

## Introduction

There are property implementation patterns that come up repeatedly.
Rather than hardcode a fixed set of patterns into the compiler,
we should provide a general "property delegate" mechanism to allow
these patterns to be defined as libraries.

This is an alternative approach to some of the problems intended to be addressed by the [2015-2016 property behaviors proposal](https://github.com/apple/swift-evolution/blob/master/proposals/0030-property-behavior-decls.md). Some of the examples are the same, but this proposal takes a completely different approach designed to be simpler, easier to understand for users, and less invasive in the compiler implementation. There is a section that discusses the substantive differences from that design near the end of this proposal.

[Pitch #1](https://forums.swift.org/t/pitch-property-delegates/21895)<br/>
[Pitch #2](https://forums.swift.org/t/pitch-2-property-delegates-by-custom-attributes/22855)<br/>

## Motivation

We've tried to accommodate several important patterns for properties with
targeted language support, like `lazy` and `@NSCopying`, but this support has been narrow in scope and utility.  For instance, Swift provides `lazy` properties as a primitive language feature, since lazy initialization is common and is often necessary to avoid having properties be exposed as `Optional`. Without this language support, it takes a lot of boilerplate to get the same effect:

```swift
struct Foo {
  // lazy var foo = 1738
  private var _foo: Int?
  var foo: Int {
    get {
      if let value = _foo { return value }
      let initialValue = 1738
      _foo = initialValue
      return initialValue
    }
    set {
      _foo = newValue
    }
  }
}
```

Building `lazy` into the language has several disadvantages. It makes the
language and compiler more complex and less orthogonal. It's also inflexible;
there are many variations on lazy initialization that make sense, but we
wouldn't want to hardcode language support for all of them.

There are important property patterns outside of lazy initialization.  It often
makes sense to have "delayed", once-assignable-then-immutable properties to
support multi-phase initialization:

```swift
class Foo {
  let immediatelyInitialized = "foo"
  var _initializedLater: String?

  // We want initializedLater to present like a non-optional 'let' to user code;
  // it can only be assigned once, and can't be accessed before being assigned.
  var initializedLater: String {
    get { return _initializedLater! }
    set {
      assert(_initializedLater == nil)
      _initializedLater = newValue
    }
  }
}
```

Implicitly-unwrapped optionals allow this in a pinch, but give up a lot of
safety compared to a non-optional 'let'. Using IUO for multi-phase
initialization gives up both immutability and nil-safety.

The attribute `@NSCopying` introduces a use of `NSCopying.copy()` to
create a copy on assignment. The implementation pattern may look familiar:

```swift
class Foo {
  // @NSCopying var text: NSAttributedString
  var _text: NSAttributedString
  var text: NSAttributedString {
    get { return _text }
    set { _text = newValue.copy() as! NSAttributedString }
  }
}
```

## Proposed solution

We propose the introduction of **property delegates**, which allow a
property declaration to state which **delegate** is used to implement
it.  The delegate is described via an attribute:

```swift
@Lazy var foo = 1738
```

This implements the property `foo` in a way described by the *property delegate type* for `Lazy`:

```swift
@propertyDelegate
enum Lazy<Value> {
  case uninitialized(() -> Value)
  case initialized(Value)

  init(initialValue: @autoclosure @escaping () -> Value) {
    self = .uninitialized(initialValue)
  }

  var value: Value {
    mutating get {
      switch self {
      case .uninitialized(let initializer):
        let value = initializer()
        self = .initialized(value)
        return value
      case .initialized(let value):
        return value
      }
    }
    set {
      self = .initialized(newValue)
    }
  }
}
```

A property delegate type provides the storage for a property that
uses it as a delegate. The `value` property of the delegate type
provides the actual
implementation of the delegate, while the (optional)
`init(initialValue:)` enables initialization of the storage from a
value of the property's type. The property declaration

```swift
@Lazy var foo = 1738
```

translates to:

```swift
var $foo: Lazy<Int> = Lazy<Int>(initialValue: 1738)
var foo: Int {
  get { return $foo.value }
  set { $foo.value = newValue }
}
```

The use of the prefix `$` for the synthesized storage property name is
deliberate: it provides a predictable name for the backing storage,
so that delegate types can provide API. For example, we could provide
a `reset(_:)` operation on `Lazy` to set it back to a new value:

```swift
extension Lazy {
  /// Reset the state back to "uninitialized" with a new,
  /// possibly-different initial value to be computed on the next access.
  mutating func reset(_ newValue:  @autoclosure @escaping () -> Value) {
    self = .uninitialized(newValue)
  }
}

$foo.reset(42)
```

The property delegate instance can be initialized directly by providing the initializer arguments in parentheses after the name. This could be used, for example, when a particular property delegate requires more setup to provide access to a value (example courtesy of Harlan Haskins):

```swift
@propertyDelegate
struct UserDefault<T> {
  let key: String
  let defaultValue: T
  
  var value: T {
    get {
      return UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
    }
    set {
      UserDefaults.standard.set(newValue, forKey: key)
    }
  }
}

enum GlobalSettings {
  @UserDefault(key: "FOO_FEATURE_ENABLED", defaultValue: false)
  static var isFooFeatureEnabled: Bool
  
  @UserDefault(key: "BAR_FEATURE_ENABLED", defaultValue: false)
  static var isBarFeatureEnabled: Bool
}
```

Property delegates can be applied to properties at global, local, or type scope.

## Examples

Before describing the detailed design, here are some more examples of
delegates.

### Delayed Initialization

A property delegate can model "delayed" initialization delegate, where
the definite initialization (DI) rules for properties are enforced
dynamically rather than at compile time.  This can avoid the need for
implicitly-unwrapped optionals in multi-phase initialization. We can
implement both a mutable variant, which allows for reassignment like a
`var`:

```swift
@propertyDelegate
struct DelayedMutable<Value> {
  private var _value: Value? = nil

  var value: Value {
    get {
      guard let value = _value else {
        fatalError("property accessed before being initialized")
      }
      return value
    }
    set {
      _value = newValue
    }
  }

  /// "Reset" the delegate so it can be initialized again.
  mutating func reset() {
    _value = nil
  }
}
```

and an immutable variant, which only allows a single initialization like
a `let`:

```swift
@propertyDelegate
struct DelayedImmutable<Value> {
  private var _value: Value? = nil

  var value: Value {
    get {
      guard let value = _value else {
        fatalError("property accessed before being initialized")
      }
      return value
    }

    // Perform an initialization, trapping if the
    // value is already initialized.
    set {
      if _value != nil {
        fatalError("property initialized twice")
      }
      _value = newValue
    }
  }
}
```

This enables multi-phase initialization, like this:

```swift
class Foo {
  @DelayedImmutable() var x: Int

  init() {
    // We don't know "x" yet, and we don't have to set it
  }

  func initializeX(x: Int) {
    self.x = x // Will crash if 'self.x' is already initialized
  }

  func getX() -> Int {
    return x // Will crash if 'self.x' wasn't initialized
  }
}
```

### `NSCopying`

Many Cocoa classes implement value-like objects that require explicit copying.
Swift currently provides an `@NSCopying` attribute for properties to give
them delegate like Objective-C's `@property(copy)`, invoking the `copy` method
on new objects when the property is set. We can turn this into a delegate:

```swift
@propertyDelegate
struct Copying<Value: NSCopying> {
  private var _value: Value
  
  init(initialValue value: Value) {
    // Copy the value on initialization.
    self._value = value.copy() as! Value
  }

  var value: Value {
    get { return _value }
    set {
      // Copy the value on reassignment.
      _value = newValue().copy() as! Value
    }
  }
}
```

This implementation would address the problem detailed in
[SE-0153](https://github.com/apple/swift-evolution/blob/master/proposals/0153-compensate-for-the-inconsistency-of-nscopyings-behaviour.md). Leaving the `copy()` out of `init(initialValue:)` implements the pre-SE-0153 semantics.

### `Atomic`

Support for atomic operations (load, store, increment/decementer, compare-and-exchange) is a commonly-requested Swift feature. While the implementation details for such a feature would involve compiler and standard library magic, the interface itself can be nicely expressed as a property delegate type:


```swift
@propertyDelegate
struct Atomic<Value> {
  private var _value: Value
  
  init(initialValue: Value) {
    self._value = initialValue
  }

  var value: Value {
    get { return load() }
    set { store(newValue: newValue) }
  }
  
  func load(order: MemoryOrder = .relaxed) { ... }
  mutating func store(newValue: Value, order: MemoryOrder = .relaxed) { ... }
  mutating func increment() { ... }
  mutating func decrement() { ... }
}

extension Atomic where Value: Equatable {
  mutating func compareAndExchange(oldValue: Value, newValue: Value, order: MemoryOrder = .relaxed)  -> Bool { 
    ...
  }
}  

enum MemoryOrder {
  case relaxed, consume, acquire, release, acquireRelease, sequentiallyConsistent
};
```

Here are some simple uses of `Atomic`. With atomic types, it's fairly common
to weave lower-level atomic operations (`increment`, `load`, `compareAndExchange`) where we need specific semantics (such as memory ordering) with simple queries, so both the property and the synthesized storage property are used often:

```swift
@Atomic var counter: Int

if thingHappened {
  $counter.increment()
}
print(counter)

@Atomic var initializedOnce: Int?
if initializedOnce == nil {
  let newValue: Int = /*computeNewValue*/
  if !$initializedOnce.compareAndExchange(oldValue: nil, newValue: newValue) {
    // okay, someone else initialized it. clean up if needed
  }
}
print(initializedOnce)
```

### Thread-specific storage

Thread-specific storage (based on pthreads) can be implemented as a property delegate, too (example courtesy of Daniel Delwood):

```swift
@propertyDelegate
final class ThreadSpecific<T> {
  private var key = pthread_key_t()
  private let initialValue: T

  init(key: pthread_key_t, initialValue: T) {
    self.key = key
    self.initialValue = initialValue
  }

  init(initialValue: T) {
    self.initialValue = initialValue
    pthread_key_create(&key) {
      // 'Any' erasure due to inability to capture 'self' or <T>
      $0.assumingMemoryBound(to: Any.self).deinitialize(count: 1)
      $0.deallocate()
    }
  }

  deinit {
    fatalError("\(ThreadSpecific<T>.self).deinit is unsafe and would leak")
  }

  private var box: UnsafeMutablePointer<Any> {
    if let pointer = pthread_getspecific(key) {
      return pointer.assumingMemoryBound(to: Any.self)
    } else {
      let pointer = UnsafeMutablePointer<Any>.allocate(capacity: 1)
      pthread_setspecific(key, UnsafeRawPointer(pointer))
      pointer.initialize(to: initialValue as Any)
      return pointer
    }
  }

  var value: T {
    get { return box.pointee as! T }
    set (v) {
      box.withMemoryRebound(to: T.self, capacity: 1) { $0.pointee = v }
    }
  }
}
```

### Copy-on-write

With some work, property delegates can provide copy-on-write wrappers (original example courtesy of Brent Royal-Gordon):

```swift
protocol Copyable: AnyObject {
  func copy() -> Self
}

@propertyDelegate
struct CopyOnWrite<Value: Copyable> {
  init(initialValue: Value) {
    value = initialValue
  }
  
  private(set) var value: Value
  
  var delegateValue: Value {
    mutating get {
      if !isKnownUniquelyReferenced(&value) {
        value = value.copy()
      }
      return value
    }
    set {
      value = newValue
    }
  }
}
```

`delegateValue` provides delegation for the synthesized storage property, allowing the copy-on-write wrapper to be used directly:

```swift
@CopyOnWrite var storage: MyStorageBuffer

// Non-modifying access:
let index = storage.index(of: …)

// For modification, access $storage, which goes through `delegateValue`:
$storage.append(…)
```

### `Ref` / `Box`

We can define a property delegate type `Ref` that is an abstracted reference
to some value that can be get/set, which is effectively a programmatic computed
property:

```swift
@propertyDelegate
struct Ref<Value> {
  let read: () -> Value
  let write: (Value) -> Void

  var value: Value {
    get { return read() }
    nonmutating set { write(newValue) }
  }

  subscript<U>(dynamicMember keyPath: WritableKeyPath<Value, U>) -> Ref<U> {
    return Ref<U>(
        read: { self.value[keyPath: keyPath] },
        write: { self.value[keyPath: keyPath] = $0 })
  }
}
```

The subscript is using [SE-0252 "Key Path Member Lookup"](https://github.com/apple/swift-evolution/blob/master/proposals/0252-keypath-dynamic-member-lookup.md) so that a `Ref` instance provides access to the properties of its value. Building on the example from SE-0252:

```swift
@Ref(read: ..., write: ...)
var rect: Rectangle

print(rect)          // accesses the Rectangle
print(rect.topLeft)  // accesses the topLeft component of the rectangle

let rect2 = $rect    // get the Ref<Rectangle>
let topLeft2 = $rect.topLeft // get a Ref<Point> referring to the Rectangle's topLeft
```

The `Ref` type encapsulates read/write, and making it a property delegate lets
us primarily see the underlying value. Often, one does not want to explicitly
write out the getters and setters, and it's fairly common to have a `Box` type that boxes up a value and can vend `Ref` instances referring into that box. We can do so with another property delegate:

```swift
@propertyDelegate
class Box<Value> {
  var value: Value

  init(initialValue: Value) {
    self.value = initialValue
  }

  var delegateValue: Ref<Value> {
    return Ref<Value>(read: { self.value }, write: { self.value = $0 })
  }
}
```

Now, we can define a new `Box` directly:

```swift
@Box var rectangle: Rectangle = ...

print(rectangle)  // access the rectangle
print(rectangle.topLeft) // access the top left coordinate of the rectangle
let rect2 = $rectangle   // through delegateValue, produces a Ref<Rectangle>
let topLeft2 = $rectangle.topLeft   // through delegateValue, produces a Ref<Point>
```

The use of `delegateValue` hides the box from the client, providing direct access to the value in the box (the common case) as well as access to the box contents via Ref.

### Property delegate types in the wild

There are a number of existing types that already provide the basic structure of a property delegate type. One fun case is `Unsafe(Mutable)Pointer`, which we could augment to allow easy access to the pointed-to value:

```swift
@propertyDelegate
struct UnsafeMutablePointer<Pointee> {
  var pointee: Pointee { ... }
  
  var value: Pointee {
    get { return pointee }
    set { pointee = newValue }
  }
}
```

From a user perspective, this allows us to set up the unsafe mutable pointer's address once, then mostly refer to the pointed-to value:

```
@UnsafeMutablePointer(mutating: addressOfAnInt)
var someInt: Int

someInt = 17 // equivalent to someInt.pointee = 17
print(someInt)

$someInt.deallocate()
```

RxCocoa's [`BehaviorRelay`](https://github.com/ReactiveX/RxSwift/blob/master/RxCocoa/Traits/BehaviorRelay.swift) replays the most recent value provided to it for each of the subscribed observers. It is created with an initial value, has `value` property to access the current value, as well as API to `subscribe` a new observer: (Thanks to Adrian Zubarev for pointing this out)

```swift
@BehaviorRelay
var myValue: Int = 17

let observer = $myValue.subscribe(...)   // subscribe an observer
$myValue.accept(42)  // set a new value via the synthesized storage property

print(myValue)   // print the most recent value
```

## Detailed design

### Property delegate types

A *property delegate type* is a type that can be used as a property
delegate. There are three basic requirements for a property delegate
type:

1. The property delegate type must be defined with the attribute
`@propertyDelegate`. The attribute indicates that the type is meant to
be used as a property delegate type, and provides a point at which the
compiler can verify any other consistency rules.
2. The name of the property delegate type must not match the regular expression `_*[a-z].*`. Such names are reserved for compiler-defined attributes.
3. The property delegate type must have a property named `value`, whose
access level is the same as that of the type itself. This is the
property used by the compiler to access the underlying value on the
delegate instance.

### Initialization of synthesized storage properties

Introducing a property delegate to a property makes that property
computed (with a getter/setter) and introduces a stored property whose
type is the delegate type. That stored property can be initialized
in one of two ways:

1. Via a value of the original property's type (e.g., `Int` in `@Lazy var
    foo: Int`, using the the property delegate type's
    `init(initialValue:)` initializer. That initializer must have a single
    parameter of the same type as the `value` property (or
    be an `@autoclosure` thereof) and have the same access level as the 
    property delegate type itself. When `init(initialValue:)` is present,
    is is always used for the initial value provided on the property
    declaration. For example:
    
    ```swift
    @Lazy var foo = 17
    
    // ... implemented as
    var $foo: Lazy = Lazy(initialValue: 17)
    var foo: Int { /* access via $foo.value as described above */ }
    ```


2. Via a value of the property delegate type, by placing the initializer
   arguments after the property delegate type:
    
    ```swift
    var addressOfInt: UnsafePointer<Int> = ...
    
    @UnsafeMutablePointer(mutating: addressOfInt) 
    var someInt: Int
    
    // ... implemented as
    var $someInt: UnsafeMutablePointer<Int> = UnsafeMutablePointer(mutating: addressOfInt)
    var someInt: Int { /* access via $someInt.value */ }
    ```

### Type inference with delegates

Type inference for properties with delegates involves both the type
annotation of the original property (if present) and the delegate
type, using the initialization of the synthesized stored property. For
example:

```swift
@Lazy var foo = 17
// type inference as in...
var $foo: Lazy = Lazy(initialValue: 17)
// infers the type of 'foo' to be 'Int'
```

The same applies when directly initializing the delegate instance, e.g.,

```swift
@UnsafeMutablePointer(mutating: addressOfInt)
var someInt
// type inference as in...
var $someInt: UnsafeMutablePointer = UnsafeMutablePointer.init(mutating: addressOfInt)
// infers the type of 'someInt' to be 'Int'
```

The type of the `value` property of the property delegate type must coincide with that of the original property using that delegate type. Some examples:

```swift
@Lazy<Int> var foo: Int  // okay
@Lazy<Int> var bar: Double  // error: Lazy<Int>.value is of type Int, not Double
```

If there is no initializer for the delegate instance, and the property delegate type takes a single generic parameter, the corresponding generic argument can be omitted:

```swift
@Lazy var foo: Int    // okay: equivalent to @Lazy<Int> var foo: Int
```

### Custom attributes

Property delegates are a form of custom attribute, where the attribute syntax
is used to refer to entities declared in Swift. Grammatically, the use of property delegates is described as follows:

```
attribute ::= '@' type-identifier expr-paren?
```

The *type-identifier* must refer to a property delegate type, which can include generic arguments. Note that this allows for qualification of the attribute names, e.g.,

```swift
@Swift.Lazy var foo = 1742
```

The *expr-paren*, if present, provides the initialization arguments for the delegate instance.

This formulation of custom attributes fits in with a [larger proposal for custom attributes](https://forums.swift.org/t/pitch-introduce-custom-attributes/21335/47), which uses the same custom attribute syntax as the above but allows for other ways in which one can define a type to be used as an attribute. In this scheme, `@propertyDelegate` is just one kind of custom attribute: there will be other kinds of custom attributes that are available only at compile time (e.g., for tools) or runtime (via some reflection capability).

### Mutability of properties with delegates

Generally, a property that has a property delegate will have both a getter and a setter. However, the setter may be missing if the `value` property of the property delegate type lacks a setter, or its setter is inaccessible.

The synthesized getter will be `mutating` if the property delegate type's `value` property is `mutating` and the property is part of a `struct`. Similarly, the synthesized setter will be `nonmutating` if either the property delegate type's `value` property has a `nonmutating` setter or the property delegate type is a `class`. For example:

```swift
struct MutatingGetterDelegate<Value> {
  var value: Value {
    mutating get { ... }
    set { ... }
  }
}

struct NonmutatingSetterDelegate<Value> {
  var value: Value {
    get { ... }
    nonmutating set { ... }
  }
}

class ReferenceDelegate<Value> {
  var value: Value
}

struct UseDelegates {
  // x's getter is mutating
  // x's setter is mutating
  @MutatingGetterDelegate var x: Int

  // y's getter is nonmutating
  // y's setter is nonmutating
  @NonmutatingSetterDelegate var y: Int
  
  // z's getter is nonmutating
  // z's setter is nonmutating
  @ReferenceDelegate var z: Int  
}
```

### Out-of-line initialization of properties with delegates

A property that has a delegate can be initialized after it is defined,
either via the property itself (if the delegate type has an
`init(initialValue:)`) or via the synthesized storage property. For
example:


```swift
@Lazy var x: Int
// ...
x = 17   // okay, treated as $x = .init(initialValue: 17)
```

The synthesized storage property can also be initialized directly,
e.g.,

```swift
@UnsafeMutable var y: Int
// ...
$y = UnsafeMutable<Int>(pointer: addressOfInt) // okay
```

Note that the rules of [definite
initialization](https://developer.apple.com/swift/blog/?id=28) (DI)
apply to properties that have delegates. Let's expand the example of
`x` above to include a re-assignment and use `var`:

```swift
@Lazy var x2: Int
// ...
x2 = 17   // okay, treated as $x2 = .init(initialValue: 17)
// ...
x2 = 42   // okay, treated as x2 = 42 (calls the Lazy.value setter)
```

### Access to the storage property

By default, the synthesized storage property will have `internal` access or the access of the original property, whichever is more restrictive.

### Memberwise initializers

Structs implicitly declare memberwise initializers based on the stored
properties of the struct. With a property that has a delegate, the
property is technically computed because it's the synthesized property
(of the delegate's type) that is stored. Instance properties that have a
property delegate will have a corresponding parameter in the memberwise
initializer, whose type will either be the original property type or
the delegate type, depending on the delegate type and the initial value
(if provided). Specifically, the memberwise initializer parameter for
an instance property with a property delegate will have the original
property type if either of the following is true:

* The corresponding property has an initial value specified with the
`=` syntax, e.g., `@Lazy var i = 17`, or
- The corresponding property has no initial value, but the property
delegate type has an `init(initialValue:)`.

Otherwise, the memberwise initializer parameter will have the same
type as the delegate. For example:

```swift
struct Foo {
  @UserDefault(key: "FOO_FEATURE_ENABLED", defaultValue: false)
  var x: Bool
  @Lazy var y: Int = 17
  @Lazy(closure: { getBool() }) var z: Bool
  @CopyOnWrite var w: Image

  // implicit memberwise initializer:
  init(x: UserDefault<Bool> = UserDefault(key: "FOO_FEATURE_ENABLED", defaultValue: false),
       y: Int = 17,
       z: Lazy<Bool> = Lazy(closure: { getBool() }),
       w: Image) {
    self.$x = x
    self.$y = Lazy(initialValue: y)
    self.$z = z
    self.$w = CopyOnWrite(initialValue: w)
  }
}
```

Synthesis for `Encodable`, `Decodable`, `Hashable`, and `Equatable`
using the underlying `value` of the property when the property
delegate type contains an `init(initialValue:)` and the delegate's
type otherwise.

### $ identifiers

Currently, identifiers starting with a `$` are not permitted in Swift programs. Today, such identifiers are only used in LLDB, where they can be used to name persistent values within a debugging session.

This proposal loosens these rules slightly: the Swift compiler will introduce identifiers that start with `$` (for the synthesized storage property), and Swift code can reference those properties. However, Swift code cannot declare any new entities with an identifier that begins with `$`. For example:

```swift
@Lazy var x = 17
print($x)     // okay to refer to compiler-defined $x
let $y = 17   // error: cannot declare entity with $-prefixed name '$y'
```

### Accessors

A property with a delegate can declare accessors explicitly (`get`, `set`, `didSet`, `willSet`). If either `get` or `set` is missing, it will be implicitly created by accessing the storage property (e.g., `$foo`). For example:

```swift
@Lazy var x = 17 {
  set {
    $x.value = newValue * 2
  }

  // implicitly synthesized...
  get { return $x.value }
}


@Lazy var y = 42 {
  didSet {
    print("Overrode lazy value with \(oldValue)")
  }

  // implicitly synthesized...
  set {
    let oldValue = $y.value
    $y.value = newValue
    didSet(oldValue)
  }
}
```

### Delegating access to the storage property

A property delegate type can choose to hide its instance entirely by providing a property named `delegateValue`. As with the `value` property and`init(initialValue:)`, the `delegateValue` property must have the
same access level as its property delegate type. When present, the synthesized storage property is hidden completely and the property `$foo` becomes a computed property accessing the storage property's `delegateValue`. For example:

```swift
class StorageManager {
  func allocate<T>(_: T.Type) -> UnsafeMutablePointer<T> { ... }
}

@propertyDelegate
struct LongTermStorage<Value> {
  let pointer: UnsafeMutablePointer<Value>

  init(manager: StorageManager, _ initialValue: Value) {
    pointer = manager.allocate(Value.self)
    pointer.initialize(to: initialValue)
  }

  var value: Value {
    get { return pointer.pointee }
    set { pointer.pointee = newValue }
  }

  var delegateValue: UnsafeMutablePointer<Value> {
    return pointer
  }
}
```

When we use the `LongTermStorage` delegate, it handles the coordination with the `StorageManager` and provides either direct access or an `UnsafeMutablePointer` with which to manipulate the value:

```swift
let manager = StorageManager(...)

@LongTermStorage(manager: manager, initialValue: "Hello")
var someValue: String

print(someValue)     // prints "Hello"
someValue = "World"  // update the value in storage to "World"

// $someValue accesses the delegateValue property of the delegate instance, which
// is an UnsafeMutablePointer<String>
let world = $someValue.move()   // take value directly from the storage
$someValue.initialize(to: "New value")
```

### Restrictions on the use of property delegates

There are a number of restrictions on the use of property delegates when defining a property:

* A property with a delegate may not declared inside a protocol.
* An instance property with a delegate may not declared inside an extension.
* An instance property may not be declared in an `enum`.
* A property with a delegate that is declared within a class must be
`final` and cannot override another property. 
* A property with a delegate cannot be `lazy`, `@NSCopying`, `@NSManaged`, `weak`, or `unowned`.
* A property with a delegate must be the only property declared within its enclosing declaration (e.g., `@Lazy var (x, y) = /* ... */` is ill-formed).
* The `value` property and (if present) `init(initialValue:)` of a property delegate type shall have the same access as the property delegate type.

## Impact on existing code

By itself, this is an additive feature that doesn't impact existing
code. However, with some of the property delegates suggested, it can
potentially obsolete existing, hardcoded language
features. `@NSCopying` could be completely replaced by a `Copying`
property delegate type introduced in the `Foundation` module. `lazy`
cannot be completely replaced because it's initial value can refer to
the `self` of the enclosing type; see 'deferred evaluation of
initialization expressions_. However, it may still make sense to
introduce a `Lazy` property delegate type to cover many of the common
use cases, leaving the more-magical `lazy` as a backward-compatibility
feature.

## Backward compatibility

The property delegates language feature as proposed has no impact on the ABI or runtime. Binaries that use property delegates can be backward-deployed to the Swift 5.0 runtime.

## Alternatives considered

### Using a formal protocol instead of `@propertyDelegate`

Instead of a new attribute, we could introduce a `PropertyDelegate`
protocol to describe the semantic constraints on property delegate
types. It might look like this:

```swift
protocol PropertyDelegate {
  associatedtype Value
  var value: Value { get }
}
```

There are a few issues here. First, a single protocol
`PropertyDelegate` cannot handle all of the variants of `value` that
are implied by the section on mutability of properties with delegates,
because we'd need to cope with `mutating get` as well as `set` and
`nonmutating set`. Moreover, protocols don't support optional
requirements, like `init(initialValue:)` (which also has two
forms: one accepting a `Value` and one accepting an `@autoclosure ()
-> Value`) and `init()`. To cover all of these cases, we would need a
several related-but-subtly-different protocols.

The second issue that, even if there were a single `PropertyDelegate`
protocol, we don't know of any useful generic algorithms or data
structures that seem to be implemented in terms of only
`PropertyDelegate`.


### Kotlin-like `by` syntax

A previous iteration of this proposal (and its [implementation](https://github.com/apple/swift/pull/23440)) used `by` syntax similar to that of [Kotlin's delegated
properties](https://kotlinlang.org/docs/reference/delegated-properties.html), where the `by` followed the variable declaration. For example:

```swift
var foo by Lazy = 1738

static var isFooFeatureEnabled: Bool by UserDefault(key: "FOO_FEATURE_ENABLED", defaultValue: false)
```

There are some small advantages to this syntax over the attribute formulation:

* For cases like `UserDefault` where the delegate instance is initialized directly, the initialization happens after the original variable declaration, which reads better because the variable type and name come first, and how it's implemented come later. (Counter point: Swift developers are already accustomed to reading past long attributes, which are typically placed on the previous line)
* The `by DelegateType` formulation leaves syntactic space for add-on features like specifying the access level of the delegate instance (`by private DelegateType`) or delegating to an existing property (`by someInstanceProperty`).

The main problem with `by` is its novelty: there isn't anything else in Swift quite like the `by` keyword above, and it is unlikely that the syntax would be re-used for any other feature. As a keyword, `by` is quite meaningless, and brainstorming  during the [initial pitch](https://forums.swift.org/t/pitch-property-delegates/21895) didn't find any clearly good names for this functionality. 

### The 2015-2016 property behaviors design

Property delegates address a similar set of use cases to *property behaviors*, which were [proposed and
reviewed](https://github.com/apple/swift-evolution/blob/master/proposals/0030-property-behavior-decls.md)
in late 2015/early 2016. The design did not converge, and the proposal
was deferred. This proposal picks up the thread, using much of the
same motivation and some design ideas, but attempting to simplify the
feature and narrow the feature set. Some substantive differences from
the prior proposal are:

* Behaviors were introduced into a property with the `[behavior]`
  syntax, rather than the attribute syntax described here. See the
  property behaviors proposal for more information.
* Delegates are always expressed by a (generic) type. Property behaviors
  had a new kind of declaration (introduced by the
  `behavior` keyword). Having a new kind of declaration allowed for
  the introduction of specialized syntax, but it also greatly
  increased the surface area (and implementation cost) of the
  proposal. Using a generic type makes property delegates more of a
  syntactic-sugar feature that is easier to implement and explain.
* Delegates cannot declare new kinds of accessors (e.g., the
  `didChange` example from the property behaviors proposal).
* Delegates used for properties declared within a type cannot refer to
  the `self` of their enclosing type. This eliminates some use cases
  (e.g., implementing a `Synchronized` property delegate type that
  uses a lock defined on the enclosing type), but simplifies the
  design.
* Delegates can be initialized out-of-line, and one
  can use the `$`-prefixed name to refer to the storage property.
  These were future directions in the property behaviors proposal.


## Future Directions

### Specifying access for the storage property

Like other declarations, the synthesized storage property will be
`internal` by default, or the access level of the original property if it is less than `internal`. However, we could provide separate access control for the storage property to make it more or less accessible using a syntax similar to that of `private(set)`:

```swift
// both foo and $foo are publicly visible
@Lazy
public public(storage) var foo: Int = 1738

// bar is publicly visible, $bar is privately visible
@Atomic
public private(storage) var bar: Int = 1738
```

### Composition of property delegates

Only one property delegate can currently be attached to a given property, so code such as the following is in error:

```swift
@UnsafeMutablePointer @Atomic var x: Int   // error: two attached property delegates
```

The [property behaviors proposal](https://github.com/apple/swift-evolution/blob/master/proposals/0030-property-behavior-decls.md#composing-behaviors) describes some of the concerns surrounding composing behaviors/delegates in this way, which would need to be addressed by a future proposal. Matthew Johnson [sketched out a potential direction](https://forums.swift.org/t/pitch-property-delegates/21895/103) for extending property delegates to support composition of property delegates.

### Referencing the enclosing 'self' in a delegate type

Manually-written getters and setters for properties declared in a type often refer to the `self` of their enclosing type. For example, this can be used to notify clients of a change to a property's value:

```swift
public class MyClass: Superclass {
  private var backingMyVar: Int
  public var myVar: Int {
    get { return backingMyVar }
    set {
      if newValue != backingMyVar {
        self.broadcastValueChanged(oldValue: backingMyVar, newValue: newValue)
      }
      backingMyVar = newValue
    }
  }
}
```

This "broadcast a notification that the value has changed" implementation cannot be cleanly factored into a property behavior type, because it needs access to both the underlying storage value (here, `backingMyVar`) and the `self` of the enclosing type. We could require a separate call to register the `self` instance with the delegate type, e.g.,

```swift
protocol Observed {
  func broadcastValueChanged<T>(oldValue: T, newValue: T)
}

@propertyDelegate
public struct Observable<Value> {
  public var stored: Value
  var observed: Observed?
  
  public init(initialValue: Value) {
    self.stored = initialValue
  }
  
  public func register(_ observed: Observable) {
    self.observed = observed
  }
  
  public var value: Value {
    get { return stored }
    set {
      if newValue != stored {
        observed?.broadcastValueChanged(oldValue: stored, newValue: newValue)
      }
      stored = newValue
    }
  }
}
```

However, this means that one would have to manually call `register(_:)` in the initializer for `MyClass`:

```swift
public class MyClass: Superclass {
  @Observable public var myVar: Int = 17
  
  init() {
    // self.$myVar gets initialized with Observable(initialValue: 17) here
    super.init()
    self.$myVar.register(self)    // register as an Observable
  }
}
```

This isn't as automatic as we would like, and it requires us to have a separate reference to the `self` that is stored within `Observable`.

Instead, we could extend the ad hoc protocol used to access the storage property of a `@propertyDelegate` type a bit further. Instead of (or in addition to) a `value` property, a property delegate type could provide a `subscript(instanceSelf:)` and/or `subscript(typeSelf:)` that receive `self` as a parameter. For example:


```swift
@propertyDelegate
public struct Observable<Value> {
  public var stored: Value
  
  public init(initialValue: Value) {
    self.stored = initialValue
  }
  
  public subscript<OuterSelf: Observed>(instanceSelf observed: OuterSelf) -> Value {
    get { return stored }
    set {
      if newValue != stored {
        observed.broadcastValueChanged(oldValue: stored, newValue: newValue)
      }
      stored = newValue
    }
  }
}
```

The (generic) subscript gets access to the enclosing `self` type via its subscript parameter, eliminating the need for the separate `register(_:)` step and the (type-erased) storage of the outer `self`. The desugaring within `MyClass` would be as follows:

```swift
public class MyClass: Superclass {
  @Observable public var myVar: Int = 17
  
  // desugars to...
  internal var $myVar: Observable<Int> = Observable(initialValue: 17)
  public var myVar: Int {
    get { return $myVar[instanceSelf: self] }
    set { $myVar[instanceSelf: self] = newValue }
  }
}
```

This change is backward-compatible with the rest of the proposal. Property delegate types could provide any (non-empty) subset of the three ways to access the underlying value:

* For instance properties, `subscript(instanceSelf:)` as shown above.
* For static or class properties, `subscript(typeSelf:)`, similar to the above but accepting a metatype parameter.
* For global/local properties, or when the appropriate `subscript` mentioned above isn't provided by the delegate type, the `value` property would be used.

The main challenge with this design is that it doesn't directly work when the enclosing type is a value type and the property is settable. In such cases, the parameter to the subscript would get a copy of the entire enclosing value, which would not allow mutation, On the other hand, one could try to pass `self` as `inout`, e.g.,

```swift
public struct MyStruct {
  @Observable public var myVar: Int = 17
  
  // desugars to...
  internal var $myVar: Observable<Int> = Observable(initialValue: 17)
  public var myVar: Int {
    get { return $myVar[instanceSelf: self] }
    set { $myVar[instanceSelf: &self] = newValue }
  }
}
```

There are a few issues here: first, subscripts don't allow `inout` parameters in the first place, so we would have to figure out how to implement support for such a feature. Second, passing `self` as `inout` while performing access to the property `self.myVar` violates Swift's exclusivity rules ([generalized accessors](https://github.com/apple/swift/blob/master/docs/OwnershipManifesto.md#generalized-accessors) might help address this). Third, property delegate types that want to support `subscript(instanceSelf:)` for both value and reference types would have to overload on `inout` or would have to have a different subscript name (e.g., `subscript(mutatingInstanceSelf:)`).

So, while we feel that support for accessing the enclosing type's `self` is useful and as future direction, and this proposal could be extended to accommodate it, the open design questions are significant enough that we do not want to tackle them all in a single proposal.

### Delegating to an existing property

When specifying a delegate for a property, the synthesized storage property is implicitly created. However, it is possible that there already exists a property that can provide the storage. One could provide a form of property delegation that creates the getter/setter to forward to an existing property, e.g.:

```swift
lazy var fooBacking: SomeDelegate<Int>
@delegate(to: fooBacking) var foo: Int
```

One could express this either by naming the property directly (as above) or, for an even more general solution, by providing a keypath such as `\.someProperty.someOtherProperty`.

## Acknowledgments

This proposal was greatly improved throughout its [first pitch](https://forums.swift.org/t/pitch-property-delegates/21895) by many people. Harlan Haskins, Brent Royal-Gordon, Adrian Zubarev, Jordan Rose and others provided great examples of uses of property delegates (several of which are in this proposal). Adrian Zubarev and Kenny Leung helped push on some of the core assumptions and restrictions of the original proposal, helping to make it more general. Vini Vendramini and David Hart helped tie this proposal together with custom attributes, which drastically reduced the syntactic surface area of this proposal.
