# Package Manager Product Definitions

* Proposal: [SE-NNNN](NNNN-package-manager-product-definitions.md)
* Author: [Anders Bertelrud](https://github.com/abertelrud)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal introduces the concept of *products* for Swift Package Manager packages, and proposes enhancements to the package manifest format to let packages define products that can be referenced by other packages.

Swift-evolution thread: [Discussion thread topic for that proposal](http://news.gmane.org/gmane.comp.lang.swift.evolution)

## Motivation

Currently, the Swift Package Manager has only a limited notion of the products that are built for a package.  It has a set of rules by which it infers implicit products based on the contents of various targets, and it also has a small amount of undocumented, unsupported package manifest syntax for explicitly declaring products, but it provides no supported way for package authors to declare the products of their packages.

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

Any target may be included in multiple products, though not all kinds of target apply to all products; for example, a test target is not able to be included in a library product.

The products represent the publicly vended package outputs on which any client package can depend, and also define the characteristics of the produced artifacts.

As mentioned earlier, Swift Package Manager already infers a set of implicit products based on the set of targets in the package.  The inference rules will be supported and documented as part of this feature; this will allow all existing packages to continue to work unmodified, and will handle simple packages without a lot of extra work on the part of the author.  Packages will only need to provide explicit product definitions when the intended products differ from what the Swift Package Manager would infer.

The inference rules are detailed in the next section of this document.  Products will only be inferred if there are no explicit product definitions in the package; in considering the various ways in which a mixture of implicit and explicit products could interact, this all-or-nothing condition has turned out to be the only policy that is simple and understandable enough to be workable.

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
        LibraryProduct(name: "Lib1", type: .static, targets: ["Bar"]),
        LibraryProduct(name: "Lib2", type: .dynamic, targets: ["Baz"]),
        ExecutableProduct(name: "Exe", targets: ["Exe"]),
        TestProduct(name: "HelloTests", targets: ["ExeTests", "FooTests", "BarTests", "BazTests"])
    ]
)
```

Note that the test product is explicitly defined, since the presence of explicit product definitions prevents the inference of implicit products.

*[NOTE: I expect that we will get a lot of pushback on this; it's particularly tedious to have to list all the test targets. Is this really what we want to go with?  Test products, in particular, feel "different" somehow.]*

The initial types of products that can be defined are executables, libraries, and tests.  Libraries can be declared as static or dynamic, but when possible, the specific type of library should be omitted -- in this case, the build system will choose the most appropriate type to build based on the context in which the product will be used (depedning on the type of client, the platform, etc).

A product definition lists the root targets to include in the product; the interfaces of those targets will be available to any clients (for product types where that makes sense).  Any dependencies of those targets will also be included in the product, but won't be made visible to clients.  The Swift compiler does not currently provide this granularity of visibility control, but it constitutes a declaration of intent that can be used by IDEs and other tools.  We also hope that the compiler will one day support this level of visibility control.

Any other targets on which the root targets depend will also be included in the product, but their interfaces will not be made available to clients.

### Product dependencies

A target will be able to declare its use of products defined by any of the package dependencies.  This is in addition to the existing ability to depend on other targets in the same package.

This is done through a new optional array parameter when instantiating a target:

```
Target(name: "Foo", dependencies: ["Bar", "Baz"], productUses: ["SomeProduct"])
```

*[NOTE: We still need to make a final decision about this: one array or two? If two, then what names?  If one array, then how do we distinguish products and targets?]*

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
public class Product {
    public let name: String
    public let targets: [String]
    
    public init(name: String, targets: [String]) {
        self.name = name
        self.targets = targets
    }
}

public class ExecutableProduct : Product {
    // nothing else at this time
}
    
public class LibraryProduct : Product {
    public enum LibraryType {
        case .static
        case .dynamic
    }
    public let type: LibraryType?

    public init(name: String, type: LibraryType? = nil, targets: [String]) {
        super.init(name: name, targets: targets)
        self.type = type
    }
}
    
public class TestProduct : Product {
    // nothing else at this time
}
```

*[QUESTION: Should `Product` be inside an `enum` for namespacing purposes?]*

*[NOTE: I'm not particularly happy with the empty definitions of some of the product classes. Still, I do think that there is a conceptual hierarchy of product types, not just an enum. This will make more sense a the set of possible types of products grow, but is a bit weird right now.]*

As with targets, there is no semantic significance to the order of the products in the array.

### Implicit products

If the `products` array is omitted, the Swift Package Manager will infer a set of implicit products based on the targets in the package.

The rules for implicit products are:

1.  An executable product is implicitly defined for any target that produces an executable module (as defined here: https://github.com/apple/swift-package-manager/blob/master/Documentation/Reference.md).

2.  A library product is implicitly defined for any target that produces a library module.

3.  A test product is implicitly defined for any test target.

As mentioned earlier, the implicit products are only inferred if the package contains no explicit product definitions.  This is true even for test products.

### Product dependencies

We will add a `usedProducts` parameter to the `Target` initializer.  This will allow any target to depend on products specified in other packages.

```
public final class Target {
    /// A dependency on an individual target.
    public enum TargetDependency {
        /// A dependency on a target in the same project.
        case Target(name: String)
    }
    
    /// A use of a particular product.
    public enum ProductUse {
        /// A use of a product.  If a package name is provided, it must match the name of one of the packages named in a `.Package()` directive.
        case Product(name: String, package: String?)
    }
    
    /// The name of the target.
    public let name: String

    /// Dependencies on other targets in the package.
    public var dependencies: [TargetDependency]

    /// Uses of products from other packages.
    public var productUses: [ProductUse]

    /// Construct a target.
    public init(name: String, dependencies: [TargetDependency] = [], productUses: [ProductUse] = []) {
        self.name = name
        self.dependencies = dependencies
        self.productUses = productUses
    }
}
```

*[ISSUE: I'm not particularly happy with where we ended up here. The terms "dependency" and "use" are not at all obvious, and apart from the short-name form, it isn't at all obvious that these dependencies are conceptually different. In this case, I think the original API had it right in preparing for being able to have different kinds of dependencies. I'm starting to go back toward thinking that we should model it correctly and then find some notation for the string short-form.]*

In the absence of any product dependencies, the entire package will be considered to be dependent on all of the packages on which it depends.  If the package contains at least one other product dependency, then all targets that depend on products from other packages will need to have product dependencies specified.

*[ISSUE: This seems like another fairly unfortunate drop-off-a-cliff semantic, but short of adding a boolean to each `.Package()` declaration to say whether to depend on everything in that package, I don't know of a better solution.  I'd like to discuss this a little bit more before broadcasting this proposal.]*

## Impact on existing code

There will be no impact on existing packages that follow the documented format of the package manifest.  The Swift Package Manager will continue to infer products based the existing.

We could also support packages that use the current undocumented product support by continuing to support the current `Product` types as a façade on the new API.
