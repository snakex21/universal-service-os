"""Container integrity shared by the bounded, allowlisted NT collectors."""
import zlib


def single_gzip(payload,max_plain):
    """Return one bounded gzip member, requiring its complete EOF and CRC."""
    inflater=zlib.decompressobj(16+zlib.MAX_WBITS)
    try:
        plain=inflater.decompress(payload,max_plain+1)
    except zlib.error as error:
        raise ValueError('Invalid gzip integrity') from error
    if len(plain)>max_plain or not inflater.eof or inflater.unused_data or inflater.unconsumed_tail:
        raise ValueError('Invalid or multiple bounded gzip streams')
    return plain


def tar_end(plain,offset):
    """Require two zero end blocks and zero padding only after the last member."""
    if len(plain)%512 or len(plain)-offset<1024 or any(plain[offset:]):
        raise ValueError('Truncated or trailing tar data')
