# Removing stdlib ManagedBufferPointer

* Proposal: [SE-NNNN](NNNN-remove-managed-buffers-pointer.md)
* Author: [Erik Eckstein](https://github.com/eeckstein)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

This proposal is about removing ManagedBufferPointer from the stdlib.

Swift-evolution thread: [deprecating ManagedBufferPointer](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161010/027782.html)

## Motivation

The purpose of ManagedBufferPointer is to create a buffer with a custom
class-metadata to be able to implement a custom deinit (e.g. to destroy
the tail allocated elements).
It was used in Array before it was replaced by the new tail-allocated-array
built-ins. But now it’s not used anymore in the standard library.

Also in user code it's not likely that ManagedBufferPointer is used that
often, because it's easier to use ManagedBuffer instead.

As a replacement for ManagedBufferPointer one can just derive a class from
ManagedBuffer and implement the deinit in the derived class:

```
final class MyBuffer : ManagedBuffer<MyHeader, MyElements> {
  deinit {
    // do whatever needs to be done
  }
}

// creating MyBuffer:
let b = MyBuffer.create(minimumCapacity: 27, makingHeaderWith: { myb in return MyHeader(...) })
```

So the main motivation for removing ManagedBufferPointer is that it is
redundant because instead the simpler ManagedBuffer can be used.

In addition, there is a optimizer-related motiviation:
ManagedBufferPointer cannot use the new tail-allocated-array SIL instructions.
Instead it uses explicit address and size calculations, which is less efficient
for the SIL optimizer.

## Proposed solution

Remove the ManagedBufferPointer type from the stdlib.

## Source compatibility

Clearly this is a source breaking change. On the other hand we do not
expect that there are many usages of ManagedBufferPointer in user code.

Automatic migration might be possible. The migrator would have to make
ManagedBuffer a base class of the class, which is passed to the
ManagedBufferPointer's bufferClass argument.

Although it is probably sufficient to just describe how this change can
be done manually.

## Effect on ABI stability

There is no effect on the ABI.

## Alternatives considered

As an alternative, MangedBufferPointer could just be deprecated. This means
the compiler would give a warning message if ManagedBufferPointer is used,
but the code would still compile.

