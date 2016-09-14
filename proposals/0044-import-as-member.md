# Import as member

* Proposal: [SE-0044](0044-import-as-member.md)
* Author: [Michael Ilseman](https://github.com/milseman)
* Status: **Implemented (Swift 3)**
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160321/013265.html)
* Bug: [SR-1053](https://bugs.swift.org/browse/SR-1053)

## Introduction

Swift imports C declarations, allowing Swift code to natively interact with C
libraries and frameworks. But, such imported APIs do not feel natural to
interact with in Swift. This proposal seeks to provide a mechanism for C API
authors to specify the capability of importing functions and variables as
members on imported Swift types. It also seeks to provide an automatic inference
option for APIs that follow a consistent, disciplined naming convention.

[Swift-evolution thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160229/011617.html)<br />
[Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160314/012695.html)
## Motivation

C APIs and frameworks currently import into Swift as global functions and global
variables. Interacting with these can feel awkward in Swift.

Here's an example of programmatic drawing using the Core Graphics C API:

```swift
override func drawRect(rect: CGRect) {
    let context: CGContext = UIGraphicsGetCurrentContext()!
    let toCenter = CGPoint(x: bounds.width/2.0, y: bounds.height/2.0)
    let angle = CGFloat(M_PI / 16)

    var transform = CGAffineTransformIdentity
    for _ in 0..<32 {
        triangulateRect(bounds, inputTransform: transform, context: context)
        transform = CGAffineTransformTranslate(transform, toCenter.x, toCenter.y)
        transform = CGAffineTransformRotate(transform, angle)
        transform = CGAffineTransformTranslate(transform, -toCenter.x, -toCenter.y)
    }
    CGContextSetLineWidth(context, bounds.size.width / 100)
    CGContextSetGrayStrokeColor(context, 0.5, 1.0)
    CGContextDrawPath(context, .Stroke)
}

func triangulateRect(bounds: CGRect, inputTransform: CGAffineTransform,
		context: CGContext) {
    var transform = inputTransform

    // Triangle from top left corner, to bottom middle, to top right, and then
    // draw the boundary
    let topLeft = bounds.origin
    let bottomRight = CGPoint(x: bounds.size.width, y: bounds.size.height)
    let path = CGPathCreateMutable()
    CGPathMoveToPoint(path, &transform, topLeft.x, topLeft.y)
    CGPathAddLineToPoint(path, &transform, CGRectGetMidX(bounds), bottomRight.y)
    CGPathAddLineToPoint(path, &transform, bottomRight.x, topLeft.y)
    CGPathAddLineToPoint(path, &transform, topLeft.x, topLeft.y)
    CGPathAddLineToPoint(path, &transform, topLeft.x, bottomRight.y)
    CGPathAddLineToPoint(path, &transform, bottomRight.x, bottomRight.y)
    CGPathAddLineToPoint(path, &transform, bottomRight.x, topLeft.y)
    CGContextAddPath(context, path)
}
```

A much more natural expression of this in Swift, would be something more like:

```swift
override func drawRect(rect: CGRect) {
    let context: CGContext = UIGraphicsGetCurrentContext()!
    let toCenter = CGPoint(x: bounds.width/2.0, y: bounds.height/2.0)
    let angle = CGFloat(M_PI / 16)

    var transform = CGAffineTransform.identity
    for _ in 0..<32 {
        triangulateRect(bounds, inputTransform: transform, context: context)
        transform = transform.translate(toX: toCenter.x, toY: toCenter.y)
                             .rotate(angle: angle)
                             .translate(toX: -toCenter.x, toY: -toCenter.y)
    }

    context.lineWidth = bounds.size.width / 100
    context.strokeColor = CGColor(gray: 0.5, alpha: 1.0)
    context.drawPath(mode: .Stroke)
}

func triangulateRect(bounds: CGRect, inputTransform: CGAffineTransform,
		context: CGContext) {
    var transform = inputTransform

    // Triangle from top left corner, to bottom middle, to top right, and then
    // draw the boundary
    let topLeft = bounds.origin
    let bottomRight = CGPoint(x: bounds.size.width, y: bounds.size.height)
    let path = CGMutablePath()
    path.move(transform: &transform, x: topLeft.x, y: topLeft.y)
    path.addLine(transform: &transform, x: bounds.midX, y: bottomRight.y)
    path.addLine(transform: &transform, x: bottomRight.x, y: topLeft.y)
    path.addLine(transform: &transform, x: topLeft.x, y: topLeft.y)
    path.addLine(transform: &transform, x: topLeft.x, y: bottomRight.y)
    path.addLine(transform: &transform, x: bottomRight.x, y: bottomRight.y)
    path.addLine(transform: &transform, x: bottomRight.x, y: topLeft.y)
    context.addPath(path)
}
```

Currently, the only way for a C framework to provide a natural Swift experience
is to author large overlays or Swift wrappers.


## Proposed solution

### Manual specification

C framework authors should have a way to manually specify how their APIs appear
in Swift beyond the limited functionality currently provided with NS_SWIFT_NAME.
This includes the ability to specify a type on which a given variable or
function should be imported. This also includes the ability to specify when a
function should be imported as a computed getter or setter of a property on that
type.

The goal is for developers using a C framework, which has these manual
annotations applied, to develop in Swift as naturally as if they were working
with a native object-oriented interface.

### Automatic inference

Coupled with this manual specification ability is an automatic inference system.
The inference system analyzes C global names and types, attempting to find an
imported Swift type to extend with a method, initializer, or property from this
global.

This inference system's goal is to be able to automatically handle the majority
of global variables and functions in CF-style frameworks, and in the future be
extensible to benefit other well structured, disciplined APIs.

*Amendment:*  Automatic inference will not be used by default for all C
APIs, but will be opt-in.

### Maps directly onto C calling convention

Wrappers and overlays have the downside that they result in an extra function
call hop in order to reach the underlying C API (though fragility controls may
somewhat alleviate this in the future).

This proposal calls for imported APIs to map directly onto the original C APIs,
without calling through intermediary wrappers or overlaid definitions. For
instance members, this means supplying a reference to self in the appropriate
parameter slot.


## Detailed design

### swift_name attribute

The primary mechanism of manually communicating to the Swift compiler how an API
should be imported is the swift_name attribute (e.g. through the CF_SWIFT_NAME
macro). swift_name will be expanded to allow the user to provide a type on which
the imported function will be a member of, and allow for specifying a function
as a computed getter or setter for a type.

Examples:

```C
// Import as init
struct Point3D createPoint3D(float x, float y, float z)
__attribute__((swift_name("Point3D.init(x:y:z:)")));

// Import as method
struct Point3D rotatePoint3D(Point3D point, float radians)
__attribute__((swift_name("Point3D.rotate(self:radians:)")));

// Import as instance computed property
float Point3DGetRadius(Point3D point)
__attribute__((swift_name("getter:Point3D.radius(self:)")));
void Point3DSetRadius(Point3D point, float radius)
__attribute__((swift_name("setter:Point3D.radius(self:_:)")));

// Import as static property
extern struct Point3D identityPoint
__attribute__((swift_name("Point3D.identity")));

// Import as static computed property
Point3D getZeroPoint(void)
__attribute__((swift_name("getter:Point3D.zero()")));
void setZeroPoint(Point3D point)
__attribute__((swift_name("setter:Point3D.zero(_:)")));
```

*Amendment:* Also allow for importing as subscript.

```C
// Import as subscript
float Point3DGetPointAtIndex(int idx, Point3D point)
__attribute__((swift_name("getter:subscript(_:self:)")))
void Point3DSetPointAtIndex(int idx, Point3D point, float val)
__attribute__((swift_name("getter:subscript(_:self:newValue:)")))
```

The string present in swift_name will additionally support the following:

* A type name proceeded by ``.`` to denote the context to import onto
* ``self`` to denote which parameter to treat as self for an instance
   method/property, otherwise this will be a static method/property
* ``getter:`` and ``setter:`` to denote the function as a property getter/setter

*Amendment:*
* ``newValue`` to denote which parameter to treat as a subscript setter's new value

*Amendment:* swift_name is not valid on non-prototyped function declarations.

*Amendment:* swift_name can be used to add instance members onto an extension
of the named protocol, but they are limited to instance members. Importing as
static method or init is not supported. Instance members are imported into a
protocol extension, enforcing static dispatch.

### Automatic inference heuristics

The following are some techniques and heuristics that can be useful for
consistently named C APIs, e.g. CF-style frameworks. These heuristics are
based off of the variable/function's name and type.

* Identify init by return type
```diff
- func CGColorCreate(space: CGColorSpace?, _ components: UnsafePointer<CGFloat>)
-   -> CGColor?

// extension CGColor { ...
+   init?(space: CGColorSpace?, components: UnsafePointer<CGFloat>)
```

* Identify computed properties by finding "get" / "set" pairs
```diff
- func CGContextGetInterpolationQuality(c: CGContext?) -> CGInterpolationQuality
- func CGContextSetInterpolationQuality(c: CGContext?,
-   _ quality: CGInterpolationQuality)

// extension CGContext { ...
+   final var interpolationQuality: CGInterpolationQuality
```

* Identify boolean predicates and other computed property patterns
```diff
- func CGDisplayModeIsUsableForDesktopGUI(mode: CGDisplayMode?) -> Bool

// extension CGDisplayMode {
+   final var isUsableForDesktopGUI: Bool { get }
```

* Identify methods by finding a self parameter
```diff
- func CGAffineTransformInvert(t: CGAffineTransform) -> CGAffineTransform

// extension CGAffineTransformation { ...
+   func invert() -> CGAffineTransform
```

* Various special cases, fuzzy name matching, etc.
```diff
- func CGDisplayStreamUpdateGetTypeID() -> CFTypeID

// extension CGDisplayStreamUpdate { ...
+   final class var typeID: CFTypeID { get }

...

- func CGBitmapContextGetData(context: CGContext?) -> UnsafeMutablePointer<Void>

// extension CGContext { ...
+   final var bitmapData: UnsafeMutablePointer<Void> { get }
```

### Underlying infrastructure

The Clang Importer will be extended to support importing function and variable
declarations onto different effective contexts than they appear in Clang.
Additionally, the Clang Importer will want to create a single extension point
per submodule/type pair on which to add these members.

SILGen will need to be extended to map calls to these members directly to the
original C API calls, passing self in the appropriate parameter location for
instance members.

### Migration

Projects using old style APIs will need to migrate to any new API. Since the
proposed imports are done programmatically in the importer, migration attributes
can be attached to the new decls, allowing the Swift migrator to automatically
migrate user code.


## Impact on existing code

Any Swift code using a C framework that uses this functionality will be
massively affected, though in ways that the Swift migrator can alleviate.

## Alternatives considered

### Wrap everything

One alternative, which is the only option available currently to framework
authors, is to require C APIs to provide Swift wrapper APIs or overlays in order
to call into the underlying C functionality.

This has the disadvantage of having to maintain separate APIs in addition to the
C headers themselves. This proposal allows for the C header to specify how the
name should appear when imported into Swift. Additionally, if a C API follows
consistent, CF-like naming, most of it can be imported automatically


