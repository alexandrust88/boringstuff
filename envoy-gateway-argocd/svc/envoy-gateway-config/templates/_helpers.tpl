{{/*
Expand the name of the chart.
*/}}
{{- define "envoy-gateway-config.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "envoy-gateway-config.labels" -}}
helm.sh/chart: {{ include "envoy-gateway-config.name" . }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: envoy-gateway
{{- end }}
