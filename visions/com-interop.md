# A Vision for COM Interoperability in Swift

## Introduction

The Component Object Model (COM) is the foundational binary interface standard underlying the Windows platform. Every significant Windows API surface, from Win32 shell extensions to Direct3D, from Office automation to the Windows Runtime (WinRT), is defined in terms of COM interfaces. COM is also used cross-platform: Mozilla's XPCOM and Apple's IOKit both implement COM-compatible binary interfaces, and projects like [MiniCOM](https://github.com/forderud/MiniCOM) demonstrate that the binary model is genuinely portable across Linux, macOS, Android, iOS, and WebAssembly.

Swift on Windows currently has no first-class story for COM. Developers who need to call COM APIs from Swift must drop to unsafe C pointer manipulation, hand-write vtable structs, and manage reference counts manually alongside Swift ARC. This is fragile, verbose, and error-prone. This vision describes how Swift can make COM interoperability as natural as its existing Objective-C interoperability.

The guiding principle is that **COM is the binary interface; Swift is the language**. Swift developers should never have to think about vtable layout, reference counting, interface identity, or memory allocation domains. They write idiomatic Swift — protocols, classes, properties, `throws`, `async`/`await`, `for`/`in` — and the compiler handles the COM binary interface automatically.

## Goals

### Toll-free bidirectional bridging

Swift code should be able to consume existing COM interfaces, implement COM interfaces, declare new COM interfaces, and expose them to other COM-speaking languages, all with the same type fidelity and performance as native C++ COM code. A COM interface should feel like a Swift protocol. A COM coclass should feel like a Swift class. Crossing the language boundary should cost nothing beyond what the COM ABI itself requires.

### Safety without ceremony

The ARC bridge should be the sole owner of the reference count. Swift developers should never call `AddRef` or `Release`. `QueryInterface` should be expressed as Swift's `as?` operator. Memory allocation domains (CoTaskMem, BSTR, HSTRING) should be handled automatically by synthesised wrappers. Error handling should use `throws`, not manual `HRESULT` checks.

### ABI compatibility

The object layout and vtable structure should be binary-compatible with C++ COM objects. A Swift-implemented COM object should be callable from C++, C#, or any other COM-speaking language without an adapter layer. The ABI should be lightweight enough to be toll-free in both directions.

### Cross-platform

The core `@COM` attribute and ARC bridge should not be Windows-specific. They should work wherever Swift runs and COM-like interfaces exist: Windows COM, XPCOM, IOKit, MiniCOM. Platform-specific features (apartments, activation, registration) should be layered on top without changing the core model.

### Incremental adoption

Existing C/C++ COM code imported via the Clang importer should be automatically elevated to idiomatic Swift without requiring annotation changes to the original headers. HRESULT-returning methods should become `throws`. Property accessor pairs should become Swift properties. Hungarian-notation parameters should be renamed. Counted arrays should become `[T]`.

## Layered design

The interoperability is structured in three layers, each building on the previous:

### Layer 1: Core COM (compiler and runtime)

The first layer provides the language-level support for COM's binary interface. This is the work that requires compiler changes:

- A `@COM` attribute on protocols (declaring COM interfaces with IIDs) and classes (declaring COM coclasses with optional CLSIDs).
- Compiler-synthesised `QueryInterface`, `AddRef`, and `Release` with a unified ARC reference count (no separate COM refcount).
- A compact object layout where COM vtable pointers precede the Swift object header, with a `vtable[−1]` adjustment constant for pointer recovery.
- An `ISwiftObject` COM interface for recovering the Swift heap object from any COM interface pointer, enabling `as?` to work across the COM boundary.
- Table-driven `QueryInterface` with a shared implementation in the `COM` module, so that the `QueryInterface` logic is not duplicated per class.
- Shared `AddRef`/`Release` thunks in the `COM` module, generic across all `@COM` classes.
- Clang importer integration: structural `IUnknown` detection, HRESULT-to-`throws` promotion, `[retval]` promotion, property synthesis, name translation, and MIDL array annotation handling.
- A `COM` standard library module providing `IUnknown`, `ISwiftObject`, `COMError`, activation overlays, threading types, and extensions on SDK-imported types (`GUID`, `IID`, `CLSID`, `HRESULT`).

This layer is platform-independent. It works with Windows COM, XPCOM, IOKit, and MiniCOM.

### Layer 2: Windows platform integration (compiler and library)

The second layer adds Windows-specific features that are meaningful only when targeting the Windows COM runtime:

- Threading model declaration (`@COM(CLSID:, ThreadingModel:)`) and the `COMThreadingModel` enum.
- `COMExecutor` and `COMMultithreadedExecutor` bridging COM apartments to Swift's concurrency model.
- `withCOMContext`, `COMContext`, and `@COMMain` for COM initialisation lifecycle.
- `withActivationContext` for scoped `CLSCTX` via `@TaskLocal`.
- `DllGetClassObject`, `IClassFactory`, `DllRegisterServer`/`DllUnregisterServer` synthesis for `@COM(CLSID:)` classes.
- `@COMInit` for designating the activation initialiser.
- `ISupportErrorInfo` synthesis and `IErrorInfo` capture/population.
- `BSTR` and `LPWSTR` string bridging with correct allocation domains.

### Layer 3: WinRT projection (pure library)

The third layer projects the Windows Runtime onto Swift. This layer requires **no compiler changes**. It is a pure library built on the `@COM` infrastructure from Layer 1:

- `IInspectable` synthesis (`GetIids`, `GetRuntimeClassName`, `GetTrustLevel`) implemented as library code reading compiler-emitted metadata.
- Parameterised interface IID derivation via UUID v5 (SHA-1), using the `WindowsRuntimeType` protocol for type signatures. The concrete IID is computed from compile-time constant inputs and stored directly.
- `IAsyncOperation<T>` and `IAsyncAction` bridged to Swift `async`/`await` via continuations.
- WinRT events (`add_`/`remove_` with `EventRegistrationToken`) bridged to `AsyncSequence`.
- WinRT collections (`IVector<T>`, `IMap<K,V>`, `IIterable<T>`) bridged to Swift `Sequence` and `Collection`.
- `HSTRING` bridging with the `WindowsCreateStringReference` fast-pass optimisation.
- `RoActivateInstance`/`RoGetActivationFactory` overlays and the `@WinRT(RuntimeName:)` macro.

The fact that WinRT requires no compiler changes is a key architectural property. It means the WinRT projection can evolve independently of the Swift compiler, new WinRT patterns can be added as library code, and the compiler team's investment is focused on the COM layer that benefits all COM-family implementations.

## What the developer sees

### Consuming a COM interface

```swift
// COM: ISpVoice inherits ISpEventSource inherits IUnknown
// Swift developer sees a protocol with methods and properties:
let voice = try SpVoice()
try voice.speak("Hello, world")

if let eventSource = voice as? any ISpEventSource {
    for await event in eventSource.events {
        print(event)
    }
}
```

No vtable structs. No `QueryInterface` calls. No `AddRef`/`Release`. No `HRESULT` checking. The COM binary interface is invisible.

### Implementing a COM interface

```swift
@COM(CLSID: "...")
final class MyWidget: IWidget {
    func render() throws { ... }
    var name: String { get throws { "MyWidget" } }
}
```

The class is a COM coclass. It can be activated via `CoCreateInstance` from C++, C#, or any COM-speaking language. The compiler synthesises the vtable, the class factory, and the registration exports.

### Declaring a new COM interface

```swift
@COM(IID: "...")
protocol ICanvas: IUnknown {
    func drawRect(_ rect: Rect) throws
    var background: Color { get throws set }
}
```

The protocol is a COM interface. Its IID and vtable layout are part of the module's ABI. Non-Swift consumers can use it through a generated C header or IDL file.

## Relationship to existing interoperability

COM interoperability follows the model established by Objective-C and C++ interop in Swift:

- Like `-enable-objc-interop`, COM interop is gated behind `-enable-com-interop` (enabled by default on Windows).
- Like the `ObjectiveC` module, the `COM` module provides foundational types and overlays.
- Like `-emit-objc-header`, a future `-emit-com-header` would generate C/C++ interface descriptions from Swift `@COM` declarations.
- Like Objective-C's `isa` pointer, COM's vtable pointers precede the Swift object header in a layout that is ABI-compatible with C++ COM objects.
- Like `@objc` on classes, `@COM` opts a type into the foreign type system while keeping it fully usable from Swift.

Both Objective-C interop and COM interop are platform-independent in principle (Objective-C depends on the ObjC runtime ABI, COM depends on the COM vtable ABI). The practical difference is that COM has multiple independent implementations across platforms (Windows COM, IOKit, XPCOM, MiniCOM), while Objective-C interop targets a single runtime family. The same `@COM` attribute works with all of these implementations. Platform-specific features (apartments, activation, WinRT) are layered on top.

## Companion documents

The detailed design is split into two companion documents:

- **COM Interoperability Design** (`com-interop-design.md`) — covers the compiler and language-level work in Layers 1 and 2: the `@COM` attribute, object layout, ARC bridge, `QueryInterface` implementation, Clang importer integration, threading model, activation, aggregation, and the `COM` module contents.

- **WinRT Projection Design** (`winrt-projection-design.md`) — covers the pure-library Layer 3: `IInspectable` synthesis, parameterised interfaces, async bridging, event sequences, collection conformances, `HSTRING` bridging, and WinRT activation.

## Future directions

### Automation (IDispatch, VARIANT, SAFEARRAY)

`IDispatch` enables late-binding COM access from scripting engines and Office VBA. `VARIANT` is COM's dynamically-typed value container. These are important for Office automation and scripting interop but are deferred from the initial design.

### DCOM and Swift's Distributed module

DCOM extends COM with cross-process and cross-machine invocation. The current design accommodates DCOM as a natural extension: a future `COMDistributedActorSystem` could bridge COM's proxy/stub infrastructure to Swift's `distributed actor` model with no changes to the core `@COM` attribute or ABI.

### Interface export tooling

Generating C/C++ headers, MIDL IDL, and `.winmd` metadata from Swift `@COM` declarations would complete the bidirectional story, allowing non-Swift consumers to call Swift COM objects without hand-written interface descriptions.

### Automation type bridging

`DECIMAL`, `CURRENCY`, `DATE`, MIDL unions, and `SAFEARRAY` need Swift mappings for full fidelity with the OLE Automation type system.
