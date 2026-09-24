package efisign

import (
	"bytes"
	"encoding/asn1"
	"errors"
	"sort"
)

// Minimal DER writer/reader: Authenticode needs a few IMPLICIT/EXPLICIT
// tagged structures that encoding/asn1 struct tags make awkward, so the
// SignedData is assembled from raw TLVs.

const (
	tagInteger     = 0x02
	tagBitString   = 0x03
	tagOctetString = 0x04
	tagNull        = 0x05
	tagOID         = 0x06
	tagSequence    = 0x30
	tagSet         = 0x31
)

func tlv(tag byte, content ...[]byte) []byte {
	body := bytes.Join(content, nil)
	out := []byte{tag}
	n := len(body)
	switch {
	case n < 0x80:
		out = append(out, byte(n))
	case n < 0x100:
		out = append(out, 0x81, byte(n))
	case n < 0x10000:
		out = append(out, 0x82, byte(n>>8), byte(n))
	case n < 0x1000000:
		out = append(out, 0x83, byte(n>>16), byte(n>>8), byte(n))
	default:
		out = append(out, 0x84, byte(n>>24), byte(n>>16), byte(n>>8), byte(n))
	}
	return append(out, body...)
}

func seq(content ...[]byte) []byte { return tlv(tagSequence, content...) }

// setOf encodes a DER SET OF: elements sorted by their encodings.
func setOf(elements ...[]byte) []byte {
	sorted := append([][]byte(nil), elements...)
	sort.Slice(sorted, func(i, j int) bool { return bytes.Compare(sorted[i], sorted[j]) < 0 })
	return tlv(tagSet, sorted...)
}

func oid(value asn1.ObjectIdentifier) []byte {
	encoded, err := asn1.Marshal(value)
	if err != nil {
		panic(err)
	}
	return encoded
}

func integer(value int) []byte {
	encoded, err := asn1.Marshal(value)
	if err != nil {
		panic(err)
	}
	return encoded
}

func algorithm(id asn1.ObjectIdentifier) []byte { return seq(oid(id), []byte{tagNull, 0}) }

// element is one parsed TLV.
type element struct {
	tag     byte
	content []byte
	full    []byte
}

func readElement(data []byte) (element, []byte, error) {
	if len(data) < 2 {
		return element{}, nil, errors.New("truncated DER")
	}
	tag := data[0]
	if tag&0x1f == 0x1f {
		return element{}, nil, errors.New("multi-byte DER tags are not supported")
	}
	length := int(data[1])
	header := 2
	if length&0x80 != 0 {
		count := length & 0x7f
		if count == 0 || count > 4 || len(data) < 2+count {
			return element{}, nil, errors.New("unsupported DER length")
		}
		length = 0
		for _, b := range data[2 : 2+count] {
			length = length<<8 | int(b)
		}
		header += count
	}
	if length < 0 || header+length > len(data) {
		return element{}, nil, errors.New("DER element exceeds its container")
	}
	return element{tag: tag, content: data[header : header+length], full: data[:header+length]}, data[header+length:], nil
}

func children(data []byte) ([]element, error) {
	var out []element
	for len(data) > 0 {
		e, rest, err := readElement(data)
		if err != nil {
			return nil, err
		}
		out = append(out, e)
		data = rest
	}
	return out, nil
}
