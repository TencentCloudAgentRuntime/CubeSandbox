package dashboard

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestGenerate(t *testing.T) {
	data, err := Generate()
	if err != nil {
		t.Fatal(err)
	}
	if !json.Valid(data) {
		t.Fatal("generated dashboard is invalid JSON")
	}
	var dashboard struct {
		Panels []struct {
			Title   string `json:"title"`
			Type    string `json:"type"`
			Targets []struct {
				Expr string `json:"expr"`
			} `json:"targets"`
		} `json:"panels"`
	}
	if err := json.Unmarshal(data, &dashboard); err != nil {
		t.Fatal(err)
	}
	wantRows := []string{"运行概览", "节点资源与网络", "VMM worker", "Guest Agent 与任务创建", "释放、恢复与状态", "错误定位", "节点与采集健康"}
	var gotRows []string
	for _, panel := range dashboard.Panels {
		if panel.Type == "row" {
			gotRows = append(gotRows, panel.Title)
			continue
		}
		if panel.Type != "timeseries" {
			t.Fatalf("panel %q type=%q, want timeseries", panel.Title, panel.Type)
		}
		for _, target := range panel.Targets {
			if strings.Contains(target.Expr, "increase(") {
				t.Fatalf("panel %q uses increase", panel.Title)
			}
		}
	}
	if strings.Join(gotRows, ",") != strings.Join(wantRows, ",") {
		t.Fatalf("rows=%v, want %v", gotRows, wantRows)
	}
}
