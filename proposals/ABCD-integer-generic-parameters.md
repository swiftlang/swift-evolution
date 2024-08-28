# Integer Generic Parameters

* Proposal: [SE-ABCD](ABCD-integer-generic-parameters.md)
* Authors: [Alejandro Alonso](https://github.com/Azoy), [Joe Groff](https://github.com/jckarter)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [apple/swift#75518](https://github.com/apple/swift/pull/75518)
* Upcoming Feature Flag: `ValueGenerics`

## Introduction

In this proposal, we introduce the ability to parameterize generic types
on literal integer parameters.

## Motivation

Swift does not currently support fixed-size or fixed-capacity collections
with inline storage. (Or at least, it doesn't do so *well*, not without
forming a struct with some specific number of elements and doing horrible
things with `withUnsafePointer` to handle indexing.) Most of the implementation
of something like a fixed-size array, or a fixed-capacity growable array with
a maximum size, or a hash table with a fixed number of buckets, is agnostic
to any specific size or capacity, so that implementation
would ideally be generic over size so that a library implementation can
be reused for any given size.

Beyond inline storage sizes, there are other use cases for carrying integers
in type information, such as to represent an operation with a particular
input or output size. Carrying this information in types can allow for APIs
with stronger static guarantees that chains of operations match in the
number of elements they consume or produce.

## Proposed solution

Generic types can now be parameterized by integer parameters, declared using
the syntax `let <Name>: Int` inside of the generic parameter angle brackets:

```swift
struct Vector<let N: Int, T> {
    /*implementation TBD*/
}
```

A generic type with integer parameters can be instantiated using literal
integer arguments:

```swift
struct Matrix4x4 {
    var matrix: Vector<4, Vector<4, Double>>
}
```

Or it can be instantiated using integer generic parameters from the surrounding
generic environment:

```swift
struct Matrix<let N: Int, let M: Int> {
    var matrix: Vector<N, Vector<M, Double>>
}
```

Generic functions and methods can also be parameterized by integer generic
parameters.  As with other generic parameters, the values of the generic
arguments for a call are inferred from the types of the argument values
provided to the call:

```swift
func matmul<let A: Int, let B: Int, let C: Int>(
    _ l: Matrix<A, B>,
    _ r: Matrix<B, C>
) -> Matrix<A, C> { ... }

let m1 = Matrix<4, 2>(...)
let m2 = Matrix<2, 5>(...)

let m3 = matmul(m1, m2) // A = 4, B = 2, C = 5, result type is Matrix<4, 5>
```

Within an expression, a reference to an integer generic parameter evaluates
the parameter as a value of type `Int`:

```swift
extension Vector {
    subscript(i: Int) -> T {
        get {
            if i < 0 || i >= N {
                fatalError("index \(i) out of bounds [0, \(N))")
            }
            return element(i)
        }
    }
}
```

## Detailed design

The grammar for generic parameter lists expands to include value generic
parameters:

```swift
generic-parameter --> 'let' type-name ':' type
```

Correspondingly, signed integer literals can now appear as elements in
generic argument lists and as operands of generic requirements:

```swift
generic-argument --> '-'? integer-literal
same-type-requirement --> type-identifier '==' '-'? integer-literal
```

Although they can appear as elements in generic parameter lists, integer
literals are still not allowed to appear as types in and of themselves, and
cannot be used as bindings for type generic parameters.

```swift
let x: 2 // error, 2 is not a type
let y: Array<2> // error, Array's Element is a type generic parameter
```

Likewise, integer generic parameters cannot be used as standalone types in their
generic context.

```swift
struct Foo<let X: Int> {
    let x: X // Error, X is not a type
    let metax: X.Type // Error, X has no member `.Type`
}
```

The type referenced by a value generic parameter declaration must resolve to
the `Swift.Int` standard library type. (Allowing other types of value generic
parameter is a future direction.)

```swift
struct Foo<let X: Int> { } // OK (assuming no shadowing `Int` declaration)
struct Foo2<let X: Swift.Int> { } // also OK

struct BadFoo<let x: Float> { } // Error, generic parameters of type Float not supported

typealias MyInt = Swift.Int
struct Bar<let X: MyInt> { } // OK

struct Baz: P {
    typealias A = Int
}

struct Zim<let X: Baz.A> { } // OK

func contrived() {
    struct Int { }

    struct BadFoo<let X: Int> { } // Error, local Int not supported

    struct Foo<let X: Swift.Int> { } // OK
}
```

In a type reference, an integer generic argument can be provided as either
a literal integer, or as a reference to an integer generic parameter from
the enclosing generic context. References to type generic parameters,
type generic parameter packs, or declarations other than integer generic
parameters is an error. (Allowing references to constants of integer type,
or more elaborate constant expressions, as generic parameters is a future
direction.)

```swift
struct IntParam<let X: Int> { }

let a: IntParam<2> // OK
let b: IntParam<-2> // OK

struct AlsoIntParam<let X: Int, T, each U> {
    let c: IntParam<X> // OK

    static let someIntegerConstant = 42
    let d: IntParam<someIntegerConstant> // Error, not an Int generic parameter

    let e: IntParam<T> // Error, is a type generic parameter
    let f: IntParam<U> // Error, is a pack generic parameter
}
```

Conversely, using an integer generic parameter as an argument for a type
generic parameter is also an error.

```swift
struct IntAndTypeParam<let X: Int, T> {
    let x: Array<X> // Error, X is an integer type parameter
}
```

An integer generic parameter can be constrained to be equal to a specific
literal value using a same-value constraint, spelled with `==` as for a
same-type constraint. Two integer generic parameters can also be constrained
to be equal to each other.

```swift
struct TwoIntParams<T, let N: Int, let M: Int> {}

extension TwoIntParams where N == 2 {
    func foo() { ... }
}

extension TwoIntParams where N == M {
    func bar() { ... }
}

let x: TwoIntParams<Int, 2, 42>
x.foo() // OK
x.bar() // Error, doesn't match constraint

let y: TwoIntParams<Int, 3, 3>
y.foo() // Error, doesn't match constraint
y.bar() // OK
```

Integer generic parameters cannot be constrained to be equal to type generic
parameters, concrete types, or to declarations other than generic parameters.
Integer generic parameters also cannot be constrained to conform to protocols.

```swift
extension TwoIntParams where N == T {} // error
extension TwoIntParams where T == N {} // error
extension TwoIntParams where N == Int {} // error

let globalConstant = 42
extension TwoIntParams where N == globalConstant {} // error

extension TwoIntParams where N: Collection // error
```

(In the same way overload resolution already works in Swift, extensions or
functions with generic constraints on integer parameters will only be chosen
for call sites at which those constraints always hold; we won't "dispatch"
based on the value of an argument from a less-constrained call site.)

```swift
struct Foo<let N: Int> {
    func foo() { print("foo #1") }

    func bar() {
        // Always prints "foo #1" 
        self.foo()
    } 
}

extension Foo where N == 2 {
    func foo() { print("foo #2") }
}

Foo<2>().bar() // prints "foo #1"
Foo<2>().foo() // prints "foo #2"
```

## Source compatibility

This proposal is a pure extension of the existing language. The `let N: Type`
syntax should ensure source compatibility if we expand the feature to allow
value generic parameters of other types in the future.

## ABI compatibility

This proposal does not affect the ABI of existing code. Handling integer
generic parameters in full generality requires new functionality in the
Swift runtime to be able to encode and interpret them as part of type
metadata.

As with generic parameters in general, adding or removing
integer generic parameters, replacing value parameters of a function with
integer generic parameters, reordering an integer generic parameter relative to
other generic parameters (whether value or type), and adding or removing
same-value constraints are all ABI-breaking changes.

## Implications on adoption

On platforms where the vendor ships the Swift runtime with the operating
system, there may be limitations on using integer generic parameters in
programs that want to target earlier versions of those platforms that don't
have the necessary runtime support.

## Future directions

This proposal aims to establish the core functionality of integer generic
parameters. There are many possible improvements that could be built upon
this base:

### Fixed-size and fixed-capacity collection types

This proposal provides a foundational mechanism for fixed-size array and
fixed-capacity collection types, but does not itself introduce any
new standard library types or mechanisms for defining those types. We leave
it to future proposals to explore the design of those types.

### Use of constant bindings as generic parameters

It would be very useful to be able to use constant bindings as generic
parameter bindings, in addition to literals and existing generic parameter
bindings:

```swift
static let bufferSize
    = MemoryLayout<Int8>.size * 64 + MemoryLayout<Int>.size * 8

var buffer = Vector<bufferSize, UInt8>(...)
```

This should be possible as long as the bindings referenced are known to be
constant (like `let` bindings are). However, the type checker will likely
be unable to reason about the value of these bindings, since constant
evaluation occurs after type checking is complete, so they would be treated
as opaque values.

### Arithmetic in generic parameters

There are many operations that would benefit from being able to express basic
arithmetic relationships among values. For instance, the concatenation of two
fixed-sized arrays would give an array whose length is the sum of the input
lengths:

```swift
func concat<let N: Int, let M: Int, T>(
    _ a: Vector<N, T>, _ b: Vector<M, T>
) -> Vector<N + M, T>
```

Due to the bidirectional nature of Swift's type-checking, there would be
limits to the sorts of relations we would be able to express this way.

### Relating integer generic parameters and variadic pack shapes

The "shape" of a parameter pack ultimately compiles down to its length.
Variadic packs don't currently have a way to directly reference or constrain
their shape or length, and integer generic parameters might be one way of doing
so.  Among other things, this might allow for a variadic API to express that it
takes as many arguments as one of its integer generic parameters indicates:

```swift
struct Vector<let N: Int, T> {
    // the initializer for a Vector takes one argument
    // for every element
    init(_ values: repeat each N * T)
}
```

### Non-integer value generic parameters

We may want to eventually allow generic declarations to have value parameters
of type other than `Int`. The proposal's `let Parameter: Type` declaration
syntax maintains space for this:

```swift
struct MatrixShape { var rows: Int, columns: Int }

struct Matrix<let Shape: MatrixShape> {
    var elements: Vector<Shape.rows, Vector<Shape.columns, Double>>
}
```

Although the syntactic extension is straightforward, there are a lot of
questions to answer about how type equality is determined when values of
arbitrary type are involved, and what sorts of construction and destructuring
operations can be supported at type level. There is some precedent in
other languages to look at here, particularly C++'s non-type template
parameters or Rust's similar const generics feature. However, in relation to
those other languages, Swift puts a bit stronger emphasis on being able to
abstract the layout of types, but the type-level equality of parameters would
be heavily dependent on their types' layout and how initialization and property
access works.

### Integer parameter packs

There are use cases for variadic packs of integer generic parameters.
For instance, it might be a way of representing arbitrary multidimensional
matrices of values:

```swift
struct MDMatrix<let each N: Int> { ... }

let mat2d: MDMatrix<4, 4> = ...
let mat4d: MDMatrix<120, 24, 6, 2> = ...
```

## Alternatives considered

### Variable-sized types instead of integer generic parameters

One of the primary motivators for integer generic parameters is to represent
fixed-size and fixed-capacity collections. One of the reasons this is necessary
is because every value of a Swift type has to have a uniform size; since
a four-element array has a different size from a five-element array, that
implies that they have to be different types `Vector<4, T>` and `Vector<5, T>`.

However, one could argue that the fundamental type of such a container
doesn't really change with its size; in most cases, a function that can
accept an array of some size can just as well accept an array of any size.
Forcing a type distinction between different-sized arrays forces the majority
of APIs that want to work with arrays to either be generic over their size,
be generic over some more abstract protocol like `Collection` that all
sized arrays conform to (along with unsized `Array` and non-array collections),
or work with the arrays indirectly through some handle type like
`UnsafeBufferPointer` or `Span`.

So it's interesting to consider an alternative design where we instead
remove the "all values of a type have the same size" constraint. One could
say that the owner of a `Vector` value has to give it some size, but then
a `borrowing` or `inout Vector` can reference a `Vector` of any size, since
the reference representation would carry that size information from the
owner. There are however a lot of open questions following this design
path—if you want to have a two-dimensional `Vector` of `Vector`s, how do you
track the size information of both levels of nesting? There also *are*
functions that want to require taking two input arrays of the same size,
or promise to return an array as the same size as an argument. These
relationships are straightforward to express through the generics system,
and if sizes aren't propagated through types but some other means, it seems
likely we would need a parallel mechanism for reasoning about sizes generically.
Variable-sized types are an interesting idea to explore, but it isn't clear
that they lead to an overall simpler language design.

### Declaring value parameters without `let`

One could argue that, since `Int` clearly isn't a protocol constraint, that
it should be sufficient to declare integer generic parameters with the
syntax `<T: Int>` without an introducer like `let`. There are at least
a couple of reasons we choose to adopt the `let` introducer:

- It makes it clear to the reader (and the compiler) what parameters are
  value parameters without needing to do name resolution first. This may not
  be a huge deal for `Int`, but if we expand the feature to allow other
  types of value generic parameters, then it may not be obvious in an
  unfamiliar codebase whether `T: Foo` refers to a protocol constraint
  `Foo` or a concrete type `Foo`.
- If we do generalize value generic parameters to allow other types in the
  future, it's not entirely out of the question that that could include
  existential types, which would make `T: P` potentially ambiguous as to
  whether it declares a type parameter constrained to `T` or a value
  parameter of type `any P`. (There are perhaps other ways of dealing with that
  ambiguity, such as requiring the value parameter form to be written
  explicitly with `T: any P`.)

### Arbitrary-precision integer generic parameters

Instead of treating integer generic parameters as values of `Int` or any
finite type, another possible design would be to treat type-level integers
as independent of any concrete type, leaving them as ideal arbitrary-precision
integers. This would have some semantic advantages if we want to allow for
type-level arithmetic relationships, since these operations could be defined
in their ideal form without having to deal with overflow and other limitations
of concrete Swift types. In such a design, a reference to an integer generic
parameter in a value expression could be treated as polymorphic, in a similar
way to how integer literals can be used with any type that's
`ExpressibleByIntegerLiteral`.

Although this model has some appeal, it also has some practical issues. If
type-level integers are arbitrary precision, but value-level integer types are
still finite, then there is the chance for overflow any time a type-level
integer is reified to a finite integer type. This model also would not extend
very naturally to non-integer value parameters if we introduce those in the
future.

### Generic parameters of integer types other than `Int`

We discuss generalizing value generic parameters to types other than `Int`
as a future direction above, but a narrower expansion might be to allow all
of Swift's primitive integer types, including all of the sized and
signed/unsigned variants, as types for generic value parameters. One could
argue that `UInt` is particular is desirable to use as the type for fixed-size
and fixed-capacity collections, of which instances can never actually be
constructed for negative sizes.

However, we would like to continue to promote the use of `Int` as the common
currency type for integers, as we have already established for the standard
library. Introducing mixed integer types as type-level generic parameters
would inevitably lead to the need to be able to perform type conversions
at type level, and the associated need to deal with overflow during these
type-level conversions.

The established API for the `Collection` protocol, `Array`, and the other
standard library types already use `Int` for `count` and array subscripting
operations, so establishing `Int` as the type for type-level size parameters
avoids the need for type conversions when mixing type- and value-level index
and size values. Types that use integer parameters for sizing can still
refuse to initialize values of types with negative parameters, so that a
type like `Vector<-1, Int>` is uninhabited. Given the restrictions in this
initial proposal, without type-level arithmetic, it is unlikely that
developers would intentionally form such a type with a negative size explicitly.

## Acknowledgments

We would like to thank the following people for prototyping and design
contributions that helped shape this proposal:

- Holly Borla
- Ben Cohen
- Erik Eckstein
- Doug Gregor
- Tim Kientzle
- Karoy Lorentey
- John McCall
- Kuba Mracek
- Slava Pestov
- Andrew Trick
- Pavel Yaskevich
