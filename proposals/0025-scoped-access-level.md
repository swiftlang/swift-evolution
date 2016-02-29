# Scoped Access Level

* Proposal: [SE-0025](https://github.com/apple/swift-evolution/blob/master/proposals/0025-scoped-access-level.md)
* Author(s): Ilya Belenkiy
* Status: **Under review** (February 26...March 3, 2016)
* Review manager: [Doug Gregor](http://github.com/DougGregor)

## Introduction

Scoped access level allows to hide implementation details of a class or a class extension at the class/extension level, instead of a file. It is a concise expression of the intent that a particular part of a class or extension definition is there only to implement a public API for other classes or extensions, and must not be used directly anywhere outside of the scope of the class or the extension.

## Motivation

Currently, the only reliable way to hide implementations details of a class is to put the code in a separate file and mark it as private. This is not ideal for the following reasons:

- It is not clear whether the implementation details are meant to be completely hidden or can be shared with some related code without the danger of misusing the APIs marked as private. If a file already has multiple classes, it is not clear if a particular API is meant to be hidden completely or can be shared with the other classes.

- It forces a one class per file structure, which is very limiting. Putting related APIs and/or related implementations in the same file helps ensure consistency and reduces the time to find a particular API or implementation. This does not mean that the classes in the same file need to share otherwise hidden APIs, but there is no way to express it with the current access levels.

Another, less reliable, way is to prefix APIs that are meant to be hidden with a `_` or do something similar. That works, but it’s not enforced by the compiler, and those APIs show up in tools like code completion, so the programmer has to filter out the noise - although these tools could quite easily support hiding methods with the `_` prefix standard. Also, there is a greater danger of using private APIs if they do something similar to public APIs but are somehow more optimized (because they make additional assumptions about the internal state).

The existing solutions are in some ways similar to those for untyped collections. It is usually possible to give collection a name that would imply the type of elements it holds (similar to using _ to indicate private), but it is not the same as specifying it explicitly. Just as with generics, the intent not to share the implementation details with any other class is much clearer with support from the language as opposed to where the code is in the project. Also, with untyped collections, it is possible to add an element of a different type (deliberately or not). Generics make it impossible, and it’s enforced by the compiler. Similarly, a dedicated access level modifier could enforce hiding implementation details at the compiler level and make it impossible to accidentally misuse or (deliberately use) implementation details in a context that the class meant not to share.

## Proposed solution

Add another access level modifier that is meant to express that the API is visible only within the scope in which it is defined. Properties, functions, and nested types marked this way would be completely hidden outside the class or class extension definition.

## Detailed design

When a function or a property is defined with a scoped access modifier, it is visible only within that lexical scope. For example:

```swift
class A {
   local var counter = 0

   // public API that hides the internal state
   func incrementCount() { ++counter }

   // hidden API, not visible outside of this lexical scope
   local func advanceCount(dx: Int) { counter += dx }

   // incrementTwice() is not visible here
}

extension A {
   // counter is not visible here
   // advanceCount() is not visible here

   // may be useful only to implement some other methods of the extension
   // hidden from anywhere else, so incrementTwice() doesn’t show up in 
   // code completion outside of this extension
   local func incrementTwice() {
      incrementCount()
      incrementCount()
   }
}
```

## Impact on existing code

The existing code is completely unaffected.

## Alternatives considered

1. Do nothing and use `_` and `/` or split the code into more files and use the private modifier. The proposed solution makes the intent much clearer, it would be enforced by the compiler, and the language does not dictate how the code must be organized.

2. Introduce a scoped namespace that would make it possible to hide APIs in part of the file. This introduces an extra level of grouping and nesting and forces APIs to be grouped by access level instead of a logical way that may make more sense.
