package main

import (
	"fmt"
	"io"
	"sort"
	"strings"
	"sync"
	"time"
)

// metricSet — минимальный экспозитор Prometheus text format без зависимостей:
// counters по (имя, метки), gauges по функции, одна форма гистограммы.
type metricSet struct {
	mu       sync.Mutex
	counters map[string]map[string]int64 // name -> labels -> value
	gauges   map[string]func() int64
	hists    map[string]*histogram
	order    []string
}

var histBuckets = []float64{0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5}

type histogram struct {
	counts []int64 // по бакетам
	sum    float64
	total  int64
}

func newMetricSet() *metricSet {
	return &metricSet{
		counters: map[string]map[string]int64{},
		gauges:   map[string]func() int64{},
		hists:    map[string]*histogram{},
	}
}

var metrics = newMetricSet()

func (m *metricSet) remember(name string) {
	for _, n := range m.order {
		if n == name {
			return
		}
	}
	m.order = append(m.order, name)
}

func (m *metricSet) inc(name, labels string) { m.add(name, labels, 1) }

func (m *metricSet) add(name, labels string, v int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.remember(name)
	if m.counters[name] == nil {
		m.counters[name] = map[string]int64{}
	}
	m.counters[name][labels] += v
}

func (m *metricSet) gauge(name string, f func() int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.remember(name)
	m.gauges[name] = f
}

func (m *metricSet) observe(name string, d time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.remember(name)
	h := m.hists[name]
	if h == nil {
		h = &histogram{counts: make([]int64, len(histBuckets))}
		m.hists[name] = h
	}
	sec := d.Seconds()
	for i, b := range histBuckets {
		if sec <= b {
			h.counts[i]++
		}
	}
	h.sum += sec
	h.total++
}

func fmtBucket(b float64) string {
	return strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.3f", b), "0"), ".")
}

func (m *metricSet) write(w io.Writer) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, name := range m.order {
		if c, ok := m.counters[name]; ok {
			fmt.Fprintf(w, "# TYPE %s counter\n", name)
			keys := make([]string, 0, len(c))
			for k := range c {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				if k == "" {
					fmt.Fprintf(w, "%s %d\n", name, c[k])
				} else {
					fmt.Fprintf(w, "%s{%s} %d\n", name, k, c[k])
				}
			}
		}
		if g, ok := m.gauges[name]; ok {
			fmt.Fprintf(w, "# TYPE %s gauge\n%s %d\n", name, name, g())
		}
		if h, ok := m.hists[name]; ok {
			fmt.Fprintf(w, "# TYPE %s histogram\n", name)
			for i, b := range histBuckets {
				fmt.Fprintf(w, "%s_bucket{le=\"%s\"} %d\n", name, fmtBucket(b), h.counts[i])
			}
			fmt.Fprintf(w, "%s_bucket{le=\"+Inf\"} %d\n%s_sum %.6f\n%s_count %d\n", name, h.total, name, h.sum, name, h.total)
		}
	}
}
