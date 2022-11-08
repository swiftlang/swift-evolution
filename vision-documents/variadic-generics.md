# A vision for variadic generics in Swift

Generic functions and types in Swift currently require a fixed number of type parameters. It is not possible to write a function or type that accepts an arbitrary number of arguments with distinct types, instead requiring one of the following workarounds:

* Erasing all the types involved, e.g. using `Any...`
* Using a single tuple type argument instead of separate type arguments
* Overloading for each argument length with an artificial limit

There are a number of examples of these workarounds in the Swift Standard Library alone, such as 6 overloads for each tuple comparison operator:

```swift
func < (lhs: (), rhs: ()) → Bool

func < <A, B>(lhs: (A, B), rhs: (A, B)) → Bool where A : Comparable, B : Comparable

func < <A, B, C>(lhs: (A, B, C), rhs: (A, B, C)) → Bool where A : Comparable, B : Comparable, C : Comparable

func < <A, B, C, D>(lhs: (A, B, C, D), rhs: (A, B, C, D)) → Bool where A : Comparable, B : Comparable, C : Comparable, D : Comparable

func < <A, B, C, D, E>(lhs: (A, B, C, D, E), rhs: (A, B, C, D, E)) → Bool where A : Comparable, B : Comparable, C : Comparable, D : Comparable, E : Comparable

func < <A, B, C, D, E, F>(lhs: (A, B, C, D, E, F), rhs: (A, B, C, D, E, F)) → Bool where A : Comparable, B : Comparable, C : Comparable, D : Comparable, E : Comparable, F : Comparable
```

These ad-hoc variadic APIs demonstrate a glaring hole in the generics system. The above workarounds all have significant tradeoffs:

* Erasing all types involved sacrifices static type safety.
* Using a single tuple type argument sacrifices expressivity by making the individual element types opaque, preventing the code from operating on the elements individually.
* Overloading for each argument length sacrifices compile-time performance, library maintainability, and imposes arbitrary restrictions on clients of the API.

Variadic generics is a language feature that enables writing generic code that abstracts over a variable number of type parameters. The goals of adding variadic generics to Swift are:

* **Express variadic APIs with a single implementation that abstracts over length**, removing arbitrary limits and reducing the developer experience and library maintenance costs of multiple overloads.
* **Enable generalizing tuple types with abstract elements** by expressing abstract elements in terms of variadic generics.
* **Maintain separate compilation of variadic generic code** by introducing the notion of abstract length into the type system, including a representation of length in generic signatures.

Using variadic generics, the above operator overloads can be written as a single `<` implementation that accepts tuples of abstract length:

```swift
func < <Element...>(lhs: (Element...), rhs: (Element...) -> Bool where Element: Comparable {
  let leftElement = lhs...
  let rightElement = rhs...
  for (left, right) in (leftElement, rightElement)... {
    guard left < right else { return false }
  }
  return true
}
```

## The approach

The design for variadic generics described in this document includes:

* A construct for abstracting over a list of zero or more parameters at the type and value level, and using the list of zero or more parameters in positions that naturally accept a list of types or values.
* List operations over an abstract type/value list including mapping, iteration, concatenation, and de-structuring.
* Projecting elements out of an abstract list of zero or more types or values.
* Unpacking tuples into an abstract list of zero or more elements.

The above features enable much of the same functionality that programmers expect from `Sequence`. However, with variadic generics, the elements in the list each have a different type, making the list heterogeneous. To express a static interface that contains an abstract heterogeneous list, the list operations must be expressible at the type level. An explicit usability goal for variadic generics in Swift is that these heterogeneous list operations are expressed in the same way at the type level and at the value level.

### Parameter packs: the foundation of length abstraction

Parameter packs are the core concept that facilitates abstracting over a variable number of parameters. A pack is a new _kind_ of type-level and value-level entity that represents a list of types or values, and it has an abstract length. A type parameter pack stores a list of zero or more type parameters, and a value parameter pack stores a list of zero or more value parameters.

A type parameter pack is declared in angle brackets using an ellipsis:

```swift
// 'S' is a type parameter pack
struct ZipSequence<S...> {}
```

