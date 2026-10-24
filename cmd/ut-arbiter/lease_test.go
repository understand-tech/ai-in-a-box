package main

import (
	"testing"
	"time"
)

var epoch = time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC)

func TestAcquireGrantsToTheFirstRequester(t *testing.T) {
	var l Lease
	got := l.Acquire("box-a", epoch, 15*time.Second)
	if !got.Held || got.Holder != "box-a" {
		t.Fatalf("got %+v, want held by box-a", got)
	}
}

func TestAcquireDeniesASecondHolderBeforeExpiry(t *testing.T) {
	var l Lease
	l.Acquire("box-a", epoch, 15*time.Second)
	got := l.Acquire("box-b", epoch.Add(5*time.Second), 15*time.Second)
	if got.Held {
		t.Fatalf("box-b got the lease while box-a's hold had not expired: %+v", got)
	}
	if got.Holder != "box-a" {
		t.Fatalf("got holder %q, want box-a named as the refusal's reason", got.Holder)
	}
}

func TestAcquireRenewsForTheCurrentHolder(t *testing.T) {
	var l Lease
	l.Acquire("box-a", epoch, 15*time.Second)
	got := l.Acquire("box-a", epoch.Add(10*time.Second), 15*time.Second)
	want := epoch.Add(10 * time.Second).Add(15 * time.Second)
	if !got.Held || !got.ExpiresAt.Equal(want) {
		t.Fatalf("got %+v, want held by box-a, expiring %s", got, want)
	}
}

func TestAcquireGrantsAgainAfterExpiry(t *testing.T) {
	var l Lease
	l.Acquire("box-a", epoch, 15*time.Second)
	got := l.Acquire("box-b", epoch.Add(16*time.Second), 15*time.Second)
	if !got.Held || got.Holder != "box-b" {
		t.Fatalf("got %+v, want box-b holding it once box-a's lease expired", got)
	}
}

func TestReleaseLetsAnotherAcquireImmediately(t *testing.T) {
	var l Lease
	l.Acquire("box-a", epoch, 15*time.Second)
	l.Release("box-a", epoch.Add(1*time.Second))
	got := l.Acquire("box-b", epoch.Add(1*time.Second), 15*time.Second)
	if !got.Held || got.Holder != "box-b" {
		t.Fatalf("got %+v, want box-b holding it right after box-a released", got)
	}
}

func TestReleaseIgnoresAnIDThatDoesNotHoldIt(t *testing.T) {
	var l Lease
	l.Acquire("box-a", epoch, 15*time.Second)
	l.Release("box-b", epoch.Add(1*time.Second))
	got := l.Status(epoch.Add(1 * time.Second))
	if !got.Held || got.Holder != "box-a" {
		t.Fatalf("got %+v, want box-a still holding it: a release is not a command the lease obeys from anyone", got)
	}
}

func TestStatusReportsUnheldBeforeAnyAcquire(t *testing.T) {
	var l Lease
	got := l.Status(epoch)
	if got.Held {
		t.Fatalf("got %+v, want unheld", got)
	}
}

func TestStatusReportsUnheldOnceExpired(t *testing.T) {
	var l Lease
	l.Acquire("box-a", epoch, 15*time.Second)
	got := l.Status(epoch.Add(16 * time.Second))
	if got.Held {
		t.Fatalf("got %+v, want unheld — a status read never extends a lease, and an expired one tells nobody to stand down", got)
	}
}

func TestStatusNeverExtendsTheLease(t *testing.T) {
	var l Lease
	l.Acquire("box-a", epoch, 15*time.Second)
	l.Status(epoch.Add(10 * time.Second))
	got := l.Status(epoch.Add(16 * time.Second))
	if got.Held {
		t.Fatalf("got %+v, want unheld: reading the status at 10s must not have pushed expiry past 15s", got)
	}
}
