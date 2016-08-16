# Refactor Metatypes, repurpose `T.self` and `Mirror`

* Proposal: [SE-0126](0126-refactor-metatypes-repurpose-t-dot-self-and-mirror.md)
* Authors: [Adrian Zubarev](https://github.com/DevAndArtist), [Anton Zhilin](https://github.com/Anton3)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Withdrawn**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000251.html)

## Introduction

This proposal wants to revise metatypes `T.Type`, repurpose *public* `T.self` notation to return a new `Type<T>` type instance rather than a metatype, merge **SE-0101** into `Type<T>`, rename the global function from **SE-0096** to match the changes of this proposal and finally rename current `Mirror` type to introduce a new (lazy) `Mirror` type. 

Swift-evolution threads: 

* [\[Proposal\] Refactor Metatypes, repurpose T[dot]self and Mirror](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160718/024772.html) 
* [\[Discussion\] Seal `T.Type` into `Type<T>`](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160704/023818.html)
* [\[Discussion\] Can we make `.Type` Hashable?](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160627/023067.html)

GitHub Gist thread: 

* [Refactor metatypes](https://gist.github.com/Anton3/9931463695f1c3263333e18f04f9cd8e)

## Motivation

The following tasks require metatype-like types:

1. Explicit specialization of functions and expressing specific static types.
2. Dynamic dispatch of `static` methods.
3. Representing any value as a tree, for debug purposes.
4. Retrieving and passing around information about dynamic types - Reflection.

Current state of things:

[1] is given to metatypes `T.Type`:

  * The metatype instance is usually ignored.
  * For example, if you pass `Derived.self as Base.self` into function taking `T.Type`, it will work with `Base`.
  * This raises concerns: are metatypes perfectly suited for that purpose?
  
[2] is also given to metatypes `T.Type`:

  * Because they are used so often, it's tempting to add useful methods to them, but we can't, because metatypes are not extensible types.
  
[3] is given to `Mirror`:

  * Does its name reflect what it's intended to do?
  * `Mirror.DisplayStyle` contains `optional` and `set` as special cases, but does not contain `function` at all.
  * `Mirror` collects all information possible at initialization, while for "true" reflection we want *laziness*.
  * `Mirror` allows customization. For example, `Array<T>` is represented with a field for each of its elements. Do we want this for "true" reflection we want to add in the future?
  
[4] is given to both metatypes `T.Type` and `Mirror`:

  * Metatypes are generic. But do we want genericity in reflection? No, we almost always want to cast to `Any.Type`.
  * Metatypes are used for getting both static and dynamic sizes.
  * In this context, distinction between generic parameter `T` and value of metatype instance is unclear.
  * People are confused that `Mirror` is intended to be used for full-featured reflection, while it does not aim for that.

### Known issues of metatypes:

Assume this function that checks if an `Int` type conforms to a specific protocol. This check uses current model of metatypes combined in a generic context:

```swift
func intConforms<T>(to _: T.Type) -> Bool {
   return Int.self is T.Type
}

intConforms(to: CustomStringConvertible.self) //=> FALSE
```

> [1] When `T` is a protocol `P`, `T.Type` is the metatype of the protocol type itself, `P.Protocol`. `Int.self` is not `P.self`.
>
> [2] There isn't a way to generically expression `P.Type` **yet**.
>
> [3] The syntax would have to be changed in the compiler to get something that behaves like `.Type` today.
>
> Written by Joe Groff: [\[1\]](https://twitter.com/jckarter/status/754420461404958721) [\[2\]](https://twitter.com/jckarter/status/754420624261472256)  [\[3\]](https://twitter.com/jckarter/status/754425573762478080)

A possible workaround might look like the example below, but does not allow to decompose `P.Type` which is a major implementation problem of this proposal:

```swift
func intConforms<T>(to _: T.Type) -> Bool {
  return Int.self is T
}

intConforms(to: CustomStringConvertible.Type.self) //=> TRUE
```

This issue was first found and documented as a strange issue in **[SR-2085](https://bugs.swift.org/browse/SR-2085)**. It also raises the concerns: do we need `.Protocol` at all?

We can extend this issue and find the second problem by checking against the metatype of `Any`:

```swift
func intConforms<T>(to _: T.Type) -> Bool {
	return Int.self is T
}

intConforms(to: Any.Type.self) //=> TRUE

intConforms(to: Any.self) //=> TRUE
```

As you clearly can see, when using `Any` the compiler does not require `.Type` at all.

The third issue will show itself whenever we would try to check protocol relationship with another protocol. Currently there is no way (that we know of) to solve this problem:

```swift
protocol P {}
protocol R : P {}

func rIsSubtype<T>(of _: T.Type) -> Bool {
	return R.self is T
}

rIsSubtype(of: P.Type.self) //=> FALSE
```

We also believe that this issue is also the reason why the current global functions `sizeof`, `strideof` and `alignof` make use of generic `<T>(_: T.Type)` declaration notation instead of `(_: Any.Type)`.

## Proposed solution

### `Metatype<T>`:

* Revise metatypes in generic context so the old `T.Type` notation does not produce `T.Protocol` when a protocol metatype is passed around.
* Introduce a distinction between **public** and **internal** `T.self` notation where the **internal** `T.self` notation will be renamed to `T.metatype`.
* Rename old metatype `T.Type` notation to `Metatype<T>`.
* Make **internal** `T.metatype` notation (builtin - not visible in public Swift) return an instance of `Metatype<T>`.
* Public construction of metatypes will look like `Type<T>.metatype` or `T.self.metatype`, see below.
* Metatypes will be used **only** for dynamic dispatch of static methods, see example below:

```swift
protocol HasStatic   { static func staticMethod() -> String; init() }
struct A : HasStatic { static func staticMethod() -> String { return "I am A" }; init() {} }
struct B : HasStatic { static func staticMethod() -> String { return "I am B" }; init() {} }

func callStatic(_ metatype: Metatype<HasStatic>) {
    let result = metatype.staticMethod()   
    print(result)
    let instance = metatype.init()
    print(instance)
}

let a = Type<A>.metatype
let b = Type<B>.metatype
callStatic(a)  //=> "I am A" "A()"
callStatic(b)  //=> "A am B" "B()"
```

### `Type<T>` API:

`T.self` will be repurposed to return ab instance of `Type<T>` that is declared as follows:

```swift
public struct Type<T> : Hashable, CustomStringConvertible, CustomDebugStringConvertible {
	
	/// Creates an instance that reflects `T`.
	/// Example: `let type = T.self`
	public init()
	
	/// Returns the contiguous memory footprint of `T`.
	///
	/// Does not include any dynamically-allocated or "remote" storage.
	/// In particular, `Type<T>.size`, when `T` is a class type, is the
	/// same regardless of how many stored properties `T` has.
	public static var size: Int { get }
	
	/// Returns the least possible interval between distinct instances of
	/// `T` in memory.  The result is always positive.
	public static var stride: Int { get }
	
	/// Returns the default memory alignment of `T`.
	public static var alignment: Int { get }
	
	/// Returns an instance of `Metatype<T>` from captured `T` literal.
	public static var metatype: Metatype<T> { get }
	
	/// Returns the contiguous memory footprint of `T`.
	///
	/// Does not include any dynamically-allocated or "remote" storage.
	/// In particular, `Type<T>().size`, when `T` is a class type, is the
	/// same regardless of how many stored properties `T` has.
	public var size: Int { get }
	
	/// Returns the least possible interval between distinct instances of
	/// `T` in memory.  The result is always positive.
	public var stride: Int { get }
	
	/// Returns the default memory alignment of `T`.
	public var alignment: Int { get }
	
	/// Returns an instance of `Metatype<T>` from captured `T` literal.
	public var metatype: Metatype<T> { get }
	
	/// Hash values are not guaranteed to be equal across different executions of
	/// your program. Do not save hash values to use during a future execution.
	public var hashValue: Int { get }
	
	/// A textual representation of `self`.
	public var description: String { get }
	
	/// A textual representation of `self`, suitable for debugging.
	public var debugDescription: String { get }
}

public func ==<T>(lhs: Type<T>, rhs: Type<T>) -> Bool
```

Size of `Type<T>` struct equals `0`. It will be used for generic function specialization:

```swift
func performWithType(_ type: Type<T>)
performWithType(Float.self)
```

### `metatype(of:)` function:

The global `type(of:)` function from **SE-0096** will be renamed to `metatype(of:)` and receive the following declaration:

```swift
/// Returns a dynamic instance of `Metatype<T>`. A dynamic
/// metatype can reflect type `U` where `U : T`.
public func metatype<T>(of instance: T) -> Metatype<T>
```

### `Mirror` API:

Rename current `Mirror` (Swift 2.2) to `DebugRepresentation` and `CustomReflectable` to `CustomDebugRepresentable`.

A *completely different* `Mirror` type will be introduced in Swift 3.

* `Mirror` wraps metatypes and allows checking subtype relationships at runtime.
* `Mirror` contains dynamic versions of `size`, `stride` and `alignment`. 
* Size of `Mirror` itself is always `8` bytes, because it only needs to store a single metatype.
* `Mirror` provides a starting point for adding fully functional (lazy) reflection in the future.

```swift
public struct Mirror : Hashable, CustomStringConvertible, CustomDebugStringConvertible {

	/// Creates an instance of `Mirror`, reflecting type, which is
	/// reflected by a metatype.
	public init(_ metatype: Metatype<Any>)
	
	/// Creates an instance of `Mirror`, reflecting type `T`
	public init<T>(_ type: Type<T>)
	
	/// Creates an instance of `Mirror`, reflecting 
	/// dynamic metatype of a given instance.
	public init<T>(reflecting instance: T)
	
	/// Returns the contiguous memory footprint of reflected metatype.
	public var size: Int { get }
	
	/// Returns the least possible interval between distinct instances of
	/// the dynamic type in memory calculated from the reflected dynamic 
	/// metatype. The result is always positive.
	public var stride: Int { get }
	
	/// Returns the minimum memory alignment of the reflected dynamic 
	/// metatype.
	public var alignment: Int { get }
	
	/// Returns an instance of `Metatype<Any>` from reflected dynamic metatype.
	public var metatype: Metatype<Any> { get }
	
	/// Checks if type reflected by `self` is a subtype of type reflected by another `Mirror`.
	public func `is`(_ mirror: Mirror) -> Bool { get }
	
	/// Checks if type reflected by `self` is a subtype of `T`.
	public func `is`<T>(_ type: Type<T>) -> Bool { get }
	
	/// Checks if type reflected by `self` is a subtype of type reflected by a metatype.
	public func `is`<T>(_ metatype: Metatype<T>) -> Bool { get }
	
	/// Hash values are not guaranteed to be equal across different executions of
	/// your program. Do not save hash values to use during a future execution.
	public var hashValue: Int { get }
	
	/// A textual representation of `self`.
	public var description: String { get }
	
	/// A textual representation of `self`, suitable for debugging.
	public var debugDescription: String { get }
}

public func ==(lhs: Mirror, rhs: Mirror) -> Bool
```

### Summary of metatype-like types:

#### Before

* `T.Type` does three things:
  1. Specialization of functions.
  2. Dynamic dispatch of static methods.
  3. Partial reflection using dynamic casts and functions like `sizeof`, `strideof` etc.
* `Mirror` does two things:
  1. It is primarily intended for use in debugging, like `PlaygroundQuickLook`.
  2. With less success, it can be used for reflection.

#### After

* `Type<T>` does specialization of functions.
* `Mirror` does reflection.
* `Metatype<T>` does dynamic dispatch of static methods.
* `DebugRepresentation` is used in debugging.

## Detailed design

### Possible Implementation:

```swift
public struct Type<T> : Hashable, CustomStringConvertible, CustomDebugStringConvertible {
	
	/// Creates an instance that reflects `T`.
	/// Example: `let type = T.self`
	public init() {}
	
	/// Returns the contiguous memory footprint of `T`.
	///
	/// Does not include any dynamically-allocated or "remote" storage.
	/// In particular, `Type<T>.size`, when `T` is a class type, is the
	/// same regardless of how many stored properties `T` has.
	public static var size: Int { return _size(of: T.metatype) }
	
	/// Returns the least possible interval between distinct instances of
	/// `T` in memory.  The result is always positive.
	public static var stride: Int { return _stride(of: T.metatype) }
	
	/// Returns the default memory alignment of `T`.
	public static var alignment: Int { return _alignment(of: T.metatype) }
	
	/// Returns an instance of `Metatype<T>` from captured `T` literal.
	public static var metatype: Metatype<T> { return T.metatype }
	
	/// Returns the contiguous memory footprint of `T`.
	///
	/// Does not include any dynamically-allocated or "remote" storage.
	/// In particular, `Type<T>().size`, when `T` is a class type, is the
	/// same regardless of how many stored properties `T` has.
	public var size: Int { return Type<T>.size }
	
	/// Returns the least possible interval between distinct instances of
	/// `T` in memory.  The result is always positive.
	public var stride: Int { return Type<T>.stride }
	
	/// Returns the default memory alignment of `T`.
	public var alignment: Int { return Type<T>.alignment }
	
	/// Returns an instance of `Metatype<T>` from captured `T` literal.
	public var metatype: Metatype<T> { return Type<T>.metatype }
	
	/// Hash values are not guaranteed to be equal across different executions of
	/// your program. Do not save hash values to use during a future execution.
	public var hashValue: Int { return _uniqueIdentifier(for: self.metatype) }
	
	/// A textual representation of `self`.
	public var description: String { return "Type<\(self.metatype)>()" }
	
	/// A textual representation of `self`, suitable for debugging.
	public var debugDescription: String {
		return "[" + self.description
			+ " metatype: \(self.metatype)"
			+ " size: \(self.size)"
			+ " stride: \(self.stride)"
			+ " alignment: \(self.alignment)]"
	}
}

public func ==<T>(lhs: Type<T>, rhs: Type<T>) -> Bool { return true }

/// Returns a dynamic instance of `Metatype<T>`. A dynamic
/// metatype can reflect type `U` where `U : T`.
public func metatype<T>(of instance: T) -> Metatype<T> {
	return /* implement */
}

public struct Mirror : Hashable, CustomStringConvertible, CustomDebugStringConvertible {
	
	/// Storage for any dynamic metatype.
	internal let _metatype: Metatype<Any>
	
	/// Creates an instance of `Mirror`, reflecting type, which is
	/// reflected by a metatype.
	public init(_ metatype: Metatype<Any>) {
		self._metatype = metatype
	}
	
	/// Creates an instance of `Mirror`, reflecting type `T`
	public init<T>(_ type: Type<T>) {
		self._metatype = type.metatype
	}
	
	/// Creates an instance of `Mirror`, reflecting 
	/// dynamic type of a given instance.
	public init<T>(reflecting instance: T) {
		self._metatype = metatype(of: instance)
	}
	
	/// Returns the contiguous memory footprint of reflected metatype.
	public var size: Int { return _size(of: self._metatype) }
	
	/// Returns the least possible interval between distinct instances of
	/// the dynamic type in memory calculated from the reflected dynamic 
	/// metatype. The result is always positive.
	public var stride: Int { return _stride(of: self._metatype) }
	
	/// Returns the minimum memory alignment of the reflected dynamic 
	/// metatype.
	public var alignment: Int { return _alignment(of: self._metatype) }
	
	/// Returns an instance of `Metatype<T>` from reflected dynamic metatype.
	public var metatype: Any.Type { return self._metatype }
	
	/// Checks if type reflected by `self` is a subtype of type reflected by another `Mirror`.
	public func `is`(_ mirror: Mirror) -> Bool {
		return _is(metatype: self._metatype, also: mirror.metatype)
	}
	
	/// Checks if type reflected by `self` is a subtype of `T`.
	public func `is`<T>(_ type: Type<T>) -> Bool {
		return _is(metatype: self._metatype, also: type.metatype)
	}
	
	/// Checks if type reflected by `self` is a subtype of type reflected by a metatype.
	public func `is`<T>(_ metatype: Metatype<T>) -> Bool {
		return _is(metatype: self._metatype, also: metatype)
	}
	
	/// Hash values are not guaranteed to be equal across different executions of
	/// your program. Do not save hash values to use during a future execution.
	public var hashValue: Int { return _uniqueIdentifier(for: self._metatype) }
	
	/// A textual representation of `self`.
	public var description: String { return "Mirror(\(self._metatype))" }
	
	/// A textual representation of `self`, suitable for debugging.
	public var debugDescription: String {
		return "[" + self.description
			+ " metatype: \(self._metatype)"
			+ " size: \(self.size)"
			+ " stride: \(self.stride)"
			+ " alignment: \(self.alignment)]"
	}
}

public func ==(lhs: Mirror, rhs: Mirror) -> Bool {
	return lhs.hashValue == rhs.hashValue
}
```

### Internal functions:

These functions were used in the implementation above to calculate metatype related information.

* `_size(of:)`, `_stride(of:)` and `_alignment(of:)` functions need some additional tweaking so they will work with any matatype stored in an instance of `Metatype<Any>` rather than a dynamic `<T>(of metatype: Metatype<T>)` variant, which is not suitable for calculations needed in `Mirror`. 

* `_uniqueIdentifier(for:)` function is fully implemented and should just work when the current generic issue with `.Protocol` metatypes is resolved.

* `_is(metatype:also:)` relies on the resolved `.Protocol` issue. The final implementation should allow to check type relationship between two different metatype instances.

```swift
internal func _size(of metatype: Metatype<Any>) -> Int {
	// Fix this to allow any metatype
	return Int(Builtin.sizeof(metatype))
}

internal func _stride(of metatype: Metatype<Any>) -> Int {
	// Fix this to allow any metatype
	return Int(Builtin.strideof_nonzero(metatype))
}

internal func _alignment(of metatype: Metatype<Any>) -> Int {
	// Fix this to allow any metatype
	return Int(Builtin.alignof(metatype))
}

internal func _uniqueIdentifier(for metatype: Metatype<Any>) -> Int {
	let rawPointerMetatype = unsafeBitCast(metatype, to: Builtin.RawPointer.metatype)
	return Int(Builtin.ptrtoint_Word(rawPointerMetatype))
}

internal func _is(metatype m1: Metatype<Any>, also m2: Metatype<Any>) -> Bool {
	return /* implement - checks type ralationship `M1 : M2` and `M1 == M2` */
}
```

### Summary of Steps:

* Revise metatypes in generic context so the old `T.Type` notation does not produce `T.Protocol` when a protocol metatype is passed around.
* Make **public** `T.self` notation return an instance of `Type<T>`.
* Rename **internal** `T.self` notation to `T.metatype` (builtin - not visible in public Swift).
* Rename old metatype `T.Type` notation to `Metatype<T>`.
* Make **internal** `T.metatype` notation return an instance of `Metatype<T>`.
* Revise APIs with current `T.Type` notation to use `Type<T>` and in few edge cases `Metatype<T>`.
* Move `size`, `stride` and `alignment` from **SE-0101** to `Type<T>`.
* Provide a concrete declaration for **SE-0096** and rename it to `metatype(of:)`.
* Rename current `Mirror` type (Swift 2.2) to `DebugRepresentation` and `CustomReflectable` to `CustomDebugRepresentable`.
* Introduce a new `Mirror` type that is intended to replace metatypes for most use cases and extended with reflection in a future release.

## Impact on existing code

This is a source-breaking change that can be automated by a migrator.

The following steps reflects our suggestion of the migration process; these can differ from the final migration process implemented by the core team if this proposal will be accepted:

* `T.Type` → `Metatype<T>`
* `T.self` → `Type<T>.metatype`
* `Mirror` → `DebugRepresentation`
* `CustomReflectable` → `CustomDebugRepresentable`
  * `customMirror` → `customDebugRepresentation`
* `sizeof(T.self)` → `Type<T>.size`
* `sizeof(metatype)` → `Mirror(metatype).size`

### Migrating metatype variables to use `Type<T>` and `Mirror`

`Metatype<T>` is a safe default for transition, but we want to discourage usage of metatypes.
In some cases, we can provide fix-its to replace usage of `Metatype<T>` with `Type<T>` or `Mirror`.

To change type of a variable named `type` from `Metatype<T>` to `Type<T>`:

1. Replace its type with `Type<T>`.
2. Use the migration patterns below.
3. If some use case does not match any of these, the variable cannot be migrated to type `Type<T>`.

Migration patterns:

* `type = T.self.metatype` → `type = T.self`
* `type = U.self.metatype` where `U != T` → Automatic migration impossible
* `type = Type<T>.metatype` → `type = T.self`
* `type = Type<U>.metatype` where `U != T` → Automatic migration impossible
* `type = otherMetatype` where `otherMetatype: Metatype<T>` → `type = T.self`
* `type = otherMetatype` where `otherMetatype: Metatype<U>`, `U != T` → Automatic migration impossible
* `type = mirror.metatype` where `mirror: Mirror` → Automatic migration impossible
* `otherMetatype = type` where `otherMetatype: Metatype<U>` → `otherMetatype = Type<T>.metatype`
* `Mirror(type)` → `Mirror(type)`
* `type as otherMetatype` where `otherMetatype: Metatype<U>` → `type.metatype as metatype<U>`
* `type as? otherMetatype` → Automatic migration impossible
* `type as! otherMetatype` → Automatic migration impossible
* `type is otherMetatype` → Automatic migration impossible

How to change type of a variable named `type` from `Metatype<T>` to `Mirror`:

1. Replace its type with `Mirror`.
2. Use the migration patterns below.
3. If some use case does not match any of these, the variable cannot be migrated to type `Mirror`.

Migration patterns:

* `type: Metatype<T>` → `type: Mirror`
* `type = U.self.metatype` → `type = Mirror(U.self)`
* `type = Type<U>.metatype` → `type = Mirror(U.self)`
* `type = otherMetatype` → `type = Mirror(otherMetatype)`
* `type = mirror.metatype` where `mirror: Mirror` → `type = mirror`
* `otherMetatype = type` → `otherMetatype = type.metatype`
* `Mirror(type)` → `type`
* `type as otherMetatype` → `type.metatype as! otherMetatype`
* `type as? otherMetatype` → `type.metatype as? otherMetatype`
* `type as! otherMetatype` → `type.metatype as! otherMetatype`
* `type is otherMetatype` → `type.is(otherMetatype)`

We can also migrate metatype parameters of a function, where assignment means passing an argument to that function.

In two cases we can apply these automatically:

1. If a generic function takes parameter `Metatype<T>`, then we can try to replace `Metatype<T>` with `Type<T>`.
2. We can try to replace usage of `Metatype<Any>` (aka `AnyMetatype`) with `Mirror`.


## Alternatives considered

* After refactoring metatypes it is assumed that any metatype can be stored inside an instance of `Metatype<Any>`. If that will not be the case, then we propose to introduce a new standalone type for explained behavior. That type could be named as `AnyMetatype`. Therefore, any type marked with `Metatype<Any>` in this proposal will become `AnyMetatype`.

* If the community and the core team are strongly against the repurposing of `Mirror` we'd like to consider to merge the proposed functionality into a single type. For such a change we do believe `Type<T>` might be the right type here. However, this introduces further complications such as storing dynamic metatypes inside of `Type<T>` and a few other that we don't want go in detail here.

## Future directions

### Remove public `.self`:

When **SE-0090** is accepted we will remove `T.self` notation and only have type literals like `T`.

Examples:

```swift
let someInstance = unsafeBitCast(1.0, to: Int)
let dynamicSize = Mirror(reflecting: someInstance).size
```

Then we can add `Type(_: Type<T>)` initializer for disambiguation:

```swift
Int.self.size     // Works fine with this proposal, but what if we drop `.self`?
Int.size          // Will be an error after dropping `.self`.
Type<Int>().size  // Would work, but looks odd.
Type(Int).size    // This version looks much better.
```

When combined with this proposal, the result will be to eliminate all 'magical' members that existed in the language:

* `.dynamicType`
* `.Type`
* `.self`

There is also `Self`, but it acts like an `associatedtype`.

### Extend `Mirror` with reflection functionality:   

Reflection is one of stated goals for Swift 4. With this proposal, adding reflection becomes as simple as extending `Mirror`. For example, we could add the following computed property:

```swift
typealias FieldDescriptor = (name: String, type: Mirror, getter: (Any) -> Any, setter: (inout Any, Any) -> ())
var fields: [FieldDescriptor] { get }
```
