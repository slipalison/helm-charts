{{/*
Lista `env` do container do app, em texto, como o Rollout a escreve: a
versao, o nome, a fiacao do OpenTelemetry, o `env` do values (com o que o
preview sobrepoe) e o banco.

Um helper, e nao o bloco escrito dentro do Rollout, porque os workers e o Job
de migracao recebem o mesmo ambiente: com duas copias do bloco, uma variavel
nova entraria em uma e faltaria na outra. Quem precisa da lista como dado (os
workers, para mesclar o `env` proprio pelo nome) le este texto com
`fromYamlArray`; os comentarios somem na leitura e ficam no Rollout.

Parametros, num dict:
  ctx          o contexto raiz (`.`)
  segredoBanco o Secret de onde saem PGUSER, PGPASSWORD, DATABASE_URL e
               ConnectionStrings__Default (no preview, sempre o `banco-app`)
*/}}
{{- define "app.env" -}}
{{- $c := .ctx -}}
{{- $segredo := .segredoBanco -}}
# A versao chega ao app como APP_VERSION, sempre. Sem isto, durante
# um canary nao ha como a propria aplicacao dizer qual versao
# respondeu — e um canary que nao se enxerga nao serve para decidir
# nada. E a versao semantica que a esteira escreve (1.4.0); sem ela,
# a tag da imagem (sha-<commit>).
- name: APP_VERSION
  value: {{ include "app.versao" $c | quote }}
- name: APP_NAME
  value: {{ include "app.name" $c | quote }}
{{- if $c.Values.instrumentation.enabled }}
# Fiacao do OpenTelemetry, escrita aqui e nao injetada por webhook.
#
# Ate 0.1.4 este chart punha a anotacao que mandava o operador do
# OpenTelemetry injetar o agente no pod. O webhook desse operador
# estava com "tls: bad certificate" e failurePolicy: Ignore — o pod
# nascia sem instrumentacao NENHUMA e nada no cluster reclamava. Um
# componente que falha calado e pior do que um componente ausente.
# O operador foi removido do cluster; ver ADR-001.
#
# Sao os nomes padrao do OpenTelemetry: qualquer SDK oficial os le
# sem configuracao. O app so precisa iniciar o SDK — e se nao
# iniciar, estas variaveis nao fazem mal a ninguem.
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ $c.Values.instrumentation.endpoint | quote }}
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: {{ $c.Values.instrumentation.protocol | quote }}
- name: OTEL_SERVICE_NAME
  value: {{ include "app.name" $c | quote }}
# service.version e o que liga um trace a uma versao durante o
# canary; sem ela os dois lados do rollout viram o mesmo servico.
- name: OTEL_RESOURCE_ATTRIBUTES
  value: "service.version={{ include "app.versao" $c }},service.namespace={{ include "app.name" $c }},k8s.namespace.name={{ include "app.name" $c }},deployment.environment={{ include "app.ambiente" $c }}"
{{- end }}
{{- /*
No preview, `preview.env` (um MAPA nome: valor) e `preview.secretEnv` (um
MAPA nome: {secret, key}) sobrepoem o `env` de producao PELO NOME, e
acrescentam o que nao existia. Mapa, e nao lista, porque o Helm SUBSTITUI
listas: um `env:` no values do preview apagaria todas as variaveis de
producao, e o app subiria sem metade da configuracao. Em producao nada disto
roda.
*/}}
{{- $env := $c.Values.env | default list }}
{{- if include "app.emPreview" $c }}
{{- $sobre := include "app.sobreposicoesPreview" $c | fromYaml }}
{{- $saida := list }}
{{- $nomes := list }}
{{- range $env }}
{{- $nomes = append $nomes .name }}
{{- if hasKey $sobre .name }}
{{- $saida = append $saida (get $sobre .name) }}
{{- else }}
{{- $saida = append $saida . }}
{{- end }}
{{- end }}
{{- range $nome := keys $sobre | sortAlpha }}
{{- if not (has $nome $nomes) }}
{{- $saida = append $saida (get $sobre $nome) }}
{{- end }}
{{- end }}
{{- $env = $saida }}
{{- end }}
{{- with $env }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- if $c.Values.database.enabled }}
# Banco. O que o chart JA SABE vai em texto puro: endereco, porta e
# nome do banco nao sao segredo e nao ganham nada em virar Secret.
#
# `-rw` e o Service do primario: num failover ele segue sozinho.
# Apontar para o pod, ou para o `-ro`, e como se descobre tarde que
# o app nao consegue escrever.
- name: PGHOST
  value: {{ include "app.dbHost" $c | quote }}
- name: PGPORT
  value: "5432"
- name: PGDATABASE
  value: {{ include "app.dbName" $c | quote }}
# O CNPG serve TLS. `require` cifra sem conferir quem esta do outro
# lado — os pods do banco ficam fora da malha do Istio (o namespace
# `databases` nao tem istio-injection), entao esta e a unica camada
# que existe aqui. Para `verify-full` seria preciso distribuir o
# `postgres-ca` ao app; ainda nao e o caso.
- name: PGSSLMODE
  value: require
# E o que E segredo vem do Secret <app>-db, NO NAMESPACE DO APP.
#
# Ate o chart 0.3.0 esta linha era `envFrom: secretRef:
# postgres-app` — um Secret do namespace `databases`. Secret nao
# atravessa namespace: o pod pararia em CreateContainerConfigError.
# E `postgres-app` e a credencial unica do usuario `app` do
# bootstrap, comum a todos os apps.
#
# Chave por chave, e nao `envFrom`, por dois motivos: o nome da
# variavel passa a ser escolha do chart, e uma chave que falte
# DERRUBA o pod em vez de sumir calada.
- name: PGUSER
  valueFrom:
    secretKeyRef:
      name: {{ $segredo }}
      key: username
