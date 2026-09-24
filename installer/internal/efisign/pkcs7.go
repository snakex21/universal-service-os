package efisign

import (
	"bytes"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"errors"
	"fmt"
	"math/big"
	"unicode/utf16"
)

var (
	oidSignedData        = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 7, 2}
	oidSpcIndirectData   = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 311, 2, 1, 4}
	oidSpcPeImageData    = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 311, 2, 1, 15}
	oidSpcSpOpusInfo     = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 311, 2, 1, 12}
	oidSpcStatementType  = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 311, 2, 1, 11}
	oidIndividualCodeSig = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 311, 2, 1, 21}
	oidSHA256            = asn1.ObjectIdentifier{2, 16, 840, 1, 101, 3, 4, 2, 1}
	oidRSAEncryption     = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 1, 1}
	oidContentType       = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 9, 3}
	oidMessageDigest     = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 9, 4}
)

// spcIndirectDataContent encodes the Authenticode SpcIndirectDataContent for
// a PE image digest. The digest is the last element, which is where EDK2's
// AuthenticodeVerify (used by shim) looks for it.
func spcIndirectDataContent(digest []byte) []byte {
	obsolete := utf16.Encode([]rune("<<<Obsolete>>>"))
	bmp := make([]byte, 0, len(obsolete)*2)
	for _, unit := range obsolete {
		bmp = append(bmp, byte(unit>>8), byte(unit))
	}
	// SpcPeImageData { flags BIT STRING {}, file [0] EXPLICIT SpcLink.file [2] { unicode [0] IMPLICIT BMPString } }
	file := tlv(0xa0, tlv(0xa2, tlv(0x80, bmp)))
	peImageData := seq([]byte{tagBitString, 1, 0}, file)
	return seq(
		seq(oid(oidSpcPeImageData), peImageData),
		seq(algorithm(oidSHA256), tlv(tagOctetString, digest)),
	)
}

func attribute(id asn1.ObjectIdentifier, value []byte) []byte {
	return seq(oid(id), setOf(value))
}

// buildSignedData returns a DER ContentInfo(SignedData) Authenticode
// signature over digest (the SHA-256 Authenticode hash of the image).
func buildSignedData(digest []byte, key *rsa.PrivateKey, cert *x509.Certificate) ([]byte, error) {
	if len(digest) != sha256.Size {
		return nil, fmt.Errorf("digest must be SHA-256, got %d bytes", len(digest))
	}
	content := spcIndirectDataContent(digest)
	contentElement, _, err := readElement(content)
	if err != nil {
		return nil, err
	}
	// Authenticode: messageDigest covers the SpcIndirectDataContent value
	// without its outer SEQUENCE tag and length.
	contentDigest := sha256.Sum256(contentElement.content)
	attributes := [][]byte{
		attribute(oidContentType, oid(oidSpcIndirectData)),
		attribute(oidSpcSpOpusInfo, seq()),
		attribute(oidSpcStatementType, seq(oid(oidIndividualCodeSig))),
		attribute(oidMessageDigest, tlv(tagOctetString, contentDigest[:])),
	}
	signedAttributes := setOf(attributes...)
	attributesDigest := sha256.Sum256(signedAttributes)
	signature, err := rsa.SignPKCS1v15(nil, key, crypto.SHA256, attributesDigest[:])
	if err != nil {
		return nil, fmt.Errorf("RSA sign: %w", err)
	}
	serial, err := asn1.Marshal(cert.SerialNumber)
	if err != nil {
		return nil, err
	}
	attributesElement, _, err := readElement(signedAttributes)
	if err != nil {
		return nil, err
	}
	signerInfo := seq(
		integer(1),
		seq(cert.RawIssuer, serial),
		algorithm(oidSHA256),
		tlv(0xa0, attributesElement.content),
		algorithm(oidRSAEncryption),
		tlv(tagOctetString, signature),
	)
	signedData := seq(
		integer(1),
		setOf(algorithm(oidSHA256)),
		seq(oid(oidSpcIndirectData), tlv(0xa0, content)),
		tlv(0xa0, cert.Raw),
		setOf(signerInfo),
	)
	return seq(oid(oidSignedData), tlv(0xa0, signedData)), nil
}

// Signature is the part of an Authenticode PKCS#7 blob USOS inspects.
type Signature struct {
	// ImageDigest is the Authenticode hash the signature vouches for.
	ImageDigest          []byte
	ImageDigestAlgorithm asn1.ObjectIdentifier
	Certificates         []*x509.Certificate
	signerIssuer         []byte
	signerSerial         *big.Int
	signedAttributes     []byte
	messageDigest        []byte
	contentValue         []byte
	signatureValue       []byte
}

