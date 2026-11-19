{{/*
Helpers dos workloads que nao sao o Rollout: os workers e o Job de migracao.
*/}}

{{/*
Recusa no render o container sem os tres campos de recursos que o Kyverno
exige (`exige-requests-e-limits`). A politica olha o POD, e nao o Deployment
ou o Job: sem esta recusa o apply sai verde e o pod e que e barrado ao nascer,
com o motivo escondido nos eventos do ReplicaSet ou do Job.

Parametros, num dict: `onde` (o caminho no values, para a mensagem) e
`recursos` (o bloco resources efetivo).
*/}}
{{- define "app.exigeRecursos" -}}
{{- $r := .recursos | default dict -}}
{{- $req := $r.requests | default dict -}}
{{- $lim := $r.limits | default dict -}}
{{- if not (and $req.cpu $req.memory $lim.memory) -}}
{{- fail (printf "%s.resources: faltam requests.cpu, requests.memory ou limits.memory. O Kyverno exige os tres em todo container, e a recusa e no pod: o apply sairia verde e o pod nunca nasceria." .onde) -}}
{{- end -}}
{{- end -}}

{{/*
O `env` de um workload que nao e o Rollout: a lista BASE (o texto do helper
`app.env`) com o `env` PROPRIO do workload por cima, pelo nome. Devolve YAML;
quem chama le com `fromYamlArray`.

  - nome do proprio que existe na base: substitui, no mesmo lugar;
  - nome novo: entra no fim, na ordem em que foi escrito;
  - no preview, se o nome tambem esta em `preview.env`/`preview.secretEnv`, o
    preview ganha: o `env` proprio e de producao, e o ponto do preview e nao
    herdar o que e de producao;
  - nome que o chart escreve (APP_VERSION, OTEL_*, PG*, DATABASE_URL...) e
    recusado: a credencial do banco de um workload muda pelo `database.secret`
    dele, que no preview da lugar ao banco efemero. Uma DATABASE_URL escrita a
    mao levaria a credencial de producao para o preview.

Parametros, num dict: `ctx`, `onde` (para a mensagem), `base` (texto) e
`proprio` (a lista).
*/}}
{{- define "app.envComProprio" -}}
{{- $c := .ctx -}}
{{- $onde := .onde -}}
{{- $base := .base | fromYamlArray -}}
{{- $sobre := dict -}}
{{- if include "app.emPreview" $c -}}
{{- $sobre = include "app.sobreposicoesPreview" $c | fromYaml -}}
{{- end -}}
{{- $doChart := include "app.variaveisDoChart" $c | fromYamlArray -}}
{{- $proprio := dict -}}
{{- $ordem := list -}}
{{- range .proprio -}}
{{- if not (and (kindIs "map" .) .name) -}}
{{- fail (printf "%s.env: todo item precisa de name." $onde) -}}
{{- end -}}
{{- if has .name $doChart -}}
{{- fail (printf "%s.env: '%s' e escrita pelo proprio chart. A credencial do banco muda por %s.database.secret." $onde .name $onde) -}}
{{- end -}}
{{- if hasKey $proprio .name -}}
{{- fail (printf "%s.env: '%s' aparece duas vezes." $onde .name) -}}
{{- end -}}
{{- if hasKey $sobre .name -}}
{{- $_ := set $proprio .name (get $sobre .name) -}}
{{- else -}}
{{- $_ := set $proprio .name . -}}
{{- end -}}
{{- $ordem = append $ordem .name -}}
{{- end -}}
{{- $saida := list -}}
{{- $vistos := list -}}
{{- range $base -}}
{{- $vistos = append $vistos .name -}}
{{- if hasKey $proprio .name -}}
{{- $saida = append $saida (get $proprio .name) -}}
{{- else -}}
{{- $saida = append $saida . -}}
{{- end -}}
{{- end -}}
{{- range $ordem -}}
{{- if not (has . $vistos) -}}
{{- $saida = append $saida (get $proprio .) -}}
{{- end -}}
{{- end -}}
{{- toYaml $saida -}}
{{- end -}}

{{/*
Os componentes que falam com o banco alem do app: o nome de cada worker, e
`migration` com o Job de migracao ligado. No
preview, a NetworkPolicy do banco efemero (`-banco`) deixa entrar estes pods
pela 5432, alem dos do app. Devolve YAML (lista); vazio quando nao ha nenhum.
*/}}
{{- define "app.componentesComBanco" -}}
{{- $lista := list -}}
{{- range $nome, $w := .Values.workers -}}
{{- if $w -}}
{{- $lista = append $lista $nome -}}
{{- end -}}
{{- end -}}
{{- if include "app.migracao" . -}}
{{- $lista = append $lista "migration" -}}
{{- end -}}
{{- toYaml $lista -}}
{{- end -}}

