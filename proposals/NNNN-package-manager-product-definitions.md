# Package Manager Product Definitions

* Proposal: [SE-NNNN](NNNN-package-manager-product-definitions.md)
* Author: [Anders Bertelrud](https://github.com/abertelrud)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal introduces the concept of *products* for Swift Package Manager packages, and proposes enhancements to the package manifest format to let packages define products that can be referenced by other packages.

Swift-evolution thread: [Discussion thread topic for that proposal](http://news.gmane.org/gmane.comp.lang.swift.evolution)

## Motivation

Currently, the Swift Package Manager has only a limited notion of the products that are built for a package.  It has a set of rules by which it infers implicit products based on the contents of various targets, and it also has a small amount of undocumented, unsupported package manifest syntax for explicitly declaring products, but it provides no supported way for package authors to declare what their packages produce.

Also, while the Swift Package Manager currently supports dependencies between packages, it has no support for declaring a dependency on anything more fine-grained than a package.

Such fine-grained dependencies are often desired, and this desire has in the past been expressed as a request for the ability to define a dependency on any arbitrary target of a package.  That, in turn, leads to requests to provide access control for targets, since a package author may want control over which targets can be independently accessed from outside the package.

Even if visibility control for targets were to be provided (indeed, an early draft of the package manifest had the notion of "publishing" a target to external clients), there would still be no way for the package author to declare anything about the kind of product that should be built (such as the kind of library that should be produced).

One consequence of the lack of ability to define dependencies at sub-package granularity is that package authors have to break up packages into several smaller packages in order to achieve the layering they want.  This may be appropriate in some cases, but should be done based on what makes sense from a conceptual standpoint and not because of limitations of expressibility in the Swift Package Manager.

For example, consider the package for a component that has both a library API and command line tools.  Such a package is also likely to be layered into a set of core libraries that are dependencies of both the public library and the command line tools, but that should remain a private implementation detail as far as clients are concerned.

Such a package would need to be split up into three separate packages in order to provide the appropriate dependency granularity:  one for the public library, another for the command line tools, and a third, private package that provides the shared implementation for the other two packages.  In the case of a single conceptual component that should have a single version number, this fracturing into multiple packages is directly opposed to the developer's preferred manner of packaging.

What is needed is a way to allow package authors to declare conceptually distinct products of a package, and to allow client packages to define dependencies on individual products in a package.

Furthermore, explicit product definitions allow the package author to control the types of artifacts produced from the targets in the package.  This can include such things as whether a library is built as a static or a dynamic library, and we expect that additional product types will be added over time to let package authors build more kinds of artifacts.

## Proposed solution

We will introduce a documented and supported concept of a package product, along with package manifest improvements to let package authors define products and to let package clients define dependencies on products.  In defining a product, a package author will be able to specify the type of product and a set of characteristics appropriate for the type.

### Product definitions

A package will be able to define an arbitrary number of products that are visible to all clients of the package.  A product definition includes the type of product, the name (which must be unique among the products in the package), and the root set of targets that comprise the implementation of the product.

Any target may be included in multiple products, though not all kinds of targets apply to all products; for example, a test target is not able to be included in a library product.

The products represent the publicly vended package outputs on which any client package can depend, and also define the characteristics of the produced artifacts.

As mentioned earlier, Swift Package Manager already infers a set of implicit products based on the set of targets in the package.  One open question is whether inference rules will be supported and documented as part of this feature, in order to allow existing packages to continue to work unmodified and to avoid the need for explicit product definitions for simple packages.  While the inference rules will need to be supported for existing packages, it is still an open question whether product will be inferred for packages using the Swift Pacakge Manager 4.0 version of the API.

The inference rules that apply to legacy packages are detailed in the next section of this document.

Even if Swift Pacakge Manager 4.0 does infer products for non-legacy packages, products will only be inferred if there are no explicit product definitions in the package.  The reason is that the interaction of a mixture of implicit and explicit products is likely to lead to significant complexity and to be a source of both confusion and bugs.

An example of a package containing explicit product definitions:

```
let package = Package(
    name: "Hello",
    targets: [
        Target(name: "Foo"),
        Target(name: "Bar"),
        Target(name: "Baz", dependencies: ["Foo", "Bar"]),
        Target(name: "Exe", dependencies: ["Foo"])
    ],
    products: [
        Library(name: "Lib1", type: .static, targets: ["Bar"]),
        Library(name: "Lib2", type: .dynamic, targets: ["Baz"]),
        Executable(name: "Exe", targets: ["Exe"]),
    ]
)
```

The initial types of products that can be defined are executables and libraries.  Libraries can be declared as static or dynamic, but when possible, the specific type of library should be omitted -- in this case, the build system will choose the most appropriate type to build based on the context in which the product will be used (depedning on the type of client, the platform, etc).

Note that tests are not considered to be products, and do not need to be explicitly defined.

A product definition lists the root targets to include in the product; the interfaces of those targets will be available to any clients (for product types where that makes sense).  Any dependencies of those targets will also be included in the product, but won't be made visible to clients.  The Swift compiler does not currently provide this granularity of visibility control, but it constitutes a declaration of intent that can be used by IDEs and other tools.  We also hope that the compiler will one day support this level of visibility control.

Any other targets on which the root targets depend will also be included in the product, but their interfaces will not be made available to clients.

For example, in the package definition shown above, the library product `Lib2` would only vend the interface of `Baz` to clients.  Since `Baz` depends on `Foo` and `Bar`, those two targets would also be compiled and linked into `Lib2`, but their interfaces should not be visible to clients of `Lib2`.

### Product dependencies

A target will be able to declare its use of the products that are defined in any of the external package dependencies.  This is in addition to the existing ability to depend on other targets in the same package.

There are two basic approaches for how to represent this.  As noted in the "Open questions" section below, more discussion is needed before we can choose which of these approaches to recommend:

1.  Extending the notion of the types of dependencies that can be listed in a target definition's `dependencies` parameter.

    To see how this works, remember that each string listed for the `dependencies` parameter of a target is just shorthand for a `.target(name: "...")` parameter, i.e. a dependency on a target within the same package.
    
    For example, the target definition:
    
    ```
    Target(name: "Foo", dependencies: ["Bar", "Baz"])
    ```
    
    is shorthand for:
    
    ```
    Target(name: "Foo", dependencies: [.target(name: "Bar"), .target(name: "Baz")])
    ```
    
    This could be extended to support product dependencies in addition to target dependencies.
    
    ```
    let package = Package(
        name: "Hello",
        dependencies: [
            .Package(url: "https://github.com/ExamplePackage", majorVersion: 1),
        ],
        targets: [
            Target(name: "Foo"),
            Target(name: "Bar", dependencies: [
                .target(name: "Foo"),
                .product(name: "Baz", package: "ExamplePackage")
            ])
        ],
    )
    ```
    
    In this example, the package name is the short name of the package as defined by the package itself.  A possibility would be to allow the package parameter to be optional when it is unambiguous.
    
    A significant drawback of this approach is the loss of an ability to use strings as unambiguous shorthand for `.target(name: "...")` values.  To remedy this, strings could still be allowed, as long as there was a clear way to disambiguate the dependency in cases in which two or more entities have the same name.
    
    If we look at practical use cases, it seems rare that two completely unrelated entities (e.g. a target and a product) would have the same name.  For example, if a target depends on `libAlamofire`, it doesn't actually matter whether it's the target or the product that is the dependency.  So in most cases, a string would unambiguously capture the intent of the package author.  If the shorthand form followed a search order, such as:
    
    - first look for a target with the specified name in the same package
    - second, look for a product with the specified name in any package dependency

    then it should be possible for the shorthand notation to be sufficient in the vast majority of cases, with the possibility of using the more verbose form in the cases in which the shorthand form really is ambiguous.

2.  Alternatively, a new optional array parameter could be added to the instantiation of a target:

    ```
    Target(name: "Foo", dependencies: ["Bar", "Baz"], externalDependencies: ["SomeProduct"])
    ```
    
    If we go this route, one of the difficulties is in choosing good names from the arrays.  Also, we would still need to determine whether it would be sufficient to list strings in the `externalDependencies` parameter, or whether `(<package>, <product>)` tuples would be needed.

## Detailed design

### Product definitions

We will add a `products` parameter to the `Package()` initializer:
    
```
Package(
    name: String,
    pkgConfig: String? = nil,
    providers: [SystemPackageProvider]? = nil,
    targets: [Target] = [],
    dependencies: [Package.Dependency] = [],
    products: [Product]? = nil,
    exclude: [String] = []
)
```
    
The definition of the `Product` type will be:
   
```
public enum Product {
    public class AbstractProduct {
        public let name: String
        public let targets: [String]
        
        public init(name: String, targets: [String])
    }
    
    public class Executable : AbstractProduct {
        public init(name: String, targets: [String])
    }
    
    public class Library : AbstractProduct {
        public let type: LibraryType?
    
        public init(name: String, type: LibraryType? = nil, targets: [String])
    }
    
    public enum LibraryType {
        case .static
        case .dynamic
    }
}
```

The namespacing allows the names of the product types to be kept short.

As with targets, there is no semantic significance to the order of the products in the array.

### Implicit products

If the `products` array is omitted, the Swift Package Manager will infer a set of implicit products based on the targets in the package.

The rules for implicit products are:

1.  An executable product is implicitly defined for any target that produces an executable module (as defined here: https://github.com/apple/swift-package-manager/blob/master/Documentation/Reference.md).

2.  If there are any library targets, a single library product is implicitly defined for all the library targets.  The name of this product is based on the name of the package.

### Product dependencies

Depending on the decision about whether to extend the meaning of the `dependencies` parameter to target initialization or to add a new `externalDependencies` parameter, we will take one of these two approaches:

1.  For the extended `dependencies` parameter approach:  Add a new enum case to the `TargetDependency` enum to handle the case of dependencies on products, and another enum case to represent an unbound by-name dependency.  Modify the string-literal conversion to create a by-name dependency instead of a target dependency, and add logic to bind the by-name dependencies to either target or product dependencies once the package graph has been resolved.

    Alternatively, we could handle the case of unbound by-name dependencies by initially recording them as dependencies on targets (as today), and by then converting them to dependencies on products if appropriate after the package has been loaded:

    ```
    public final class Target {
        /// Represents a dependency on another entity.
        public enum TargetDependency {
            /// A dependency on a target in the same project.
            case Target(name: String)
            /// A dependency on a product from a package dependency.  If a package name is provided, it must match the name of one of the packages named in a `.Package()` directive.
            case Product(name: String, package: String)
        }
        
        /// The name of the target.
        public let name: String
    
        /// Dependencies on other entities inside or outside the package.
        public var dependencies: [TargetDependency]
    
        /// Construct a target.
        public init(name: String, dependencies: [TargetDependency] = [])
    }
    ```

2.  For the separate `externalDependencies` parameter approach:  We will add an `externalDependencies ` parameter to the `Target` initializer, along with additional type definitions to support it:

    ```
    public final class Target {
        /// Represents a dependency on another target.
        public enum TargetDependency {
            /// A dependency on a target in the same project.
            case Target(name: String)
        }
        
        /// Represents a dependency on a product in an external package.
        public enum ExternalTargetDependency {
            /// A dependency on a product from a package dependency.  If a package name is provided, it must match the name of one of the packages named in a `.Package()` directive.
            case Product(name: String, package: String?)
        }
        
        /// The name of the target.
        public let name: String
    
        /// Dependencies on other targets in the package.
        public var dependencies: [TargetDependency]
    
        /// Dependencies on products in external packages.
        public var externalDependencies: [ExternalTargetDependency]
    
        /// Construct a target.
        public init(name: String, dependencies: [TargetDependency] = [], externalDependencies: [ExternalTargetDependency] = [])
    }
    ```

In the absence of any product dependencies, the entire package will be considered to be dependent on all of the packages on which it depends.  If the package contains at least one other product dependency, then all targets that depend on products from other packages will need to have product dependencies specified.

*[ISSUE: This seems like a fairly unfortunate drop-off-a-cliff semantic, but short of adding a boolean to each `.Package()` declaration to say whether to depend on everything in that package, I don't know of a better solution.  I'd like to discuss this a little bit more before broadcasting this proposal.]*

## Impact on existing code

There will be no impact on existing packages that follow the documented Swift Package Manager 3.0 format of the package manifest.  The Swift Package Manager will continue to infer products based the existing rules.  We could also support packages that use the current undocumented product support by continuing to support the current `Product` types as a façade on the new API, but this does not seem worth the effort.

If we decide to completely deprecate the implied products in the Swift Package Manager 4.0 API, then that will only affect packages once they upgrade their manifests to the SwiftPM 4.0 API.

## Alternatives considered

Instead of product definitions, fine-grained dependencies could be introduced by allowing targets to be marked as public or private to the package.  This would not provide any way for a package author to control the type and characteristics of the various artifacts, however.  Relying on the implied products that result from the inference rules is not likely to be scalable in the long term as we introduce new kinds of product types.

*[As we address the open questions, the approaches not chosen will be described here]*

## Open questions

1. Should tests be considered to be products?

   Pro:  Since tests are artifacts that can be produced during a build, just like products are, it may make sense for users to be able to express opinions about them in the same manner as for products.
   
   Con:  Tests are conceptually different from products in their intended use, and it is much less likely that users will have specific opinions about the details of how tests are built.  It seems conceptually cleaner to treat tests as a different kind of artifact than products.
   
2. Should there be any inference of products at all?

   Pro:  It can be much more convenient to not have to declare products, and to be able to add new products just by adding or renaming files and directories.

   Con:  The very fact that it is so easy to change the set of products without modifying the package manifest can lead to unexpected behavior due to seemingly unrelated changes (e.g. creating a file called "main.swift" in a module changes that module from a library to an executable).

3. Should target dependencies on products be separate from dependencies on other targets?

   Pro:  Targets and products are different concepts, and it is possible for a target and a product to have the same name.  This can lead to ambiguity.
   
   Con:  Conceptually the *dependency* itself is the same concept, even if type of entity being depended on is technically different.  In both cases (target and product), it is up to the build system to determine the exact type of artifacts that should be produced.  In most cases, there is no actual semantic ambiguity, since the name of a target, product, and package are often the same uniquely identifiable "brand" name of the component.
