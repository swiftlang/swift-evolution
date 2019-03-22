# Property Delegates

* Proposal: [SE-NNNN](NNNN-property-delegates.md)
* Authors: [Doug Gregor](https://github.com/DougGregor), [Joe Groff](https://github.com/jckarter)
* Review Manager: **TBD**
* Status: **Awaiting review**
* Implementation: [PR #23440](https://github.com/apple/swift/pull/23440)

## Introduction

There are property implementation patterns that come up repeatedly.
Rather than hardcode a fixed set of patterns into the compiler,
we should provide a general "property delegate" mechanism to allow
these patterns to be defined as libraries.

This is an alternative approach to some of the problems intended to be addressed by the [2015-2016 property behaviors proposal](https://github.com/apple/swift-evolution/blob/master/proposals/0030-property-behavior-decls.md). Some of the examples are the same, but this proposal  a completely different approach designed to be simpler, easier to understand for users, and less invasive in the compiler implementation. There is a section that discusses the substantive differences from that design at the end of this proposal.

[Pitch](TODO)<br/>

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
`var` declaration to state which **delegate** is used to implement
it. Borrowing from [Kotlin's delegated
properties](https://kotlinlang.org/docs/reference/delegated-properties.html),
we propose the `by` keyword to indicate the delegate:

```swift
var foo by Lazy = 1738
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
names it after `by`. The `value` property provides the actual
implementation of the delegate, while the (optional)
`init(initialValue:)` enables initialization of the storage from a
value of the property's type. The property declaration

```swift
var foo by Lazy = 1738
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

Like other declarations, the synthesized storage property will be
`internal` by default, or the access level of the original property if it is less than `internal`. However, it can be given more lenient access by putting the
access level after `by`, e.g.,

```swift
// both foo and $foo are publicly visible
public var foo: Int by public Lazy = 1738
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
  static var isFooFeatureEnabled: Bool by UserDefault(key: "FOO_FEATURE_ENABLED", defaultValue: false)
  static var isBarFeatureEnabled: Bool by UserDefault(key: "BAR_FEATURE_ENABLED", defaultValue: false)
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
struct DelayedImmutable<Value>: Value {
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
      _value = initialValue
    }
  }
}
```

This enables multi-phase initialization, like this:

```swift
class Foo {
  var x: Int by DelayedImmutable

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
stuct Copying<Value: NSCopying> {
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

### `Unsafe(Mutable)Pointer`

The `Unsafe(Mutable)Pointer` types could be augmented to be property delegate types, allowing one to access the referenced value directly using the `by` syntax. For example:


```swift
@propertyDelegate
struct UnsafeMutablePointer<Pointee> {
  var pointee: Pointee { ... }
  
  var value: Pointee {
    get { return pointee }
    set { pointee = newValue
  }
}

var someInt: Int by UnsafeMutablePointer(mutating: addressOfAnInt)
someInt = 17 // equivalent to someInt.value = 17
```

## Detailed design

### Property delegate types

A *property delegate type* is a type that can be used as a property
delegate. There are three basic requirements for a property delegate
type:

1. The property delegate type must be defined with the attribute
`@propertyDelegate`. The attribute indicates that the type is meant to
be used as a property delegate type, and provides a point at which the
compiler can verify the other consistency rules.
2. The property delegate type must be generic, with a single generic
type parameter. The type parameter will filled in with the type of the
variable that uses the property delegate type.
3. The property delegate type must have a property named `value` whose
type is that of the single generic type parameter. This is the
property used by the compiler to access the underlying value on the
delegate instance.

### Initialization of synthesized storage properties

Introducing a property delegate to a property makes that property
computed (with a getter/setter) and introduces a stored property whose
type uses the delegate type. That stored property can be initialized
in one of two ways:

1. Via a value of the original property's type (e.g., `Int` in `var
    foo: Int by Lazy`, using the the property delegate type's
    `init(initialValue:)` initializer. That initializer must have a single
    parameter of the property delegate type's generic type parameter (or
    be an `@autoclosure` thereof). When `init(initialValue:)` is present,
    is is always used for the initial value provided on the property
    declaration. For example:
    
    ```swift
    var foo by Lazy = 17
    
    // ... implemented as
    var $foo: Lazy = Lazy(initialValue: 17)
    var foo: Int { /* access via $foo.value as described above */ }
    ```


2. Via a value of the property delegate type, by placing the call arguments after the property delegate type:
    
    ```swift
    var addressOfInt: UnsafePointer<Int> = ...
    var someInt: Int by UnsafeMutablePointer(mutating: addressOfInt)
    
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
var foo by Lazy = 17
// type inference as in...
var $foo: Lazy = Lazy(initialValue: 17)
// infers the type of 'foo' to be 'Int'
```

The same applies when directly initialize the property delegate type, e.g.,

```swift
var someInt by UnsafeMutablePointer(mutating: addressOfInt)
// type inference as in...
var $someInt: UnsafeMutablePointer = UnsafeMutablePointer.init(mutating: addressOfInt)
// infers the type of 'someInt' to be 'Int'
```

### Using delegates in property declarations

A property declaration can specify its delegate following the `by`
keyword:

```text
pattern-initializer ::= pattern property-delegate[opt] initializer[opt]

property-delegate ::= 'by' access-level-modifier[opt] type property-delegate-init[opt]

property-delegate-init ::= parenthesized-expression
                       ::= tuple-expression
```

The *type* in a *property-delegate* must refer to a 'property delegate
type'_ without specifying a generic argument. The
*access-level-modifier* can be any of `private`, `fileprivate`,
`internal`, or `public`, but cannot be less restrictive than the
property declaration itself.

### Mutability of properties with delegates

A property with a delegate must be introduced with the `var` keyword.
If the `value` property of the behavior type lacks a setter (or the setter is inaccessible), `value` will not have a setter. However, the
synthesized storage property could still be mutated.

### Out-of-line initialization of properties with delegates

A property that has a delegate can be initialized after it is defined,
either via the property itself (if the delegate type has an
`init(initialValue:)`) or via the synthesized storage property. For
example:


```swift
let x: Int by Lazy
// ...
x = 17   // okay, treated as $x = .init(initialValue: 17)
```

The synthesized storage property can also be initialized directly,
e.g.,

```swift
var y: Int by UnsafeMutable
// ...
$y = UnsafeMutable<Int>(pointer: addressOfInt) // okay
```

Note that the rules of [definite
initialization](https://developer.apple.com/swift/blog/?id=28) (DI)
apply to properties that have delegates. Let's expand the example of
`x` above to include a re-assignment and use `var`:

```swift
var x2: Int by Lazy
// ...
x2 = 17   // okay, treated as $x2 = .init(initialValue: 17)
// ...
x2 = 42   // okay, treated as x2 = 42 (calls the Lazy.value setter)
```

### Memberwise initializers

Structs implicitly declare memberwise initializers based on the stored
properties of the struct. With a property that has a delegate, the
property is technically computed because it's the synthesized property
(of the delegate's type) that is stored. However, the delegate itself
might be an implementation detail that should not affect the form of
the memberwise initializer.

The parameter type that is introduced into an implicit memberwise
initializer for a property with a delegate is determined as follows:

* If the delegate type contains an `init(initialValue:)`, the
  parameter type is the original type of the property. 
* When the delegate type does not contain an `init(initialValue:)`,
  the parameter type is the type of the synthesized storage property
  (i.e., a specialization of the delegate type). In this case, the
  access level of the implicit initializer may need to be adjusted to
  account for a visibility of the delegate: if the delegate is private
  (e.g., `var x: Int by private UnsafeMutablePointer`), then the implicit memberwise
  initializer will be `private`.

For example:

```swift
struct Foo {
  var x: Int by fileprivate UnsafeMutable
  var y: Int by Lazy = 17

  // implicit memberwise initializer:
  fileprivate init(x: UnsafeMutable<Int>, y: Int = 17) {
    self.$x = x
    self.$y = .init(initialValue: y)
  }
}
```

Synthesis for `Encodable`, `Decodable`, `Hashable`, and `Equatable`
follows the same rules, using the underlying `value` of the property
delegate type contains an `init(initialValue:)` and the synthesized
storage property's type otherwise.

### $ identifiers

Currently, identifiers starting with a `$` are not permitted in Swift programs. Today, such identifiers are only used in LLDB, where they can be used to name persistent values within a debugging session.

This proposal loosens these rules slightly: the Swift compiler will introduce identifiers that start with `$` (for the synthesized storage property), and Swift code can reference those properties. However, Swift code cannot declare any new entities with an identifier that begins with `$`. For example:

```swift
var x by Lazy = 17
print($x)     // okay to refer to compiler-defined $x
let $y = 17   // error: cannot declare entity with $-prefixed name '$y'
```

### Restrictions on the use of property delegates

There are a number of restrictions on the use of property delegates when defining a property:

* A property with a delegate may not declared inside a protocol.
* An instance property with a delegate may not declared inside an extension.
* An instance property may not be declared in an `enum`.
* A property with a delegate that is declared within a class must be
`final` and cannot override another property. 
* A property with a delegate may not declare any accessors.
* A property with a delegate cannot be `lazy`, `@NSCopying`, or `@NSManaged`.
* A property with a delegate must be the only property declared within its enclosing declaration (e.g., `var (x, y) by Lazy = /* ... */` is ill-formed)

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
are implied by the section 'Mutability of properties with delegates'_,
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

## The 2015-2016 property behaviors design

Property delegates address a similar set of use cases to *property behaviors*, which were [proposed and
reviewed](https://github.com/apple/swift-evolution/blob/master/proposals/0030-property-behavior-decls.md)
in late 2015/early 2016. The design did not converge, and the proposal
was deferred. This proposal picks up the thread, using much of the
same motivation and some design ideas, but attempting to simplify the
feature and narrow the feature set. Some substantive differences from
the prior proposal are:

* Behaviors were introduced into a property with the `[behavior]`
  syntax, rather than the `by delegate` syntax described here. See the
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
