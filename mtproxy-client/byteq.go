package main

import "sync"

// byteQueue — FIFO кадров, ограниченная суммой байт. push никогда не
// блокирует: переполнение — это нарушение окна отправителем (v2) или
// потолок стрима (v1), и решает его вызывающий, а не ожидание.
type byteQueue struct {
	mu     sync.Mutex
	cond   *sync.Cond
	frames [][]byte
	bytes  int64
	capB   int64
	closed bool
	done   bool // finish(): входа больше нет, хвост дочитывается
}

func newByteQueue(capBytes int64) *byteQueue {
	q := &byteQueue{capB: capBytes}
	q.cond = sync.NewCond(&q.mu)
	return q
}

func (q *byteQueue) push(f []byte) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed || q.done || q.bytes+int64(len(f)) > q.capB {
		return false
	}
	q.frames = append(q.frames, f)
	q.bytes += int64(len(f))
	q.cond.Signal()
	return true
}

func (q *byteQueue) pop() ([]byte, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.frames) == 0 {
		return nil, false
	}
	f := q.frames[0]
	q.frames[0] = nil
	q.frames = q.frames[1:]
	q.bytes -= int64(len(f))
	if len(q.frames) == 0 {
		q.frames = nil // отдать хвост массива сборщику
	}
	return f, true
}

// wait блокирует, пока не появится кадр. Отмена — через close() или done;
// done слушает отдельная горутина, будящая cond.
func (q *byteQueue) wait(done <-chan struct{}) bool {
	stop := make(chan struct{})
	go func() {
		select {
		case <-done:
			q.mu.Lock()
			q.cond.Broadcast()
			q.mu.Unlock()
		case <-stop:
		}
	}()
	defer close(stop)
	q.mu.Lock()
	defer q.mu.Unlock()
	for len(q.frames) == 0 && !q.closed && !q.done {
		select {
		case <-done:
			return false
		default:
		}
		q.cond.Wait()
	}
	return !q.closed && len(q.frames) > 0
}

// finish — отправитель закончил (CLOSE от релея): новых кадров не будет,
// но уже принятые дописываются; wait вернёт false, когда очередь опустеет.
func (q *byteQueue) finish() {
	q.mu.Lock()
	q.done = true
	q.cond.Broadcast()
	q.mu.Unlock()
}

func (q *byteQueue) close() {
	q.mu.Lock()
	q.closed = true
	q.frames = nil
	q.bytes = 0
	q.cond.Broadcast()
	q.mu.Unlock()
}

func (q *byteQueue) queued() int64 {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.bytes
}

func (q *byteQueue) setCap(n int64) {
	q.mu.Lock()
	q.capB = n
	q.mu.Unlock()
}

func (q *byteQueue) isClosed() bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.closed
}
