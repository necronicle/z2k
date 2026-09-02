//go:build !android && !ios && !windows

/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2017-2025 WireGuard LLC. All Rights Reserved.
 */

package device

import "golang.zx2c4.com/wireguard/conn"

const (
	QueueStagedSize    = conn.IdealBatchSize
	QueueOutboundSize  = 1024
	QueueInboundSize   = 1024
	QueueHandshakeSize = 1024
	// z2k: 2048 вместо (1<<16)-1. Буфер этого размера берётся ПОД КАЖДЫЙ пакет в
	// очередях (по 1024 в каждую сторону плюс батчи приёма), и при MTU 1280
	// 64 КБ на пакет давали 70–90 МБ RSS после одного скачанного файла и
	// OOM-kill на роутере с 512 МБ (замер 2026-09-02). Датаграммы крупнее
	// MTU+32 сюда не приходят: UDP GRO выключен в conn/bind_std.go — иначе
	// ядро склеивало бы несколько датаграмм в одну и она не влезала бы.
	MaxSegmentSize             = 2048
	PreallocatedBuffersPerPool = 0 // Disable and allow for infinite memory growth
)
