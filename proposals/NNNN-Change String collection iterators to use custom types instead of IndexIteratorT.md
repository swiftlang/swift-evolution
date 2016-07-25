# Feature name

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Michael Gottesman](https://github.com/gottesmm)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Iterators are very important for performance since we use them for for loops. By default collections if they do not provide a custom iterator use IndexingIterator as an iterator. IndexingIterator, while only supporting forward movement, is based on indices which possess the ability to go backwards and forwards. For the various String.*Views, backwards iteration adds unnecessary cost/complexity. In order to preserve future flexibility, we want to change these types to use custom types that are essentially just IndexingIterator<T>. Then later on when we want to implement these optimizations, we can do it on the custom type underneath the hood without changing the API/ABI.

Swift-evolution thread: [[Proposal] Change some collection iterators to use custom types instead of IndexIterator<T>](http://article.gmane.org/gmane.comp.lang.swift.evolution/24822)

## Motivation

The motivation behind this proposal is simply to enable us to make further changes without causing API breakage.

## Proposed solution

The solution is to simply gyb the code for IndexingIterator for each one of the iterators.

## Detailed design

Specifically, IndexingIterator will be extracted into a gyb file and in addition to IndexingIterator, we will use gyb to create the following 3 iterators.

1. String.CharacterView.CharacterViewIterator
2. String.UTF16View.UTF16ViewIterator
3. String.UTF8View.UTF8ViewIterator

Then in the conformance of String.{CharacterView,UTF16View,UTF8View} to CollectionType, the relevant iterator will be specified as the Iterator associated type.

## Impact on existing code

The only impact on existing code would be that code that sets a variable to have the type IndexingIterator<StringView> and assigns it the value returned from stringview.makeIterator() will no longer compile. This can be fixed via a simple fix it.

## Alternatives considered

Alternatively we could take the performance hit here (which is not preferable) or break the API after swift 3 (which is also not preferable).
