// MARK: rotate(shiftingToStart:)

extension MutableCollection {
    /// Rotates the elements of the collection so that the element at the
    /// specified index ends up first.
    ///
    /// - Parameter middle: The index of the element to rotate to the front of
    ///   the collection.
    /// - Returns: The new index of the element that was first pre-rotation.
    ///
    /// - Complexity: O(*n*)
    @discardableResult
    public mutating func rotate(shiftingToStart middle: Index) -> Index {
        _rotate(in: startIndex..<endIndex, shiftingToStart: middle)
    }

    /// Rotates the elements of the collection so that the element at `middle`
    /// ends up first.
    ///
    /// - Returns: The new index of the element that was first pre-rotation.
    ///
    /// - Complexity: O(*n*)
    @discardableResult
    mutating func _rotate(in subrange: Range<Index>, shiftingToStart middle: Index) -> Index {
        var m = middle, s = subrange.lowerBound
        let e = subrange.upperBound

        // Handle the trivial cases
        if s == m { return e }
        if m == e { return s }

        // We have two regions of possibly-unequal length that need to be
        // exchanged.  The return value of this method is going to be the
        // position following that of the element that is currently last
        // (element j).
        //
        //   [a b c d e f g|h i j]   or   [a b c|d e f g h i j]
        //   ^             ^     ^        ^     ^             ^
        //   s             m     e        s     m             e
        //
        var ret = e // start with a known incorrect result.
        while true {
            // Exchange the leading elements of each region (up to the
            // length of the shorter region).
            //
            //   [a b c d e f g|h i j]   or   [a b c|d e f g h i j]
            //    ^^^^^         ^^^^^          ^^^^^ ^^^^^
            //   [h i j d e f g|a b c]   or   [d e f|a b c g h i j]
            //   ^     ^       ^     ^         ^    ^     ^       ^
            //   s    s1       m    m1/e       s   s1/m   m1      e
            //
            let (s1, m1) = _swapNonemptySubrangePrefixes(s..<m, m..<e)

            if m1 == e {
                // Left-hand case: we have moved element j into position.  if
                // we haven't already, we can capture the return value which
                // is in s1.
                //
                // Note: the STL breaks the loop into two just to avoid this
                // comparison once the return value is known.  I'm not sure
                // it's a worthwhile optimization, though.
                if ret == e { ret = s1 }

                // If both regions were the same size, we're done.
                if s1 == m { break }
            }

            // Now we have a smaller problem that is also a rotation, so we
            // can adjust our bounds and repeat.
            //
            //    h i j[d e f g|a b c]   or    d e f[a b c|g h i j]
            //         ^       ^     ^              ^     ^       ^
            //         s       m     e              s     m       e
            s = s1
            if s == m { m = m1 }
        }

        return ret
    }

    /// Swaps the elements of the two given subranges, up to the upper bound of
    /// the smaller subrange. The returned indices are the ends of the two
    /// ranges that were actually swapped.
    ///
    ///     Input:
    ///     [a b c d e f g h i j k l m n o p]
    ///      ^^^^^^^         ^^^^^^^^^^^^^
    ///      lhs             rhs
    ///
    ///     Output:
    ///     [i j k l e f g h a b c d m n o p]
    ///             ^               ^
    ///             p               q
    ///
    /// - Precondition: !lhs.isEmpty && !rhs.isEmpty
    /// - Postcondition: For returned indices `(p, q)`:
    ///
    ///   - distance(from: lhs.lowerBound, to: p) == distance(from:
    ///     rhs.lowerBound, to: q)
    ///   - p == lhs.upperBound || q == rhs.upperBound
    mutating func _swapNonemptySubrangePrefixes(
        _ lhs: Range<Index>, _ rhs: Range<Index>
    ) -> (Index, Index) {
        assert(!lhs.isEmpty)
        assert(!rhs.isEmpty)

        var p = lhs.lowerBound
        var q = rhs.lowerBound
        repeat {
            swapAt(p, q)
            formIndex(after: &p)
            formIndex(after: &q)
        }
        while p != lhs.upperBound && q != rhs.upperBound
        return (p, q)
    }

}

// MARK: - halfStablePartition(by:)

