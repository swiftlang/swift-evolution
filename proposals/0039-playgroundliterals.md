# Modernizing Playground Literals

* Proposal: [SE-0039](https://github.com/apple/swift-evolution/blob/master/proposals/0039-playgroundliterals.md)
* Author(s): [Erica Sadun](http://github.com/erica)
* Status: **Scheduled** for March 7...9, 2016
* Review manager: [Chris Lattner](https://github.com/lattner)

## Introduction

Playground literals tokenize colors, files, and images. They provide drag-and-drop convenience and
in-context visualizations that offer easy reference and manipulation when designing playground content.
These literals are built using a simple square bracket syntax that, in the current form, 
conflicts with collection literals.
This proposal redesigns playground literals to follow the precedent of #available and #selector.

*Discussion took place on the Swift Evolution mailing list in the [\[Discussion\] Modernizing Playground Literals](http://article.gmane.org/gmane.comp.lang.swift.evolution/7124) thread. Thanks to [Chris Lattner](https://github.com/lattner) for suggesting this enhancement.*

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
used in modern Swift. Our proposed identifiers are `#colorliteral`, `#imageliteral`, and `#fileliteral`.

```swift
color-literal → #colorliteral(red: unit-floating-point-literal, green: unit-floating-point-literal, blue: unit-floating-point-literal, alpha: unit-floating-point-literal)
unit-floating-point-literal → floating point number greater or equal to zero, less than or equal to one

image-literal → #imageliteral(imageName: image-resource-name)
image-resource-name → static-string-literal referring to image resource name

file-literal → #fileliteral(resourceName: file-resource-name)
file-resource-name → static-string-literal referring to local resource name
```

In this design:

* Each redesigned identifier uses lower case, to match existing Swift literals.
* Arguments use lower camel case labels, as is conventional.
* The word `literal` is added to identifiers denoting each item's role.
* The arguments are simplified and standardized to `red`, `green`, `blue`, `alpha`, `imageName`, and `resourceName`.

## Alternatives Considered

`#resourceliteral` may better describe a file resource than `#fileliteral`.