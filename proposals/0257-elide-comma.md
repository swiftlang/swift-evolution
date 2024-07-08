# Eliding commas from multiline expression lists

* Proposal: [SE-0257](0257-elide-comma.md)
* Author: [Nate Chandler](https://github.com/nate-chandler), [Matthew Johnson](https://github.com/anandabits)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Returned for revision**
* Implementation: [apple/swift#21876](https://github.com/apple/swift/pull/22714)
* Review: ([previous pitch 1](https://forums.swift.org/t/se-0084-spinoff-newlines-as-item-separators/2659)) ([previous pitch 2](https://forums.swift.org/t/trailing-commas-in-all-expression-lists/19527)) ([pitch](https://forums.swift.org/t/pitch-eliding-commas-from-multiline-expression-lists/22558)) ([review](https://forums.swift.org/t/se-0257-eliding-commas-from-multiline-expression-lists/22889)) ([returned for revision](https://forums.swift.org/t/se-0257-eliding-commas-from-multiline-expression-lists/22889/191))

# Introduction

Swift requires a semicolon "`;`" to separate statements unless those statements are separated by newlines, in which case the semicolon can be elided.  Currently, Swift requires a comma "`,`" to separate expressions even when those statements are separated by newlines.  We should ease this restriction, allowing the comma between two expressions to be elided when they are separated by a newline.

* Implementation: [apple/swift#21876](https://github.com/apple/swift/pull/22714)
* Previous Pitch: [SE-0084 spinoff: Newlines as item separators](https://forums.swift.org/t/se-0084-spinoff-newlines-as-item-separators/2659)

## Reducing visual clutter

When writing a list of expressions, you insert commas to tell the compiler where one expression ends and the next begins.  When you add a newline between the expressions, though, you provide that same information by way of the newline characters.  When newlines are present, commas provide clarity neither to human readers nor to the compiler.

In these cases, at best, commas can be overlooked by human readers.  At worst, they cause visual clutter and obscure the meaning you are trying to communicate in our code.  Consider the following sample, taken from [Alamofire](https://github.com/Alamofire/Alamofire/blob/4df5912df4ebb138454aeba78f1470acc52dd4ae/Source/Request.swift#L649-L655):

```swift
let protectionSpace = URLProtectionSpace(
    host: host,
    port: url.port ?? 0,
    protocol: url.scheme,
    realm: host,
    authenticationMethod: NSURLAuthenticationMethodHTTPBasic
)
```

The commas here are not communicating anything.  The writer has to put them in, the compiler has to observe that they're there and move along, and the reader has to filter them out.  They're noise for all parties involved.  Compare that to the following:

```swift
let protectionSpace = URLProtectionSpace(
    host: host
    port: url.port ?? 0
    protocol: url.scheme
    realm: host
    authenticationMethod: NSURLAuthenticationMethodHTTPBasic
)
```

The difference is small, but significant:
1. **There are no spurious characters between the parentheses**.  You are presented with a list of the names of the ingredients being used to construct the `URLProtectionSpace` on the left hand side of the colons and on the right hand side you see the values which are serving as those ingredients.  
2. **The lines are symmetric**.  the last line, lacking a comma, looks no different from the others, because they all lack a comma.
3. **Each line stands on its own**.  Because they appear in single line argument lists, a comma at the end of a line has the effect of drawing your eye down to the next line.  Without the commas, you have a moment to breathe at the end of the line, maybe to glance back at the argument label before moving on to the next line.

Let's take a look at a couple more examples.

To begin with, let's look at constructing another [type](https://github.com/apple/swift/blob/master/benchmark/utils/DriverUtils.swift#L59-L98) which takes many arguments.  Here it is with commas:

```swift
let config = TestConfig(
  delim: "abc",
  sampleTime: 42.0,
  numIters: nil,
  numSamples: nil,
  quantile: nil,
  delta: true,
  verbose: false,
  logMemory: true,
  afterRunSleep: nil
)
```

and without:

```swift
let config = TestConfig(
  delim: "abc"
  sampleTime: 42.0
  numIters: nil
  numSamples: nil
  quantile: nil
  delta: true
  verbose: false
  logMemory: true
  afterRunSleep: nil
)
```

Once again, the result is cleaner.  All the characters that you see are relevant and meaningful.  Each line you see is like the others.  You're not drawn from one line to the next by the comma, you're free to scan through the items at your leisure.

These same improvements are visible in expression lists besides the arguments to an initializer.  Consider the following [function calls](https://github.com/apple/swift/blob/master/benchmark/single-source/StringComparison.swift), first with commas:

```swift
StringTests.test("AssociatedTypes-UTF8View") {
  typealias View = String.UTF8View
  expectCollectionAssociatedTypes(
    collectionType: View.self,
    iteratorType: View.Iterator.self,
    subSequenceType: Substring.UTF8View.self,
    indexType: View.Index.self,
    indicesType: DefaultIndices<View>.self)
}

StringTests.test("AssociatedTypes-UTF16View") {
  typealias View = String.UTF16View
  expectCollectionAssociatedTypes(
    collectionType: View.self,
    iteratorType: View.Iterator.self,
    subSequenceType: Substring.UTF16View.self,
    indexType: View.Index.self,
    indicesType: View.Indices.self)
}
```

and then without:


```swift
StringTests.test("AssociatedTypes-UTF8View") {
  typealias View = String.UTF8View
  expectCollectionAssociatedTypes(
    collectionType: View.self
    iteratorType: View.Iterator.self
    subSequenceType: Substring.UTF8View.self
    indexType: View.Index.self
    indicesType: DefaultIndices<View>.self)
}

StringTests.test("AssociatedTypes-UTF16View") {
  typealias View = String.UTF16View
  expectCollectionAssociatedTypes(
    collectionType: View.self
    iteratorType: View.Iterator.self
    subSequenceType: Substring.UTF16View.self
    indexType: View.Index.self
    indicesType: View.Indices.self)
}
```

The difference is subtle but striking.

## Making domain-specific languages first-class

One case where the problem of visual clutter is especially pronounced is in domain-specific languages embedded (EDSLs) within Swift.  Particularly when those EDSLs are "declarative".

Consider an EDSL for specifying a table in a database:

```swift
let table = Table(
    name: "Employees",
    columns: 
        guid ("record_id", isPrimaryKey: true, nullable: false),
        guid ("manager_id", isPrimaryKey: false, nullable: true),
        string ("name", length: 1024, nullable: false),
        int64 ("employee_id", nullable: false),
        date ("start_date", nullable: false)
)
```

Beyond merely defining a table, the intent is to do so in a way that feels natural in this context, to define a table "in its own terms".  The majority of defining the table is taken up providing a list of columns, declaring them type first, in C style.

The corresponding declaration in native Swift would look something like this:

```swift
let recordID = SQLGUIDColumn(isPrimaryKey: true, nullable: false);
let managerID = SQLGUIDColumn(isPrimaryKey: true, nullable: true);
let name = SQLStringColumn(length: 1024, nullable: false);
let employeeID = SQLInt64Column(nullable: false);
let startDate = SQLDateColumn(nullable: false);
```

Note in particular the use of semicolons at the end.  While the semicolons are not a huge problem, they are unpleasant.  The main reason that they are unpleasant is that they are superfluous.  We are merely going through some ceremony that is of service to nobody: not the writer, not the reader, and not the compiler.  For that reason, semicolons are not required to end statements that are terminated by line endings in Swift.  Instead, Swift allows you to write

```swift
let recordID = SQLGUIDColumn(isPrimaryKey: true, nullable: false)
let managerID = SQLGUIDColumn(isPrimaryKey: true, nullable: true)
let name = SQLStringColumn(length: 1024, nullable: false)
let employeeID = SQLInt64Column(nullable: false)
let startDate = SQLDateColumn(nullable: false)
```

The situation with definition of the table in the EDSL is the same.  The commas are providing information to nothing and nobody.  They are ceremony for its own sake.  Moreover, they are a constant visual reminder that you are looking at a list of arguments being passed to a function rather than a list of declarations in the EDSL.

Just as Swift allows semicolons to be omitted, it should also allow the commas to be omitted, permitting

```swift
let table = Table(
    name: "Employees"
    columns:
        guid ("record_id", isPrimaryKey: true, nullable: false)
        guid ("manager_id", isPrimaryKey: false, nullable: true)
        string ("name", length: 1024, nullable: false)
        int64 ("employee_id", nullable: false)
        date ("start_date", nullable: false)
)
```

With the commas present, the reader is saddled with a constant reminder that she is "just" reading a list of arguments, not language uses that stand on their own.  Once they are removed, the author can express her intent directly, that the table is defined by a series of declarations, *not* by passing a series of arguments to a function.  That fact, while still visible, is reduced from its current overbearing status to an implementation detail of the EDSL.

Without the commas, each column can be viewed as intended: *as a **declaration** in the EDSL*.

By allowing statement separators to be omitted when a newline is present while requiring expression separators Swift exhibits a subtle bias, making imperative code look clean where declarative code must be cluttered with punctuation. By providing the same affordance for declarative style, this bias towards imperative style is lifted, allowing declarative EDSLs to feel just as natural as imperative Swift code.

This example EDSL is not taken from a real library.  There are, despite the current limitation, many shipping Swift libraries that make extensive use of EDSLs.  Let's take a look at the EDSLs from those in several different domains to see how they would be improved by comma elision:

### Networking EDSL case study: HTTP Requests

HTTP requests are pervasive in modern applications.  To avoid dealing directly with networking-layer API, higher-level abstractions are often used to specify requests.  Here's an example taken from some real-world code:

```swift
Request(
    method: .get,
    host: .someHost,
    path: "/path/to/model",
    query: [
         "page": 10,
         "order": "ascending",
    ]
)
```

A request is specified by a series of declarations.  The request will use the GET verb.  It will be made against `someHost` at "/path/to/model".  The content should be ordered ascending and there should be ten entities per page.  

The commas here add no value.  At the least, they are line noise.  At worst, they obscure the fact that there is a series of declarations, forcing the reader back into viewing the each line as *just* an argument to an initializer.

Here's the same code without commas:

```swift
Request(
    method: .get
    host: .someHost
    path: "/path/to/model"
    query: [
         "page": 10
         "order": "ascending"
    ]
)
```

As you read the code, first you see that a Request is being initialized.  In that context, you see a number of declarations about the request, that it uses the GET verb and so on.  The elision of commas allows you to focus on what's important, the declarations that make up the definition of the `Request`.  You are not constantly reminded that each line is an argument passed to an initializer but are instead free to think of each as a declaration in the language in which HTTP requests are specified.

### App Routing EDSL case study: Jason Prasad's Routing library

The [routing](https://github.com/jjgp/Routing) library provides a convenient API for specifying which screen of an app should be displayed when the app is launched via a URL.  Here's an example usage taken from the project's README:

```swift
router.map("routingexample://present/login",
           source: .storyboard(storyboard: "Main", identifier: "LoginViewController", bundle: nil),
           style: .inNavigationController(.present(animated: true)),
           setup: presentationSetup)
```

This code specifies that when the app is launched with the `present/login` path, the `LoginViewController` from the `Main` storyboard will be presented in a navigation controller.

Here's how that code looks without commas and with newlines added instead:

```swift
router.map(
    "routingexample://present/login"
    source: .storyboard(name: "Main"
                        identifier: "LoginViewController"
                        bundle: nil)
    style: .inNavigationController(.present(animated: true))
    setup: presentationSetup
)
```

Without the commas, and with newlines added to the storyboard example, the code looks much cleaner.  Moreover, while in Swift an instance of the `ControllerSource` enum is being instantiated via the `.storyboard` implicit member access, in this code snippet, you are free to ignore those mechanics and focus instead on the declaration of a location from which to obtain a view controller in a storyboard named "Main" under the identifier "LoginViewController".

## Improving the editing experience

Another, more minor point is that commas in these positions cause problems when editing code.  In Swift today, you can easily add or remove any item--even the last--from a collection literal by commenting it in or out:

```swift
let colors = [
    "red",
    "green",
    "blue",
//    "cerulean"
]
```

Unfortunately that convenience is not available fully in the other expression lists.  For example, in a multiline function call, it is a breeze to comment out any argument

```swift
print(
    "red",
//    "green", // ok
    "blue",
    "cerulean"
)
```

*except* the last; commenting it out raises an error:


```swift
print(
    "red",
    "green",
    "blue", // error: unexpected ',' separator
//    "cerulean"
)
```

The reason for these inconsistent behaviors is that trailing commas are permitted in collection literals but not in any other expression list.

One solution would be to allow trailing commas in all expression lists.  That change, however, only addresses part of the problem.  The visual noise that the commas cause not only remains but is magnified: to get this convenience, we would be incentivized to write our code with trailing commas in all multiline expression lists.

Instead, we should allow commas to be elided from multiline expression lists entirely.  Without commas, the original function call would instead look like

```swift
print(
    "red"
    "green"
    "blue"
    "cerulean"
)
```

with its arguments untarnished by commas.  We would be free to comment out any line of it, including the last

```swift
print(
    "red"
    "green"
    "blue"
//    "cerulean"
)
```

because what remains is again a multiline expression list with commas elided.

## Proposed solution

Rather than allowing comma elision in just some expression lists in an ad hoc fashion, this document proposes allowing commas to be elided uniformly in all multiline expression lists.

### When will you still use commas?

When parsing an expression, the compiler keeps going until it can't any longer, following the [maximal munch](https://en.wikipedia.org/wiki/Maximal_munch) principle.  Sometimes, though, you want one expression to end and the next to begin before the parser would otherwise stop.  In those situations, you will use a comma to communicate that intent.

There are two scenarios where you will use commas to clarify that one expression is ending and the next is beginning:

#### Implicit members

When parsing a multiline expression list featuring a member expression which appears after a newline

```swift
foo(
    bar
    .baz
)
```

the member expression will be interpreted as modifying the expression that preceded it

```swift
foo(bar.baz)
```

rather than as a separate expression

```swift
foo(bar, .baz)
```

If you actually want `.baz` to be as an implicit member, an expression in its own right, you will add a comma:

```swift
foo(
    bar,
    .baz
)
```

##### Diagnostics

When this situation comes up, the issue can be ameliorated via a good diagnostic experience.  If you attempt to compile the original function call

```swift
foo(
    bar
    .baz
)
```

in a context where `baz` is not an instance member of `bar`'s type but is a static member of the type of the second parameter accepted by `foo`

```swift
enum E {
    case baz
}

func foo(_ bar: Bar, _ e: E) {...}
```

the error can be diagnosed with a fixit to insert a comma at the end of the line before `.baz`, right after `bar`, leaving you with the code you intended:

```swift
foo(
    bar,
    .baz
)
```

If you attempt to compile the original function call

```swift
foo(
    bar
    .baz
)
```

in a context where both `foo(bar.baz)` and `foo(bar, .baz)` are legal, a warning can be emitted with several fixits to clarify the intent by doing one of the following:

1. inserting a comma

```swift
foo(
    bar,
    .baz
)
```

2. eliminating the newline

```swift
foo(
    bar.baz
)
```

3. indenting the second expression

```swift
foo(
    bar
        .baz
)
```

as is suggested today for an expression on the line after the `return` keyword at its same indentation level.

#### Closures

In a similar vein, when parsing a multiline expression list featuring a closure which appears after a newline

```swift
foo(
    bar
    { print("baz") }
)
```

the closure will be interpreted as a trailing closure passed as an argument to the expression that preceded it.

```swift
foo(bar { print("baz") })
```

rather than as a separate expression

```swift
foo(bar, { print("baz") }
```

If you actually want the closure to stand on its own, to be its own expression, you will add a comma to separate it from the preceding expression.

```swift
foo(
    bar,
    { print("baz") }
)
```

##### Diagnostics

As with implicit members, we will be able to provide a good diagnostic experience here including both

1. an error with a fixit to insert a comma before the closure which is being parsed as a trailing closure in the case where using the closure as a trailing closure doesn't typecheck
2. a warning with multiple fixits to insert a comma or change whitespace in the case where the closure could be used both as a trailing closure and as a top level expression in the list

#### Alternatives to adding commas

These situations may sound familiar--they are exactly the same situations where we need to use semicolons to separate items in statement lists, even in the presence of newlines.  In practice, you will need to use commas more often than semicolons because it is more often for these expressions to appear in expression lists than in statement lists.  

That said, you will need to use them less often than it might at first seem.  

Consider closures:  Trailing closure syntax means that most of the time, closures appear after the end of the expression list.  Typically, the above example would actually be written

```swift
foo(
    bar
)
{ 
    print("baz") 
}
```

What about implicit members?  Consider a function call like this: 

```swift
buyTreat(
    .sweet
    .orange
)
```

This would be parsed as `.sweet.orange`, which may not be what you want.  Even to a human, reader, though, it's not clear what is meant.  To make code obvious to readers, you often use argument labels (`flavor: .orange`) to provide a hint to readers of what the implicit member may be a member of:  

```swift
buyTreat(
    .sweet
    flavor: .orange
)
```

If you would prefer to leave out an argument label, you could also provide the type `Flavor.orange` in order to provide a reader with that context:  

```swift
buyTreat(
    .sweet
    Flavor.orange
)
```

If you don't want to use either of those approaches, only then will you end the prior expression with a comma.

Without this change, you are forced to use commas everywhere.  In multiline expression lists, they are reduced to line noise and meaninglessness.  A comma is a character to be ignored.  With this change, if you omit commas whenever possible, when you write a comma, you will mean something: "without this, the previous expression would keep going; I want it to end here."

## Detailed design

Swift will allow the comma separating two expressions in an expression list to be elided provided that there is a newline separating the expressions.

The grammatical productions from The Swift Programming Language will be modified as follows:

<pre>
expression-list -> expression | expression , expression-list <b>| expression \n expression-list </b>
function-call-argument-list -> function-call-argument | function-call-argument , function-call-argument-list <b>| function-call-argument \n function-call-argument-list</b>
tuple-element-list -> tuple-element | tuple-element , tuple-element-list <b>| tuple-element \n tuple-element-list</b>
</pre>

With these few changes to the grammatical productions, comma elision will be accepted in the following positions:

- array literals
```swift
[
    "red"
    "green"
]
```
- dictionary literals
```swift
[
    "red" : 4
    "green" : 8
]
```
- free function calls
```swift
print(
    "red"
    "green"
)
```
- method calls
```swift
foo.print(
    "red"
    "green"
)
```
- initializer calls
```swift
let instance = Widget(
    "red"
    "green"
)
```
- subscript reads
```swift
foo[
    "red"
    "green"
]
```
- subscript writes
```swift
foo[
    "red"
    "green"
] = "yellow"
```
- super method calls
```swift
super.print(
    "red"
    "green"
)
```
- super initializer calls
```swift
super.init(
    "red"
    "green"
)
```
- super subscript reads
```swift
super[
    "red"
    "green"
]
```
- super subscript writes
```swift
super[
    "red"
    "green"
] = "yellow"
```
- enum instantiations
```swift
let e = E.foo(
    "red"
    "green"
)
```
- tuple instantiations
```swift
let t = (
    "red"
    "green"
)
```
- key-path subscripts
```swift
let path = \Gadget[
    0
    1
]
```

## Source compatibility

This is not a source-breaking change.  Extensive compatibility tests have been run against the change.

This document does *not* propose removing commas from the language.  All code that is legal today will continue to be legal.  This document proposes easing a restriction, making more code legal.

@blangmuir looked into SourceKit's under the change and determined everything just works without any other changes.  Autocomplete continues to function as before.

Because statement separator (i.e. semicolon) elision has been in the language for so long, all the engineering problems for expression separator (i.e. comma) elision have already been solved.

## Effect on ABI stability

N/A

## Effect on API resilience

N/A

## Alternatives considered

- Allow trailing commas in expression lists.

While trailing commas in expression lists would provide the same improvements in the editing experience that comma elision does, they do not bring the same readability improvements to the language as comma elision.

- Base interpretation of arguments off of semantic information.

The two cases where commas will still be written listed above may seem less than ideal.  It is tempting to ask whether we could decide the number of expressions in the expression list based on the context in which it appears.  Swift does not currently do this sort of interpretation based on semantic information and doing so massively complicates the language.