- name: PGPASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $segredo }}
      key: password
{{- if include "app.bancoPreview" $c }}
# Preview: o Secret e o `banco-app` que o CNPG gera para o banco
# efemero, e ele nao traz as duas strings montadas. Elas sao
# montadas aqui, no MESMO formato do `--only pgapp` de producao, com
# a expansao `$(VAR)` do Kubernetes sobre as duas variaveis acima.
# Sem risco de escape: a senha que o CNPG sorteia e so letras e
# numeros (conferido em 2026-09-24, 64 caracteres).
- name: DATABASE_URL
  value: "postgresql://$(PGUSER):$(PGPASSWORD)@{{ include "app.dbHost" $c }}:5432/{{ include "app.dbName" $c }}?sslmode=require"
- name: ConnectionStrings__Default
  value: "Host={{ include "app.dbHost" $c }};Port=5432;Database={{ include "app.dbName" $c }};Username=$(PGUSER);Password=$(PGPASSWORD);SSL Mode=Require;Trust Server Certificate=true"
{{- else }}
# A string montada, nos dois dialetos. Ela e montada no momento de
# selar, e nao aqui, porque a senha e a unica parte que falta e ela
# nunca passa pelo values.
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ $segredo }}
      key: DATABASE_URL
- name: ConnectionStrings__Default
  valueFrom:
    secretKeyRef:
      name: {{ $segredo }}
      key: ConnectionStrings__Default
{{- end }}
{{- end }}
{{- end -}}

{{/*
O que o preview poe no lugar das variaveis de producao, como um MAPA
nome -> item de `env` ja pronto (YAML; quem chama le com `fromYaml`).

  preview.env        nome: valor          -> {name, value}
  preview.secretEnv  nome: {secret, key}  -> {name, valueFrom.secretKeyRef}

`secretEnv` existe para o preview receber CREDENCIAIS PROPRIAS, de teste, em
vez de uma copia do Secret de producao. Sem ele, o preview de um app que le
uma chave de um Secret ou recebia a copia do Secret de producao (o Kyverno
copia para `pr-*` so o que leva o rotulo `preview.alisonamorim.com/copiar`),
ou ficava sem a variavel. Com ele, a variavel de producao some do preview: o
nome do Secret de producao nao aparece no render, e nenhum pod do preview o
referencia. O Secret nomeado aqui precisa existir no namespace do preview; o
caminho e o mesmo rotulo de copia, num Secret SO de teste (README).

Recusas, cada uma com o motivo:
  - o mesmo nome em `env` e em `secretEnv`: um dos dois seria descartado
    calado, e nao se sabe qual a pessoa quis;
  - um nome que o proprio chart escreve (APP_VERSION, OTEL_*, PG*,
    DATABASE_URL...): o container sairia com a variavel duplicada, e o
    servidor de API guarda a ultima sem avisar. A credencial do banco do
    preview ja e a do banco efemero;
  - `secret` ou `key` vazios.
*/}}
{{- define "app.sobreposicoesPreview" -}}
{{- $env := .Values.preview.env | default dict -}}
{{- $segredos := .Values.preview.secretEnv | default dict -}}
{{- $saida := dict -}}
{{- range $nome, $valor := $env -}}
{{- $_ := set $saida $nome (dict "name" $nome "value" (toString $valor)) -}}
{{- end -}}
{{- $doChart := include "app.variaveisDoChart" . | fromYamlArray -}}
{{- range $nome, $ref := $segredos -}}
{{- if hasKey $env $nome -}}
{{- fail (printf "preview: '%s' esta em preview.env e em preview.secretEnv. Escolha um dos dois." $nome) -}}
{{- end -}}
{{- if has $nome $doChart -}}
{{- fail (printf "preview.secretEnv: '%s' e escrita pelo proprio chart e nao pode ser sobreposta." $nome) -}}
{{- end -}}
{{- if not (and (kindIs "map" $ref) $ref.secret $ref.key) -}}
{{- fail (printf "preview.secretEnv.%s precisa de secret e key." $nome) -}}
{{- end -}}
{{- $chave := dict "name" $ref.secret "key" $ref.key -}}
{{- if hasKey $ref "optional" -}}
{{- $_ := set $chave "optional" $ref.optional -}}
{{- end -}}
{{- $_ := set $saida $nome (dict "name" $nome "valueFrom" (dict "secretKeyRef" $chave)) -}}
{{- end -}}
{{- toYaml $saida -}}
{{- end -}}

{{/*
As variaveis que o chart escreve sozinho. Nenhuma sobreposicao (o
`preview.secretEnv`, o `env` de um worker ou do Job de migracao) pode
nomea-las: o resultado seria uma variavel duplicada no container.
*/}}
{{- define "app.variaveisDoChart" -}}
{{- toYaml (list "APP_VERSION" "APP_NAME" "OTEL_EXPORTER_OTLP_ENDPOINT" "OTEL_EXPORTER_OTLP_PROTOCOL" "OTEL_SERVICE_NAME" "OTEL_RESOURCE_ATTRIBUTES" "PGHOST" "PGPORT" "PGDATABASE" "PGSSLMODE" "PGUSER" "PGPASSWORD" "DATABASE_URL" "ConnectionStrings__Default") -}}
{{- end -}}
