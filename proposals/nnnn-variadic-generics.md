# Variadic Generics

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Robert Widmann](https://github.com/codafi)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

Functions that take a variable number of arguments have proven to be an effective tool in Swift. Up to now, these functions could only accept a single type of argument. Authors have worked around this restriction by using less specific types like `Any` or by creating lots of overloaded boilerplate code at each argument arity. 

Generic programming provides an effective answer to these challenges. This proposal seeks to unify Swift’s generic programming capabilities with its variable-arity programming features by adding *variadic generics* to Swift.

## Motivation

Functions and aggregate types in Swift currently require a fixed number of generic arguments. To support functions that need to take an arbitrary number of arguments of any type, Swift currently requires erasing all the types involved. A prime example of this kind of function is `print`, which is declared with the following signature in the Swift standard library:

```
`func print(_ items: Any..., separator: String = " ", terminator: String = "\n")`
```

The `print` function uses a number of runtime tricks to inspect the type of each argument in the pack of existential `items` and dispatch to recover the appropriate description. But we also have many situations where the user wants to write a type-safe, generic, variadic function where the types of the arguments *cannot* be erased in this manner. 

SwiftUI’s primary result builder is a type called `ViewBuilder`. Today, `ViewBuilder` is artificially constrained to accept between 0 and 10 sub- `View` elements of differing types. What’s more, for each given arity, [a fresh declaration of buildBlock must be given](https://developer.apple.com/documentation/swiftui/viewbuilder/buildblock()), which leads to an explosion in the amount of boilerplate necessary to build the strongly-typed API that such a library desires. What would be ideal is if the Swift language provided a built-in way to express variadic generic functions. For our SwiftUI example above, we would like to write one and only one `buildBlock` function.

```
extension ViewBuilder {
    public static func buildBlock<V...>(views: V...) -> (V...) 
      where V: View
    {
        return views
    }
}
```

Finally, tuples have always held a special place in the Swift language, but working with arbitrary tuples remains a challenge today. In particular, there is no way to extend tuples, and so clients like the Swift Standard Library must take a similarly boilerplate-heavy approach and define special overloads at each arity for the comparison operators. There, the Standard Library chooses to artificially limit its overload set to tuples of length between 2 and 7, with each additional overload placing ever more strain on the type checker. Of particular note: This proposal lays the ground work for non-nominal conformances, but syntax for such conformances are **out of scope**.

## Proposed solution

We propose the addition of *generic parameter packs* to Swift’s generics. These packs enable types and functions to declare that they accept a variable number and type of argument:

```
// 'max' accepts a pack of 0 or more Comparable 'T's
func max<T...>(_ xs: T...) -> T? where T: Comparable { /**/ }

// Tuple<T, U, V, ...> accepts a pack of element types
struct Tuple<Elements...> { /**/ }
```

To support the ability to store and return parameter packs, we propose the addition of *pack expansion* types to Swift.

```
// The return type of this function '(T...)' is a pack expansion. It lets you
// gather variadic arguments together into a generic tuple-like value 
//
// let (s, i, d) = tuple("Hi", 42, 3.14) // : (String, Int, Double)
// let s = tuple("Hi") // : String
// _ = tuple() // ()
func tuple<T...>(_ xs: T...) -> (T...) { return xs } 

// You can have stored properties with a pack expansion as a type
struct Tuple<Elements...> { 
  var elements: (Elements...)
  init(elements: Elements...) { self.elements = elements }
}
```

## Detailed design

### Variadic Generic Parameters

Variadic generic parameter declarations are formed from “plain” generic parameter declarations plus the addition of trailing triple dots as in `func tuple<Elements...>`. Similarly, a type may declare a variadic generic parameter `struct Tuple<T...>`.  A function may have any number of variadic generic parameters. Types, by contrast, support only one variadic generic parameter because of a lack of delimiter when instantiating them

```
func double<Ts..., Us...>(ts: Ts..., us: Us...) { /**/ } // ok
```

```
struct Broken<T..., U...> { /**/ }
typealias Bar = Broken<String, Int, Void> // Which types are bound to T... and U...?
```

### **Generic Parameter Packs**

Swift already has a syntax for variadic parameters in functions:  `xs: T...`, as well as a number of rules around variadic applies that are already semantically well-formed. We choose to overload the syntax of variadic parameters to inherit this behavior, but also to show by extension that the semantics of variadic generic parameters are no different than those of monomorphic variadic parameters.

There is one peculiarity of this choice, though. Today, the interface type of `xs: T...` is sugar that produces an array type. This allows the user to reason about variadic parameters as a high-level container type. Parameters of variadic generic type will similarly implicitly construct a container type. However, instead of an array type, variadic generic parameters will be a new kind of container: *packs*. One can read the parameter in the following function as “`elements` is a pack of Ts”

```
func tuple<Ts...>(_ elements: Ts...) {}
```

The type parameter `Ts` is the “pattern type” of the constituent elements of the pack. It need not solely be a reference to a variadic generic parameter. The following demonstrates more advanced usages of pattern types in packs:

```
// This function: 
// - Takes a variadic sequence of (possibly-distinct) arrays of optional values
// - Removes the optional values from each one
// - Returns a pack with arrays sans `nil` elements.
func flattenAll<Ts...>(_ seqs: [Ts?]...) -> ([Ts]...) { 
  return seqs.map { $0.compactMap { $0 } }
}
```

### **Pack Expansions**

In order to support parameter packs in the return position of functions and as stored properties, we will need to introduce new syntax. At the type level, a parameter pack is nothing more than a tuple-like value with its elements and arity presented abstractly. Swift already has a natural space in its tuple syntax for just this operation: `(T...)` - read as the “pack expansion of `T`”. As the name implies, the type of the elements of `(T...)` are precisely the types of the elements of the pack used to construct `T...` when the function is called. Put another way, `(T...)` “unfolds” to become the (tuple) type of the elements provided to its parent variadic generic function. Returning to the variadic identity function from before:

```
func tuple<T...>(_ xs: T...) -> (T...) {
  return xs
}

tuple() // xs: Void
tuple(42) // xs: (Int) = Int
tuple(42, "Hello") // xs: (Int, String)
```

This is an extremely powerful typing rule, as it allows for the output of a function to observe the arity of its inputs - a form of dependent typing.

One other thing to observe about this example is that we do not require any special syntax to convert an input parameter pack to an output expansion. Because we take the view that the pack itself is a scalar object, there is no need to present a user-visible syntax to “splat” its elements. We simply forward the pack on, or transform it - by analogy with existing variadic parameters.

### **Iteration**

Going further, we can extend existing language constructs to support values with variadic types to enable a much more fluid syntax. Consider a slightly modified typesafe variadic version of `print`:

```
func printTypes<Args...>(_ items: Args...) {
  for (item: Args) in items {
    print(type(of: item), item)
  }
}
```

This proposed syntax uses Swift’s existing for-in loop construct to enable iteration over a pack. This shows how we can manipulate individual elements of the parameter pack one-by-one and can be accomplished with a builtin conformance of packs to `Sequence`.

Simultaneous operations on every element of a pack are also extremely important to have as language primitives. To support this, pack types will come with a “magic map” operation that functions identically to [its cousin for Swift Sequences](https://developer.apple.com/documentation/swift/sequence/3018373-map) - only this time it transforms the elements of a pack. A hypothetical internalization of this function is

```
extension<T...> (T...) {
  public func map<U...>(_ transform: (T) throws -> U) rethrows -> (U...) { /**/ }
}
```

### **Forwarding**

Implementations of variadics inevitably run into the problem of how to send one pack of arguments to another function that accepts a parameter pack. This is usually achieved via an operation called “splat” or “explode”, and one can think of it as taking a pack, breaking it down into its component parts, then calling the function. This usually involves special syntax like `*` in Ruby and Python, or C++‘s trailing `...` syntax (read as “pack out”). Since this proposal takes the tact that packs are values in their own right, we see no need for additional syntax. Therefore, we propose the removal of the restriction on passing variadic arguments to variadic parameters. 

```
func forward<T...>(_ xs: T...) { return onwards(xs) }
func onwards<T...>(_ xs: T...) { /**/ }
```

A variadic argument is said to “saturate” a variadic parameter which means you cannot provide additional arguments before or after forwarding a variadic argument:

```
func forward<T...>(_ xs: T...) { 
  onwards(xs, "oops") // error: Too many arguments to 'onwards'!
  onwards("oops", xs) // error: Too many arguments to 'onwards'!
}
func onwards<T...>(_ xs: T...) { /**/ }
```

As a historical note, Swift already has the ability to forward (plain) variadic parameters, the user just cannot spell it. Internally, the implementation of compiler-provided overrides of variadic initializers (among other synthesized language elements) produces a variadic-to-variadic conversion on your behalf.

At the type level, it is also useful to be able to forward a pack of arguments to another pack of arguments. But it is *also* useful to forward the pack of elements as a single tuple type. To support both of these behaviors, a pack expansion type `T...` appearing bound as a generic parameter will act to forward any expanded elements.

```
struct Forward<T...> {}
typealias Onwards<T...> = Forward<T...>

// Onwards<Int, String, Void> = Forward<Int, String, Void>
```

While a pack expansion type appearing parenthesized in this same position will act to bind a single tuple type after it has been expanded

```
struct Forward<T...> {}
typealias Onwards<T...> = Forward<(T...)>

// Onwards<Int, String, Void> = Forward<(Int, String, Void)>
```

### **All Together Now**

Using all of these concepts, we present a generalization of the standard library’s `zip` function to an arbitrary number and kind of sequences:

```
public func zip<Sequences...>(_ seqs: Sequences...) -> ZipSequence<Sequences...> 
  where Sequences: Sequence
{
    return ZipSequence(seqs)
}

public struct ZipSequence<Sequences...>: Sequence
  where Sequences: Sequence 
{

  private let seqs: (Sequences...)
  
  public init(_ seqs: Sequences...) {
      self.seqs = seqs  
  }
  
  public func makeIterator() -> Self.Iterator {
    return Self.Iterator(self.sequences)
  }
  
  public struct Iterator : IteratorProtocol {
    private enum Stop { case iterating }
    
    public typealias Element = (Sequences.Element...)
    
    private var reachedEnd = false
    var iterators: (Sequences.Iterator...)

    init(_ iterators: Sequences...) {
      self.iterators = iterators.map { $0.makeIterator() }
    }

    public mutating func next() -> Element? {
      if reachedEnd { return nil }

      guard 
        let values = try? iterators.map({ 
          guard let next = $0.next() else { throw Stop.iterating } 
          return next
        })
      else {
        reachedEnd = true
        return nil
      }
      return values
    }
  }
}
```

### Semantic Constraints

* A pack expansion that does not involve a variadic generic parameter is ill-formed outside the body of a function or closure

```
typealias Nope = (Int...)
typealias Nope<Again> = (Again...)

func nope<T...>(_ xs: T...) -> (Int...) {}

struct Nope {
  var xs: (Int...)
}

func ok<T...>(_ xs: T...) {
  let zeroes: (Int...) = xs.map { 0 }
  // There's not much you can do with this value...
  
  struct NestedNope {
    var zeroes: (Int...) // Nope!
  }
}
```

* Pack expansion types may not appear in associated type requirements for protocols. They may, however, appear in type witnesses themselves

```
protocol Nope { associatedtype (Ts...) }
```

* Parameters of pack type cannot be `inout`, in keeping with existing language restrictions

```
func foo<T...>(_ xs: inout T...) {} // 'inout' must not be used on variadic parameters

// This doesn't work either!
func foo<T>(_ xs: inout T...) {} // 'inout' must not be used on variadic parameters`
```

* Pack expansion types may not appear in inheritance clauses

```
protocol Nope : (T...) {}
class Nope<Again...> : (Again...) {}
```

* A pack expansion type may not appear in the position that would otherwise bind a non-variadic generic parameter

```
struct Singleton<T> {}
typealias PackOf<Ts...> = Singleton<Ts...> // Oops!
```

* The arity of an argument pack must remain consistent when variadic generic types are mentioned in multiple parameters

```
// 'first' mentions T... and U..., so it must have the
// same arity as 'second' which mentions 'T...' and
// the same arity as 'third' which mentions 'U...'
func foo<T..., U...>(
  first: [T: U]...,
  second: T...,
  third: U...
) where T: Hashable

foo(first: [String:Void](), second: "K", third: ()) // ok
foo(first: [String:Void](), second: "K", "L", third: ()) // nope!
```

* Equality constraints between variadic generic parameters must similarly only involve other variadic generic parameters.

```
func foo<T..., U>() where T == U // nope!
```

* Equality constraints that would concretize a pack expansion type are banned.

```
func foo<T..., U>() where (T...) == (Int, String, Void) // nope! 
```

### Grammatical Ambiguities

The use of `...` in parameter lists to introduce a generic variadic parameter introduced a grammatical ambiguity with the use of `...` to indicate a (non-generic) variadic parameter. The ambiguity can arise when forming a pack expansion type. For example:

```
struct X<U...> { }

struct Ambiguity<T...> {
  struct Inner<U...> {
    typealias A = X<(T...) -> U...>
  }
}
```

Here, the `...` within the function type `(T...) -> U` could mean one of two things:

* The `...` defines a (non-generic) variadic parameter, so for each element `Ti` in the parameter pack, the function type has a single (non-generic) variadic parameter of type `Ti`, i.e., `(Ti...) -> U`. So, `Ambiguity<String, Character>.Inner<Float, Double>.A` would be equivalent to `X<(String...) -> Float, (Character...) -> Double>`.
* The `...` expands the parameter pack `T` into individual parameters for the function type, and no variadic parameters remain after expansion. Only `U` is expanded by the outer `...`. Therefore, `Ambiguity<String, Character>.Inner<Float, Double>.A` would be equivalent to `X<(String, Character) -> Float, (String, Character) -> Double>`.

If we take the first meaning, then it is hard to expand a parameter pack into separate function parameter types, which is necessary when accepting a function of arbitrary arity, e.g.,

```
func forwardWithABang<T..., R>(_ args: T?..., body: (T...) -> R) -> R {
  body(args.map { $0! })
}
```

Therefore, we propose that the `...` in a function type be interpreted as a pack expansion type when the pattern of that type (e.g., the `T` in `...`) involves a parameter pack that has not already been expanded. This corresponds with the second meaning above. It is source-compatible because the “pattern” for existing code will never contain a parameter pack.

With this scheme, it is still possible to write code that produces the first meaning, by abstracting the creation of the function type into a `typealias` that does not involve any parameter packs:

```
struct X<U...> { }

struct AmbiguityWithFirstMeaning<T...> {
  struct Inner<U...> {
    typealias VariadicFn<V, R> = (V...) -> R
    typealias A = X<VariadicFn<T, U>...>
  }
}
```

Note that this ambiguity resolution rule relies on the ability to determine which names within a type refer to parameter packs. Within this proposal, only generic parameters can be parameter packs and occur within a function type, so normal (unqualified) name lookup can be used to perform disambiguation fairly early. However, there are a number of potential extensions that would make this ambiguity resolution harder. For example, if associated types could be parameter packs, then one would have to reason about member type references (e.g., `A.P`) as potentially being parameter packs.

## Source compatibility

The majority of the elements of this proposal are additive. However, the use of triple dots `...` in the type grammar has the potential to conflict with the existing parsing of user-defined operators. Take this stream of tokens:

```
T...>foo
```

This has the potential to be parsed as an operator `...>` applied to two arguments as in

```
(T) ...> (foo)
```

or as a fragment of a generic parameter as in

```
/*HiddenType<*/T...> foo
```

To break this ambiguity, in function declarations and type expressions we require that the dots `...` *always* bind to their preceding generic parameter, if any.

We strongly suspect there are little to no libraries taking advantage of this kind of operator overloading, but we wish to call it out as it creates a new reserved class of expression in the grammar.

## Effect on ABI stability

This proposal is additive, and has no affect on the existing ABI of libraries.

## Effect on API resilience

This proposal is additive, and has no affect on the existing API of libraries.

## Alternatives considered

There are a number of alternative formulations of variadics that have been implemented in many different languages. The approach detailed here is particularly inspired by the work of [Felleisen, Strickland, and Tobin-Hochstadt](https://link.springer.com/content/pdf/10.1007/978-3-642-00590-9_3.pdf) who presented the bones of the inference algorithm needed to implement the type system extensions.

### Explicit Syntax for Pack Expansion in Expressions

“Magic map” is a way to sidestep this particular requirement of C++‘s implementation of variadics. There, `...` in postfix position in an expression directs the compiler to syntactically expand any packs in the preceding expression and optionally [“fold” it around an operator](https://en.cppreference.com/w/cpp/language/fold). Explicit pack expansion syntax has a number of upsides, but it also complicates the forwarding story presented above. Most glaringly, Swift already has a meaning for postfix `...` in expression position with [one-sided ranges](https://github.com/apple/swift-evolution/blob/main/proposals/0172-one-sided-ranges.md).

### Alternative Syntax for Variadic Generic Parameters/Expansions

We chose `...` by analogy with Swift’s existing syntax for variadic parameters. However, there’s no reason we cannot pick a different syntax, especially one that does not conflict with one-sided ranges. Suggestions from [the first pitch thread](https://forums.swift.org/t/pitching-the-start-of-variadic-generics/51467) include: `T*`, `*T`, `variadic T`, `pack T`, `T[]`, and many more.

## Future directions

### Non-Nominal Conformances

We do not explicitly propose a syntax for non-nominal extensions and protocol conformances involving pack types. In concert with [parameterized extensions](https://github.com/apple/swift/blob/main/docs/GenericsManifesto.md#parameterized-extensions), however, there is a natural syntax: 

```
extension<T...> (T...) {
  public var count: Int { /**/ }
}

extension<T...> (T...): Equatable where T: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool { 
    for (l, r) in zip(lhs, rhs) {
      guard l == r else { return false }
    }
    return true
  }
}

extension<T...> (T...): Comparable where T: Comparable {
  public static func < (lhs: Self, rhs: Self) -> Bool { 
    guard lhs.count > 0 else { return true } 
    
    for (l, r) in zip(lhs, rhs) {
      guard l < r else { return false }
    }
    return true
  }
}
```

```
import SwiftUI

extension <T...> (T...): View where T: View {
    var body: some View { /**/ }
}
```

### Additional Structural Pack Operations

A natural extension to this feature set is the ability to concatenate and destructure compound pack expansion types and their corresponding values. To support the former, a magical `append` function could be added that looks as follows:

```
extension<T...> (T...) {
  public func append<U...>(_ xs: U...) -> (T..., U...) { /*poof!*/ }
}
```

To support the latter, the ability to abstract over multiple values in patterns is needed:

```
let (first, remaining...) = ("A", "B", "C").append(1, 2, 3)
// first: String, last: (String, String, Int, Int, Int)
```

It would also make sense to support the mixing of pack expansions with normal tuple element types as in

```
func atLeastTwo<T, U, V...>(_ x: T, _ y: U, v: V...) -> (T, U, V...) {
  return (x, y).append(v)
}

let (x, y, rest...) = atLeastTwo("Hello", 42) // rest: ()
```

### Explicit Arity Constraints

We could allow users to reason explicitly about the arity of packs. In particular, they could present inequalities to the type checker and those could, in turn, restrict the types of packs allowed at a particular apply. A purely illustrative example is:

```
extension <T...> (T...) where (T...).count >= 4 {}
```

