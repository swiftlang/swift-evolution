# Add const as alias of let

* Proposal: [SE-0008](https://github.com/apple/swift-evolution/proposals/0008-add-const-as-alias-of-let.md)
* Author(s): [Wu Yang](https://github.com/pinxue)
* Status: **Review**
* Review manager: TBD

## Introduction

Add const as alias of let.

## Motivation

const is more related to var than let, which may makes source code a little easier to read.

## Proposed solution

Add const as an alias of let.

## Detailed design

Programmer may write const instead of let in source code. Mixing of const and let is forbidden though to avoid confusion.

## Impact on existing code

It is harmless new syntax sugar, thus no impacts.

## Alternatives considered

N/A
