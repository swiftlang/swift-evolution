# Replace repeating `Character` and `UnicodeScalar` forms of String.init

* Proposal: [SE-0130](0130-string-initializers-cleanup.md)
* Author: Roman Levenstein
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000260.html)

## Introduction

This proposal suggest replacing String initializers taking Character or UnicodeScalar as a repeating value by a more general initializer that takes a String as a repeating value. This is done to avoid the ambiguities in the current String API, which can be only resolved by explicit casting. It is also proposed to remove one of the String.append APIs to match these changes.

All user-facing Swift APIs must go through Swift Evolution. While this is a relatively simple API change with an existing implementation, this formal proposal provides a paper trail as is normal and usual for this process.

## Motivation

This change introduces a non-ambiguous API for constructing Strings. With the set of String initializers available today, ones often needs to explicitly cast the repeating value literal to disambiguate what initializer is meant to be used. 

An example of the ambiguity:

```
> let x = String(repeating:"0", count: 10) 
error: repl.swift:29:9: error: ambiguous use of 'init(repeating:count:)'
let x = String(repeating:"0", count: 10)
        ^

Swift.String:11:12: note: found this candidate
    public init(repeating repeatedValue: Character, count: Int)
           ^

Swift.String:21:12: note: found this candidate
    public init(repeating repeatedValue: UnicodeScalar, count: Int)
           ^
```

To disambiguate, one currently needs to write something like:
   * `let zeroes = String(repeating: "0" as Character, count: 10)` or 
   * `let zeroes = String(repeating: "0" as UnicodeScalar, count: 10)`

## Detailed Design

This update affects `String`.

It is proposed to replace the following ambiguous API:
*  `public init(repeating repeatedValue: Character, count: Int)`
*  `public init(repeating repeatedValue: UnicodeScalar, count: Int)`

by the following, more powerful API:
*  `public init(repeating repeatedValue: String, count: Int)`

To match this change, it is also proposed to remove the following String.append API:
*  `public mutating func append(_ x: UnicodeScalar)`

It should be fine, because there is already an existing and more powerful API:
*  `public mutating func append(_ other: String)`

## Impact on Existing Code

Existing third party code using these to be removed String APIs will need migration.
A fix-it could be provided to automate this migration.

## Alternatives Considered

Not Applicable