A value parameter pack is a function parameter whose type contains a reference to a type parameter pack followed by an ellipsis:

```swift
// 'value' is a value parameter pack
func variadicPrint<T...>(_ value: T...) {}
```

Parameter packs are substituted with a list of zero or more arguments. In this document, concrete type and value packs will be denoted as a comma-separated list of types or values in curly braces, e.g. `{Int, String, Bool}` and `{1, "hello!", true}`, respectively. Note that the design does not include a syntax for writing concrete packs in the language itself.

```swift
struct Tuple<Element...> {}

Tuple<Int> // T := {Int}
Tuple<Int, String, Bool> // T := {Int, String, Bool}
Tuple<> // T := {}
```

#### Patterned pack expansion

A parameter pack itself is not a first-class value or type, but the elements of a parameter pack can be used anywhere that naturally accepts a comma-separated list of values or types using *pack expansions*. A pack expansion unpacks the elements of a pack into a comma-separated list, and elements can be appended to either side of a pack expansion by writing more values in the comma-separated list.

A pack expansion consists of a type or an expression followed by an ellipsis. The ellipsis is called the *expansion operator*, and the type or expression that the expansion operator is applied to is called the *repetition pattern*. The repetition pattern must contain pack references. Given a concrete pack substitution, the pattern is repeated for each element in the substituted pack.

Consider a type parameter pack `T` and a pack expansion `Mapped<T>...`. Substituting the concrete pack `{Int, String, Bool}` will expand the pattern `Mapped<T>` by repeating it for each element in the concrete pack, replacing the pack reference `T` with the concrete type at each position. This produces a new comma-separated list of types `Mapped<Int>, Mapped<String>, Mapped<Bool>`. The following code demonstrates concrete pack substitution:

```swift
struct Mapped<Value> {}

func map<T...>(_ t: T...) -> (Mapped<T>...) {
  return (Mapped(t)...)
}

map(1, "hello", true)
```

In the above code, the call to the variadic `map` function infers the type parameter pack substitution `T:= {Int, String, Bool}` from the argument values. Expanding the repetition pattern `Mapped<T>` into a tuple type produces a tuple return type of `(Mapped<Int>, Mapped<String>, Mapped<Bool>)`. Substituting the value parameter pack with `t := {1, "hello", true}` and expanding the repetition pattern `Mapped(t)` into a tuple value produces a tuple return value `(Mapped(1), Mapped("hello"), Mapped(true))`.

#### Static shape of a parameter pack

Validating variadic generic code separately from its application requires introducing the notion of abstract length of a list of type parameters into the type system. Operations over parallel lists, such as statically zipping two separate lists of type parameters to create a new list of 2-element tuple types, require that multiple lists have the length.

Same-type requirements will further characterize packs. For example, consider the following generic signature of `firstRemoved`, which contains a same-type requirement involving two pack expansions:

```swift
struct List<Element...> {
  func firstRemoved<First, Rest...>() -> List<Rest...> where (Element...) == (First, Rest...) {}
}
```

The `(Element...) == (First, Rest...)` requirement defines the following static properties:
* The first element of the `Element` parameter pack is equal to `First`.
* The remaining elements of the `Element` parameter pack are equal to `Rest`

These properties are called the *shape* of a parameter pack. Formally, the shape of a pack is one of:
* A single scalar type element; all scalar (i.e. non-pack) types have a singleton scalar shape
* An abstract shape that is specific to a parameter pack
* A concrete shape that is composed of the scalar shape and abstract shapes

For example, the pack `{First, Rest...}` has a concrete shape that consists of one scalar type element, one abstract shape corresponding to `Rest`.

##### Destructuring operations using static shape

The statically-known shape of a pack can enable destructing packs with concrete shape into the component elements:

```swift
struct List<Element...> {
  let elements: (Element...)
  init(_ element: Element) { elements = (element...) }
}

extension List {
  func firstRemoved<First, Rest...>() -> List<Rest...> where (Element...) == (First, Rest...) {
    let (first, rest) = (value...)
    return List(rest...)
  }
}

let list = List(1, "Hello", true)
let firstRemoved = list.firstRemoved() // 'List("Hello, true)'
```

