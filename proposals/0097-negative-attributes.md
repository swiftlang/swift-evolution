# Normalizing naming for "negative" attributes

* Proposal: [SE-0097](0097-negative-attributes.md)
* Author: [Erica Sadun](https://github.com/erica)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-June/000181.html)

## Introduction

This proposal normalizes naming for "negative" attributes by adopting a rule 
that replaces property names starting with `no` with adjectives 
starting with `non`. 

Swift-evolution thread:
[RFC: didset and willset](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160516/017959.html)

## Motivation

Swift is an opinionated language. One opinion it adheres to is that attributes should be built around "non", and not "no", avoiding camel casing bumps. Converting `no`-prefixed attributes to `non`-integrated attributes establishes a single word that describes how each attribute modifies the syntax they decorate.

## Detailed Design

Upon adoption, Swift will rename:

* `noreturn` to `nonreturning`
* `noescape` to `nonescaping`

## Impact on Existing Code

This proposal requires migration support to rename keywords that use the old convention to adopt the new convention. This is a simple substitution with limited impact on existing code.

## Alternatives Considered

The core team may consider exceptions for terms of art. For example, "no return" indicates "there is no return from this function", as in the "point of no return".
