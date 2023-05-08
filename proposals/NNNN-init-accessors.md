# Init Accessors

* Proposal: [SE-NNNN](NNNN-init-accessors.md)
* Authors: [Holly Borla](https://github.com/hborla), [Doug Gregor](https://github.com/douggregor)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

Init accessors generalize the out-of-line initialization feature of property wrappers to allow any computed property on types to opt into definite initialization analysis, and subsume initialization of a stored property with custom initialization code.

## Motivation

Swift applies [definite initialization analysis](https://en.wikipedia.org/wiki/Definite_assignment_analysis) to stored properties, stored local variables, and variables with property wrappers. Definite initialization ensures that memory is initialized on all paths before it is accessed. A common pattern in Swift code is to use one property as backing storage for one or more computed properties, and abstractions like [property wrappers](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md) and now [attached macros](https://github.com/apple/swift-evolution/blob/main/proposals/0389-attached-macros.md) help facilitate this pattern. Under this pattern, the backing storage is an implementation detail, and most code works with the computed property, including initializers.

Property wrappers support bespoke definite initialization that allows initializing the backing property wrapper storage via the computed property, always re-writing initialization-via-wrapped-property in the form `self.value = value` to initialization of the backing storage in the form of `_value = Wrapper(wrappedValue: value)`:

```swift
@propertyWrapper
struct Wrapper<T> {
  var wrappedValue: T
}

struct S {
  @Wrapper var value: Int

  init(value: Int) {
    self.value = value  // Re-written to self._x = Wrapper(wrappedValue: value)
  }

  init(other: Int) {
    self._value = Wrapper(wrappedValue: other) // Okay, initializes storage '_x' directly
  }
}
```

The ad-hoc nature of property wrapper initializers mixed with an exact definite initialization pattern prevent property wrappers with additional arguments from being initialized out-of-line. Furthermore, property-wrapper-like macros cannot achieve the same initializer usability, because any backing storage variables added must be initialized directly instead of supporting initialization through computed properties. For example, the proposed [`@Observable` macro](https://github.com/apple/swift-evolution/blob/main/proposals/0395-observability.md) applies a property-wrapper-like transform that turns stored properties into computed properties backed by the observation APIs, but it provides no way to write an initializer using the original property names like the programmer expects:

```swift
@Observable
struct Proposal {
  var title: String
  var text: String

  init(title: String, text: String) {
    self.title = title // error: 'self' used before all stored properties are initialized
    self.text = text // error: 'self' used before all stored properties are initialized
  } // error: Return from initializer without initializing all stored properties
}
```

## Proposed solution

This proposal adds _`init` accessors_ to opt computed properties on types into virtual initialization that subsumes initialization of a set of zero or more specified stored properties, which allows assigning to computed properties in the body of a type's initializer:

```swift
struct Angle {
  var degrees: Double
  var radians: Double {
    init(newValue, initializes: degrees) {
      degrees = newValue * 180 / .pi
    }

    get { degrees * .pi / 180 }
    set { degrees = newValue * 180 / .pi }
  }

  init(degrees: Double) {
    self.degrees = degrees // sets 'self.degrees' directly
  }

  init(radians: Double) {
    self.radians = radians // calls init accessor with 'radians'
  }
}
```

The signature of an `init` accessor specifies up to two sets of stored properties: the access dependencies (via `accesses`) and the initialized properties (via `initializes`). Access dependencies specify the other stored properties that can be accessed from within the `init` accessor (no other uses of `self` are allowed), and therefore must be initialized before the computed property's `init` accessor is invoked. The `init` accessor must initialize each of the initialized stored properties on all control flow paths. The `radians` property in the example above specifies no access dependencies, but initializes the `degrees` property, so it specifies only `initializes: degrees`.

Access dependencies allow a computed property to be initialized by placing its contents into another stored property:

```swift
struct ProposalViaDictionary {
  private var dictionary: [String: String] = [:]

  var title: String {
    init(newValue, accesses: dictionary) {
      dictionary["title"] = newValue
    }

    get { dictionary["title"]! }
    set { dictionary["title"] = newValue }
  }

   var text: String {
    init(newValue, accesses: dictionary) {
      dictionary["text"] = newValue
    }

    get { dictionary["text"]! }
    set { dictionary["text"] = newValue }
  }

  init(title: String, text: String) {
    self.title = title // calls init accessor to insert title into the dictionary
    self.text = text   // calls init accessor to insert text into the dictionary

    // it is an error to omit either initialization above
  }
}
```

Both `init` accessors document that they access `dictionary`, which allows them to insert the new values into the dictionary with the appropriate key as part of initialization. This allows one to fully abstract away the storage mechanism used in the type.

With this proposal, property wrappers have no bespoke definite initialization support. Instead, the desugaring includes an `init` accessor for wrapped properties. The property wrapper code in the Motivation section will desugar to the following code:

```swift
@propertyWrapper
struct Wrapper<T> {
  var wrappedValue: T
}

struct S {
  private var _value: Wrapper<Int>
  var value: Int {
    init(newValue, initializes: _value) {
      self._value = Wrapper(wrappedValue: newValue)
    }

    get { _value.wrappedValue }
    set { _value.wrappedValue = newValue }
  }

  init(value: Int) {
    self.value = value  // Calls 'init' accessor on 'value'
  }
}
```

This proposal allows macros to model the following property-wrapper-like patterns including out-of-line initialization of the computed property:
* A wrapped property with attribute arguments
* A wrapped property that is backed by an explicit stored property
* A set of wrapped properties that are backed by a single stored property

## Detailed design

### Syntax

This proposal adds new syntax for `init` accessor blocks, which can be written in the accessor list of a computed property. Init accessors add the following production rules to the grammar:

```
init-accessor -> 'init' init-accessor-signature[opt] function-body

init-accessor-signature -> '(' init-dependency-clause [opt] ')'

init-dependency-clause -> identifier
init-dependency-clause -> identifier ',' init-dependencies
init-dependency-clause -> init-dependencies

init-dependencies -> initializes-list
init-dependencies -> initializes-list ',' accesses-list
init-dependences -> access-list

initializes-list -> 'initializes' ':' identifier-list

accesses-list -> 'accesses' ':' identifier-list

identifier-list -> identifier
identifier-list -> identifier ',' identifier-list

// Not actually sure if `get` and `set` appearing once is baked into the grammar or is a semantic restriction
accessor-block -> init-accessor
```

The `identifier` in an `init-dependency-clause`, if provided, is the name of the parameter that contains the initial value. If not provided, a parameter with the name `newValue` is automatically created.

### `init` accessor signatures

`init` accessor declarations can optionally specify a signature. An `init` accessor signature is composed of a parameter for the initial value, a list of stored properties that are initialized by this accessor specified with the `initializes:` label, and a list of stored properties that are accessed by this accessor specified with the `accesses:` labe, all of which are optional:

```swift
struct S {
  var readMe: String

  var _x: Int

  var x: Int {
    init(newValue, initializes: _x, accesses: readMe) {
      print(readMe)
      _x = newValue
    }

    get { _x }
    set { _x = newValue }
  }
}
```

If the accessor uses the default parameter name `newValue` and neither initializes nor accesses any stored property, the signature is not required.

Init accessors can subsume the initialization of a set of stored properties. Subsumed stored properties are specified through the `initializes:` clause of the accessor signature. The body of an `init` accessor is required to initialize the subsumed stored properties on all control flow paths.

Init accessors can also require a set of stored properties to already be initialized when the body is evaluated, which are specified through the `accesses:` cause of the signature. These stored properties can be accessed in the accessor body; no other properties or methods on `self` are available inside the accessor body, nor is `self` available as a whole object (i.e., to call methods on it).

### Definite initialization of properties on `self`

The semantics of an assignment inside of a type's initializer depend on whether or not all of `self` is initialized on all paths at the point of assignment. Before all of `self` is initialized, assignment to a computed property with an `init` accessor is re-written to an `init` accessor call; after `self` has been initialized, assignment to a computed property is re-written to a setter call.

With this proposal, all of `self` is initialized if:
* All stored properties are initialized on all paths, and
* All computed properties with `init` accessors are virtually initialized on all paths.

An assignment to a computed property with an `init` accessor before all of `self` is initialized will virtually initialize the computed property and initialize all of the stored properties specified in its `initializes` clause:

```swift
struct S {
  var x1: Int
  var x2: Int
  var computed: Int {
    init(newValue, initializes: x1, x2) { ... }
  }

  init() {
    self.computed = 1 // initializes 'computed', 'x1', and 'x2'; 'self' is now fully initialized
  }
}
```

An assignment to a stored property before all of `self` is initialized will initialize that stored property. When all of the stored properties listed in the `initializes:` clause of a computed property with an `init` accessor have been initialized, that computed property is virtually initialized:

```swift
struct S {
  var x1: Int
  var x2: Int
  var x3: Int
  var computed: Int {
    init(newValue, initializes: x1, x2) { ... }
  }

  init() {
    self.x1 = 1 // initializes 'x1'; neither 'x2' or 'computed' is initialized
    self.x2 = 1 // initializes 'x2' and 'computed'
    self.x3 = 1 // initializes 'x3'; 'self' is now fully initialized
  }
}
```

An assignment to a computed property where at least one of the stored properties listed in `initializes:` is initialized, but `self` is not initialized, is an error. This prevents double-initialization of the underlying stored properties:

```swift
struct S {
  var x: Int
  var y: Int
  var point: (Int, Int) {
    init(newValue, initializes: x, y) {
	    (self.x, self.y) = newValue
    }
    get { (x, y) }
    set { (x, y) = newValue }
  }

  init(x: Int, y: Int) {
    self.x = x // Only initializes 'x'
    self.point = (x, y) // error: neither the `init` accessor nor the setter can be called here
  }
}
```

### Memberwise initializers

If a struct does not declare its own initializers, it receives an implicit memberwise initializer based on the stored properties of the struct, because the storage is what needs to be initialized. Because `init` provide a preferred mechanism for initializing storage, the memberwise initializer parameter list will include any computed properties that subsume the initialization of stored properties instead of parameters for those stored properties.

```swift
struct S {
  var _x: Int
  var x: Int {
    init(newValue, initializes: _x) {
      _x = newValue
    }

    get { _x }
    set { _x = newValue }
  }

  var y: Int  
}

S(x: 10, y: 100)
```

The above struct `S` receives a synthesized initializer:

```swift
init(x: Int, y: Int) {
  self.x = x
  self.y = y
}
```

A memberwise initializer cannot be synthesized if a stored property that is an `accesses:` dependency of a computed property is ordered after that computed property in the source code:

```swift
struct S {
  var _x: Int
  var x: Int {
    init(newValue, initializes: _x, reads: y) {
      _x = newValue
    }

    get { _x }
    set { _x = newValue }
  }

  var y: Int 
}
```

The above struct would receive the following memberwise initializer, which is invalid so an error is emitted:

```swift
init(x: Int, y: Int) {
  self.x = x // error
  self.y = y
}
```

TODO: define whether macro-generated members are ordered before or after their 'attached-to' declaration for peer macros, or before or after the full member list for member macros.

## Source compatibility

`init` accessors are an additive capability with new syntax; there is no impact on existing source code.

## ABI compatibility

`init` accessors are only called from within a module, so they are not part of the module's ABI. In cases where a type's initializer is `@inlinable`, the body of an `init` accessor must also be inlinable.

## Implications on adoption

Because `init` accessors are always called from within the defining module, adopting `init` accessors is an ABI-compatible change. Adding an `init` accessor to an existing property also cannot have any source compatibility impact outside of the defining module; the only possible source incompatibilities are on the generated memberwise initializer (if new entries are added), or on the type's `init` implementation (if new initialization dependencies are added).

## Future directions

### `init` accessors for local variables

`init` accessors for local variables have different implications on definite initialization, because re-writing assignment to `init` or `set` is not based on the initialization state of `self`. Local variable getters and setters can also capture any other local variables in scope, which raises more challenges for diagnosing escaping uses before initialization during the same pass where assignments may be re-written to `init` or `set`. As such, local variables with `init` accessors are a future direction.
