package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"io"
	"math/rand"
	"net"
	"time"
)

const clientHelloSize = 517

// buildClientHello constructs a FakeTLS ClientHello with the proxy secret's SNI.
func buildClientHello(secret *ProxySecret) ([]byte, error) {
	sni := secret.SNI
	if sni == "" {
		sni = "s3.amazonaws.com"
	}

	// Base TLS 1.2 ClientHello structure.
	// Offsets are carefully aligned to match what MTProxy servers expect.
	hello := make([]byte, clientHelloSize)

	// TLS record header
	hello[0] = tlsRecordHandshake // content type
	binary.BigEndian.PutUint16(hello[1:3], 0x0301) // TLS 1.0 for ClientHello record
	binary.BigEndian.PutUint16(hello[3:5], uint16(clientHelloSize-5)) // record length

	// Handshake header
	hello[5] = 0x01 // ClientHello
	hello[6] = 0x00
	binary.BigEndian.PutUint16(hello[7:9], uint16(clientHelloSize-9)) // handshake length

	// Client version: TLS 1.2
	binary.BigEndian.PutUint16(hello[9:11], tlsVersion12)

	// Random (32 bytes at offset 11) - will be filled with HMAC later
	// For now, fill with random
	randomOffset := 11
	rand.Read(hello[randomOffset : randomOffset+32])

	// Session ID (32 bytes)
	sessionIDOffset := 43
	hello[sessionIDOffset] = 32 // session ID length
	rand.Read(hello[sessionIDOffset+1 : sessionIDOffset+33])

	// Cipher suites
	csOffset := sessionIDOffset + 33
	cipherSuites := []uint16{
		0xcca9, 0xcca8, 0xc02c, 0xc02b, 0xc030, 0xc02f,
		0x009f, 0x009e, 0xccaa, 0xc0a3, 0xc09f, 0xc0ad,
		0xc0a7, 0x009d, 0xc0a2, 0xc09e, 0xc0ac, 0xc0a6,
		0x00ff,
	}
	binary.BigEndian.PutUint16(hello[csOffset:csOffset+2], uint16(len(cipherSuites)*2))
	for i, cs := range cipherSuites {
		binary.BigEndian.PutUint16(hello[csOffset+2+i*2:csOffset+4+i*2], cs)
	}

	// Compression methods
	compOffset := csOffset + 2 + len(cipherSuites)*2
	hello[compOffset] = 1 // length
	hello[compOffset+1] = 0 // null compression

	// Extensions
	extStart := compOffset + 2
	extBuf := new(bytes.Buffer)

	// SNI extension
	sniBytes := []byte(sni)
	extBuf.Write([]byte{0x00, 0x00}) // extension type: SNI
	sniLen := len(sniBytes) + 5
	binary.Write(extBuf, binary.BigEndian, uint16(sniLen))
	binary.Write(extBuf, binary.BigEndian, uint16(sniLen-2))
	extBuf.WriteByte(0x00) // host name type
	binary.Write(extBuf, binary.BigEndian, uint16(len(sniBytes)))
	extBuf.Write(sniBytes)

	// Supported versions extension (TLS 1.3, 1.2)
	extBuf.Write([]byte{0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x03})

	// Signature algorithms
	extBuf.Write([]byte{0x00, 0x0d, 0x00, 0x10, 0x00, 0x0e,
		0x04, 0x03, 0x05, 0x03, 0x06, 0x03, 0x02, 0x03,
		0x08, 0x04, 0x08, 0x05, 0x08, 0x06})

	// Key share (empty x25519 placeholder)
	extBuf.Write([]byte{0x00, 0x33, 0x00, 0x02, 0x00, 0x00})

	// Supported groups
	extBuf.Write([]byte{0x00, 0x0a, 0x00, 0x04, 0x00, 0x02, 0x00, 0x1d})

	// EC point formats
	extBuf.Write([]byte{0x00, 0x0b, 0x00, 0x02, 0x01, 0x00})

	// Padding to fill exactly clientHelloSize
	extData := extBuf.Bytes()
	paddingNeeded := clientHelloSize - extStart - 2 - len(extData)
	if paddingNeeded > 4 {
		// Padding extension
		padExt := make([]byte, 4+paddingNeeded-4)
		padExt[0] = 0x00
		padExt[1] = 0x15 // padding extension type
		binary.BigEndian.PutUint16(padExt[2:4], uint16(paddingNeeded-4))
		extData = append(extData, padExt...)
	}

	binary.BigEndian.PutUint16(hello[extStart:extStart+2], uint16(len(extData)))
	copy(hello[extStart+2:], extData)

	// Now compute HMAC for the random field.
	// Zero out random field, compute HMAC(secret, hello), put result in random field.
	saved := make([]byte, 32)
	copy(saved, hello[randomOffset:randomOffset+32])

	// Zero the random field
	for i := 0; i < 32; i++ {
		hello[randomOffset+i] = 0
	}

	mac := hmac.New(sha256.New, secret.Secret)
	mac.Write(hello)
	digest := mac.Sum(nil)

	copy(hello[randomOffset:randomOffset+32], digest)

	// XOR last 4 bytes of random with current timestamp
	ts := uint32(time.Now().Unix())
	tsBytes := make([]byte, 4)
	binary.LittleEndian.PutUint32(tsBytes, ts)
	for i := 0; i < 4; i++ {
		hello[randomOffset+28+i] ^= tsBytes[i]
	}

	return hello, nil
}

