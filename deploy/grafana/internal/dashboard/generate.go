package dashboard

import (
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
)

const PrometheusUID = "cube-cri-prometheus"

//go:embed source/base.json
var source embed.FS

func Generate() ([]byte, error) {
	raw, err := source.ReadFile("source/base.json")
	if err != nil {
		return nil, err
	}
	var dashboard map[string]any
	if err := json.Unmarshal(raw, &dashboard); err != nil {
		return nil, err
	}
	dashboard["panels"] = panels()
	if dashboard["uid"] != "cube-cri-runtime" {
		return nil, fmt.Errorf("unexpected dashboard UID")
	}
	var out bytes.Buffer
	encoder := json.NewEncoder(&out)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(dashboard); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func panels() []any {
	return []any{
		row(1, "运行概览", 0),
		timeseriesWidth(30, "Kubelet Pod 启动耗时 P95", 1, 0, 8, "s", false, kubeletPodStartP95()),
		timeseriesWidth(2, "Sandbox 创建总耗时", 1, 8, 8, "s", false, quantiles("shim", "CreatePodSandbox")),
		timeseriesWidth(3, "Sandbox 创建结果速率", 1, 16, 8, "ops", true, []query{{"sum by (result) (rate(cube_cri_operations_total{node=~\"$node\",component=\"shim\",operation=\"CreatePodSandbox\"}[$__rate_interval]))", "{{result}}"}}),

		row(4, "节点资源与网络", 9),
		timeseries(5, "资源准备耗时", 10, 0, "s", false, quantiles("resource", "Prepare|NetworkPrepare")),
		timeseries(6, "资源准备结果速率", 10, 12, "ops", true, []query{{"sum by (operation, result) (rate(cube_cri_operations_total{node=~\"$node\",component=\"resource\",operation=~\"Prepare|NetworkPrepare\"}[$__rate_interval]))", "{{operation}} {{result}}"}}),
		timeseries(7, "Sandbox 锁等待 P95", 18, 0, "s", false, []query{{"histogram_quantile(0.95, sum by (le, lock) (rate(cube_cri_lock_wait_duration_seconds_bucket{node=~\"$node\"}[$__rate_interval])))", "{{lock}}"}}),
		timeseries(29, "资源与 RPC 并发", 18, 12, "short", false, []query{
			{"sum by (component, operation) (cube_cri_operations_inflight{node=~\"$node\"})", "{{component}} {{operation}}"},
			{"sum by (method) (cube_cri_rpc_inflight{node=~\"$node\"})", "RPC {{method}}"},
		}),

		row(8, "VMM worker", 26),
		timeseries(9, "Worker 阶段 P95", 27, 0, "s", false, []query{
			{"histogram_quantile(0.95, sum by (le, operation) (rate(cube_cri_operation_duration_seconds_bucket{node=~\"$node\",component=\"vmm\",operation=~\"prepare-intent|fork-exec|hello|fd-gate|placement|launch\",result=\"ok\"}[$__rate_interval])))", "{{operation}}"},
			{"histogram_quantile(0.95, sum by (le, operation) (rate(cube_cri_operation_duration_seconds_bucket{node=~\"$node\",component=\"vmm\",operation=~\"LaunchVmm|CreateVm|BootVm\",result=\"ok\"}[$__rate_interval])))", "{{operation}}"},
		}),
		timeseries(10, "Worker 阶段结果速率", 27, 12, "ops", true, []query{{"sum by (operation, result) (rate(cube_cri_operations_total{node=~\"$node\",component=\"vmm\"}[$__rate_interval]))", "{{operation}} {{result}}"}}),

		row(11, "Guest Agent 与任务创建", 35),
		timeseriesWidth(12, "Agent 创建耗时", 36, 0, 8, "s", false, quantiles("agent", "CreateSandbox|CreateContainer")),
		timeseriesWidth(31, "Task 创建与启动 P95", 36, 8, 8, "s", false, operationP95("shim|agent", "TaskCreate|TaskStart|StartContainer")),
		timeseriesWidth(13, "任务生命周期结果速率", 36, 16, 8, "ops", true, []query{{"sum by (component, operation, result) (rate(cube_cri_operations_total{node=~\"$node\",component=~\"agent|shim\",operation=~\"CreateSandbox|CreateContainer|TaskCreate|TaskStart|StartContainer\"}[$__rate_interval]))", "{{component}} {{operation}} {{result}}"}}),

		row(14, "释放、恢复与状态", 44),
		timeseries(15, "资源释放耗时", 45, 0, "s", false, quantiles("resource", "Release|NetworkRelease|SharedRootCleanup")),
		timeseries(16, "资源释放结果速率", 45, 12, "ops", true, []query{{"sum by (operation, result) (rate(cube_cri_operations_total{node=~\"$node\",component=\"resource\",operation=~\"Release|NetworkRelease|SharedRootCleanup\"}[$__rate_interval]))", "{{operation}} {{result}}"}}),
		timeseries(17, "资源租约状态", 53, 0, "short", false, []query{{"sum by (node, phase) (cube_cri_resource_leases{node=~\"$node\"})", "{{node}} {{phase}}"}}),
		timeseries(18, "Reaper 待处理任务", 53, 12, "short", false, []query{{"sum by (node) (cube_cri_reaper_pending_jobs{node=~\"$node\"})", "{{node}}"}}),
		timeseries(19, "Reaper 最老任务年龄", 61, 0, "s", false, []query{{"(time() - cube_cri_reaper_oldest_job_timestamp_seconds{node=~\"$node\"}) * (cube_cri_reaper_oldest_job_timestamp_seconds{node=~\"$node\"} > bool 0)", "{{node}}"}}),

		row(20, "错误定位", 69),
		timeseries(21, "内部操作错误速率", 70, 0, "ops", true, []query{{"sum by (component, operation) (rate(cube_cri_operations_total{node=~\"$node\",result=\"error\"}[$__rate_interval]))", "{{component}} {{operation}}"}}),
		timeseries(22, "错误类别速率", 70, 12, "ops", true, []query{{"sum by (component, operation, error_class) (rate(cube_cri_operation_failures_total{node=~\"$node\"}[$__rate_interval]))", "{{component}} {{operation}} {{error_class}}"}}),
		timeseries(23, "RuntimeResource RPC 错误速率", 78, 0, "ops", true, []query{{"sum by (method, code) (rate(cube_cri_rpc_requests_total{node=~\"$node\",code!=\"OK\"}[$__rate_interval]))", "{{method}} {{code}}"}}),

		row(24, "节点与采集健康", 86),
		timeseries(25, "指标端点可达性", 87, 0, "short", false, []query{{"up{job=\"cube-cri\",node=~\"$node\"}", "{{node}}"}}),
		timeseries(26, "事件链路速率", 87, 12, "ops", true, []query{
			{"sum by (node, result) (rate(cube_cri_metric_events_total{node=~\"$node\"}[$__rate_interval]))", "{{node}} {{result}}"},
			{"sum by (node) (rate(cube_cri_metric_events_dropped_total{node=~\"$node\"}[$__rate_interval]))", "{{node}} dropped"},
		}),
		timeseries(27, "状态采样结果", 95, 0, "short", false, []query{{"cube_cri_state_collection_success{node=~\"$node\"}", "{{node}}"}}),
		timeseries(28, "状态采样年龄", 95, 12, "s", false, []query{{"time() - cube_cri_state_collection_timestamp_seconds{node=~\"$node\"}", "{{node}}"}}),
	}
}

func quantiles(component, operation string) []query {
	base := "sum by (le, component, operation) (rate(cube_cri_operation_duration_seconds_bucket{node=~\"$node\",component=~\"" + component + "\",operation=~\"" + operation + "\",result=\"ok\"}[$__rate_interval]))"
	return []query{
		{"histogram_quantile(0.50, " + base + ")", "{{component}} {{operation}} p50"},
		{"histogram_quantile(0.95, " + base + ")", "{{component}} {{operation}} p95"},
		{"histogram_quantile(0.99, " + base + ")", "{{component}} {{operation}} p99"},
	}
}

func operationP95(component, operation string) []query {
	base := "sum by (le, component, operation) (rate(cube_cri_operation_duration_seconds_bucket{node=~\"$node\",component=~\"" + component + "\",operation=~\"" + operation + "\",result=\"ok\"}[$__rate_interval]))"
	return []query{{"histogram_quantile(0.95, " + base + ")", "{{component}} {{operation}} p95"}}
}

func kubeletPodStartP95() []query {
	return []query{
		{"histogram_quantile(0.95, sum by (le) (rate(kubelet_pod_start_duration_seconds_bucket{job=\"kubelet\",node=~\"$node\"}[$__rate_interval])))", "首次见 Pod 到 Running p95"},
		{"histogram_quantile(0.95, sum by (le) (rate(kubelet_pod_start_sli_duration_seconds_bucket{job=\"kubelet\",node=~\"$node\"}[$__rate_interval])))", "创建到 ContainersStarted p95"},
		{"histogram_quantile(0.95, sum by (le) (rate(kubelet_pod_start_total_duration_seconds_bucket{job=\"kubelet\",node=~\"$node\"}[$__rate_interval])))", "创建到 ContainersStarted（含镜像）p95"},
	}
}

type query struct{ Expr, Legend string }

func row(id int, title string, y int) map[string]any {
	return map[string]any{"collapsed": false, "gridPos": map[string]int{"h": 1, "w": 24, "x": 0, "y": y}, "id": id, "panels": []any{}, "title": title, "type": "row"}
}

func timeseries(id int, title string, y, x int, unit string, stack bool, queries []query) map[string]any {
	return timeseriesWidth(id, title, y, x, 12, unit, stack, queries)
}

func timeseriesWidth(id int, title string, y, x, width int, unit string, stack bool, queries []query) map[string]any {
	targets := make([]any, 0, len(queries))
	for index, query := range queries {
		targets = append(targets, map[string]any{"datasource": datasource(), "editorMode": "code", "expr": query.Expr, "legendFormat": query.Legend, "range": true, "refId": string(rune('A' + index))})
	}
	stacking := map[string]string{"mode": "none"}
	if stack {
		stacking["mode"] = "normal"
	}
	return map[string]any{
		"datasource": datasource(), "fieldConfig": map[string]any{"defaults": map[string]any{"unit": unit, "custom": map[string]any{"drawStyle": "line", "lineWidth": 1, "fillOpacity": 8, "showPoints": "never", "spanNulls": false, "stacking": stacking}}, "overrides": []any{}},
		"gridPos": map[string]int{"h": 8, "w": width, "x": x, "y": y}, "id": id,
		"options": map[string]any{"legend": map[string]any{"displayMode": "table", "placement": "bottom", "showLegend": true, "calcs": []string{"lastNotNull", "max"}}, "tooltip": map[string]string{"mode": "multi", "sort": "desc"}},
		"targets": targets, "title": title, "type": "timeseries",
	}
}

func datasource() map[string]string {
	return map[string]string{"type": "prometheus", "uid": PrometheusUID}
}
