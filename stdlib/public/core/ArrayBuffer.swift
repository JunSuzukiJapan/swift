//===--- ArrayBuffer.swift - Dynamic storage for Swift Array --------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2015 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
//  This is the class that implements the storage and object management for
//  Swift Array.
//
//===----------------------------------------------------------------------===//

#if _runtime(_ObjC)
import SwiftShims

internal typealias _ArrayBridgeStorage
  = _BridgeStorage<_ContiguousArrayStorageBase, _NSArrayCoreType>

public struct _ArrayBuffer<T> : _ArrayBufferType {

  public typealias Element = T

  /// create an empty buffer
  public init() {
    _storage = _ArrayBridgeStorage(native: _emptyArrayStorage)
  }

  public init(nsArray: _NSArrayCoreType) {
    _sanityCheck(_isClassOrObjCExistential(T.self))
    _storage = _ArrayBridgeStorage(objC: nsArray)
  }

  /// Returns an `_ArrayBuffer<U>` containing the same elements.
  ///
  /// Requires: the elements actually have dynamic type `U`, and `U`
  /// is a class or `@objc` existential.
  func castToBufferOf<U>(_: U.Type) -> _ArrayBuffer<U> {
    _sanityCheck(_isClassOrObjCExistential(T.self))
    _sanityCheck(_isClassOrObjCExistential(U.self))
    return _ArrayBuffer<U>(storage: _storage)
  }

  /// The spare bits that are set when a native array needs deferred
  /// element type checking.
  var deferredTypeCheckMask : Int { return 1 }
  
  /// Returns an `_ArrayBuffer<U>` containing the same elements,
  /// deffering checking each element's `U`-ness until it is accessed.
  ///
  /// Requires: `U` is a class or `@objc` existential derived from `T`.
  func downcastToBufferWithDeferredTypeCheckOf<U>(
    _: U.Type
  ) -> _ArrayBuffer<U> {
    _sanityCheck(_isClassOrObjCExistential(T.self))
    _sanityCheck(_isClassOrObjCExistential(U.self))
    
    // FIXME: can't check that U is derived from T pending
    // <rdar://problem/19915280> generic metatype casting doesn't work
    // _sanityCheck(U.self is T.Type)

    return _ArrayBuffer<U>(
      storage: _ArrayBridgeStorage(
        native: _native._storage, bits: deferredTypeCheckMask))
  }

  var needsElementTypeCheck: Bool {
    // NSArray's need an element typecheck when the element type isn't AnyObject
    return _isClassOrObjCExistential(T.self) && (
      _storage.isObjC || (_storage.spareBits & deferredTypeCheckMask != 0)
    ) && !(AnyObject.self is T.Type)
  }
  
  //===--- private --------------------------------------------------------===//
  internal init(storage: _ArrayBridgeStorage) {
    _storage = storage
  }

  internal var _storage: _ArrayBridgeStorage
}

extension _ArrayBuffer {
  /// Adopt the storage of source
  public
  init(_ source: NativeBuffer) {
    _storage = _ArrayBridgeStorage(native: source._storage)
  }

  var arrayPropertyIsNative : Bool {
    if !_isClassOrObjCExistential(T.self) {
      return true
    }
    return !_storage.isObjC
  }

  var arrayPropertyNeedsElementTypeCheck : Bool {
    if !_isClassOrObjCExistential(T.self) {
      return false
    }
    return needsElementTypeCheck
  }

  /// Return true iff this buffer's storage is uniquely-referenced.
  mutating func isUniquelyReferenced() -> Bool {
    if !_isClassOrObjCExistential(T.self) {
      return _storage.isUniquelyReferenced_native_noSpareBits()
    }
    return _storage.isUniquelyReferencedNative() && _isNative
  }

  /// Return true iff this buffer's storage is either
  /// uniquely-referenced or pinned.
  mutating func isUniquelyReferencedOrPinned() -> Bool {
    if !_isClassOrObjCExistential(T.self) {
      return _storage.isUniquelyReferencedOrPinned_native_noSpareBits()
    }
    return _storage.isUniquelyReferencedOrPinnedNative() && _isNative
  }