The body of `firstRemoved` decomposes `Element` into the components of its shape -- one value of type `First` and a value pack of type `Rest...` -- effectively removing the first element from the list.

### Pack iteration

All list operations can be expressed using pack expansion expressions by factoring code involving statements into a function or closure. However, this approach does not allow for short-circuiting, because the pattern expression will always be evaluated once for every element in the pack. Further, requiring a function or closure for code involving statements is unnatural. Allowing `for-in` loops to iterate over packs solves both of these problems.

Value packs can be expanded into the source of a for-in loop, allowing you to iterate over each element in the pack and bind each value to a local variable:

```swift
func allEmpty<T...>(_ array: [T]...) -> Bool {
  for array in array... {
    guard array.isEmpty else { return false }
  }
  
  return true
}
```

The type of the local variable `array` in the above example is an `Array` of an opaque element type with the requirements that are written on `T`. For the *i*th iteration, the element type is the *i*th type parameter in the type parameter pack `T`.

### Pack element projection

Use cases for variadic generics that break up pack iteration across function calls, require random access, or operate over concrete packs are supported in this design by projecting individual elements out from a parameter pack. Because elements of the pack have different types, there are two approaches to pack element projection; using an `Int` index which will return the dynamic type of the element, and using a statically typed index which is parameterized over the requested pack element type.

#### Dynamic pack indexing with `Int`

Dynamic pack indexing is useful when the specific type of the element is not known, or when all indices must have the same type, such as for index manipulation or storing an index value. Packs will support subscript calls with an `Int` index, which will return the dynamic type of the pack element directly as the opened underlying type that can be assigned to a local variable with opaque type. Values of this type need to be erased or cast to another type to return an element value from the function:

```swift
func element<T...>(at index: Int, in t: T...) where T: P -> any P {
  // The subscript returns 'some P', which is erased to 'any P'
  // based on the function return type.
  let value: some P = t[index]
  return value
}
```

Consider the following `ChainCollection` data structure, which has a type parameter pack of collections with the same `Element` type:

```swift
struct ChainCollection<Element, C...> where C: Collection, C.Element == Element {
  var collections: (C...)
}
```

`ChainCollection` implements the `Collection` protocol. Iterating over a `ChainCollection` will iterate over all `Element` values for a given collection in `collections` before moving onto the next collection in the pack. Internally, an index into `ChainCollection` is two-dimensional - it has a component for the collection in the pack, and another component for the index into that collection:

```swift
struct ChainCollectionIndex: Comparable {
  // The position of the current collection in the pack.
  var collectionPosition: Int
  
  // The position of the element in the current collection.
  var elementPosition: any Comparable
}
```

Now, a `ChainCollection` subscript can be implemented by first indexing into the pack to get the current collection using the collection position, and then indexing into that collection using the element position:

```swift
extension ChainCollection {
  subscript(position: ChainCollectionIndex) -> Element {
    // Expand the stored tuple into a local variable pack
    let collection = collections...
    
    func element<C: Collection<Element>>(in c: Collection, at index: any Comparable) -> Element {
      guard let index = index as? C.Index else { fatalError() }
      return c[index]
    }
    
    return element(in: collection[position.collectionPosition],
                   at: position.elementPosition)
  }
}
```

#### Typed pack element projection using key-paths

The `ChainCollection` use case above requires using the same index type for all elements in the pack. However, other use cases for pack element projection know upfront which type within the pack will be projected, and can use a statically typed pack index. A statically typed pack index can be represented with `KeyPath`, which is parameterized over the base type for access (i.e. the pack), and the resulting value type (i.e. the element within the pack to project). Pack element projection via key-paths falls out of 1) positional tuple key-paths, and 2) expanding packs into tuple values:

```swift
struct Tuple<Elements...> {
  var elements: (Elements...)
  
  subscript<Value>(keyPath: KeyPath<(Element...), Value>) -> Value {
    return elements[keyPath: keyPath]
  }
}
```

The same positional key-path application should be supported directly on packs:

```swift
func apply<T..., Value>(keyPath: KeyPath<T..., Value>, to t: T...) -> Value {
  return t[keyPath: keyPath]
}

let value: Int = apply(keyPath: \.0, to: 1, "hello", false)
```

