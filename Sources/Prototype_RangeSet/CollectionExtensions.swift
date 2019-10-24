// MARK: Subscripts

extension Collection {
    /// Accesses a view of this collection with the elements at the given
    /// indices.
    ///
    /// - Parameter indices: The indices of the elements to retrieve from this
    ///   collection.
    /// - Returns: A collection of the elements at the positions in `indices`.
    ///
    /// - Complexity: O(1)
    public subscript(indices: RangeSet<Index>) -> IndexingCollection<Self> {
        IndexingCollection(base: self, ranges: indices)
    }
}

extension MutableCollection {
    /// Accesses a mutable view of this collection with the elements at the
    /// given indices.
    ///
    /// - Parameter indices: The indices of the elements to retrieve from this
    ///   collection.
    /// - Returns: A collection of the elements at the positions in `indices`.
    ///
    /// - Complexity: O(1) to access the elements, O(*m*) to mutate the
    ///   elements at the positions in `indices`, where *m* is the number of
    ///   elements indicated by `indices`.
    public subscript(indices: RangeSet<Index>) -> IndexingCollection<Self> {
        get {
            IndexingCollection(base: self, ranges: indices)
        }
        set {
            for i in newValue.indices {
                self[i.base] = newValue[i]
            }
        }
    }
}

// MARK: - move(from:to:) / move(to:where:)

