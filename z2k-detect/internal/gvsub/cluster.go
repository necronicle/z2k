package gvsub

import (
	"regexp"
	"strconv"
	"strings"
)

var clusterRe = regexp.MustCompile(`^rr?([0-9]+)(?:---|\.)(sn-[a-z0-9-]+)\.(?:googlevideo\.com|c\.youtube\.com|gvt1\.com)$`)

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
