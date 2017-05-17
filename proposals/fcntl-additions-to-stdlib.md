# Expose fcntl() API as part of the Swift stdlib

* Proposal: [SE-NNNN]
* Author(s): [Bill Abt](https://github.com/billabt)
* Status: **Review**
* Review manager: TBD

## Introduction

At the present time Swift does not support the calling of variadic functions in 
other languages.  There are a number of these functions in the standard "C" 
library that are critical for various programming tasks.  One of these is 
fcntl(2) which is used to manipulate POSIX file descriptors.  The need for
exposing this API in Swift is readily apparent when doing socket programming 
since it's this API that's used to make a socket non-blocking.

## Motivation

The main motivation behind this proposal is outlined above in the
introduction with regard to socket programming.  However, this API is
extremely powerful and can be used to do many things in different contexts.
Exposing it to the Swift community is almost a necessity. 

## Proposed solution

The fcntl() API comes in 3 basic forms all returning an integer.  The 
first form takes 3 integers as parameters but the third is ignored.  The
second take 3 integers and uses all three.  Finally, the third take 2
integers and a void pointer.  The solution is to add 3 exposed Swift
stdlib APIs representing each of the variations outlined above.

## Detailed design

Three new APIs would be added to both Glibc and Darwin packages.  The
signatures are below:

```
func fcntl(fd: CInt, _ cmd: CInt) ->CInt
func fcntl(fd: CInt, _ cmd: CInt, _ value: CInt) ->CInt
func fcntl(fd: CInt, _ cmd: CInt, _ ptr: UnsafeMutablePointer<Void>) ->CInt
```

Underlying each of these APIs would be an internal Swift shim that 
calls the underlying fcntl() "C" library function.  This new code
would be added to the existing overlay system for both Darwin and
Glibc.

**Note:** There are a number of other variadic functions that are
currently supplied via the Darwin overlay but are not currently 
present in Glibc overlay. This proposal would expose those APIs as
well in Glibc. The following APIs are in Darwin and would be ported
as part of this effort over to Glibc overlay:
```
open(), openat(), sem_open()
```

## Impact on existing code

Since this API is currently not exposed, there's no impact on any
existing code.

## Alternatives considered

The only other alternative is for Swift programmers to create their
own shims to their own versions of C functions calling "C" standard
library functions.  This will work but it forces Swift programmers
to resort to a hybrid model and have at least rudimentary knowledge
of C.