extension MutableCollection {
    /// Shifts the elements in the given range to the specified insertion point.
    ///
    /// - Parameters:
    ///   - range: The range of the elements to move.
    ///   - insertionPoint: The index to use as the insertion point for the
    ///     elements. `insertionPoint` must be a valid index of the collection.
    /// - Returns: The new bounds of the moved elements.
    ///
    /// - Returns: The new bounds of the moved elements.
    /// - Complexity: O(*n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func shift(
        from range: Range<Index>, toJustBefore insertionPoint: Index
    ) -> Range<Index> {
        if insertionPoint < range.lowerBound {
            let endIndex = _rotate(
                in: insertionPoint..<range.upperBound,
                shiftingToStart: range.lowerBound)
            return insertionPoint..<endIndex
        }

        if range.upperBound < insertionPoint {
            let startIndex = _rotate(
                in: range.lowerBound..<insertionPoint,
                shiftingToStart: range.upperBound)
            return startIndex..<insertionPoint
        }

        return range
    }

    /// Shifts the elements in the given range expression to the specified
    /// insertion point.
    ///
    /// - Parameters:
    ///   - range: The range of the elements to move.
    ///   - insertionPoint: The index to use as the insertion point for the
    ///     elements. `insertionPoint` must be a valid index of the collection.
    /// - Returns: The new bounds of the moved elements.
    ///
    /// - Complexity: O(*n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func shift<R : RangeExpression>(
        from range: R, toJustBefore insertionPoint: Index
    ) -> Range<Index> where R.Bound == Index {
        return shift(from: range.relative(to: self), toJustBefore: insertionPoint)
    }

    /// Moves the element at the given index to just before the specified
    /// insertion point.
    ///
    /// This method moves the element at position `i` to immediately before
    /// `insertionPoint`. This example shows moving elements forward and
    /// backward in an array of integers.
    ///
    ///     var numbers = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    ///     let newIndexOfNine = numbers.shift(from: 9, toJustBefore: 7)
    ///     // numbers == [0, 1, 2, 3, 4, 5, 6, 9, 7, 8, 10]
    ///     // newIndexOfNine == 7
    ///
    ///     let newIndexOfOne = numbers.shift(from: 1, toJustBefore: 4)
    ///     // numbers == [0, 2, 3, 1, 4, 5, 6, 9, 7, 8, 10]
    ///     // newIndexOfOne == 3
    ///
    /// To move an element to the end of a collection, pass the collection's
    /// `endIndex` as `insertionPoint`.
    ///
    ///     numbers.shift(from: 0, toJustBefore: numbers.endIndex)
    ///     // numbers == [2, 3, 1, 4, 5, 6, 9, 7, 8, 10, 0]
    ///
    /// - Parameters:
    ///   - source: The index of the element to move. `source` must be a valid
    ///     index of the collection that isn't `endIndex`.
    ///   - insertionPoint: The index to use as the destination of the element.
    ///     `insertionPoint` must be a valid index of the collection.
    /// - Returns: The resulting index of the element that began at `source`.
    ///
    /// - Complexity: O(*n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func shift(
        from source: Index, toJustBefore insertionPoint: Index
    ) -> Index {
        _failEarlyRangeCheck(source, bounds: startIndex..<endIndex)
        _failEarlyRangeCheck(insertionPoint, bounds: startIndex..<endIndex)
        if source == insertionPoint {
            return source
        } else if source < insertionPoint {
            return _rotate(in: source..<insertionPoint, shiftingToStart: index(after: source))
        } else {
            _rotate(in: insertionPoint..<index(after: source), shiftingToStart: source)
            return insertionPoint
        }
    }
    
    /// Moves the element at the given index to the specified destination.
    ///
    /// This method moves the element at position `source` to the position given
    /// as `destination`. This example shows moving elements forward and
    /// backward in an array of numbers.
    ///
    ///     var numbers = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    ///     numbers.move(from: 9, to: 7)
    ///     // numbers == [0, 1, 2, 3, 4, 5, 6, 9, 7, 8, 10]
    ///     // numbers[7] == 9
    ///
    ///     numbers.move(from: 1, to: 4)
    ///     // numbers == [0, 2, 3, 4, 1, 5, 6, 9, 7, 8, 10]
    ///     // numbers[4] == 1
    ///
    /// To move an element to the end of a collection, pass the collection's
    /// `endIndex` as the second parameter to the `shift(from:toJustBefore:)`
    /// method.
    ///
    /// Parameters:
    ///   - source: The index of the element to move. `source` must be a valid
    ///     index of the collection that isn't `endIndex`.
    ///   - destination: The index to use as the destination of the element.
    ///     `destination` must be a valid index of the collection that isn't
    ///     `endIndex`.
    ///
    /// - Complexity: O(*n*) where *n* is the length of the collection.
    internal mutating func move(from source: Index, to destination: Index) {
        _failEarlyRangeCheck(source, bounds: startIndex..<endIndex)
        _failEarlyRangeCheck(destination, bounds: startIndex..<endIndex)
        precondition(destination != endIndex, "Can't move an element to endIndex")
        if source == destination {
            return
        } else if source < destination {
            _rotate(in: source..<index(after: destination), shiftingToStart: index(after: source))
        } else {
            _rotate(in: destination..<index(after: source), shiftingToStart: source)
        }
    }

    /// Collects the elements at the given indices just before the specified
    /// index.
    ///
    /// This example finds all the uppercase letters in the array and then
    /// gathers them between `"i"` and `"j"`.
    ///
    ///     var letters = Array("ABCdeFGhijkLMNOp")
    ///     let uppercase = letters.indices(where: { $0.isUppercase })
    ///     let rangeOfUppercase = letters.gather(uppercase, justBefore: 10)
    ///     // String(letters) == "dehiABCFGLMNOjkp"
    ///     // rangeOfUppercase == 4..<13
    ///
    /// - Parameters:
    ///   - indices: The indices of the elements to move.
    ///   - insertionPoint: The index to use as the destination of the elements.
    /// - Returns: The new bounds of the moved elements.
    ///
    /// - Complexity: O(*n* log *n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func gather(
        _ indices: RangeSet<Index>, justBefore insertionPoint: Index
    ) -> Range<Index> {
        let lowerCount = distance(from: startIndex, to: insertionPoint)
        let upperCount = distance(from: insertionPoint, to: endIndex)
        let start = _indexedStablePartition(
            count: lowerCount,
            range: startIndex..<insertionPoint,
            by: { indices.contains($0) })
        let end = _indexedStablePartition(
            count: upperCount,
            range: insertionPoint..<endIndex,
            by: { !indices.contains($0) })
        return start..<end
    }

    /// Collects the elements that satisfy the given predicate just before the
    /// specified index.
    ///
    /// This example gathers all the uppercase letters in the array between
    /// `"i"` and `"j"`.
    ///
    ///     var letters = Array("ABCdeFGhijkLMNOp")
    ///     let rangeOfUppercase = letters.gather(justBefore: 10) { $0.isUppercase }
    ///     // String(letters) == "dehiABCFGLMNOjkp"
    ///     // rangeOfUppercase == 4..<13
    ///
    /// - Parameters:
    ///   - predicate: A closure that returns `true` for elements that should
    ///     move to `destination`.
    ///   - insertionPoint: The index to use as the destination of the elements.
    /// - Returns: The new bounds of the moved elements.
    ///
    /// - Complexity: O(*n* log *n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func gather(
        justBefore insertionPoint: Index, where predicate: (Element) -> Bool
    ) -> Range<Index> {
        let lowerCount = distance(from: startIndex, to: insertionPoint)
        let upperCount = distance(from: insertionPoint, to: endIndex)
        let start = _stablePartition(
            count: lowerCount,
            range: startIndex..<insertionPoint,
            by: { predicate($0) })
        let end = _stablePartition(
            count: upperCount,
            range: insertionPoint..<endIndex,
            by: { !predicate($0) })
        return start..<end
    }
}

// MARK: - removeAll(at:) / removingAll(at:)

extension RangeReplaceableCollection {
    /// Removes the elements at the given indices.
    ///
    /// For example, this code sample finds the indices of all the vowel
    /// characters in the string, and then removes those characters.
    ///
    ///     var str = "The rain in Spain stays mainly in the plain."
    ///     let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
    ///     let vowelIndices = str.indices(where: { vowels.contains($0) })
    ///
    ///     str.removeAll(at: vowelIndices)
    ///     // str == "Th rn n Spn stys mnly n th pln."
    ///
    /// - Parameter indices: The indices of the elements to remove.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the collection.
    public mutating func removeAll(at indices: RangeSet<Index>) {
        guard !indices.isEmpty else {
            return
        }
        
        let inversion = indices.inverted(within: self)
        var result = Self()
        for range in inversion.ranges {
            result.append(contentsOf: self[range])
        }
        self = result
    }
}

