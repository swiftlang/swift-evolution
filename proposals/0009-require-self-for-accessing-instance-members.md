# Require self for accessing instance members

* Proposal: [SE-0009](0009-require-self-for-accessing-instance-members.md)
* Author: [David Hart](https://github.com/hartbit)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160104/005478.html)

## Introduction

The current version of Swift (2.1) requires using `self` when accessing instance members in closures. The proposal suggests extending this to all member accesses (as is intrinsically the case in Objective-C). It has the benefit of documenting instance properties vs local variables and instance functions vs local functions or closures.

[Swift Evolution Discussion Thread](https://lists.swift.org/pipermail/swift-evolution/2015-December/000209.html)

## Motivation

This proposal makes it obvious which are instance properties vs local variables, as well as which are instance functions vs local functions/closures. This has several advantages:

* More readable at the point of use. 
* More consistent than only requiring `self` in closure contexts.
* Less confusing from a learning point of view.
* Lets the compiler warn users (and avoids bugs) where the authors mean to use a local variable but instead are unknowingly using an instance property (and the other way round).

One example of a bug avoidable by the proposal ([provided by Rudolf Adamkovic](https://lists.swift.org/pipermail/swift-evolution/2015-December/000243.html)):

```swift
class MyViewController : UIViewController {
	@IBOutlet var button: UIButton!
        var name: String = "David"

	func updateButton() {
		// var title = "Hello \(name)"
		button.setTitle(title, forState: .Normal) // forgot to comment this line but the compiler does not complain and title is now referencing UIViewController’s title by mistake
		button.setTitleColor(UIColor.blackColor(), forState: .Normal)
	}
}
```

The API Design Guidelines are meant for writing APIs but I still think they represent fundamentals of Swift. The two first points are:

* Clarity at the point of use is your most important goal. Code is read far more than it is written.
* Clarity is more important than brevity. Although Swift code can be compact, it is a non-goal to enable the smallest possible code with the fewest characters. Brevity in Swift code, where it occurs, is a side-effect of the strong type system and features that naturally reduce boilerplate.

And I believe that the proposition is directly in line with those objectives.

## Counter-argument

The counter-argument brought up by two members of the community is that the current behaviour "makes the capturing semantics of self stand out more in closures". While this is true, the author finds its usefulness lacking.

In the following lines of code, we know without a shadow of a doubt that `foobar` is a throwing function and that `barfoo` does not throw.

```swift
try foobar()
barfoo()
```

But with an example of `self` in a closure:

```swift
foobar({
	print(self.description)
})
```

The `self` keyword in the previous lines of code gives a hint but does not bring any certitudes:

* `self` might have been forced by the compiler to hint at possible memory issues,
* `self` might have been a programmer choice if the closure is non-escaping.

And in the reverse example:

```swift
barfoo({
	print(description)
})
```

* the closure might be non-escaping,
* the `description` might be referring to a local variable (which we missed the declaration of) shadowing the instance property in an escaping closure.

In both of these examples, the `self` keyword does not tell us with any certainty that we should or not be careful about reference cycle issues without checking the signature of the called function, only that self is captured. With the proposition, `self` gets some meaning back: it indicates which are local and which are instance properties.

## Proposed Solution

I suggest that not using `self` for accessing instance properties and functions is applied in two stages. In Swift 2.x, it could start as a warning and Xcode could provide a Fix-It. Then, it could become a compiler error in Swift 3 and the migrator would help transition code over.

The following code which used to compile would generate an error at the documented lines:

```swift
class Person {
	var name: String = "David"
	
	func foo() {
		print("Hello \(name)") // would not compile
	}
	
	func bar() {
		foo() // would not compile
	}
}
```

The code would have to be modified as so to compile correctly:

```swift
class Person {
	var name: String = "David"
	
	func foo() {
		print("Hello \(self.name)")
	}
	
	func bar() {
		self.foo()
	}
}
```

## Impact on existing code

A lot of code written since the original change would be impacted by this proposal, but it seems like it can be easily fixed by both the migrator tool and an Xcode Fix-It.

## Alternatives considered

The alternative is to keep the current behaviour, but it has the aforementioned disadvantages.

An alternative would be to demote from a compiler error to a warning.

## Community Responses

* "I actually encountered at least two bugs in my app introduced by this implicit "self" behavior. It can be dangerous and hard to track down." -- Rudolf Adamkovic, salutis@me.com
* "Given this, some teams use underscores for their iVars which is very unfortunate. Myself, I use self whenever possible to be explicit. I'd like the language to force us to be clear." -- Dan, robear18@gmail.com
* "I'm not sure how many Swift users this effects, but I'm colorblind and I really struggle with the local vs properties syntax coloring." -- Tyler Cloutier, cloutiertyler@aol.com
* "+1 I've had a lot of weird things happen that I've traced to mistakes in properties having the same name as function arguments. I've hardly ever had this issue in modern Obj-C." -- Colin Cornaby, colin.cornaby@mac.com
* "Teaching wise, its much less confusing for self to be required so students don't mix up instance properties and local vars. Especially when self is required in closures, it confuses students. If self is mandatory for all instance properties, it would be so much clearer and much easier to read." -- Yichen Cao, ycao@me.com
* "this avoids confusion, maintains a consistent language approach, and thus helps reducing bugs. Sure, it might lead to less poetic haiku code, but that is not necessarily a bad thing in medium to large scale software products with more than one person working on it and possible/eventual change of people on the project over time." -- Panajev
* "I'm +1 on this, for the reasons already stated by others, but not as strongly as I was a year ago. I was very worried about this with Swift 1 was first released, but since then, I haven't actually made this mistake, possibly because I'm so paranoid about it." -- Michael Buckley, michael@buckleyisms.com
