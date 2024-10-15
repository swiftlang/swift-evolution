# A Vision for WebAssembly Support in Swift

## Introduction

WebAssembly (abbreviated [Wasm](https://webassembly.github.io/spec/core/intro/introduction.html#wasm)) is a virtual
machine instruction set focused on portability, security, and high performance. It is vendor-neutral, designed and
developed by [W3C](https://w3.org). An implementation of a WebAssembly virtual machine is usually called a
*WebAssembly runtime*.

One prominent spec-compliant implementation of a Wasm runtime in Swift is [WasmKit](https://github.com/swiftwasm/WasmKit). It is available as a Swift package, supports multiple
host platforms, and has a simple API for interaction with guest Wasm modules.

An application compiled to a Wasm module can run on any platform that has a Wasm runtime available. Despite its origins
in the browser, it is a general-purpose technology that has use cases in client-side and
server-side applications and services. WebAssembly support in Swift makes the language more appealing in those settings,
and also brings it to the browser where it previously wasn't available at all. It facilitates a broader adoption of
Swift in more environments and contexts.

We can't anticipate every possible application Swift developers are going to create with Wasm, but we can provide a few
examples of its possible adoption in the Swift toolchain itself. To quote
[a GSoC 2024 idea](https://www.swift.org/gsoc2024/#building-swift-macros-with-webassembly):

> WebAssembly could provide a way to build Swift macros into binaries that can be distributed and run anywhere,
> eliminating the need to rebuild them continually.

This can be applicable not only to Swift macros, but also for the evaluation of SwiftPM manifests and plugins.

The WebAssembly instruction set has useful properties from a security perspective, as it has
no interrupts or peripheral access instructions. Access to the underlying system is always done by calling
explicitly imported functions, implementations for which are provided by an imported WebAssembly module or a WebAssembly
runtime itself. The runtime has full control over interactions of the virtual machine with the outside world.

WebAssembly code and data live in completely separate address spaces, with all executable code in a given module loaded
and validated by the runtime upfront. Combined with the lack of "jump to address" and a limited set of control flow
instructions that require explicit labels in the same function body, this makes a certain class of attacks impossible to
execute in a correctly implemented spec-compliant WebAssembly runtime.

In the context of Swift developer tools, arbitrary code execution during build time can be virtualized with Wasm.
While Swift macros, SwiftPM manifests, and plugins are sandboxed on Darwin platforms, with Wasm we can provide stronger
security guarantees on other platforms that have a compatible Wasm runtime available.

The WebAssembly instruction set is designed with performance in mind. A WebAssembly module can be JIT-compiled or
compiled on a client machine to an optimized native binary ahead of time. With recently accepted proposals to the Wasm
specification it now supports features such as SIMD, atomics, multi-threading, and more. A WebAssembly runtime can
generate a restricted subset of native binary code that implements these features with little performance overhead.

This means that adoption of Wasm in developer tools does not imply unavoidable performance overhead. In fact, with
security guarantees that virtualization brings there's no longer a need to spawn a separate process for each
Swift compiler and SwiftPM plugin/manifest invocation. Virtualized Wasm binaries can run in the host process of a
Wasm runtime, removing the overhead of new process setup and IPC infrastructure.

### WebAssembly System Interface and the Component Model

The WebAssembly virtual machine has no in-built support for I/O; instead, a Wasm module's access to I/O is dependent entirely upon the runtime that executes it.

A standardized set of APIs implemented by a Wasm runtime for interaction with the host operating system is called
[WebAssembly System Interface (WASI)](https://wasi.dev). A layer on top of WASI that Swift apps compiled to Wasm can already
use thanks to C interop is [WASI libc](https://github.com/WebAssembly/wasi-libc). In fact, the current implementation of
Swift stdlib and runtime for `wasm32-unknown-wasi` triple is based on this C library. It is important for WASI support in
Swift to be as complete as possible to ensure portability of Swift code in the broader Wasm ecosystem.

In the last few years, the W3C WebAssembly Working Group considered multiple proposals for improving the WebAssembly
[type system](https://github.com/webassembly/interface-types) and
[module linking](https://github.com/webassembly/module-linking). These were later subsumed into a combined
[Component Model](https://component-model.bytecodealliance.org) proposal thanks to the ongoing work on
[WASI Preview 2](https://github.com/WebAssembly/WASI/blob/main/preview2/README.md), which served as playground for
the new design.

The Component Model defines these core concepts:

- A *component* is a composable container for one or more WebAssembly modules that have a predefined interface;
- *WebAssembly Interface Types (WIT) language* allows defining contracts between components;
- *Canonical ABI* is an ABI for types defined by WIT and used by component interfaces in the Component Model.

Preliminary support for WIT has been implemented in
[the `wit-tool` subcommand](https://github.com/swiftwasm/WasmKit/blob/0.0.3/Sources/WITTool/WITTool.swift) of the WasmKit
CLI. Users of this tool can generate `.wit` files from Swift declarations, and vice versa: Swift bindings from `.wit`
files.

## Goals

As of March 2024 all patches necessary for basic Wasm and WASI support have been merged to the Swift toolchain and
core libraries. Based on this, we propose a high-level roadmap for WebAssembly support and adoption in the Swift
ecosystem:

1. Ensure that Swift toolchain and core libraries have a regularly running test suite for supported Wasm and WASI
triples.

2. Allow Swift developers to easily install and build with a Swift SDK for WASI. This requires an implementation
of corresponding build scripts and CI jobs to generate and publish such SDK. Some parts of the Swift toolchain and core
libraries need a Swift SDK for running tests for WASI, so this will benefit the previous point in stabilizing support
for this platform.

3. Make it easier to evaluate and adopt Wasm with increased API coverage for this platform in the Swift core libraries. As a
virtualized embeddable platform, not all system APIs are always available or easy to port to WASI. For example,
multi-threading, file system access, and localization need special support in Wasm runtimes and a certain amount of
consideration from a developer adopting these APIs.

4. Improve support for cross-compilation in Swift and SwiftPM. We can simplify versioning, installation, and overall
management of Swift SDKs for cross-compilation in general, which is beneficial not only for WebAssembly, but for all
platforms.

5. Continue work on Wasm Component Model support in Swift as the Component Model proposal is stabilized. Ensure
that future versions of WASI are available to Swift developers targeting Wasm. A more ambitious long-term goal to
consider is making interoperability with Wasm components as smooth as C and C++ interop already is for Swift. With
a formal specification for Canonical ABI progressing, this goal will become more achievable with time.

### Proposed Language Features

In our work on Wasm support in Swift we experimented with a few function attributes that could be considered
as pitches and eventually Swift Evolution proposals, if the community is interested in their wider adoption.
These attributes allow easier interoperation between Swift code and other Wasm modules linked with it by a Wasm
runtime.

* [`@_extern(wasm)` attribute](https://github.com/apple/swift/pull/69107) that corresponds to Clang's
[`__attribute__((import_name("declaration_name")))`](https://clang.llvm.org/docs/AttributeReference.html#export-name)
and [`__attribute__((import_module("module_name")))`](https://clang.llvm.org/docs/AttributeReference.html#import-module).
This indicates that function's implementation is not provided together with its declaration in Swift and is
available externally, imported by a Wasm runtime during the linking phase. The declaration is added to current Wasm
module's imports section. Without `@_extern(wasm)` developers need to rely on C interop to create a declaration in a C
header using the Clang version of attributes.

* [`@_expose(wasm)` attribute](https://github.com/apple/swift/pull/68524) that corresponds to Clang's
[`__attribute__((export_name("name")))`](https://clang.llvm.org/docs/AttributeReference.html#export-name), which
is the counterpart of `@_extern(wasm)` working in the opposite direction. This explicitly makes a Swift declaration
available outside of the current module, added to its exports section under a given name. Again, the lack of
this attribute in Swift requires use of C headers as a workaround.

## Platform-specific Considerations

### Debugging

Debugging Wasm modules is challenging because Wasm does not expose ways to introspect and control the execution of
the Wasm instance, so a debugger cannot be built on top of Wasm itself. Therefore, special support from the Wasm
execution engine is necessary for debugging.

The current state of debugging tools in the Wasm ecosystem is not as mature as other platforms but there are two
main directions:

1. LLDB debugger with Wasm runtime supporting GDB Remote Serial Protocol [1]
2. Wasm runtime with a built-in debugger [2]

The first approach provides an almost equivalent experience to existing debugging workflows on other platforms. It
can utilize LLDB's Swift support, remote metadata inspection and serialized Swift module information. However, since
Wasm is a Harvard architecture and has no way to allocate executable memory space at runtime, implementing expression
evaluation with JIT in user space is challenging. In other words, gdb stub in Wasm engines need tricky implementations
or need to extend the GDB Remote Serial Protocol.

The second approach embeds the debugger within the Wasm engine. In scenarios where the Wasm engine is embedded as a guest
language in another host language engine (e.g. within a Web Browser), this approach allows seamless debugging experiences
with the host language by integrating with the host debugger. For example, in cases where JavaScript and Wasm call frames
are interleaved, the debugger works well in both contexts without switching tools. Debugging tools like Chrome DevTools
can use DWARF information embedded in Wasm file to provide debugging support. However, supporting Swift-specific
metadata information and JIT-based expression evaluation will require integrating LLDB's Swift plugin with these debuggers
in some way.

Given that both approaches can utilize DWARF information, the Swift toolchain should generate as much DWARF information as possible
for statically known things. Also, making Swift type information DWARF-friendly is desirable because the current debug
information generated by the Swift compiler assumes that debuggers can understand certain Swift primitives (e.g. `Swift.Int`
is currently represented as a `DW_TAG_structure_type` node without any member but ideally such types should be represented
as `DW_TAG_base_type` nodes with `DW_AT_encoding` attribute or provide a debug summary string by LLDB Summary Strings)

[1]: https://github.com/llvm/llvm-project/pull/77949
[2]: https://github.com/ChromeDevTools/devtools-frontend/blob/main/extensions/cxx_debugging

### Multi-threading and Concurrency

WebAssembly has [atomic operations in the instruction set](https://github.com/WebAssembly/threads) (only sequential
consistency is supported), but it does not have a built-in way to create threads. Instead, it relies on the host
environment to provide multi-threading support. This means that multi-threading in Wasm is dependent on the Wasm runtime
that executes the module. There are two proposals to standardize ways to create threads in Wasm: (1) [wasi-threads](https://github.com/WebAssembly/wasi-threads),
which is already supported by some toolchains, runtimes, and libraries but has been superseded by the new one. (2) The
new proposal [shared-everything-threads](https://github.com/WebAssembly/shared-everything-threads) is still in the
early stages of spec development but is expected to be the future of multi-threading in Wasm.

Swift currently supports two threading models in Wasm: single-threaded (`wasm32-unknown-wasi`) and multi-threaded
using wasi-threads (`wasm32-unknown-wasip1-threads`). Despite the latter supporting multi-threading, Swift Concurrency defaults
to a cooperative single-threaded executor due to the lack of wasi-threads support in libdispatch. Preparing for the
shared-everything-threads proposal is crucial to ensure that Swift Concurrency can adapt to future multi-threading
standards in Wasm.

### 64-bit address space

WebAssembly currently uses a 32-bit address space, but the specification is going to support [64-bit address space](https://github.com/WebAssembly/memory64/).
Swift already has support on 64-bit for other platforms, however, WebAssembly is the first platform where relative reference
from data to code is not allowed. Alternative solutions like image-base relative addressing or small "code model" for fitting
64-bit pointer in 32-bit are unavailable, at least for now. This means that we need cooperation from the WebAssembly toolchain
side or different memory layout in Swift metadata to support 64-bit in WebAssembly.

### Shared libraries

There are two approaches to using shared libraries in WebAssembly ecosystem:

1. [Emscripten-style dynamic linking](https://emscripten.org/docs/compiling/Dynamic-Linking.html)
2. [Component Model-based "ahead-of-time" linking](https://github.com/WebAssembly/component-model/blob/main/design/mvp/Linking.md)
Emscripten-style dynamic linking is a traditional way to use shared libraries in WebAssembly, where the host environment provides
non-standard dynamic loading capabilities.

Component Model-based AOT linking is a new way that transforms shared library WebAssembly Core modules compiled with
Emscripten's dynamic linking ABI into a single WebAssembly Component at build time. The latter approach cannot fully replace the former,
as it is not able to handle dynamic loading of shared libraries at runtime, but it is more portable way to distribute programs linked
with shared libraries because it does not require the host environment to provide any special capabilities except for Component Model
support.

From the Swift toolchain perspective, they both use the Emscripten's dynamic linking ABI, so the support for shared libraries in
Swift is mostly about making sure that Swift programs can be compiled in position-independent code mode and linked with shared
libraries by following the dynamic linking ABI.