### Concrete packs

Stored property packs are useful to avoid variadic generic types needing a tuple for pack storage. Enabling stored property packs requires admitting concrete packs into the language.

Concrete value packs need the ability to access individual elements in the pack. This can be done with typed pack element projection directly on a concrete value pack:
```swift
struct Tuple<Element...> {
  var element: Element...
  init(elements element: Element...) { self.element = element... }
}

let tuple = Tuple(1, "hello", true)
let number: Int = tuple.element.0
let message: String = tuple.element.1
let condition: Bool = tuple.element.2
```

Statically type checked code that abstracts over argument length requires a static representation of the element type of a pack. Concrete packs can also be used in code that abstracts over argument length by writing a type annotation for the abstract element type:

```swift
struct Tuple<Element...> {
  var element: Element...
}

func iterate(over tuple: Tuple<Int, String, Bool>) {
  for value: some Equatable in tuple... {
    // do something with an 'Equatable' value
  }
}
```

### Multi-dimensional packs

Enabling associated type packs is necessary for writing protocols that express an interface for variadic generic types. For example:

```swift
protocol HeterogeneousSequence<Element...> {
  associatedtype Element...
}

struct List<Element...>: HeterogeneousSequence {}
```

In full generality, associated type packs introduce multi-dimensional packs into the language:

```swift
func twoDimensional<T...>(_ t: T...) where T: HeterogeneousSequence {}
```

In the above generic signature for `twoDimensional`, `T.Element` is a multi-dimensional pack. It may be useful to introduce a way to express pack expansions of multi-dimensional packs, e.g. to flatten all of the `Element` values into a single list, but it's unclear how this might be expressed. To enable associated type packs in the short term, it may be possible to restrict conformance requirements involving protocols with associated type packs to scalar, non-pack type parameters.

### Accessing tuple elements as a pack

To achieve the goal of using variadic generics to generalize tuple types, this design includes the ability to access the elements of a tuple value as a value pack, unlocking all the same expressivity for tuples without introducing an additional set of operations for mapping, iteration, concatenation, and de-structuring.

An abstract tuple value contains a list of zero or more individual values. Packing the elements of a tuple removes the tuple structure, and collects the individual tuple elements into a value pack. This operation is a special property on tuple types called `.element`:

```swift
struct Mapped<Value> {}

func map<T...>(tuple: (T...)) -> (Mapped<T>...) {
  return (Mapped(tuple.element)...)
}
```

The `element` property returns the elements of a tuple in a single pack. For an abstract tuple `(T...)`, the signature of this property is `(T...) -> T`, which is otherwise not expressible in the language. For a tuple of length *n*, the complexity of converting a tuple value to a pack is *O(n)*.

Similar to concrete value packs, using the pack operation on concrete or partially concrete tuples requires a type annotation for the abstract element type:

```swift
func iterate(over tuple: (Int, String, Bool)) {
  for value: some Equatable in tuple.element... {
    // do something with an 'Equatable' value
  }
}
```

### User-defined tuple conformances

The above features together provide the necessary tools for writing abstractions over tuples with variable length. The last major expressivity gap between tuples and nominal types is the ability to declare conformances on tuples. This design finally closes that gap, using a parameterized extension syntax to declare the conformance:

```
extension <T...> (T...): P where T: P {
  // Implementation of tuples to 'P'
}
```

