package gvsub

import (
	"regexp"
	"strconv"
	"strings"
)

var clusterRe = regexp.MustCompile(`^rr?([0-9]+)(?:---|\.)(sn-[a-z0-9-]+)\.(?:googlevideo\.com|c\.youtube\.com|gvt1\.com)$`)

// ParseCluster — логический кластер и машина в googlevideo.com/c.youtube.com.
func ParseCluster(name string) (cluster string, machine int, ok bool) {
	m := clusterRe.FindStringSubmatch(strings.TrimSuffix(strings.ToLower(name), "."))
	if m == nil {
		return "", 0, false
	}
	n, _ := strconv.Atoi(m[1])
	return m[2], n, true
}
