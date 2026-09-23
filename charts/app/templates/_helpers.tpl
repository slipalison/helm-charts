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
app.kubernetes.io/version: {{ .Values.versao | default .Values.image.tag | default "sem-tag" | quote }}
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

{{/*
Nome do Secret com a credencial do banco. O MESMO nome nos dois namespaces:
em `databases` ele alimenta o DatabaseRole, no namespace do app ele alimenta o
Rollout. Sao dois SealedSecrets distintos — um blob selado para um namespace
nao decifra em outro, e essa e a protecao — com a mesma senha dentro.
*/}}
{{- define "app.dbSecret" -}}
{{- printf "%s-db" (include "app.name" .) -}}
{{- end -}}

{{/*
Nome do banco. Sai do values, mas o padrao e o nome do app.
*/}}
{{- define "app.dbName" -}}
{{- .Values.database.name | default (include "app.name" .) -}}
{{- end -}}

{{/*
Host do banco dentro do cluster. `-rw` e o Service que o CNPG aponta para o
primario; num failover ele segue o primario novo sozinho. Usar o nome do pod ou
o `-ro` aqui e como o app descobre, tarde, que nao consegue escrever.
*/}}
{{- define "app.dbHost" -}}
{{- printf "%s-rw.%s.svc.cluster.local" .Values.database.cluster .Values.database.clusterNamespace -}}
{{- end -}}

{{/*
Porta das duas sondas. Sem `probes.port` no values, e `port` — a mesma do
trafego, que e o caso de quase todo app, e o render sai byte a byte igual ao
de antes deste campo existir.

Existe para o app que serve as sondas num listener INTERNO, fora da porta que
o gateway alcanca. O basalto, desde a fase `borda-e-casca`: `/healthz`,
`/readyz` e `/metrics` so respondem na 9090, e a 8080 devolve 404 para as tres.
Sondar a 8080 nesse app daria um pod que nunca fica pronto.

Um helper, e nao a expressao repetida nas duas sondas: readiness e liveness
apontando para portas diferentes e o tipo de divergencia que ninguem ve ate o
pod ser morto pela sonda errada.
*/}}
{{- define "app.probePort" -}}
{{- .Values.probes.port | default .Values.port -}}
{{- end -}}
