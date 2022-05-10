# Swift Snippets

* Proposal: [SE-0356](0356-swift-snippets.md)
* Authors: [Ashley Garland](http://github.com/bitjammer)
* Review Manager: [Tom Doron](https://github.com/tomerd)
* Status: **Active Review (May 2 – May 16 2022)**
* Implementation:
    Available in [recent nightly](https://swift.org/download/#snapshots) snapshots. Requires `--enable-experimental-snippet-support` feature flag when using the [Swift DocC Plugin](https://github.com/apple/swift-docc-plugin). Related pull requests:
    * Swift DocC
        * [Add snippet support](https://github.com/apple/swift-docc/pull/61)
    * Swift Package Manager: 
        * [Introduce the snippet target type](https://github.com/apple/swift-package-manager/pull/3694)
        * [Rename _main symbol when linking snippets](https://github.com/apple/swift-package-manager/pull/3732)
    * SymbolKit:
        * [Add snippet mixin for symbols](https://github.com/apple/swift-docc-symbolkit/pull/10)
        * [Add .snippet and .snippetGroup kind](https://github.com/apple/swift-docc-symbolkit/pull/15)
    * Swift DocC Plugin
        * [Swift DocC Plugin Snippets](https://github.com/apple/swift-docc-plugin/pull/7)
* Review threads
    * [Pitch](https://forums.swift.org/t/pitch-swift-snippets/56348)
    * [Review](https://forums.swift.org/t/se-0356-swift-snippets/57097)
    

## Introduction

This proposal describes a convention for writing a new form of sample code called *snippets*. Snippets are short, single-file examples that can build and run from within a Swift package, with access to other code within that package, and can be used in a variety of ways.

## Motivation

There are two main vehicles people employ when they want to use code to demonstrate an idea or API:

* Complete sample projects
* Bits of code displayed inline within documentation

Both of these are critical tools, and snippets aren’t intended to replace either of them. Instead, snippets offer an additional method for teaching with code, that fits somewhere between both ideas. First, let’s look at the current options available to most developers.

### Sample code projects

Sample code is often created as a full project with build configuration files, resources, and multiple source files to produce a finished “app”. These sample projects are useful when you want to show code in a specific, complete scenario. However, these projects also tend to be a lot of effort to create and maintain. For this reason, developers often simply don’t build great samples. 

Because sample code projects require more time and effort, they tend to become "kitchen sink" examples that show anything and everything around a particular topic, or grow to exemplify multiple topics and libraries. Not only does this make the project increasingly difficult to maintain, it also makes it more difficult for a reader to navigate and find the gems that may be hidden in a sample code project.

### Code listings within documentation

Code listings are generally presented as a few lines of code printed inline within larger bits of documentation prose, most often carved out in a small “code box” area. This code is generally authored right along side the prose by a writer, in their favorite word processor. While these bits of code are incredibly helpful while reading the documentation — often this is the best sort of documentation — there are downsides, too.

**Code listings tend to go stale .** Code listings, once put into the documentation, tend to be treated as regular text. The code isn’t built regularly, and may not be revisited by the author for a long period of time. Over time, changes to the programming language or APIs can easily make code listings go stale and stop compiling successfully. A larger documentation team may build bespoke systems to extract and test this code — time better spent writing great new documentation. Making it easy to add code listings to documentation that can also be built and run (and validated) is one of the main goals of snippets.

**Code listings don't get good editor support.** As most code listings are typed into an editor focused on writing prose, the author misses out on the coding features typically available in a code editor or IDE. Missing inline error checking and syntax highlighting means it is much more likely the code sample will have an error.

**Code listings tend to be more like pseudocode.**  This happens because the author knows they aren’t actually building running code, and all the explanation for the code happens in the surrounding prose. This results in code that is much less useful for the reader to copy into their own projects.

### Snippets combine the best of both

Snippets are designed to provide some of the best features of each of the above approaches. Each snippet is a single file, making it easy to think about as an author and as a reader, but it is also a fully valid program. Each snippet can access the full code and features of the rest of the package, so behavior can be powerful, while the code in each snippet remains simple. This means the code should also be small enough to present inline within documentation — perfect to act as a code listing. This code is able to be tested and maintained as fully-functional code ready to be copied and used by the reader.

Snippets fill a gap in the spectrum of example-oriented documentation, shown below roughly in decreasing granularity:

* **API reference and inline code fragments.** Not typically compilable, these usually occur in lists, an index, or perhaps a link to a symbol page. These are not compositional in nature.
* **Snippets.** Here, one file demonstrates one task, composing one or more APIs, across no more than a handful of modules. A snippet should basically be something a reader can copy and paste or use as a starting point. Some examples of a snippet might be:
    * An implementation of a sort algorithm
    * An interesting SwiftUI view hierarchy
    * A quick recipe for displaying a 3D model in a view
    * A struct that demonstrates a Swift Argument Parser option
    * An example of Swift Coding with custom coding keys
    * Many of the examples in [Swift Algorithms’s “Guides”](https://github.com/apple/swift-algorithms/tree/main/Guides)
    * Many StackOverflow answers
* **Full sample projects and tutorials.** Here, a project demonstrates a full application, composing not just one or more APIs, but potentially many technologies or modules. A sample project also demonstrates multiple, potentially independent scenarios. Most developers are already familiar with these.

**Once written, snippets are useful in many contexts.** Both sample projects and inline code listings are written once and meant to be consumed in one particular manner. In contrast, snippets are meant to be written once but read (or even run) anywhere. Snippets are just simple bits of code (but with access to the full package), great for importing within documentation prose, runnable from the command line, or copied and edited within an IDE. 

**Short, focused, single files.** This versatility comes with constraints — snippets should be small and focused, for instance. They should also stand on their own and not require a complex scenario to be understood. With these constraints, snippets can then be easily shuttled around, shown inline in docs, used in interactive code tutorials, run from the command line, quickly gleaned, and provide useful code for a developer to take on the spot. As soon as a snippet feels like it needs multiple files or resources, a traditional sample project starts to become appropriate. But with full access to the rest of the package, it may make sense to group “big” functionality elsewhere in the package, allowing each snippet to remain small, focused, and easily understood.

**The possibility of snippet-only packages.** While sample code projects' strength is their depth in a specific scenario (often application development), packages consisting mostly or entirely of snippets provide breadth. Examples of snippet-only packages might be a collection of recipes for composing UI elements in new and interesting ways, teaching the Swift language snippet by snippet, or providing exercises for a textbook. Again, since snippets get access to the package's shared code libraries, it is possible to demonstrate even powerful concepts in an easy-to-read snippet.

## Proposed Solution

This proposal is a definition of a sample code convention that offers a bite-sized hybrid of sample code and API reference, with a sprinkle of prose: snippets. Snippets are individual `.swift` files that can build and run as executable targets in a Swift package. Each snippet is a complete program, that stands on its own as a token of documentation.

### Writing a snippet

A snippet file might look like the following:

```swift
//! Line comments prefixed with ! will
//! serve as the snippet's short description.

func someCodeToShow() {
    print("Hello, world!")
}

// MARK: HIDE

func someCodeToHide() {
    print("Some demo message")
}

// Still hidden
someCodeToHide()

// MARK: Show
someCodeToShow()
```

At the top is the snippet's description, a short paragraph that may appear with the snippet. `// MARK: Hide` and `// MARK: Show` toggle hiding and showing code when displaying a snippet in documentation or other tools that may support snippets in the future. This lets the author add some additional demo logic when running the snippet while still keeping its presentation clean when it shows up the finished documentation.

The above snippet would end up looking something like this within the docs:

> Line comments prefixed with ! will serve as the snippet's description.
>
> ```swift
> func someCodeToShow() {
>     print("Hello, world!")
> } 
> someCodeToShow()
> ```

This code extracted after resolving hiding markers is known as a snippet’s *presentation code*.

### Getting started

To start adding snippets to a package, first create a `Snippets` directory alongside a package's familiar `Sources` and `Tests` directories. From here, you can start dropping in `.swift` files. Base filenames must be unique from one another. SwiftPM will assume each of these comprise their own executable targets, so it can build and run them for the host platform as it would any other executable.

After getting started, a package might start to look like the following:


```
📁 MyPackage
  📁 Package.swift
  📁 Sources
  📁 Tests
  📂 Snippets
     📄 Snippet1.swift
     📄 Snippet2.swift
     📄 Snippet3.swift
    
```

### Grouping

To help organizing a growing number of snippets, you can also create one additional level of subdirectories under `Snippets` . This does not affect snippet links as shown below.


```
📁 MyPackage
  📁 Package.swift
  📁 Sources
  📁 Tests
  📂 Snippets
     📁 Group1
        📄 Snippet1.swift
        📄 Snippet2.swift
        📄 Snippet3.swift
    📁 Group2
        📄 Snippet4.swift
        📄 Snippet5.swift
```

### Using snippets in Swift-DocC documentation

Swift-DocC (or other documentation tools) can then import snippets within prose Markdown files. For DocC, a snippet's description and code will appear anywhere you use a new block directive called `@Snippet`, with a single required `path` argument:

<!-- swift language used in the following code block for some highlighting only -->

```swift
@Snippet(path: "my-package/Snippets/Snippet1")
```

The `path` argument consists of the following three components:


* `my-package` : The package name, as taken from the `Package.swift` manifest.
* `Snippets`: An informal namespace to differentiate snippets from symbols and articles.
* `Snippet1`: The snippet name taken from the snippet file basename without extension.

### Building and Running Snippets

After creating snippets, the Swift Package Manager can build and run them in the same way as executable targets. 

Snippet targets will be built by default when running `swift build --build-snippets`. This is consistent with how building tests is an explicit choice, like when running `swift test` or `swift build --build-tests`. It’s recommended to build snippets in all CI build processes or at least when building documentation.

Example usage:

```bash
swift build                   # Builds source targets as usual,
                              # but excluding tests and snippets.
                              
swift build --build-snippets  # Builds source targets, including snippets.

swift build Snippet1          # Build the snippet, Snippet1.swift, as an executable.

swift run Snippet1            # Run the snippet, Snippet1.swift.
```

### Testing Snippets

While the code exemplified in snippets should already be covered by tests, an author may want to assert specific behavior when running a snippet. While we could use a test library like XCTest, it comes with platform-specific considerations and difficulties with execution–XCTest assertions can’t be collected and logged without a platform-specific test harness to execute the tests. Again, thinking about snippets as a kind of executable, how does one assert behavior in an executable? With asserts and preconditions. These should be enough for a majority of use cases.

**Example:**

```swift
let numbers = [20, 19, 7, 12]
let numbersMap = numbers.map({ (number: Int) -> Int in
  return 3 * number
})

// MARK: Hide
print(numbersMap)
precondition(numbersMap == [60, 57, 21, 36])
```

## Detailed Design

### Swift Package Manager

When constructing the set of available targets for a package, SwiftPM will automatically find snippet files with the following pattern:


* `./Snippets/**.swift*`
*  `./Snippets/*/*.swift`

These will each become a new kind of `.snippet` target behaving more or less as existing executable targets. A single level of subdirectories is allowed to balance filesystem organization and further subdirectories for snippet-related resources, which are expected to be found informally using relative paths.

### SymbolKit

Snippets will be communicated to DocC via Symbol Graph JSON, with each snippet becoming a kind of symbol.

Snippet symbols will include two primary pieces of information: a description carried as the symbol’s “documentation comment”, and presentation code via new mix-in called `Snippet`:

```swift
public struct Snippet: Mixin, Codable {
    public struct Chunk: Codable {
        public var name: String?
        public var language: String?
        public var code: String
    }
    public var chunks: [Chunk]
}
```

In the data model shown above, snippets can be separated into one or more *chunks* when applicable. For Swift, most snippets will have just one chunk. There are some cases where a snippet might have a natural separation, such as a protocol and an example conformance, or a situation where code likely goes into two different places, such as a data model paired with a hook into the UI that displays it.

### Swift-DocC

Swift-DocC will need to do the following to support snippets:

**Look for and register occurrences of the new snippet mix-ins in symbol graph JSON.** By treating snippets as symbols, this mostly comes for free with the SymbolKit data model.

**Add support for the new `@Snippet` directive**, checking the `path` argument with the same logic as symbol links. This comes in the form of a new `Semantic` instance:

```swift
public final class Snippet: Semantic, DirectiveConvertible {
    public static let directiveName = "Snippet"
    // etc.
}
```

**Convert** `@Snippet` **occurrences to paragraphs and code blocks** as needed in the `RenderContentCompiler`, resulting in the following content for each occurrence:

* The documentation comment Markdown processed as normal for a symbol, a list of block elements.
* For each snippet chunk:
    * If the chunk has a name, the name, strongly emphasized, i.e. `Paragraph(Strong(Text(chunk.name)))`, followed by,
    * the chunk’s code as a `CodeBlock`.

### Swift-DocC Plugin

The recently added [Swift DocC Plugin](https://github.com/apple/swift-docc-plugin) is a new [SwiftPM command plugin](https://github.com/apple/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md) that builds documentation for SwiftPM libraries and executables.

In order to forward a package's snippet information to DocC, a new tool, `snippet-build`, is added to convert `.swift` files into Symbol Graph JSON, which the plugin will run before `docc`.

The `snippet-build` tool crawls the `Snippets` directory structure in the same way as SwiftPM, looking for `.swift` files. For each file, a snippet symbol entry is created in a Symbol Graph, and emitted into an output directory. The tool’s usage looks like the following:

```
USAGE: snippet-build <snippet directory> <output directory> <module name>

ARGUMENTS:
    <snippet directory> - The directory containing Swift snippets
    <output directory> - The diretory in which to place Symbol Graph JSON file(s) representing the snippets
    <module name> - The module name to use for the Symbol Graph (typically should be the package name)
```

It’s not expected that a person will run this command manually.

#### A note on Swift plugin dependencies

Because SwiftPM plugins fold their dependencies into the plugin client’s dependency graph, some useful but minor dependencies were dropped to prevent the possibility for dependency cycles or conflicts:

* **Swift Argument Parser.** This is a common dependency for lots of packages so the `snippet-build` tool implements argument parsing manually using positional arguments. It’s not expected that the usage will change over time.
* **Swift Syntax.** This could be useful for tokenizing code blocks, but DocC implements syntactic highlighting in the `Swift-DocC-Render` project.

This current restriction on dependencies is one motivating factor for investigating moving Symbol Graph generation from `.swift` files down to the compiler. This would have nearly identical usage to [existing functionality to emit library and executable symbol graphs](https://github.com/apple/swift/tree/main/lib/SymbolGraphGen) today. More on this below.

## Source compatibility

Proposed changes to enable snippets do not break source compatibility.

## Effect on ABI stability

Proposed changes to enable snippets do not break ABI stability.

## Effect on API resilience

Proposed changes to enable snippets do not impact API resilience.

## Alternatives considered

### Snippets embedded in Markdown

Another option was to support “[literate programming](http://www.literateprogramming.com/)” where source code is embedded in documentation. However, developers miss out on a lot of coding features by writing code within prose. People have thought about this approach for a long time, but we don’t yet have the tools ecosystem needed to make it great. So separate `.swift` files is a pragmatic decision to keep the snippet code easily editable by existing coding tools, and then very easy to move into a coding project.

### Snippets as playgrounds

Why aren’t these just playgrounds? Playgrounds tend to tell a story and are implemented as bundles of folders, files, and resources. Packages already have a model for building targets that have multiple files and resources. Snippets are intentionally much simpler examples that stand on their own — with access to the rest of the package. As soon as what you want to demonstrate requires something more complex than a snippet, the SwiftPM system already supports powerful build products.

### Tests acting as snippets

Snippets are not meant to be tests or come directly from tests, although they may include their own testing to validate demonstrated behavior. While tests may use public API in similar ways, the context in which one writes and thinks about tests is usually different from writing sample code. The setup required for tests doesn’t match the simpler case of just using an executable target. For those tests that do match common use cases very well, it may be possible in the future to extract snippets from multiple sources (see below).

### Snippets in documentation comments

Writing snippets exclusively in documentation comments limits their utility, putting too much focus on documenting APIs within a module. More interesting uses for snippets would be left behind, such as composing functionality across multiple modules, or packages whose sole purpose is to communicate a body of interesting snippets, without being tied to one particular library.

### Customizing the snippets directory name

An important part of snippets’ utility is the shared convention and terminology. There are three main reasons for not allowing customization of their location in the source tree:

* A subdirectory `Snippets` is unlikely to clash with existing or future projects.
* By always putting snippets in the same place, prospective clients of a package always know where to look in the source tree to get a very quick overview of how the library is used without having to dig through the file hierarchy.
* Coining the term `snippet` is an intentional move to differentiate them from existing “sample” or “example” code, which have historically been larger projects contextualized by more complex scenarios.

## Future Directions

**Multiple snippets per file.** In the future there is the option to create multiple snippets per file, where each snippet’s identifier is expressed as a kind of start/end marker in source code.

**Multi-file snippets.** This could manifest in a couple ways. First, requiring several files to build a snippet already exists in the form sample target or project, so this is probably not a future goal. However, for snippets embedded within existing multi-file projects, it may be possible extract those snippets during build time. This will likely require that the snippet extraction move down to the compiler.

**Extract snippets while building.** To facilitate some of the above future possibilities and others, the `snippet-build` tool may move down to the `SymbolGraphGen` library that coverts modules into Symbol Graph JSON. Since snippets are communicated with the same Symbol Graph format, moving the implementation down to the compiler will allow utilizing shared implementation and semantic information for future enhancements. This would allow snippets to be pulled from different kinds of sources: from libraries, unit tests, larger sample projects, etc.

**Build snippets when building documentation.** The current Swift-DocC implementation only requires reading snippet source files when rendering documentation, so building is not required. Depending on whether the implementation is moved down to the compiler, this could be implemented by having the Swift-DocC plugin request snippet builds before generating documentation, or implicitly as the compiler builds snippets to generate symbol graphs.

**Snippet dependencies.** While snippets automatically depend on any libraries defined in their host package, there may be packages that exist solely to illustrate using one or more libraries from other packages. In the future, we can add the ability to declare external dependencies to which snippets have access.
