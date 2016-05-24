# Moving `dynamicType` to the standard library

* Proposal: [SE-0096](0096-dynamictype.md)
* Author: [Erica Sadun](https://github.com/erica)
* Status: **Review scheduled for May 24...30**
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

This proposal establishes `dynamicType` as a named operator rather than a property
and moves it to the standard library.

Swift-evolution thread:
[RFC: didset and willset](http://thread.gmane.org/gmane.comp.lang.swift.evolution/17534)

## Motivation

In Swift, `dynamicType` is a property. Because of that, it shows up in code completion as an "appropriate"
completion for all values, regardless of whether it makes sense to do so or not. For example, Swift offers
`4.dynamicType` and `myFunction().dynamicType`, etc. 

Rather than express a logical attribute of a specific type,
it can be applied to any expression. Since `dynamicType` behaves more like a operator (like `sizeof`), 
its implementation should follow suit. Moving it to the standard library, allows Swift to remove a keyword and better aligns the functionality with its
intended use.

## Detailed Design

Upon adoption of this proposal, Swift removes the `dynamicType` keyword and introduces a `dynamicType()` function:

```
dynamicType(value) // returns the dynamicType of value
```

The function will look like:

```
/// Returns an instance's dynamic runtime type
func dynamicType<T>(_ : T) -> T.Type { return T.self }
```

## Impact on Existing Code

Adopting this proposal will break code and require migration support. The postfix property syntax must change to a function call. 

## Alternatives Considered

Not adopting this proposal

## Acknowledgements

Thank you, Nate Cook