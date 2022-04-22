# Build-Time Constant Values

* Proposal: [SE-0353](build-time-constant-values.md)
* Authors: [Artem Chikin](https://github.com/artemcm), [Ben Cohen](https://github.com/airspeedswift), [Xi Ge](https://github.com/nkcsgexi)
* Review Manager: TBD
* Status: **Implemented**

## Introduction

A Swift language feature for requiring certain values to be knowable at compile-time. This is achieved through an attribute, `@const`, constraining properties and function parameters to have compile-time knowable values. Such information forms a foundation for richer compile-time features in the future, such as extraction and validation of values at compile time.

Related forum threads:

* [[Pitch] Compile-Time Constant Values](https://forums.swift.org/t/pitch-compile-time-constant-values/53606)

## Motivation

Compile-time constant values are values that can be known or computed during compilation and are guaranteed to not change after compilation. Use of such values can have many purposes, from enforcing desirable invariants and safety guarantees to enabling users to express arbitrarily complex compile-time algorithms. 

The first step towards building out support for compile-time constructs in Swift is a basic primitives consisting of an attribute to declare function parameters and properties to require being known at *compile-time*. While this requirement explicitly calls out the compiler as having additional guaranteed information about such declarations, it can be naturally extended into a broader sense of *build-time* known values - with the compiler being able to inform other tools with type-contextual value information. For an example of the latter, see the “Declarative Package Manifest” motivating use-case below.

## Proposed Solution

The Swift compiler will recognize declarations of properties, local variables, and function parameters declared with a `@const` attribute as having an additional requirement to be known at compile-time. If a `@const` property or variable is initialized with a runtime value, the compiler will emit an error. Similarly, if a runtime value is passed as an argument to a `@const` function parameter, the compiler will emit an error. Aside from participating in name mangling, the attribute has no runtime effect.

## Detailed Design

### Property `@const` attribute

A stored property on a `struct` or a `class` can be marked with a `@const` attribute to indicate that its value is known at compile-time. 

```
struct Foo {
  @const let title: String = "foo"
}
```

Similarly to Implicitly-Unwrapped Optionals, the mental model for semantics of this attribute is that it is a flag on the declaration that  guarantees that the compiler is able to know its value as shared by all instance of the type. For now, `@const let` and `@const static let` are equivalent in what information the `@const` attribute conveys to the compiler.(*AC: Worth mentioning here that in the future,* `@const let` *properties will gain an ability to be initialized with compile-time expressions*). Unlike a plain `static let` stored property, a `@const static let` property does not need to refer to a location in memory shared by all instances of the type, and can be elided by the compiler entirely. Default-initializing a `@const` property with a runtime value or not default-initializing it at all results in an compilation error.

### Parameter `@const` attribute

A function parameter can be marked with a `@const`  keyword to indicate that values passed to this parameter at the call-site must be compile-time-known values.

```
func foo(@**const** input: Int) {...}
```

### Supported Types

The requirement that values of `@const` properties and parameters be known at compile-time restricts the allowable types for such declarations. The current scope of the proposal includes:

* Integer and floating-point and boolean literals.
* String literals (excluding interpolated strings).
* Enum cases with no associated values.
* Tuple literals consisting of the above list items.
* Array and dictionary literals consisting of the above list items.

This list will expand in the future to include more literal-value kinds or potential new compile-time valued constructs.

### Protocol `@const` property requirement 

A protocol author may require conforming types to default initialize a given property with a compile-time-known value by specifying it as `@const static` in the protocol definition. For example:

```
protocol NeedsConstGreeting {
    @const static var greeting: String
}
```

If a conforming type initializes `greeting` with something other than a compile-time-known value, a compilation error is produced:

```
struct Foo: NeedsConstGreeting {
  // 👍
  static let greeting = "Hello, Foo"
}

struct Bar: NeedsConstGreeting {
  // error: 'greeting' must be initialized with a const value
  static let greeting = "\(Bool.random ? "Hello" : "Goodbye"), Bar"
}
```

## Forward-looking design aspects

### Propagation Rules
Though this proposal does not itself introduce propagation rules of `@const`-ness, their future existence is worth discussing in this design. Consider the example:
```
@const let i = 1
let j = i
```
Our intent is to allow the use of `i` where `@const` values are expected in the future, for example`@const let k = i` or `f(i)` where `f` is `func f(@const _: Int)`. It is therefore important to consider whether `@const` is propagated to values like `j` in the above example, which determines whether or not statements like `f(j)` and `@const let k = j` are valid code. While it is desreable to allow such uses of the value within the same compilation unit, if `j` is `public`, automatically inferring it to be `@const` is problematic at the module boundary: it creates a contract with the module's clients that the programmer may not have indended. Therefore, `public` properties must explicitly be marked `@const` in order to be accessible as such outside the defining module. This is similar in nature to `Sendable` inference - `internal` or `private` entities can automatically be inferred by the compiler as `Sendable`, while `public` types must explicitly opt-in.

### Memory placement
Effect on runtime placement of `@const` values is an implementation detail that this proposal does not cover beyond indicating that today this attribute has no effect on memory layout of such values at runtime. It is however a highly desireable future direction for the implementation of this feature to allow the use read-only memory for `@const` values. With this in mind, it is important to allow semantics of this attribute to allow such implementation in the future. For example, a global `@const let`, by being placed into read-only memory removes the need for synchronization on access to such data. Moreover, using read-only memory reduces memory pressure that comes from having to maintain all mutable state in-memory at a given program point - read-only data can be evicted on-demand to be read back later. These are desireable traits for optimization of existing programs which become increasingly important for enabling of low-level system programs to be written in Swift.

In order to allow such implementation in the future, this proposal makes the *value* of `public` `@const` values/properties a part of a module's ABI. That is, a resilient library that vends `@const let x = 11` changing the value of `x` is considered an ABI break. This treatment allows `public` `@const` data to exist in a single read-only location shared by all library clients, without each client having to copy the value or being concerned with possible inconsistency in behavior across library versions. 

## Motivating Example Use-Cases

### Facilitate Compile-time Extraction of Values

The [Result Builder-based SwiftPM Manifest](https://forums.swift.org/t/pre-pitch-swiftpm-manifest-based-on-result-builders/53457) pre-pitch outlines a proposal for a manifest format that encodes package model/structure using Swift’s type system via Result Builders. Extending the idea to use the builder pattern throughout can result in a declarative specification that exposes the entire package structure to build-time tools, for example:

```
let package = Package {
  Modules {
    Executable("MyExecutable", public: true, include: {
        Internal("MyDataModel")
      })
    Library("MyLibrary", public: true, include: {
        Internal("MyDataModel", public: true)
      })
    Library("MyDataModel")
    Library("MyTestUtilities")
    Test("MyExecutableTests", for: "MyExecutable", include: {
        Internal("MyTestUtilities")
        External("SomeModule", from: "some-package") 
      })
    Test("MyLibraryTests", for: "MyLibrary")
  }
  Dependencies {
    SourceControl(at: "https://git-service.com/foo/some-package", upToNextMajor: "1.0.0")
  } 
}
```

A key property of this specification is that all the information required to know how to build this package is encoded using compile-time-known concepts: types and literal (and therefore compile-time-known) values. This means that for a category of simple packages where such expression of the package’s model is possible, the manifest does not need to be executed in a sandbox by the Package Manager - the required information can be extracted at manifest *build* time.

To *ensure* build-time extractability of the relevant manifest structure, a form of the above API can be provided that guarantees the compile-time known properties. For example, the following snippet can guarantee the ability to extract complete required knowledge at build time:

```
Test("MyExecutableTests", for: "MyExecutable", include: {
        Internal("MyTestUtilities")
        External("SomeModule", from: "some-package") 
      })
```

By providing a specialized version of the relevant types (`Test`, `Internal`, `External`) that rely on parameters relevant to extracting the package structure being `const`:

```
struct Test {
  init(_ title: const String, for: const String, @DependencyBuilder include: ...) {...} 
}
struct Internal {
  init(_ title: const String)
}
struct External {
  init(_ title: const String, from: const String)
}
```

This could, in theory, allow SwiftPM to build such packages without executing their manifest. Some packages, of course, could still require run-time (execution at package build-time) Swift constructs. More-generally, providing the possibility of declarative APIs that can express build-time-knowable abstractions can both eliminate (in some cases) the need for code execution - reducing the security surface area - and allow for further novel use-cases of Swift’s DSL capabilities (e.g. build-time extractable database schema, etc.). 

### Enforcement of Compile-Time Attribute Parameters

Attribute definitions can benefit from additional guarantees of compile-time constant values. Imagine a property wrapper that declares a property is to be serialized and that it must be stored/retrieved using a specific string key. `Codable` requires users to provide a `CodingKeys` `enum` boilerplate, relying on the `enum`’s `String` raw values. Alternatively, such key can be specified on the property wrapper itself:

```
struct Foo {
  @SpecialSerializationSauce(key: "title") 
  var someSpecialTitleProperty: String
}

@propertyWrapper
struct SpecialSerializationSauce {
  init(@const key: String) {...}
}
```

Having the compiler enforce the compile-time constant property of `key` parameter eliminates the possibility of an error where a run-time value is specified which can cause serialized data to not be able to be deserialized, for example. 

Enforcing compile-time constant nature of the parameters is also the first step to allowing attribute/library authors to be able to check uses by performing compile-time sanity checking and having the capability to emit custom build-time error messages.

### Enforcement of Non-Failable Initializers

Ergonomics of the recently-pitched [Foundation.URL](https://forums.swift.org/t/foundation-url-improvements/54057) would benefit greatly from the ability to require the string argument to be compile-time constant. With evolving compile-time evaluation facilities, Swift may even gain an ability to perform compile-time validation of such URLs  even though the user may never be able to express a fully compile-time constant `Foundation.URL` type because this type is a part of an ABI-stable SDK. While a type like `StaticString` may be used to require that the argument string must be static, which string is chosen can still be determined at runtime, e.g.:

```
URL(Bool.random() ? "https://valid.url.com" : "invalid url . com")
```

### Guaranteed Optimization Hints

Similarly, ergonomics of numeric intrinsics can benefit from allowing only certain function parameters to be required to be compile-time known. For example, requiring a given numeric operation to specify a `@const` parameter for the rounding mode of an operation as an enum case, while allowing the operands of the operation be runtime values, allowing the compiler to generate more-efficient code. 

## Source compatibility

This is a purely additive change and has no source compatibility impacts.

## Effect on ABI stability and API resilience

The new function parameter attribute is a part of name mangling. The *value* of `public @const` properties is a part of a module's ABI. See discussion on *Memory placement* for details.

## Effect on SwiftPM packages

There is no impact on SwiftPM packages.

## Alternatives Considered

### Using a keyword or an introducer instead of an attribute
`@const` being an attribute, as opposed to a keyword or a new introducer (such as `const` instead of `let`), is an approach that is more amenable to applying to a greater variety of constructs in the futures, in addition to property and parameter declarations, such as `@const func`. In addition, as described in comparison to Implicitly-Unwrapped Optionals above, this attribute does not fundamentally change the behavior of the declaration, rather it restricts its handling by the compiler, similar to `@objc`.

### Difference to `StaticString`-like types
As described in the **Enforcement of Non-Failable Initializers**, the key difference to types like `StaticString` that require a literal value is the `@const` attribute's requirement that the exact value be known at compile-time. `StaticString` allows for a runtime selection of multiple compile-time known values.

### Placing `@const` on the declaration type
One altenative to declaring compile-time known values as proposed here with the declaration attribute:
```
@const let x = 11
```
Is to instead shift the annotation to declared property's type:
```
let x: @const Int = 11
```
This shifts the information conveyed to the compiler about this declaration to be carried by the declaration's type. Semantically, this departs from, and widely broadens the scope from what we intend to capture: the knowability of the declared *value*. Encoding the compile-time property into the type system would force us to reckon with a great deal of complexity and unintended consequences. Consider the following example:
```
typealias CI = @const Int
let x: CI?
```
What is the type of `x`? It appears to be Optional<@const Int>, which is not a meaningful or useful type, and the programmer most likely intended to have a @const Optional<Int>. And although today Implicitly-Unwrapped optional syntax conveys an additional bit of information about the declared value using a syntactic indicator on the declared type, without affecting the declaration's type, the [historical context](https://www.swift.org/blog/iuo/) of that feature makes it a poor example to justify requiring consistency with it. 

## Future Directions
* Constant-propogation - allow default-initialization of `@const` properties using other `@const` values and allow passing `@const` values to `@const` parameters.
* Toolchain support for extracting compile-time values at build time.
* Compile-time expressions - allow expressions that operate on compile-time-known values, from binary operators to control flow.
* Compile-time types - allow types consisting of `const` properties to be treated as compile-time-known values.
* Compile-time functions - consisting of expressions operating on compile-time-known values and `const` parameters.

