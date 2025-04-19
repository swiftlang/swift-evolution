# A Vision for WebAssembly Support in Swift

## Introduction

WebAssembly (abbreviated [Wasm](https://webassembly.github.io/spec/core/intro/introduction.html#wasm)) is a virtual
machine instruction set focused on portability, security, and high performance. It is vendor-neutral, designed and
developed by [W3C](https://w3.org). An implementation of a WebAssembly virtual machine is usually called a
*WebAssembly runtime*.

One prominent spec-compliant implementation of a Wasm runtime in Swift is [WasmKit](https://github.com/swiftwasm/WasmKit).
It is available as a Swift package, supports multiple host platforms, and has a simple API for interaction with guest
Wasm modules.

An application compiled to a Wasm module can run on any platform that has a Wasm runtime available. Despite its origins
in the browser, it is a general-purpose technology that has use cases in client-side and server-side applications and
services. WebAssembly support in Swift makes the language more appealing in those settings, and also brings it to the
browser where it previously wasn't available at all[^1]. It facilitates a broader adoption of Swift in more environments
and contexts.

The WebAssembly instruction set has useful properties from a security perspective, as it has no interrupts or
peripheral access instructions. Access to the underlying system is always done by calling explicitly imported
functions, implementations for which are provided by an imported WebAssembly module or a WebAssembly runtime itself.
The runtime has full control over interactions of the virtual machine with the outside world.

WebAssembly code and data live in completely separate address spaces, with all executable code in a given module loaded
and validated by the runtime upfront. Combined with the lack of "jump to address" and a limited set of control flow
instructions that require explicit labels in the same function body, this makes a certain class of attacks impossible to
execute in a correctly implemented spec-compliant WebAssembly runtime.

### WebAssembly System Interface and the Component Model

The WebAssembly virtual machine has no in-built support for I/O; instead, a Wasm module's access to I/O is dependent
entirely upon the runtime that executes it.

A standardized set of APIs implemented by a Wasm runtime for interaction with the host operating system is called
[WebAssembly System Interface (WASI)](https://wasi.dev). [WASI libc](https://github.com/WebAssembly/wasi-libc) is a
layer on top of WASI that Swift apps compiled to Wasm can already use thanks to C interop. The current implementation
of Swift stdlib and runtime for `wasm32-unknown-wasi` triple is based on this C library. It is important for WASI
support in Swift to be as complete as possible to ensure portability of Swift code in the broader Wasm ecosystem.

In the last few years, the W3C WebAssembly Working Group considered multiple proposals for improving the WebAssembly
[type system](https://github.com/webassembly/interface-types) and
[module linking](https://github.com/webassembly/module-linking). These were later subsumed into a combined
[Component Model](https://component-model.bytecodealliance.org) proposal thanks to the ongoing work on
[WASI Preview 2](https://github.com/WebAssembly/WASI/blob/main/wasip2/README.md), which served as playground for
the new design.

The Component Model defines these core concepts:

- A *component* is a composable container for one or more WebAssembly modules that have a predefined interface;
- *WebAssembly Interface Types (WIT) language* allows defining contracts between components;
- *Canonical ABI* is an ABI for types defined by WIT and used by component interfaces in the Component Model.

Preliminary support for WIT has been implemented in
[the `wit-tool` subcommand](https://github.com/swiftwasm/WasmKit/blob/0.0.3/Sources/WITTool/WITTool.swift) of the
WasmKit CLI. Users of this tool can generate `.wit` files from Swift declarations, and vice versa: Swift bindings from
`.wit` files.

## Use Cases

We can't anticipate every possible application Swift developers are going to create with Wasm, but we can provide a few
examples of its possible adoption in the Swift toolchain itself. To quote
[a GSoC 2024 idea](https://www.swift.org/gsoc2024/#building-swift-macros-with-webassembly):

> WebAssembly could provide a way to build Swift macros into binaries that can be distributed and run anywhere,
> eliminating the need to rebuild them continually.

This can be applicable not only to Swift macros, but also for the evaluation of SwiftPM manifests and plugins.

In the context of Swift developer tools, arbitrary code execution during build time can be virtualized with Wasm.
While Swift macros, SwiftPM manifests, and plugins are sandboxed on Darwin platforms, with Wasm we can provide stronger
security guarantees on other platforms that have a compatible Wasm runtime available.

The WebAssembly instruction set is designed with performance in mind. A WebAssembly module can be JIT-compiled or
compiled on a client machine to an optimized native binary ahead of time. With recently accepted proposals to the Wasm
specification it now supports features such as SIMD, atomics, multi-threading, and more. A WebAssembly runtime can
generate a restricted subset of native binary code that implements these features with little performance overhead.

Adoption of Wasm in developer tools does not imply unavoidable performance overhead. With security guarantees that
virtualization brings, there's no longer a need to spawn a separate process for each Swift compiler and SwiftPM
plugin/manifest invocation. Virtualized Wasm binaries can run in the host process of a Wasm runtime, removing the
overhead of new process setup and IPC infrastructure.

## Goals

As of March 2024 all patches necessary for basic Wasm and WASI Preview 1 support have been merged to the Swift
toolchain and core libraries. Based on this, we propose a high-level roadmap for WebAssembly support and adoption in the Swift
ecosystem:

1. Make it easier to evaluate and adopt Wasm with increased API coverage for this platform in the Swift core libraries.
   Main prerequisite for that is setting up CI jobs for those libraries that run tests for WASI and also Embedded Wasm, where
   possible. As a virtualized embeddable platform, not all system APIs are always available or easy to port to WASI. For example,
   multi-threading, file system access, networking and localization need special support in Wasm runtimes and a certain amount of
   consideration from a developer adopting these APIs.

2. Improve support for cross-compilation in Swift and SwiftPM. We can simplify versioning, installation, and overall
   management of Swift SDKs for cross-compilation in general, which is beneficial not only for WebAssembly, but for all
   platforms.

3. Continue work on Wasm Component Model support in Swift as the Component Model proposal is stabilized. Ensure
   that future versions of WASI are available to Swift developers targeting Wasm.

4. Make interoperability with Wasm components as smooth as C and C++ interop already is for Swift. With a formal
   specification for Canonical ABI progressing, this will become more achievable with time. This includes consuming
   components from, and building components with Swift.

5. Improve debugging experience of Swift code compiled to Wasm. While rudimentary support for debugging
   exists in some Wasm runtimes, we aim to improve it and, where possible, make it as good as debugging Swift code
   compiled to other platforms.

### Proposed Language Features

In our work on Wasm support in Swift, we experimented with a few function attributes that could be considered
as pitches and eventually Swift Evolution proposals, if the community is interested in their wider adoption.
These attributes allow easier interoperation between Swift code and other Wasm modules linked with it by a Wasm
runtime.

## Platform-specific Considerations

### Debugging

Debugging Wasm modules is challenging because Wasm does not expose ways to introspect and control the execution of
a Wasm module instance, so a debugger cannot be built on top of Wasm itself. Special support from the Wasm execution
engine is necessary for debugging.

The current state of debugging tools in the Wasm ecosystem is not as mature as other platforms, but there are two
main directions:

1. [LLDB debugger with Wasm runtime](https://github.com/llvm/llvm-project/pull/77949) supporting GDB Remote Serial Protocol;
2. [Wasm runtime with a built-in debugger](https://book.swiftwasm.org/getting-started/debugging.html#enhanced-dwarf-extension-for-swift).

The first approach provides an almost equivalent experience to existing debugging workflows on other platforms. It
can utilize LLDB's Swift support, remote metadata inspection, and serialized Swift module information. However, since
Wasm is a Harvard architecture and has no way to allocate executable memory space at runtime, implementing expression
evaluation with JIT in user space is challenging. In other words, GDB stub in Wasm engines need tricky implementations
or need to extend the GDB Remote Serial Protocol.

The second approach embeds the debugger within the Wasm engine. In scenarios where the Wasm engine is embedded as a
guest in another host engine (e.g. within a Web Browser), this approach allows seamless debugging experiences with the
host language by integrating with the host debugger. For example, in cases where JavaScript and Wasm call frames
are interleaved, the debugger works well in both contexts without switching tools. Debugging tools like Chrome DevTools
can use DWARF information embedded in Wasm file to provide debugging support. However, supporting Swift-specific
metadata information and JIT-based expression evaluation will require integrating LLDB's Swift plugin with these
debuggers in some way.

In summary, debugging in the browser and outside of the browser context are sufficiently different activities to
require separate implementation approaches.

### Multi-threading and Concurrency

WebAssembly has [atomic operations in the instruction set](https://github.com/WebAssembly/threads) (only sequential
consistency is supported), but it does not have a built-in way to create threads. Instead, it relies on the host
environment to provide multi-threading support. This means that multi-threading in Wasm is dependent on the Wasm runtime
that executes a module. There are two proposals to standardize ways to create threads in Wasm:

(1) [wasi-threads](https://github.com/WebAssembly/wasi-threads), which is already supported by some toolchains,
runtimes, and libraries but has been superseded;

(2) The new [shared-everything-threads](https://github.com/WebAssembly/shared-everything-threads) proposal is still
in the early stages, but is expected to be the future of multi-threading in Wasm.

Swift currently supports two threading models in Wasm: single-threaded (`wasm32-unknown-wasi`) and multi-threaded
using wasi-threads (`wasm32-unknown-wasip1-threads`). Despite the latter supporting multi-threading, Swift Concurrency
defaults to a cooperative single-threaded executor due to the lack of wasi-threads support in libdispatch. Preparing
for the shared-everything-threads proposal is crucial to ensure that Swift Concurrency can adapt to future
multi-threading standards in Wasm.

### 64-bit address space

WebAssembly currently uses a 32-bit address space, but [64-bit address space](https://github.com/WebAssembly/memory64/)
proposal is already in the implementation phase.

Swift supports 64-bit pointers on other platforms where available, however WebAssembly is the first platform where
relative reference from data to code is not allowed. Alternative solutions like image-base relative addressing or
"small code model" for fitting 64-bit pointer in 32-bit are unavailable, at least for now. This means that we need
cooperation from the WebAssembly toolchain side or different memory layout in Swift metadata to support 64-bit linear
memory support in WebAssembly.

### Shared libraries

There are two approaches to using shared libraries in the WebAssembly ecosystem:

1. [Emscripten-style dynamic linking](https://emscripten.org/docs/compiling/Dynamic-Linking.html)
2. [Component Model-based "ahead-of-time" linking](https://github.com/WebAssembly/component-model/blob/main/design/mvp/Linking.md)

Emscripten-style dynamic linking is a traditional way to use shared libraries in WebAssembly, where the host
environment provides non-standard dynamic loading capabilities.

The latter approach cannot fully replace the former, as it is unable to handle dynamic loading of shared libraries at
runtime, but it is more portable way to distribute programs linked with shared libraries, as it does not require the
host environment to provide any special capabilities except for Component Model support.

Support for shared libraries in Swift means ensuring that Swift programs can be compiled in
position-independent code mode and linked with shared libraries by following the corresponding dynamic linking ABI.

[^1]: We aim to address browser-specific use cases in a separate future document.
