# -*- coding: utf-8 -*-
# cython: embedsignature=True
# cython: profile=False
# cython: linetrace=False
# cython: binding=False
from __future__ import absolute_import, print_function, division


# noinspection PyUnresolvedReferences
from cpython cimport array, PyObject
import array
from cpython.buffer cimport PyObject_GetBuffer, PyBuffer_Release, PyBUF_ANY_CONTIGUOUS, \
    PyBUF_WRITEABLE
from cpython.bytes cimport PyBytes_FromStringAndSize, PyBytes_AS_STRING


from numcodecs.compat import PY2
from numcodecs.abc import Codec


cdef extern from "lz4.h":

    const char* LZ4_versionString() nogil

    int LZ4_compress_fast(const char* source,
                          char* dest,
                          int sourceSize,
                          int maxDestSize,
                          int acceleration) nogil

    int LZ4_decompress_safe(const char* source,
                            char* dest,
                            int compressedSize,
                            int maxDecompressedSize) nogil

    int LZ4_compressBound(int inputSize) nogil


cdef extern from "stdint_compat.h":
    cdef enum:
        UINT32_SIZE,
    void store_le32(char *c, int y)
    int load_le32(const char *c)



VERSION_STRING = LZ4_versionString()
if not PY2:
    VERSION_STRING = str(VERSION_STRING, 'ascii')
__version__ = VERSION_STRING
DEFAULT_ACCELERATION = 1


cdef class MyBuffer:
    """Compatibility class to work around fact that array.array does not support new-style buffer
    interface in PY2."""

    cdef:
        char *ptr
        Py_buffer buffer
        size_t nbytes
        size_t itemsize
        array.array arr
        bint new_buffer

    def __cinit__(self, obj, flags):
        if PY2 and isinstance(obj, array.array):
            self.new_buffer = False
            self.arr = obj
            self.ptr = <char *> self.arr.data.as_voidptr
            self.itemsize = self.arr.itemsize
            self.nbytes = self.arr.buffer_info()[1] * self.itemsize
        else:
            self.new_buffer = True
            PyObject_GetBuffer(obj, &(self.buffer), flags)
            self.ptr = <char *> self.buffer.buf
            self.itemsize = self.buffer.itemsize
            self.nbytes = self.buffer.len

    def release(self):
        if self.new_buffer:
            PyBuffer_Release(&(self.buffer))


def compress(source, int acceleration=DEFAULT_ACCELERATION):
    """Compress data.

    Parameters
    ----------
    source : bytes-like
        Data to be compressed. Can be any object supporting the buffer
        protocol.
    acceleration : int
        Acceleration level. The larger the acceleration value, the faster the algorithm, but also
        the lesser the compression.

    Returns
    -------
    dest : bytes
        Compressed data.
    """

    cdef:
        char *source_ptr
        char *dest_ptr, *dest_start
        MyBuffer source_buffer
        int source_size, dest_size, compressed_size
        bytes dest

    # check level
    if acceleration <= 0:
        acceleration = DEFAULT_ACCELERATION

    # setup source buffer
    source_buffer = MyBuffer(source, PyBUF_ANY_CONTIGUOUS)
    source_ptr = source_buffer.ptr
    source_size = source_buffer.nbytes

    try:

        # setup destination
        dest_size = LZ4_compressBound(source_size)
        dest = PyBytes_FromStringAndSize(NULL, dest_size + UINT32_SIZE)
        dest_ptr = PyBytes_AS_STRING(dest)
        store_le32(dest_ptr, source_size)
        dest_start = dest_ptr + UINT32_SIZE

        # perform compression
        with nogil:
            compressed_size = LZ4_compress_fast(source_ptr, dest_start, source_size, dest_size,
                                                acceleration)

    finally:

        # release buffers
        source_buffer.release()

    # check compression was successful
    if compressed_size <= 0:
        raise RuntimeError('LZ4 compression error: %s' % compressed_size)

    # resize after compression
    compressed_size += UINT32_SIZE
    dest = dest[:compressed_size]

    return dest


def decompress(source, dest=None):
    """Decompress data.

    Parameters
    ----------
    source : bytes-like
        Compressed data. Can be any object supporting the buffer protocol.
    dest : array-like, optional
        Object to decompress into.

    Returns
    -------
    dest : bytes
        Object containing decompressed data.

    """
    cdef:
        char *source_ptr, *source_start
        char *dest_ptr
        MyBuffer source_buffer
        MyBuffer dest_buffer = None
        int source_size, dest_size, decompressed_size

    # setup source buffer
    source_buffer = MyBuffer(source, PyBUF_ANY_CONTIGUOUS)
    source_ptr = source_buffer.ptr
    source_size = source_buffer.nbytes

    try:

        # determine uncompressed size
        if source_size < UINT32_SIZE:
            raise ValueError('bad input data')
        dest_size = load_le32(source_ptr)
        if dest_size <= 0:
            raise RuntimeError('LZ4 decompression error: invalid input data')
        source_start = source_ptr + UINT32_SIZE
        source_size -= UINT32_SIZE

        # setup destination buffer
        if dest is None:
            # allocate memory
            dest = PyBytes_FromStringAndSize(NULL, dest_size)
            dest_ptr = PyBytes_AS_STRING(dest)
        else:
            dest_buffer = MyBuffer(dest, PyBUF_ANY_CONTIGUOUS | PyBUF_WRITEABLE)
            dest_ptr = dest_buffer.ptr
            if dest_buffer.nbytes != dest_size:
                raise ValueError('destination buffer has wrong size; expected %s, '
                                 'got %s' % (dest_size, dest_buffer.nbytes))

        # perform decompression
        with nogil:
            decompressed_size = LZ4_decompress_safe(source_start, dest_ptr, source_size, dest_size)

    finally:

        # release buffers
        source_buffer.release()
        if dest_buffer is not None:
            dest_buffer.release()

    # check decompression was successful
    if decompressed_size <= 0:
        raise RuntimeError('LZ4 decompression error: %s' % decompressed_size)
    elif decompressed_size != dest_size:
        raise RuntimeError('LZ4 decompression error: expected to decompress %s, got %s' %
                           (dest_size, decompressed_size))

    return dest



class LZ4(Codec):
    """Codec providing compression using LZ4.

    Parameters
    ----------
    acceleration : int
        Acceleration level. The larger the acceleration value, the faster the algorithm, but also
        the lesser the compression.

    """

    codec_id = 'lz4'

    def __init__(self, acceleration=DEFAULT_ACCELERATION):
        self.acceleration = acceleration

    def encode(self, buf):
        return compress(buf, self.acceleration)

    def decode(self, buf, out=None):
        return decompress(buf, out)

    def __repr__(self):
        r = '%s(acceleration=%r)' % \
            (type(self).__name__,
             self.acceleration)
        return r
