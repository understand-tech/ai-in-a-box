package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

const peopleWindowDays = 7

var knownApps = []string{"app", "assistants", "llms", "workbench", "appbuilder", "dep", "agentic", "tabular",
	"assistants-analyst"}

type ToolHour struct {
	Hour     int64  `json:"hour"`
	Source   string `json:"source"`
	App      string `json:"app"`
	Requests int64  `json:"requests"`
}

type ToolPeople struct {
	Source string `json:"source"`
	App    string `json:"app"`
	Users  int64  `json:"users"`
}

type Tools struct {
	RequestsByHour []ToolHour   `json:"requests_by_hour"`
	Users7d        []ToolPeople `json:"users_7d"`
}

// Runs inside the database container: only counts come out of it, never who
// asked or what.
const countInTheDatabase = `
db.getSiblingDB('admin').auth(process.env.MONGO_INITDB_ROOT_USERNAME, process.env.MONGO_INITDB_ROOT_PASSWORD);
const platform = db.getSiblingDB(process.env.MONGO_INITDB_DATABASE);
const now = Date.now() / 1000;
const since = now - DAYS * 86400, peopleSince = now - PEOPLE_DAYS * 86400;
const known = new Set(KNOWN_APPS);
const toolOf = app => !app ? 'none' : known.has(app) ? app : 'other';
const requests = {}, people = {};
const served = (source, seconds, app, who) => {
    const tool = toolOf(app);
    const hour = [Math.floor(seconds / 3600) * 3600, source, tool].join(' ');
    requests[hour] = (requests[hour] || 0) + 1;
    if (seconds < peopleSince || !who) return;
    for (const group of [source + ' ' + tool, 'any any']) (people[group] = people[group] || new Set()).add(who);
};
platform.gateway_usage.find({ ts: { $gte: since } }, { _id: 0, ts: 1, app: 1, user_email: 1 })
    .forEach(d => served('gateway', d.ts, d.app, d.user_email));
platform.prompt_response_collector.find({ time: { $gte: new Date(since * 1000) } }, { _id: 0, time: 1, app: 1, user: 1 })
    .forEach(d => served('chat', d.time.getTime() / 1000, d.app, d.user));
print(JSON.stringify({
    requests_by_hour: Object.entries(requests).map(([key, n]) => {
        const [hour, source, app] = key.split(' ');
        return { hour: Number(hour), source, app, requests: n };
    }),
    users_7d: Object.entries(people).map(([group, who]) => {
        const [source, app] = group.split(' ');
        return { source, app, users: who.size };
    }),
}));
`

func countingScript(days int) string {
	apps, _ := json.Marshal(knownApps)
	return fmt.Sprintf("const DAYS = %d, PEOPLE_DAYS = %d, KNOWN_APPS = %s;", days, peopleWindowDays, apps) + countInTheDatabase
}

func parseTools(output string) (Tools, bool) {
	lines := strings.Split(strings.TrimSpace(output), "\n")
	var found Tools
	if json.Unmarshal([]byte(lines[len(lines)-1]), &found) != nil || found.RequestsByHour == nil || found.Users7d == nil {
		return Tools{}, false
	}
	sort.Slice(found.RequestsByHour, func(i, j int) bool {
		a, b := found.RequestsByHour[i], found.RequestsByHour[j]
		if a.Hour != b.Hour {
			return a.Hour < b.Hour
		}
		if a.Source != b.Source {
			return a.Source < b.Source
		}
		return a.App < b.App
	})
	sort.Slice(found.Users7d, func(i, j int) bool {
		a, b := found.Users7d[i], found.Users7d[j]
		if a.Source != b.Source {
			return a.Source < b.Source
		}
		return a.App < b.App
	})
	return found, true
}

func (m machine) tools(days int) (Tools, []string) {
	nothing := Tools{RequestsByHour: []ToolHour{}, Users7d: []ToolPeople{}}
	id := runningContainer(m.containers(), "mongodb")
	if id == "" {
		return nothing, nil
	}
	output, err := m.run("", "docker", "exec", id, "mongosh", "--quiet", "--eval", countingScript(days))
	if err != nil {
		return nothing, []string{"tools-unreadable:mongodb"}
	}
	found, ok := parseTools(output)
	if !ok {
		return nothing, []string{"tools-unreadable:mongodb"}
	}
	return found, nil
}
