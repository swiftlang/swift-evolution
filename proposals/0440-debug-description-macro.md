# DebugDescription Macro

* Proposal: [SE-0440](0440-debug-description-macro.md)
* Authors: [Dave Lee](https://github.com/kastiglione)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Implemented (Swift 6.0)**
* Implementation: Present in `main` under experimental feature `DebugDescriptionMacro` [apple/swift#69626](https://github.com/apple/swift/pull/69626)
* Previous Revision: [1](https://github.com/swiftlang/swift-evolution/blob/fda6746506368c8c6d2933ee6d71c87e6ed92f94/proposals/0440-debug-description-macro.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-debug-description-macro/67711)) ([review](https://forums.swift.org/t/se-0440-debugdescription-macro/72958)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0440-debugdescription-macro/73270)) ([second review](https://forums.swift.org/t/second-review-se-0440-debugdescription-macro/73325))([acceptance](https://forums.swift.org/t/accepted-se-0440-debugdescription-macro/73741))

## Introduction

This proposal introduces `@DebugDescription`, a new debugging macro to the standard library, which lets data types specify a custom summary to be presented by the debugger. This macro brings improvements to the debugging experience, and simplifies the maintenance and delivery of debugger type summaries. It can be used in place of `CustomDebugStringConvertible` conformance, or in addition to, for custom use cases.

## Motivation

Displaying data is a fundamental part of software development. Both the standard library and the debugger offer multiple ways of printing values - Swift's print and dump, and LLDB's `p` and `po` commands. These all share the ability to render an arbitrary value into human readable text. Out of the box, both the standard library and the debugger present data as a nested tree of property-value pairs. The similarities run deep, for example the standard library and the debugger provide control over how much of the tree is shown. This functionality requires no action from the developer.

The utility of displaying a complete value depends on the size and complexity of the data type(s), or depends on the context the data is being presented. Displaying the entirety of a small/shallow structure is sufficient, but some data types reach sizes/complexities where the complete tree of data is too large to be useful.

For types that are too large or complex, the standard library and debugger again both provide tools giving us control over how our data is displayed. In the standard library, Swift has the `CustomDebugStringConvertible` protocol, which allows types to represented not as the aforementioned property tree, but as an arbitrary string. Relatedly, Swift has `CustomReflectable`, which lets developers control the contents and structure of the rendered property tree. For brevity and convention, from this point on this document will refer to the `CustomDebugStringConvertible` and `CustomReflectable` protocols via their single properties: `debugDescription` and `customMirror` respectively.

LLDB has analogous features, which are called Type Summaries (\~`debugDescription`) and Synthetic Children (\\~`customMirror`) respectively. However, Swift and the debugger don't share or interoperate these definitions. Implementing these customizing protocols provides limited benefit inside the debugger. Likewise, defining Type Summaries or Synthetic Children in LLDB will have no benefit to Swift.

While LLDB’s `po` command provides a convenient way to evaluate a `debugDescription` property defined in Swift, there are downsides to expression evaluation: Running arbitrary code can have side effects, be unstable to the application, and is slower. Expression evaluation happens by JIT compiling code, pushing it to the device the application is running on, and executing it in the context of the application, which involves a lot of work. As such, LLDB only does expression evaluation when explicitly requested by a user, most commonly with the `po` command in the console. Debugger UIs (IDEs) often provide a variable view which is populated using LLDB’s variable inspection which does not perform expression evaluation and is built on top of reflection. In some cases, such as when viewing crashlogs, or working with a core file, expression evaluation is not even possible. For these reasons, rendering values is ideally done without expression evaluation.

This proposal introduces the ability to share a `debugDescription` definition between Swift and the debugger. This has benefits for developers, and for the debugger.

LLDB Type Summaries can be defined using LLDB’s own (non Turing-complete) string interpolation syntax, called [Summary Strings](https://lldb.llvm.org/use/variable.html#summary-strings). While similar to Swift string interpolation, LLDB Summary Strings have restrictions that Swift string interpolation does not have. The primary restriction is that it allows data/property access, but not computation. LLDB Summary Strings cannot evaluate function calls, which includes computed properties. For the purpose of definition sharing, LLDB Type Summaries can be viewed as a lower common denominator of the two. As a result, definition sharing can be achieved only when a `debugDescription` definition meets the criteria imposed by LLDB Summary Strings. The criteria is not overly limiting, LLDB Summary Strings have been in for some time.

Swift macros provide a convenient means to implement automatic translation of compatible `debugDescription` definitions into LLDB Summary Strings. A macro provides benefits that LLDB Summary Strings do not currently offer, including the ability to do compile time static validation to produce typo-free LLDB Summary Strings. The previously mentioned criteria that `debugDescription` must meet in order to be converted to an LLDB Summary String will loosen over time. This will be achieved first through the macro implementation becoming more sophisticated, and second as LLDB’s Summary Strings gain advancements.

## Proposed solution

Consider this simple example data type:

```swift
struct Organization: CustomDebugStringConvertible {
    var id: String
    var name: String
    var manager: Person
    var members: [Person]
    // ... and more

    var debugDescription: String {
        "#\(id) \(name) (\(manager.name))"
    }
}
```

To see the results of `debugDescription` in the debugger, the user has to run `po team` in the console.

```
(lldb) po team
"#15 Shipping (Francis Carlson)
```

Running the `p` command, or viewing the value in the Debugger UI (IDE), will show the value’s property tree, which may have arbitrary size/nesting:

```
(lldb) p team
(Organization) {
  id = "..."
  name = "Shipping"
  manager = {
    name = "Francis Carlson"
    ...
  }
  members = {
    [0] = ...
  }
  ...
}
```

However, by introducing the `@DebugDescription` macro, we can teach the debugger how to generate a summary without expression evaluation.

```swift
@DebugDescription
struct Organization: CustomDebugStringConvertible {
    var id: String
    var name: String
    var manager: Person
    var members: [Person]
    var officeAddress: [Address]
    // ... and more

    var debugDescription: String {
        "#\(id) \(name) (\(manager.name))"
    }
}
```

The macro expands the body of `debugDescription` into the following LLDB Summary String:

```
#${var.id} ${var.name} (${var.manage.name})
```

This summary string is emitted into the binary, where LLDB will load it automatically. Using this definition, LLDB can now present this description in contexts it previously could not, including the variable view and other parts of the debugger UI.

A notable difference between the debugger console and debugger UI is that that UI displays one level at a time. When viewing an Array for example, its children are not expanded. To distinguish between elements of an Array (or any other collection), a user must expand each child. By employing `@DebugDescription`, LLDB will show a summary for each element of a collection, so that users may know – at a glance – exactly which element(s) to expand.

## Detailed design

```swift
/// Converts description definitions to a debugger Type Summary.
///
/// This macro converts compatible description implementations written in Swift
/// to an LLDB format known as a Type Summary. A Type Summary is LLDB's
/// equivalent to debugDescription, with the distinction that it does not
/// execute code inside the debugged process. By avoiding code execution,
/// descriptions can be produced faster, without potential side effects, and
/// shown in situations where code execution is not performed, such as the
/// variable list of an IDE.
///
/// Consider this an example. This Team struct has a debugDescription which
/// summarizes some key details, such as the team's name. The debugger only
/// computes this string on demand - typically via the po command. By applying
/// the DebugDescription macro, a matching Type Summary is constructed. This
/// allows the user to show a string like "Rams [11-2]", without executing
/// debugDescription. This improves the usability, performance, and
/// reliability of the debugging experience.
///
///     @DebugDescription
///     struct Team: CustomDebugStringConvertible {
///        var name: String
///        var wins, losses: Int
///
///        var debugDescription: String {
///            "\(name) [\(wins)-\(losses)]"
///        }
///     }
///
/// The DebugDescription macro supports both debugDescription, description,
/// as well as a third option: a property named lldbDescription. The first
/// two are implemented when conforming to the CustomDebugStringConvertible
/// and CustomStringConvertible protocols. The additional lldbDescription
/// property is useful when both debugDescription and description are
/// implemented, but don't meet the requirements of the DebugDescription
/// macro. If lldbDescription is implemented, DebugDescription choose it
/// over debugDescription and description. Likewise, debugDescription is
/// preferred over description.
///
/// ### Description Requirements
///
/// The description implementation has the following requirements:
///
/// * The body of the description implementation must a single string
///   expression. String concatenation is not supported, use string interpolation
///   instead.
/// * String interpolation can reference stored properties only, functions calls
///   and other arbitrary computation are not supported. Of note, conditional
///   logic and computed properties are not supported.
/// * Overloaded string interpolation cannot be used.
@attached(member)
@attached(memberAttribute)
public macro DebugDescription() =
  #externalMacro(module: "SwiftMacros", type: "DebugDescriptionMacro")

/// Internal-only macro. See @DebugDescription.
@attached(peer, names: named(_lldb_summary))
public macro _DebugDescriptionProperty( debugIdentifier: String, _ computedProperties: [String]) =
  #externalMacro(module: "SwiftMacros", type: "_DebugDescriptionPropertyMacro")
```

Of note, the work is split between two macros `@DebugDescription` and `@_DebugDescriptionProperty`. By design, `@DebugDescription` is attached to the type, where it gathers type-level information, including gather a list of stored properties. This macro also determines which description property to attach @_DebugDescriptionProperty to.

`@_DebugDescriptionProperty` is not intended for direct use by users. This macro is scoped to the inspect a single description property, not the entire type. This approach of splitting the work allows the compiler to avoid unnecessary work.

The additional supported property, `lldbDescription`, is to support two different use cases.

First, in some cases existing `debugDescription`/`description` cannot be changed, because doing so would be a breaking change to either `String(reflecting:)` or `String(describing:)`. In these circumstances, developers can define `lldbDescription` instead.

Second, in some cases developer may want to use LLDB Summary String syntax directly. Since `lldbDescription` is not coupled to API, developers are free to include Summary String elements in their `lldbDescription`. This is expected to be uncommon, but lets developers have more control over Summary Strings. Since LLDB syntax has no meaning inside `debugDescription`/`description`, the macro performs escaping when translating those definitions.

Using both `debugDescription` and `lldbDescription` is an intended use case. The design of this macro allows developers to have both an LLDB compatible  `lldbDescription`, and a more complex `debugDescription`. This allows the debugger to show a simple summary, while providing enabling a more detailed or dynamic `debugDescription`.

## Source compatibility

This proposal adds a new macro to the standard library. There are no source compatibility concerns.

## ABI compatibility

The macro implementation emits metadata for the debugger, and does not affect ABI.

## Implications on adoption

The macro can be freely adopted and un-adopted in source code with no deployment constraints and without affecting source or ABI compatibility.

## Future directions

### Support for Generics

The `@DebugDescription` macro cannot currently be attached to generic type definitions. This is because the macro's implementation emits a static property into the type, which is a use case not currently supported by the Swift language. To support generic types, Swift will need a separate proposal to enable code such as the following:

```swift
struct Generic<T> {
    static let _lldb_summary = (23 as UInt8, 30 as UInt8, ...)
}
```

The goal is to allow static properties in generic types, specifically when the property's type is concrete and independent of the generic signature. In the above code, the property's type is a tuple of `UInt8`, which does not depend on `T`.

### Beyond Summary Strings

Future directions include generating Python instead of LLDB Summary Strings. This has the benefit of having fewer restrictions on the `debugDescription` definition. It has the downside of needing security scrutiny not required by LLDB Summary Strings.

A similar future direction is to support sharing Swift `customMirror` definitions into LLDB Synthetic Children definitions. Unlike LLDB Type Summaries, LLDB has no "DSL" to expression LLDB Synthetic Children, currently the main option is Python. Given that there are two uses solved by generating Python, it's an approach worth considering in the future. While `customMirror` implementations are less common in Swift than their `debugDescription` counterpart, in LLDB, Synthetic Children are as important, or even more important than Summary Strings. The reason is that Synthetic Children allow data types to express their data "interface" rather than their implementation. Consider types like Array and Dictionary, which often have implementation complexity that provides optimal performance, not for data simplicity.

## Alternatives considered

### Explicit LLDB Summary Strings

The simplest macro implementation is one that performs no Swift-to-LLDB translation and directly accepts an LLDB Summary String. This approach requires users to know LLDB Summary String syntax, which while not complex, still presents a hindrance to adoption. Such a macro would could create redundancy: `debugDescription` and the separate LLDB Summary String. These would need to be manually kept in sync.

### Independent Property (No `debugDescription` Reuse)

Instead of leveraging existing `debugDescription`/`description` implementations, the `@DebugDescription` macro could use a completely separate property.

Reusing existing `debugDescription` implementations makes a tradeoff that may not be obvious to developers. The benefit is a single definition, and getting more out of a well known idiom. The risk comes from the requirements imposed by `@DebugDescription`. The requirements could lead to developers changing their existing implementation. Any changes to `debugDescription` will impact `String(reflecting:)`, and similarly changes to `description` will impact `String(describing:)`.

The risk involving String conversion would be avoided by having the macro use an independent property. The macro would not support `debugDescription`/`description`. In this scenario, developers would be required to implement `lldbDescription`, even if the implementation is identical to the existing `debugDescription`.

Our expectation is that most code, particularly application code, will not depend on String conversion (especially `String(reflecting:)`). For code that does depend on String conversion, it should have testing in place to catch breaking changes. Inside of an application, authors of code which has behavior that depends on String conversion initializers should already be aware of the consequences of changing `debugDescription`/`description`. Frameworks are a more challenging situation, where its authors are not always aware of if/how its clients depend on String conversion.

The belief is that the benefits of reusing `debugDescription` will outweigh the downsides. Framework authors can make it a policy of their own to not reuse `debugDescription`, if they believe that presents a risk to clients of their framework.

### Contextual Diagnostics

To help address the potential risk around reuse of `debugDescription`, the macro could emit diagnostics that vary by the property being used. Specifically, if the developer implements `lldbDescription`, they will get the full diagnostics available, indicating how to fix its implementation. Conversely, when `debugDescription` is being reused, the diagnostics will not contain details of which requirements were not met, instead the diagnostics would tell the user that `debugDescription` is not compatible, and to define `lldbDescription` instead. This should make it less likely that the macro leads to changes affecting String conversion.

## Revision history

* Changes from the first review
  * Document support for generic types as a future direction
  * Rename `_debugDescription` to `lldbDescription`
  * Direct use of LLDB Summary String syntax is supported only by `lldbDescription`

## Acknowledgments

Thank you to Doug Gregor and Alex Hoppen for their generous guidance, and PR reviews. Adrian Prantl, for the many productive discussions and implementation ideas. To Kuba Mracek, for implementing linkage macros which support this work. Thank you to Tony Parker and Steve Canon for their adoption feedback. To Holly Borla, for timely technical and process support.
