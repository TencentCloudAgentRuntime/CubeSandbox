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
	wantRows := []string{"端到端启动定位", "Kubernetes 控制链路", "Shim 与 VMM worker", "Guest Agent 与任务创建", "节点资源、网络与并发", "释放、恢复与状态", "错误定位", "节点与采集健康"}
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
	startPathPanelFound := false
	for i := range dashboard.Panels {
		if dashboard.Panels[i].Title == "模板派生与冷启动沙箱事件速率" {
			if len(dashboard.Panels[i].Targets) != 2 ||
				!strings.Contains(dashboard.Panels[i].Targets[0].Expr, "TemplateDerivedSandbox") ||
				!strings.Contains(dashboard.Panels[i].Targets[1].Expr, "ColdStartSandbox") {
				t.Fatal("template-derived and cold-start panel targets are invalid")
			}
			startPathPanelFound = true
			break
		}
	}
	if !startPathPanelFound {
		t.Fatal("missing template-derived and cold-start sandbox event panel")
	}
	for _, panel := range dashboard.Panels {
		if panel.Title != "Kubelet Pod 启动耗时 P95" && panel.Title != "Kubelet 同步与 CRI P95" && panel.Title != "API Server Pod POST P95" {
			continue
		}
		for _, target := range panel.Targets {
			if !strings.Contains(target.Expr, "[1m]") {
				t.Fatalf("panel %q must use the fixed 1m rate window: %s", panel.Title, target.Expr)
			}
		}
	}
}