extension MutableCollection where Self: RangeReplaceableCollection {
    /// Removes the elements at the given indices.
    ///
    /// For example, this code sample finds the indices of all the negative
    /// numbers in the array, and then removes those values.
    ///
    ///     var numbers = [5, 7, -3, -8, 11, 2, -1, 6]
    ///     let negativeIndices = numbers.indices(where: { $0 < 0 })
    ///
    ///     numbers.removeAll(at: negativeIndices)
    ///     // numbers == [5, 7, 11, 2, 6]
    ///
    /// - Parameter indices: The indices of the elements to remove.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the collection.
    public mutating func removeAll(at indices: RangeSet<Index>) {
        guard let firstRange = indices.ranges.first else {
            return
        }
        
        var endOfElementsToKeep = firstRange.lowerBound
        var firstUnprocessed = firstRange.upperBound
        
        // This performs a half-stable partition based on the ranges in
        // `indices`. At all times, the collection is divided into three
        // regions:
        //
        // - `self[..<endOfElementsToKeep]` contains only elements that will
        //   remain in the collection after this method call.
        // - `self[endOfElementsToKeep..<firstUnprocessed]` contains only
        //   elements that will be removed.
        // - `self[firstUnprocessed...]` contains a mix of elements to remain
        //   and elements to be removed.
        //
        // Each iteration of this loop moves the elements that are _between_
        // two ranges to remove from the third region to the first region.
        for range in indices.ranges.dropFirst() {
            let nextLow = range.lowerBound
            while firstUnprocessed != nextLow {
                swapAt(endOfElementsToKeep, firstUnprocessed)
                formIndex(after: &endOfElementsToKeep)
                formIndex(after: &firstUnprocessed)
            }
            
            firstUnprocessed = range.upperBound
        }
        
        // After dealing with all the ranges in `indices`, move the elements
        // that are still in the third region down to the first.
        while firstUnprocessed != endIndex {
            swapAt(endOfElementsToKeep, firstUnprocessed)
            formIndex(after: &endOfElementsToKeep)
            formIndex(after: &firstUnprocessed)
        }
        
        removeSubrange(endOfElementsToKeep..<endIndex)
    }
}

extension Collection {
    /// Returns a collection of the elements in this collection that are not
    /// represented by the given range set.
    ///
    /// For example, this code sample finds the indices of all the vowel
    /// characters in the string, and then retrieves a collection that omits
    /// those characters.
    ///
    ///     let str = "The rain in Spain stays mainly in the plain."
    ///     let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
    ///     let vowelIndices = str.indices(where: { vowels.contains($0) })
    ///
    ///     let disemvoweled = str.removingAll(at: vowelIndices)
    ///     print(String(disemvoweled))
    ///     // Prints "Th rn n Spn stys mnly n th pln."
    ///
    /// - Parameter indices: A range set representing the elements to remove.
    /// - Returns: A collection of the elements that are not in `indices`.
    public func removingAll(at indices: RangeSet<Index>) -> IndexingCollection<Self> {
        let inversion = indices.inverted(within: self)
        return self[inversion]
    }
}

// MARK: - indices(of:) / indices(where:)

extension Collection where Element: Equatable {
    /// Returns the indices of all the elements that are equal to the given
    /// element.
    ///
    /// For example, you can use this method to find all the places that a
    /// particular letter occurs in a string.
    ///
    ///     let str = "Fresh cheese in a breeze"
    ///     let allTheEs = str.indices(of: "e")
    ///     // str[allTheEs].count == 7
    ///
    /// - Parameter element: An element to look for in the collection.
    /// - Returns: A set of the indices of the elements that are equal to
    ///   `element`.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the collection.
    public func indices(of element: Element) -> RangeSet<Index> {
        indices(where: { $0 == element })
    }
}

extension Collection {
    /// Returns the indices of all the elements that match the given predicate.
    ///
    /// For example, you can use this method to find all the places that a
    /// vowel occurs in a string.
    ///
    ///     let str = "Fresh cheese in a breeze"
    ///     let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
    ///     let allTheVowels = str.indices(where: { vowels.contains($0) })
    ///     // str[allTheVowels].count == 9
    ///
    /// - Parameter predicate: A closure that takes an element as its argument
    ///   and returns a Boolean value that indicates whether the passed element
    ///   represents a match.
    /// - Returns: A set of the indices of the elements for which `predicate`
    ///   returns `true`.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the collection.
    public func indices(where predicate: (Element) throws -> Bool) rethrows
        -> RangeSet<Index>
    {
        if isEmpty { return [] }
        
        var result = RangeSet<Index>()
        var i = startIndex
        while i != endIndex {
            let next = index(after: i)
            if try predicate(self[i]) {
                result._append(i..<next)
            }
            i = next
        }
        
        return result
    }
}