// ParseSignature decodes a ContentInfo(SignedData) Authenticode blob.
func ParseSignature(der []byte) (*Signature, error) {
	contentInfo, _, err := readElement(der)
	if err != nil {
		return nil, err
	}
	parts, err := children(contentInfo.content)
	if err != nil || len(parts) != 2 || !bytes.Equal(parts[0].full, oid(oidSignedData)) || parts[1].tag != 0xa0 {
		return nil, errors.New("not a PKCS#7 SignedData ContentInfo")
	}
	signedData, _, err := readElement(parts[1].content)
	if err != nil {
		return nil, err
	}
	fields, err := children(signedData.content)
	if err != nil || len(fields) < 4 {
		return nil, errors.New("malformed SignedData")
	}
	sig := &Signature{}
	encap, err := children(fields[2].content)
	if err != nil || len(encap) != 2 || !bytes.Equal(encap[0].full, oid(oidSpcIndirectData)) || encap[1].tag != 0xa0 {
		return nil, errors.New("SignedData does not carry SpcIndirectDataContent")
	}
	indirect, _, err := readElement(encap[1].content)
	if err != nil {
		return nil, err
	}
	sig.contentValue = indirect.content
	indirectParts, err := children(indirect.content)
	if err != nil || len(indirectParts) != 2 {
		return nil, errors.New("malformed SpcIndirectDataContent")
	}
	digestInfo, err := children(indirectParts[1].content)
	if err != nil || len(digestInfo) != 2 || digestInfo[1].tag != tagOctetString {
		return nil, errors.New("malformed DigestInfo")
	}
	algorithmParts, err := children(digestInfo[0].content)
	if err != nil || len(algorithmParts) == 0 {
		return nil, errors.New("malformed digest algorithm")
	}
	if _, err := asn1.Unmarshal(algorithmParts[0].full, &sig.ImageDigestAlgorithm); err != nil {
		return nil, err
	}
	sig.ImageDigest = append([]byte(nil), digestInfo[1].content...)

	next := 3
	if fields[next].tag == 0xa0 {
		certs, err := children(fields[next].content)
		if err != nil {
			return nil, err
		}
		for _, c := range certs {
			parsed, err := x509.ParseCertificate(c.full)
			if err != nil {
				return nil, fmt.Errorf("embedded certificate: %w", err)
			}
			sig.Certificates = append(sig.Certificates, parsed)
		}
		next++
	}
	if next < len(fields) && fields[next].tag == 0xa1 {
		next++ // CRLs
	}
	if next >= len(fields) || fields[next].tag != tagSet {
		return nil, errors.New("SignedData has no signerInfos")
	}
	signers, err := children(fields[next].content)
	if err != nil || len(signers) == 0 {
		return nil, errors.New("SignedData has no signer")
	}
	info, err := children(signers[0].content)
	if err != nil || len(info) < 5 {
		return nil, errors.New("malformed SignerInfo")
	}
	issuerSerial, err := children(info[1].content)
	if err != nil || len(issuerSerial) != 2 {
		return nil, errors.New("SignerInfo is not identified by issuer and serial number")
	}
	sig.signerIssuer = issuerSerial[0].full
	sig.signerSerial = new(big.Int)
	if _, err := asn1.Unmarshal(issuerSerial[1].full, &sig.signerSerial); err != nil {
		return nil, err
	}
	index := 3
	if info[index].tag == 0xa0 {
		sig.signedAttributes = tlv(tagSet, info[index].content)
		attrs, err := children(info[index].content)
		if err != nil {
			return nil, err
		}
		for _, attr := range attrs {
			pair, err := children(attr.content)
			if err != nil || len(pair) != 2 {
				return nil, errors.New("malformed signed attribute")
			}
			if bytes.Equal(pair[0].full, oid(oidMessageDigest)) {
				values, err := children(pair[1].content)
				if err != nil || len(values) != 1 || values[0].tag != tagOctetString {
					return nil, errors.New("malformed messageDigest attribute")
				}
				sig.messageDigest = values[0].content
			}
		}
		index++
	}
	if index+1 >= len(info) || info[index+1].tag != tagOctetString {
		return nil, errors.New("SignerInfo has no signature value")
	}
	sig.signatureValue = info[index+1].content
	return sig, nil
}

// Signer returns the embedded certificate that produced the signature.
func (s *Signature) Signer() (*x509.Certificate, error) {
	for _, c := range s.Certificates {
		if bytes.Equal(c.RawIssuer, s.signerIssuer) && c.SerialNumber.Cmp(s.signerSerial) == 0 {
			return c, nil
		}
	}
	return nil, errors.New("signer certificate is not embedded in the signature")
}

// VerifyRSA checks the SignerInfo cryptographically: the messageDigest
// attribute must match the SpcIndirectDataContent and the RSA signature over
// the signed attributes must verify with the signer's public key. It does
// not build or trust a certificate chain.
func (s *Signature) VerifyRSA() (*x509.Certificate, error) {
	signer, err := s.Signer()
	if err != nil {
		return nil, err
	}
	public, ok := signer.PublicKey.(*rsa.PublicKey)
	if !ok {
		return nil, errors.New("signer key is not RSA")
	}
	if s.signedAttributes == nil {
		return nil, errors.New("signature has no signed attributes")
	}
	contentDigest := sha256.Sum256(s.contentValue)
	if !bytes.Equal(contentDigest[:], s.messageDigest) {
		return nil, errors.New("messageDigest attribute does not match SpcIndirectDataContent")
	}
	attributesDigest := sha256.Sum256(s.signedAttributes)
	if err := rsa.VerifyPKCS1v15(public, crypto.SHA256, attributesDigest[:], s.signatureValue); err != nil {
		return nil, fmt.Errorf("RSA signature: %w", err)
	}
	return signer, nil
}
