# Lowercase `didSet` and `willSet` for more consistent keyword casing

* Proposal: [SE-0098](0098-didset-capitalization.md)
* Author: [Erica Sadun](https://github.com/erica)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Rejected**
* Decision Notes: [Rationale](https://forums.swift.org/t/rejected-se-0098-lowercase-didset-and-willset-for-more-consistent-keyword-casing/2852)

## Introduction

This proposal adopts consistent conjoined keyword lowercasing.

Swift-evolution thread:
[RFC: didset and willset](https://forums.swift.org/t/rfc-didset-and-willset/2669)

## Motivation

Swift is an opinionated language. One opinion it adheres to is that keywords should
use conjoined lowercasing. Conjoined lowercase terms already in the language include `typealias`, 
`associatedtype`, and `fallthrough`. Using this casing style enables programmers to treat 
keywords as atomic concepts. This proposal formalizes this rule and fixes current inconsistencies. 

## Detailed Design

Upon adoption, Swift will rename `didSet` and `willSet` to `didset` and `willset`.
Future expansions to the language will follow this adopted rule, for example `didchange`.

This proposal deliberately omits the `dynamicType` keyword, which will be addressed
under separate cover: to be moved to the standard library as a standalone global function.

## Impact on Existing Code

This proposal requires migration support to rename keywords that use the old convention to
adopt the new convention. This is a simple substitution that should limit effect on code.

## Alternatives Considered

Not adopting this rule for Swift.
