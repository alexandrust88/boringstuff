{{/*
Expand the name of the chart.
*/}}
{{- define "envoy-gateway-wrapper.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "envoy-gateway-wrapper.fullname" -}}
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
{{- define "envoy-gateway-wrapper.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "envoy-gateway-wrapper.labels" -}}
helm.sh/chart: {{ include "envoy-gateway-wrapper.chart" . }}
{{ include "envoy-gateway-wrapper.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: envoy-gateway
{{- if .Values.global.environment }}
environment: {{ .Values.global.environment }}
{{- end }}
{{- if .Values.global.clusterName }}
cluster: {{ .Values.global.clusterName }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "envoy-gateway-wrapper.selectorLabels" -}}
app.kubernetes.io/name: {{ include "envoy-gateway-wrapper.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "envoy-gateway-wrapper.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "envoy-gateway-wrapper.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Azure LoadBalancer annotations helper
Returns the complete set of Azure LoadBalancer annotations for static IP configuration
*/}}
{{- define "envoy-gateway-wrapper.azureLoadBalancerAnnotations" -}}
service.beta.kubernetes.io/azure-load-balancer-resource-group: {{ .Values.azure.loadBalancer.resourceGroup | default .Values.global.azureResourceGroup | quote }}
{{- if .Values.azure.loadBalancer.staticIP }}
service.beta.kubernetes.io/azure-load-balancer-ipv4: {{ .Values.azure.loadBalancer.staticIP | quote }}
{{- end }}
{{- if .Values.azure.loadBalancer.dnsLabel }}
service.beta.kubernetes.io/azure-dns-label-name: {{ .Values.azure.loadBalancer.dnsLabel | quote }}
{{- end }}
service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: {{ .Values.azure.loadBalancer.healthProbeRequestPath | default "/ready" | quote }}
{{- if .Values.azure.loadBalancer.internal }}
service.beta.kubernetes.io/azure-load-balancer-internal: "true"
{{- else }}
service.beta.kubernetes.io/azure-load-balancer-internal: "false"
{{- end }}
service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout: {{ .Values.azure.loadBalancer.idleTimeout | default "30" | quote }}
{{- end }}

{{/*
Get cluster configuration by cluster name
Usage: {{ include "envoy-gateway-wrapper.clusterConfig" (dict "clusterName" "cluster-001" "clusters" .Values.clusters) }}
*/}}
{{- define "envoy-gateway-wrapper.clusterConfig" -}}
{{- $clusterName := .clusterName -}}
{{- $clusters := .clusters -}}
{{- if hasKey $clusters $clusterName -}}
{{- $cluster := index $clusters $clusterName -}}
staticIP: {{ $cluster.staticIP | quote }}
dnsLabel: {{ $cluster.dnsLabel | quote }}
resourceGroup: {{ $cluster.resourceGroup | quote }}
{{- end -}}
{{- end }}

{{/*
Generate Azure LoadBalancer annotations for a specific cluster
Usage: {{ include "envoy-gateway-wrapper.clusterAzureAnnotations" (dict "clusterName" "cluster-001" "Values" .Values) }}
*/}}
{{- define "envoy-gateway-wrapper.clusterAzureAnnotations" -}}
{{- $clusterName := .clusterName -}}
{{- $values := .Values -}}
{{- if hasKey $values.clusters $clusterName -}}
{{- $cluster := index $values.clusters $clusterName -}}
service.beta.kubernetes.io/azure-load-balancer-resource-group: {{ $cluster.resourceGroup | quote }}
{{- if $cluster.staticIP }}
service.beta.kubernetes.io/azure-load-balancer-ipv4: {{ $cluster.staticIP | quote }}
{{- end }}
{{- if $cluster.dnsLabel }}
service.beta.kubernetes.io/azure-dns-label-name: {{ $cluster.dnsLabel | quote }}
{{- end }}
service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: {{ $values.azure.loadBalancer.healthProbePath | default "/ready" | quote }}
service.beta.kubernetes.io/azure-load-balancer-internal: {{ $values.azure.loadBalancer.internal | default false | quote }}
service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout: {{ $values.azure.loadBalancer.idleTimeoutMinutes | default 30 | quote }}
{{- end -}}
{{- end }}

{{/*
Validate required Azure configuration
*/}}
{{- define "envoy-gateway-wrapper.validateAzureConfig" -}}
{{- if and .Values.azure.loadBalancer.staticIP (not .Values.azure.loadBalancer.resourceGroup) }}
{{- fail "azure.loadBalancer.resourceGroup is required when staticIP is specified" }}
{{- end }}
{{- end }}

{{/*
Environment-specific resource suffix
*/}}
{{- define "envoy-gateway-wrapper.envSuffix" -}}
{{- if eq .Values.global.environment "prod" -}}
-prod
{{- else if eq .Values.global.environment "staging" -}}
-stg
{{- else -}}
-dev
{{- end -}}
{{- end }}

{{/*
Generate namespace name based on environment
*/}}
{{- define "envoy-gateway-wrapper.namespace" -}}
{{- if .Values.namespaceOverride -}}
{{ .Values.namespaceOverride }}
{{- else -}}
envoy-gateway-system
{{- end -}}
{{- end }}

{{/*
Check if monitoring is enabled
*/}}
{{- define "envoy-gateway-wrapper.monitoringEnabled" -}}
{{- if and .Values.monitoring .Values.monitoring.enabled -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Check if ServiceMonitor should be created
*/}}
{{- define "envoy-gateway-wrapper.serviceMonitorEnabled" -}}
{{- if and (eq (include "envoy-gateway-wrapper.monitoringEnabled" .) "true") .Values.monitoring.serviceMonitor .Values.monitoring.serviceMonitor.enabled -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Pod security context for restricted mode
*/}}
{{- define "envoy-gateway-wrapper.restrictedSecurityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
Container security context for restricted mode
*/}}
{{- define "envoy-gateway-wrapper.restrictedContainerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop:
    - ALL
{{- end }}
