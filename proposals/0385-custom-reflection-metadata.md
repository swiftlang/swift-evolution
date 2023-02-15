# Custom Reflection Metadata

* Proposal: [SE-0385](0385-custom-reflection-metadata.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin), [Holly Borla](https://github.com/hborla), [Alejandro Alonso](https://github.com/Azoy), [Stuart Montgomery](https://github.com/stmontgomery)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Active review (January 24, 2023...February 7, 2023)**
* Implementation: [PR#1](https://github.com/apple/swift/pull/62426), [PR#2](https://github.com/apple/swift/pull/62738), [PR#3](https://github.com/apple/swift/pull/62818), [PR#4](https://github.com/apple/swift/pull/62850), [PR#5](https://github.com/apple/swift/pull/62920), [PR#6](https://github.com/apple/swift/pull/63057)

## Introduction

In Swift, declarations are annotated with attributes to opt into both built-in language features (e.g. `@available`) and library functionality (e.g. `@RegexComponentBuilder`). This proposal introduces the ability to attach library-defined reflection metadata to declarations using custom attributes, which can then be queried by the library to opt client code into library functionality.

Previous Swift Forum discussions

* [Custom attributes](https://forums.swift.org/t/custom-attributes/13976)
* [Pitch: introduce custom attributes](https://forums.swift.org/t/pitch-introduce-custom-attributes/21335)

## Motivation

There are some problem domains in which it can be beneficial for a library author to let a client annotate within their own code certain declarations that the library should be made aware of, since requiring the client call an explicit API instead would be too onerous, repetitive, or easy to forget.

One classic example is **testing**: there is a common pattern in unit testing libraries where users define a type that extends one of the library's types, they annotate some of its methods as tests, and the library locates, initializes, and runs all tests automatically. There is no official mechanism in Swift to implement this test discovery pattern today, however XCTest—the language's current de-facto standard test library—has longstanding workarounds:

* On Apple platforms, XCTest relies on the Objective-C runtime to enumerate all subclasses of a known base class and their methods, and it considers all instance methods with a supported signature and name prefixed with "test" a test method.
* On other platforms, XCTest is typically used from a package, and the Swift Package Manager has special logic to introspect build-time indexer data, locate test methods, and explicitly pass the list of discovered tests to XCTest to run.

XCTest's current approach has some drawbacks and limitations:

* Users must adhere to a strict naming convention by prefixing all test methods with the word "test". This prefix can be redundant since all tests include it, and may surprise users if they accidentally use that prefix on a non-test method since the behavior is implicit.
* Since tests are declared implicitly, there is no way for a user to provide additional details about an individual test or group of tests. It would be useful to have a way to indicate whether a test is enabled, its requirements, or other metadata, for example, so that the testing library could use this information to inform how it executes tests and offer more powerful features.
* The lack of a built-in runtime discovery mechanism means that related tools (such as Swift Package Manager) require specialized discovery logic for each test library they support. This makes adding support for alternate test libraries to those tools very difficult and increases their implementation complexity.

Registering code to be discovered by a framework is a common pattern across Swift programs. For example, a program that uses a plugin architecture commonly uses a protocol for the interface of the plugin, which is then implemented on concrete types in clients. This pattern imposes error-prone registration boilerplate, where clients must explicitly supply a list of concrete plugin types or explicitly register individual plugin types to be used by the framework before the framework needs them.

More generally, annotating parts of a program with metadata to be used by other parts of the program has use-cases beyond registration patterns. Consider the `Persisted` property wrapper from the [Realm](https://github.com/realm/realm-swift) package:

```swift
@propertyWrapper
public struct Persisted<Value: _Persistable> { ... }

class Dog: Object {
  @Persisted var name: String
  @Persisted var age: Int
}
```

To support [advanced schema customization](https://forums.swift.org/t/se-0385-custom-reflection-metadata/62777/19), the property wrapper could store a string that provides a custom name for the underlying database column, specified in the attribute arguments, e.g. `@Persisted(named: "CustomName")`. However, storing this metadata in the property wrapper requires additional storage for each _instance_ of the containing type, even though the metadata value is fixed for the declaration the property wrapper is attached to. In addition to higher memory overload, the metadata values are evaluated eagerly, and for each instantiation of the containing type, rendering property-wrapper instance metadata too expensive for this use case.


## Proposed solution

* A new built-in attribute `@reflectionMetadata` that can be applied to structs, enums, classes, and actors.
* Types annotated with this built-in attribute can be used as custom attributes on declarations that can be used as values.
    * The custom attribute can have additional arguments; the custom attribute application will turn into an initializer call on the attribute type, passing in the declaration value as the first argument.
* A reflection API that can gather all declarations with a given custom attribute attached, which lazily constructs the metadata values when invoked.

Combined with [attached macros](https://forums.swift.org/t/pitch-attached-macros/62812), the `@Persisted` property wrapper in Realm can evolve into a macro attached to persistent types, combined with custom metadata attributes that provide schema customization for specific declarations:

```swift
@reflectionMetadata
struct Named {
  let name: String

  init<T: _Persistable>(attachedTo: T.Type, _ name: String) {
    self.name = name
  }
}

@Persisted
class Dog: Object {
  var name: String
  @Named("CustomName") var age: Int
}
```

This approach completely eliminates initialization overhead of using property wrappers, provides separate storage of custom metadata values, and enables lazy initialization of metadata values that is only invoked when the framework requests the metadata.

## Detailed design

### Declaring reflection metadata attributes

Reflection metadata custom attributes are declared by attaching the built-in `@reflectionMetadata` attribute to a nominal type, i.e. a struct, enum, class, or actor:

```swift
@reflectionMetadata
struct Example { ... }
```

A reflection metadata type must have a synchronous initializer of the form `init(attachedTo:)`. The type of the `attachedTo:` parameter dictates which types of declarations the custom attribute can be applied to, as described in the following section.

### Applications of reflection metadata types

Reflection metadata custom attributes can be applied to any declaration that can be used as a first-class value in Swift, including:

* Types
* Global functions
* Static methods
* Instance methods, both non-mutating and mutating
* Instance properties

Reflection metadata types opt into which kinds of declarations are supported based on their initializer overloads which begin with a parameter labeled `attachedTo:`. For an application of a reflection metadata attribute to be well-formed, the reflection metadata type must declare an initializer that accepts the appropriate value as the first argument. Applications of a reflection metadata type to a declaration will synthesize an initializer call with the attribute arguments, and the declaration value passed as the first initializer argument:

* Types will pass a metatype.
* Global functions will pass an unapplied function reference.
* Static methods on a type `T` will pass a function which calls the method on the metatype `T.Type` passed as the first parameter.
* Instance methods on a type `T` will pass a function which calls the method on an instance `T` passed as the first parameter. The function will support `mutating` instance methods when the first parameter is declared `inout T`.
* Instance properties will pass a key-path.

```swift
@reflectionMetadata
struct Flag {
  // Initializer that accepts a metatype of a nominal type
  init<T>(attachedTo: T.Type) {
    // ...
  }
  
  // Initializer that accepts an unapplied reference to a global function
  init<Args, Result>(attachedTo: (Args) -> Result) {
    // ...
  }
  
  // Initializer that accepts a function which calls a static method
  init<T, Args, Result>(attachedTo: (T.Type, Args) -> Result) {
    // ...
  }
  
  // Initializer that accepts a function which calls an instance method
  init<T, Args, Result>(attachedTo: (T, Args) -> Result) {
    // ...
  }
  
  // Initializer that accepts a function which calls a mutating instance method
  init<T, Args, Result>(attachedTo: (inout T, Args) -> Result) {
    // ...
  }
  
  // Initializer that accepts a reference to an instance property
  init<T, V>(attachedTo: KeyPath<T, V>, custom: Int) {
    // ...
  }
}

// The compiler will synthesize the following initializer call
// -> Flag.init(attachedTo: doSomething)
@Flag func doSomething(_: Int, other: String) {}

// The compiler will synthesize the following initializer call
// -> Flag.init(attachedTo: Test.self)
@Flag
struct Test {
  // The compiler will synthesize the following initializer call
  // -> Flag.init(attachedTo: { metatype in metatype.computeStateless() })
  @Flag static func computeStateless() {}
  
  // The compiler will synthesize the following initializer call
  // -> Flag.init(attachedTo: { instance, values in instance.compute(values: values) })
  @Flag func compute(values: [Int]) {}
  
  var state = 1
  
  // The compiler will synthesize the following initializer call
  // -> Flag.init(attachedTo: { (instance: inout Test) in instance.incrementState() })
  @Flag mutating func incrementState() {
    state += 1
  }
  
  // The compiler will synthesize the following initializer call
  // -> Flag.init(attachedTo: \Test.answer, custom: 42)
  @Flag(custom: 42) var answer: Int = 42
}
```

#### Restrictions on custom reflection metadata application

A given declaration can have multiple reflection metadata attributes as long as a given reflection metadata type only appears once:

```swift
@Flag @Ignore func ignored() { 🟢
  // ...
}

@Flag @Flag func specialFunction() { 🔴
      ^ error: duplicate reflection metadata attribute
  // ...
}
```

Reflection metadata attributes must be applied at either the primary declaration of a type or in an unavailable unconstrained extension of the type within the same module as the type’s primary declaration. Unavailable extensions are supported to allow API implementers a way to opt-out from an attribute. Applying the attribute to a type in an available/constrained extension or in extension outside its module is prohibited to prevent the same type from having multiple reflection metadata annotations of the same type.

```swift
@available(*, unavailable)
@Flag extension MyType { 🟢 if extension is in the same module
}
```

```swift
@Flag extension MyType { 🔴
 ^ error: cannot associate reflection metadata @Flag with MyType in extension
}
```

```swift
@Flag extension MyType where ... { 🔴
 ^ error: cannot associate reflection metadata @Flag with MyType in constrained extension
}
```

Declarations with custom reflection metadata attributes must be fully concrete:

```swift
struct GenericType<T> {
  @Flag
  var genericValue: T 🔴
  ^ error
}

extension GenericType where T == Int {
  @Flag
  var concreteValue: Int // okay
}
```

Generic declarations cannot be discovered through the Reflection query that gathers all instances of reflection metadata, because generic values cannot be represented in a higher-kinded way in Swift; generic values must always have substitutions at runtime. Generic declarations could be supported in the future by adding reflection queries for the other direction, e.g. a query to return the custom reflection metadata for a given key-path `\Generic<Int>.value`.


### Inference of reflection metadata attributes

A reflection metadata attribute can be applied to a protocol:

```swift
@EditorCommandRecord
protocol EditorCommand { /* ... */ }
```

Conceptually, the reflection metadata attribute is applied to the generic `Self` type that represents the concrete conforming type. When a protocol conformance is written at the primary declaration of a concrete type, the reflection metadata attribute is inferred:

```swift
// @EditorCommandRecord is inferred
struct SelectWordCommand: EditorCommand { /* ... */ }
```

If the protocol conformance is written in an extension on the conforming type, attribute inference is prohibited. A reflection metadata attribute applied to a protocol is a form of requirement, so such conformances declared in extensions are invalid unless the primary declaration already has the explicit reflection metadata attribute:

```swift
// Error unless the primary declaration of 'SelectWordCommand' has '@EditorCommandRecord'
extension SelectWordCommand : EditorCommand { 🔴
   // ...
}
```

Reflection metadata attributes applied to protocols cannot have additional attribute arguments; attribute arguments must be explicitly written on the conforming type.

A type which conforms to a protocol that has a reflection metadata attribute may specify the attribute explicitly. This can be useful if the reflection metadata type includes additional parameters in its `init(attachedTo: ...)` overload, since it allows the conforming type to pass arguments for those parameters:

```swift
// Overrides the inferred `@EditorCommandRecord` attribute from `EditorCommand`
@EditorCommandRecord(keyboardShortcut: "j", modifier: .command)
struct SelectWordCommand: EditorCommand { /* ... */ }
```

### Accessing metadata through Reflection

With the introduction of the new [Reflection](https://forums.swift.org/t/pitch-reflection/61438) module, we feel a natural place to reflectively retrieve these attributes is there. The following Reflection APIs provide the runtime query for custom reflection metadata:

```swift
/// Get all the instances of a custom reflection attribute wherever it's attached to.
///
/// - Parameters:
///   - type: The type of the attribute that is attached to various sources.
/// - Returns: A sequence of attribute instances of `type` in no particular
///   order.
public enum Attribute {
  public static func allInstances<T>(of type: T.Type) -> AttributeInstances<T>
}

/// A sequence wrapper over some runtime attribute instances.
///
/// Instances of `AttributeInstances` are created with the
/// `Attribute.allInstances(of:)` function.
public struct AttributeInstances<T> {}

extension AttributeInstances: IteratorProtocol {
  @inlinable
  public mutating func next() -> T?
}

extension AttributeInstances: Sequence {}
```

This API will retrieve all of the instances of your reflection attribute across all modules. Instances of metadata types are initialized in the Reflection query to gather the metadata. Attributes who are not available in the current running OS, i.e. because the `attachedTo` declaration is not available as described in the following section, will be excluded from the results.

### Magic literals in custom reflection metadata attributes

When custom reflection metadata type is accessed through the Reflection APIs, magic literals - `#function`, `#file`, `#line`, and `#column` associated with `init(attachedTo:)` would behave in a special way. Even though in such cases `init(attachedTo:)` is called from a special generator function `#function` literal is still going to point to the declaration attribute is attached to, and `#file`, `#line`, and `#column` are going to point to the attribute itself at the point of use or to the declaration if the attribute has been inferred.

**test.swift**

```swift
 1: @reflectionMetadata
 2: struct Flag {
 3:   init<T>(attachedTo: T.Type,
 4:           func: String = #function,
 5:           file: String = #file,
 6:           line: Int = #line,
 7:           column: Int = #column) {}
 8:
 9:   init<B, V>(attachedTo: KeyPath<B, V>,
10:              func: String = #function,
11:              file: String = #file,
12:              line: Int = #line,
13:              column: Int = #column) {}
14: }
15:
16: struct Test {
17:   @Flag var value: Int = 42
18: }
19:
20: @Flag
21: protocol Flagged {}
22:
23: struct InferredTest : Flagged {}
```

**other.swift**

```swift
1: let flags = Attribute.allInstances(of: Flag.self)
```

`Flag.init(attachedTo:)` associated with `Test.value` in this case is going to receive the following information:

* `#function` = `"value"`
* `#file` = `"test.swift"`
* `#line` = `17`
* `#column` = `4`

`Flag.init(attachedTo:)` for implicitly inferred attribute on `InferredTest` in this case is going to receive the following information:

* `#function` = `"InferredTest"`
* `#file` = `"test.swift"`
* `#line` = `23`
* `#column` = `1`

We think that this behavior provides the most benefit to the users because it preserves all of the information about attribute locations.


### API Availability

Custom metadata attributes can be attached to declarations with limited availability. The Reflection query for an individual instance of the metadata attribute type will be gated on a matching availability condition and will return `nil` for instances which are unavailable at runtime. For example:

```swift
@available(macOS 12, *)
@Flag
struct NewType { /* ... */ }
```

The Reflection query that produces the `Flag` instance attached to `NewType` will effectively execute the following code:

```swift
if #available(macOS 12, *) {
  return Flag(attachedTo: NewType.self)
} else {
  return nil
}
```

and if `nil` is returned, there will not be a `Flag` instance representing `NewType` included in the collection returned by `Attribute.allInstances(of:)`.

## Alternatives considered

### Extend other language features

Some reviewers of the original pitch suggested that the motivating use cases could be addressed through a combination of improved Reflection capabilities and enhancing existing language features. For example:

* We could use existing protocol conformance metadata to allow discovering all types conforming to a protocol.
* We could allow property wrappers to be used to discover properties via reflection.

These suggestions have some notable downsides, however. Supporting discovery of all types that conform to *any* protocol would be very expensive, and the majority of protocols do not need this reflection capability. Opting-in to this capability via an attribute on protocols which require it is an intentional aspect of this feature’s design intended to mitigate this cost.

It’s also important to note that a reflection API which *only* allows discovering types that conform to a protocol would be insufficient to satisfy some of the use cases which motivate this feature because it would not allow including additional, custom values in the reflection metadata. For example, the `@EditorCommandRecord(keyboardShortcut: "j", modifier: .command)` example shown above includes custom values on a type conforming to a protocol, and the design of this feature includes a way for the reflection query to retrieve these values in addition to the declaration the attribute was attached to. For types conforming to a protocol, similar functionality could be provided through protocol requirements, but this strategy does not generalize to enable providing custom metadata on functions or computed properties. 

Regarding the use of property wrappers to represent metadata on properties: We feel that property wrappers are not an ideal tool for reflection metadata because they require an instance of the backing property to be stored for each instance, even though the wrapper is constant per-declaration. Property wrappers that are *only* used for reflection metadata don’t need to introduce any access indirection of the wrapped value, either. The value itself can simply be stored inline in the type, rather than synthesizing computed properties.

### Using reflection types in the `init(attachedTo:)` signature

We considered using types from the [Reflection](https://forums.swift.org/t/pitch-reflection/61438) module to represent declarations which have reflection attributes. For example, Reflection’s `Field` could be used as the type of the first parameter in `init(attachedTo:)` when a reflection attribute is attached to a property declaration.

But this design would not allow constraining the types of the declaration(s) the reflection attribute can be attached to using techniques like generic requirements or additional parameters after `attachedTo:` in an initializer, since Reflection types do not expose the interface type of the declaration they represent. For example, `Field` is not parameterized on the field’s type, which would prevent compile-time enforcement of requirements.

### Use static methods instead of `init(attachedTo:)` overloads

We considered using static methods such as `buildMetadata(attachedTo:)` instead of overloads of `init(attachedTo:)` on reflection metadata types to generate metadata instances. This could potentially allow the overloads of `buildMetadata` to return a different type than `Self`, or even an associated type from some protocol. For example:

```swift
// Defined in either the standard library or Reflection
protocol Attribute {
  associatedtype Metadata
}

// Example usage
@reflectionMetadata
struct Flag<Metadata>: Attribute {
  static func buildMetadata(attachedTo: ...) -> Metadata { /* ... */ }
}
```

This alternative has a potential advantage of making it easier for `@propertyWrapper` types to also act as `@reflectionMetadata` types, because it would mean that the storage for any additional, custom values used for metadata purposes only (which are constant for every instance of the declared property) could be stored separately rather than having those values be stored redundantly in every instance of a property wrapper.

### Alternative attribute names

We considered several alternative spellings of the attribute used to declare a reflection metadata type:

* `@runtimeMetadata`
* `@dynamicMetadata`
* `@metadata`
* `@runtimeAnnotation`
* `@runtimeAttribute`
* `@reflectionAnnotation`

### Bespoke `@test` attribute

A previous Swift Evolution discussion suggested [adding a built-in `@test` attribute](https://forums.swift.org/t/rfc-in-line-tests/12111) to the language. However, registration is a general code pattern that is also used outside of testing, so allowing libraries to declare their own domain-specific attributes is a more general approach that supports a wider set of use cases.

## Acknowledgments

Thank you to [Thomas Goyne](https://forums.swift.org/u/tgoyne) for surfacing use cases in the Realm Swift project and insights into alternative design directions.

## Revision history

### Changes after first pitch

* Changed the proposed function signature for reflection metadata type initializer overloads for instance methods to accept `T` as the first parameter, instead of an unapplied function reference, and allow `inout T` to support `mutating` instance methods.
* Changed the proposed function signature for reflection metadata type initializer overloads for static methods to accept `T.Type` as the first parameter, instead of an unapplied function reference.
* Changed the spelling of the proposed attribute from `@runtimeMetadata` to `@reflectionMetadata`.
* Added `@reflectionAnnotation` (suggested by @xedin) to the list of alternative attribute spellings considered.
* Updated the list of supported use cases in the "Applications of reflection metadata types" section by separating global functions and static methods into separate bullets, to describe their differing type signatures. In particular, the function parameter for static methods now has type `(T.Type, Args) -> Result`.
* Clarified paragraph describing where reflection metadata attribute can be applied, to mention it is allowed in extensions of a type within the same module as the type's primary declaration, just not in extensions outside the module.
* Mentioned the ability to explicitly specify a reflection attribute on a type conforming to a protocol with that attribute, and described how that can be useful for specifying additional custom values. Added a code example of this.
* Changed the proposed name and return type of the Reflection API to `func allInstances<T>(of type: T.Type) -> AttributeInstances<T>`, returning a custom `Sequence` type whose type is `T`. Clarified that the returned sequence will omit values which do not satisfy the API availability conditions at runtime, rather than including `nil` values for them.
* Added discussion of some alternatives that were considered involving extending Reflection capabilities and other existing language features.
* Added discussion of an alternative that was considered about using Reflection types as the parameters to `init(attachedTo:)`.
* Added discussion of an alternative that was considered about using static methods instead of `init(attachedTo:)` overloads.
* Clarified interaction between extensions and custom reflection metadata attributes.