  /// Convert to an NSArray.
  /// Precondition: _isBridgedToObjectiveC(Element.self)
  /// O(1) if the element type is bridged verbatim, O(N) otherwise
  public func _asCocoaArray() -> _NSArrayCoreType {
    _sanityCheck(
      _isBridgedToObjectiveC(T.self),
      "Array element type is not bridged to Objective-C")

    return _fastPath(_isNative) ? _native._asCocoaArray() : _nonNative
  }

  /// If this buffer is backed by a uniquely-referenced mutable
  /// _ContiguousArrayBuffer that can be grown in-place to allow the self
  /// buffer store minimumCapacity elements, returns that buffer.
  /// Otherwise, returns nil
  public
  mutating func requestUniqueMutableBackingBuffer(minimumCapacity: Int)
    -> NativeBuffer?
  {
    if _fastPath(isUniquelyReferenced()) {
      let b = _native
      if _fastPath(b.capacity >= minimumCapacity) {
        return b
      }
    }
    return nil
  }

  public
  mutating func isMutableAndUniquelyReferenced() -> Bool {
    return isUniquelyReferenced()
  }
  
  public
  mutating func isMutableAndUniquelyReferencedOrPinned() -> Bool {
    return isUniquelyReferencedOrPinned()
  }

  /// If this buffer is backed by a `_ContiguousArrayBuffer`
  /// containing the same number of elements as `self`, return it.
  /// Otherwise, return `nil`.
  public func requestNativeBuffer() -> NativeBuffer? {
    if !_isClassOrObjCExistential(T.self) {
      return _native
    }
    return _fastPath(_storage.isNative) ? _native : nil
  }

  /// Replace the given subRange with the first newCount elements of
  /// the given collection.
  ///
  /// Requires: this buffer is backed by a uniquely-referenced
  /// _ContiguousArrayBuffer
  public
  mutating func replace<C: CollectionType where C.Generator.Element == Element>(
    #subRange: Range<Int>, with newCount: Int, elementsOf newValues: C
  ) {
    _arrayNonSliceInPlaceReplace(&self, subRange, newCount, newValues)
  }

  // We have two versions of type check: one that takes a range and the other
  // checks one element. The reason for this is that the ARC optimizer does not
  // handle loops atm. and so can get blocked by the presence of a loop (over
  // the range). This loop is not necessary for a single element access.
  func _typeCheck(index: Int, hoistedNeedsElementTypeCheck: Bool) {
    if !_isClassOrObjCExistential(T.self) {
      return
    }    
    if _slowPath(hoistedNeedsElementTypeCheck) {
      _typeCheckSlowPath(index)
    } else {
      // For memory safety we need to check the actual storage. Because of
      // hoisting of array properties hoistedNeedsElementTypeCheck might not be
      // correct in case inout rules where violated. If inout rules are violated
      // we want to catch this be failing.
      // Example:
      //  func f(inout a : A[AClass]) {
      //    let b = a.props.isNative() // Hoisted.
      //    for i in 0..a.count {
      //              _typeCheck(a, i, b)
      //       .. += _getElement(a, i, b)
      //       g() // g should not be able to access 'a' but could if inout
      //           // safety was violated.
      //    }
      //  }
      _precondition(!needsElementTypeCheck,
           "inout rules were violated: the array was overwritten by an NSArray")
    }

  }

  @inline(never)
  internal func _typeCheckSlowPath(index: Int) {
    if _fastPath(_isNative) {
      let element: AnyObject = castToBufferOf(AnyObject.self)._native[index]
      _precondition(
        element is T,
        "Down-casted Array element failed to match the target type")
    }
    else  {
      let ns = _nonNative
      _precondition(
        ns.objectAtIndex(index) is T,
        "NSArray element failed to match the Swift Array Element type")
    }
  }

  func _typeCheck(subRange: Range<Int>) {
    if !_isClassOrObjCExistential(T.self) {
      return
    }

    if _slowPath(needsElementTypeCheck) {
      // Could be sped up, e.g. by using
      // enumerateObjectsAtIndexes:options:usingBlock: in the
      // non-native case.
      for i in subRange {
        _typeCheck(i, hoistedNeedsElementTypeCheck: true)
      }
    }
  }
  
