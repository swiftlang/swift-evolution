# New mechanism to combine `Types` with/or `Protocols`

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Adrian Zubarev](https://github.com/DevAndArtist)
* Status: [Awaiting review](#rationale)
* Review manager: TBD

## Introduction

The current `protocol<>` mechanism defines the `Any` protocol to which all types implicitly conform. It also can combine distinct protocols to a new `Protocol`, whereas combinging `SubProtocol` with its `BaseProtocol` will be inferred as `SubProtocol` (the order withhin the angle brackets doesn't matter). I propose to replace the current `protocol<>` mechanism with a new more powerful mechanism called `Any<>`, which will allow combining `Types` with independent `Protocols` and enforce *multiple* constraints. 

Swift-evolution thread: [\[Pitch\] Merge `Types` and `Protocols` back together with `type<Type, Protocol, ...>`](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160502/016523.html)

## Important note

Because this proposal will break existing code and some Swift 3 features are not rock solid yet.
This proposal will only define the **simple/base `Any<>`** version. *Enhanced existential support* can be added without breaking `Any<>` in a future version of Swift and needs its own [proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160516/017917.html).

## Motivation

The motivation for this proposal comes from solving the missing `Type` issue ([rdar://20990743](https://openradar.appspot.com/20990743)) and combining the idea mentioned in the generics manifesto for Swift 3 in section [Renaming `protocol<...>` to `Any<...>`](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md#renaming-protocol-to-any-). 

The proposed mechanism will allow us to create a new `Type` from extendable distinct types - there are still some restrinctions you can read about below.

## Proposed solution

First step to implement this proposal would need to rename `protocol<>` to `Any<>` and configure the migration process to update code that used old style `protocol<>`.

Next the `Any<>` mechanism would be extended to allow nesting and at most one class type. When all types within angle brackets are indepented/distinct to each other a new `Type` will be formed by `Any<A, B, ...>`. This new `Type` can be used to store instances that conform to *multiple* constrains defined by `Any<>` without any generic context (see **Detailed design** for more information).

Here only some subtype of `UIView` (dynamic type) conforms to `SomeProtocol`, but both types within angle brackets are distinct.

```swift
protocol SomeProtocol {}
extension SomeProtocol {
	func foo() { print("fooooo") }
}

// we'll be able to store the new type without generics
class A {
	var view: Any<UIView, SomeProtocol>
	init(view: Any<UIView, SomeProtocol>) {
		self.view = view
	}
	
	// `dynamicType` of the `view` might be `UIButton` for example
	// but we still be able to acces SomeProtocol which only UIButton conforms to
	func doSomeWork() {
		self.view.removeFromSuperview() // just for a simple example
		self.view.foo() // prints "fooooo"
	}
}

extension UIButton: SomeProtocol {}

let button: SomeProtocol = UIButton() // split types for the example

if let mergedValue = button as? Any<UIView, SomeProtocol> {
	let a = A(view: mergedValue)
	a.doSomeWork()
}
```

## Detailed design

#### Rules for `Any<>`:
1. Empty `Any<>` will be used as `typealias Any = Any<>`. No constraints means it can accept any type or simply that all types implicitly conform to empty `Any<>`. This is the logical replacement for `typealias Any = protocol<>`.

2. The order of protocols within angle brackets doesn't matter: `Any<A, B> == Any<B, A>`. (The compiler already reorders protocols by its own will from `protocol<B, A>` to `protocol<A, B>` today.)

3. `Any<...>` can be composed from protocols and by the mention of this rule fully replace `protocol<...>` 

	* `Any<ProtocolA, ...>` equals to old `protocol<ProtocolA, ...>`
	* `Any<ProtocolX>` (redundant and should be banned) equals to old `protocol<ProtocolX>` or simply inferred as `ProtocolX`

4. `Any<...>` can contain at most one class type plus none or n protocols. The class type must be the first requirement, if present.

	* `Any<ClassType>` (redundant and should be banned) or `Any<ClassType, Protocol, ...>`
	* This rule will disallow `Any<...>` to contain unnecessary inheritance type branches.

5. Nesting `Any<...>` is allowed under special rules:

	* `A: Any<...>` can contain `B: Any<...>` if `B` is composed from protocols:
		* e.g. `Any<ClassType, Any<ProtocolA, ProtocolB, ...>>` will be inferred by the compiler as `Any<ClassType, ProtocolA, ProtocolB, ...>`
	* For class types nesting is allowed only when there is a inheritance relationship between all provided classes.
		* The complier will look for the class which is a subclass of every other class within such constraints and choose it as the `Any<...>` construct's constraint.
	* `Any<...>` can NOT contain empty `Any<>` or a single `Any<...>`.

	* Example made by [Matthew Johnson](https://github.com/anandabits):

	> ```swift
	> class B {}
	> class D: B, SomeProtocol {}
	> class E: D, AnotherProtocol {}
	> class Z: B {}
	> 
	> typealias TA = Any<B, AnotherProtocol>
	> typealias TA2 = Any<D, TA>
	> typealias TA3 = Any<E, TA2>
	> ```
	> Because the types specified form a linear path from subtype to supertype the composition of these type constraints would simply resolve to the deepest type in the subtype tree.  
	> 
	> However, we should not allow multiple types when there is not a strict subtype / supertype relationship between all of them whether we are composing Any or not.  For example, `B`, `D` and `E` can all be composed. `B` and `Z` can be composed. But `D` and `Z` can not be composed (nor `E` and `Z`).  And unrelated types such as `String` and `Int` cannot be composed.
		
8. All types should be checked againts each other to find a simplified `Type`. At the end all type dependencies should be distinct and will form a new constrained type. These constraints are then tested against the dynamic type.
	
	```swift
	protocol X {}   protocol Y: X {}
	class A: X {}   class B: Y {}
	
	Any<A, X, Y> /* inferred as */ Any<A, Y> 
	// e.g. will the above type accept `B` but not `A` as long `A` doesn't conform to `Y`
	```

9. `Any<>` can be an optional type `Any<>?` or `Any<>!`

#### Detailed design for `Any<...>` (below `type` is an extendable type):

1. `type A` can be applied to:
	
	| Type  | Equivalent inferred `Type` |
	|:------|:--------------------------:|
	| `A` | `A` |
	| `Any` | `Any<>` |
	| **BAN:** `Any<A>` | `A` |
	| **BAN:** `Any<Any, A>` | `A` |
	| **BAN:** `Any<Any>` | `Any<>` |

2. `type B: C`:
	* `class B: ProtocolC` can be applied to:
		
		| Type  | Equivalent inferred `Type` |
		|:------|:--------------------------:|
		| `B` | `B` |
		| `ProtocolC` | `ProtocolC` |
		| `Any` | `Any<>` |
		| **BAN:** `Any<ProtocolC>` | `ProtocolC` |
		| **BAN:** `Any<Any, ProtocolC>` | `ProtocolC` |
		| **BAN:** `Any<Any>` | `Any<>` |
		| **BAN:** `Any<B, ProtocolC>` | `B` |
		| **BAN:** `Any<B>` | `B` |
			
	* `class B: ClassC` can be applied to:

		| Type  | Equivalent inferred `Type` |
		|:------|:--------------------------:|
		| `B` | `B` |
		| `ClassC` | `ClassC`|
		| `Any` | `Any<>` |
		| **BAN:**`Any<ClassC>` | `ClassC`|
		| **BAN:**`Any<B>` | `B` |
		| **BAN:** `Any<Any>` | `Any<>` |
			
	* `protocol B: C` can be applied to:

		| Type  | Equivalent inferred `Type` |
		|:------|:--------------------------:|
		| `B` | `B`|
		| `C` | `C`|
		| `Any` | `Any<>` |
		| **BAN:** `Any<Any, B>` | `B`|
		| **BAN:** `Any<Any, C>` | `C`|
		| **BAN:** `Any<Any>` | `Any<>` |
		| **BAN:** `Any<B, C>` | `B` |
		| **BAN:** `Any<B>` | `B` |
		| **BAN:** `Any<C>` | `C` |
		
3. `type B` distinct to `C`:
	* `class B` and `protocol C` can be combined to `Any<B, C>`.
	* `protocol B` and `protocol C` can be combined to `Any<B, C>` or `Any<C, B>`.
	* `class B` and `class C` can NOT be combined (here 'distinct' means that there no inheritance relationship).

4. `type D: E, F` where `E` doesn't conform to `F`:
	* `class D: ClassE, ProtocolF` can be applied to:

		| Type  | Equivalent inferred `Type` |
		|:------|:--------------------------:|
		| `D` | `D` |
		| `ClassE ` | `ClassE ` |
		| `ProtocolF ` | `ProtocolF` |
		| `Any` | `Any<>` |
		| `Any<ClassE, ProtocolF>` | **NEW:** `Any<ClassE, ProtocolF>` |
		| **BAN:** `Any<ProtocolF>` | `ProtocolF` |
		| **BAN:** `Any<Any, ProtocolF>` | `ProtocolF` |
		| **BAN:** `Any<Any>` | `Any<>` |
		| **BAN:** `Any<D, ProtocolF>` | `D` |
		| **BAN:** `Any<D>` | `D` |
		| **BAN:** `Any<ClassE>` | `ClassE` |
			
	* `class D: ProtocolE, ProtocolF` can be applied to:

		| Type  | Equivalent inferred `Type` |
		|:------|:--------------------------:|
		| `D` | `D` |
		| `ProtocolE` | `ProtocolE` |
		| `ProtocolF` | `ProtocolF` |
		| `Any` | `Any<>` |
		| `Any<ProtocolE, ProtocolF>` | `Any<ProtocolE, ProtocolF>` |
		| **BAN:** `Any<ProtocolE>` | `ProtocolE` |
		| **BAN:** `Any<ProtocolF>` | `ProtocolF` |
		| **BAN:** `Any<Any, ProtocolE, ProtocolF>` | `Any<ProtocolE, ProtocolF>` |
		| **BAN:** `Any<Any, ProtocolE>` | `ProtocolE` |
		| **BAN:** `Any<Any, ProtocolF>` | `ProtocolF` |
		| **BAN:** `Any<Any>` | `Any` or `Any<>` |
		| **BAN:** `Any<D, ProtocolE, ProtocolF>` | `D` |
		| **BAN:** `Any<D, ProtocolE>` | `D` |
		| **BAN:** `Any<D, ProtocolF>` | `D` |
		| **BAN:** `Any<D>` | `D` |
			
	* `protocol D: E, F` can be applied to:

		| Type  | Equivalent inferred `Type` |
		|:------|:--------------------------:|
		| `D` | `D`|
		| `E` | `E`|
		| `F` | `F`|
		| `Any` | `Any<>`|
		| `Any<E, F>` | `Any<E, F>` |
		| **BAN:** `Any<D, E, F>` | `D` |
		| **BAN:** `Any<D, E>` | `D` |
		| **BAN:** `Any<D, F>` | `D` |
		| **BAN:** `Any<E>` | `E` |
		| **BAN:** `Any<F>` | `F`|
		| **BAN:** `Any<D>` | `D`|

Possible functions (just a few examples - solves rdar://problem/15873071 and [rdar://20990743](https://openradar.appspot.com/20990743)):
	
```swift
// with assumed generalized `class` and `AnyObject` typealias in mind
// current verion with unwanted `@objc` and possible bridging 
func woo<T: AnyObject where T: SomeProtocol>(value: T)

// rewritten without generics to accept only classes that conform to `SomeProtocol`
func woo(value: Any<AnyObject, SomeProtocol>)

// more specific example which accepts all subtypes of `UIView` that conform 
// to `SomeProtocol` and one would drop generics here 
func woo(value: Any<UIView, SomeProtocol>)
```

## Impact on existing code

These changes will break existing code. Projects using old style `protocol<...>` mechanism will need to migrate to the new `Any<...>` mechanism. The code using old style `protocol<...>` won't compile until updated to the new conventions.

## Alternatives considered

* This feature was orginally proposed as `type<...>` but was renamed to `Any<...>` to dodge possible confusion and serve its main purpose to enforce *multiple* constraints.

* Rename `protocol<>` to `Any<>` without any additional changes and defer this proposal as enhancement for a future Swift version.

## Future directions

* `Any<...>` should reflect powerful generalized generic features to be able to constrain types even further (e.g. `where` clause). This should have its own proposal, which will extend `Any<...>` proposed here!

* Generalize `class` constraints. This will create the possibility for `AnyObject` typealias.

```swift
typealias AnyObject = Any<class> // @objc will be removed

// or 
typealias ClassInstance = Any<class>

// and ban confusion with old `AnyClass` vs. `AnyObject`
typealias ClassType = ClassInstance.Type
```

* Adding constraints for other extendable types like `struct` and `enum` and generalize these. This change will allow us to form more typealiases like:

```swift
typealias AnyStruct = Any<struct>
typealias AnyEnum = Any<enum>

// or
typealias StructInstance = Any<struct>
typealias EnumInstance = Any<enum>

// and
typealias StructType = StructInstance.Type
typealias EnumType = EnumInstance.Type
```
			
Possible functions (just a few more examples):
	
```swift
// to start with we should remember that we are already to do some syntax 
// magic with current`protocol<>`
protocol A { func zoo() }

// this is the base design that does not violate any rule
// but this should be banned because it is redundant
func boo(value: Any<A>) { value.zoo() }

// this is the refined design that we all use today
func boo(value: A) { value.zoo() }

// we could constrain functions to accept only structs
// this might be seen as an enforcement to the library user to design a 
// struct in this scenario
func foo(value: StructInstance)

// structs that conforms to a specific protocol (from our library?)
func foo(value: Any<StructInstance, SomeProtocol>) 
// one could use of ClassInstance and EnumInstance analogically

// generalized way with generics
func foo<T: struct where T: SomeProtocol>(value: T) 

// or
func foo<T: StructInstance where T: SomeProtocol>(value: T) 

// current only one verion for classes with unwanted `@objc` and possible bridging 
func woo<T: AnyObject where T: SomeProtocol>(value: T)

// better alternative might look like
func woo<T: class where T: SomeProtocol>(value: T) 

// or
func woo<T: ClassInstance where T: SomeProtocol>(value: T) 

// or simpler without generics
func woo(value: Any<ClassInstance, SomeProtocol>)

// or
func zoo(value: Any<class, SomeProtocol>)
```

Possible scenarios:

```swift
// constrainted to accept only structs
struct A<T: struct> {
	var value: T 
} 

// or
struct A<T: StructInstance> {
	var value: T 
} 

protocol SomeProtocol { /* implement something shiny */ }

// lets say this array is filled with structs, classes and enums that conforms to `SomeProtocol`
let array: [SomeProtocol] = // fill

// this would be new
var classArray: [Any<class, SomeProtocol>] = array.flatMap { $0 as? Any<class, SomeProtocol> }
var structArray: [Any<struct, SomeProtocol>] = array.flatMap { $0 as? Any<struct, SomeProtocol> }
var enumArray: [Any<enum, SomeProtocol>] = array.flatMap { $0 as? Any<enum, SomeProtocol> }
```


Flattened operators or even `Type operators` for `Any<>`:

```swift
class B {
	var mainView: UIView & SomeProtocol
	
	init(view: UIView & SomeProtocol) {
		self. mainView = view
	}
}
```

> The `&` type operator would produce a “flattened" `Any<>` with its operands.  It could be overloaded to accept either a concrete type or a protocol on the lhs and would produce `Type` for an lhs that is a type and `Any<>` when lhs is a protocol.    `Type operators` would be evaluated during compile time and would produce a type that is used where the expression was present in the code.  This is a long-term idea, not something that needs to be considered right now. 
> 
> Written by: [Matthew Johnson](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160509/017499.html)

Adding `OneOf<>` which can reduce overloading (idea provided by: [Thorsten Seitz](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160509/017397.html)). `OneOf<>` will pick the first type match from angle brackets with the dynamic type at compile time and proceed. One would then need to handle the value by own desire.

```swift
func foo(value: OneOf<String, Int>) {
	
	if let v = value as? String {
		// do some work
	} else if let v = value as? Int {
		// do some work
	}
}
	
// flattened version for `OneOf<>`
func foo(value: String | Int)
```

Mix different types like `Any<>` and `OneOf<>`:

```swift
// accept dynamic type constrained by 
// (`ClassA` AND `SomeProtocol`) OR (`ClassB` AND `SomeProtocol`)
func foo(value: Any<OneOf<ClassA, ClassB>, SomeProtocol>)

// flattened version
func foo(value: (ClassA | ClassB) & SomeProtocol)
```

Typealias `AnyValue` or `ValueInstance` (for extendable types only):

```swift
typealias AnyValue = OneOf<Any<struct>, Any<enum>> // magic isn't it?
typealias AnyValue = OneOf<AnyStruct, AnyEnum>

// or
typealias ValueInstance = OneOf<Any<struct>, Any<enum>>
typealias ValueInstance = OneOf<StructInstance, EnumInstance>

// and 
typealias ValueType = ValueInstance.Type

// flattened version
typealias AnyValue = Any<struct> | Any<enum>
typealias AnyValue = AnyStruct | AnyEnum
typealias ValueInstance = StructInstance | EnumInstance

// any value which conforms to `SomeProtocol`; reference types finally are out the way
func foo(value: Any<AnyValue, SomeProtocol>) 
func foo(value: Any<ValueInstance, SomeProtocol>) 

// flattened version
func foo(value: AnyValue & SomeProtocol) 
func foo(value: ValueInstance & SomeProtocol) 
```

-------------------------------------------------------------------------------

# Rationale

On [Date], the core team decided to (TBD) this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
