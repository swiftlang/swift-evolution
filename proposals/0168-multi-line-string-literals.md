# Multi-Line String Literals

* Proposal: [SE-0168](0168-multi-line-string-literals.md)
* Authors: [John Holdsworth](https://github.com/johnno1962), [Brent Royal-Gordon](https://github.com/brentdax), [Tyler Cloutier](https://github.com/TheArtOfEngineering)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Active review (April 6...12, 2017)**
* Bug: [SR-170](https://bugs.swift.org/browse/SR-170)

## Introduction

This proposal introduces multi-line string literals to Swift source code.
This has been discussed a few times on swift-evolution most recently
putting forward a number of different syntaxes that could achieve this goal
each of which has their own use case and constituency for discussion.

[Swift-evolution thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/001565.html)

## Motivation

Multi-line string literals are a common programming language feature that is, to date, still missing in
Swift. Whether generating XML/JSON messages or building usage messages in Swift scripts, providing string
literals that extend over multiple lines offers a simple way to represent text without having to manually
break lines using string concatenation. Concatenation is ungainly and may result in slow compilation; 
escape sequences like `\n` make it harder to picture how the string constructed by the literal will look.

If the goal is to make multi-line string literals more readable, we can't ignore indentation. Any 
feature we design should allow the contents of a string literal to be indented to match the surrounding 
code. Languages which include a multiline string literal syntax, but don't allow them to be indented, 
often end up adding an indentation feature later. We think we should tackle this problem from the outset.

A related problem is that of string literals which contain double-quote characters. Because `"` is the 
delimiter for string literals, double-quote characters *within* a string literal have to be escaped with 
a `\`. This can make even relatively short string literals difficult to read, particularly if they mix 
quotation marks, backslashes, newlines, and/or interpolated expressions in close proximity. Thus, the 
right design for a multi-line string literal feature might also improve the readability of some short 
string literals.

## Proposed solution

### Tripled string literal syntax

We propose adding a new string literal syntax delimited by three double-quote marks.
Unlike ordinary string literals, literal newline and tab characters are permitted in these 
*tripled string literals*, and sequences of one or two double-quotes do not need to be escaped:

```swift
"""You want a revolution? I want a revelation
So listen to my declaration:
"We hold these truths to be self-evident
That all men are created equal"
And when I meet Thomas Jefferson
I'm 'a compel him to include women in the sequel!"""
```

Tripled string literals can also do double duty as a syntax for handling short string literals with 
many internal quotation marks:

```swift
"<a href=\"\(url)\" id=\"link\(i)\" class=\"link\">"    // With escapes
"""<a href="\(url)" id="link\(i)" class="link">"""      // With tripled literals
```

Newlines in tripled string literals are normalized so that, even if a user's tools convert a 
source code file to use CR LF line endings, a newline in a multi-line string literal is 
always equivalent to a `\n` escape:

```swift
"""Hello!
""" == "Hello!\n"   // Always true, no matter how your editor is set.
```

Tripled string literals support backslash escapes and interpolation as normal, except that 
you can also place a backslash immediately before a newline. This indicates that the newline 
is merely for code formatting and should not be present in the resulting string:

```swift
"""The newline after this sentence is real!
The newline after this sentence is just for looks!\
"""
```

Tripled string literals are entirely a compile-time construct; they use 
`ExpressibleByStringLiteral` and `ExpressibleByStringInterpolation` to construct an instance, 
and otherwise look identical to ordinary string literals at runtime.

#### Rationale

We evaluated several different multi-line literal syntaxes; each has its advantages and 
disadvantages, and there is no choice that is unambiguously superior in all ways. We selected 
this design partially because of subjective opinions—we believe it is a lightweight and 
elegant syntax which suits Swift's low-punctuation feel. But we also like it for more objective 
reasons: We believe it is a well-understood design, which compared to the alternatives 
will be easier to implement, easier for tooling to handle, and easier for people unfamiliar 
with it to understand.

Tripled string literals have long been used in Python, where they are one of four supported 
string literal delimiters. (Python supports `"string"`, `'string'`, `"""string"""`, and 
`'''string'''`; the single-quote variants have the same semantics as their double-quoted counterparts, but 
save you from escaping double-quotes.) They have proven readable and popular in that language, so there 
is good reason to believe they will work in Swift. Moreover, we can learn from their mistakes; 
line ending normalization, escaped newlines, and the indentation stripping feature discussed 
shortly are all novel innovations.

We also developed a prototype of this feature, and the process was pretty smooth. The changes necessary were fairly simple and 
largely limited to the lexer; the rest of the toolchain then supported multi-line string literals 
with no modification. A production-ready implementation would touch more of the compiler, but 
we believe it will be less invasive and risky than (for instance) heredocs, where our prototype 
had to disable assertions in other parts of the toolchain.

We also think tripled string literals will be easier for tools which *don't* rely on our 
parser. Many common developer tools—text editors, bug trackers, version control 
clients, wikis and blogging engines, and Markdown-based sites like Stack Overflow and 
GitHub—highlight syntax without using SourceKit or any sort of sophisticated, robust 
parser. We believe these kinds of applications will be able to add support for this syntax 
relatively easily, and even if they don't, they will usually gracefully degrade by 
interpreting the leading pair of quotes and the trailing pair of quotes as separate, 
empty string literals. For instance, GitHub's Markdown formatter does not support tripled 
string literals yet, but it does a decent job of highlighting the examples in this proposal.

Perhaps most importantly, we believe tripled string literals will also be easy to learn.
They both look and work like ordinary string literals—you just type three double-quotes 
instead of one. They stand out compared to ordinary string literals, but they also explain 
themselves fairly well. Most alternatives we've considered are much more opaque; users 
would more likely need to hit the documentation to figure out what was going on.

Newline normalization is a slightly odd feature to include. Normally, the Swift compiler 
does not alter the characters in a string literal; for instance, it does not normalize 
combining or composed Unicode characters. We think newlines are different because so many 
tools convert newlines automatically and transparently—for instance, many Windows programmers 
configure Git to convert line endings automatically—but Unicode doesn't smooth over line 
ending differences like it handles normalization differences. We think these kinds of 
invisible, automatic changes are too common, and the resulting change in behavior is too 
important, for tripled string literals to ignore the problem.

### Indentation stripping

As specified so far, this syntax has one significant weakness: it interferes with 
proper indentation of code. We propose that, when the space between the last 
newline in the string and the closing delimiter contains only whitespace characters, 
tripled string literals should automatically remove whatever indentation is present 
before the closing delimiter from each line before it, except for the opening line. 
Thus, this code:

```swift
let xml = """<?xml version="1.0"?>
            <catalog>
                <book id="bk101" empty="">
                    <author>John Doe</author>
                    <title>XML Developer's Guide</title>
                    <genre>Computer</genre>
                    <price>44.95</price>
                </book>
            </catalog>
            """        // Note that there are 12 spaces before the delimiter on this line.
```

Strips 12 spaces from the beginning of each line in the literal, producing a string with
this content (including a trailing newline):

```xml
<?xml version="1.0"?>
<catalog>
    <book id="bk101" empty="">
        <author>John Doe</author>
        <title>XML Developer's Guide</title>
        <genre>Computer</genre>
        <price>44.95</price>
    </book>
</catalog>

```

Indentation stripping is concerned with the actual characters present in the source file, 
not the logical characters produced by escapes, so indentation is stripped after an escaped 
newline, but not after a `\n` sequence. That means escaped newlines work really well with 
this feature—indentation after them will still be stripped.

In fact, two special uses for escaped newlines fall naturally out of the two features' designs.
When placed after the opening delimiter in a tripled string literal, an escaped newline lets 
you start the content of the literal on a fresh line of text:

```swift
let xml = """\
    <?xml version="1.0"?>
    <catalog>
        <book id="bk101" empty="">
            <author>John Doe</author>
            <title>XML Developer's Guide</title>
            <genre>Computer</genre>
            <price>44.95</price>
        </book>
    </catalog>
    """
```

Contrarily, when placed at the end of the last full line in a string literal, an escaped 
newline suppresses the trailing newline:

```swift
let xml = """<?xml version="1.0"?>
            <catalog>
                <book id="bk101" empty="">
                    <author>John Doe</author>
                    <title>XML Developer's Guide</title>
                    <genre>Computer</genre>
                    <price>44.95</price>
                </book>
            </catalog>\
            """        // No trailing newline on this string.
```

If indentation stripping is enabled but some of the lines do not start with the 
same sequence of whitespace characters as the last line, the compiler leaves those 
lines unchanged and emits a warning about inconsistent indentation. This code sample 
would emit a warning on the line with the `<catalog>` tag and leave two spaces before it:

```swift
let xml = """\
    <?xml version="1.0"?>
  <catalog>
        <book id="bk101" empty="">
            <author>John Doe</author>
            <title>XML Developer's Guide</title>
            <genre>Computer</genre>
            <price>44.95</price>
        </book>
    </catalog>
    """
```

Indentation stripping does not affect whitespace in the middle or at the end of a line; nor 
does it allow comments in the middle of tripled string literals. Fans of Perl's `/x` 
regex modifier will need a different proposal.

If the line containing the closing delimiter *does* contains at least one 
non-whitespace character before the delimiter, no indentation-stripping logic will 
be applied. This preserves the feature's utility for short, possibly single-line 
strings and for code generation use cases where nobody will read the code.

#### Rationale

We considered designs where a character explicitly marked the indentation on each line.
While this was very clear, it meant that users would need to edit each line of the string, 
rather than just inserting text verbatim. This made a lot of people very angry and was 
widely regarded as a bad move.

The best alternative, then, is to somehow infer the amount of indentation from the text, 
preferably in a way that can also easily tell us whether indentation stripping should be 
enabled at all. We use the closing delimiter's indentation because it's the 
only part of the string literal's syntax whose distance from the first column has no other 
meaning. By using it, we can support string literals which include indentation 
*in their content*, which is helpful for many code-generation use cases, where you may care 
about the indentation of both the generator and the output. With this design, even literals where 
all lines are indented can be expressed without ambiguity, with the string literal itself 
properly indented within the code using it. For instance, this example is both easy to read 
by itself *and* generates easy-to-read XML:

```swift
var xml = """\
    <?xml version="1.0"?>
    <catalog>
    """

for (id, author, title, genre, price) in bookTuples {
    xml += """\
            <book id="bk\(id)">
                <author>\(author)</author>
                <title>\(title)</title>
                <genre>\(genre)</genre>
                <price>\(price)</price>
            </book>
        """
    //  | The string literal as a whole is indented up to this line (eight spaces), but 
    //  | the string it expresses also contains at least four spaces of indentation on 
    //  | every line. The position of the ending `"""` tells the compiler how much of 
    //  | that indentation is for source code formatting and how much is actually part 
    //  | of the string literal's contents.
}

xml += """\
    </catalog>
    """
```

We could instead use an algorithm where the longest common whitespace prefix is removed from 
all lines; in well-formed code, that would produce the same behavior as this algorithm. But 
when *not* well-formed—when one line was accidentally indented less than the delimiter, or 
when a user mixed tabs and spaces accidentally—it would lead to valid, but incorrect and 
undiagnosable, behavior. For instance, if one line used a tab and other lines used spaces, 
Swift would not strip indentation from any of the lines; if most lines were indented four 
spaces, but one line was indented three, Swift would strip three spaces of indentation from 
all lines. And while you would still be able to create a string with all lines indented by 
indenting the closing delimiter less than the others, many users would never discover this 
trick.

We discuss many alternative indentation stripping designs *ad nauseam* 
[below](#indentation-stripping-alternatives). Suffice it to say, other languages have explored 
this problem space thoroughly, and we think this is the right design for Swift.

## Detailed design

### Parsing a tripled string literal

Upon reading a double-quote mark in a Swift expression, the lexer immediately examines the next two
characters. If they are both double-quote marks as well, the lexer consumes all three characters and 
begins parsing a tripled string literal.

When parsing an ordinary string literal, the lexer emits an error if it encounters a U+000A LINE FEED 
("LF") or U+000D CARRIAGE RETURN ("CR"). But when parsing a tripled string literal, this rule is 
modified: The lexer permits either LF or CR LF and, in either case, inserts an LF into the resulting 
string literal. (A CR without an LF in an tripled string literal is an error; while some operating 
systems have historically used CR alone or LF CR as line endings, they have largely been retired and 
are unlikely platforms for future Swift development.)

When parsing an ordinary string literal, the lexer also emits an error if it encounters a U+0009 CHARACTER 
TABULATION ("tab") character. When parsing a tripled string literal, these characters will be permitted 
and treated verbatim.

Backslash escapes and interpolations are processed as in a normal string. However, an additional escape
is added: If an LF (or CR LF) is preceded by a backslash, it is not included in the string literal's 
contents, though it still "counts" for indentation stripping.

Upon encountering a double-quote mark in a tripled string literal, the lexer examines the next few 
characters to figure out how many quote marks there are in a row:

* Just the one: One quote mark is added to the literal's contents.
* Two: Two quote marks are added to the literal's contents.
* Three: The literal is terminated.
* Four: One quote mark is added to the literal's contents and the literal is terminated.
* Five: Two quote marks are added to the literal's contents and the literal is terminated.
* Six or more: A syntax error occurs.

(The exact specifics of how this is accomplished are an implementation detail; the prototype 
simply doesn't consider the delimiter matched until it finds three quotes and a non-quote.)

These rules ensure that up to two unescaped double-quote marks may appear anywhere in a tripled 
string literal, including adjacent to the closing delimiter. If you want a string with three 
adjacent double-quote marks in it, you'll need to escape at least one of them:

```swift
""""" <-- Two double-quote marks adjacent to the opening delimiter
This is okay: "
This is okay: ""
This needs at least one escape: \"""
This would work too: ""\"
Or this, if you want to overdo it: \""\"
This needs several escapes: \"""\"""\"""
Two double-quote marks adjacent to the closing delimiter --> """""
```

Other characters are processed as they would be in an ordinary string literal; that is, they are 
typically included verbatim.

### Stripping indentation from a literal

Indentation stripping is performed on the raw source code, after the delimiter has been 
located but before backslash escapes are interpreted. That means that, when we talk about 
an "LF", we mean a physical LF in the code, not a logical LF after escapes have been 
processed—we will match escaped newlines, but not `\n` escapes. Similarly, tabs are actual 
physical tab characters, not `\t` escapes.

For the purposes of this section, a "whitespace character" is either a tab or U+0020 SPACE.
This is how `Lexer::lexWhitespace()` currently defines whitespace in code; if 
that's changed, the indentation stripping algorithm should change to match.

After locating the delimiters of the string, the lexer:

1. Examines the characters between the last LF and the closing delimiter. If there 
   are any non-whitespace characters in this stretch (or there are no LFs in the string),
   indentation stripping is disabled, and we skip the remaining steps.

2. Records the exact sequence of whitespace between the last LF and the closing delimiter 
   as the indentation to be removed.

3. Examines the characters after each LF. If they exactly match the recorded indentation, 
   the characters are removed from the string literal contents. Otherwise, a warning should 
   be emitted.

At this point, the remaining text should undergo normal processing, including processing 
of backslash escapes.

### Implementation

We have prepared a [prototype implementation][proto] which includes:

* Parsing the tripled delimiter syntax.
* Support for existing escaping and interpolation features.
* Permitting newlines and short double-quote sequences in tripled string literals.
* Escaping newlines to remove them from the content string.
* Indentation stripping similar to what is specified here.
* Some work on newline normalization.
* Tests similar to the ones in the "gallery" below.

It does not include:

* Detailed indentation diagnostics with fix-its.
* Specific diagnostics work for runaway tripled string literals.
* Updates to other clients of the tokenizer (IDE, Syntax, etc.) so they fully understand 
  tripled string literals.

In our prototype, we were able to implement this feature solely by modifying the lexer; not 
even the parser, let alone upstream components like type checking, code generation, or the 
standard library, were impacted. When we built a toolchain from this prototype and installed 
it in Xcode, tripled string literals highlighted *almost* correctly (only the innermost quote 
marks are highlighted) and otherwise appeared to work pretty well. Overall, the compiler seems 
to be very amenable to this change.

  [proto]: https://github.com/DoubleSpeak/swift/commit/d37fa1c08923707d598418227c481a3a87a54b4e

### Gallery of test cases

We've prepared a series of examples to help illustrate some of the rules described above.
Each of these corresponds to a test in our prototype. Because whitespace is important to 
these examples, it is explicitly indicated: `·` is a space, `⇥` is a tab, and `↵` is a 
newline.

Please keep in mind:

* LF and CR LF are both valid newlines.

* Warning messages and fix-its are just general suggestions, not final.

* Any valid code can go before the opening delimiter or after the closing delimiter. 
  Although we show only the delimiters and what's between them, there could be much 
  more code before the opening delimiter or after the closing delimiter.

#### Single-line string

```swift
"""Hello·world!"""
```
Creates a string with:
```
Hello·world!
```

#### Single-line string with quotes

```swift
"""Hello·"cruel"·world!"""
```
Creates a string with:
```
Hello·"cruel"·world!
```


#### Single-line string with quotes adjacent to delimiter

```swift
""""Hello·world!""""
```
Creates a string with:
```
"Hello·world!"
```

#### Single-line string with only quotes inside

```swift
""""""""
```
Creates a string with:
```
""
```

This corner case is not very readable, but supporting it ensures that you can insert anything 
into triple quotes as long as it doesn't have three adjacent, unescaped quote marks. In 
practice, you should probably format code like this with escaped newlines next to both 
delimiters.

#### Simple multi-line string

```swift
"""Hello↵
world!"""
```
Creates a string with:
```
Hello↵
world!
```

#### Simple multi-line string with escaped newline

```swift
"""Hello\↵
world!"""
```
Creates a string with:
```
Helloworld!
```

#### Simple multi-line string with `\n` escape

```swift
"""Hello↵
world!\n"""
```
Creates a string with:
```
Hello↵
world!↵
```

The `\n` escape, like all escapes and string interpolation, still works normally in a 
multi-line string.

#### Multi-line string with indentation stripping

```swift
"""Hello↵
···world!↵
···"""
```
Creates a string with:
```
Hello↵
world!↵
```

#### Multi-line string with indentation stripping, escaped trailing newline

```swift
"""Hello↵
···world!\↵
···"""
```
Creates a string with:
```
Hello↵
world!
```

#### Multi-line string with indentation stripping, escaped leading newline

```swift
"""\↵
····Hello↵
····world!↵
····"""
```
Creates a string with:
```
Hello↵
world!↵
```

#### Multi-line string with indentation stripping, one line indented more

```swift
"""\↵
··Hello↵
····world!↵
··"""
```
Creates a string with:
```
Hello↵
··world!↵
```

#### Multi-line string with indentation stripping, all lines indented more

```swift
"""\↵
····Hello↵
····world!↵
··"""
```
Creates a string with:
```
··Hello↵
··world!↵
```

#### Multi-line string with indentation stripping, missing indentation

```swift
"""\↵
····Hello↵
··world!↵
····"""
```
Creates a string with:
```
Hello↵
··world!↵
```

A warning should be emitted on the third line:

```
warning: missing indentation in multi-line string literal
  ··world!
    ^ 
  Fix-it: Insert "··"
```

#### Multi-line string with indentation stripping, missing indentation, `\t` escape

```swift
"""\↵
⇥   Hello↵
\tworld!↵
⇥   """
```
Creates a string with:
```
Hello↵
⇥   world!↵
```

The `\t` is *not* treated as equivalent to a real tab character. A warning should be emitted 
on the third line:

```
warning: missing indentation in multi-line string literal
  \tworld!
  ^ 
  Fix-it: Insert "⇥   "
```

#### Multi-line string with indentation stripping, mismatched indentation

```swift
"""\↵
····Hello↵
⇥   world!↵
····"""
```
Creates a string with:
```
Hello↵
⇥   world!↵
```

The tab character is not treated as four spaces, or indeed as any number of spaces; it is 
simply not a match. A warning should be emitted on the third line:

```
warning: multi-line string literal indentation uses tabs and spaces inconsistently
  ⇥   world!
  ^~~~ 
  Fix-it: Replace "⇥" with "····"
```

#### Multi-line string with indentation stripping, partially mismatched indentation

```swift
"""\↵
····Hello↵
··⇥ world!↵
····"""
```
Creates a string with:
```
Hello↵
··⇥ world!↵
```

Even though the two spaces on this line are a partial match for the four spaces we expect, 
we do not remove them. A warning should be emitted on the third line:

```
warning: multi-line string literal indentation uses tabs and spaces inconsistently
  ··⇥ world!
    ^~ 
  Fix-it: Replace "⇥" with "··"
```

#### Multi-line string with indentation stripping prevented by non-whitespace before trailing delimiter

```swift
"""\↵
····Hello↵
····world!"""
```
Creates a string with:
```
····↵
····Hello↵
····world!
```

Despite each line having some indentation, no indentation is stripped because the delimiter is 
not on its own line. We might add a warning with a pair of fix-its to help people discover this 
feature:

```
warning: indentation will not be stripped from this multi-line string literal.
  ····world!"""
  ^~~~
  Fix-it: Insert "\↵····" before delimiter to strip "····" from each line
  Fix-it: Insert "\↵" before delimiter to disable this warning
```

#### Multi-line string with indentation stripping, last line not indented

```swift
"""\↵
····Hello↵
····world!↵
"""
```
Creates a string with:
```
····Hello↵
····world!↵
```

When there's no indentation before the closing delimiter, the indentation stripping feature 
gracefully degrades into merely specifying a trailing newline.

#### Empty strings

Both of these produce an empty string:

```swift
""""""
```
```swift
"""\
"""
```

Additionally, both of these produce an empty string through indentation stripping:

```swift
"""
"""
```
```swift
"""
····"""
```

Although redundant with `""`, none of these forms cause errors or warnings; we don't 
want to make life difficult for code generators.

## Impact on existing code

This proposal is additive and does not affect existing code.

## Alternatives considered

Two other alternative syntaxes (along with many minor variations) were discussed in the 
swift-evolution thread. It became apparent that each syntax had its own, at times, 
non-overlapping constituency of supporters.

### Continuation quotes

The basic idea of continuation quotes is straightforward. If a quoted string literal is not closed by `"`
before the end of the line and the first non-whitespace character on the next line is `"` it is taken to
be a continuation of the previous literal.

```swift
let xml = "<?xml version=\"1.0\"?>
    "<catalog>
    "    <book id=\"bk101\" empty=\"\">
    "        <author>\(author)</author>
    "        <title>XML Developer's Guide</title>
    "        <genre>Computer</genre>
    "        <price>44.95</price>
    "        <publish_date>2000-10-01</publish_date>
    "        <description>An in-depth look at creating applications with XML.</description>
    "    </book>
    "</catalog>
    ""
```
<!-- "
``` -->

The advantage of this format is it gives precise control of exactly what is included in the literal. It also
allows code to be formatted in an aesthetically pleasing manner. Its main disadvantage is that, unless 
their editor provides assistance, users must edit every line to add a quotation mark; many people vociferously 
objected to this. Also, some external editors will not be familiar with the format and will be unable to 
correctly highlight literals. For instance, TextMate chokes so badly on this example that we've added an 
HTML comment below it with characters that fix the problem.

### Heredocs

Taking a precedent from other languages, a syntax such as the following could be used to introduce
literals into a codebase. 

```swift
assert( xml == <<"XML" )
    <?xml version="1.0"?>
    <catalog>
        <book id="bk101" empty="">
            <author>\(author)</author>
            <title>XML Developer's Guide</title>
            <genre>Computer</genre>
            <price>44.95</price>
            <publish_date>2000-10-01</publish_date>
            <description>An in-depth look at creating applications with XML.</description>
        </book>
    </catalog>
    XML
```

The same indentation stripping rules would be applied as for tripled string literals. This syntax has the 
advantage of being able to paste content in directly and the additional advantage that the
literal is separated from the line of code using it, increasing clarity. Its main disadvantage
is a more practical one: it is a more major departure for the compiler in that tokens
in the AST are no longer in source file order. Testing has, however, shown the toolchain
to be surprisingly robust in dealing with this change once a few assertions were removed.

### Indentation stripping alternatives

The proposed indentation stripping algorithm is not included in Python, but it has precedent 
Perl 6; that language has a similar feature for its heredocs, also based on the indentation 
of the ending delimiter. We considered several alternatives:

* **Not doing anything about it**: This would make code using multiline string literals quite 
  ugly. Perl and Ruby both used to do this; each added indentation stripping features in later 
  versions, so we think that we would eventually end up doing the same.

* **Including indentation stripping in the standard library**: There are three problems with this: 
  it performs processing at runtime that could be done at compile time; it cannot emit warnings 
  for invalid indentation; and it loses the ability to reason from information only present in 
  the source code. (For instance, `\t` escapes would be indistinguishable from real tab 
  characters.) Python's standard library includes a module with a [`dedent` function][py-dedent] 
  which does this.

* **Explicitly marking literals to enable indentation stripping**: For instance, literals might be 
  annotated with a hash keyword like `#trimLeft()`, or a symbol or an `i` (for "indent") character 
  might be added before the opening delimiter. We believe that, as much as possible, indentation 
  stripping should be the default; good formatting should be the rule, not the exception. Ruby 2.3
  marks its heredocs with a `~` if indentation should be stripped.

* **Stripping indentation to match the depth of the least indented line**: Instead of removing 
  indentation to match the end delimiter, you remove indentation to match the least indented 
  line of the string itself. The issue here is that, if all lines in a string should be 
  indented, you can't use indentation stripping. Ruby 2.3 does this with its heredocs, and Python's 
  `dedent` function also implements this behavior.

* **Stripping a common prefix from lines with partially matching indentation**: For instance, if 
  the delimiter line had four spaces, and an earlier line had two spaces and a tab, we would remove 
  the two spaces and leave the tab. We think that indentation mismatches are obvious mistakes 
  (although not serious enough to be hard errors), so there's little sense in trying to do part of 
  the indentation stripping. Perl 6 does this.

  [py-dedent]: https://docs.python.org/2/library/textwrap.html#textwrap.dedent
