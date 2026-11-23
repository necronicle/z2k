package gvsub

import (
	"net/netip"
	"regexp"
	"strconv"
	"strings"
)

var clusterRe = regexp.MustCompile(`^rr?([0-9]+)(?:---|\.)(sn-[a-z0-9-]+)\.(?:googlevideo\.com|c\.youtube\.com|gvt1\.com)$`)

// NodeKind — 5-классовая классификация наблюдаемого кэш-узла.
type NodeKind int

const (
	KindUnknown NodeKind = iota
	KindGVCacheGoogle
	KindGVCacheISP
	KindPlayCache
	KindYouTubeCache
	KindSharedGFE
)

func (k NodeKind) String() string {
	switch k {
	case KindGVCacheGoogle:
		return "google"
	case KindGVCacheISP:
		return "isp"
	case KindPlayCache:
		return "play"
	case KindYouTubeCache:
		return "yt"
	case KindSharedGFE:
		return "gfe"
	default:
		return "unknown"
	}
}

// IsCluster возвращает true для всех реальных кэш-кластеров googlevideo/gvt1,
// чьи адреса публикуются в /tmp/z2k-gv-ips.txt.
func (k NodeKind) IsCluster() bool {
	return k == KindGVCacheGoogle || k == KindGVCacheISP || k == KindPlayCache
}

// ClassifyNode определяет класс узла по имени (с учётом IP для разделения Google/ISP GGC).
func ClassifyNode(name string, addr netip.Addr) NodeKind {
	norm := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(name)), ".")
	switch ClassifyTarget(norm) {
	case HostYouTubeCache:
		return KindYouTubeCache
	case HostSharedGFE:
		return KindSharedGFE
	case HostCluster:
		if strings.HasSuffix(norm, ".gvt1.com") {
			return KindPlayCache
		}
		a := addr.Unmap()
		if !a.IsValid() || isGoogle(a) {
			return KindGVCacheGoogle
		}
		return KindGVCacheISP
	default:
		return KindUnknown
	}
}

// SanitizeHostname проверяет и нормализует SNI/DNS-имя из внешнего журнала
// (например /tmp/z2k-gv-observed.tsv), пропуская только корректные целевые хосты.
func SanitizeHostname(raw string) (string, bool) {
	s := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(raw)), ".")
	if len(s) == 0 || len(s) > 253 {
		return "", false
	}
	labels := strings.Split(s, ".")
	if len(labels) < 2 {
		return "", false
	}
	for _, lbl := range labels {
		if len(lbl) == 0 || len(lbl) > 63 {
			return "", false
		}
		for i := 0; i < len(lbl); i++ {
			c := lbl[i]
			isLower := c >= 'a' && c <= 'z'
			isDigit := c >= '0' && c <= '9'
			isDash := c == '-' && i > 0 && i < len(lbl)-1
			if !isLower && !isDigit && !isDash {
				return "", false
			}
		}
	}
	if ClassifyTarget(s) == HostOther {
		return "", false
	}
	return s, true
}

// ParseCluster — логический кластер и машина в googlevideo.com/c.youtube.com/gvt1.com.
func ParseCluster(name string) (cluster string, machine int, ok bool) {
	m := clusterRe.FindStringSubmatch(strings.TrimSuffix(strings.ToLower(name), "."))
	if m == nil {
		return "", 0, false
	}
	n, _ := strconv.Atoi(m[1])
	return m[2], n, true
}

// IsCacheCluster — адрес относится к реальному видеокэш-кластеру (rrX---sn-*).
func IsCacheCluster(name string) bool {
	_, _, ok := ParseCluster(name)
	return ok
}

// IsYouTubeCache — видеокэш в зоне c.youtube.com (идёт в профиль yt_tcp).
func IsYouTubeCache(name string) bool {
	norm := strings.TrimSuffix(strings.ToLower(name), ".")
	return strings.HasSuffix(norm, ".c.youtube.com") && IsCacheCluster(norm)
}
