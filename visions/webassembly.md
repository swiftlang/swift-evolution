# A Vision for WebAssembly Support in Swift

## Introduction

WebAssembly (abbreviated [Wasm](https://webassembly.github.io/spec/core/intro/introduction.html#wasm)) is a virtual 
machine instruction set focused on portability, security, and high performance. It is vendor-neutral, designed and
developed by [W3C](https://w3.org). An implementation of a WebAssembly virtual machine is usually called a
*WebAssembly runtime*, or [*embedder*](https://webassembly.github.io/spec/core/intro/overview.html#embedder).

Despite its origins in the browser, it is a general-purpose technology that has use cases in client-side and
server-side applications and services. WebAssembly support in Swift makes the language more appealing in those settings,
and also brings it to the browser where it previously wasn't available at all.

### Portability

An application compiled to a Wasm module can run on any platform that has a Wasm runtime available. This is useful not
only for certain applications and libraries, but for the Swift toolchain itself. To quote
[a GSoC 2024 idea](https://www.swift.org/gsoc2024/#building-swift-macros-with-webassembly):

> WebAssembly could provide a way to build Swift macros into binaries that can be distributed and run anywhere,
> eliminating the need to rebuild them continually.

This can be applicable not only to Swift macros, but also SwiftPM manifests and plugins.

### Security

WebAssembly instruction set has useful properties from a security perspective, as it has
no interrupts or peripherals access instructions. Access to the underlying system is always done by calling a
explicitly imported functions, implementations for which are provided by an imported WebAssembly module or a WebAssembly
runtime itself. The runtime has full control over interactions of the virtual machine with the outside world.

WebAssembly code and data live in completely separate address spaces, with all executable code in a given module loaded
and validated by the runtime upfront. Combined with the lack of "jump to address" and a limited set of control flow
instructions that require explicit labels in the same function body, this makes a certain class of attacks impossible to
execute in a correctly implemented spec-compliant WebAssembly runtime.

### Performance

WebAssembly instruction set is designed with performance in mind. A WebAssembly module can be JIT-interpreted or
compiled on a client machine to an optimized native binary ahead of time. With recently accepted proposals to the Wasm
specification it now supports features such as SIMD, atomics, multi-threading, and more. A WebAssembly runtime can
generate native binary code that implements these features with little performance overhead.

### 64-bit Support

WebAssembly specifies support for both 32-bit and 64-bit integers and floats as a baseline. Currently, the most common
pointer size used by Wasm binaries is 32-bit. A large proportion of Wasm applications and libraries don't need to
address more than 4 GiB of memory. Support for 64-bit pointers was added to the WebAssembly spec and widely used
runtimes later as an extension. Wasm binaries utilizing certain pointer width are referred as supporting `wasm32`
and `wasm64` "architectures" respectively.

### WebAssembly System Interface (WASI)

WebAssembly instruction set on its own doesn't "support" file I/O or networking, in the same way that ARM64 or x86_64
don't "support" those directly either. Actual implementation of I/O for a hardware CPU is provided by the operating system, and
for a Wasm module it's provided by a runtime that executes it.

A standardized set of APIs implemented by a Wasm runtime for interaction with the host
operating system is called [WebAssembly System Interface](https://wasi.dev). A layer on top of WASI that Swift apps compiled to Wasm
can already use thanks to C interop is [WASI libc](https://github.com/WebAssembly/wasi-libc). In fact, the current
implementation of Swift stdlib and runtime for `wasm32-unknown-wasi` triple is based on this C library.

### The WebAssembly Component Model

Initial version of WASI (referred to as "Preview 1" or as `wasi_snapshot_preview1` used by its Wasm module name) was
inspired by C ABI and POSIX, and WASI libc itself is a fork of a portable [Musl libc](http://musl.libc.org) used on
Linux. This proved to be limiting with continued development of WASI, especially as it does not necessarily have to
be constrained by C ABI and POSIX, as it can abstract these away in more powerful runtime implementations.

At the same time, W3C WebAssembly Working Group was considering multiple proposals for improving the WebAssembly [type
system](https://github.com/webassembly/interface-types) and
[module linking](https://github.com/webassembly/module-linking). These were later subsumed into a combined
[Component Model](https://component-model.bytecodealliance.org) proposal thanks to the ongoing work on
[WASI Preview 2](https://github.com/WebAssembly/WASI/blob/main/preview2/README.md), which served as playground for
the new design.

The Component Model defines these core concepts:

- A *component* is a composable container for one or more WebAssembly modules that have a predefined interface;
- *WebAssembly Interface Types (WIT) language* allows defining contracts between components;
- *Canonical ABI* is an ABI for types defined by WIT and used by component interfaces in the Component Model.

WIT is a high-level language with [an advanced type system](https://component-model.bytecodealliance.org/design/wit.html#built-in-types). It can be particularly interesting for Swift, as it allows significantly more Swift APIs to be exposed directly in interfaces of Wasm
components compiled from Swift.

Preliminary support for WIT has been implemented in
[the `wit-tool` subcommand](https://github.com/swiftwasm/WasmKit/blob/0.0.3/Sources/WITTool/WITTool.swift) of WasmKit
CLI.

## Goals

TBD
