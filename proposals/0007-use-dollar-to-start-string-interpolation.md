# Use $() instead of \() for string interpolation

* Proposal: [SE-0007](https://github.com/apple/swift-evolution/proposals/0007-use dollar to start string interpolation.md)
* Author(s): [Wu Yang](https://github.com/pinxue)
* Status: **Review**
* Review manager: TBD

## Introduction

Use $(expr) to replace current \(expr) to interpolate string literal.

## Motivation

Currently, \(expr) is used for interpolation of string literal. \ starts character escaping as well in string literal, which makes \( ) looks quite unbalance. Use $( ) makes the string literal looks much more comfortable.

## Proposed solution

$(expr) and ${expr} are widely used for years. Considering $(expr) is closer to \(expr), let's take $(expr).

## Detailed design

Let's change "\n(\(name),\(value))\n" to "\n($(name),$(value))".

## Impact on existing code

Existed code will lose interpolation without modifying. Compiler may detect the legacy interpolation syntax and issue an error. An auto-rewriting wizard can be a part of project migrating in Xcode.

## Alternatives considered

Another way is to use \(expr\), which is one letter more and a little harder to type than $(expr)
