{{/*
AMBIENTE DE PREVIEW: "sim" quando `preview.numero` veio preenchido, vazio em
producao. Quem preenche e o ApplicationSet `previews` do homelab-gitops, a
partir do pull request; ninguem escreve isto a mao.

Tudo o que muda no preview passa por este helper, e so por ele. Sem o bloco, o
render de todo app sai byte a byte igual ao de antes de o preview existir — e e
isso que o CI deste repositorio confere.
*/}}
{{- define "app.emPreview" -}}
{{- if and .Values.preview .Values.preview.numero -}}
{{- if not (regexMatch "^[0-9]+$" (toString .Values.preview.numero)) -}}
{{- fail (printf "preview.numero: '%v' nao e o numero de um pull request." .Values.preview.numero) -}}
{{- end -}}
sim
{{- end -}}
{{- end -}}

{{/*
Nome do app. Tudo neste chart deriva daqui: namespace, Service, Rollout, host.

No preview e `pr-<numero>-<name>`. O prefixo nao e enfeite: o gateway e o
Cloudflare Access protegem os previews por `pr-*`, e o Istio so casa host por
prefixo ou sufixo. E o ApplicationSet calcula o MESMO nome para o namespace de
destino — por isso aqui ele FALHA em vez de truncar: truncado, o namespace do
chart e o do Application divergiriam.
*/}}
{{- define "app.name" -}}
{{- if include "app.emPreview" . -}}
{{- $nome := printf "pr-%v-%s" .Values.preview.numero .Values.name -}}
{{- if gt (len $nome) 40 -}}
{{- fail (printf "preview: '%s' passa de 40 caracteres, o teto de nome deste chart. Encurte o nome do app (sobram 32 depois de pr-NNNN-)." $nome) -}}
{{- end -}}
{{- $nome -}}
{{- else -}}
{{- .Values.name | trunc 40 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Host publico. No preview ele SEMPRE sai do nome, e `host` do values e
ignorado: o values do preview e o de producao, e respeitar o `host` dali poria
um VirtualService do preview disputando o host de producao no mesmo gateway.
*/}}
{{- define "app.host" -}}
{{- if include "app.emPreview" . -}}
{{- printf "%s.alisonamorim.com" (include "app.name" .) -}}
{{- else if .Values.host -}}
{{- .Values.host -}}
{{- else -}}
{{- printf "%s.alisonamorim.com" (include "app.name" .) -}}
{{- end -}}
{{- end -}}

{{/*
Tag da imagem. No preview e a que a esteira publica no pull request,
`pr-<numero>-<7 do head>` (build-push.yml do github-workflows). O formato e
conferido: um preview nao roda imagem de producao, nem de outro PR.
*/}}
{{- define "app.tag" -}}
{{- if include "app.emPreview" . -}}
{{- $tag := required "preview.tag e obrigatorio no preview - o ApplicationSet previews escreve pr-<numero>-<head>" .Values.preview.tag -}}
{{- if not (regexMatch (printf "^pr-%v-[0-9a-f]{7}$" .Values.preview.numero) $tag) -}}
{{- fail (printf "preview.tag: '%s' nao e pr-%v-<7 do head>." $tag .Values.preview.numero) -}}
{{- end -}}
{{- $tag -}}
{{- else -}}
{{- required "image.tag e obrigatorio - o CI escreve este valor a cada build" .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{/*
Versao que o app anuncia (APP_VERSION, service.version, rotulo). No preview e a
tag do PR: a `versao` do values e a de producao, e anuncia-la faria o preview
se dizer a versao que esta no ar.
*/}}
{{- define "app.versao" -}}
{{- if include "app.emPreview" . -}}
{{- include "app.tag" . -}}
{{- else -}}
{{- .Values.versao | default .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{/*
Replicas e canary. Preview e uma replica sem canary: ele existe para validar
funcionalidade, nao o rollout — e cada replica a mais e memoria de um cluster
que ja roda a ~55%.
*/}}
{{- define "app.replicas" -}}
{{- if include "app.emPreview" . -}}1{{- else -}}{{ .Values.replicas }}{{- end -}}
{{- end -}}

{{- define "app.canary" -}}
{{- if and .Values.canary.enabled (not (include "app.emPreview" .)) -}}sim{{- end -}}
{{- end -}}

{{- define "app.ambiente" -}}
{{- if include "app.emPreview" . -}}preview{{- else -}}{{ .Values.instrumentation.environment }}{{- end -}}
{{- end -}}

{{/*
Banco efemero do preview: um Cluster do CNPG DENTRO do namespace do preview,
que morre com ele. Nunca o banco compartilhado de producao.
*/}}
{{- define "app.bancoPreview" -}}
{{- if and .Values.database.enabled (include "app.emPreview" .) -}}sim{{- end -}}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ include "app.versao" . | default "sem-tag" | quote }}
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
{{- if include "app.bancoPreview" . -}}
banco-app
{{- else -}}
{{- printf "%s-db" (include "app.name" .) -}}
{{- end -}}
{{- end -}}

{{/*
Nome do banco. Sai do values, mas o padrao e o nome do app.
*/}}
{{- define "app.dbName" -}}
{{- .Values.database.name | default (include "app.nomeBase" .) -}}
{{- end -}}

{{/*
O nome de PRODUCAO do app, sem o prefixo do preview. E o nome do banco e da
role, nos dois ambientes: o banco efemero do preview se chama igual ao de
producao, para o app que tem o nome escrito em algum lugar funcionar igual.
Em producao e identico a `app.name`.
*/}}
{{- define "app.nomeBase" -}}
{{- .Values.name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{/*
Host do banco dentro do cluster. `-rw` e o Service que o CNPG aponta para o
primario; num failover ele segue o primario novo sozinho. Usar o nome do pod ou
o `-ro` aqui e como o app descobre, tarde, que nao consegue escrever.
*/}}
{{- define "app.dbHost" -}}
{{- if include "app.bancoPreview" . -}}
{{- printf "banco-rw.%s.svc.cluster.local" (include "app.name" .) -}}
{{- else -}}
{{- printf "%s-rw.%s.svc.cluster.local" .Values.database.cluster .Values.database.clusterNamespace -}}
{{- end -}}
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