// doFakeTLSHandshake performs the FakeTLS handshake with the MTProxy server.
// Returns a net.Conn that wraps the connection with TLS record framing.
func doFakeTLSHandshake(conn net.Conn, secret *ProxySecret) (clientRandom []byte, err error) {
	// Build and send ClientHello
	hello, err := buildClientHello(secret)
	if err != nil {
		return nil, fmt.Errorf("build ClientHello: %w", err)
	}

	clientRandom = make([]byte, 32)
	copy(clientRandom, hello[11:43])

	if _, err := conn.Write(hello); err != nil {
		return nil, fmt.Errorf("send ClientHello: %w", err)
	}

	// Read server response: multiple Handshake records, then ChangeCipherSpec,
	// then optionally Application Data. Some MTProxy servers send more TLS
	// handshake records than the minimum (ServerHello, Certificate, etc.).
	for i := 0; i < 10; i++ {
		recType, _, err := readTLSRecord(conn)
		if err != nil {
			return nil, fmt.Errorf("read server record %d: %w", i, err)
		}
		if recType == tlsRecordChangeCipherSpec {
			// Read one more Application Data record after CCS
			recType, _, err = readTLSRecord(conn)
			if err != nil {
				return nil, fmt.Errorf("read post-CCS record: %w", err)
			}
			_ = recType // may be Application or another type
			break
		}
		if recType != tlsRecordHandshake && recType != tlsRecordApplication {
			return nil, fmt.Errorf("unexpected record type 0x%02x at position %d", recType, i)
		}
	}

	return clientRandom, nil
}

// tlsRecordConn wraps a connection to read/write TLS Application Data records.
type tlsRecordConn struct {
	conn    net.Conn
	readBuf []byte // buffered decrypted data from last record
}

func newTLSRecordConn(conn net.Conn) *tlsRecordConn {
	return &tlsRecordConn{conn: conn}
}

func (c *tlsRecordConn) Read(p []byte) (int, error) {
	if len(c.readBuf) > 0 {
		n := copy(p, c.readBuf)
		c.readBuf = c.readBuf[n:]
		return n, nil
	}

	recType, payload, err := readTLSRecord(c.conn)
	if err != nil {
		return 0, err
	}
	if recType != tlsRecordApplication {
		return 0, fmt.Errorf("unexpected TLS record type: 0x%02x", recType)
	}

	n := copy(p, payload)
	if n < len(payload) {
		c.readBuf = payload[n:]
	}
	return n, nil
}

func (c *tlsRecordConn) Write(p []byte) (int, error) {
	// Split into max-size TLS records
	total := 0
	for len(p) > 0 {
		chunk := p
		if len(chunk) > 16384 {
			chunk = chunk[:16384]
		}
		if err := writeTLSRecord(c.conn, tlsRecordApplication, chunk); err != nil {
			return total, err
		}
		total += len(chunk)
		p = p[len(chunk):]
	}
	return total, nil
}

func (c *tlsRecordConn) Close() error {
	return c.conn.Close()
}

func (c *tlsRecordConn) LocalAddr() net.Addr                { return c.conn.LocalAddr() }
func (c *tlsRecordConn) RemoteAddr() net.Addr               { return c.conn.RemoteAddr() }
func (c *tlsRecordConn) SetDeadline(t time.Time) error      { return c.conn.SetDeadline(t) }
func (c *tlsRecordConn) SetReadDeadline(t time.Time) error  { return c.conn.SetReadDeadline(t) }
func (c *tlsRecordConn) SetWriteDeadline(t time.Time) error { return c.conn.SetWriteDeadline(t) }

var _ io.ReadWriteCloser = (*tlsRecordConn)(nil)
