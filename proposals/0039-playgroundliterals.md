# Modernizing Playground Literals

* Proposal: [SE-0039](0039-playgroundliterals.md)
* Author: [Erica Sadun](http://github.com/erica)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-March/000060.html)
* Bug: [SR-917](https://bugs.swift.org/browse/SR-917)

## Introduction

Playground literals tokenize colors, files, and images. They provide drag-and-drop convenience and
in-context visualizations that offer easy reference and manipulation when designing playground content.
These literals are built using a simple square bracket syntax that, in the current form, 
conflicts with collection literals.
This proposal redesigns playground literals to follow the precedent of #available and #selector.

*Discussion took place on the Swift Evolution mailing list in the [\[Discussion\] Modernizing Playground Literals](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160215/010301.html) thread. Thanks to [Chris Lattner](https://github.com/lattner) for suggesting this enhancement.*

[Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160307/012025.html)

## Motivation

Color, image, and file literals are currently represented as:

```swift
[#Color(colorLiteralRed: red, green: green, blue: blue, alpha: alpha)#]
[#Image(imageLiteral: localResourceNameAsString)#]
[#FileReference(fileReferenceLiteral: localResourceNameAsString)#]
```

Playground literals present the following features:

* They appear within a container designated with `[# #]` endpoints. 
* They are marked with a capital camel case role name.
* First label arguments use the word *literal* to punch the construction of each literal item.

There are several issues with this approach:

* The enclosing square brackets conflict with collection literals, adding extra work for parsing. 
* The construction syntax does not follow modern Swift conventions.
* The word *literal* describes the constructed items not the argument being passed to create the literal.
  It is misplaced in its current use.

## Detail Design 

Simplifying constructors to [octothorpe](https://en.wikipedia.org/wiki/Octothorpe)-delineated identifiers 
cleans up the language, removes potential grammar conflicts, and follows precedent for other identifiers
used in modern Swift. Our proposed identifiers are `#colorLiteral`, `#imageLiteral`, and `#fileLiteral`.

```swift
color-literal → #colorLiteral(red: unit-floating-point-literal, green: unit-floating-point-literal, blue: unit-floating-point-literal, alpha: unit-floating-point-literal)
unit-floating-point-literal → floating point number greater or equal to zero, less than or equal to one

image-literal → #imageLiteral(resourceName: image-resource-name)
image-resource-name → static-string-literal referring to image resource name

file-literal → #fileLiteral(resourceName: file-resource-name)
file-resource-name → static-string-literal referring to local resource name
```

In this design:

* Each redesigned identifier uses lower case, to match existing Swift literals.
* Arguments use lower camel case labels, as is conventional.
* The word `literal` is added to identifiers denoting each item's role.
* The arguments are simplified and standardized to `red`, `green`, `blue`, `alpha`, and `resourceName`.

However, these argument labels are not appropriate for the actual initializers. Initializers in literal protocols should use argument labels that clearly mark their use in literals. This serves two ends. First, types may wish to provide specialized behavior for literals that would be inappropriate for a general-purpose initializer. Second, literal initializers must obey rigid naming and typing rules; giving them an "unusual" name avoids contaminating the standard interface to the type and reduces the risk of spurious ambiguity. With that in mind, Swift will interpret the syntax above as a use of the corresponding initializer below:

```swift
protocol _ColorLiteralConvertible {
  init(colorLiteralRed red: Float, green: Float, blue: Float, alpha: Float)
}

protocol _ImageLiteralConvertible {
  init(imageLiteralResourceName path: String)
}

protocol _FileReferenceLiteralConvertible {
  init(fileReferenceLiteralResourceName path: String)
}
```

## Alternatives Considered

`#resourceliteral` may better describe a file resource than `#fileliteral`.