extension MutableCollection {
    /// Moves all elements satisfying `belongsInSecondPartition` into a suffix
    /// of the collection, preserving the relative order of the prefix, and
    /// returns the start of the resulting suffix.
    ///
    /// This code example moves all the negative values in the `numbers` array
    /// to a section at the end of the array.
    ///
    ///     var numbers = Array(-5...5)
    ///     let startOfNegatives = numbers.halfStablePartition(by: { $0 < 0 })
    ///     // numbers == [0, 1, 2, 3, 4, 5, -4, -3, -2, -1, -5]
    ///
    /// Note that while the operation maintains the order of the beginning
    /// section of the array, the elements in the ending section have been
    /// rearranged.
    ///
    ///     // numbers[..<startOfNegatives] == [0, 1, 2, 3, 4, 5]
    ///     // numbers[startOfNegatives...] == [-4, -3, -2, -1, -5]
    ///
    /// - Parameter belongsInSecondPartition: A predicate used to partition the
    ///   collection. All elements satisfying this predicate are ordered after
    ///   all elements not satisfying it.
    /// - Returns: The index of the first element in the reordered collection
    ///   that matches `belongsInSecondPartition`. If no elements in the
    ///   collection match `belongsInSecondPartition`, the returned index is
    ///   equal to the collection's `endIndex`.
    ///
    /// - Complexity: O(*n*) where *n* is the number of elements.
    @discardableResult
    public mutating func halfStablePartition(
        by belongsInSecondPartition: (Element) throws -> Bool
    ) rethrows -> Index {
        guard var i = try firstIndex(where: belongsInSecondPartition)
            else { return endIndex }
        
        var j = index(after: i)
        while j != endIndex {
            if try !belongsInSecondPartition(self[j]) {
                swapAt(i, j)
                formIndex(after: &i)
            }
            formIndex(after: &j)
        }
        return i
    }
}

// MARK: - stablePartition(by:) / stablyPartitioned(by:)

extension Collection {
    /// Returns an array of the elements in this collection, partitioned by the
    /// given predicate, and the index of the start of the second region.
    ///
    /// This code example moves all the negative values in the `numbers` array
    /// to a section at the end of the array.
    ///
    ///     let numbers = Array(-5...5)
    ///     let (partitioned, startOfNegatives) =
    ///         numbers.stablyPartitioned(by: { $0 < 0 })
    ///     // partitioned == [0, 1, 2, 3, 4, 5, -5, -4, -3, -2, -1]
    ///
    /// The partitioning operation maintains the initial relative order of the
    /// elements in each section of the array.
    ///
    ///     // partitioned[..<startOfNegatives] == [0, 1, 2, 3, 4, 5]
    ///     // partitioned[startOfNegatives...] == [-5, -4, -3, -2, -1]
    ///
    /// - Parameter belongsInSecondPartition: A predicate used to partition the
    ///   collection. All elements satisfying this predicate are ordered after
    ///   all elements not satisfying it.
    /// - Returns: The index of the first element in the reordered collection
    ///   that matches `belongsInSecondPartition`. If no elements in the
    ///   collection match `belongsInSecondPartition`, the returned index is
    ///   equal to the collection's `endIndex`.
    ///
    /// - Complexity: O(*n*) where *n* is the number of elements.
    public func stablyPartitioned(
        by belongsInSecondPartition: (Element) throws -> Bool
    ) rethrows -> (partitioned: [Element], partitioningIndex: Int) {
        var partitionPoint = 0
        let result = try Array<Element>(unsafeUninitializedCapacity: count) {
            buffer, initializedCount in
            var low = buffer.baseAddress!
            var high = low + buffer.count
            do {
                for element in self {
                    if try belongsInSecondPartition(element) {
                        high -= 1
                        high.initialize(to: element)
                    } else {
                        low.initialize(to: element)
                        low += 1
                    }
                }
                
                partitionPoint = high - buffer.baseAddress!
                buffer[partitionPoint...].reverse()
                initializedCount = buffer.count
            } catch {
                let lowCount = low - buffer.baseAddress!
                let highCount = (buffer.baseAddress! + buffer.count) - high
                buffer.baseAddress!.deinitialize(count: lowCount)
                high.deinitialize(count: highCount)
                throw error
            }
        }
        return (result, partitionPoint)
    }
}

