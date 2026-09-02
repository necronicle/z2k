package main

// proto — всё, чем v1 отличается от v2 на проводе. Ядро одно (спека §3.4):
// v1 без окон, без причин в CLOSE/CONNECT_FAIL и без INFO.
type proto interface {
	name() string
	windows() bool
	closeFrame(id uint16, reason byte, text string) []byte
	connectOK(id uint16, window uint32) []byte
	connectFail(id uint16, reason byte, text string) []byte
	info(kind byte, arg uint32, text string) []byte
}

type v1 struct{}
type v2 struct{}

var (
	protoV1 proto = v1{}
	protoV2 proto = v2{}
)

func (v1) name() string                                  { return "v1" }
func (v1) windows() bool                                 { return false }
func (v1) closeFrame(id uint16, _ byte, _ string) []byte { return encodeFrame(id, muxCLOSE, nil) }
func (v1) connectOK(id uint16, _ uint32) []byte          { return encodeFrame(id, muxCONNECT_OK, nil) }
func (v1) connectFail(id uint16, _ byte, _ string) []byte {
	return encodeFrame(id, muxCONNECT_FAIL, nil)
}
func (v1) info(byte, uint32, string) []byte { return nil }

func (v2) name() string  { return "v2" }
func (v2) windows() bool { return true }
func (v2) closeFrame(id uint16, reason byte, text string) []byte {
	return encodeFrame(id, muxCLOSE, encodeClose(reason, text))
}
func (v2) connectOK(id uint16, window uint32) []byte {
	return encodeFrame(id, muxCONNECT_OK, encodeConnectOK(window))
}
func (v2) connectFail(id uint16, reason byte, text string) []byte {
	return encodeFrame(id, muxCONNECT_FAIL, encodeClose(reason, text))
}
func (v2) info(kind byte, arg uint32, text string) []byte {
	return encodeFrame(0, muxINFO, encodeInfo(kind, arg, text))
}
