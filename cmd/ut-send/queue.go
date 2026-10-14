package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	maxAge        = 7 * 24 * time.Hour
	maxQueueBytes = 200 << 20
)

var kinds = map[string]string{
	"report": "/reports",
	"usage":  "/conso",
}

type Item struct {
	Name    string
	Kind    string
	Created time.Time
	Size    int64
}

func queueDir(state string) string { return filepath.Join(state, "queue") }

func itemName(created time.Time, kind string) string {
	return fmt.Sprintf("%020d-%s", created.UnixNano(), kind)
}

func parseItem(name string) (Item, bool) {
	stamp, kind, found := strings.Cut(name, "-")
	if !found {
		return Item{}, false
	}
	if _, known := kinds[kind]; !known {
		return Item{}, false
	}
	nanos, err := strconv.ParseInt(stamp, 10, 64)
	if err != nil {
		return Item{}, false
	}
	return Item{Name: name, Kind: kind, Created: time.Unix(0, nanos).UTC()}, true
}

func listQueue(dir string) ([]Item, error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var items []Item
	for _, entry := range entries {
		item, ok := parseItem(entry.Name())
		if !ok || !entry.Type().IsRegular() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return nil, err
		}
		item.Size = info.Size()
		items = append(items, item)
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Name < items[j].Name })
	return items, nil
}

// Oldest first: what is too old goes, then the oldest until the rest fits.
func prune(items []Item, now time.Time, maxBytes int64, oldest time.Duration) (keep, drop []Item) {
	var total int64
	for _, item := range items {
		if now.Sub(item.Created) > oldest {
			drop = append(drop, item)
			continue
		}
		keep = append(keep, item)
		total += item.Size
	}
	for len(keep) > 0 && total > maxBytes {
		total -= keep[0].Size
		drop, keep = append(drop, keep[0]), keep[1:]
	}
	return keep, drop
}

func enqueue(dir, kind string, content []byte, now time.Time) error {
	if _, known := kinds[kind]; !known {
		return fmt.Errorf("unknown kind %q: report or usage", kind)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	created := now
	for {
		if _, err := os.Stat(filepath.Join(dir, itemName(created, kind))); errors.Is(err, os.ErrNotExist) {
			break
		}
		created = created.Add(time.Nanosecond)
	}
	return writeWhole(filepath.Join(dir, itemName(created, kind)), content)
}
