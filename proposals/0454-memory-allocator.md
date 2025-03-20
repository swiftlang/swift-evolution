# Custom Allocator for Toolchain

* Proposal: [SE-0454](0454-memory-allocator.md)
* Authors: [Saleem Abdulrasool](https://github.com/compnerd)
* Review Manager: [Alastair Houghton](https://github.com/al45tair)
* Status: **Accepted**
* Implementation: [swiftlang/swift#76563](https://github.com/swiftlang/swift/pull/76563)
* Review: ([review](https://forums.swift.org/t/se-454-adopt-mimalloc-for-windows-toolchain/77096))
      ([acceptance](https://forums.swift.org/t/accepted-se-0454-custom-allocator-for-toolchain-adopt-mimalloc-for-windows-toolchain/77413))

## Introduction

The tools in the Swift toolchain require allocating data structures for
compiling the code. Different memory allocators have differing performance
characteristics. Changing the default memory allocator away from the default
(system) allocator can yield benefits if the allocator is better tuned to the
allocation patterns of the compiler.

## Motivation

A more effecient memory allocator would improve the performance of the compiler
on Windows. This allows better developer productivity by reducing compile time.

## Proposed solution

We propose to adopt mimalloc as the memory allocator for the Swift toolchain on
Windows.

## Detailed design

Building a test codebase yielded a 4% build time decrease when the toolchain was
built with mimalloc.

## Source compatibility

This proposal does not affect source compatibility.

## ABI compatibility

This proposal does not affect ABI of code.

## Implications on adoption

Additional files will need to be built, packaged, and shipped as part of the
toolchain. The mimalloc build is relatively light and the overall build time
impact is minimal.

This change has no implications for the runtime, only the toolchain is changed.

## Future directions

None at this time.

## Alternatives considered

Alternative memory allocators were considered, including
[tcmalloc](https://github.com/google/tcmalloc) and
[tbb](https://github.com/intel/tbb). mimalloc is well supported, developed by
Microsoft, and has better characteristics comparatively.

Leaving the allocator on the default system allocator leaves the compiler
without the performance improvements of an alternative allocator.

## Acknowledgements

Special thanks to @hjyamauchi for performing the work to integrate the mimalloc
build into the Windows build and collecting the performance numbers that showed
the improvement.
