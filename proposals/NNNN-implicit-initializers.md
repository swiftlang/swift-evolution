# Implicit Initializers 

* Proposal: TBD
* Author(s): [Manav Gabhawala](https://github.com/manavgabhawala)
* Status: **Review**
* Review manager: TBD

## Introduction

Implicit initializers are available by default in old languages like C++, however, in Swift one **must** explicitly call the initializer when converting between types because Swift is a very expressive language. However, in some cases this expressiveness is more burdensome to the programmer than useful, most notably when converting (or casting) from a smaller numeric type to a larger one. This document proposes the (re-)addition of implicit initializers to Swift. Since the addition of new features like failable initializers and the error handling model, having implicit initializers will no longer be a problem in Swift as there are clean ways to solve the inherent problems that implicit initializers have. Further, this proposal suggests to go even further and allow for generic wrapper classes/structs to have the ability to respond to function calls on their implicitly wrapper types without knowing what type they are wrapping ahead of time.

## Motivation

This proposal addresses a problem that Swift's very strict type checking creates in very specific and limited cases where the lack of expressiveness is more beneficial. 

The proposal is trying to address is the ability to implicitly create an object from a [Directly Acyclic Graph](https://en.wikipedia.org/wiki/Directed_acyclic_graph) of a subtype. The most common case of this is the numerics model in the standard library:

```swift
	let foo: Float = 10.0
	
	// What we use currently:
	let bar = 12.0 + Double(foo) 
	let point = CGPoint(x: CGFloat(foo), y: CGFloat(foo))
	
	// What this is proposing
	let bar = 12.0 + foo // (Here foo is implicitly constructed to a Double like above but is done by the compiler)
	let point: CGFloat = CGPoint(x: foo, y: foo)
```
However, we do not want to hard code this behavior into the compiler and also want to allow users of Swift to be able to hook into this behavior because they may have types where it makes more sense to do implicit conversions rather than calling a constructor explicitly. 

## Proposed solution

The proposed solution is to allow for a new keyword on initializers, namely `implicit`. This keyword will serve as an antonym to the `explicit` keyword in [C++](http://en.cppreference.com/w/cpp/language/explicit). 

Here is an example of how it could serve with an initializer for an Int32 from an Int16

```swift
struct Int32 {
	implicit init(_ value: Int16) {
		// Usual initialization goes here.
	}
}
```

This is the usage of the keyword in its most basic form. For more details read the Detailed Design.
Moreover, the proposal suggest allowing for implicit initializers to be failable. The return value will still be optional. The way this works and is useful is as follows:

```swift
class NSURL {
	implicit init?(_ string: String) { 
		// Usual initialization goes here.
	}
}

let str: String? = "Something"
guard let URL : NSURL = str
else {
	// Could not create URL from str
}
// Do something with URL.

// Another reason to do this would be for constructs like this:
let request = NSURLRequest(URL: "https://apple.com"!)

```
If implemented like this, String literals could then respond to all the usual function calls from the String API, but also the function calls from NSURL since NSURL is implicitly constructible from a string.
This design would benefit in many ways in the numbers department when moving from a bigger size to a smaller size

```swift
struct Float {
	implicit init?(_ double: Double) { // Returns nil if double is too big to fit in a Float 
		// ...
	}
}
// This is a clean and nice API to use especially when using values from an untrusted source like JSON.
if let fl : Float = JSON["some_float_val"] as! Double { 
	// Now we know they can't overflow our Float yet we can use a Float as wanted.
}
```


## Detailed design

The most important idea behind this design is that the compiler will be *inserting* a call to the initializer, so the existing design of the SIL or further along the compiler pipeline will not be impacted. Further, if the user decides to write in a call to initializer no warnings or errors must be shown as that code is still correct, and hence backwards compatibility will be maintained.

There are several other things to consider about initializers before this proposal is complete. Here are the restrictions suggested that must be imposed on `implicit initializers` to ensure that their users don't abuse their power and try to ensure they are only used for subtypes as intended:
 
- Implicit initializers must have **one** and only one parameter.
	- The reason for this is that Swift doesn't support multiple inheritance and so only a 'single' super-types will exist and so it must only be possible to create the new object from a single other object.
- Implicit initializers must have an unnamed parameter.
	- The reasoning behind this is that only if converting between two types is clear enough for an initializer without a label should there exist an implicit initializer for that type conversion.
- Implicit constructors operate at a single level only and are **not** transitive. Such that if A -> B and B -> C does not imply A -> C where -> indicates implicitly constructible from.
	- The reason for this is that an implicit initializer must be defined before such a jump is made.
- Implicit initializers **cannot** throw.
	- If an initializer can throw it probably means that calling the initializer will prove to be more expressive, and error information is usually wanted at the call site.
- Implicit initializers **can be** failable. The return value will still remain optional and so if implicitly constructed (even from a non optional value) the object created will be optional.


## Impact on existing code

Prewritten code will not be impacted in any way by this change, however, the stdlib and other frameworks will have to be updated to support implicit initializers. Further, since the proposed solution is for the compiler to make these conversions itself, the ABI will not be impacted in any way either. However, the biggest gain will be the friction of working with numbers of different types will be reduced. 
Moreover, implementation in the compiler should not be too difficult either. In one of the early front-end passes the compiler can make insertions into the correct places to the actual initializers and the rest of the compiler pipeline can continue unchanged.

## Relevant Mailing Threads and Responses
 
- [Auto-convert for numbers when safe](https://lists.swift.org/pipermail/swift-evolution/2015-December/000345.html)
	- "I think all of the numeric types should be able to auto-convert if the conversion is safe (without loss of precision or overflow)." - Johnathan Hull  
	- "I’m not opposed to allowing user-defined implicit conversions, but IMO they need to be limited to a DAG of subtype relationships." - Chris Lattner
	
