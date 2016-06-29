# Remove `Boolean` protocol

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Anton Zhilin](https://github.com/Anton3), [Chris Lattner](https://github.com/lattner)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Remove `Boolean` protocol. Only Bool will be able to be used in logical contexts:

```swift
let x: ObjCBool = true
if x { ... }  // will become an error!
```

[Discussion thread](http://thread.gmane.org/gmane.comp.lang.swift.evolution/21559)

## Motivation

> “Boolean” isn’t pulling its weight:
> - It only abstracts over Bool and ObjCBool.
> - It only enables a few operations on ObjCBool, which are not very important.
> - ObjCBool is a bridging problem, and we don’t handle bridging by introducing common protocols (e.g. in the case of String vs NSString, we don’t introduce a common “Stringable” protocol.
>
> Further, it complicates the model:
> - People are confused by it and the similar but very different Bool type.
> - Bool is a simple enough concept to not need a family of protocols.
>
> -- <cite>Chris Lattner</cite>

## Impact on existing code

Change is backwards incompatible, but automatic migration is possible:

- In places where Boolean (but not Bool) was in logical contexts, migrator can add `.boolValue`.
- Migrator can remove conformances to Boolean