And with that, [SE-0283](https://github.com/apple/swift-evolution/blob/main/proposals/0283-tuples-are-equatable-comparable-hashable.md): Tuples Conform to `Equatable`, `Comparable`, and `Hashable` can be implemented in the Swift standard library with the following code:

```swift
extension <Element...> (Element...): Equatable where Element: Equatable {
   public static func ==(lhs: Self, rhs: Self) -> Bool {
    let leftElement = lhs...
    let rightElement = rhs...
    for (left, right) in (leftElement, rightElement)... {
      guard left == right else { return false }
    }
    return true
  }
}

extension<Element...> (Element...): Comparable where Element: Comparable {
  public static func <(lhs: Self, rhs: Self) -> Bool { 
    let leftElement = lhs...
    let rightElement = rhs...
    for (left, right) in (leftElement, rightElement)... {
      if left < right { return true }
      if left > right { break }
    }
    return false
  }
}

extension<Element...> (Element...): Hashable where Element: Hashable {
  public func hash(into hasher: inout Hasher) {
    for element in self... {
      hasher.combine(element)
    }
  }
}
```

## The distinction between packs and tuples

Packs and tuples differ in the type system because a type pack itself is not a type while a tuple itself is a type. A type pack is composed of individual types, and type packs are only usable in positions that naturally accept a list of zero or more types, such as generic argument lists. On the other hand, a tuple can be used anywhere an individual type can be used. The following code demonstrates the semantic differences between using a tuple value versus accessing its elements as a pack:

```swift
func printPack<U...>(_ u: U...) {
  print("u := {\(u...)}")
}

func print4Ways<T...>(tuple: (T...), pack: T...) {
  print("Concatenating tuple with pack")
  printPacks(tuple, pack...)
  print("\n")

  print("Concatenating tuple element pack with pack")
  printPacks(tuple.element..., pack...)
  print("\n")

  print("Expanding tuple with pack")
  _ = (printPacks(tuple, pack)...)
  print("\n")

  print("Expanding tuple element pack with pack")
  _ = (printPacks(tuple.element, pack)...)
  print("\n")
}

print4Ways(tuple: (1, "hello", true), pack: 2, "world", false)
```

The output of the above code is:

```
Concatenating tuple with pack
u := {(1, "hello", true), 2, "world", false}

Concatenating tuple element pack with pack
u := {1, "hello", true, 2, "world", false}

Expanding tuple with pack
u := {(1, "hello", true), 2}
u := {(1, "hello", true), "world"}
u := {(1, "hello", true), false}

Expanding tuple element pack with pack
u := {1, 2}
u := {"hello", "world"}
u := {true, false}
```

The concept of a pack is necessary in the language because though tuples can have an abstract length, there is a fundamental ambiguity between whether a tuple is meant to be used as a single type, or whether it was meant to be exploded to form a flattened comma-separated list of its elements:

```swift
func variadicPrint<T...>(_ t: T...) { ... }

func forward(tuple: (Int, String Bool)) {
  // Does this print three comma-separated values, or a tuple?
  variadicPrint(tuple)  
}
```

Packs can also be used in the parameter list of a function type; if packs were tuples, generic code would be unable to abstract over function types with variable length parameter lists.

## Exploring syntax alternatives

This design for variadic generics results introduces 2 new meanings of `...`, leaving Swift with 4 total meanings of `...`:

1. Non-pack variadic parameters
2. Postfix partial range operator
3. Type parameter pack declaration
4. Pack expansion operator

Choosing an alternative syntax may alleviate ambiguities with existing meanings of `...` in Swift. The authors of this vision document are open to considering an alternative syntax, but have yet to find a more compelling one.

### Pack and unpack keywords

Another alternative is to use keywords for pack declarations and pack expansions, e.g.

```swift
func zip<pack T, pack U>(_ first: unpack T, and second: unpack U) -> (unpack (T, U)) {
  return (unpack (first, second))
}
```

The downsides to choosing a keyword syntax are:

* A keyword with a parenthesized operand in expression context is subtle because it looks like a function call rather than a built in expansion operation.
* A new keyword in expression context would break existing code that uses that keyword name, e.g. as the name of a function.
* A contextual keyword must be resolved in the parser, meaning there is no room for moving resolution of the unpack/expansion operation to later in type checking, e.g. to support member packs. The `unpack` keyword would need to instead be a special built-in function or method at the expression level, and a keyword at the type level.

### Alternative postfix operators

One alternative is to use a different operator, such as `*`, instead of `...`

```swift
func zip<T*, U*>(_ first: T*, and second: U*) -> ((T, U)*) {
  return ((first, second)*)
}
```

The downsides to postfix `*` include:

* `*` is subtle.
* `*` evokes pointer types / a dereferencing operator to programmers familiar with other languages including C/C++, Go, and Rust.
* Another operator does not alleviate the ambiguities in expressions, because values could have a postfix `*` operator or any other operator symbol, leading to the same ambiguity.