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

{{/*
Chaves que sumiram, e que nao podem sumir em silencio.

Um values que ainda traz `instrumentation.language` foi escrito para a versao
em que este chart pedia a injecao por webhook do operador do OpenTelemetry.
Esse operador nao existe mais no cluster (ADR-001). Sem esta checagem o valor
seria simplesmente IGNORADO na renderizacao — o deploy passaria verde e o app
ficaria sem telemetria, que e exatamente o modo de falha que a remocao do
operador veio consertar. Entao aqui o render PARA.
*/}}
{{- define "app.valoresAposentados" -}}
{{- if .Values.instrumentation -}}
{{- if hasKey .Values.instrumentation "language" -}}
{{- fail "instrumentation.language foi removido no chart app 0.2.0. O operador do OpenTelemetry saiu do cluster (webhook com certificado invalido e failurePolicy: Ignore: injetava nada, calado). Agora o chart escreve OTEL_EXPORTER_OTLP_ENDPOINT/OTEL_SERVICE_NAME/OTEL_RESOURCE_ATTRIBUTES no container e o SDK roda DENTRO do app. Tire a chave 'language' do values e inicie o SDK da linguagem. Ver helm-charts/charts/app/README.md." -}}
{{- end -}}
{{- end -}}
{{- end -}}
