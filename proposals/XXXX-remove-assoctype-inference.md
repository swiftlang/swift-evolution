# Remove associated type inference

* Proposal: [SE-NNNN](NNNN-remove-assoctype-inference.md)
* Author: Austin Zheng
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

In Swift, a type `T` may choose to conform to a protocol `P`, where `P` has [associated types](https://developer.apple.com/library/ios/documentation/Swift/Conceptual/Swift_Programming_Language/Generics.html#//apple_ref/doc/uid/TP40014097-CH26-ID189) that may be used in the protocol requirements. If the associated types are used in the requirements, the types that `T` chooses to bind those associated types to can currently be inferred by the type checker by examining how `T` chooses to implement `P`'s requirements:

```swift
// This protocol is used in subsequent examples throughout the document.
protocol SimpleCollection {
	associatedtype Element
	func object(at index: Int) -> Element?
}

class StringBag : SimpleCollection {
	func object(at index: Int) -> String? {
		// ...
	}
}
```

In this example, the typechecker deduces that `StringBag.Element` is `String` through the way the `object(at:)` requirement is implemented.

In order to simplify the compiler and typechecker, we propose to **remove associated type inference** and require users to explicitly bind their associated types using an `associatedtype` declaration.

swift-evolution thread: [pre-proposal](http://thread.gmane.org/gmane.comp.lang.swift.evolution/21714)

## Motivation

According to *[Completing Generics](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md#associated-type-inference)*:

> [...] associated type inference is the only place in Swift where we have a global type inference problem: it has historically been a major source of bugs, and implementing it fully and correctly requires a drastically different architecture to the type checker.

There are three main advantages to removing type inference and requiring explicit declarations:

1. It improves the type system's function as a form of code documentation by making it very clear to readers of a type declaration how the type's associated types are defined.

	Rather than having to look through protocol requirement implementations (which can't be differentiated from 'normal' type members by sight) and piece out the associated types, the associated types are explicitly declared. A distinction is also made between associated types and whatever type aliases are defined for convenience purposes.

2. It decreases the complexity of the type checker.

	This has a number of advantages: it removes the only aspect of Swift that depends upon global type inference. Simplifying the type checker makes it easier to improve the performance and correctness of the type checker code. Given that both are widely acknowledged issues with current versions of Swift, any opportunity for improvement should be carefully considered.

	As Douglas Gregor (original author of the relevant type inference code) [puts it](http://article.gmane.org/gmane.comp.lang.swift.evolution/22058):

	> Because this is the only place we do global type inference, it’s put tremendous pressure on the type checker that caused a huge number of bugs, crashes, and outright incomprehensible behavior. [...] [The re-implementation is] still not global *enough* to actually be predictable, and the legacy of this mis-feature manifests in a number of weird ways (e.g., typealiases in protocol extensions cannot be used to satisfy associated type requirements, weird rules for when a defaulted associated type gets used).

3. It makes it significantly easier for those learning the language to understand how associated types work.

	This proposal introduces a symmetry between the *declaration* of an associated type in a protocol, and the *binding* of that same associated type in a conforming type. Both declarations use the `associatedtype` keyword. This harmonizes the semantics of associated types with those of other protocol components (such as member requirements), all of which are declared in the protocol and then 'bound' or 'defined' in the conforming type using similar syntax:

	```swift
	protocol P {
		// Associated type declaration
		associatedtype A

		// Method requirement declaration
		func foo() -> Int
		
		// Property requirement declaration
		var bar : A { get }
	}

	class C : P {
		// Associated type conformance
		associatedtype A = String

		// Method requirement conformance
		func foo() -> Int { return 1234 }

		// Property requirement conformance
		var bar : String {
			get {
				return "foobar"
			}
		}
	}
	```

## Proposed solution

Types conforming to one or more protocols with associated types will be required to explicitly bind the associated types belonging to those protocols to specific types using an `associatedtype` declaration. In the following example, taken from the introduction, `StringBag.Element` is explicitly defined to be of type `String`.

```swift
class StringBag : SimpleCollection {
	associatedtype Element = String
	
	func object(at index: Int) -> String? { /* ... */ }
}
```

Once an associated type is bound in this way, it can be used as if it were a type alias:

```swift
class StringBag : SimpleCollection {
	associatedtype Element = String

	// Okay
	func object(at index: Int) -> Element? { /* ... */ }
}
```

## Detailed design

Associated type requirements declared in a class `C` need not be redeclared in any subclasses of `C`:

```swift
class FixedSizeStringBag : StringBag {
	// No need to redeclare 'Element'

	// ...
}
```

An associated type requirement may reference or shadow a typealias or a nested type. (However, even if a typealias or nested type named the same as an associated type exists, the `associatedtype` declaration is still required for that associated type.)

```swift
// Typealias
class FixedSizeStringBag : StringBag /*, SimpleCollection */ {
	typealias Element = String
	associatedtype Element = Element
}

// Nested type
class FooBag : SimpleCollection {
	// Note that omitting the following declaration is an error.
	associatedtype Element = Foo
	struct Foo { /* ... */ }
}

// Retroactive modeling:
class IntBag { 
	typealias Element = Int
	// ...
}

extension IntBag : SimpleCollection {
	associatedtype Element = Element
}
```

It will become an error to define or redefine a typealias within the scope of a type which is named the same as an associated type, but is bound to a different type. Likewise, it will become an error to bind an associated type named the same as a nested type to a type other than that nested type:

```swift
class FixedSizeStringBag : StringBag {
	// NOT ALLOWED, since Element was declared in StringBag to be String, and
	// the associated type Element was bound to String.
	typealias Element = Bool
}

class FooBag : SimpleCollection {
	struct Element { /* ... */ }

	// NOT ALLOWED, since Element is already a nested type.
	associatedtype Element = Int
}

class BarBag : SimpleCollection {
	typealias Element = String

	// NOT ALLOWED, since Element is already a typealias for String.
	associatedtype Element = Int
}
```

Associated type declarations cannot be used to bind typealiases defined in protocols. However, normal `typealias` declarations will be allowed to shadow those protocol typealiases.

```swift
// A future definition of Sequence, with convenience typealias
protocol Sequence {
	// ...
	typealias Element = Iterator.Element
}

class ListOfItemsAndMetadata<(T, Metadata)> : Sequence {
	// NOT ALLOWED, "Element" is not a valid associated type
	associatedtype Element = T

	// Required
	associatedtype Iterator = ListIterator<(T, Metadata)>

	// Allowed
	typealias Element = T
}
```

Associated types do not have to bound if the protocol defines a default type satisfying that associated type. However, if two or more protocols define different default types for the same associated type, the conforming type must explicitly bind the associated type.

```swift
protocol FooProtocol {
	associatedtype A = Int
}

class SomeClass : FooProtocol {
	// ...
}

protocol BarProtocol {
	associatedtype A = String
}

class AnotherClass : FooProtocol, BarProtocol {
	// Necessary, because there is more than one possible default value.
	associatedtype A = Int
	// ...
}
```

### (addendum) Limited type inference using `@infers(T)`

Dmitri Gribenko proposed an solution in which associated type inference is kept, but limited in the following way:

For each associated type `A` defined in a protocol, at most one requirement can be marked with the annotation `@infers(A)`. That requirement must contain `A` in its definition (for example, as an argument or return type for a method), and that requirement is the sole determinant of how `A` is bound. For example:

```swift
protocol Collection {
	associatedtype Index
	associatedtype Element

	@infers(Index)
	var startIndex: Index { get }

	var endIndex: Index { get }

	@infers(Element)
	var first : Element? { get }

	// ...
}
```

In the following declaration, the `startIndex` requirement would be considered to bind `Index`. For example, if a conforming type `Z` implemented `startIndex` as a property returning an `Int`, the type inference engine would then bind `Z.Index` to `Int`. If, for example, `endIndex` was then implemented to return a `String`, the type inference engine would immediately reject the code as ill-typed.

The following will be considered errors, for any given associated type `A`:

* Marking more than one requirement with `@infers(A)`
* Marking a requirement that does not involve `A` with `@infers(A)`

Any associated type `A` without a corresponding `@infers(A)` annotation would need to be explicitly bound, as per the main body of the proposal.

This addendum would significantly reduce boilerplate when defining types conforming to protocols with a large number of simple associated type requirements, at the cost of very slightly reducing the documentation value of the `associatedtype` declaration, and is presented here for consideration by the reviewers.

Douglas Gregor's [thoughts on this approach](http://article.gmane.org/gmane.comp.lang.swift.evolution/22067).

## Impact on existing code

Swift source code containing types conforming to protocols with associated types will need to explicitly define their associated types using the syntax detailed in the proposal. If they are using `typealias` to do so currently, they will need to replace that keyword with `associatedtype`.

## Alternatives considered

A couple of alternatives follow.

### Keep the current behavior

The current behavior is kept. Swift will continue to allow associated types to be inferred.

There are some advantages to this approach. Brevity is slightly improved. A type's associated types don't "stand out" in the type declaration, being unobtrusively and implicitly defined through the implementation of protocol requirements.

As well, Dave Abrahams expresses a [potential issue](http://article.gmane.org/gmane.comp.lang.swift.evolution/21892):

> Finally, I am very concerned that there are protocols such as `Collection`, with many inferrable associated types, and that conforming to these protocols could become *much* uglier.

As with many proposals, there is a tradeoff between the status quo and the proposed behavior. As *Completing Generics* puts it,

> Is the value of this feature worth keeping global type inference in the Swift language [...]?

### Require associated types to be declared, but use `typealias`

Behavior is identical to the behavior outlined in the main body of the proposal, but `typealias` is used instead of `associatedtype`, and a nested type `N` in a parent type `S` named identically to an associated type (e.g. `P.N`) can be used to define `S.N` when conforming to `P`.

The main advantage of this alternative is that it is already legal to declare an associated type conformance explicitly using `typealias AssocType = ConcreteType`. In fact, in cases where inference is impossible (for example, an associated type is not used in any requirement or defined as a nested type), explicit declaration is already required. As such, the syntactic scope of this proposal would be significantly smaller: simply making a valid but optional declaration a requirement.

There are a few disadvantages to this option. First, it makes no distinction between `typealias` declarations used to bind associated types, and those used to declare convenience typealiases. Second, in subclasses of classes that conform to a protocol, it can be used to misleadingly imply that an associated type is different from the value it is actually bound to. Both disadvantages substantially decrease the value of this proposal as a way to improve documentation of code semantics.

Example:

```swift
class OddStringBag : StringBag {
	// You can do this today, but OddStringBag.Element is still 'String'
	typealias Element = Int
}

func doSomething<T : SimpleCollection>(x: T) {
  print("Element is: \(T.Element.self)")
}

// Prints out "Element is: String"
doSomething(OddStringBag())
```

We could disallow the second behavior in an alternative proposal, but at the risk of increasing the complexity of the alternative proposal to a point where the advantages over the main proposal disappear.

### As written, but remove `typealias` aliasing restrictions

The proposal currently prohibits defining or redefining a `typealias` with the same name as an associated type, but bound to a different actual type than that associated type.

This prohibition can be removed without introducing ambiguity. Doing so would allow an associated type named `A` to be bound to a different type than an existing typealias also named `A`.

This addendum would remove the ability of an `associatedtype` binding declaration to serve as a typealias. In this case, an `associatedtype A = P` declaration does not expose `A` for use elsewhere in the type as a typealias, unless explicitly defined by a separate `typealias` declaration:

```swift
protocol Foo {
	associatedtype A
}

class SomeClass : Foo {
	associatedtype A = Bool

	// NOT ALLOWED, A is not a typealias
	func foo() -> A { return true }
}

class AnotherClass : Foo {
	typealias A = Int
	associatedtype A = String

	// Returns 'Int'
	func foo() -> A { return 1234 }
}
```

The main advantage of this alternative is that it makes Swift even more expressive than it currently is: restrictions on associated types could conceivably be loosened such that an associated type can be arbitrarily bound, even if there exists a typealias or nested type with the same name as that associated type. (This is not currently possible.)

The main disadvantage is that it decreases clarity.

Swift's current behavior is to limit the ability to perform retroactive modeling in situations where it would be semantically ambiguous. For example, a type cannot bind an associated type differently for each of two protocols, even if the name of that associated type has a different meaning for each protocol. As well, if a type contains a nested type named the same as an associated type, it cannot rebind that associated type.

My opinion is that the proposal as described in this document retains the current level of expressiveness and also significantly increases the clarity of code. This alternative is presented in order that it might be discussed and adopted if the community and reviewers feel otherwise.
