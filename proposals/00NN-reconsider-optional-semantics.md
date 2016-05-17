# Reconsider semantics for optional methods in Swift

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/00NN-reconsider-optional-semantics.md)
* Author(s): [Carlos Rodriguez-Dominguez](https://github.com/carlosrodriguez85)
* Status: **[Awaiting review](#rationale)**
* Review manager: TBD

## Introduction

Swift protocols allow `optional` methods to be declared, just as a means to maintain compatibility with Objective-C. Consequently, optional methods are following the removal path in future Swift versions. Nonetheless, this proposal intends to propose new semantics to the `optional` keyword, which could fit well with Swift and solve some current issues.

Swift-evolution thread: [Modify optional method semantics for swift](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160509/016893.html)

## Motivation

As a everybody knows, `optional` keyword is present in Swift solely to maintain compatibility with objective-c protocols. Optional methods in protocols are neither a Swift capability, nor a wanted one.In fact, proposal [0070] intends to begin the transition to an optionals-free language, since optionals, as presented by Objective-C, are a manner to avoid interface segregation.

Nonetheless, in many occasions, optionals are used to model customized behavior vs default one. For instance, if you take a look at the documentation of UITableViewDataSource or delegate, you’ll see that optional methods are not required, since the framework provides a default behavior that can be customized by implementing the corresponding optional methods.

Consequently, is most cases, optional methods in Cbjective-C are a means to replace the semantics of *default* protocol method implementations, as supported through extensions in swift.

Therefore, the proposal is to modify the semantics of the `optional` keyword in Swift to mean: `a default implementation of this method is available, therefore you don't need to implement it`. This is different from Objective-C semantics, which means `the implementation of this method may not be provided, since there is somewhere else a default behavior in case the method is not implemented`.

## Detailed design

In this proposal, protocols could be defined like this:

```swift
protocol Datasource {
	associatedtype Element

	var count:Int {get}
	func element(at index:Int) -> Element
	optional func color(forElementAt index:Int) -> UIColor
}
```

This definition will enforce the developer to create an extension to provide a default implementation of the optional method:

```swift
extension Datasource {
	func color(forElementAt index:Int) -> UIColor {
		return UIColor.blackColor()
	}
}
```

In this way, what we are achieving is that we are avoiding Objective-C optional semantics (which is a way to avoid interface segregation), but we are making explicit that a method in a protocol requires a default implementation, thus not requiring the developer to re-implement the method in any entity adopting the protocol (as it currently happens when we provide a default method implementation). Moreover, we are making explicit that a certain protocol method has a default implementation, which can be confusing right now (right now, how do you know if a method has a default implementation?).

Note that in this proposal, the intention is to keep both `@objc optional` and simply `optional`keywords, to highlight both semantics. However, in order to avoid @objc optional semantics as much as possible (to be able to remove it in a future swift release), new annotations could be incorporated to optional methods in Objective-C code, to specify the default returned value in simple cases. For instance, the annotations could be like this:

@protocol Datasource
	-(NSInteger) count;
	-(NSObject*) elementAtIndex:(NSInteger)index;

	@optional
	-(UIColor*) colorForElementAtIndex:(NSInteger)index __attribute__((swift_default_value("UIColor.blackColor()")));
@end

That annotation should produce a Swift code similar to the above one.

Those types of annotations also allow to better understand the default behavior (in case the method is not implemented by the developer) without reading the documentation.


## Impact on existing code

In simple cases, Objective-C optional methods could be annotated to avoid `@objc optional` imports into Swift code as much as possible. Annotations may require a great effort, but reducing Objective-C optionals could make it easier the future transition to an `@objc optional`-free language.

## Alternatives considered

As an alternative, to separate more from Objective-C semantics, a new keyword could be added: `default`. Moreover, instead of requiring extensions to provide default implementations, they could be provided in-line, like this:

 ```swift
protocol Datasource {
	associatedtype Element

	var count:Int {get}
	func element(at index:Int) -> Element
	default func color(forElementAt index:Int) -> UIColor {
		return UIColor.blackColor()
	}
}
```

In fact, I think that in most cases it could be more obvious to read that code. However, in-line implementations will require more implementation efforts in the compiler side.

