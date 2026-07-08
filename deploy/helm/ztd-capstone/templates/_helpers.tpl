{{/*
Base chart name.
*/}}
{{- define "ztd.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name, used as a prefix for release-scoped resources
(ServiceAccounts, Deployments, etc). Service names for the app services and
postgres are intentionally left un-prefixed (see ztd.svcName) so that the
inter-service DNS names stay stable across releases/upgrades.
*/}}
{{- define "ztd.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart name and version label.
*/}}
{{- define "ztd.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every resource.
*/}}
{{- define "ztd.labels" -}}
helm.sh/chart: {{ include "ztd.chart" . }}
{{ include "ztd.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
project: ztd-capstone
{{- end -}}

{{/*
Base selector labels shared by every resource (release scoped).
*/}}
{{- define "ztd.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ztd.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Per-service selector labels. Usage: include "ztd.serviceSelectorLabels" (dict "root" $ "service" $svcName)
*/}}
{{- define "ztd.serviceSelectorLabels" -}}
{{ include "ztd.selectorLabels" .root }}
app.kubernetes.io/component: {{ .service }}
{{- end -}}

{{/*
Per-service labels (selector labels + service label). Usage: include "ztd.serviceLabels" (dict "root" $ "service" $svcName)
*/}}
{{- define "ztd.serviceLabels" -}}
{{ include "ztd.labels" .root }}
app.kubernetes.io/component: {{ .service }}
{{- end -}}

{{/*
Un-prefixed Service/DNS name for a given service key. Kept stable (no
release-name prefix) so peer services can reach each other via plain
short names (e.g. http://catalog:8080) regardless of the Helm release
name, and so the Postgres headless Service is reachable as "postgres".
Usage: include "ztd.svcName" (dict "service" $svcName)
*/}}
{{- define "ztd.svcName" -}}
{{- .service -}}
{{- end -}}

{{/*
Release-scoped resource name for a given service key (used for
ServiceAccounts, Deployments, etc). Usage: include "ztd.svcFullname" (dict "root" $ "service" $svcName)
*/}}
{{- define "ztd.svcFullname" -}}
{{- printf "%s-%s" (include "ztd.fullname" .root) .service | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Render a full image reference: registry/repo:tag, with per-service tag
override support. Usage: include "ztd.image" (dict "root" $ "svc" $svcValues)
*/}}
{{- define "ztd.image" -}}
{{- $root := .root -}}
{{- $svc := .svc -}}
{{- $registry := $root.Values.image.registry -}}
{{- $repo := $svc.image.repo -}}
{{- $tag := $root.Values.image.tag -}}
{{- if $svc.image.tagOverride -}}
{{- $tag = $svc.image.tagOverride -}}
{{- end -}}
{{- printf "%s/%s:%s" $registry $repo (toString $tag) -}}
{{- end -}}
