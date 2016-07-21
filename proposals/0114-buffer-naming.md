# Updating Buffer "Value" Names to "Header" Names

* Proposal: [SE-0114](0114-buffer-naming.md)
* Author: [Erica Sadun](http://github.com/erica)
* Status: **Accepted** ([Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000221.html))
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

This proposal updates parameters and generic type parameters from `value` names to `header` names for `ManagedBuffer`, `ManagedProtoBuffer`, and `ManagedBufferPointer`. 

All user-facing Swift APIs must go through Swift Evolution. While this is a trivial API change with an existing implementation, this formal proposal provides a paper trail as is normal and usual for this process.

[Swift Evolution Thread](http://thread.gmane.org/gmane.comp.lang.swift.evolution/22127)

[Patch](https://github.com/apple/swift/commit/eb7311de065df7ea332cdde8782cb44f9f4a5121)

## Motivation
This change introduces better semantics for buffer types.

## Detailed Design

This update affects `ManagedBuffer`, `ManagedProtoBuffer`, and `ManagedBufferPointer`. 

#### Generic Parameters
The generic parameters `<Value, Element>` become `<Header, Element>` in affected classes.

#### Type Members
Each use of `value` or `Value` in type members is renamed to `header` or `Header`. Affected members include

* `header: Header`
* `_headerPointer`, `_headerOffset`
* `withUnsafeMutablePointerToHeader`
* `create(minimumCapacity:makingHeaderWith:) -> Header`
* Initializers that refer to `makingHeaderWith`

## Impact on Existing Code

Existing third party code will need migration using a simple fixit. 

## Alternatives Considered

Not Applicable
