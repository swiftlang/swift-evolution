### Commonly Rejected Changes 
 
This is a list of changes to the Swift language that are frequently proposed, but that are unlikely to be accepted.  If you're interested in pursuing something in this space, please familiarize yourself with the discussions that we have already had.  In order to bring one of these topics up, you'll be expected to add new information to the discussion, not just say "I really want this" or "This exists in some other language and I liked it there".

Several of the discussions below refer to "C Family" languages.  This is intended to mean the extended family of languages that resemble C at a syntactic level.  This includes languages like C++, C#, Objective-C, Java, Javascript, etc.

 * [Replace `{}` Brace Syntax with Python-style indentation](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/003656.html): Surely a polarizing issue, but Swift will not change to use indentation for scoping instead of curly braces..

 * [Replace Logical Operators (`&&`, `||`, etc) with words like "and" and "or"](https://lists.swift.org/pipermail/swift-evolution/2015-December/000032.html): The operator and identifier grammars are intentionally partitioned in Swift, which is a key part to how user defined overloaded operators are supported.

 * [Replace `?:` Ternary Operator](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/002609.html): Definitely magical, but it serves a very important use-case for terse selection of different values.  Proposals for alternatives have been intensely discussed, but none have been "better enough" for it to make sense to diverge from the precedent established by the C family of languages.

 * [`if/else` and `switch` as expressions](https://lists.swift.org/pipermail/swift-evolution/2015-December/000393.html): These are conceptually interesting things to support, but many of the problems solved by making these into expressions are already solved in Swift in other ways.  Making them expressions introduces significant tradeoffs, and on balance, we haven't found a design that is clearly better than what we have so far.

 * [Rewrite the Swift compiler in Swift](https://github.com/apple/swift/blob/2c7b0b22831159396fe0e98e5944e64a483c356e/www/FAQ.rst): This would be a lot of fun someday, but (unless you include rewriting all of LLVM) requires the ability to import C++ APIs into Swift.  Additionally, there are lots of higher priority ways to make Swift better.

 * [Change closure literal syntax] (https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/002583.html): Closure syntax in Swift has been carefully debated internally, and aspects of the design have strong motivations.  It is unlikely that we'll find something better, and any proposals to change it should have a very detailed understanding of the Swift grammar.

 * [Single-quotes `''` for Character literals](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151221/003977.html): Swift takes the approach of highly valuing Unicode.  However, there are multiple concepts of a character that could make sense in Unicode, and none is so much more commonly used than the others that it makes sense to privilege them.  We'd rather save single quoted literals for a greater purpose (e.g. non-escaped string literals).

 * [Replace `continue` keyword with synonyms from other scripting languages (e.g. next, skip, advance, etc)](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151221/004407.html): Swift is designed to feel like a member of the C family of languages.  Switching keywords away from C precedent without strong motivation is a non-goal.


Here are some other less-commonly proposed changes that have also been rejected:
 
* [Remove `;` Semicolons](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/002421.html): Semicolons within a line are an intentional expressivity feature.  Semicolons at the end of the line should be handled by a "linter", not by the compiler.

* [Remove support for `default:` in Switch, and just use `case _:`](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/001422.html): `default` is widely used, `case _` is too magical, and default is widely precedented in many C family languages.

