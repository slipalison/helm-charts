{{/*
Nome do app. Tudo neste chart deriva daqui: namespace, Service, Rollout, host.
*/}}
{{- define "app.name" -}}
{{- .Values.name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.host" -}}
{{- if .Values.host -}}
{{- .Values.host -}}
{{- else -}}
{{- printf "%s.alisonamorim.com" (include "app.name" .) -}}
{{- end -}}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.image.tag | default "sem-tag" | quote }}
owner: {{ .Values.owner }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app: {{ include "app.name" . }}
{{- end -}}
