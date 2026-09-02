package main

import "testing"

func TestProtoFrames(t *testing.T) {
	f := protoV1.closeFrame(9, rQueueLimit, "x")
	sid, mt, p, _ := decodeFrame(f)
	if sid != 9 || mt != muxCLOSE || len(p) != 0 {
		t.Fatalf("v1 CLOSE обязан быть без payload: %v", f)
	}
	if protoV1.info(infoRetryAfter, 5, "") != nil || protoV1.windows() {
		t.Fatal("v1 не знает INFO и окон")
	}
	f = protoV2.closeFrame(9, rQueueLimit, "x")
	_, _, p, _ = decodeFrame(f)
	if r, txt := decodeClose(p); r != rQueueLimit || txt != "x" {
		t.Fatal("v2 CLOSE несёт причину")
	}
	_, mt, p, _ = decodeFrame(protoV2.connectOK(3, 1024))
	if mt != muxCONNECT_OK || decodeConnectOK(p) != 1024 {
		t.Fatal("v2 CONNECT_OK несёт окно")
	}
	_, mt, p, _ = decodeFrame(protoV1.connectOK(3, 1024))
	if mt != muxCONNECT_OK || len(p) != 0 {
		t.Fatal("v1 CONNECT_OK пустой")
	}
	sid, mt, p, _ = decodeFrame(protoV2.info(infoGoodbye, uint32(rShutdown), "bye"))
	k, arg, _, _ := decodeInfo(p)
	if sid != 0 || mt != muxINFO || k != infoGoodbye || arg != uint32(rShutdown) {
		t.Fatal("v2 INFO на стриме 0")
	}
}
