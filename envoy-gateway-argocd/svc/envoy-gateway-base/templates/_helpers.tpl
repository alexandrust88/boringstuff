{{/*
Expand the name of the chart.
*/}}
{{- define "envoy-gateway-base.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "envoy-gateway-base.labels" -}}
helm.sh/chart: {{ include "envoy-gateway-base.name" . }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: envoy-gateway
{{- end }}
