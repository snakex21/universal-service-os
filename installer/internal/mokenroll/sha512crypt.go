package mokenroll

import "crypto/sha512"

// SHA-512-crypt ("$6$", Ulrich Drepper, "Unix crypt using SHA-256 and
// SHA-512"). shim's PasswordCrypt.c recomputes exactly this digest from the
// password typed in MokManager and compares it with pw_crypt_t.hash, so the
// raw 64-byte result (not the crypt(3) base64 text) is what MokAuth stores.

const (
	sha512CryptMaxSalt      = 16
	sha512CryptDefaultRound = 5000
)

// sha512CryptRaw returns the final digest of the $6$ algorithm. salt is
// truncated to 16 bytes as the specification requires.
func sha512CryptRaw(key, salt []byte, rounds int) [sha512.Size]byte {
	if len(salt) > sha512CryptMaxSalt {
		salt = salt[:sha512CryptMaxSalt]
	}

	// Digest B = SHA512(key || salt || key).
	b := sha512.New()
	b.Write(key)
	b.Write(salt)
	b.Write(key)
	digestB := b.Sum(nil)

	// Digest A.
	a := sha512.New()
	a.Write(key)
	a.Write(salt)
	n := len(key)
	for ; n > sha512.Size; n -= sha512.Size {
		a.Write(digestB)
	}
	a.Write(digestB[:n])
	for n = len(key); n > 0; n >>= 1 {
		if n&1 != 0 {
			a.Write(digestB)
		} else {
			a.Write(key)
		}
	}
	digestA := a.Sum(nil)

	// P: SHA512 of the key repeated len(key) times, stretched to len(key).
	dp := sha512.New()
	for i := 0; i < len(key); i++ {
		dp.Write(key)
	}
	p := repeatTo(dp.Sum(nil), len(key))

	// S: SHA512 of the salt repeated 16+A[0] times, stretched to len(salt).
	ds := sha512.New()
	for i := 0; i < 16+int(digestA[0]); i++ {
		ds.Write(salt)
	}
	s := repeatTo(ds.Sum(nil), len(salt))

	c := digestA
	for i := 0; i < rounds; i++ {
		h := sha512.New()
		if i&1 != 0 {
			h.Write(p)
		} else {
			h.Write(c)
		}
		if i%3 != 0 {
			h.Write(s)
		}
		if i%7 != 0 {
			h.Write(p)
		}
		if i&1 != 0 {
			h.Write(c)
		} else {
			h.Write(p)
		}
		c = h.Sum(c[:0])
	}
	var out [sha512.Size]byte
	copy(out[:], c)
	return out
}

func repeatTo(block []byte, length int) []byte {
	out := make([]byte, length)
	for i := 0; i < length; i += len(block) {
		copy(out[i:], block)
	}
	return out
}

// cryptAlphabet is the crypt(3) base64 alphabet; salts use it too.
const cryptAlphabet = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

// sha512CryptEncode renders a raw digest the way crypt(3) prints it after
// "$6$salt$" (byte permutation plus the little-endian 6-bit alphabet).
func sha512CryptEncode(d [sha512.Size]byte) string {
	order := [21][3]int{
		{0, 21, 42}, {22, 43, 1}, {44, 2, 23}, {3, 24, 45}, {25, 46, 4},
		{47, 5, 26}, {6, 27, 48}, {28, 49, 7}, {50, 8, 29}, {9, 30, 51},
		{31, 52, 10}, {53, 11, 32}, {12, 33, 54}, {34, 55, 13}, {56, 14, 35},
		{15, 36, 57}, {37, 58, 16}, {59, 17, 38}, {18, 39, 60}, {40, 61, 19},
		{62, 20, 41},
	}
	out := make([]byte, 0, 86)
	emit := func(b2, b1, b0 byte, n int) {
		w := uint32(b2)<<16 | uint32(b1)<<8 | uint32(b0)
		for ; n > 0; n-- {
			out = append(out, cryptAlphabet[w&0x3f])
			w >>= 6
		}
	}
	for _, o := range order {
		emit(d[o[0]], d[o[1]], d[o[2]], 4)
	}
	emit(0, 0, d[63], 2)
	return string(out)
}
