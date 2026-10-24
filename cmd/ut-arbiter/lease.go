package main

import (
	"sync"
	"time"
)

// Lease is the arbiter's only state: which of the two paired boxes currently
// holds it, and until when. A box is the active one only while it holds the
// lease — losing contact with the arbiter must never be read as holding it.
// That is what prevents two primaries: a box isolated from the arbiter falls
// silent instead of assuming it is the only one left.
type Lease struct {
	mu        sync.Mutex
	holder    string
	expiresAt time.Time
}

// LeaseStatus is what a caller is told, whether it asked to acquire the lease
// or only to read it.
type LeaseStatus struct {
	Held      bool      `json:"held"`
	Holder    string    `json:"holder,omitempty"`
	ExpiresAt time.Time `json:"expires_at,omitempty"`
}

// Acquire grants or renews the lease for id at now, for ttl, unless somebody
// else holds it and that hold has not expired.
func (l *Lease) Acquire(id string, now time.Time, ttl time.Duration) LeaseStatus {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.holder == "" || l.holder == id || !now.Before(l.expiresAt) {
		l.holder = id
		l.expiresAt = now.Add(ttl)
		return LeaseStatus{Held: true, Holder: id, ExpiresAt: l.expiresAt}
	}
	return LeaseStatus{Held: false, Holder: l.holder, ExpiresAt: l.expiresAt}
}

// Release gives the lease up early, id's own hold only: a box stepping down
// on purpose should not make its peer wait out the full ttl before taking
// over.
func (l *Lease) Release(id string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.holder == id {
		l.holder = ""
		l.expiresAt = time.Time{}
	}
}

// Status reports the lease without acquiring it. An expired lease reads as
// unheld — nobody is told to stand down for a holder whose time is already up.
func (l *Lease) Status(now time.Time) LeaseStatus {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.holder == "" || !now.Before(l.expiresAt) {
		return LeaseStatus{Held: false}
	}
	return LeaseStatus{Held: true, Holder: l.holder, ExpiresAt: l.expiresAt}
}
