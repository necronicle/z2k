package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/binary"
	"io"
	"math/rand"
)

const (
	obfuscated2HeaderSize = 64
	tagPaddedIntermediate = 0xdddddddd
)

// obfuscated2Conn wraps an io.ReadWriteCloser with obfuscated2 encryption.
type obfuscated2Conn struct {
	inner   io.ReadWriteCloser
	encStream cipher.Stream
	decStream cipher.Stream
}

// generateObfuscated2Header creates the 64-byte init header with DC number encoded.
func generateObfuscated2Header(secret []byte, dc int16) (header []byte, encStream, decStream cipher.Stream, err error) {
	header = make([]byte, obfuscated2HeaderSize)

	// Generate random bytes, avoiding certain patterns that look like other protocols.
	for {
		rand.Read(header)

		// First byte must not be 0xef (abridged protocol marker)
		if header[0] == 0xef {
			continue
		}
		// First 4 bytes must not match known protocol signatures
		first4 := binary.LittleEndian.Uint32(header[0:4])
		if first4 == 0x44414548 || // "HEAD"
			first4 == 0x54534f50 || // "POST"
			first4 == 0x20544547 || // "GET "
			first4 == 0x4954504f || // "OPTI"
			first4 == 0xdddddddd || // padded intermediate
			first4 == 0xeeeeeeee || // intermediate
			first4 == 0x16030102 { // TLS
			continue
		}
		// Bytes [4:8] must not be all zeros
		if binary.LittleEndian.Uint32(header[4:8]) == 0 {
			continue
		}
		break
	}

	// Encode protocol tag at offset 56 (PaddedIntermediate)
	binary.LittleEndian.PutUint32(header[56:60], tagPaddedIntermediate)

	// Encode DC number at offset 60 as int16 LE
	binary.LittleEndian.PutUint16(header[60:62], uint16(dc))

	// Derive encryption keys
	// encrypt: key = header[8:40], iv = header[40:56]
	encKeyRaw := make([]byte, 32)
	copy(encKeyRaw, header[8:40])
	encIV := make([]byte, 16)
	copy(encIV, header[40:56])

	// decrypt: reverse of header[8:56]
	reversed := make([]byte, 48)
	for i := 0; i < 48; i++ {
		reversed[i] = header[8+47-i]
	}
	decKeyRaw := reversed[:32]
	decIV := reversed[32:48]

	// Mix in proxy secret: key = SHA256(key || secret)
	if len(secret) >= 16 {
		h := sha256.New()
		h.Write(encKeyRaw)
		h.Write(secret[:16])
		encKeyRaw = h.Sum(nil)

		h = sha256.New()
		h.Write(decKeyRaw)
		h.Write(secret[:16])
		decKeyRaw = h.Sum(nil)
	}

	// Create AES-256-CTR streams
	encBlock, err := aes.NewCipher(encKeyRaw)
	if err != nil {
		return nil, nil, nil, err
	}
	encStream = cipher.NewCTR(encBlock, encIV)

	decBlock, err := aes.NewCipher(decKeyRaw)
	if err != nil {
		return nil, nil, nil, err
	}
	decStream = cipher.NewCTR(decBlock, decIV)

	// Encrypt bytes [56:64] of the header (tag + DC) with the encrypt stream.
	// First, advance the encrypt stream by processing bytes [0:56] (discarded).
	dummy := make([]byte, 56)
	encStream.XORKeyStream(dummy, header[:56])

	// Now encrypt bytes [56:64] in place
	encStream.XORKeyStream(header[56:64], header[56:64])

	// Reset encrypt stream for actual data (need fresh stream from same key/IV)
	encBlock2, _ := aes.NewCipher(encKeyRaw)
	encStream = cipher.NewCTR(encBlock2, encIV)
	// Advance past the 64-byte header
	skip := make([]byte, 64)
	encStream.XORKeyStream(skip, skip)

	return header, encStream, decStream, nil
}

func newObfuscated2Conn(inner io.ReadWriteCloser, secret []byte, dc int16) (*obfuscated2Conn, error) {
	header, encStream, decStream, err := generateObfuscated2Header(secret, dc)
	if err != nil {
		return nil, err
	}

	// Send the header
	if _, err := inner.Write(header); err != nil {
		return nil, err
	}

	return &obfuscated2Conn{
		inner:     inner,
		encStream: encStream,
		decStream: decStream,
	}, nil
}

func (c *obfuscated2Conn) Read(p []byte) (int, error) {
	n, err := c.inner.Read(p)
	if n > 0 {
		c.decStream.XORKeyStream(p[:n], p[:n])
	}
	return n, err
}

func (c *obfuscated2Conn) Write(p []byte) (int, error) {
	buf := make([]byte, len(p))
	c.encStream.XORKeyStream(buf, p)
	return c.inner.Write(buf)
}

func (c *obfuscated2Conn) Close() error {
	return c.inner.Close()
}
