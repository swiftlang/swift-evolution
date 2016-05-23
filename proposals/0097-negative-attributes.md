# Normalizing naming for "negative" attributes

* Proposal: [SE-0097](0097-negative-attributes.md)
* Author: [Erica Sadun](https://github.com/erica)
* Status: **Review scheduled for May 24...30**
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

This proposal normalizes naming for "negative" attributes by adopting a rule 
that replaces camel-cased property names starting with `no` with adjectives 
starting with `non`. 

Swift-evolution thread:
[RFC: didset and willset](http://thread.gmane.org/gmane.comp.lang.swift.evolution/17534)

## Motivation

Converting `no`-prefixed attributes to `non` changes them into a single word that 
describes how they modify the syntax they decorate.

## Detailed Design

Upon adoption, Swift will rename:

* `noreturn` to `nonreturning`
* `noescape` to `nonescaping`

## Impact on Existing Code

This proposal requires migration support to rename keywords that use the old convention to adopt the new convention. This is a simple substitution with limited impact on existing code.

## Alternatives Considered

The core team may consider exceptions for terms of art. For example, "no return" indicates "there is no return from this function", as in the "point of no return".