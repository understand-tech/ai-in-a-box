package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func newServer(t *testing.T, now func() time.Time) *httptest.Server {
	t.Helper()
	lease := &Lease{}
	mux := http.NewServeMux()
	mux.HandleFunc("/lease", leaseHandler(lease, now))
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

func decode(t *testing.T, resp *http.Response) LeaseStatus {
	t.Helper()
	defer resp.Body.Close()
	var status LeaseStatus
	if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
		t.Fatalf("decoding the response: %v", err)
	}
	return status
}

func TestAcquireWithNoIDIsRefused(t *testing.T) {
	server := newServer(t, func() time.Time { return epoch })
	resp, err := http.Post(server.URL+"/lease", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status %d, want %d", resp.StatusCode, http.StatusBadRequest)
	}
}

func TestAcquireByTheFirstBoxReturns200(t *testing.T) {
	server := newServer(t, func() time.Time { return epoch })
	resp, err := http.Post(server.URL+"/lease?id=box-a", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d, want %d", resp.StatusCode, http.StatusOK)
	}
	got := decode(t, resp)
	if !got.Held || got.Holder != "box-a" {
		t.Fatalf("got %+v, want held by box-a", got)
	}
}

func TestAcquireBySecondBoxReturns409(t *testing.T) {
	server := newServer(t, func() time.Time { return epoch })
	mustPost(t, server.URL+"/lease?id=box-a")
	resp, err := http.Post(server.URL+"/lease?id=box-b", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("status %d, want %d — a second holder must be refused, never silently granted", resp.StatusCode, http.StatusConflict)
	}
	got := decode(t, resp)
	if got.Held {
		t.Fatalf("got %+v, want not held: box-b must not read itself as active", got)
	}
}

func TestGetReadsTheLeaseWithoutAcquiringIt(t *testing.T) {
	server := newServer(t, func() time.Time { return epoch })
	mustPost(t, server.URL+"/lease?id=box-a")
	resp, err := http.Get(server.URL + "/lease")
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d, want %d", resp.StatusCode, http.StatusOK)
	}
	got := decode(t, resp)
	if !got.Held || got.Holder != "box-a" {
		t.Fatalf("got %+v, want held by box-a", got)
	}
}

func TestDeleteReleasesTheLease(t *testing.T) {
	server := newServer(t, func() time.Time { return epoch })
	mustPost(t, server.URL+"/lease?id=box-a")
	req, err := http.NewRequest(http.MethodDelete, server.URL+"/lease?id=box-a", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := http.DefaultClient.Do(req); err != nil {
		t.Fatal(err)
	}
	resp, err := http.Post(server.URL+"/lease?id=box-b", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d, want %d: box-b should acquire right after box-a released", resp.StatusCode, http.StatusOK)
	}
}

func mustPost(t *testing.T, url string) {
	t.Helper()
	resp, err := http.Post(url, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
}