{{/*
"sim" com o Job de migracao ligado.
*/}}
{{- define "app.migracao" -}}
{{- if and .Values.migration .Values.migration.enabled -}}sim{{- end -}}
{{- end -}}

{{/*
A ONDA do Rollout e dos workers no preview com Job de migracao.

Em producao o Job e um gancho PreSync: o Argo CD o roda e espera terminar
antes de aplicar qualquer outra coisa, e o Rollout nao precisa de onda. No
preview isso nao serve: o namespace e o banco efemero nascem NO MESMO sync
(ondas -2 e -1), e um PreSync rodaria antes de os dois existirem. Ali o Job e
um gancho Sync na onda 1, depois da NetworkPolicy e da ServiceAccount (onda
0), e o app e os workers vao para a onda 2: so sobem com o esquema migrado.

Vazio em producao e sem migracao: o render nao muda.
*/}}
{{- define "app.ondaDosWorkloads" -}}
{{- if and (include "app.migracao" .) (include "app.emPreview" .) -}}
argocd.argoproj.io/sync-wave: "2"
{{- end -}}
{{- end -}}

{{/*
Os Secrets que os pods do app leem, como os pods SAEM do render, e nao como o
values os descreve: um nome montado por template, ou uma variavel que so um
worker tem, aparece aqui igual. Quem usa: a lista de Secrets permitidos do
preview (preview-secrets.yaml) e a recusa do Secret da migracao no app e nos
workers (migration.yaml).

Le, em todo container e initContainer, o `env` (`secretKeyRef`) e o `envFrom`
(`secretRef`), e os volumes do pod (`secret` e `projected`). Nao le
`imagePullSecrets`: quem le o pull secret e o kubelet, e nao o processo do app.
A anotacao `sidecar.istio.io/userVolume` monta volume no sidecar, num JSON que
o chart nao confere; ela sai a parte, com o texto, para quem chama decidir.

Parametros, num dict: `ctx` (o contexto raiz) e `arquivos` (os templates a
ler, como "rollout.yaml"). Devolve YAML, um mapa:
  refs        lista de {onde, secret, caminho}: `onde` e Kind/nome do objeto,
              `caminho` e "env NOME", "envFrom" ou "volume NOME"
  userVolume  lista de {onde, valor}
*/}}
{{- define "app.secretsDosPods" -}}
{{- $ctx := .ctx -}}
{{- $refs := list -}}
{{- $userVolume := list -}}
{{- range $arq := .arquivos -}}
{{- $texto := include (printf "%s/%s" $ctx.Template.BasePath $arq) $ctx -}}
{{- range $doc := regexSplit "(?m)^---[ \t]*$" $texto -1 -}}
{{- $o := fromYaml $doc -}}
{{- $pod := dig "spec" "template" "spec" dict $o -}}
{{- if $pod -}}
{{- $onde := printf "%s/%s" (dig "kind" "?" $o) (dig "metadata" "name" "?" $o) -}}
{{- range $c := concat (dig "containers" list $pod) (dig "initContainers" list $pod) -}}
{{- range $e := dig "env" list $c -}}
{{- with dig "valueFrom" "secretKeyRef" "name" "" $e -}}
{{- $refs = append $refs (dict "onde" $onde "secret" . "caminho" (printf "env %s" $e.name)) -}}
{{- end -}}
{{- end -}}
{{- range $e := dig "envFrom" list $c -}}
{{- with dig "secretRef" "name" "" $e -}}
{{- $refs = append $refs (dict "onde" $onde "secret" . "caminho" "envFrom") -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $v := dig "volumes" list $pod -}}
{{- with dig "secret" "secretName" "" $v -}}
{{- $refs = append $refs (dict "onde" $onde "secret" . "caminho" (printf "volume %s" $v.name)) -}}
{{- end -}}
{{- range $s := dig "projected" "sources" list $v -}}
{{- with dig "secret" "name" "" $s -}}
{{- $refs = append $refs (dict "onde" $onde "secret" . "caminho" (printf "volume %s" $v.name)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $anotacoes := dig "spec" "template" "metadata" "annotations" dict $o -}}
{{- if hasKey $anotacoes "sidecar.istio.io/userVolume" -}}
{{- $userVolume = append $userVolume (dict "onde" $onde "valor" (get $anotacoes "sidecar.istio.io/userVolume" | toString)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml (dict "refs" $refs "userVolume" $userVolume) -}}
{{- end -}}
