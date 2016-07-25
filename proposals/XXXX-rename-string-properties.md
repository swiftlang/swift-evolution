# Rename two properties on String

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Xiaodi Wu](https://github.com/xwu), [Erica Sadun](https://github.com/erica)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal renames `nulTerminatedUTF8` and `nulTerminatedUTF8CString` to enhance clarity and reduce mismatch between user expectations and the Swift programming language.

Swift-evolution thread: [Discussion thread](http://thread.gmane.org/gmane.comp.lang.swift.evolution/24955)

## Motivation

Both `nulTerminatedUTF8` and `nulTerminatedUTF8CString` are poorly named for the following reasons:
 
* **Inappropriate abbreviation of a term of art**: The ASCII names for \0 are "null character" or "null terminator". Both properties instead use the ASCII abbreviation "NUL" in place of the English word "null". A Google search returned approximately 20,000 results for "NUL-terminated string" and approximately 200,000 results for "null-terminated string".
* **Impaired recognition**: "NUL" is less recognizable than "null". Further, "NUL" suffers from reduced recognition when written in lowercase: `nulTerminated`.
* **Hindered source completion**: When using source editor completion, users who type "null" will not find a property named `nulTerminatedUTF8` or `nulTerminatedUTF8CString`.
* **Redundant terminology**: C strings are terminated by the null character. Using both "C string" and "null-terminated" is redundant and, to some, could unintentionally raise doubts as to whether some C strings might not be null-terminated.

This proposal favors `null` over `nul` and eliminates the redundancy in `nulTerminatedUTF8CString`.

## Detailed design
This proposal introduces the following changes to the Swift standard library:

* Rename `nulTerminatedUTF8CString` to `utf8CString`.
* Rename `nulTerminatedUTF8` to `nullTerminatedUTF8`.

#### `utf8CString`

This property renaming follows the precedent of the related Foundation method `cString(using: .utf8)` and lowercases its leading `utf8`.

####`nullTerminatedUTF8`

This property is a null-terminated contiguous array of a string's UTF8 representation. Retaining `nullTerminated` correctly differentiates this property from the `utf8` property on `String`, since `Array<UInt8>(str.utf8)` has precisely one fewer element than `str.nulTerminatedUTF8` (that element being the null character).

## Impact on existing code

Fix-its will be needed to help transition existing code.

## Alternatives considered

The alternative is not to rename the stated properties.
