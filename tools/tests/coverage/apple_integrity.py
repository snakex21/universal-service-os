"""Apple XAR catalogue digests and HTTPS integrityDataV1 chunk manifests.

Catalogue Digest is SHA-1 of the compressed XAR TOC, NOT of the full PKG.
Integrity method 2 is a manifest checksum, not a digital signature; callers
must fetch it from the expected Apple host over verified HTTPS.
"""
import hashlib
import struct


def chunk_manifest(data, expected_size):
    if len(data) < 36:
        raise ValueError('Truncated Apple integrity manifest')
    magic, header, version, method, signature, count, offset, end = struct.unpack_from('<4sIBBBxQQQ',data)
    if (magic,header,version,method,signature,offset) != (b'CNKL',36,1,1,2,36):
        raise ValueError('Unsupported integrity manifest; expected method 2')
    if not 0 < count < 100000 or end != offset+count*36 or len(data) != end+32:
        raise ValueError('Invalid integrity manifest bounds')
    if hashlib.sha256(data[:end]).digest() != data[end:]:
        raise ValueError('Integrity manifest footer checksum differs')
    chunks = [struct.unpack_from('<I32s',data,offset+i*36) for i in range(count)]
    if any(size == 0 for size,digest in chunks) or sum(size for size,digest in chunks) != expected_size:
        raise ValueError('Manifest size differs from Apple catalogue')
    return chunks


def verify_xar_toc(stream, expected_digest):
    stream.seek(0)
    header = stream.read(28)
    if len(header) != 28:
        raise ValueError('Truncated XAR header')
    magic,size,version,compressed,plain,algorithm = struct.unpack('>4sHHQQI',header)
    if magic != b'xar!' or version != 1 or algorithm != 1 or not 28 <= size <= 4096:
        raise ValueError('Unexpected Apple XAR header')
    if not 0 < compressed <= 1024**2 or not 0 < plain <= 8*1024**2:
        raise ValueError('XAR TOC exceeds metadata bound')
    stream.seek(size)
    toc = stream.read(compressed)
    if len(toc) != compressed or hashlib.sha1(toc).hexdigest() != expected_digest.lower():
        raise ValueError('Apple catalogue compressed TOC SHA-1 differs')
    return dict(compressed_bytes=compressed, uncompressed_bytes=plain, sha1=expected_digest.lower())
