# Remove access modifiers from extensions

* Proposal: [SE-0119](0119-extensions-access-modifiers.md)
* Author: [Adrian Zubarev](https://github.com/DevAndArtist)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000250.html)

## Introduction

<p align="justify">One great goal for Swift 3 is to sort out any source breaking language changes. This proposal aims to fix access modifier inconsistency on extensions compared to other scope declarations types.</p>

Swift-evolution thread: [\[Proposal\] Revising access modifiers on extensions](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160620/022144.html)

## Motivation

<p align="justify">The access control of classes, enums and structs in Swift is very easy to learn and memorize. It also disallows to suppress the access modifier of implemented conformance members to lower access modifier if the host type has an access modifier of higher or equal level.</p>

<center>`public` > `internal` > `fileprivate` >= `private`</center>

```swift
public class A {
	public func foo() {}
}

public class B : A {
	
	// `foo` must retain `public`
	override public func foo() {}
}
```

However in Swift it is possible to grant more visibility to a member but still hide the conformance to a *protocol*.

```swift
internal protocol C {
	func foo()
}

public struct D : C {

	// `foo` can be either `internal` or `public`
	public func foo() {}
}
```

The imported module will look like this:

```swift
public struct D {
	public func foo()
}
```

This simple access control model also allows us to nest types inside each other to create a really nice type hierarchy.

*Extensions* however behave differently when it comes to their access control:

* The *access modifier* of an *extension* sets the default modifier of its members which do not have their own localy defined modifier.

	```swift
	public struct D {}
	
	// The extension itself has also `private` visibility
	private extension D {
		// `foo` is implicitly `private`
		func foo() {}
	}
	```
	
* > Any type members added in an extension have the same default access level as type members declared in the original type being extended. If you extend a public or internal type, any new type members you add will have a default access level of internal. If you extend a private type, any new type members you add will have a default access level of private. 
 >
 > Source: [The Swift Programming Language](https://swift.org/documentation/TheSwiftProgrammingLanguage(Swift3).epub)

	```swift
	private struct E {}
	
	extension E {
		// `foo` is implicitly `private`
		func foo() {}
	}
	```
	
* The access modifier can be overridden by the member with a lower access modifier.

	```swift
	public struct F {}
	
	internal extension F {
		// `foo` can be `internal`, `fileprivate` or `private`
		private func foo() {}
	}
	```
	
Furthermore in Swift 2.2 it is not allowed to apply an *access modifier* on extensions when a *type inheritance clause* is present:

```swift
public protocol SomeProtocol {}

// 'public' modifier cannot be used with
// extensions that declare protocol conformances
public extension A : SomeProtocol {}
```

*Extensions* are also used for *protocol default implementations* in respect to the mentioned rules. That means that if someone would want to provide a public default implementation for a specific protocol there are three different ways to  achieve this goal:

```swift
public protocol G {
	func foo()
}
```

*  First way:

	```swift
	extension G {
		public func foo() { /* implement */ }
	}
	```
	
*  Second way:

	```swift
	public extension G {
		func foo() { /* implement */ }
	}
	```

* Third way:

	```swift
	public extension G {
		public func foo() { /* implement */ }
	}
	```
	
Any version will currently be imported as:

```swift
public protocol G {
	func foo()
}

extension G {
	public func foo()
}
```

I propose to revise the access control on extensions by removing access modifiers from extensions. 

> That way, access for members follows the same defaults as in the original type.
>
> [Jordan Rose](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160627/022341.html)

* It would be possible to conform types to a protocol using an *extension* which has an explicit *access modifier*. The *access modifier* respects the modifier of the extended type and the protocol to which it should be conformed.

	```swift
	internal protocol H { 
		func foo() 
	}
	
	public protocol I { 
		func boo() 
	}

	public struct J {}
	
	public extension J : H {
     
	    // We can grant `foo` visibility but still hide conformance to `H`
	    // and move everything from `H` to an extra extension bag
	    public func foo() {}  
	     
	    // Access modifier on members won't be overridden by the extension access modifier anymore
	    // And they will respect the access level boundary set by the extension
	    func moo() {}
	}
	
	// The extension of `J` conforming to `I` must retain `public`
	public extension J : I {
     
	    // `boo` must retain `public`
	    public func boo() {}  
	}
	```
	
	The above extension can be simplified to:
	
	```swift
	// The extension must retain `public` because `J` and `I` are marked as `public`
	public extension J : H, I {
     
     	// `foo` can be either `public` or `internal`
	    public func foo() {}  
	     
		// Implicitly `internal`
	    func moo() {}

	    // `boo` must retain `public`
	    public func boo() {}  
	}
	```

* The right and only one version for public *protocol default implementations* will look like this:

	```swift
	public extension G {
		public func foo() { /* implement */ }
	}
	```
* Removing this behavior would imply less need to learn different behaviors for access control in general.
* From a future perspective one could allow Swift to have nested extensions (which is neither part nor a strong argument of this proposal).

	```swift
	internal protocol K {}

	public struct L {
	     
	    public struct M {}
	     
	    /* implicitly internal */ extension M : K {}
	}
	
	// Nested extension would remove this:
	/* internal */ extension L.M : K {}
	```
* The ability of setting the default modifier could be reintroduces in its own typeless scope design, which might look like this:

	```swift
	fileprivate extension Int {
	
		// Not visible outside this extension bag
		private func doSomething() -> Int { ... }
		
		fileprivate group {
		
			// Every group memebr is `fileprivate`
			func member1() {}
			func member2() {}
			func member3() {}
			func member4() {}
			func member5() {}
		}
	}
	```
	Such a mechanism could also be used outside extensions! This idea has its own discussion [thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160627/022644.html).

## Proposed solution

1. Remove access modifier from extensions to stop being able to set the default access modifier.
2. Allow *access modifier* when *type-inheritance-clause* is present.
3. *Access modifier* on extensions should respect the modifier of the extended type and the protocol to which it should conform.

	* Public protocol:
	
		* `public type` + `public protocol` = `public extension`
		* `internal type` + `public protocol` = `internal extension`
		* `private  type` + `public protocol` = `private extension`

	* Internal protocol:
	
		* `public type` + `internal protocol` = `public extension` or `internal extension`
		* `internal type` + `internal protocol` = `internal extension`
		* `private type` + `internal protocol` = `private extension`

	* Private protocol:
	
		* `public type` + `private protocol` = `public extension` or `internal extension` or `private extension`
		* `internal type` + `private protocol` = `internal extension` or `private extension`
		* `private type` + `private protocol` = `private extension`
		
	* Multiple protocol conformance is decided analogously by using the highest access modifier from all protocols + the access level of the extended type.
	 	
#### The current grammar will not change:

*extension-declaration* → *access-level-modifier*<sub>opt</sub> **extension** *type-identifier* *type-inheritance-clause*<sub>opt</sub> *extension-body*

*extension-declaration* → *access-level-modifier*<sub>opt</sub> **extension** *type-identifier* *requirement-clause* *extension-body*

*extension-body* → **{** *declarations*<sub>opt</sub> **}**

Iff the *access-level-modifier* is not present, the access modifier on extensions should always be implicitly *internal*.

#### Impact on public APIs (imported version):

```diff
- extension SomeType : SomeProtocol {
+ public extension SomeType : SomeProtocol {
	public func someMemeber()
}
```

## Impact on existing code

This is a source-breaking change that can be automated by a migrator.

* Extensions without an explicit access modifier:

	```diff
	//===-----------------------------===//
	//===-------- public type --------===//
	//===-----------------------------===//
	
	public struct AA {}
	
	- extension AA {
	+ public extension AA {
		func member1() {}
		public func member2() {}
		private func member3() {}
	}
	
	//===-----------------------------===//
	//===------- internal type -------===//
	//===-----------------------------===//
	
	internal struct BB {}
	
	// No impact at all because it is already
	// implicitly `internal`
	
	extension BB {
		func member1() {}
		private func member2() {}
	}
	
	//===-----------------------------===//
	//===------- private type --------===//
	//===-----------------------------===//
	
	private struct CC {}
	
	- extension CC {
	+ private extension CC {
	
	 	// Implicitly private
		func member1() {}
		private func member2() {}
	}
	```

* Extensions with an explicit access modifier:

	```diff
	//===-----------------------------===//
	//===-------- public type --------===//
	//===-----------------------------===//
	
	public struct DD {}
	
	public extension DD {
	-	func member1() {}
	+	public func member1() {} 
		public func member2() {}
		private func member3() {}
		internal func member4() {}
	}
	
	internal extension DD {
		func member5() {}
		private func member6() {}
		internal func member7() {}
	}
	
	private extension DD {
	
		// Implicitly private
		func member8() {}
		private func member9() {}
	}
	
	//===-----------------------------===//
	//===------- internal type -------===//
	//===-----------------------------===//
	
	internal struct EE {}
	
	internal extension EE {
		func member1() {}
		private func member2() {}
		internal func member3() {}
	}
	
	private extension EE {
	
		// Implicitly private
		func member4() {}
		private func member5() {}
	}
	
	//===-----------------------------===//
	//===------- private type --------===//
	//===-----------------------------===//
	
	private struct FF {}
	
	private extension FF {
		
		// Implicitly private
		func member1() {}
		private func member2() {}
	}
	```
	
* Extensions without an explicit access modifier and protocol conformance:

	```diff
	public protocol Foo {
		func foo()
	}
	
	internal protocol Boo {
		func boo()
	}
	
	private protocol Zoo {
		func zoo()
	}
	
	//===-----------------------------===//
	//===-------- public type --------===//
	//===-----------------------------===//
	
	public struct GG {}
	
	- extension GG : Foo, Boo, Zoo {
	+ public extension GG : Foo, Boo, Zoo {
		func member1() {}
		public func member2() {}
		private func member3() {}
		
		// Access modifier for `foo`, `boo` and `zoo`
		// won't have an impact
	}
	
	//===-----------------------------===//
	//===------- internal type -------===//
	//===-----------------------------===//
	
	internal struct HH {}
	
	// No impact at all because it is already
	// implicitly `internal`
	
	extension BB : Foo, Boo, Zoo {
		func member1() {}
		private func member2() {}
		
		// Access modifier for `foo`, `boo` and `zoo`
		// won't have an impact
	}
	
	//===-----------------------------===//
	//===------- private type --------===//
	//===-----------------------------===//
	
	private struct II {}
	
	- extension CC : Foo, Boo, Zoo {
	+ private extension CC : Foo, Boo, Zoo {
	
		// Implicitly private
		func member1() {}
		private func member2() {}

		// Access modifier for `foo`, `boo` and `zoo`
		// won't have an impact (all are private)
	}
	```

## Alternatives considered

* Allow *access modifier* when *type-inheritance-clause* is present and use the rules presented in [**Proposed solution**](#proposed-solution).
