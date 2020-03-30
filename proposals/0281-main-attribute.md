# `@main`: Type-Based Program Entry Points

* Proposal: [SE-0281](0281-main-attribute.md)
* Authors: [Nate Cook](https://github.com/natecook1000), [Nate Chandler](https://github.com/nate-chandler), [Matt Ricketson](https://github.com/ricketson)
* Review Manager: [Tom Doron](https://github.com/tomerd)
* Status: **Active Review** (March 30 - April 8)
* Implementation: [apple/swift#30693](https://github.com/apple/swift/pull/30693)

## Introduction

A Swift language feature for designating a type as the entry point for beginning program execution. Instead of writing top-level code, users can use the `@main` attribute on a single type. Libraries and frameworks can then provide custom entry-point behavior through protocols or class inheritance.

Related forum threads:

- [Initial pitch](https://forums.swift.org/t/main-type-based-program-execution/34624)
- [Control of Swift Entry Point](https://forums.swift.org/t/control-of-swift-entry-point/25069)

## Motivation

Swift programs start execution at the beginning of a file. This works great for procedural code, and allows simple Swift programs to be as short as a single line, with no special syntax required.

```swift
// A self-contained Swift program:
print("Hello, world!")
```

However, not all kinds of programs naturally fit into this model. For example, a user-facing app launches and runs until it is quit. User interface frameworks like UIKit and AppKit take care of the complexities of launching an application, providing high-level API hooks for defining app behavior. A developer using these frameworks typically does not care about nor interact with the literal starting point of their app’s execution.

In order to resolve these two models, apps need a small amount of “boot-loading” code to kick off the framework’s preferred execution entry point. Ever since its initial release, Swift has provided the domain-specific attributes `@UIApplicationMain` and `@NSApplicationMain` to smooth over this startup process for developers of UIKit and AppKit applications.

Instead of these hard-coded, framework-specific attributes, it would be ideal for Swift to offer a more general purpose and lightweight mechanism for delegating a program’s entry point to a designated type. A type-based approach to program execution fits within Swift's general pattern of solving problems through the type system and allows frameworks to use standard language features to provide clean, simple entry point APIs.

## Proposed solution

The Swift compiler will recognize a type annotated with the `@main` attribute as providing the entry point for a program. Types marked with `@main` have a single implicit requirement: declaring a static `main()` method. This `main()` method will typically be provided by libraries or frameworks, so that the author of a Swift program will only need to use the `@main` attribute to indicate the correct starting point.

When the program starts, the static `main()` method is called on the type marked with `@main`. For example, this code:

```swift
// In a framework:
public protocol ApplicationRoot {
    // ...
}
extension ApplicationRoot {
    public static func main() {
        // ...
    }
}

// In MyProgram.swift:
@main 
struct MyProgram: ApplicationRoot {
    // ...
}
```

is equivalent to this code:

```swift
// In a framework:
public protocol ApplicationRoot {
    // ...
}
extension ApplicationRoot {
    public static func main() {
        // ...
    }
}

// In MyProgram.swift:
struct MyProgram: ApplicationRoot {
    // ...
}

// In 'main.swift':
MyProgram.main()
```

Since `main()` is a regular static method, it can be supplied by a protocol as an extension method or by a base class. This allows frameworks to easily define custom entry point behavior without additional language features.

For example, the `ArgumentParser` library offers a `ParsableCommand` protocol that provides a default implementation for `main():`

```swift
// In ArgumentParser:
public protocol ParsableCommand {
    // Other requirements
}

extension ParsableCommand {
    static func main() {
        // Parses the command-line arguments and then
        // creates and runs the selected command.
    }
}
```

The `@main` attribute would allow clients to focus on just the requirements of their command-line tool, rather than how to launch its execution:

```swift
@main 
struct Math: ParsableCommand {
    @Argument(help: "A group of integers to operate on.")
    var values: [Int]

    func run() throws {
        let result = values.reduce(0, +)
        print(result)
    }
}
```

Likewise, UIKit and AppKit could add the static `main()` method to the `UIApplicationDelegate` and `NSApplicationDelegate` protocols, allowing authors to use the single `@main` attribute no matter the user interface framework, and allowing for the deprecation of the special-purpose attributes. (Note: These changes are not a part of this proposal.)

## Detailed design

The compiler will ensure that the author of a program only specifies one entry point: either a single, non-generic type designated with the `@main` attribute *or* a single `main.swift` file. The type designated as the entry point with `@main` can be defined in any of a module's source files. `@UIApplicationMain` and `@NSApplicationMain` will be counted the same way as the `@main` attribute when guaranteeing the uniqueness of a program's entry point.

A `main.swift` file is always considered to be an entry point, even if it has no top-level code. Because of this, placing the `@main`-designated type in a `main.swift` file is an error.

`@main` can be applied to either a type declaration or to an extension of an existing type. The `@main`-designated type can be declared in the application target or in an imported module. `@main` can be applied to the base type of a class hierarchy, but is not inherited — only the specific annotated type is treated as the entry point.

The rules for satisfying the `static func main()` requirement are the same as for satisfying a protocol with the same requirement. The method can be provided by the type itself, inherited from a superclass, or declared in an extension to a protocol the type conforms to.

## Other considerations

### Source compatibility

This is a purely additive change and has no source compatibility impacts.

### Effect on ABI stability and API resilience

The new attribute is only applicable to application code, so there is no effect on ABI stability or API resilience.

### Effect on SwiftPM packages

The `@main` attribute will currently not be usable by Swift packages, since SwiftPM recognizes executable targets by looking for a `main.swift` file.

## Alternatives

### Use a special protocol instead of an attribute

The standard library includes several protocols that the compiler imbues with special functionality, such as expressing instances of a type using literals and enabling `for`-`in` iteration for sequences. It would similarly be possible to define a `protocol Main` instead of creating a `@main` attribute, with the same requirements and special treatment. However, such a protocol wouldn’t enable any useful generalizations or algorithms, and the uniqueness requirement is totally non-standard for protocol conformance. These factors, plus the precedent of `@UIApplicationMain` and `@NSApplicationMain`, make the attribute a more appropriate way to designate a type as an entry point.

### Allow `@main` to be applied to protocols

One or more protocols could be attributed with `@main` to make any type that conforms an automatic entry point, with the compiler ensuring that only one such type exists in an application. As noted above, however, this uniqueness requirement is non-standard for protocols. In addition, this would make the entry point less explicit from the perspective of the program's author and maintainers, since the entry-point conforming type would look the same as any other. Likewise, this would prevent using _manual_ execution if a programmer still wanted to have custom logic in a `main.swift` file.

### Use a `@propertyWrapper`-style type instead of an attribute

Instead of a dedicated `@main` attribute, the compiler could let libraries declare a type that could act as an attribute used to denote a program's entry point. This approach is largely isomorphic to the proposed `@main` attribute, but loses the consistency of having a single way to spell the entry point, no matter which library you're using.

### Use an instance instead of static method

Instead of requiring a static `main()` method, the compiler could instead require `main()` as an instance method and a default initializer. This, however, would increase the implicit requirements of the `@main` attribute and split the entry point into two separate calls. 

In addition, a default initializer may not make sense for every type. For example, a web framework could offer a `main()` method that loads a configuration file and instantiates the type designated with `@main` using data from that configuration.

### Use a different name for `main()`

Some types may already define a static `main()` method with a different purpose than being a program’s entry point. A different, more specific name could avoid some of these potential collisions.

However, adding `@main` isn’t source- or ABI-breaking for those types, as authors would already need to update their code with the new attribute and recompile to see any changed behavior. In addition, the `main` name matches the existing behavior of `main.swift`, as well as the name of the entry point in several other languages—C, Java, Rust, Kotlin, etc. all use functions or static methods named `main` as entry points.

### Use `(Int, [String]) -> Int` or another signature for `main()`

C programs define a function with the signature `int main(int argc, char *argv[])` as their entry point, with access to any arguments and returning a code indicating the status of the program. Swift programs have access to arguments through the `CommandLine` type, and can use `exit` to provide a status code, so the more complicated signature isn't strictly necessary.

To eliminate any overhead in accessing arguments via `CommandLine` and to provide a way to handle platform-specific entry points, a future proposal could expand the ways that types can satisfy the `@main` requirement. For example, a type could supply either `main()` or `main(Int, [String]) -> Int`.

Some platforms, such as Windows, base an executable's launch behavior on the specific entry point that the executable provides. A future direction could be to allow `@main` designated types to supply other specific entry points, such as `wWindowsMain(Int, UnsafeMutablePointer<UnsafeMutablePointer<WCHAR>>) -> Int`, and to allow additional arguments to be given with the `@main` attribute:

```swift
// In a framework:
extension ApplicationRoot {
    static func main(console: Bool = true, ...) { ... }
}

@main(console: false)
struct MyApp: Application {
     // ...
}
```

Alternatively, a future proposal could add an attribute that would let a library designate a different symbol name for the entry point:

```swift
// In a framework:
extension ApplicationRoot {
    @entryPoint(symbolName: "wWinMain", convention: stdcall)
    static func main(_ hInstance: HINSTANCE, _ hPrevInstance: HINSTANCE, lpCmdLine: LPWSTR, _ nCmdShow: Int32) { ... }
}
```

### Return `Never` instead of `Void`

A previous design of this feature required the static `main()` method to return `Never` instead of `Void`, since that more precisely matches the semantics of how the method is used when invoked by the compiler. That said, because you can’t provide any top-level code when specifying the `@main` attribute, the `Void`-returning version of the method effectively acts like a `() -> Never` function. 

In addition, returning `Void` allows for more flexibility when the `main()` method is called manually. For example, an author might want to leave out the `@main` attribute and use top-level code to perform configuration, diagnostics, or other behavior before or after calling the static `main()` method.
