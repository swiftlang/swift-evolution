# Function builders

* Proposal: [SE-XXXX](XXXX-function-builders.md)
* Authors: [John McCall](https://github.com/rjmccall), [Doug Gregor](http://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: Available in [development snapshots](https://swift.org/download/#snapshots) behind the underscored attribute `@_functionBuilder`.

Table of Contents
=================
   * [Function builders](#function-builders)
      * [Introduction](#introduction)
      * [Motivation](#motivation)
      * [Detailed design](#detailed-design)
         * [Function builder types](#function-builder-types)
         * [Function builder attributes](#function-builder-attributes)
         * [Function-building methods](#function-building-methods)
         * [The function builder transform](#the-function-builder-transform)
            * [Statement blocks](#statement-blocks)
            * [Declaration statements](#declaration-statements)
            * [Expression statements](#expression-statements)
            * [Assignments](#assignments)
            * [Selection statements](#selection-statements)
            * [Imperative control-flow statements](#imperative-control-flow-statements)
            * [Exception-handling statements](#exception-handling-statements)
            * [do statements](#do-statements)
            * [for..in loops](#forin-loops)
         * [Compiler Diagnostic Directives](#compiler-diagnostic-directives)
         * [Availability](#availability)
         * [<strong>Example</strong>](#example)
      * [Type inference](#type-inference)
         * [Function builder bodies](#function-builder-bodies)
         * [Inferring function builders from protocol requirements](#inferring-function-builders-from-protocol-requirements)
         * [Implicit memberwise initializer](#implicit-memberwise-initializer)
      * [Source compatibility](#source-compatibility)
      * [Effect on ABI stability and API resilience](#effect-on-abi-stability-and-api-resilience)
      * [Future Directions](#future-directions)
         * ["Simple" function builder protocol](#simple-function-builder-protocol)
         * [Stateful function builders](#stateful-function-builders)
         * [Transforming declarations](#transforming-declarations)
         * [Virtualized Abstract Syntax Trees (ASTs)](#virtualized-abstract-syntax-trees-asts)
      * [Alternatives considered](#alternatives-considered)
         * [Additional control-flow statements](#additional-control-flow-statements)
         * [Builder-scoped name lookup](#builder-scoped-name-lookup)

## Introduction

This proposal describes *function builders*, a new feature which allows certain functions (specially-annotated, often via context) to implicitly build up a value from a sequence of components.

The basic idea is that the results of the function's statements are collected using a builder type, like so:

```swift
// Original source code:
@TupleBuilder
func build() -> (Int, Int, Int) {
  1
  2
  3
}

// This code is interpreted exactly as if it were this code:
func build() -> (Int, Int, Int) {
  let _a = TupleBuilder.buildExpression(1)
  let _b = TupleBuilder.buildExpression(2)
  let _c = TupleBuilder.buildExpression(3)
  return TupleBuilder.buildBlock(_a, _b, _c)
}
```

In this example, all the statements are expressions and so produce a single value apiece.  Other statements, like `let`, `if`, and `while`, are variously either handled differently or prohibited; see the proposal details below.

In effect, this proposal allows the creation of a new class of embedded domain-specific languages in Swift by applying *builder transformations* to the statements of a function.  The power of these builder transformations is intentionally limited so that the result preserves the dynamic semantics of the original code: the original statements of the function are still executed as normal, it's just that values which would be ignored under normal semantics are in fact collected into the result.  The use of an *ad hoc* protocol for the builder transformation leaves room for a wide variety of future extension, whether to support new kinds of statements or to customize the details of the transformation. A similar builder pattern was used successfully for string interpolation in [SE-0228](https://github.com/apple/swift-evolution/blob/master/proposals/0228-fix-expressiblebystringinterpolation.md). 

Function builders have been a "hidden" feature since Swift 5.1, and the implementation (and its capabilities) have evolved since then. They are used most famously by [SwiftUI](https://developer.apple.com/xcode/swiftui/) to declaratively describe user interfaces, but others have also experimented with [building Swift syntax trees](https://swiftpack.co/package/akkyie/SyntaxBuilder), [testing](https://www.dotconferences.com/2020/02/kaya-thomas-swift-techniques-for-testing),
[a Shortcuts DSL](https://github.com/a2/swift-shortcuts), [a CSS SDL](https://github.com/carson-katri/swift-css/blob/master/Sources/CSS/CSSBuilder.swift), and [an alternative SwiftPM manifest format](https://forums.swift.org/t/declarative-package-description-for-swiftpm-using-function-builders/28699). There's a GitHub repository dedicated to [awesome function builders](https://github.com/carson-katri/awesome-function-builders) with more applications.

## Motivation

It's always been a core goal of Swift to allow the creation of great libraries. A lot of what makes a library great is its interface, and Swift is designed with rich affordances for building expressive, type-safe interfaces for libraries. In some cases, a library's interface is distinct enough and rich enough to form its own miniature language within Swift. We refer to this as a *Domain Specific Language* (DSL), because it lets you better describe solutions within a particular problem domain.

Function builders target a specific kind of interface that involves the declaration of list and tree structures, which are useful in many problem domains, including generating structured data (e.g. XML or JSON), UI view hierarchies (notably including Apple's SwiftUI framework, mentioned above), and similar use cases.  In this proposal, we will be primarily working with code which generates an HTML DOM hierarchy, somewhat like a web templating language except in code; credit goes to Harlan Haskins for this example.

Suppose that you have a program, part of which generates HTML.  You could, of course, directly generate a `String`, but that's error-prone (you have to make sure you're handling escapes and closing tags correctly throughout your code) and would make it hard to structurally process the HTML before sending it out.  An alternative approach is to generate a DOM-like representation of the HTML and then render it to a `String` as a separate pass:


```swift
protocol HTML {
  func renderAsHTML(into stream: HTMLOutputStream)
}

extension String: HTML {
  func renderAsHTML(into stream: HTMLOutputStream) {
    stream.writeEscaped(self)
  }
}

struct HTMLNode: HTML {
  var tag: String
  var attributes: [String: String] = [:]
  var children: [HTML] = []

  func renderAsHTML(into stream: HTMLOutputStream) {
    stream.write("<")
    stream.write(tag)
    for (k, v) in attributes.sort { $0.0 < $1.0 } {
      stream.write(" ")
      stream.write(k)
      stream.write("=")
      stream.writeDoubleQuoted(v)
    }
    if children.isEmpty {
      stream.write("/>")
    } else {
      stream.write(">")
      for child in children {
        child.renderAsHTML(into: stream)
      }
      stream.write("</")
      stream.write(tag)
      stream.write(">")
    }
  }
}
```

To make it easier to build these HTML hierarchies, we can define a bunch of convenient node-builder functions corresponding to common nodes:

```swift
func body(_ children: [HTML]) -> HTMLNode { ... }
func division(_ children: [HTML]) -> HTMLNode { ... }
func paragraph(_ children: [HTML]) -> HTMLNode { ... }
func header1(_ text: String) -> HTMLNode { ... }
```

Unfortunately, even with these helper functions, it's still pretty awkward to actually produce a complex hierarchy because of all the lists of children:

```swift
return body([
  division([
    header1("Chapter 1. Loomings."),
    paragraph(["Call me Ishmael. Some years ago"]),
    paragraph(["There is now your insular city"])
  ]),
  division([
    header1("Chapter 2. The Carpet-Bag."),
    paragraph(["I stuffed a shirt or two"])
  ])
])
```

The first problem is that there's a lot of punctuation here: commas, parentheses, and brackets.  This is a pretty superficial problem, and it's probably not a showstopper by itself, but it is something that it'd be nice to avoid, because it does distract a little from the content.

The second problem is that, because we're using array literals for the children, the type-checker is going to require the elements to have a homogeneous type.  That's fine for our HTML example, but it's limiting in general, because some trees are more generic and would benefit from propagating the types of the children into the type of the node.  For example, SwiftUI uses this for various optimizations within the view hierarchy.

The biggest problem, though, is that it's awkward to change the structure of this hierarchy.  That's fine if our hierarchy is just the static contents of *Moby Dick*, but in reality, we're probably generating HTML that should vary significantly based on dynamic information.  For example, if we wanted to allow chapter titles to be turned off in the output, we'd have to restructure that part of the code like this:

```swift
division((useChapterTitles ? [header1("Chapter 1. Loomings.")] : []) +
    [paragraph(["Call me Ishmael. Some years ago"]),
     paragraph(["There is now your insular city"])])
```

It's also harder to use good coding practices within this hierarchy. For example, suppose there's a common string we want to use many times, and so we want to create a variable for it:

```swift
let chapter = spellOutChapter ? "Chapter " : ""
  ...
header1(chapter + "1. Loomings.")
  ...
header1(chapter + "2. The Carpet-Bag.")
```

Most programmers would advise declaring this variable in as narrow a scope as possible and as close as possible to where it's going to be used.  But because the entire hierarchy is an expression, and there's no easy to declare variables within expressions, every variable like this has to be declared above the entire hierarchy.  (Now, it's true that there's a trick for declaring locals within expressions: you can start a closure, which gives you a local scope that you can use to declare whatever you want, and then immediately call it. But this is awkward in its own way and significantly adds to the punctuation problem.)

Some of these problems would be solved, at least in part, if the hierarchy was built up by separate statements:

```swift
let chapter = spellOutChapter ? "Chapter " : ""

let d1header = useChapterTitles ? [header1(chapter + "1. Loomings.")] : []
let d1p1 = paragraph(["Call me Ishmael. Some years ago"])
let d1p2 = paragraph(["There is now your insular city"])
let d1 = division(d1header + [d1p1, d1p2])

let d2header = useChapterTitles ? [header1(chapter + "2. The Carpet-Bag.")] : []
let d2p1 = paragraph(["I stuffed a shirt or two"])
let d2 = division(d2header + [d2p1])

return body([d1, d2])
```

But in most ways, this is substantially worse.  There's quite a lot of extra code that's made it much more difficult to track what's really going on.  That's especially true with all the explicit data flow, where it can be tough to piece together what nodes are children of others; moreover, that code is as tedious to write as it is to read, making it very prone to copy-paste bugs.  Furthermore, the basic structure of the hierarchy used to be clear from the code, and that's been completely lost: all of the nicely-nested calls to node builders have been flattened into one sequence.  Also, while optional children are a common problem for this hierarchy, the actual code to handle them has to be repeated over and over again, leading to boilerplate and bugs.  Overall, this is not a good approach at all.

What we really want is a compromise between these two approaches:

* We want the programming flexibility that comes from building things up with ordinary blocks of code: the ability to have local declarations and explicit control flow.

* We want the explicit recursive structure and implicit data flow that comes from building things up with expression operands.

This suggests a straightforward resolution: allow certain blocks of code to have implicit data flow out of the block and into the context which entered the block. The goal here is to allow this node hierarchy to be declared something like this:

```swift
return body {
  let chapter = spellOutChapter ? "Chapter " : ""
  division {
    if useChapterTitles {
      header1(chapter + "1. Loomings.")
    }
    paragraph {
      "Call me Ishmael. Some years ago"
    }
    paragraph {
      "There is now your insular city"
    }
  }
  division {
    if useChapterTitles {
      header1(chapter + "2. The Carpet-Bag.")
    }
    paragraph {
      "I stuffed a shirt or two"
    }
  }
}
```

The above has to be embedded into the ordinary language somehow, which means that at least the outermost layer must obey something like ordinary language rules.  Under ordinary language rules, this is a function call to `body `passing a trailing closure.  It makes sense, then, that what we're doing is taking the body of the anonymous function and apply some sort of transformation to it.  This raises a series of separate questions:

1. What it is about this source code that triggers the transformation?  We have chosen not to require an explicit annotation on every closure that needs transformation; see Alternatives Considered for a discussion.  So somehow this must get picked up from the fact that we're passing the closure to `body`.

2. Given that the transformation is going to collect a bunch of information, how does that information get back to `body`?  Since the transformation is working on a function body, this one's straightforward: the collected information will just be the return value of the function. There's no requirement to support this transformation simultaneously with ordinary `return`.

3. Given that the transformation has collected a sequence of partial results, how do they get combined to produce a return value?  We could simply always produce a tuple, but that isn't necessarily what the caller actually wants. In particular, it may be useful to allow the DSL to do different things for different partial results.  The logical answer is that there should be a function somehow provided by the DSL to combine the partial results, and this function might need to be generic or overloaded.

4. Given that the transformation might collect a partial result within optionally-executed code (e.g. in an `if` statement), what should be passed to the combining function?  The transformation can be taught to produce an optional value of the partial result type, but the DSL needs to be able to distinguish between a partial result that is optionally produced and a partial result that coincidentally happens to be of optional type.  The logical answer is that there should be a function provided by the DSL to translate optional partial results into "ordinary" partial results that can be collected normally.

These last two points (and some other considerations) strongly suggest that the DSL should be identified with a type that can provide an arbitrary namespace of functions that can be used as *ad hoc* customization points for the transformation.

## Detailed design

[SE-0258](https://github.com/apple/swift-evolution/blob/master/proposals/0258-property-wrappers.md) introduced the concept of custom attributes to Swift, an approach we build on here.

### Function builder types

A *function builder type* is a type that can be used as a function builder, which is to say, as an embedded DSL for collecting partial results from the expression-statements of a function and combining them into a return value.

A function builder type must satisfy one basic requirement:

* It must be annotated with the `@functionBuilder` attribute, which indicates that it is intended to be used as a function builder type and allows it to be used as a custom attribute.

In addition, to be practically useful, it must supply a sufficient set of function-builder methods to translate the kinds of functions which the DSL desires to translate.

### Function builder attributes

A function builder type can be used as an attribute in two different syntactic positions. The first position is on a `func`, `var`, or `subscript` declaration.  For the `var` and `subscript`, the declaration must define a getter, and the attribute is treated as if it were an attribute on that getter. A function builder attribute used in this way causes the function builder transform to be applied to the body of the function; it is not considered part of the interface of the function and does not affect its ABI.

A function builder type can also be used as an attribute on a parameter of function type, including on parameters of protocol requirements. A function builder attribute used in this way causes the function builder transform to be applied to the body of any explicit closures that are passed as the corresponding argument, unless the closure contains a `return` statement.  This is considered part of the interface of the function and can affect source compatibility, although it does not affect its ABI.

### Function-building methods

To be useful as a function builder, the function builder type must provide a sufficient subset of the function-building methods.  The protocol between the compiler's generated code and the function builder type is intended to be *ad hoc* and arbitrarily extensible in the future.

Function-building methods are `static` methods that can be called on the function builder type.  Calls to function-building methods are type-checked as if a programmer had written `BuilderType.<methodName>(<arguments>)`, where the arguments (including labels) are as described below; therefore, all the ordinary overload resolution rules apply.  However, in some cases the function builder transform changes its behavior based on whether a function builder type declares a certain method at all; it is important to note that this is a weaker check, and it may be satisfied by a method that cannot in fact ever be successfully called on the given builder type.

This is a quick reference for the function-builder methods currently proposed.  The typing here is subtle, as it often is in macro-like features.  In the following descriptions, `Expression` stands for any type that is acceptable for an expression-statement to have (that is, a raw partial result), `Component` stands for any type that is acceptable for a partial or combined result to have, and `Return` stands for any type that is acceptable to be ultimately returned by the transformed function.

* `buildExpression(_ expression: Expression) -> Component` is used to lift the results of expression-statements into the `Component` internal currency type.  It is only necessary if the DSL wants to either (1) distinguish `Expression` types from `Component` types or (2) provide contextual type information for statement-expressions. 

* `buildBlock(_ components: Component...) -> Component` is used to build combined results for most statement blocks.

* `buildFinalResult(_ components: Component) -> Return` is used to finalize the result produced by the outermost `buildBlock` call for top-level function bodies.  It is only necessary if the DSL wants to distinguish `Component` types from `Return` types, e.g. if it wants builders to internally traffic in some type that it doesn't really want to expose to clients.  If it isn't declared, the result of the outermost `buildBlock` will be used instead.

* `buildOptional(_ component: Component?) -> Component` is used to build a partial result in an enclosing block from the result of an optionally-executed sub-block.  If it isn't declared, optionally-executed sub-blocks are ill-formed.

* `buildEither(first: Component) -> Component` and `buildEither(second: Component) -> Component` are used to build partial results in an enclosing block from the result of either of two (or more, via a tree) optionally-executed sub-blocks.

* `buildArray(_ components: [Component]) -> Component` is used to build a partial result given the partial results collected from all of the iterations of a loop.

* `buildLimitedAvailability(_ component: Component) -> Component` is used to transform the partial result produced by `buildBlock` in a limited available context (such as `if #available`) into one suitable for any context. If not present, the partial result produced from a limited availability context will be the result of `buildBlock`.

### The function builder transform

The function builder transform is a recursive transformation operating on statement blocks and the individual statements within them.

#### Statement blocks

Within a statement block, the individual statements are separately transformed into sequences of statements which are then concatenated. Each such sequence may optionally produce a single *partial result*, which is an expression (typically a reference to a unique local variable defined as part of the transformation) which can be used later in the block.

After the transformation has been applied to all the statements, a call to `buildBlock` is generated to form a *combined result*, with all the partial results as unlabelled arguments.

If the statement block is the top-level body of the function being transformed, the final statement in the transformed block is a `return` with the combined result expression as its operand, wrapped in `buildFinalResult` if it was provided by the builder.  Otherwise, the combined result is propagated outwards, typically by assigning it (possibly after a transformation) to a local variable in the enclosing block; the exact rule is specified in the section for the enclosing statement below.

#### Declaration statements

Local declarations are left alone by the transformation. This allows developers to factor out subexpressions freely to clarify their code, without affecting the function builder transformation.

#### Expression statements

An expression statement which does not perform an assignment is transformed as follows:

* If the function builder type declares the `buildExpression` function-building method, the transformation calls it, passing the expression-statement as a single unlabeled argument.  This call expression is hereafter used as the expression statement.  This call is type-checked together with the statement-expression and may influence its type.

*  The statement-expression is used to initialize a unique variable of the statement-expression's result type, as if by `let v = <expression>`. This variable is treated as a partial result of the containing block. References to this variable are type-checked independently from it so that they do not affect the type of the expression.

The ability to control how expressions are embedded into partial results is an important advantage for certain kinds of DSL, including our HTML example.  In the original HTML example, we have an `HTML` protocol with a very small (and essentially fixed) number of implementing types.  This would probably be more natural to represent in Swift as an `enum` rather than a  `protocol`, but that would prevent a `String` from being written directly wherever an `HTML` was required, which would make complex `HTML` literals even more onerous to write in our original, pre-DSL solution:

```swift
return body([
  division([
    header1("Chapter 1. Loomings."),
    paragraph([.text("Call me Ishmael. Some years ago")]),
    paragraph([.text("There is now your insular city")])
  ]),
  division([
    header1("Chapter 2. The Carpet-Bag."),
    paragraph([.text("I stuffed a shirt or two")])
  ])
])
```

By using a DSL with `buildExpression`, however, we can use an `enum` for its natural representational, pattern-matching, and other advantages, then just add overloads to `buildExpression` to make it easier to build common cases within the DSL:

```swift
static func buildExpression(_ text: String) -> [HTML] {
  return [.text(text)]
}

static func buildExpression(_ node: HTMLNode) -> [HTML] {
  return [.node(node)]
}

static func buildExpression(_ value: HTML) -> [HTML] {
  return [value]
}
```

#### Assignments

An expression statement which performs an assignment is treated in the same manner as all other expression statements, although it will always return `()`. A function builder could choose to handle `()`-returning expression statements specially by overloading `buildExpression`, e.g.,

```swift
static func buildExpression(_: ()) -> Component { ... }
```

#### Selection statements

`if`/`else` chains and `switch` statements produce values conditionally depending on their cases. There are two basic transformation patterns which can be used, depending on the selection statement itself; we'll show examples of each, then explain the details of the transformation.

Consider a simple "if" statement without an "else" block:

```swift
if i == 0 {
  "0"
}
```

The first transformation pattern for selection statements turns the case into its own optional partial result in the enclosing block.  This is a simple transformation handling code that is optionally executed:

```swift
var vCase0: String?
if i == 0 {
  vCase0 = "0"
}
let v0 = BuilderType.buildOptional(vCase0)
```

The second transformation pattern produces a balanced binary tree of injections into a single partial result in the enclosing block. It can support general selection statements such as `if`-`else` and `switch`. Consider the following DSL code:

```swift
if i == 0 {
  "0"
} else if i == 1 {
  "1"
} else {
  generateFibTree(i)
}
```

Under this pattern, the example code becomes something like the following:

```swift
let vMerged: PartialResult
if i == 0 {
  vMerged = BuilderType.buildEither(first: "0")
} else if i == 1 {
  vMerged = BuilderType.buildEither(second:
        BuilderType.buildEither(first: "1"))
} else {
  vMerged = BuilderType.buildEither(second:
        BuilderType.buildEither(second: generateFibTree(i)))
}
```

The detailed transformation of selection statements proceeds as follows. The child blocks of the statement are first analyzed to determine the number *N* of cases that can produce results and whether there are any cases that don't. The implementation is permitted to analyze multiple nesting levels of statements at once; e.g. if a `case` consists solely of an `if` chain, the cases of the `if` can be treated recursively as cases of the `switch` at the implementation's discretion. A missing `else` is a separate case for the purposes of this analysis.

If *N* = 0, the statement is ignored by the transformation. Otherwise, an injection strategy is chosen:

* If the function builder type declares the `buildEither(first:)` and `buildEither(second:)` function-building methods, a full binary tree with *N* leaves (the *injection tree*) is chosen, and each result-producing case is uniquely assigned a leaf in it; these decisions are implementation-defined.  A unique variable `vMerged` of fresh type is declared before the statement.

* Otherwise, unique variables `vCase` are declared before the statement for each result-producing case.

The transformation then proceeds as follows:

* In each result-producing case, the transformation is applied recursively.  As the final statement in the case, the combined result is injected and assigned outwards:

  * If the statement is not using an injection tree, the combined result is wrapped in `Optional.Some` and assigned to the appropriate `vCase`.

  * Otherwise, the path from the root of the  injection tree to the appropriate leaf is considered.  An expression is formed by the following rules and then assigned to `vMerged`:

    * For an empty path, the original combined result from the case.

    * For a left branch through the tree, a call to the function-building method `buildEither(first:)` with the argument being the injection expression for the remainder of the path.

    * For a right branch through the tree, the same but with `buildEither(second:)`.

    * Finally, if there are any non-result-producing cases, the expression is wrapped in `Optional.some`.

    For example, if the path to the case's leaf is `left`, `left`, `right`, and there are non-result-producing cases, and the original combined result is `E`, then the injection expression assigned to `vMerged` is

    ```swift
    Optional.some(
      BuilderType.buildEither(first:
        BuilderType.buildEither(first:
          BuilderType.buildEither(second: E))))
    ```

    Note that all of the assignments to `vMerged` will be type-checked together, which should allow any free generic arguments in the result types of the injections to be unified.

* After the statement, if the statement is not using an injection tree or if there are any non-result-producing cases, then for each of the variables `v` declared above, a new unique variable `v2` is initialized by calling the function-building method `buildOptional(_:)` with `v` as the argument, and `v2` is then a partial result of the surrounding block.  Otherwise, there is a unique variable `vMerged`, and `vMerged` is a partial result of the surrounding block.

#### Imperative control-flow statements

`return` statements are ill-formed when they appear within a transformed function.  However, note that the transformation is suppressed in closures that contain a `return` statement, so this rule is only applicable in `func`s and getters that explicitly provide the attribute.

`break` and `continue` statements are ill-formed when they appear within a transformed function.  These statements may be supported in some situations in the future, for example by treating all potentially-skipped partial results as optional.

`guard` is provisionally ill-formed when it appears within a transformed function.  Situations in which this statement may appear may be supported in the future, such as when the statement does not produce a partial result.

#### Exception-handling statements

`throw` statements are left alone by the transformation.

`defer` statements are ill-formed when encountered in transformed functions.

`do` statements with `catch` blocks are ill-formed when encountered in transformed functions.

#### `do` statements

`do` statements without `catch` blocks are effectively wrappers around a block statement, and are transformed accordingly:

* A unique variable `v` is declared immediately prior to the `do`.

* The transformation is applied recursively to the child statement block.

* The combined result is assigned to `v` as the final statement in the child block, and `v` becomes a partial result of the containing block.

#### `for`..`in` loops

`for`...`in` statements execute each of the iterations of the loop, collecting the partial results from all iterations into an array. That array is then passed into `buildArray`. Specifically:

* A unique variable `v` is declared immediately prior to the `for`.
* A unique variable `vArray` is declared immediately prior to the `for`, is given `Array` type (with as-yet-undetermined element type), and is initialized to `[]`.
* The transformation is applied recursively to the body of the `for`..`in` loop, except that the partial result produced by the body is appended to the array via a call to `vArray.append`.
* The result of calling `buildArray(vArray)` is assigned to `v`, and `v` becomes a partial result of the containing block.

If no `buildArray` is provided, `for`..`in` loops are not supported in the body.

### Compiler Diagnostic Directives

`#warning` and `#error` have no run-time impact and are left unchanged by the function builder transformation.

### Availability

Statements that introduce limited available contexts, such as `if #available(...)`, allow use of newer APIs while still making the code backward-deployable to older versions of the libraries. A function builder carries complete type information (such as SwiftUI's [`ViewBuilder`](https://developer.apple.com/documentation/swiftui/viewbuilder)) may need to "erase" type information from a limited availability context using `buildLimitedAvailability`. Here is a SwiftUI example borrowed from [Paul Hudson](https://www.hackingwithswift.com/quick-start/swiftui/how-to-lazy-load-views-using-lazyvstack-and-lazyhstack):

```swift
@available(macOS 10.15, iOS 13.0)
struct ContentView: View {
    var body: some View {
        ScrollView {
            if #available(macOS 11.0, iOS 14.0, *) {
                LazyVStack {
                    ForEach(1...1000, id: \.self) { value in
                        Text("Row \(value)")
                    }
                }
            } else {
                VStack {
                    ForEach(1...1000, id: \.self) { value in
                        Text("Row \(value)")
                    }
                }
            }
        }
    }
}
```

`LazyVStack` was introduced in macOS 11/iOS 14.0, but this view is also available on macOS 10.15/iOS 13.0, so it uses `if #available`. SwiftUI carries complete type information throughout the view builder closure, including conditional branches:

```swift
static func buildEither<TrueContent, FalseContent>(first: TrueContent) -> _ConditionalContent<TrueContent, FalseContent>
```

This means that the type of the `ScrollView` will refer to `LazyVStack`, even on macOS 10.15/iOS 13.0, which results in a compilation error. `buildLimitedAvailability` provides a way for the function builder to "erase" type information it would normally keep, specifically in these situations:

```swift
static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView { .init(content) }
```

### **Example**

Let's return to our earlier example and work out how to define a function-builder DSL for it.  First, we need to define a basic function builder type:

```swift
@functionBuilder
struct HTMLBuilder {
  // We'll use these typealiases to make the lifting rules clearer in this example.
  // Function builders don't really require these to be specific types that can
  // be named this way!  For example, Expression could be "either a String or an
  // HTMLNode", and we could just overload buildExpression to accept either.
  // Similarly, Component could be "any Collection of HTML", and we'd just have
  // to make buildBlock et al generic functions to support that.  But we'll keep
  // it simple so that we can write these typealiases.

  // Expression-statements in the DSL should always produce an HTML value.
  typealias Expression = HTML

  // "Internally" to the DSL, we'll just build up flattened arrays of HTML
  // values, immediately flattening any optionality or nested array structure.
  typealias Component = [HTML]

  // Given an expression result, "lift" it into a Component.
  //
  // If Component were "any Collection of HTML", we could have this return
  // CollectionOfOne to avoid an array allocation.
  static func buildExpression(_ expression: Expression) -> Component {
    return [expression]
  }

  // Build a combined result from a list of partial results by concatenating.
  //
  // If Component were "any Collection of HTML", we could avoid some unnecessary
  // reallocation work here by just calling joined().
  static func buildBlock(_ children: Component...) -> Component {
    return children.flatMap { $0 }
  }

  // We can provide this overload as a micro-optimization for the common case
  // where there's only one partial result in a block.  This shows the flexibility
  // of using an ad-hoc builder pattern.
  static func buildBlock(_ component: Component) -> Component {
    return component
  }
  
  // Handle optionality by turning nil into the empty list.  
  static func buildOptional(_ children: Component?) -> Component {
    return children ?? []
  }

  // Handle optionally-executed blocks.
  static func buildEither(first child: Component) -> Component {
    return child
  }
  
  // Handle optionally-executed blocks.
  static func buildEither(second child: Component) -> Component {
    return child
  }
}
```

Next, we need to adjust our convenience functions to use it:

```swift
func body(@HTMLBuilder makeChildren: () -> [HTML]) -> HTMLNode {
  return HTMLNode(tag: "body", attributes: [:], children: makeChildren())
}
func division(@HTMLBuilder makeChildren: () -> [HTML]) -> HTMLNode { ... }
func paragraph(@HTMLBuilder makeChildren: () -> [HTML]) -> HTMLNode { ... }
```

Now we can go back to the example code and see how the transformation acts on a small part of it:

```swift
division {
  if useChapterTitles {
    header1(chapter + "1. Loomings.")
  }
  paragraph {
    "Call me Ishmael. Some years ago"
  }
  paragraph {
    "There is now your insular city"
  }
}
```

The transformation proceeds one-by-one through the top-level statements of the closure body passed to `division`.

For the `if` statement, we see that there are two cases: the “then” case and the implicit “else” case.  The first produces a result (because it has a non-assignment expression-statement), the second does not.  We apply the recursive transformation to the “then” case:

```swift
  if useChapterTitles {
    let v0: [HTML] = HTMLBuilder.buildExpression(header1(chapter + "1. Loomings."))
    // combined result is HTMLBuilder.buildBlock(v0)
  }
```

We're not using an injection tree because this is a single `if` without an `else`:

```swift
  var v0_opt: [HTML]?
  if useChapterTitles {
    let v0: [HTML] = HTMLBuilder.buildExpression(header1(chapter + "1. Loomings."))
    v0_opt = v0
  }
  let v0_result = HTMLBuilder.buildOptional(v0_opt)
  // partial result is v0_result
```

The two calls to `paragraph` happen to involve arguments which are also transformed blocks; we'll leave those alone for now, but
suffice it to say that they'll also get transformed in time when the type-checker gets around to checking those calls.  These are just non-assignment expression-statements, so we just lift them into the `Component` type:

```swift
division {
  var v0_opt: [HTML]?
  if useChapterTitles {
    let v0: [HTML] = HTMLBuilder.buildExpression(header1(chapter + "1. Loomings."))
    v0_opt = v0
  }
  let v0_result = HTMLBuilder.buildOptional(v0_opt)
  
  let v1 = HTMLBuilder.buildExpression(paragraph {
    "Call me Ishmael. Some years ago"
  })
  
  let v2 = HTMLBuilder.buildExpression(paragraph {
    "There is now your insular city"
  })
  
  // partial results are v0_result, v1, v2
}
```

Finally, we finish this block with a call to `buildBlock`.  This is the top-level body of the function, but the function builder type doesn't declare `buildFinalResult`, that result is returned directly:

```swift
division {
  var v0_opt: [HTML]?
  if useChapterTitles {
    let v0: [HTML] = HTMLBuilder.buildExpression(header1(chapter + "1. Loomings."))
    v0_opt = v0
  }
  let v0_result = HTMLBuilder.buildOptional(v0_opt)
  
  let v1 = HTMLBuilder.buildExpression(paragraph {
    "Call me Ishmael. Some years ago"
  })
  
  let v2 = HTMLBuilder.buildExpression(paragraph {
    "There is now your insular city"
  })
  
  return HTMLBuilder.buildBlock(v0_result, v1, v2)
}
```

This closure has now been completely transformed (except for the nested closures passed to `paragraph`).

## Type inference

### Function builder bodies
Type inference in function builder bodies follows from the syntactic effects of the function builder transformation.
For example, when applying the function builder to the following closure:

```swift
{
  42
  3.14159
}
```

the function builder transformation produces

```swift
let v1 = 42
let v2 = 3.14159
return Builder.buildBlock(v1, v2)
```

The types for `v1` and `v2` are determined independently by the normal type inference rules to `Int` and `Double`,
respectively, then `buildBlock` can operate on both types to produce the final result of the closure.
However, the type of `buildBlock` cannot have any effect on how the types of `v1` and `v2` are
computed. For example, if the builder contained a `buildBlock` like the following:

```swift
func buildBlock<T>(_ a: T, _ b: T) -> T { ... }
```

Then the call to `buildBlock(v1, v2)` will fail because `Int` and `Double` have different types, even though the integer literal `42` could have been treated as a `Double` if type inference were permitted to propagate information "backward" to affect `v1`.

Note that the first implementation of function builders in Swift 5.1 used a different syntactic transform that *did* allow such backward propagation, e.g.,

```swift
return Builder.buildBlock(42, 3.14159)  // not proposed; example only
```

in which case the `42` would be treated as a `Double`. There are several reasons why allowing such "backward" propagation of type information is undesirable for function builders:
* The type inference model would be different from normal closures or function bodies, which is a divergence that makes the mental model more complicated 
* Type checker performance with moderate-to-large function builder bodies was unacceptable, because backward propagation introduced exponential behavior. The implementation of [one-way constraints](https://github.com/apple/swift/pull/26661) for function builders (which introduced the current behavior) resolved most reported "expression too complex to be solved in a reasonable time" issues with SwiftUI code.

### Inferring function builders from protocol requirements

Most function builder transformations are applied implicitly, without the client of the API writing the name of the function builder. For example, given the following API:

```swift
func paragraph(@HTMLBuilder makeChildren: () -> [HTML]) -> HTMLNode { ... }
```

The function builder `HTMLBuilder` is applied at each call site, implicitly, when the closure argument is matched to the parameter that has a function builder attribute:

```swift
paragraph {
  "Call me Ishmael. Some years ago"
}
```

Most function declarations are standalone, so only the explicit function builder annotation can enable the transformation. However, function builder DSLs like SwiftUI tend to have a central protocol to which many different types conform. A typical SwiftUI view might look something like this:

```swift
struct ContentView: View {
  @ViewBuilder var body: some View {
    Image(named: "swift")
    Text("Hello, Swift!")
  }
}
```

Nearly every `body` for a SwiftUI view can use `@ViewBuilder`, because `body` defines a `View`, and those are best built with a `ViewBuilder`. To eliminate the boilerplate from writing `@ViewBuilder` on each, one can annotate `body` with `@ViewBuilder` in the `View` protocol itself:

```swift
protocol View {
  associatedtype Body: View
  @ViewBuilder var body: Body { get }
}
```

When a `View`-conforming type defines it's `body`, the `@ViewBuilder` attribute is inferred from the protocol requirement it satisfies, implicitly applying the function builder transform. This inferred occurs unless:
* The function or property already has a function builder attribute explicitly written on it, or
* The body of the function or property getter contains an explicit `return` statement.

### Implicit memberwise initializer

Function builders are designed with composition in mind, and it is common to have a number of small structures that use function builders to describe their child content. For example, a custom VStack in SwiftUI might look like this:

```swift
struct CustomVStack<Content: View>: View {
    let content: () -> Content

    var body: some View {
        VStack {
            // custom stuff here
            content()
        }
    }
}
```

However, this custom VStack doesn't work with function builder syntax without writing an initializer to introduce the `@ViewBuilder` attribute:

```swift
init(@ViewBuilder content: @escaping () -> Content) {
    self.content = content
}
```

A function builder attribute can be placed on a stored property. This introduces the function builder attribute on the corresponding parameter of the implicit memberwise initializer. In other words, changing the `CustomVStack` definition to the following:

```swift
struct CustomVStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack {
            // custom stuff here
            content()
        }
    }
}
```

implicitly produces the memberwise initializer shown above.

A function builder attribute can also be placed on a stored property whose type does not [structurally resemble function type](https://github.com/apple/swift-evolution/blob/master/proposals/0286-forward-scan-trailing-closures.md#structural-resemblance-to-a-function-type). In this case, the implicit memberwise initializer will have a corresponding function parameter that is a function-builder-attributed  closure returning the property's type, and the body of the initializer will call the function. For example, given:

```swift
struct CustomHStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            // custom stuff here
            content
        }
    }
}
```

the implicit memberwise initializer would have the following definition:

```swift
init(@ViewBuilder content: () -> Content) {
    self.content = content()
}
```

This idea was reported as [SR-13188](https://bugs.swift.org/browse/SR-13188), and the examples are pulled from there.

## Source compatibility

Function builders are an additive feature which should not affect existing source code.

Because some decisions with function builders are implementation-defined, e.g. the structure of the injection tree for `switch` statements, it is possible that certain DSLs will observe differences in behavior across future compiler versions if they are written to observe such differences.

## Effect on ABI stability and API resilience

Function builders are based on compile-time code generation and do not require support from the language runtime or standard library.

Because function builders are essentially a kind of macro system, where the details of expansion are basically an aspect of  the current implementation rather than necessarily a stable interface, library authors are encouraged to make as much as possible inlinable and, if possible, non-ABI.

## Future Directions

There are a number of future directions that could be layered on top of this proposal without compromising its basic design. Several of them are covered here.

### "Simple" function builder protocol

On the Swift forums, @anreitersimon [demonstrated](https://forums.swift.org/t/pitch-2-function-builders/39410/6) the ability to use protocols to make it easier to define new functions builders that support all of the syntax, and for which all expressions have the same type. Their example (slightly tuned) follows. The basic idea is to form a tree describing the result:

```swift
enum Either<T,U> {
  case first(T)
  case second(U)
}

indirect enum FunctionBuilderTerm<Expression> {
    case expression(Expression)
    case block([FunctionBuilderTerm])
    case either(Either<FunctionBuilderTerm, FunctionBuilderTerm>)
    case optional(FunctionBuilderTerm?)
}
```

and then define a `FunctionBuilder` protocol with only a single requirement, `buildFinalResult`, to take all of the values and form the final result:

```swift
protocol FunctionBuilder {
    associatedtype Expression
    typealias Component = FunctionBuilderTerm<Expression>
    associatedtype Return

    static func buildFinalResult(_ components: Component) -> Return
}
```

All of the other `build` functions---to enable `if`, `switch`, and so on---are implemented in an extension of `FunctionBuilder`:

```swift
extension FunctionBuilder {
    static func buildExpression(_ expression: Expression) -> Component { .expression(expression) }
    static func buildBlock(_ components: Component...) -> Component { .block(components) }
    static func buildOptional(_ optional: Component?) -> Component { .optional(optional) }
    static func buildArray(_ components: [Component]) -> Component { .block(components) }
    static func buildLimitedAvailability(_ component: Component) -> Component { component }
}
```

It then becomes possible to define new version builders with only a small amount of code, e.g., here is a builder that flattens the result term into an array:

```swift
@_functionBuilder
enum ArrayBuilder<E>: FunctionBuilder {
    typealias Expression = E
    typealias Return = [E]

    static func buildFinalResult(_ components: Component) -> Return {
        switch components {
        case .expression(let e): return [e]
        case .block(let children): return children.flatMap(buildFinalResult)
        case .either(.first(let child)): return buildFinalResult(child)
        case .either(.second(let child)): return buildFinalResult(child)
        case .optional(let child?): return buildFinalResult(child)
        case .optional(nil): return []
        }
    }
}
```

With some more experience, a facility like this could become part of the standard library.

### Stateful function builders
All of the `build*` functions for a function builder type are defined to be `static`, and no instances of the function builder type are created by the function builder transform. However, the transform could create an instance of the function builder type at the beginning of the transformed function, then call `build*` instance methods on it. For example, this code adapted from [Constantino Tsarouhas](https://forums.swift.org/t/pitch-2-function-builders/39410/67)):

```swift
struct Heading<Content : Element> : Element {
    init(@ElementBuilder(containerStyle: .inline) content: () -> Content) { … }
}

Heading {
  Text("Loomings")
  Text("Call me Ishmael. Some years ago")
}
```

would be translated as:

```swift
Heading {
  var builder = ElementBuilder(containerStyle: .inline)
  let v0 = builder.buildExpression(Text("Loomings"))
  let v1 = builder.buildExpression(Text("Call me Ishmael. Some years ago"))
  let v2 = builder.buildBlock(v0, v1)
  return builder.buildFinalResult(v2)
}
```

The introduction of stateful function builders would be a pure extension. However, the same effect can be achieved by the "simple function builder protocol" described above, so it is not clear that this facility belongs in the language.

### Transforming declarations

Function builders leave all declaration statements unmodified. However, some DSLs might want to incorporate declarations, notifying the builder of such declarations so it can incorporate them. Here's an abstracted example based on one [provided by Konrad Malawski](https://forums.swift.org/t/function-builders-and-including-let-declarations-in-built-result/37184):

```swift
Definition {
  Thing {
    // "import" the Def people, in order to be able to use it in this Thing
    // there may be many Defs, but this Thing only uses people
    let people = Defs.people // <1>
    let other = Def.otherThings // <2>

    show {
      people.name // <1>
      people.surname // <1>
      other.information // <2>
    }
    filter {
      equals(people.age, 42)
    }
}
```

The builder could be informed of each `let` declaration, allowing it to produce a partial result, e.g., the innermost `Thing` could be transformed to:

```swift
let people = Defs.people
let v0 = ThingBuilder.buildDeclaration(people)
let other = Def.otherThings
let v1 = ThingBuilder.buildDeclaration(other)

let v2 = <result of translating show expression>
let v3 = <result of transalation filter expression>
let v4 = ThingBuilder.buildBlock(v0, v1, v2, v3)
```

Such DSLs would not be change the way declarations are type checked, but would have the option to produce partial results for them, which could further eliminate boilerplate. On the other hand, without this feature one can freely use `let` to pull out subexpressions and partial computations without changing the code. For example, today one expects to be able to refactor

```swift
a.doSomething().doSomethingElse()
```

into

```swift
let b = a.doSomething()
b.doSomethingElse()
```

without changing semantics. That would no longer be the case for function builders that opt in to this feature by providing `buildDeclaration`.

### Virtualized Abstract Syntax Trees (ASTs)

The function builder model executes the transformed function directly, collecting the partial results that get passed into the builder. Some DSLs might prefer to "virtualize" the structure of the transformed function, such that the DSL can determine how the evaluation happens. A simple form of this can be achieved by using escaping autoclosures in `buildExpression:`:

```swift
typealias DelayedValue = () -> Any

static func buildExpression(_ value: @autoclosure @escaping () -> Any) -> DelayedValue {
  return value
}
```

Here, the partial results provided to other build functions (e.g., `buildBlock`) will be functions that produce the value. The DSL is free to call those functions whenever it wants to produce the values.

However, virtualizing any kind of control flow would require a new kind of build function that describes more of the structure of the AST. For example, consider a `for..in` loop:

```swift
for person in employees {
  "Hello, \(person.preferredName)"
}
```

Function builders currently will execute all iterations of the loop. Virtualizing the execution means passing along the means to execute the loop to the function builder, e.g., via a `buildVirtualFor` operation:

```swift
Builder.buildVirtualFor(employees, { person in
  let v0 = Builder.buildExpression("Hello, \(person.preferredName)")
  return Builder.buildBlock(v0)
}
```

The builder's `buildVirtualFor` would have a signature such as:

```swift
static func buildVirtualFor<S: Sequence, T>(_ sequence: S, @escaping (S.Element) -> T) -> ForEach<S, T> { ... }
```

Such a facility could be used to map the language's `for..in` syntax to a lazily-evaluated construct like SwiftUI's [`ForEach`](https://developer.apple.com/documentation/swiftui/foreach). Similar builder functions would need to be developed for each supported syntax, e.g., `if` statements where the condition and then/else blocks are provided via closures.

Virtualized ASTs would be a powerful extension to function builders. However, they will require an additional set of builder functions that match more closely with the syntax of the function being transformed.

## Alternatives considered

### Additional control-flow statements
The set of statements that are permitted within a transformed function are intentionally limited to those that are "strictly structural", and could reasonably be thought of as being part of a single, functional expression, aggregating values but without complicated control flow. However, one could go beyond this model to accept additional statements in a transformed function:

* Local control flow statements that aren't “strictly structural”, like `break`, `continue`, and `do/catch`, could be handled by treating subsequent partial results as optional, as if they appeared within an `if`.
* Iteration statements other than `for`..`in` (i.e., `while` and `repeat`..`while`) could be supported via `buildArray`.

Support for additional control-flow statements would weaken the declarative feel of function builders, and makes the "tree" structure of the DSL harder to reason about.

It has been suggested that there could be two "forms" of function builders, one that matches the design in this proposal and a second, "simpler" one that handles the full breadth of the statement grammar (including all loops, `break`, `continue`, and so on) but sees only the partial results (e.g., via `buildExpression`) and not the structure (`buildBlock`, `buildEither(first:)`, etc. would not get called). The "simple function builder protocol" described above illustrates how one can get the second part of this--defining a simple function builder that receives all of the values without the structure--by building on top of this proposal. However, we should not have two forms of function builders in the language itself, with different capabilities, because it leads to confusion. If function builders gain support for additional control-flow statements (as a general feature), that should be reflected in the "simple function builder protocol" to extend the feature set for function builders that don't want the structure.

### Builder-scoped name lookup
It is common for DSLs to want to introduce shorthands which might not be unreasonable to introduce into the global scope.  For example, `p` might be a reasonable name in the context of our `HTMLBuilder` DSL (rather than `paragraph`), but actually introducing a global function named `p` just for DSL use is quite unfortunate.  Contextual lookups like `.p` will generally not work at the top level in DSLs because they will be interpreted as continuations of the previous statement. One could imagine having some way for the DSL to affect lexical lookup within transformed functions so that, e.g., within the transformed function one could use short names like `p`, `div`, and `h1`:

```swift
return body {
  let chapter = spellOutChapter ? "Chapter " : ""
  div {
    if useChapterTitles {
      h1(chapter + "1. Loomings.")
    }
    p {
      "Call me Ishmael. Some years ago"
    }
    p {
      "There is now your insular city"
    }
  }
}
```

which are defined in the function builder type itself, e.g.,

```swift
extension HTMLBuilder {
  static func body(_ children: [HTML]) -> HTMLNode { ... }
  static func div(_ children: [HTML]) -> HTMLNode { ... }
  static func p(_ children: [HTML]) -> HTMLNode { ... }
  static func h1(_ text: String) -> HTMLNode { ... }
}
```

Name lookup that doesn't find the names `p`, `div`, or `h1` within the closure would look into the function builder being used to transform the closure before continuing lexical name lookup.

Note that one can simulate this kind of effect by following the common pattern set out by SwiftUI, where the transformed function is usually within a type that conforms to some common protocol. For example, if we were to always say that HTML documents are types that conform to an `HTMLDocument` protocol, like this:

```swift
protocol HTMLDocument {
  @HTMLBuilder var body: HTML { get }
}

struct MobyDick: HTMLDocument {
  var body: HTML {
    let chapter = spellOutChapter ? "Chapter " : ""
    div {
      if useChapterTitles {
        h1(chapter + "1. Loomings.")
      }
      p {
        "Call me Ishmael. Some years ago"
      }
      p {
        "There is now your insular city"
      }
    }
  }
}
```

Here, one can put the shorthand names (or, indeed, everything defined for the DSL) into an extension of the protocol:

```swift
extension HTMLDocument {
  static func body(_ children: [HTML]) -> HTMLNode { ... }
  static func div(_ children: [HTML]) -> HTMLNode { ... }
  static func p(_ children: [HTML]) -> HTMLNode { ... }
  static func h1(_ text: String) -> HTMLNode { ... }
}
```