  /// Copy the given subRange of this buffer into uninitialized memory
  /// starting at target.  Return a pointer past-the-end of the
  /// just-initialized memory.
  @inline(never) // The copy loop blocks retain release matching.
  public
  func _uninitializedCopy(subRange: Range<Int>, target: UnsafeMutablePointer<T>)
         -> UnsafeMutablePointer<T> {
    _typeCheck(subRange)
    if _fastPath(_isNative) {
      return _native._uninitializedCopy(subRange, target: target)
    }

    let nonNative = _nonNative

    let nsSubRange = SwiftShims._SwiftNSRange(
      location:subRange.startIndex,
      length: subRange.endIndex - subRange.startIndex)

    let buffer = UnsafeMutablePointer<AnyObject>(target)
    
    // Copies the references out of the NSArray without retaining them
    nonNative.getObjects(buffer, range: nsSubRange)
    
    // Make another pass to retain the copied objects
    var result = target
    for i in subRange {
      result.initialize(result.memory)
      ++result
    }
    return result
  }
  
  /// Return a _SliceBuffer containing the given subRange of values
  /// from this buffer.
  public
  subscript(subRange: Range<Int>) -> _SliceBuffer<T> {
    _typeCheck(subRange)
    
    if _fastPath(_isNative) {
      return _native[subRange]
    }

    let nonNative = self._nonNative

    let subRangeCount = Swift.count(subRange)
    
    // Look for contiguous storage in the NSArray
    let cocoa = _CocoaArrayWrapper(nonNative)
    let start = cocoa.contiguousStorage(subRange)
    if start != nil {
      return _SliceBuffer(owner: nonNative, start: UnsafeMutablePointer(start),
          count: subRangeCount, hasNativeBuffer: false)
    }
    
    // No contiguous storage found; we must allocate
    var result = _ContiguousArrayBuffer<T>(
        count: subRangeCount, minimumCapacity: 0)

    // Tell Cocoa to copy the objects into our storage
    cocoa.buffer.getObjects(
      UnsafeMutablePointer(result.baseAddress),
      range: _SwiftNSRange(location: subRange.startIndex, length: subRangeCount)
    )

    return _SliceBuffer(result)
  }

  /// Precondition: _isNative is true.
  internal func _getBaseAddress() -> UnsafeMutablePointer<T> {
    _sanityCheck(_isNative, "must be a native buffer")
    return _native.baseAddress
  }

  /// If the elements are stored contiguously, a pointer to the first
  /// element. Otherwise, nil.
  public
  var baseAddress: UnsafeMutablePointer<T> {
    if (_fastPath(_isNative)) {
      return _native.baseAddress
    }
    return nil
  }
  
  /// How many elements the buffer stores
  public
  var count: Int {
    @inline(__always)
    get {
      return _fastPath(_isNative) ? _native.count : _nonNative.count
    }
    set {
      _sanityCheck(_isNative, "attempting to update count of Cocoa array")
      _native.count = newValue
    }
  }
  
  /// Return whether the given `index` is valid for subscripting, i.e. `0
  /// ≤ index < count`
  internal func _isValidSubscript(index : Int,
                                  hoistedIsNativeBuffer: Bool) -> Bool {
    if _fastPath(hoistedIsNativeBuffer) {
      // We need this precondition check to ensure memory safety. It ensures
      // that if due to an inout violation a store of a different representation
      // to the array (an NSArray) happened between 'hoistedIsNativeBuffer' was
      // obtained  and now we still are memory safe. To ensure safety we need to
      // reload the 'isNative' flag from memory which _isNative will do -
      // instead of relying on the value in 'hoistedIsNativeBuffer' which could
      // have been invalidated by an intervening store since we obtained
      // 'hoistedIsNativeBuffer'. See also the comment of _typeCheck.
      if (_isClassOrObjCExistential(T.self)) {
        // Only non value elements can have non native storage.
        _precondition(_isNative,
          "inout rules were violated: the array was overwritten by an NSArray")
      }

      /// Note we call through to the native buffer here as it has a more
      /// optimal implementation than just doing 'index < count'
      return _native._isValidSubscript(index,
                                   hoistedIsNativeBuffer: hoistedIsNativeBuffer)
    }
    return index >= 0 && index < count
  }

  /// How many elements the buffer can store without reallocation
  public
  var capacity: Int {
    return _fastPath(_isNative) ? _native.capacity : _nonNative.count
  }

