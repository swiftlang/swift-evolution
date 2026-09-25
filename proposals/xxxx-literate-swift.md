# Literate Swift

* Proposal: [SE-NNNN](NNNN-literate-swift.md)
* Authors: [Alastair Houghton](https://github.com/al45tair)
* Review Manager: TBD
* Status: *Implemented*
* Implementation: https://github.com/apple/swift/pull/39305, https://github.com/apple/swift-driver/pull/837, https://github.com/apple/swift-package-manager/pull/3747, https://github.com/apple/swift-syntax/pull/3382, https://github.com/apple/swift-build/pull/1542
* Review: pitch

## Introduction

In the 1984, Donald Knuth introduced the idea of Literate Programming,
a unique programming style that he used to implement the TeX and
MetaFONT systems that form the basis for many commercial typesetting
systems to this day.

The key difference between Literate Programming and the normal
approach is that in a literate program you spend your time describing,
in prose and potentially with the aid of diagrams, equations and other
explanatory figures, how the program is constructed.  During this
exposition, the programmer presents the code that implements the
program, in whatever order makes most sense for the purpose of
describing its operation.

This is facilitated by two features of Literate Programming:

1. The default is _prose, not code_.  If you wish to write code, you
   can do so by encapsulating it in some kind of code block.

2. For languages that force the developer to order declarations,
   Literate Programming systems typically provide a means to write
   those declarations _out of order_ and have the literate programming
   tools re-order the declarations into an order suitable for
   compilation.

The most widely known literate programming system is Knuth's _WEB_
system, a variant of which, _CWEB_, is used to this day for TeX and
MetaFONT, among others.  Additionally, most TeX packages are
themselves written in literate style, since it is a very natural fit
given that TeX is itself both a typesetting system and a programming
language.

Outside of the TeX ecosystem, relatively few languages directly
support Literate Programming, though there are a number of systems
built on similar principles including Mathematica's notebooks, along
with similar features in Jupyter and indeed Swift Playgrounds.

## Motivation

Literate programming improves both the quality of the final product and
also makes it considerably easier for other people to understand and work
on code they haven't seen before --- since there is a clear description of
_how_ it works, as well as an explanation of _why_ the author decided to
make particular choices when writing the code.

Literate style is also extremely useful for teaching, self-directed learning,
and academic publications.

Swift is a great choice for literate programming, because unlike many older
languages, it does not require declarations or definitions of types or
functions to precede uses, and it makes it easy to extend existing types
with additional functions with its `extension` syntax; this means that there
is no need to provide support for re-ordering code.

## Design

The key observation here is that it is possible to make Swift support
literate programming by a straightforward change to the lexical analyser.
The idea is that, when parsing a literate program, the lexer should skip
over characters until it finds itself inside a code block, then generate
tokens as normal until it finds the end of that code block, before going
back into the character skipping mode again.

Making this change will allow the compiler to support literate programming
without any external tooling --- you will be able to point the compiler
_directly_ at the literate source code and it will simply compile the
Swift content it sees in code blocks embedded into the literate content.

### Which document formats to support?

We want to support

  * Markdown

    Markdown is a very popular text-based documentation format.  It is
    simple, familiar, and can be processed by a large number of tools,
    including Swift's own DocC document processor.

    Markdown is also widely supported by existing editors, many of which
    already know how to display Swift code blocks.

  * reStructuredText

    reStructuredText is a format similar to but more powerful than
    Markdown.  It is very popular in the Python ecosystem, and some of
    Swift's existing documentation is written in this format.

  * (La)TeX

    The original high quality typesetting format.  TeX support is great
    because it has good support for equations and advanced typesetting,
    and is the format of choice for academic work in computer science and
    mathematics.

We could have chosen to support only one of the above formats, but since
the compiler only really needs to know how to locate and process code blocks,
as opposed to needing to know the full syntax of the documentation format,
it isn't difficult to support more than one format, or indeed to add others
should someone find one that seems useful.

We do _not_ want to support HTML at this point because doing so is a lot
more complicated than it might seem.  In particular, HTML would require
that Swift code blocks escape some characters; in XML we could get away with
this to some extent by using `CDATA`, but HTML does not, officially, support
`CDATA`.

### Compiler changes required

We need to update the lexer to detect literate input files and place itself
in a mode where it will skip over non-code content.

We also want to pay attention to annotations in the document format that
indicate which language is in use --- we should only compile _Swift_ code,
and not code intended for some other language --- and there needs to be
a way to mark a Swift code block as not-for-compilation.  The mechanism
used varies:

  * Markdown looks for code blocks by watching for fences or indentation,
    then for _fenced_ code blocks, tries to read the name of the language
    (if present) before scanning additional attributes.  The `nocompile`
    attribute will prevent Swift from attempting compilation even for
    `swift` code blocks.

  * reStructuredText looks for `codeblock::` or `source-code::` blocks,
    as well as implicit code blocks.  Explicit code blocks can have a
    language annotation as well as attributes; the `:nocompile:`
    attribute will prevent Swift from attempting compilation.

  * (La)TeX looks for blocks starting with `\begin{swift}` and ending with
    `\end{swift}`.  Since this is not a standard construct, there seems
    little need to worry about providing a no-compile option.  In a LaTeX
    document, you might define a suitable environment using something like:

    ``` latex
    \usepackage{listings}

    \lstnewenvironment{swift}{\lstset{language=Swift,basicstyle=\small}}{}
    ```

No changes are required to compiler flags or options --- literate mode can
be triggered by having the compiler look at the file extension of its inputs,
which it already does for other purposes.  We just need to teach it about
`.md`, `.rst` and `.tex` respectively.

Note: we do _not_ want to use `.swift.md`, `.swift.rst`, `.swift.tex` and
so on, because it's entirely possible that a given literate document will
include code for other languages also.  Since people do not normally pass
these kinds of files to the compiler, it's reasonable to assume that when
they do, we need to treat them as literate input.

### SwiftPM support

Unlike the compiler, SwiftPM support _does_ raise some issues.  SwiftPM
tries to automatically detect source files and pass them to the compiler for
compilation.  We therefore need to teach it to do that for `.md`, `.rst` and
`.tex`, _however_ it is not uncommon for people to have `README.md` and other
documentation files in their source directories.

We _do not_ want to process these existing files; indeed, we should ignore
files with the following stems:

```
README
LICENSE
CHANGELOG
CONTRIBUTING
CODE_OF_CONDUCT
NOTICE
AUTHORS
SECURITY
CODEOWNERS
CLAUDE
AGENTS
```

This, however, is not really enough on its own.  Someone might have a project
with a `ReadMe.md` or indeed any other document file, and it would be
surprising if we suddenly started compiling code from that.

So, we propose adding a `literate:` option to the various `Target` types in
the package description.  This will be gated on a future Swift version, and
will default to `false`.

When in non-`literate` mode, SwiftPM will process files as it does now.  Only
when in `literate` mode will it recognise `.md`, `.rst` and `.tex` files as
Swift source code, and even then it will still actively ignore files with the
stems above (thus you can still have a `README.md` and don't need to annotate
everything in there with `nocompile`).

Making this into a target setting allows you to mix literate and non-literate
targets in a single project.  It also makes it easy to enable literate mode
for part of your project as you transition to literate programming.

## Source compatibility

For existing Swift code there is no source compatibility concern.

## ABI compatibility

There are no ABI compatibility implications.

## Implications on adoption

Software wishing to use literate mode will need to target a Swift version
that has this feature.

## Future directions

We could add support for further document formats.  HTML seems like it might
be interesting, but there are some significant problems because HTML reserves
some characters, which means we would need to do considerably more processing
on the input.

We could also add support for code-block re-ordering.  This is not really
needed for Swift though, and again would complicate processing.

## Alternatives considered

### Implement just Markdown

TeX is too useful to pass up as an option, and reStructuredText support will
provide a useful alternative when TeX is too heavyweight but Markdown is not
sufficiently expressive (for instance, complex tables are difficult to
express in Markdown).

### Build a separate literate processor

We could have built a separate program to separate code from literate
documentation, ala Knuth's `tangle` program.  This would have the advantage
that we could add re-ordering support, and would have an easier time
processing HTML if we want to do that, _but_ it adds another step to the
build process and increases the level of friction associated with adopting
literate programming.

History suggests that this friction is sufficient to discourage most users,
while languages that have built-in support (LaTeX and Haskell being examples)
experience broader adoption.

### Wait for some future where Swift accepts "rich" input

Some people have in the past suggested that at some point it might make
sense for compilers to accept some kind of rich, structured input rather than
text files.  In that world, they're being fed something more like e.g. a
Mathematica workbook or a Swift Playground, perhaps with full formatting
support, images, drawing tools and so on.

This is a nice vision, but the fact is that we have a lot of tooling that
works well on text files, including version control systems, text editors,
build tools, linters, formatters, and even the new generation of AI-based
tools.

Moving to a format not supported by any of that existing tooling will be
a significant challenge.
