{{/*
Expand the name of the chart.
*/}}
{{- define "argocd-envoy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "argocd-envoy.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "argocd-envoy.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "argocd-envoy.labels" -}}
helm.sh/chart: {{ include "argocd-envoy.chart" . }}
{{ include "argocd-envoy.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "argocd-envoy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "argocd-envoy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Gateway namespace - defaults to gateway.namespace or Release.Namespace
*/}}
{{- define "argocd-envoy.gatewayNamespace" -}}
{{- .Values.gateway.namespace | default .Release.Namespace }}
{{- end }}

{{/*
Service namespace - defaults to service.namespace or "argocd"
*/}}
{{- define "argocd-envoy.serviceNamespace" -}}
{{- .Values.service.namespace | default "argocd" }}
{{- end }}