  @inline(__always)
  func getElement(i: Int, hoistedIsNativeBuffer: Bool,
                  hoistedNeedsElementTypeCheck: Bool) -> T {
    if _isClassOrObjCExistential(T.self) {
      _typeCheck(i, hoistedNeedsElementTypeCheck: hoistedNeedsElementTypeCheck)
    }
    if _fastPath(hoistedIsNativeBuffer) {
      return _native[i]
    }
    return unsafeBitCast(_nonNative.objectAtIndex(i), T.self)
  }

  /// Get/set the value of the ith element
  public
  subscript(i: Int) -> T {
    get {
      return getElement(i, hoistedIsNativeBuffer:!_storage.isObjC,
                        hoistedNeedsElementTypeCheck: needsElementTypeCheck)
    }
    
    nonmutating set {
      if _fastPath(_isNative) {
        _native[i] = newValue
      }
      else {
        var refCopy = self
        refCopy.replace(
          subRange: i...i, with: 1, elementsOf: CollectionOfOne(newValue))
      }
    }
  }

  /// Call `body(p)`, where `p` is an `UnsafeBufferPointer` over the
  /// underlying contiguous storage.  If no such storage exists, it is
  /// created on-demand.
  public
  func withUnsafeBufferPointer<R>(
    @noescape body: (UnsafeBufferPointer<Element>) -> R
  ) -> R {
    if _fastPath(_isNative) {
      let ret = body(UnsafeBufferPointer(start: self.baseAddress, count: count))
      _fixLifetime(self)
      return ret
    }
    return ContiguousArray(self).withUnsafeBufferPointer(body)
  }
  
  /// Call `body(p)`, where `p` is an `UnsafeMutableBufferPointer`
  /// over the underlying contiguous storage.  Requires: such
  /// contiguous storage exists or the buffer is empty
  public
  mutating func withUnsafeMutableBufferPointer<R>(
    @noescape body: (UnsafeMutableBufferPointer<T>) -> R
  ) -> R {
    _sanityCheck(
      baseAddress != nil || count == 0,
      "Array is bridging an opaque NSArray; can't get a pointer to the elements"
    )
    let ret = body(
      UnsafeMutableBufferPointer(start: baseAddress, count: count))
    _fixLifetime(self)
    return ret
  }
  
  /// An object that keeps the elements stored in this buffer alive
  public
  var owner: AnyObject {
    return _fastPath(_isNative) ? _native._storage : _nonNative
  }
  
  /// A value that identifies the storage used by the buffer.  Two
  /// buffers address the same elements when they have the same
  /// identity and count.
  public var identity: UnsafePointer<Void> {
    if _isNative {
      return _native.identity
    }
    else {
      return unsafeAddressOf(_nonNative)
    }
  }
  
  //===--- CollectionType conformance -------------------------------------===//
  /// The position of the first element in a non-empty collection.
  ///
  /// Identical to `endIndex` in an empty collection.
  public
  var startIndex: Int {
    return 0
  }

  /// The collection's "past the end" position.
  ///
  /// `endIndex` is not a valid argument to `subscript`, and is always
  /// reachable from `startIndex` by zero or more applications of
  /// `successor()`.
  public var endIndex: Int {
    return count
  }

  /// Return a *generator* over the elements of this *sequence*.
  ///
  /// Complexity: O(1)
  public func generate() -> IndexingGenerator<_ArrayBuffer> {
    return IndexingGenerator(self)
  }
  
  //===--- private --------------------------------------------------------===//
  typealias Storage = _ContiguousArrayStorage<T>
  typealias NativeBuffer = _ContiguousArrayBuffer<T>

  func _invariantCheck() -> Bool {
    return true
  }

  var _isNative: Bool {
    if !_isClassOrObjCExistential(T.self) {
      return true
    }
    else {
      return _storage.isNative
    }
  }

  /// Our native representation.
  ///
  /// Requires: `_isNative`
  var _native: NativeBuffer {
    return NativeBuffer(
      _isClassOrObjCExistential(T.self)
      ? _storage.nativeInstance : _storage.nativeInstance_noSpareBits)
  }

  var _nonNative: _NSArrayCoreType {
    @inline(__always)
    get {
      _sanityCheck(_isClassOrObjCExistential(T.self))
        return _storage.objCInstance
    }
  }
}
#endif