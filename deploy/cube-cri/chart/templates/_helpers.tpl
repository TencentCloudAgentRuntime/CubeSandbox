{{- define "cube-cri.name" -}}
cube-cri
{{- end }}

{{- define "cube-cri.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "cube-cri.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "cube-cri.labels" -}}
app.kubernetes.io/name: {{ include "cube-cri.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{- define "cube-cri.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cube-cri.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "cube-cri.image" -}}
{{- $repository := required "image.repository 不能为空" .Values.image.repository -}}
{{- $digest := required "image.digest 不能为空" .Values.image.digest -}}
{{- printf "%s@sha256:%s" $repository $digest -}}
{{- end }}
