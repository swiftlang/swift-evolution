# Use colons for subscript declarations

* Proposal: [SE-0122](0122-use-colons-for-subscript-type-declarations.md)
* Author: [James Froggatt](https://github.com/MutatingFunk)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000258.html)

## Introduction

Currently, subscript declarations follow the following model:

```
subscript(externalName internalName: ParamType) -> ElementType {
	get { … }
	set { … }
}
```

The initial keyword `subscript` is followed by a parameter list, followed by an arrow to the accessed type. This proposal is to replace the arrow with a colon, to match accessor declarations elsewhere in the language.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160704/023883.html)

## Motivation

The arrow, borrowed from function syntax, is very much out of place in this context, and so can act as a mental stumbling block.
It is also misleading, as it implies that subscripts have the full capabilities of functions, such as the ability to throw. If throwing functionality were to be added to accessors, it is likely the specific get/set accessor would be annotated. In this case, the effects on a subscript's ‘function signature’ could become a source of confusion.

Subscripts act like parameterised property accessors. This means, like a property, they can appear on the left hand side of an assignment, and values accessed through subscripts can be mutated in-place. The colon has precedent in declaring this kind of construct, so it makes sense to reuse it here.

## Proposed solution

A simple replacement of `->` with `:` in the declaration syntax.

## Detailed design

This would change the above example to look like the following:

```
subscript(externalName internalName: ParamType) : ElementType {
	get { … }
	set { … }
}
```

## Impact on existing code

Existing code would have to update subscripts to use a colon. This can be automated in a conversion to Swift 3 syntax.

## Potential hazards

The Swift core team has previously implemented this change internally, but rejected it due to reduced readability. This is something to bear in mind when considering this proposal.

The effect largely depends on coding style, which can match either of the following:

```
subscript(_ example: Type) : ElementType
```
```
subscript(_ example: Type): ElementType
```

This issue is most apparent in the latter example, which omits the leading space before the colon, as the colon blends into the closing bracket.

However, the real-world effect of this change is hard to predict, and subscript declarations are rare enough that the consequences of this change are very limited.

## Alternatives considered

We could leave the syntax as it is, or use an alternative symbol, such as `:->` or `<->`.

We could also leave open the possibility of expanding function syntax with `inout ->`.

Colons were chosen for this proposal because they have precedent elsewhere in the language, and are already reserved syntax.

## Future directions

This parameterised accessor syntax could be expanded in a future version of Swift, to support named accessors. This could look something like the following:

```
var image(for state: UIControlState) : UIImage? {
	get {
		…
	}
	set {
		…
	}
}

button.image(for: .normal) = image
```
