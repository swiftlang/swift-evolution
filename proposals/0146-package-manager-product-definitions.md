# Package Manager Product Definitions

* Proposal: [SE-0146](0146-package-manager-product-definitions.md)
* Author: [Anders Bertelrud](https://github.com/abertelrud)
* Review manager: Daniel Dunbar
* Status: **Accepted**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-November/000298.html)
* Bug: [SR-3606](https://bugs.swift.org/browse/SR-3606)

## Introduction

This proposal introduces the concept of *products* to the Swift Package Manager, and proposes enhancements to the `Package.swift` syntax to let packages define products that can be referenced by other packages.

## Motivation

Currently, the Swift Package Manager has only a limited notion of the products that are built for a package.  It does have a set of rules by which it infers implicit products based on the contents of the targets in the package, and it also has a small amount of undocumented, unsupported package manifest syntax for explicitly declaring products, but it provides no supported way for package authors to declare what their packages produce.

Also, while the Swift Package Manager currently supports dependencies between packages, it has no support for declaring a dependency on anything more fine-grained than a package.

Such fine-grained dependencies are often desired, and this desire has in the past been expressed as a request for the ability to declare a dependency on an arbitrary target in a package.  That, in turn, leads to requests to provide access control for targets, since a package author may want control over which targets can be independently accessed from outside the package.

Even if visibility control for targets were to be provided (indeed, an early draft of the package manifest syntax had the notion of "publishing" a target to external clients), there would still be no way for the package author to declare anything about the kind of product that should be built.

One consequence of the lack of ability to define dependencies at subpackage granularity is that package authors have to break up packages into several smaller packages in order to achieve the layering they want.  Such package decomposition may be appropriate in some cases, but should be done based on what makes sense from a conceptual standpoint and not because the Swift Package Manager doesn't allow the author to express their intent.

For example, consider the package for a component that has both a library API and command line tools.  Such a package is also likely to be partitioned into a set of core libraries on which both the public library and the command line tools depend, but which should remain a private implementation detail as far as clients are concerned.

Such a package would currently need to be split up into three separate packages in order to provide the appropriate dependency granularity:  one for the public library, another for the command line tools, and a third, private package to provide the shared implementation used by the other two packages.  In the case of a single conceptual component that should have a single version number, this fracturing into multiple packages is directly contrary to the developer's preferred manner of packaging.

What is needed is a way to allow package authors to define conceptually distinct products of a package, and to allow client packages to declare dependencies on individual products in a package.

Furthermore, explicit product definitions would allow the package author to control the types of artifacts produced from the targets in the package.  This would include such things as whether a library is built as a static archive or a dynamic library.  We expect that additional product types will be added over time to let package authors build more kinds of artifacts.

## Proposed solution

We will introduce a documented and supported concept of a package product, along with package manifest improvements to let package authors define products and to let package clients define dependencies on such products.  In defining a product, a package author will be able specify the type of product as well as its characteristics.

### Product definitions

A package will be able to define an arbitrary number of products that are visible to all direct clients of the package.  A product definition consists of a product type, a name (which must be unique among the products in the package), and the root targets that comprise the implementation of the product.  There may also be additional properties depending on the type of product (for example, a library may be static or dynamic).

Any target may be included in multiple products, though not all kinds of targets are usable in every kind of product; for example, a test target is not able to be included in a library product.

The products represent the publicly vended package outputs on which client packages can depend.  Other artifacts might also be created as part of building the package, but what the products specifically define are the conceptual "outputs" of the package, i.e. those that make sense to think of as something a client package can depend on and use.  Examples of artifacts that are not necessarily products include built unit tests and helper tools that are used only during the build of the package.

An example of a package that defines two library products and one executable product:

```swift
let package = Package(
    name: "MyServer",
    targets: [
        Target(name: "Utils"),
        Target(name: "HTTP", dependencies: ["Utils"]),
        Target(name: "ClientAPI", dependencies: ["HTTP", "Utils"]),
        Target(name: "ServerAPI", dependencies: ["HTTP"]),
        Target(name: "ServerDaemon", dependencies: ["ServerAPI"]),
    ],
    products: [
        .Library(name: "ClientLib", type: .static, targets: ["ClientAPI"]),
        .Library(name: "ServerLib", type: .dynamic, targets: ["ServerAPI"]),
        .Executable(name: "myserver", targets: ["ServerDaemon"]),
    ]
)
```

The initial types of products that can be defined are executables and libraries.  Libraries can be declared as either static or dynamic, but when possible, the specific type of library should be left unspecified, letting the build system chooses a suitable default for the platform.

Note that tests are not considered to be products, and do not need to be explicitly defined.

A product definition lists the root targets to include in the product; for product types that vend interfaces (e.g. libraries), the root targets are those whose modules will be available to clients.  Any dependencies of those targets will also be included in the product, but won't be made visible to clients.  The Swift compiler does not currently provide this granularity of module visibility control, but the set of root targets still constitutes a declaration of intent that can be used by IDEs and other tools.  We also hope that the compiler will one day support this level of visibility control.  See [SR-3205](https://bugs.swift.org/browse/SR-3205) for more details.

For example, in the package definition shown above, the library product `ClientLib` would only vend the interface of the `ClientAPI` module to clients.  Since `ClientAPI` depends on `HTTP` and `Utilities`, those two targets would also be compiled and linked into `ClientLib`, but their interfaces should not be visible to clients of `ClientLib`.

### Implicit products

SwiftPM 3 applies a set of rules to infer products based on the targets in the package.  For backward compatibility, SwiftPM 4 will apply the same rules to packages that use the SwiftPM 3 PackageDescription API.  The `package describe` command will show implied product definitions.

When switching to the SwiftPM 4 PackageDescription API, the package author takes over responsibility for defining the products.  There will be tool support (probably in the form of a fix-it on a "package defines no products" warning) to make it easy for the author to add such definitions.  Also, the `package init` command will be extended to automatically add the appropriate product definitions to the manifest when it creates the package.

There was significant discussion about whether the implicit product rules should continue to be supported alongside the explicit product declarations.  The tradeoffs are described in the "Alternatives considered" section.

### Product dependencies

A target will be able to declare its use of the products that are defined in any of the external package dependencies.  This is in addition to the existing ability to declare dependencies on other targets in the same package.

To support this, the `dependencies` parameter of the `Target()` initializer will be extended to also allow product references.

To see how this works, remember that each string listed for the `dependencies` parameter is just shorthand for `.target(name: "...")`, i.e. a dependency on a target within the same package.
    
For example, the target definition:
    
```swift
Target(name: "Foo", dependencies: ["Bar", "Baz"])
```
    
is shorthand for:
    
```swift
Target(name: "Foo", dependencies: [.target(name: "Bar"), .target(name: "Baz")])
```

This will be extended to support product dependencies in addition to target dependencies:
    
```swift
let package = Package(
    name: "MyClientLib",
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire", majorVersion: 3),
    ],
    targets: [
        Target(name: "MyUtils"),
        Target(name: "MyClientLib", dependencies: [
            .target(name: "MyUtils"),
            .product(name: "Alamofire", package: "Alamofire")
        ])
    ]
)
```
    
The package name is the canonical name of the package, as defined in the manifest of the package that defines the product.  The product name is the name specified in the product definition of that same manifest.

The package name is optional, since the product name is almost always unambiguous (and is frequently the same as the package name).  The package name must be specified if there is more than one product with the same name in the package graph (this does not currently work from a technical perspective, since Swift module names must currently be unique within the package graph).

In order to continue supporting the convenience of being able to use plain strings as shorthand, and in light of the fact that most of the time the names of packages and products are unique enough to avoid confusion, we will extend the short-hand notation so that a string can refer to either a target or a product.

The Package Manager will first try to resolve the name to a target in the same package; if there isn't one, it will instead to resolve it to a product in one of the packages specified in the `dependencies` parameter of the `Package()` initializer.

For both the shorthand form and the complete form of product references, the only products that will be visible to the package are those in packages that are declared as direct dependencies -- the products of indirect dependencies  are not visible to the package.

## Detailed design

### Product definitions

We will add a `products` parameter to the `Package()` initializer:
    
```swift
Package(
    name: String,
    pkgConfig: String? = nil,
    providers: [SystemPackageProvider]? = nil,
    targets: [Target] = [],
    dependencies: [Package.Dependency] = [],
    products: [Product] = [],
    exclude: [String] = []
)
```
    
The definition of the `Product` type will be:
   
```swift
public enum Product {
    public class Executable {
        public init(name: String, targets: [String])
    }
    
    public class Library {
        public enum LibType {
            case .static
            case .dynamic
        }
        public init(name: String, type: LibType? = nil, targets: [String])
    }
}
```

The namespacing allows the names of the product types to be kept short.

As with targets, there is no semantic significance to the order of the products in the array.

### Implicit products

If the `products` array is omitted, and if the package uses version 3 of the PackageDescription API, the Swift Package Manager will infer a set of implicit products based on the targets in the package.

The rules for implicit products are the same as in SwiftPM 3:

1.  An executable product is implicitly defined for any target that produces an executable module (as defined here: https://github.com/apple/swift-package-manager/blob/master/Documentation/Reference.md).

2.  If there are any library targets, a single library product is implicitly defined for all the library targets.  The name of this product is based on the name of the package.

### Product dependencies

We will add a new enum case to the `TargetDependency` enum to represent dependencies on products, and another enum case to represent an unbound by-name dependency.  The string-literal conversion will create a by-name dependency instead of a target dependency, and there will be logic to bind the by-name dependencies to either target or product dependencies once the package graph has been resolved:

```swift
public final class Target {

    /// Represents a target's dependency on another entity.
    public enum TargetDependency {
        /// A dependency on a target in the same project.
        case Target(name: String)
        
        /// A dependency on a product from a package dependency.  The package name match the name of one of the packages named in a `.package()` directive.
        case Product(name: String, package: String?)
        
        /// A by-name dependency that resolves to either a target or a product, as above, after the package graph has been loaded.
        case ByName(name: String)
    }
    
    /// The name of the target.
    public let name: String
    
    /// Dependencies on other entities inside or outside the package.
    public var dependencies: [TargetDependency]
    
    /// Construct a target.
    public init(name: String, dependencies: [TargetDependency] = [])
}
```

For compatibility reasons, packages using the Swift 3 version of the PackageDescription API will have implicit dependencies on the directly specified packages.  Packages that have adopted the Swift 4 version need to declare their product dependencies explicitly.

## Impact on existing code

There will be no impact on existing packages that follow the documented Swift Package Manager 3.0 format of the package manifest.  Until the package is upgraded to the 4.0 format, the Swift Package Manager will continue to infer products based the existing rules.

## Alternatives considered

Many alternatives were considered during the development of this proposal, and in many cases the choice was between two distinct approaches, each with clear advantages and disadvantages.  This section summarizes the major alternate approaches.

### Not adding product definitions

Instead of product definitions, fine-grained dependencies could be introduced by allowing targets to be marked as public or private to the package.

_Advantage_

It would avoid the need to introduce new concepts.

_Disadvantage_

It would not provide any way for a package author to control the type and characteristics of the various artifacts.  Relying on the implied products that result from the inference rules is not likely to be scalable in the long term as we introduce new kinds of product types.

### Inferring implicit products

An obvious alternative to the proposal would be to keep the inference rules even in v4 of the PackageDescription API.

_Advantage_

It can be a lot more convenient to not have to declare products, and to be able to add new products just by adding or renaming files and directories.  This is particularly true for small, simple packages.

_Disadvantages_

The very fact that it is so easy to change the set of products without modifying the package manifest can lead to unexpected behavior due to seemingly unrelated changes (e.g. creating a file called `main.swift` in a module changes that module from a library to an executable).

Also, as packages become more complex and new conceptual parts on which clients can depend are introduced, the interaction of implicit rules with the explicit product definitions can become very complicated.

We plan to provide some of the convenience through tooling.  For example, an IDE (or `swift package` itself on the command line) can offer to add product definitions when it notices certain types of changes to the structure of the package.  We believe that having defined product types lets the tools present a lot better diagnostics and other forms of help to users, since it provides a clear statement of intent on the part of the package author.

### Distinguishing between target dependencies and product dependencies

The proposal extends the `Target()` initializer's `dependencies` parameter to allow products as well as targets; another approach would have been to add a new parameter, e.g. `externalDependencies` or `productDependencies`.

_Advantage_

Targets and products are different types of entities, and it is possible for a target and a product to have the same name.  Having the `dependencies` parameter as a heterogeneous list can lead to ambiguity.
   
_Disadvantages_

Conceptually the *dependency* itself is the same concept, even if type of entity being depended on is technically different.  In both cases (target and product), it is up to the build system to determine the exact type of artifacts that should be produced.  In most cases, there is no actual semantic ambiguity, since the name of a target, product, and package are often the same uniquely identifiable "brand" name of the component.

Also, separating out each type of dependency into individual homogeneous lists doesn't scale.  If a third type of dependency needs to be introduced, a third parameter would also need to be introduced.  Keeping the list heterogeneous avoids this.
