# Section Placement Control

* Proposal: [SE-0492](0492-section-control.md)
* Authors: [Kuba Mracek](https://github.com/kubamracek)
* Status: **Accepted**
* Implementation: available in recent `main` snapshots under the experimental feature `SymbolLinkageMarkers` and with undercored attribute names `@_section` and `@_used`.
* Review: [review](https://forums.swift.org/t/se-0492-section-placement-control/82289), [acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0492-section-placement-control/82701)
* Discussion threads:
  * Pitch #1: https://forums.swift.org/t/pitch-low-level-linkage-control-attributes-used-and-section/65877
  * Pitch #2: https://forums.swift.org/t/pitch-2-low-level-linkage-control/69752
  * Pitch #3: https://forums.swift.org/t/pitch-3-section-placement-control/77435

## Introduction

This proposal adds `@section` and `@used` attributes which can be applied to global variables. These allow users to directly control which section of the resulting binary should global variables be emitted into, and give users the ability to disable DCE (dead code elimination) on those. The goal is to enable systems and embedded programming use cases like runtime discovery of test metadata from multiple modules, and also to serve as a low-level building block for higher-level features (e.g. linker sets, plugins).

## Motivation

**Testing frameworks** need to be able to produce test metadata about user’s types and other declarations (e.g. standalone test entrypoints) in a way that they are discoverable and enumerable at runtime. In dynamic languages like Objective-C, this is typically done at runtime using reflection, by querying the language runtime, and/or walking lists of types or exported symbols:

```swift
// MyXCTestModule
@objc class TableValidationTests: XCTestCase {
    func test1() { ... }
}

// Testing framework, pseudo-code
let classList = objc_copyClassList(...)
for aClass in classList {
  if aClass is XCTestCase {
    let methodList = class_copyMethodList(aClass)
    ...
  }
}
```

A similarly dynamic approach was proposed in [SE-0385 (Custom Reflection Metadata)](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0385-custom-reflection-metadata.md), but was rejected because for Swift, a more static approach would be a better fit: If Swift code had the ability to produce custom metadata directly into the resulting binaries in a well-understood way, we would be able to directly access the data at runtime via platform loader’s APIs and also use offline binary inspection tools (such as objdump, objcopy, otool). This would be more efficient and not require the language runtime and thus also be palatable in embedded use cases using Embedded Swift.

Mainstream operating systems support dynamically loading modules from disk at runtime, and large applications tend to build **plugin systems** as a way to separate the development of subsystems, or to support separate compilation of 3rd party code. Loading a module from disk can be done using standard APIs like `dlopen`, but discovering and calling the interface in the plugin usually requires using unsafe C constructs (dlsym, casting of pointers) and/or querying the language runtime for type information, similarly to the testing enumerating approach mentioned above. A better approach could publish the information about a plugin in a structured way into the binary, and a runtime component could locate this metadata, and provide access to it in a type-safe way.

This proposal recommends to use sections of the various object file formats as the vehicle for custom metadata produced by Swift code. This approach is a good fit to the above mentioned use cases, but also enables others:

* “**Linker sets**” are an approach in systems programming that collects data from multiple source files or subsystems using a standard linker behavior of collocating symbols that belong to the same section. In principle, this is simply a generalization of the test enumeration and plugin discovery use cases mentioned above. The primary goal is decentralization of the information, for example, linker sets can be used to describe memory requirements of each subsystem (and a boot step at runtime can process those to figure out how much heap should be made available).
* Emitting custom metadata into binaries can be used to convey **information to the debugger**. The `@DebugDescription` macro generates a “summary string” for LLDB that summarizes the contents of the fields of a type without the need for runtime evaluation, but rather as a composition of the fields that LLDB assembles. To make those summary strings discoverable by LLDB, placing them into a custom section is a clean solution allowing LLDB to consume them in the case where LLDB has access to the binary on disk, or even without that. Embedded programs might need to rely on such a mechanism as the only way to get enhanced data visualization in the debugger, because runtime evaluation from a debugger is commonly not possible at all in firmware.

```swift
@DebugDescription struct Student { 
  var name: String
  var id: Int

  /* synthesized by the @DebugDescription macro, made discoverable by LLDB */
  let __Student_lldb_summary = ("PupilKit.Student", "${var.id}: ${var.name}")
}
```

* More embedded and systems programming use cases often require directly control of section placement as well, for example to adhere to a **startup contract** with platform libraries, SDK’s linker scripts or the hardware itself. Such contract can be pre-existing in the platform and require placing a specific data structure into a specific section. Enabling doing that directly in Swift will provide a more intuitive and safer implementation option, and users of Swift for embedded devices won’t need to reach for C/C++ as a workaround.

## Proposed Solution

The proposal is to add two new attributes `@section` and `@used` that will allow annotating global and static variables with directives to place the value into a custom section, and to require no-dead-stripping aka "attribute used". Using `@section` requires that the initializer expression is a constant expression (see [Constant expressions](#constant-expressions) below for the definition of that):

```swift
// Place an entry into a section, mark as "do not dead strip".
// Initializer expression must be a constant expression.
// The global variable is implicitly made statically initialized.
@section("__DATA,mysection")
@used
let myLinkerSetEntry: Int = 42 // ✅

// Non-constant or statically non-initializable expressions are disallowed
@section("__DATA,mysection")
let myLinkerSetEntry: Int = Int.random(in: 0 ..< 10) // ❌ error

// Section-placed globals can be "var", the initializer expression still must be constant
@section("__DATA,mysection")
var mutableVariable: Int = 42 // ✅

// Some complex data types are allowed (tuples, function references)
typealias PluginData = (version: Int, identifier: UInt64, initializer: @convention(c) ()->())

@section("__DATA,plugins")
@used
let myPlugin: PluginData = (
    version: 1,
    initializer: { print("init") }
)
```

On top of specifying a custom section name with the `@section` attribute, marking a variable as `@used` is needed to prevent otherwise unused symbols from being removed by the compiler. When using section placement to e.g. implement linker sets, such values are typically going to have no usage at compile time, and at the same time they should not be exposed in public interface of libraries (not be made public), therefore we the need the `@used` attribute.

Different object file formats (ELF, Mach-O, COFF) have different restrictions and rules on what are valid section names, and cross-platform code will have to use different names for different file formats. To support that, custom section names can be specified as a string literal. The string will be used directly, without any processing, as the section name for the symbol. A new `#if objectFormat(...)` conditional compilation directive will be provided to support conditionalizing based on the file format:

```swift
#if objectFormat(ELF)
@section("mysection")
#elseif objectFormat(MachO)
@section("__DATA,mysection")
#endif
var global = ...
```

For the ELF file format specifically, the compiler will also emit a “section index” into produced object files, containing an entry about each custom section used in the compilation. This is a solution to an ELF specific problem where the behavior of ELF linkers and loaders means that sections are not easily discoverable at runtime.

> Note: The intention is that the `@section` and `@used` attributes are to be used rarely and only by specific use cases; high-level application code should not need to use them directly and instead should rely on libraries, macros and other abstractions over the low-level attributes.

> The scope of this proposal is limited to compile-time behavior and compile-time control. We expect that full user-facing solutions for features like linker sets, test discovery or plugins will also require runtime implementations to discover and iterate the contents of custom sections, possibly from multiple modules. This proposal makes sure to provide the right building blocks and artifacts in binaries for the runtime components, but doesn’t prescribe the shape of those. However, it is providing a significant step towards generalized and safe high-level mechanisms for those use cases. See the discussion in [Runtime discovery of data in custom sections](#runtime-discovery-of-data-in-custom-sections) and [Linker sets, plugins as high-level APIs](#linker-sets-plugins-as-high-level-apis) in Future Directions.

## Detailed design

### Attributes @section and @used on global and static variables

Two new attributes are to be added: `@section`, which has a single argument specifying the section name, and a argument-less `@used` attribute. The section name must be a string literal. The attributes can be used either together or independently.

```swift
// (1)
@section("__DATA,mysection")
@used
let global = ... // ✅

// (2)
@section("__DATA,mysection")
let global = ... // ✅

// (3)
@used
let global = ... // ✅
```

The new attributes (`@section` and `@used`) can be used on variable declarations under these circumstances:

* the variable must be a global variable or a static member variable (no local variables, no non-static member variables)
* the variable must not be declared inside a generic context (either directly in generic type or nested in a generic type)
* the variable must be a stored property (not a computed property)
* the variable must not have property observers (didSet, willSet)
* the initial expression assigned to the variable must be a constant expression, and it must be eligible for static initilization

> *Note: These restrictions limit the `@section` and `@used` attributes to only be allowed on variables that are expected to be represented as exactly one statically-initialized global storage symbol (in the linker sense) for the variable’s content. This is generally true for all global and static variables in C and C++, but in Swift global variables might have zero global storage symbols (e.g. a computed property), or need non-trivial storage (e.g. lazily initialized variables with runtime code in the initializer expression).*

```swift
@section("__DATA,mysection") @used
let global = 42 // ✅

@section("__DATA,mysection") @used
var global = 42 // ✅

@section("__DATA,mysection") @used
var computed: Int { return 42 } // ❌ ERROR: @section cannot be used on computed properties

struct MyStruct {
  @section("__DATA,mysection") @used
  static let staticMemberLet = 42 // ✅ 

  @section("__DATA,mysection") @used
  static var staticMemberVar = 42 // ✅ 
  
  @section("__DATA,mysection") @used
  let member = 42 // ❌ ERROR: @section cannot be used on non-static members

  @section("__DATA,mysection") @used
  var member = 42 // ❌ ERROR: @section cannot be used on non-static members
}

struct MyGenericStruct<T> {
  @section("__DATA,mysection") @used
  static let staticMember = 42 // ❌ ERROR: @section cannot be used in a generic context

  @section("__DATA,mysection") @used
  static var staticMember = 42 // ❌ ERROR: @section cannot be used in a generic context
}
```

When allowed, the `@section` attribute on a variable declaration has the following effects:

1. The variable’s initializer expression is going to be constant folded at compile-time, and assigned as the initial value to the storage symbol for the variable, i.e. the variable will be **statically initialized**. The variable’s value will not be lazily computed at runtime, and it will not use the one-time initialization helper code and token. If that’s not possible, an error is diagnosed.
2. The storage symbol for the variable will be placed into a custom section with the specified name.
   - Concretely, the section name string value will be set verbatim as a section specifier for the storage symbol at the LLVM IR level of the compiler. This means that any special behavior that the optimizer, the backend, the assembler or the linker applies based on known section names (or attributes specified as suffixes on the section name) will apply.
3. If applied to a global that is declared as part of top-level executable code (i.e. main.swift), the usual non-top-level-code initialization behavior is applied to the global. I.e. the variable is not sequentially initialized at startup.

The custom section name specified in the `@section` attribute is not validated by the compiler, instead it’s passed directly as a string to the linker. 

When allowed, the `@used` attribute on a variable declaration has the following effect:

1. The storage symbol for the variable will be marked as “do not dead-strip”.

The effects described above are applied to the storage symbols and don’t generally affect optimizations and other transformations in the compiler. For example, the compiler is still allowed to propagate and copy a constant value of a `let` variable to code that uses the variable, therefore there’s no guarantee that a value stored into a global with a custom section will not be propagated and “leak” outside of the section. The `@used` annotation, however, does inform the optimizer that such a variable cannot be removed, even when it doesn’t have any observed users or even if it’s inaccessible due to language rules (e.g. if it’s a private static member on an otherwise empty type).

### Constant expressions

Swift currently does not have a formal notion of a **constant expression**, i.e. an expression with a syntactic form that *guarantees the ability to know it's value at compile-time*. This proposal provides a definition of a "bare minimum" constant expression, with the understanding that this does not cover the language needs in generality, and with the expectation that the Swift compiler and language will keep expanding the allowed forms of constant expressions in the future. See [Generalized constant values and expressions](#generalized-constant-values-and-expressions) in Future Directions for further discussion on this.

This proposal defines a **constant expression** as being one of:

- an integer literal using any of standard integer types (Int, UInt, Int8/16/32/64/128, UInt8/16/32/64/128)
- a floating-point literal of type Float or Double
- a boolean literal of type Bool
- a direct reference to a non-generic function using its name (the function itself is not generic, and also it must not be defined in a generic context)
- a closure literal with no captures and not in a generic context
- a direct reference to a non-generic metatype using the type name directly (the type itself is not generic, and also it must not be defined in a generic context), where the type is non-resilient
- a tuple composed of only other constant expressions
- an array literal of type InlineArray composed of only other constant expressions

Explicitly, this definition currently does **not allow** any operators, using any user-defined named types, any other standard type (e.g. strings, dictionaries, sets), using closures with captures, or referencing any variables by name. See below for examples of valid and invalid constant expressions:

```swift
@section("...") let a = 42 // ✅
@section("...") let b = 3.14 // ✅
@section("...") let c = 1 + 1 // ❌ operators not allowed
@section("...") let d = Int.max // ❌ not a literal
@section("...") let e: UInt8 = 42 // ✅
@section("...") let f = UInt8(42) // ❌ not a literal
@section("...") let g: MyCustomExpressibleByIntegerLiteral = 42 // ❌ not a standard type

@section("...") let composition1 = (1, 2, 3, 2.718, true) // ✅
@section("...") let composition2 = (1, 2, Int.max) // ❌ tuple component not constant
@section("...") let composition3: InlineArray = [1, 2, 3] // ✅
@section("...") let composition4: InlineArray = [1, 2, Int.max] // ❌ array component not constant
@section("...") let composition5: (Int, [1 of Int], [1 of (Int, Int)]) = (1, [1], [(1, 1)]) // ✅

func foo() -> Int { return 42 }
@section("...") let func1 = foo // ✅
@section("...") let func2 = foo() // ❌ not a function reference
@section("...") let func3 = Bool.random // ✅
@section("...") let func4 = Bool.self.random // ❌ not a direct reference
@section("...") let func5 = (Bool.self as Bool.Type).random // ❌ not a direct reference
@section("...") let func6 = [Int].randomElement // ❌ generic
@section("...") let func7 = { } // ✅
@section("...") let func8 = { (x: Int) in print(x) } // ✅
struct Generic<T> {
  @section("...") static let func9 = { print("1") } // ❌ generic context
}
struct NonGeneric {
  static var member: Int = 42
  @section("...") static let func10 = { print(member) } // ❌ capture
}

struct S { }
@section("...") let metatype1 = S.self // ✅
@section("...") let metatype2 = Int.self // ✅
@section("...") let metatype3 = Int.self.self // ❌ not a direct reference
import Foundation
@section("...") let metatype4 = URL.self // ❌ resilient
```

### Guaranteed static initialization

Using attribute `@section` requires the initializer expression of the variable to be a **constant expression**. It's not required to separately annotate the expression for being a compile-time expression, instead this is implied from the `@section` attribute. On top of the constant-ness, `@section` on a global or static variable enforces **static initialization** on that variable.

We consider the variable to be eligible for static initialization when:

1. the initializer expression represents a valid compile-time constant, and
2. the initializer expression can be constant-folded into a representation that does not require any runtime initialization (pointer relocations/fixups done automatically by the loader are not considered runtime initialization for this purpose).

Not all constant expressions are necessarily statically initializable. For section placement we require the stronger property (static initialization) because we expect the data to be readable without any runtime mechanisms (i.e. reading raw bytes from the section at runtime, or offline binary inspection).

```swift
@section("__DATA,mysection")
let a = 42 // ✅

@section("__DATA,mysection")
let sectionPlaced = ...expression... // ✅, guaranteed to be statically initialized

@section("__DATA,mysection")
let notStaticallyInitializable = ...expression that cannot be statically initialized... // ❌
```

> *Note: As of this writing, all valid constant values are also eligible to be statically initialized, but we don’t expect that to hold in the future. So it’s important to distinguish between (a) a global variable being initialized with a language-level constant value, and (b) a global variable that is guaranteed to be statically initialized. The difference can be subtle, and in some cases immaterial in practice, but future enhancements of constant values in Swift might take advantage of this difference — i.e. not all constant values are going to be statically initializable. Consider the following example: If a future language versions allows dictionary literals to be constant values, such values might not be statically initializable because of randomized hash seeding:*

> ```swift
> let d1 = ["a": 42, "b": 777] // constant, but not statically initializable
> let d2 = d1.count            // statically initializable
> ```

> *However, using a statically non-initializable value in an expression does not preclude the outer expression from being statically initialized either. In this example, `d1` would not be allowed to be placed into a custom section because it’s not statically initializable. But `d2` could still potentially be statically initializable (even though the definition of `d2` uses a sub-expression that is not statically initializable), as it’s simply an integer.*

As described in [Swift Compile-Time Values](https://github.com/artemcm/swift-evolution/blob/const-values/proposals/0nnn-const-values.md), values of function types are eligible for being compile-time evaluable. Their concrete pointer value is not fully known until link-time or program load-time (depending on type of linking, ASLR, PAC, etc.). For the purposes of guaranteed static initialization, function values are statically initialized into a function pointer. This pointer is still subject to normal linking and loading resolutions and fixups.

```swift
func foo() { ... }

@section("__DATA,mysection")
let a = (42, foo) // "foo" is statically initialized into a
                  // linkable/relocatable pointer
```

### Cross-platform object file format support

Different platforms supported by Swift are using different object and binary file formats (Linux uses ELF, Darwin uses Mach-O, Windows uses COFF), and that implies different restrictions and rules on what are valid section names. Because of that, a multi-platform library code is expected to use `#if os(...)` to use different section names for different platforms. Because of that, it’s expected that the attributes are to be typically only used indirectly via macros that hide the low-level nature of sections and object file formats from higher-level code developers:

```swift
// Example of a potential project-specific "@RegisterPlugin" macro:
@RegisterPlugin
let plugin = ...

// The macro expands to:
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
@section("__DATA_CONST,plugins")
#elseif os(Linux)
@section("plugins")
#elseif os(Windows)
@section(".plugins")
#endif
let plugin = ...
```

See [Structured section specifiers](#structured-section-specifiers) below for more rationale.

In some cases, it’s not possible to differentiate on the OS to support multiple object file formats, for example when using Embedded Swift to target baremetal systems without any OS. For that, a new `#if objectFormat(...)` conditional compilation directive will be provided. The allowed values in this directive will match the set of supported object file formats by the Swift compiler (and expand as needed in the future). Currently, they exact values will be (case sensitive):

* COFF
* ELF
* MachO
* Wasm

```swift
#if objectFormat(MachO)
@section("__DATA_CONST,mysection")
#elseif objectFormat(ELF)
@section("mysection")
#endif
let value = ...
```

### ELF section index

The goal of placing metadata into custom section is to make them discoverable both via offline inspection (e.g. objdump or otool) and at runtime. The facilities for that are dependent on the type of linking (static vs dynamic), and platform’s linker and loader:

* For **static linking**, the bounds of a section can be statically determined by the linker and on all supported platforms and their file formats (COFF, ELF, MachO, Wasm), the linker-provided “**encapsulation symbols**” can be used to retrieve those bounds.
    * In ELF and Wasm formats, these symbols are  `__start_<section>` /  `__stop_<section>`.
    * In Mach-O, these symbols are `section$start$<segname>$<secname>` / `section$end$<segname>$<secname>`.
    * In COFF, these symbols need to be manually constructed by using “grouped sections” (section name is suffixed with a $ + string) which are automatically lexicographically ordered by the linker. For example, by manually placing a start symbol into `.section$A` , end symbol into `.section$C` and all actual section entries into `.section$B`, the two helper symbols’s addresses effectively describe the bounds of the section.
* For **dynamic linking**, the above mentioned encapsulation symbols are available too, but they always only describe the bounds of the section in the current module. Retrieving section content process-wide means collecting metadata from multiple images at runtime, which requires further assistance or support from the loader.
    * In Mach-O (Darwin OS's), image headers are present in the address space, and they include section bounds information. The loader provides straightforward image iteration APIs (`_dyld_get_image_header`), as well as image load callbacks (`_dyld_register_func_for_add_image`), and an API to lookup section bounds by name from a particular image (getsectiondata). 
    * In COFF (Windows), image headers are present in the address space, and they include section bounds information. `Module32FirstW`/`Module32NextW` can be used to enumerate images, and structures such as `IMAGE_DOS_HEADER`, `IMAGE_NT_HEADERS`, `IMAGE_FILE_HEADER`, and `IMAGE_SECTION_HEADER` can be used to walk a module and find its section bounds.
    * In Wasm, dynamic linking is work in progress and not generally available yet.
    * In ELF, however, section bounds are not guaranteed to be present in the address space at runtime, and in practice they are typically not present. This creates a challenge for retrieving section data in this configuration (ELF + multiple modules with dynamic linking) at runtime.

To solve this problem for the ELF object file format, the Swift compiler is going to emit a “**section index**” into every compilation that uses any symbols placed into a custom section. The index will be emitted only when producing ELF files, and consists of entries added into its own separate well-named section called `swift5_sections`. Each entry will have the following structure:

```c
struct SectionIndexEntry {
  const char *name;
  const void *start; // effectively equal to __start_<name>
  const void *stop; // effectively equal to __stop_<name>
};
```

The section index will describe the bounds of all custom sections used in Swift code. When compiling into a single object file (e.g. in WMO mode without -num-threads), there will be only a single entry per distinct section name, but in compilation modes that produce multiple object files for a single module, there may be multiple entries for the same section. The entries are going to be “linkonce_odr”, i.e. duplicate entries will be collapsed at link time, so in a linked module, only one entry per section will remain.

This way, runtime code present in the same module, for example SwiftRT-ELF helper code (swiftrt.o) which is currently being silently linked in to all modules, can walk over the section index using the encapsulation symbols, and register the section bounds in a globally maintained data structure in the Swift runtime. Implementation of that and exposing such a facility in an actual API from the Swift runtime is left as a future direction.

## Source compatibility

This proposal is purely additive (adding new attributes), without impact on source compatibility.

## Effect on ABI stability

This change does not impact ABI stability for existing code.

Adding, removing, or changing the `@section` attribute on variables should generally be viewed as an ABI breaking change, section placement can affect linking behavior of that symbol. In some cases, it is possible to make careful non-ABI-breaking changes via the `@section` attribute.

Adding `@used` does not affect ABI stability. Removing `@used` can be viewed as an ABI breaking change, however not in the traditional sense: The effect of `@used` only exists on symbols that would normally not be exported (e.g. private symbols), which shouldn’t be part of a ABI in the first place. However, dynamic lookups of such symbols are still possible, and if the behavior of those is considered ABI, then removing `@used` can be ABI breaking.

## Effect on API resilience

This change does not impact API resilience for existing code.

Adding, removing, or changing the `@section` attribute on variables does not affect API resilience.

Adding or removing `@used` does not affect API resilience.

## Future Directions

### Section placement for functions

This proposal only allows data placement into custom sections, however, placing code into custom sections is a relatively useful and common approach in systems and embedded programming. In the future, the `@section` and `@used` attributes could be extended to apply to function declarations, and possibly other language constructs that generate executable code (e.g. closures). A prominent use case is firmware entry points and booting schemes, which often require startup code to be in a predefined section:

```swift
// code for the function is placed into the custom section
@section("__TEXT,boot")
func firmwareBootEntrypoint() { ... }
```

This will require some design decisions to be made around when should that be allowed, whether the attribute should be automatically inherited, and what exact behavior should we expect from the compiler around thunks, compiler-generated helper functions, getters and setters, etc.

### Standalone attribute for required static initialization

Static initialization of a global can be useful on its own, without placing data into a custom section, and a separate attribute for that could be added. This way, one can get the same effects as the `@section` attribute (static initialization, normal initalization behavior if top-level code) except the symbol would not be actually placed into any custom section.

### Generalized constant values and expressions

The notions of constant expressions and constant values is applicable to a much wider set of use cases that just section placement, and the set of allowed types and syntactical forms should be expanded in the future into a full-featured system for compile-time programming. A dedicated proposal, [Swift Compile-Time Values](https://github.com/artemcm/swift-evolution/blob/const-values/proposals/0nnn-const-values.md), is being pitched [on the forums](https://forums.swift.org/t/pitch-3-swift-compile-time-values/77434) and describes in detail the possible future of generalized constants, the relevant motivation and use cases.

### Allowing a reference to a constant string declaration as a section name

The requirement to only use string literals as the section names could be lifted in the future, and we might allow referring to a declaration of variable with a compile-time string. This would be useful to avoid repetition when placing multiple values into the same section without needing to use macros.

```swift
#if objectFormat(ELF)
let mySectionName = "mysection" // required to be a compile-time value
#elseif objectFormat(MachO)
let mySectionName = "__DATA,mysection" // required to be a compile-time value
#endif

@section(mySectionName)
var global = ...
```

### Runtime discovery of data in custom sections

As described in [ELF section index](#elf-section-index), accessing records in a custom section at runtime is heavily dependent on the object file format (ELF, Mach-O, Wasm, COFF), type of linking (static vs dynamic) and available APIs from the operating system. For a single configuration, users can directly use an appropriate method of accessing the section data, and e.g. in embedded firmwares this might be completely fine as projects are commonly avoiding any attempts to be multi-platform or portable.

However, for multi-platform libraries and general purpose packages, supporting the full matrix of combinations would be very impractical. Because of that, it’s expected that a unified API for accessing the bounds and contents of a section (across multiple modules in presence of dynamic linking) is provided either as part of the Swift runtime, the standard library, or as a portable package. This API would likely still be a relatively low-level API, providing access to the raw bytes of sections across multiple loaded modules, but it would provide an shared abstraction across platforms, file formats, and linking types.

### Linker sets, plugins as high-level APIs

This proposal only builds the compile-time half of a user-facing “linker set” mechanism (placing structured data into sections). To access and enumerate the data at runtime, one can imagine a direct, still relatively low-level API like this:

```swift
func enumerateLinkerSet<T>(fromSectionNamed: String) -> Sequence<T> {
  // extract section data, assuming the raw data in the section are records of "T"
  // probably built on top of a cross-platform section access API mentioned in previous section
}
```

But a solution based on macros could achieve a higher-level abstraction for the entire “linker set” mechanism:

```swift
@DefineLinkerSet("name", type: Int) // other macros understand that linker set "name" 
                                    // has entries of type Int
                                    
@LinkerSetEntry("name") let entry1: Int = 42 // ok
@LinkerSetEntry("name") let entry2: Float = 7.7 // error

for entry in #enumerateLinkerSet("name") {
  print(entry)
}
```

Similarly, a plugin registration and discovery mechanism based on macros could provide full type safety and hide the low-level aspects completely:

```swift
// In PluginModule:
@PluginRecord(protocol: PluginProtocol, type: MyPluginType)
let plugin = PluginData(name: "myPlugin", version: 1, initialization: { ... })

// In MainModule:
... load available plugins via dlopen ...
for plugin in Plugin.enumerateLoadedPlugins(for: PluginProtocol.self) {
  print(plugin.name)
  let t = plugin.instantiateType()
  ...
}
```

### Access to a stable address

Generally, Swift values and variables do not have a stable address, and converting an inout reference to a UnsafePointer does not guarantee a stable address even on a global variable. However, statically initialized globals/static (either via the `@section` attribute, or via `@constInitialized`) do fundamentally have a stable address because they have an exact location in the binary on disk and in the module’s image at runtime. It’d be useful to provide direct access to that, in a way that adds the missing stable-address guarantees compared to inout-to-pointer conversions, and also allow fetching an address of a `let` variable (inout references only work on `var`):

```swift
@constInitialized let x = 42

let address: UnsafePointer<Int> = #address(x) // would only work on statically initialized
                                              // globals/statics
```

## Alternatives Considered

### Requiring explicitly spelled out `@const` when using `@section`

`@section` annotated globals/statics require their initializer expressions to be constant expressions, but the expression does not have to be marked as `@const` manually, it’s implied instead. An alternative of requiring the `@const` was considered:

```swift
@section(...) let global: Int = @const 42
```

Because `@const` does not affect parsing or type resolution of the expression, it’s not helpful to the compiler, and it doesn’t seem to improve readability for users either: If the expression is a constant expression or not statically initializable, it will be rejected from compilation with a clear explanation. Adding a `@const` does not convey any new information.

### Structured section specifiers

In Mach-O, custom section names are written as a pair of segment (e.g. `__DATA`) + section (e.g. `mysection`). Structured section names with separate segment and section names, `@section(segment: "...", section: "...")` were considered instead, however this pattern does not generalize across object file formats, and is Mach-O specific (ELF and PE/COFF don’t have segments).

Because different object file formats impose different restrictions on custom section names (length, “.” prefix), a shorthand syntax to specify different section names for different object file formats was considered: `@section(ELF: “...”, MachO: “...”, COFF: “...”)`.  This, however, has drawbacks of repeating the file format in cases where the code is only ever targeting a single format (common for example for embedded firmwares on ELF). The benefits of a shorthand syntax is marginal, given that we don’t expect normal application code to use the `@section` attribute directly but instead rely on macros or other higher-level API.

The alternative of using conditional compilation is what is expected to be used for those cases instead.

### Umbrella attribute for linkage properties

Instead of separate `@section` and `@used` attributes, a unified attribute with parameters to control individual linkage properties was considered, spelled for example `@linkage(section: ..., used)`. Further linkage control features would be added into this umbrella attribute.

This, however, adds challenges on composability — one umbrella attribute would need to allow multiple occurrences and the design would need rules for merging of individual properties from multiple attributes. Separate standalone attributes compose trivially, and also they play nicely with the existing `#if hasAttribute(...)` conditional compilation mechanism. There is currently no mechanism for conditional compilation based on whether a sub-feature of a umbrella attribute is available in the compiler.

Given the above, and also given that controlling symbol and linker level properties is not something that we expect normal application code to do directly, it’s more appropriate to keep the attribute system simple, and have individual orthogonal composable attributes.

### `@section` implying `@used`

In a lot of the list code snippets in this proposal, both `@section` and `@used` were used together, and so it may seem that it’s not necessary for those to be two separate attributes. However:

* `@section` and `@used` represent separate concepts and all combinations of them can be useful. An example of using `@section` without `@used` is to place for example a large data table from a library into its own section for binary size accounting reasons (so that it shows up separately in per-section binary size listings), but where we’d still expect the data table to be dead-code removed if not used.
* It’s already common to have those attributes as separate options in existing popular systems programming languages (C, C++, Rust).

### Blocking section placement into compiler reserved sections

In most cases, placing data into one of Swift’s runtime reserved sections (e.g. `__swift5_types`, etc.) without relying on extreme details of the compiler and runtime would result in invalid binaries. It was considered to simply reject using `@section` to target one of these reserved sections, but ultimately that would introduce both false positives (*what if we at some point wanted to write compiler/runtime code in Swift to actually legitimately place data into these sections?*) and false negatives (*there are many other "reserved" sections that the Swift compiler and language cannot know about*), and is thus left out of this proposal.
