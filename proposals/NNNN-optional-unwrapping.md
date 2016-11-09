# Optional Unwrapping

* Proposal: [SE-NNNN](NNNN-type-narrowing.md)
* Author: [Haravikk](https://github.com/haravikk)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal is to introduce unwrapping as an explicit concept in Swift.

Swift-evolution thread: [Discussion thread topic for that proposal](http://news.gmane.org/gmane.comp.lang.swift.evolution)

## Motivation

Currently when dealing with optionals it is necessary to use conditional binding to extract an unwrapped version of a variable; this is fine when dealing with a copy, but introduces a number of awkward cases when mutability is required, especially if when the original variable is shadowed at the same time.

Example with shadowing:
```
var foo:T? = getValueFromSomewhere()
if var foo = foo {
	print(foo.someValue)
	foo.someMutatingMethod() // shadowed value of foo is mutated, not the original!
	foo = nil // can't do this
}
```

Example with copy:
```
var foo:T? = getValueFromSomewhere()
if let thisFoo = foo {
	print(foo.someValue)
  foo!.someMutatingMethod() // modifies original
  foo = nil // now works
}
```

## Proposed solution

The proposed solution for both optionals and polymorphism is type-narrowing, simply the concept of explicitly refining a type to work with a more specific (narrower) form more conveniently.

## Detailed design


## Impact on existing code


## Alternatives considered

