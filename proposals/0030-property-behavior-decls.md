# Property Behaviors

* Proposal: [SE-0030](https://github.com/apple/swift-evolution/blob/master/proposals/0030-property-behavior-decls.md)
* Author(s): [Joe Groff](https://github.com/jckarter)
* Status: **Under review** (February 10...February 16, 2016)
* Review manager: [Doug Gregor](https://github.com/DougGregor)

## Introduction

There are property implementation patterns that come up repeatedly.
Rather than hardcode a fixed set of patterns into the compiler,
we should provide a general "property behavior" mechanism to allow
these patterns to be defined as libraries.

## Motivation

We've tried to accommodate several important patterns for properties with
targeted language support, but this support has been narrow in scope and
utility.  For instance, Swift 1 and 2 provide `lazy` properties as a primitive
language feature, since lazy initialization is common and is often necessary to
avoid having properties be exposed as `Optional`. Without this language
support, it takes a lot of boilerplate to get the same effect:

```swift
class Foo {
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
wouldn't want to hardcode language support for all of them. For instance, some
applications may want the lazy initialization to be synchronized, but `lazy`
only provides single-threaded initialization. The standard implementation of
`lazy` is also problematic for value types. A `lazy` getter must be `mutating`,
which means it can't be accessed from an immutable value.  Inline storage is
also suboptimal for many memoization tasks, since the cache cannot be reused
across copies of the value. A value-oriented memoized property implementation
might look very different, using a class instance to store the cached value
out-of-line in order to avoid mutation of the value itself. Lazy properties are
also unable to surface any additional operations over a regular property, such
as to reset a lazy property's storage to be recomputed again.

There are important property patterns outside of lazy initialization.
It often makes sense to have "delayed",
once-assignable-then-immutable properties to support multi-phase initialization:

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
safety compared to a non-optional 'let'. Using IUO for multi-phase initialization
gives up both immutability and nil-safety.

We also have other application-specific property features like
`didSet`/`willSet` that add language complexity for
limited functionality. Beyond what we've baked into the language already,
there's a seemingly endless set of common property behaviors, including
resetting, synchronized access, and various kinds of proxying, all begging for
language attention to eliminate their boilerplate.

## Proposed solution

I suggest we allow for **property behaviors** to be implemented within the
language.  A `var` or `let` declaration can specify its **behaviors** in square
brackets after the keyword:

```swift
var [lazy] foo = 1738
```

which implements the property `foo` in a way described by the **property
behavior declaration** for `lazy`:

```swift
behavior var [lazy] _: Value = initialValue {
  var value: Value? = nil

  mutating get {
    if let value = value {
      return value
    }
    let initial = initialValue
    value = initial
    return initial
  }
  set {
    value = newValue
  }

  mutating func clear() {
    value = nil
  }
}
```

Property behaviors can control the storage,
initialization, and access of affected properties, obviating the need for
special language support for `lazy`, observers, and other
special-case property features. Property behaviors can also provide additional
operations on properties, such as `clear`-ing a lazy property, accessed with
`property.[behavior]` syntax:

```swift
foo.[lazy].clear()
```

## Examples

Before describing the detailed design, I'll run through some examples of
potential applications for behaviors.

### Lazy

The current `lazy` property feature can be reimplemented as a property behavior.

```swift
// Property behaviors are declared using the `behavior var` keyword cluster.
// The declaration is designed to look similar to a property declaration
// using the behavior. Identifiers in the name, type, and initializer position
// of the declaration bind to the name as a string, type as a generic parameter,
// and initializer as a computed property, respectively.
public behavior var [lazy] _: Value = initialValue {
  // Behaviors can declare storage that backs the property.
  private var value: Value?

  // Behaviors can declare initialization logic for the storage.
  // (Stored properties can also be initialized in-line.)
  init() {
    value = nil
  }

  // Inline initializers are also supported, so `var value: Value? = nil`
  // would work equivalently.

  // Behaviors can declare accessors that implement the property.
  mutating get {
    if let value = value {
      return value
    }
    let initial = initialValue
    value = initial
    return initial
  }
  set {
    value = newValue
  }

  // Behaviors can also declare methods to attach to the property.
  // These can be accessed with `property.[behavior].method` syntax.
  public mutating func clear() {
    value = nil
  }
}
```

Properties declared with the `lazy` behavior are backed by the `Optional`-typed
storage and accessors from the behavior:

```swift
var [lazy] x = 1738 // Allocates an Int? behind the scenes, inited to nil
print(x) // Invokes the `lazy` getter, initializing the property
x = 679 // Invokes the `lazy` setter
```

Visible members of the behavior can also be accessed under
`property.[behavior]`:

```swift
x.[lazy].clear() // Invokes `lazy`'s `clear` method
```

### Delayed Initialization

A property behavior can model "delayed" initialization behavior, where the DI
rules for properties are enforced dynamically rather than at compile time.
This can avoid the need for implicitly-unwrapped optionals in multi-phase
initialization. We can implement both a mutable variant, which
allows for reassignment like a `var`:

```swift
public behavior var [delayedMutable] _: Value {
  private var value: Value? = nil

  get {
    guard let value = value else {
      fatalError("property accessed before being initialized")
    }
    return value
  }
  set {
    value = newValue
  }

  // Perform an explicit initialization, trapping if the
  // value is already initialized.
  public mutating func initialize(initialValue: Value) {
    if let _ = value {
      fatalError("property initialized twice")
    }
    value = initialValue
  }
}
```

and an immutable variant, which only allows a single initialization like
a `let`:

```swift
public behavior var [delayedImmutable] _: Value {
  private var value: Value? = nil

  get {
    guard let value = value else {
      fatalError("property accessed before being initialized")
    }
    return value
  }

  // Perform an explicit initialization, trapping if the
  // value is already initialized.
  public mutating func initialize(initialValue: Value) {
    if let _ = value {
      fatalError("property initialized twice")
    }
    value = initialValue
  }
}
```

This enables multi-phase initialization, like this:

```swift
class Foo {
  var [delayedImmutable] x: Int

  init() {
    // We don't know "x" yet, and we don't have to set it
  }

  func initializeX(x: Int) {
    self.x.[delayedImmutable].initialize(x) // Will crash if 'self.x' is already initialized
  }

  func getX() -> Int {
    return x // Will crash if 'self.x' wasn't initialized
  }
}
```

### Resettable properties

There's a common pattern in Cocoa where properties are used as optional
customization points, but can be reset to nil to fall back to a non-public
default value. In Swift, properties that follow this pattern currently must be
imported as ImplicitlyUnwrappedOptional, even though the property can only be
*set* to nil. If expressed as a behavior, the `reset` operation can be
decoupled from the type, allowing the property to be exported as non-optional:

```swift
public behavior var [resettable] _: Value = initialValue {
  var value: Value = initialValue

  get {
    return value
  }
  set {
    value = newValue
  }

  // Reset the property to its original initialized value.
  mutating func reset() {
    value = initialValue
  }
}
```

For example:


```
var [resettable] foo: Int = 22
print(foo) // => 22
foo = 44
print(foo) // => 44
foo.[resettable].reset()
print(foo) // => 22
```

### Property Observers

A property behavior can also approximate the built-in behavior of
`didSet`/`willSet` observers, by declaring support for custom accessors:

```swift
public behavior var [observed] _: Value = initialValue {
  var value = initialValue

  // A behavior can declare accessor requirements, the implementations of
  // which must be provided by property declarations using the behavior.
  // The behavior may provide a default implementation of the accessors, in
  // order to make them optional.

  // The willSet accessor, invoked before the property is updated. The
  // default does nothing.
  mutating accessor willSet(newValue: Value) { }

  // The didSet accessor, invoked before the property is updated. The
  // default does nothing.
  mutating accessor didSet(oldValue: Value) { }

  get {
    return value
  }

  set {
    willSet(newValue)
    let oldValue = value
    value = newValue
    didSet(oldValue)
  }
}
```

A common complaint with `didSet`/`willSet` is that the observers fire on
*every* write, not only ones that cause a real change. A behavior
that supports a `didChange` accessor, which only gets invoked if the property
value really changed to a value not equal to the old value, can be implemented
as a new behavior:

```swift
public behavior var [changeObserved] _: Value = initialValue {
  var value = initialValue

  mutating accessor didChange(oldValue: Value) { }

  get {
    return value
  }
  set {
    let oldValue = value
    value = newValue
    if oldValue != newValue {
      didChange(oldValue)
    }
  }
}
```

For example:

```swift
var [changeObserved] x = 1 {
  didChange { print("\(oldValue) => \(x)") }
}

x = 1 // Prints nothing
x = 2 // Prints 1 => 2
```

(Note that, like `didSet`/`willSet` today, neither behavior implementation
will observe changes through class references that mutate a referenced
class instance without changing the reference itself.)

### Synchronized Property Access

Objective-C supports `atomic` properties, which take a lock on `get` and `set`
to synchronize accesses to a property. This is occasionally useful, and it can
be brought to Swift as a behavior. The real implementation of `atomic`
properties in ObjC uses a global bank of locks, but for illustrative purposes
(and to demonstrate referring to `self`) I'll use a per-object lock instead:

```swift
// A class that owns a mutex that can be used to synchronize access to its
// properties.
public protocol Synchronizable: class {
  func withLock<R>(@noescape body: () -> R) -> R
}

// Behaviors can refer to a property's containing type using
// the implicit `Self` generic parameter. Constraints can be
// applied using a 'where' clause, like in an extension.
public behavior var [synchronized] _: Value = initialValue
    where Self: Synchronizable {
  var value: Value = initialValue

  get {
    return self.withLock {
      return value
    }
  }
  set {
    self.withLock {
      value = newValue
    }
  }
}
```

### `NSCopying`

Many Cocoa classes implement value-like objects that require explicit copying.
Swift currently provides an `@NSCopying` attribute for properties to give
them behavior like Objective-C's `@property(copy)`, invoking the `copy` method
on new objects when the property is set. We can turn this into a behavior:

```swift
public behavior var [copying] _: Value = initialValue {
  // Copy the value on initialization.
  var value: Value = initialValue.copy()

  get {
    return value
  }
  set {
    // Copy the value on reassignment.
    value = newValue.copy()
  }
}
```

This is a small sampling of the possibilities of behaviors. Let's look at the
proposed design in detail:

## Detailed design

### Property behavior declarations

A **property behavior declaration** is introduced by the `behavior var`
contextual keyword cluster. The declaration is designed to resemble the
syntax of a property using the behavior:

```text
property-behavior-decl ::=
  attribute* decl-modifier*
  'behavior' 'var' '[' identifier ']' // behavior name
  (identifier | '_')                  // property name binding
  ':' identifier                      // property type binding
  ('=' identifier)?                   // property initial value binding
  ('where' generic-constraints)?      // generic constraints
  '{'
    property-behavior-member-decl*
  '}'
```

Inside the behavior declaration, standard initializer, property, method, and
nested type declarations are allowed, as are **core accessor** declarations
—`get` and `set`. **Accessor requirement declarations** are also recognized
contextually within the declaration:

```text
property-behavior-member-decl ::= decl
property-behavior-member-decl ::= accessor-decl // get, set
property-behavior-member-decl ::= accessor-requirement-decl
```

### Bindings within Behavior Declarations

The property behavior declaration can declare bindings in the name, type,
and initializer positions of the `var`, which bind the corresponding
aspects of a property definition using the behavior:

- A `_` placeholder is required in the name position. (A future extension
  of behaviors may allow the property name to be bound as a string literal
  here.)
- An identifier in the type position is required, which binds to the type
  of the property as a generic parameter. This generic parameter can
  be constrained in a behavior's `where` clause, and can be used as a type
  in declarations inside the behavior.

- A behavior may optionally bind an identifier to the initializer expression
  used to initialize a property:

    ```swift
    behavior var [reevaluateOnEveryAccess] _: Value = initialValue {
      get {
        return initialValue
      }
    }
    ```

  This imposes an **initializer requirement** on the behavior. Any
  property using the behavior must be declared with an initial value;
  that initial value is coerced to the property's type and bound within
  the behavior as a computed, get-only property. The initial value expression
  is evaluated when the binding is semantically loaded from (in other words,
  when its getter is called).

Inside a behavior declaration, `self` is implicitly bound to the value that
contains the property instantiated using this behavior. For a freestanding
property at global or local scope, this will be the empty tuple `()`, and
for a static or class property, this will be the metatype. Within
the behavior declaration, the type of `self` is abstract and represented by the
implicit generic type parameter `Self`. Constraints can be placed on `Self`
in the generic signature of the behavior, to make protocol members available
on `self`:

```swift
protocol Fungible {
  typealias Fungus
  func funge() -> Fungus
}

behavior var [runcible] _: Value
    where Self: Fungible, Self.Fungus == Value
{
  get {
    return self.funge()
  }
}
```

Lookup within `self` is *not* implicit within behaviors and must always be
explicit, since unqualified lookup refers to the behavior's own members. `self`
is immutable except in `mutating` methods, where it is considered an `inout`
parameter unless the `Self` type has a class constraint.  `self` cannot be
accessed within inline initializers of the behavior's storage or in `init`
declarations, since these may run during the container's own initialization
phase.

Definitions within behaviors can refer to other members of the behavior by
unqualified lookup, or if disambiguation is necessary, by qualified lookup
on the behavior's name (since `self` is already taken to mean the containing
value):

```swift
behavior var [foo] _: Value {
  var x: Int

  init() {
    x = 1738
  }

  mutating func update(x: Int) {
    [foo].x = x // Disambiguate reference to behavior storage
  }
}
```


If the behavior includes *accessor requirement declarations*, then the
declared accessor names are bound as functions with labeled arguments:

```swift
behavior var [fakeComputed] _: Value {
  accessor get() -> Value
  mutating accessor set(newValue: Value)

  get {
    return get()
  }
  set {
    set(newValue: newValue)
  }
}
```

Note that the behavior's own *core accessor* implementations `get { ... }`
and `set { ... }` are *not* referenceable this way.

### Nested Types in Behaviors

Behavior declarations may nest type declarations as a namespacing mechanism.
As with other type declarations, the nested type cannot reference members
from its enclosing behavior.

### Properties and Methods in Behaviors

Behaviors may include property and method declarations. Any storage produced
by behavior properties is expanded into the containing scope of a property
using the behavior.

```swift
behavior var [runcible] _: Value {
  var x: Int = 0
  let y: String = ""
  ...
}
var [runcible] a: Int

// expands to:

var `a.[runcible].x`: Int
let `a.[runcible].y`: String
var a: Int { ... }
```

For public behaviors, this is inherently *fragile*, so
adding or removing storage is a breaking change. Resilience can be achieved
by using a resilient type as storage. The instantiated properties must also
be of types that are visible to potential users of the behavior, meaning
that public behaviors must use storage with types that are either public
or internal-with-availability, similar to the restrictions on inlineable
functions.

The properties and methods of the
behavior are accessible from properties using the behavior, if they
have sufficient visibility.

```swift
behavior var [runcible] _: Value {
  private var x: Int = 0
  var y: String = ""

  func foo() {}
}

// In a different file...

var [runcible] a: Int
_ = a.[runcible].x // Error, runcible.x is private
_ = a.[runcible].y // OK
a.runcible.foo() // OK
```

Method and computed property implementations have only immutable access to
`self` and their storage by default, unless they are `mutating`. (As with
computed properties, setters are `mutating` by default unless explicitly
marked `nonmutating`).

### `init` in Behaviors

The storage of a behavior must be initialized, either by inline initialization,
or by an `init` declaration within the initializer:

```swift
behavior var [inlineInitialized] _: Value {
  var x: Int = 0 // initialized inline
  ...
}

behavior var [initInitialized] _: Value {
  var x: Int

  init() {
    x = 0
  }
}
```

Behaviors can contain at most one `init` declaration, which must take no
parameters. This `init` declaration cannot take a visibility modifier; it
is always as visible as the behavior itself. Neither inline initializers nor
`init` declaration bodies may reference `self`, since they will be executed
during the initialization of a property's containing value.

### Accessor Requirement Declarations

An *accessor requirement declaration* specifies that a behavior requires
any property declared to use the behavior to provide an accessor
implementation. An accessor requirement declaration is introduced by the
contextual `accessor` keyword:

```swift
accessor-requirement-decl ::=
  attribute* decl-modifier*
  'accessor' identifier function-signature function-body?
```

An accessor requirement declaration looks like, and serves a similar role to,
a function requirement declaration in a protocol. A property using the
behavior must supply an implementation for each of its accessor requirements
that don't have a default implementation. The accessor names (with labeled
arguments) are bound as functions within the behavior declaration:

```swift
// Reinvent computed properties
behavior var [foobar] _: Value {
  accessor foo() -> Value
  mutating accessor bar(bas: Value)

  get { return foo() }
  set { bar(bas: newValue) }
}

var [foobar] foo: Int {
  foo {
    return 0
  }
  bar {
    // Parameter gets the name 'bas' from the accessor requirement
    // by default, as with built-in accessors today.
    print(bas)
  }
}

var [computed] bar: Int {
  get {
    return 0
  }
  set(myNewValue) {
    // Parameter name can be overridden as well
    print(myNewValue)
  }
}
```

Accessor requirements can be made optional by specifying a default
implementation:

```swift
// Reinvent property observers
behavior var [observed] _: Value = initialValue {
  init() {
    value = initialValue
  }
  mutating accessor willSet(newValue: Value) {
    // do nothing by default
  }
  mutating accessor didSet(oldValue: Value) {
    // do nothing by default
  }

  get {
    return value
  }
  set {
    willSet(newValue: newValue)
    let oldValue = value
    value = newValue
    didSet(oldValue: oldValue)
  }
}
```

Accessor requirements cannot take visibility modifiers; they are always as
visible as the behavior itself.

Like methods, accessors are not allowed to mutate the storage of the behavior
or `self` unless declared `mutating`. Mutating accessors can only be invoked
by the behavior from other `mutating` contexts.

### Core Accessor Declarations

The behavior implements the property by defining its *core accessors*,
`get` and optionally `set`. If a behavior only provides a getter, it
produces read-only properties; if it provides both a getter and setter, it
produces mutable properties (though properties that instantiate the behavior
may still control the visibility of their setters). It is an error if
a behavior declaration does not provide at least a getter.

### Using Behaviors in Property Declarations

Property declarations gain the ability to instantiate behavior,
with arbitrary accessors:

```text
property-decl ::= attribute* decl-modifier* core-property-decl
core-property-decl ::=
  ('var' | 'let') behavior? pattern-binding
  ((',' pattern-binding)+ | accessors)?
behavior ::= '[' visibility? decl-ref ']'
pattern-binding ::= var-pattern (':' type)? inline-initializer?
inline-initializer ::= '=' expr
accessors ::= '{' accessor+ '}' | brace-stmt // see notes about disambiguation
accessor ::= decl-modifier* decl-ref accessor-args? brace-stmt
accessor-args ::= '(' identifier (',' identifier)* ')'
```

For example:

```swift
public var [behavior] prop: Int {
  accessor1 { body() }
  behavior.accessor2(arg) { body() }
}
```

If multiple properties are declared in the same declaration, the behavior
apply to every declared property. `let` properties cannot yet use behaviors.

If the behavior requires
accessors, the implementations for those accessors are taken from the
property's accessor declarations, matching by name. To support future
composition of behaviors, the accessor definitions can use
qualified names `behavior.accessor`.  If an accessor requirement takes
parameters, but the definition in for the property does not explicitly name
parameters, the parameter labels from the behavior's accessor requirement
declaration are implicitly bound by default.

```swift
behavior var [foo] _: Value {
  accessor bar(arg: Int)
  ...
}

var [foo] x: Int {
  bar { print(arg) } // `arg` implicitly bound
}

var [foo] x: Int {
  bar(myArg) { print(myArg) } // `arg` explicitly bound to `myArg`
}
```

If any accessor definition in the property does not match up to a behavior
requirement, it is an error.

The shorthand for get-only computed properties is only allowed for computed
properties that use no behaviors. Any property that uses behaviors with
accessors must name all those accessors explicitly.

If a property with behaviors declares an inline initializer, the initializer
expression is captured as the implementation of a computed, get-only property
which is bound to the behavior's initializer requirement. If the behavior
does not have a behavior requirement, then it is an error to use an inline
initializer expression. Conversely, it is an error not to provide an
initializer expression to a behavior that requires one.

Under this proposal, even if a property with a behavior has an initial value
expression, the type is always required to be explicitly declared. Behaviors
also do not allow for out-of-line initialization of properties. Both of these
restrictions can be lifted by future extensions; see the **Future directions**
section below.

### Accessing Behavior Members on Properties

A behavior's properties and methods can be accessed on properties using the
behavior under `property.[behavior]`:

```swift
behavior var [foo] _: Value = initial {
  var storage: Value = initial
  func method() { }
  get { return storage }
}

var [foo] x: Int = 0
print(x.[foo].storage)
x.[foo].method()
```

To access a behavior member, code must have visibility of both the property's
behavior, and the behavior's member. Behaviors are `private` by default,
unless declared with a higher visibility. A behavior cannot be more visible
than the property it applies to.

```swift
// foo.swift
behavior var [foo] _: Value = initial {
  private var storage: Value = initial
  func method() { }
  get { return storage }
}


// bar.swift
var [foo] bar: Int
var [internal foo] internalFoo: Int
var [public foo] publicFoo: Int // Error, behavior more visible than property

_ = bar.[foo].storage // Error, `storage` is private to behavior
bar.[foo].method() // OK

// bas.swift
bar.[foo].method() // Error, `foo` behavior is private
internalFoo.[foo].method() // OK
```

Methods, properties, and nested types within the behavior can be accessed.
It is not allowed to access a behavior's `init` declaration, initializer
or accessor requirements, or core accessors from outside the behavior
declaration.

## Impact on existing code

By itself, this is an additive feature that doesn't impact
existing code. However, it potentially obsoletes `lazy`, `willSet`/`didSet`,
and `@NSCopying` as hardcoded language features.  We could grandfather these
in, but my preference would be to phase them out by migrating them to
library-based property behavior implementations. (Removing them should be its
own separate proposal, though.)

## Alternatives considered

### Using a protocol (formal or not) instead of a new declaration

A previous iteration of this proposal used an informal instantiation
protocol for property behaviors, desugaring a behavior into function calls, so
that:

```swift
var [lazy] foo = 1738
```

would act as sugar for something like this:

```swift
var `foo.[lazy]` = lazy(var: Int.self, initializer: { 1738 })
var foo: Int {
  get {
    return `foo.[lazy]`[varIn: self,
                        initializer: { 1738 }]
  }
  set {
    `foo.[lazy]`[varIn: self,
                 initializer: { 1738 }] = newValue
  }
}
```

There are a few disadvantages to this approach:

- Behaviors would pollute the namespace, potentially with multiple global
  functions and/or types.
- In practice, it would require every behavior to be implemented using a new
  (usually generic) type, which introduces runtime overhead for the type's
  metadata structures.
- The property behavior logic ends up less clear, being encoded in
  unspecialized language constructs.
- Determining the capabilities of a behavior relied on function overload
  resolution, which can be fiddly, and would require a lot of special case
  diagnostic work to get good, property-oriented error messages out of.
- Without severely complicating the informal protocol, it would be difficult to
  support eager vs. deferred initializers, or allow mutating access to
  `self` concurrently with the property's own storage without violating `inout`
  aliasing rules. The code generation for standalone behavior decls can hide
  this complexity.

Making property behaviors a distinct declaration undeniably increases the
language size, but the demand for something like behaviors is clearly there.
In return for a new declaration, we get better namespacing, more
efficient code generation, clearer, more descriptive code for their
implementation, and more expressive power with better diagnostics. I argue that
the complexity can pay for itself, today by eliminating several special-case
language features, and potentially in the future by generalizing to other kinds
of behaviors (or being subsumed by an all-encompassing macro system). For
instance, a future `func behavior` could conceivably provide Python
decorator-like behavior for transforming function bodies.

### Declaration syntax

Alternatives to the proposed `var [behavior] propertyName` syntax include:

- A different set of brackets, `var (behavior) propertyName` or
  `var {behavior} propertyName`. Parens have the problem of being ambiguous
  with a tuple `var` declaration, requiring lookahead to resolve. Square
  brackets also work better with other declarations behaviors could be extended
  to apply to in the future, such as subscripts or functions
- An attribute, such as `@behavior(lazy)` or `behavior(lazy) var`.
  This is the most conservative answer, but is clunky.
- Use the behavior function name directly as an attribute, so that e.g. `@lazy`
  works.
- Use a new keyword, as in `var x: T by behavior`.
- Something on the right side of the colon, such as `var x: lazy(T)`.  To me
  this reads like `lazy(T)` is a type of some kind, which it really isn't.
- Something resembling the lookup syntax, such as `var x.[lazy]: T`.

### Syntax for accessing the backing property

The proposal suggests `x.[behaviorName]` for accessing the underlying backing
property of `var [behaviorName] x`.  Some alternatives to consider:

- Reserving a keyword and syntactic form to refer to the backing property, such
  as `foo.x.behavior` or `foo.behavior(x)`. The problems with this are that
  reserving a keyword is undesirable, and that `behavior` is a vague term that
  requires more context for a reader to understand what's going on. If we
  support multiple behaviors on a property, it also doesn't provide a mechanism
  to distinguish between behaviors.
- Doing member lookup in both the property's type and its behaviors (favoring
  the declared property when there are conflicts). If `foo` is known to be
  `lazy`, it's attractive for `foo.clear()` to Just Work without additional
  syntax.  This has the usual ambiguity problems of overloading, of course; if
  the behavior's members are shadowed by the fronting type, something would be
  necessary to disambiguate.
- Treat the behavior name alone as a member of the property, so that
  `foo.lazy.clear()` works. This reduces the surface area for potential
  namespace collision, but still fundamentally has the same disambiguation
  problems as the previous alternative.

## Future directions

The functionality proposed here is quite broad, so to attempt to minimize
the review burden of the initial proposal, I've factored out several
aspects for separate consideration:

### Behaviors for immutable `let` properties

Since we don't have an effects system (yet?), `let` behavior implementations
have the potential to invalidate the immutability assumptions expected of `let`
properties, and it would be the programmer's responsibility to maintain them.
We don't support computed `let`s for the same reason, so I suggest leaving
`let`s out of property behaviors for now.  `let behavior`s could be added in
the future when we have a comprehensive design for immutable computed
properties and/or functions.

### Type inference of properties with behaviors

There are subtle issues with inferring the type of a property using a behavior
when the behavior introduces constraints on the property type. If you have
something like this:

```swift
behavior var [uint16only] _: Value where Value == UInt16 { ... }

var [uint16only] x = 1738
```

there are two, and possibly more, ways to define what happens:

- We type-check the initializer expression in isolation *before* resolving
  behaviors. In this case, `1738` would type-check by defaulting to `Int`,
  and then we'd raise an error instantiating the `uint16only` behavior,
  which requires a property to have type `UInt16`.
- We apply the behaviors *before* type-checking the initializer expression,
  introducing generic constraints on the contextual type of the initializer.
  In this case, applying the `uint16only` behavior would constrain the
  contextual type of the initializer to `UInt16`, and we'd successfully
  type-check the literal as a `UInt16`.

There are merits and downsides to both approaches. To allow these issues to
be given proper consideration, I'm subsetting them out by proposing to
first require that properties with behaviors always declare an explicit type.

### Composing behaviors

It is useful to be able to compose behaviors, for instance, to have a
lazy property with observers that's also synchronized. Relatedly, it is
useful for subclasses to be able to `override` their inherited properties
by applying behaviors over the base class implementation, as can be done
with `didSet` and `willSet` today. Linear composition can be supported by
allowing behaviors to stack, each referring to the underlying property
beneath it by `super` or some other magic binding. However, this form
of composition can be treacherous, since it allows for "incorrect"
compositions of behaviors. One of `lazy • synchronized` or
`synchronized • lazy` is going to do the wrong thing. This possibility
can be handled somewhat by allowing certain compositions to be open-coded;
John McCall has suggested allowing `behavior var [lazy, synchronized]` to
work and define the behavior implementation of `lazy` and `synchronized`
composed distinct from their individual implementations. That of course
has an obvious exponential explosion problem; it's infeasible to anticipate
and hand-code every useful combination of behaviors. These issues deserve
careful separate consideration, so I'm leaving behavior composition out of this
initial proposal.

### Deferred evaluation of initialization expressions

This proposal does not suggest changing the allowed operations inside
initialization expressions; in particular, an initialization of an
instance property may not refer to `self` or other instance properties or
methods, due to the potential for the expression to execute before the
value is fully initialized:

```swift
struct Foo {
  var a = 1
  var b = a // Not allowed
  var c = foo() // Not allowed

  func foo() { }
}
```

This is inconvenient for behaviors like `lazy` that only ever evaluate the
initial value expression after the true initialization phase has completed,
and where it's desirable to reference `self` to lazily initialize.
Behaviors could be extended to annotate the initializer as "deferred",
which would allow the initializer expression to refer to `self`, while
preventing the initializer expression from being evaluated at initialization
time. (If we consider behaviors to be essentially always fragile, this could
be inferred from the behavior implementation.)

### Out-of-line initialization with behaviors

This proposal also does not allow for behaviors that support out-of-line
initialization, as in:

```swift
func foo() {
  // Out-of-line local variable initialization
  var [behavior] x: Int
  x = 1
}

struct Foo {
  var [behavior] y: Int

  init() {
    // Out-of-line instance property initialization
    y = 1
  }
}
```

This is a fairly serious limitation for instance properties. There are a few
potential approaches we can take. One is to allow a behavior's `init`
logic to take an out-of-line initialization as a parameter, either
directly or by having a different constraint on the initializer requirement
that *only* allows it to be referred to from `init`
(the opposite of "deferred"). It can also be supported indirectly by
linear behavior composition, if the default root `super` behavior for a stack
of properties defaults to a plain old stored property, which can then follow
normal initialization rules. This is similar to how `didSet`/`willSet`
behave today. However, this would not allow behaviors to change the
initialization behavior in any way.

### Binding the name of a property using the behavior

There are a number of clever things you can do with the name of a property
if it can be referenced as a string, such as using it to look up a value in
a map, to log, or to serialize. The declaration-follows-use syntax proposed
here naturally extends to allowing a behavior to bind the name as a string
(and/or potentially as a projection function):

```swift
behavior var [echo] name: Value where Value: StringLiteralConvertible {
  get { return name }
}

var [echo] echo: String
print(echo) // => echo
```

### Extensions on behaviors

It might be interesting to allow behaviors to have new functionality added
via `extension`s. This feature would come with some runtime costs, however; any
`public` behavior on a property would have to export a vtable representing
that property's implementation of the behavior in order for extensions in
other modules to be able to interact with it. This fights the
"zero-cost abstraction" goal we have for the feature.

### Overloading behaviors

It may be useful for behaviors to be overloadable, for instance to give a
different implementation to computed and stored variants of a concept:

```swift
// A behavior for stored properties...
behavior var [foo] _: Value = initialValue
{
  var value: Value = initialValue
  get { ... }
  set { ... }
  }
}

// Same behavior for computed properties...
behavior var [foo] _: Value {
  accessor get() -> Value
  accessor set(newValue: Value)

  get { ... }
  set { ... }
}
```

We could resolve overloads by accessors, type constraints on `Value`, and/or
initializer requirements. However, determining what this overload signature
should be, and also the exciting interactions with type inference from
initializer expressions, should be a separate discussion.
