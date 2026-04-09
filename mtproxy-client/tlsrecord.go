package main

import (
	"encoding/binary"
	"fmt"
	"io"
)

const (
	tlsRecordChangeCipherSpec = 0x14
	tlsRecordHandshake        = 0x16
	tlsRecordApplication      = 0x17
	tlsVersion12               = 0x0303
	tlsMaxRecordSize           = 16384 + 256 // max TLS record payload
)

// readTLSRecord reads one TLS record: 5-byte header + payload.
func readTLSRecord(r io.Reader) (recordType byte, payload []byte, err error) {
	hdr := make([]byte, 5)
	if _, err = io.ReadFull(r, hdr); err != nil {
		return 0, nil, fmt.Errorf("read TLS header: %w", err)
	}

	recordType = hdr[0]
	length := binary.BigEndian.Uint16(hdr[3:5])

	if int(length) > tlsMaxRecordSize {
		return 0, nil, fmt.Errorf("TLS record too large: %d", length)
	}

	payload = make([]byte, length)
	if _, err = io.ReadFull(r, payload); err != nil {
		return 0, nil, fmt.Errorf("read TLS payload: %w", err)
	}

	return recordType, payload, nil
}

// writeTLSRecord writes one TLS record with the given type.
func writeTLSRecord(w io.Writer, recordType byte, payload []byte) error {
	hdr := make([]byte, 5)
	hdr[0] = recordType
	binary.BigEndian.PutUint16(hdr[1:3], tlsVersion12)
	binary.BigEndian.PutUint16(hdr[3:5], uint16(len(payload)))

	if _, err := w.Write(hdr); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}