extension MutableCollection {
    /// Moves all elements satisfying `belongsInSecondPartition` into a suffix
    /// of the collection, preserving their relative order, and returns the
    /// start of the resulting suffix.
    ///
    /// This code example moves all the negative values in the `numbers` array
    /// to a section at the end of the array.
    ///
    ///     var numbers = Array(-5...5)
    ///     let startOfNegatives = numbers.halfStablePartition(by: { $0 < 0 })
    ///     // numbers == [0, 1, 2, 3, 4, 5, -5, -4, -3, -2, -1]
    ///
    /// The partitioning operation maintains the initial relative order of the
    /// elements in each section of the array.
    ///
    ///     // numbers[..<startOfNegatives] == [0, 1, 2, 3, 4, 5]
    ///     // numbers[startOfNegatives...] == [-5, -4, -3, -2, -1]
    ///
    /// - Parameter belongsInSecondPartition: A predicate used to partition the
    ///   collection. All elements satisfying this predicate are ordered after
    ///   all elements not satisfying it.
    /// - Returns: The index of the first element in the reordered collection
    ///   that matches `belongsInSecondPartition`. If no elements in the
    ///   collection match `belongsInSecondPartition`, the returned index is
    ///   equal to the collection's `endIndex`.
    ///
    /// - Complexity: O(*n* log *n*) where *n* is the number of elements.
    @discardableResult
    public mutating func stablePartition(
        by belongsInSecondPartition: (Element) throws -> Bool
    ) rethrows -> Index {
        return try _stablePartition(
            count: count,
            range: startIndex..<endIndex,
            by: belongsInSecondPartition)
    }
    
    /// Moves all elements satisfying `belongsInSecondPartition` into a suffix
    /// of the collection, preserving their relative order, and returns the
    /// start of the resulting suffix.
    ///
    /// - Complexity: O(*n* log *n*) where *n* is the number of elements.
    /// - Precondition:
    ///   `n == distance(from: range.lowerBound, to: range.upperBound)`
    mutating func _stablePartition(
        count n: Int,
        range: Range<Index>,
        by belongsInSecondPartition: (Element) throws-> Bool
    ) rethrows -> Index {
        if n == 0 { return range.lowerBound }
        if n == 1 {
            return try belongsInSecondPartition(self[range.lowerBound])
                ? range.lowerBound
                : range.upperBound
        }
        let h = n / 2, i = index(range.lowerBound, offsetBy: h)
        let j = try _stablePartition(
            count: h,
            range: range.lowerBound..<i,
            by: belongsInSecondPartition)
        let k = try _stablePartition(
            count: n - h,
            range: i..<range.upperBound,
            by: belongsInSecondPartition)
        return _rotate(in: j..<k, shiftingToStart: i)
    }

    /// Moves all elements at the indices satisfying `belongsInSecondPartition`
    /// into a suffix of the collection, preserving their relative order, and
    /// returns the start of the resulting suffix.
    ///
    /// - Complexity: O(*n* log *n*) where *n* is the number of elements.
    /// - Precondition:
    ///   `n == distance(from: range.lowerBound, to: range.upperBound)`
    mutating func _indexedStablePartition(
        count n: Int,
        range: Range<Index>,
        by belongsInSecondPartition: (Index) throws-> Bool
    ) rethrows -> Index {
        if n == 0 { return range.lowerBound }
        if n == 1 {
            return try belongsInSecondPartition(range.lowerBound)
                ? range.lowerBound
                : range.upperBound
        }
        let h = n / 2, i = index(range.lowerBound, offsetBy: h)
        let j = try _indexedStablePartition(
            count: h,
            range: range.lowerBound..<i,
            by: belongsInSecondPartition)
        let k = try _indexedStablePartition(
            count: n - h,
            range: i..<range.upperBound,
            by: belongsInSecondPartition)
        return _rotate(in: j..<k, shiftingToStart: i)
    }
}

// MARK: - partitioningIndex(where:)

extension Collection {
    /// Returns the index of the first element in the collection that matches
    /// the predicate.
    ///
    /// The collection must already be partitioned according to the predicate.
    /// That is, there should be an index `i` where for every element in
    /// `collection[..<i]` the predicate is `false`, and for every element
    /// in `collection[i...]` the predicate is `true`.
    ///
    /// - Parameter predicate: A predicate that partitions the collection.
    /// - Returns: The index of the first element in the collection for which
    ///   `predicate` returns `true`.
    ///
    /// - Complexity: O(log *n*), where *n* is the length of this collection if
    ///   the collection conforms to `RandomAccessCollection`, otherwise O(*n*).
    internal func partitioningIndex(
        where predicate: (Element) throws -> Bool
    ) rethrows -> Index {
        var n = count
        var l = startIndex
        
        while n > 0 {
            let half = n / 2
            let mid = index(l, offsetBy: half)
            if try predicate(self[mid]) {
                n = half
            } else {
                l = index(after: mid)
                n -= half + 1
            }
        }
        return l
    }
}

