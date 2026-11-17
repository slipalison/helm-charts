# helm-charts

Charts reutilizaveis do homelab. Publicados como OCI em
`oci://ghcr.io/slipalison/charts` a cada tag `v*`.

## `app`

O caminho dourado para publicar um servico. Um `values.yaml` de vinte linhas
produz:

| O que | Por que vem junto |
|---|---|
| `Namespace` com `istio-injection` e Pod Security `restricted` | Os rotulos precisam existir antes do primeiro pod; depois nao adianta |
| `Rollout` canary com analise por metrica | Um canary sem analise e so uma pausa antes do mesmo erro |
| `Service`, `VirtualService`, `DestinationRule` | Publica em `<nome>.alisonamorim.com` pelo gateway unico |
| `AnalysisTemplate` consultando o Mimir | Aborta sozinho se a taxa de sucesso cair abaixo de 99% |
| `NetworkPolicy` default-deny | Todo destino precisa ser declarado, inclusive os que funcionavam antes |
| `AuthorizationPolicy` so-pelo-gateway | mTLS diz quem e; isto diz o que pode |
| `PodDisruptionBudget` | Uma drenagem de no nao leva as duas replicas juntas |
| `Database` do CloudNativePG | Banco, usuario e Secret criados com o app |
| `Deployment` por worker, opcional | O mesmo binario em outro papel, com os cuidados do app e nenhuma porta de entrada |
| `Job` de migracao, opcional | O esquema muda num gancho do Argo CD, com um Secret que nao e o do app; o app so fica sem DDL quando a credencial dele for de uma role sem DDL |
| Variaveis `OTEL_*` apontando para o Alloy | O SDK do app acha o coletor sozinho, sem configuracao |

### Usar

```yaml
# no repositorio homelab-gitops, em apps/<nome>/values.yaml
name: meu-app
owner: alison
image:
  repository: ghcr.io/slipalison/meu-app
  tag: ""          # escrita pelo CI
port: 8080
```

O `ApplicationSet` do `homelab-gitops` encontra o diretorio e cria o
Application sozinho. Nao ha passo manual.

### Registry privado

Repositorio privado no GitHub gera **pacote privado no GHCR**. O cluster nao
tem conta no GitHub, entao o `kubelet` recebe `denied` e o pod fica em
`ImagePullBackOff` — com uma mensagem que parece dizer que a imagem nao existe.

```yaml
image:
  repository: ghcr.io/slipalison/meu-app
  pullSecret: ghcr-pull     # nome do Secret, no namespace do app
```

O Secret nasce de um SealedSecret junto do app, e **nao** do chart: o chart e
publico, e um blob selado so decifra no namespace para o qual foi selado — a
mesma razao da credencial do banco.

```bash
# no pve, com um PAT de escopo `read:packages` E SO ELE
kubectl create secret docker-registry ghcr-pull \
  --namespace meu-app \
  --docker-server=ghcr.io \
  --docker-username=slipalison \
  --docker-password="$PAT" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --controller-namespace kube-system \
> homelab-gitops/apps/meu-app/ghcr-pull.yaml
```

O `--namespace` importa duas vezes: ele decide onde o Secret nasce **e** entra
no selo. Selar para o namespace errado produz um arquivo que aplica sem erro e
nunca vira Secret.

A alternativa e tornar o pacote publico (Packages > Package settings >
Change visibility), e ai `pullSecret` fica vazio. Troca conhecida: some a
credencial para rotacionar, e a imagem passa a ser legivel por qualquer um —
inclusive o binario de um repositorio que se escolheu manter privado.

### Sondas num listener interno

Por padrao as duas sondas batem em `port`, a mesma porta do trafego. O app que
serve `/healthz` e `/readyz` num listener **interno** — fora da porta que o
gateway alcanca — diz qual e:

```yaml
port: 8080          # o que a internet alcanca
probes:
  port: 9090        # so as sondas
podAnnotations:
  prometheus.io/port: "9090"   # se /metrics mora no mesmo listener interno
```

Sem `probes.port`, o render sai **identico** ao de antes do campo existir —
nenhum outro app muda.

A raspagem da porta interna **nao passa pela NetworkPolicy**. Com
`enablePrometheusMerge` (padrao do Istio, e o `istiod` deste cluster nao o
desliga), o injetor reescreve a anotacao do pod para o endpoint mesclado do
sidecar, 15020, que e a porta que a regra do `observability` libera; e o
proprio sidecar busca a porta interna por `localhost`, dentro do pod. As
sondas seguem o mesmo caminho: o Istio as reescreve para a 15020 e o agente
chama a porta interna localmente. Sem sidecar a porta interna nao seria
raspada — e o chart so publica app com sidecar (`namespace.yaml` liga
`istio-injection`).

### Banco de dados

`database.enabled: true` declara, no namespace do Cluster, **uma role e um
banco só daquele app** — e liga o pod à credencial certa:

```yaml
database:
  enabled: true
  name: ""              # vazio = nome do app
  connectionLimit: 20   # o cluster inteiro tem max_connections: 100
```

O pod recebe `PGHOST`, `PGPORT`, `PGDATABASE` e `PGSSLMODE` em texto puro — o
chart já sabe esses valores, e eles não ganham nada em virar Secret — mais
`PGUSER`, `PGPASSWORD`, `DATABASE_URL` e `ConnectionStrings__Default` vindos do
Secret `<app>-db`, **do próprio namespace**. Com `database.secret`, o pod lê
outro Secret, no mesmo formato, e o `<app>-db` fica só para a role do app (é o
caso do app com Job de migração, mais abaixo).

Não basta o `enabled: true`. A senha precisa existir selada nos dois lados, e
quem faz isso é um comando só, que a sorteia e nunca a mostra:

```bash
setup-k8s-platform.sh --only pgapp --pg-app meu-app
```

O nome da role **não sai do values**: é sempre o nome do app. Se saísse, um
`database.name: postgres` distraído — ou um pull request de terceiro —
declararia uma role chamada `postgres` com senha conhecida, e o operador
aplicaria `ALTER ROLE` no superusuário do cluster.

#### O que estava errado antes do 0.4.0

Este caminho existia desde o 0.1.x e **nunca funcionou**. Ninguém percebeu
porque `database.enabled` era `false` nos dois apps: um caminho que nunca
rodou não está certo, está por testar. Eram três defeitos empilhados, todos
medidos no cluster:

| O que o chart fazia | O que acontecia |
|---|---|
| `Database` com `owner: <app>` | O CRD **não cria role** — "Maps to the `OWNER` parameter of `CREATE DATABASE`". Sem a role, `ERROR: role "<app>" does not exist` (SQLSTATE 42704) |
| `envFrom: secretRef: postgres-app` | `postgres-app` vive em `databases`; o Rollout nasce no namespace do app. Secret não atravessa namespace: `CreateContainerConfigError` |
| ...e mesmo que atravessasse | `postgres-app` é a credencial única do usuário `app` do bootstrap, comum a todos — sem isolamento nenhum |

O `Database` agora vem acompanhado de um `DatabaseRole`, que é o CRD que
realmente cria a role, com `superuser`, `createdb`, `createrole`, `bypassrls`
e `replication` fixos em `false`.

Os dois objetos usam `retain`: apagar o diretório do app em `apps/` faz o
ArgoCD podar os CRs, e `delete` mandaria o operador executar `DROP DATABASE`.
Um diretório removido por engano não apaga dado.

Uma ressalva honesta: `argocd.argoproj.io/sync-wave` no `Database` ordena o
*apply*, não a *aplicação em Postgres* — o ArgoCD trata CR desconhecido como
saudável na hora. Quem garante a ordem é o próprio CNPG, que reprocessa: o
banco falha uma vez com "role does not exist" e nasce na tentativa seguinte,
medido em ~20 s.

### Preview: um ambiente por pull request

O mesmo chart, com um bloco a mais. Quem preenche o bloco e o ApplicationSet
`previews` do `homelab-gitops`, a partir do pull request — nunca a mao:

```yaml
preview:
  numero: "42"            # o ApplicationSet escreve
  tag: pr-42-abcdef0      # o ApplicationSet escreve; a esteira publica
  env:                    # opcional, no apps/<app>/preview.yaml do gitops
    AUTH0_CLIENT_ID: <cliente de teste>
```

Com `numero` vazio o chart e o de producao, e o render sai **byte a byte
igual** ao de antes deste bloco existir — conferido em `basalto`, `demo-python`,
`whoami` e num exemplo com banco e HPA, na versao 0.6.0 contra a nova. Com
`numero`, muda isto e so isto:

| | Producao | Preview |
|---|---|---|
| Nome, namespace | `name` | `pr-<numero>-<name>` — falha acima de 40 caracteres, em vez de truncar |
| Host | `host`, ou `<name>.alisonamorim.com` | sempre `pr-<numero>-<name>.alisonamorim.com`; o `host` do values e ignorado, senao o preview disputaria o host de producao no gateway |
| Imagem e versao | `image.tag`, `versao` | `preview.tag`, que precisa ser `pr-<numero>-<7 hex>` |
| Replicas | `replicas`, canary, HPA, PDB | 1, troca direta, sem HPA, sem PDB |
| Banco | `Database` + `DatabaseRole` no cluster compartilhado | um `Cluster` do CNPG **dentro do namespace**, que morre com ele; o namespace nao ganha `db-access`, entao o banco de producao fica fora de alcance de rede |
| `env` | a lista | a lista, com `preview.env` e `preview.secretEnv` sobrepondo **pelo nome** |
| Telemetria | `deployment.environment=producao` | `preview`, e o `service.name` e o do preview |

O banco efemero sai com o nome do banco e o dono de producao, credencial no
Secret `banco-app` que o CNPG gera, e `DATABASE_URL` /
`ConnectionStrings__Default` montadas no mesmo formato do `--only pgapp`. Os
pods dele ficam fora do mesh (com sidecar, o Job do initdb nao termina) e fora
da NetworkPolicy padrao — a deles e a `-banco`, espelho da de `databases`.

`preview.env` e um mapa, e nao uma lista, porque o Helm substitui listas: um
`env:` no values do preview apagaria as variaveis de producao.

#### Credenciais proprias do preview: `preview.secretEnv`

`preview.env` so aceita valor em texto. Para a variavel que em producao vem de
um Secret (uma chave de API, uma credencial de servico), o preview tinha duas
saidas, e as duas sao ruins: receber uma **copia do Secret de producao** (o
Kyverno copia para `pr-*` o Secret marcado com
`preview.alisonamorim.com/copiar: "true"`) — e o codigo de um PR passa a ler a
credencial real — ou ficar sem a variavel, e o que depende dela nao se valida
no preview.

`preview.secretEnv` e a terceira: um mapa `nome: {secret, key}` que, **so no
preview**, troca a variavel de mesmo nome por um `secretKeyRef` para um Secret
do preview, com credenciais de teste.

```yaml
# apps/<app>/preview.yaml do homelab-gitops
preview:
  secretEnv:
    CHAVE_DA_API:
      secret: meu-app-preview   # Secret so de teste
      key: CHAVE_DA_API
      optional: false           # opcional
```

- A variavel coberta **some** do preview na forma de producao: o nome do Secret
  de producao nao aparece no render, e nenhum pod do preview o referencia. O CI
  confere.
- Nome que nao existia em producao entra, como no `preview.env`.
- Em producao o bloco nao muda uma linha.
- Recusa no render: o mesmo nome em `preview.env` e em `preview.secretEnv`, um
  nome que o proprio chart escreve (`APP_VERSION`, `OTEL_*`, `PG*`,
  `DATABASE_URL`, `ConnectionStrings__Default`) e `secret`/`key` ausentes.

**De onde vem o Secret do preview.** O chart nao o cria, pelo mesmo motivo do
pull secret: um SealedSecret so decifra no namespace para o qual foi selado, e
o namespace do preview nasce a cada PR. O caminho e um Secret **so de teste**,
selado para o namespace de producao do app, com o rotulo de copia:

```yaml
# SealedSecret em apps/<app>/ (ou onde o app guarda os seus), namespace <app>
spec:
  template:
    metadata:
      name: meu-app-preview
      labels:
        preview.alisonamorim.com/copiar: "true"
```

O Kyverno o copia para cada `pr-*` quando o namespace nasce. O Secret de
producao continua **sem** o rotulo, e por isso nunca chega ao preview. A copia
e tirada uma vez (`synchronize: false`): trocar a credencial de teste vale para
os previews novos; um aberto precisa renascer.

O desenho inteiro, com o que o app precisa ter para entrar, esta em
`distros-setup/proxmox/PLANO-PREVIEW.md`.

### Workers: o mesmo binario, outro papel

`workers` declara Deployments extras com a **mesma imagem** do app e
`command`/`args` proprios — o processo que consome uma fila, por exemplo. Cada
chave e um worker, e o Deployment se chama `<name>-<chave>`. Mapa, e nao lista,
pelo mesmo motivo do `preview.env`: o values do preview muda um campo de um
worker sem reescrever os outros.

```yaml
probes:
  port: 9090              # o worker sonda a mesma porta interna do app
workers:
  fila:
    args: ["worker"]      # obrigatorio: command ou args
    replicas: 1           # padrao 1; no preview, sempre 1
    resources:            # padrao: os do app
      requests: {cpu: 10m, memory: 32Mi}
      limits: {memory: 128Mi}
    env:                  # por cima do env do app, pelo nome
      - name: PAPEL
        value: fila
    database:
      secret: meu-app-fila-db   # credencial propria; padrao a do app
```

| O worker herda do app | Por que |
|---|---|
| imagem e tag (no preview, a do PR), pull secret, ServiceAccount | E o mesmo binario; uma tag a parte deixaria o worker numa versao e o app em outra |
| `securityContext` (nao-root, rootfs somente leitura, sem capability), `/tmp` em memoria | Os mesmos cuidados do Rollout, e o Kyverno recusa o pod sem eles |
| o `env` inteiro: versao, OpenTelemetry, `env`, `preview.env`/`preview.secretEnv` e o banco | Uma variavel nova no app chega ao worker sem segunda edicao. O `env` do worker entra por cima, pelo nome; no preview, a sobreposicao do preview ganha dele |
| a NetworkPolicy do namespace e o sidecar | O mesmo fechamento de rede e de saida |
| `probes` e `podAnnotations`, com o que o worker sobrepoe | A raspagem por anotacao segue funcionando |

O que ele **nao** tem: Service, rota, canary, HPA. Nenhum Service seleciona o
pod (o rotulo `app` dele e `<name>-<chave>`), e a AuthorizationPolicy
`<name>-<chave>-sem-entrada` so deixa passar as portas do sidecar — sem ela,
um workload sem politica aceita tudo o que a NetworkPolicy deixar chegar. A
porta declarada no container e so a das sondas e das metricas.

No preview, a credencial do banco e sempre a do banco efemero (`banco-app`), e
a NetworkPolicy `-banco` deixa os workers entrarem pela 5432.

Recusa no render: worker sem `command` nem `args` (rodaria o app de novo),
recursos sem `requests.cpu`, `requests.memory` e `limits.memory` (o Kyverno
recusaria o pod, com o apply verde), um `env` que nomeia variavel do chart
(`DATABASE_URL` inclusive: a credencial muda por `database.secret`, que no
preview da lugar ao banco efemero) e o nome `migration`, que e do Job de
migracao.

### Job de migracao: o esquema muda com credencial propria

`migration` declara um Job que roda a migracao do banco com uma credencial
**so dele** — a da role dona do esquema —, que nao chega a pod nenhum do app.

O que o chart garante, e so isto: o Job, o app e cada worker leem Secrets de
**nomes diferentes**, e o render recusa o mesmo Secret no Job e no app (ou num
worker). O que o chart **nao** garante: que o app fique sem DDL. Sem
`database.secret`, o app le o `<app>-db`, que e a senha da role `<app>` — a
dona do banco que o proprio chart declara. O app so fica sem DDL quando
`database.secret` aponta para a credencial de uma role sem DDL, e essa role e
os `GRANT` dela nascem fora do chart (na plataforma do banco, ou na propria
migracao).

```yaml
database:
  enabled: true           # obrigatorio
  secret: meu-app-api-db  # o Secret do app em producao; vazio = <app>-db (a role dona)
migration:
  enabled: true
  args: ["migrate"]       # obrigatorio: command ou args
  database:
    secret: meu-app-dono-db   # obrigatorio em producao; ignorado no preview
  resources: {}           # vazio = os do app
  env: []                 # por cima do que o chart escreve, pelo nome
  backoffLimit: 0         # quem tenta de novo e o retry do sync
  activeDeadlineSeconds: 600
```

O Secret de `migration.database.secret` (e o de `database.secret`) fica no
namespace do app, no mesmo formato do `<app>-db` (`username`, `password`,
`DATABASE_URL`, `ConnectionStrings__Default`), e nasce de um SealedSecret, como
ele. O chart nao cria a role dona nem a role do app: as duas sao da plataforma
do banco.

| | Producao | Preview |
|---|---|---|
| Gancho do Argo CD | `PreSync`: roda e termina antes de qualquer outro objeto do sync; se falha, o sync para e a imagem nova nao sobe | `Sync`, onda 1; o Rollout e os workers vao para a onda 2 |
| Por que diferente | — | O namespace (onda -2) e o banco efemero (onda -1) nascem no mesmo sync, e um `PreSync` rodaria antes de os dois existirem |
| Credencial | `migration.database.secret` | `banco-app`, a do banco efemero |
| Job anterior | `BeforeHookCreation`: apagado quando o proximo nasce; o ultimo fica, com o log | igual |

O Job recebe a versao, a fiacao do OpenTelemetry, o endereco do banco, a
credencial e `migration.env` — e **nao** recebe o `env` nem o `envFrom` do app:
as chaves e credenciais do app nao tem o que fazer numa migracao. Fica na
malha, com o sidecar **nativo** (`sidecar.istio.io/nativeSidecar: "true"`):
o proxy sai quando o container termina. Sem sidecar nativo o Envoy seguiria de
pe e o Job so acabaria no `activeDeadlineSeconds`, como falha. Uma
AuthorizationPolicy `<name>-migration-sem-entrada` fecha a entrada, e no
preview a NetworkPolicy `-banco` deixa o Job entrar pela 5432.

Duas ressalvas, ditas de proposito:

- **No primeiro sync de um app novo, o `PreSync` nao tem onde rodar**: o
  namespace e do chart e so nasce na fase Sync, e o sync para no gancho antes
  de chegar la — o retry repete a mesma falha. Ligue `migration` num app que
  ja sincronizou uma vez. O preview nao tem esse problema, pelo gancho `Sync`.
- **A imagem nova migra antes de o canary comecar.** Durante o canary, os pods
  da versao anterior rodam sobre o esquema novo: a migracao precisa ser
  compativel com a versao anterior (expandir antes, contrair num deploy
  seguinte).

Recusa no render: `migration` sem `database.enabled`, sem `command` nem `args`
(rodaria o app, que nao termina), sem `migration.database.secret` em producao,
com o mesmo Secret do app (`database.secret`, ou `<app>-db` sem ele) ou de um
worker, com recursos incompletos ou com `env` que nomeia variavel do chart.

### O que o chart NAO deixa voce fazer

Por desenho, e cada um ja custou caro a alguem:

- **`image.tag: latest`** — o `values.schema.json` recusa. Sem tag fixa nao
  existe rollback.
- **rodar como root** — `runAsNonRoot` e fixo, e o namespace e `restricted`.
- **sair para qualquer lugar** — o egresso externo precisa estar em
  `.Values.egress`, e as faixas de casa e da tailnet ficam de fora sempre.
- **ser chamado por outro app** — so o gateway entra.

### As politicas do Kyverno, conferidas no render

O cluster aplica cinco politicas em modo Enforce, e quatro olham o **pod**: o
`apply` de um Deployment ou de um Job sai verde, e o pod e que e recusado ao
nascer. `.github/scripts/conferir-pods.py` le cada modelo de pod de um render
(Rollout, Deployment, StatefulSet, DaemonSet, Job, CronJob, e a imagem e os
recursos do Cluster do CloudNativePG) e reprova:

| Politica | O que o conferidor exige |
|---|---|
| `exige-requests-e-limits` | `requests.cpu`, `requests.memory` e `limits.memory` em todo container e initContainer |
| `proibe-tag-latest` | tag fixa ou digest; sem tag e `:latest` implicito |
| `exige-nao-root` | `runAsNonRoot: true` no pod, ou em todo container |
| `registro-permitido` | imagem de `ghcr.io/slipalison/*` ou `ghcr.io/cloudnative-pg/*` (outra lista: `REGISTROS_PERMITIDOS`, padroes separados por espaco) |
| `exige-rotulos` | `app.kubernetes.io/name` e `owner` no Deployment, StatefulSet, DaemonSet e Rollout |

```bash
helm template meu-app charts/app -f values.yaml > render.yaml
python3 .github/scripts/conferir-pods.py render.yaml
```

Ele nao ve o que o Istio injeta nem os pods que o operador do CloudNativePG cria.
A isca, `.github/scripts/conferir-pods-isca.sh`, roda no CI antes de qualquer
render ser conferido: o render limpo passa, nove copias com um defeito
plantado cada uma sao reprovadas pela politica certa, e os valores que
plantariam esses defeitos ja sao recusados pelo chart.

### Publicar uma versao

Commitar na `main` com a mensagem no padrao Conventional Commits. E so.

```
feat(app): ...    -> 0.3.0 -> 0.4.0
fix(app): ...     -> 0.3.0 -> 0.3.1
feat(app)!: ...   -> 0.3.0 -> 1.0.0
```

A esteira (`.github/workflows/ci.yml`, sobre `slipalison/github-workflows`)
calcula a versao pelos commits desde a ultima tag, faz lint, empacota com
`helm package --version`, envia para `oci://ghcr.io/slipalison/charts`, e SO
ENTAO cria a tag `vX.Y.Z` e a release. Commit fora do padrao reprova o run.

`Chart.yaml` diz `version: 0.0.0` de proposito: a versao real e carimbada no
pacote, e o ArgoCD le o pacote. Nao crie tag a mao — uma tag manual entra na
conta da esteira e desloca a numeracao.

Depois de publicar, o `homelab-gitops` aponta para a versao nova em UM lugar:
`targetRevision` no `apps/applicationset.yaml`. O `validar-apps.yml` e o
ApplicationSet `previews` leem a versao dali.

---

## ADR-001 — o operador do OpenTelemetry saiu; o SDK entrou

**Data:** 2026-09-13. **Estado:** aplicado. **Vale a partir do chart 0.2.0.**

### O que havia

Até a versão 0.1.4 este chart escrevia uma anotação no pod:

```yaml
instrumentation.opentelemetry.io/inject-dotnet: "observability/default"
```

O operador do OpenTelemetry lia a anotação num webhook de admissão e injetava
o agente da linguagem. Instrumentação sem tocar no código — a promessa é boa.

### Por que não funcionava

O webhook nunca conseguiu completar um handshake TLS. Medido no cluster:

```
tls.crt  do operador  → assinado pela CA de 12/09 22:49:07
caBundle do webhook   → é a CA de 12/09 18:58:00
81 linhas "http: TLS handshake error ... remote error: tls: bad certificate"
```

Duas CAs diferentes, com quatro horas de distância. A causa é estrutural, não
um acidente de configuração:

- o chart do operador usa `admissionWebhooks.autoGenerateCert`, que gera a CA
  **no momento do `helm template`**;
- o ArgoCD renderiza o chart **a cada sync**, então cada sync produz uma CA
  nova;
- o `ignoreDifferences` que existia para calar esse drift congelava o
  `caBundle` do webhook, mas não impedia o Secret do certificado de ser
  reescrito. As duas pontas passaram a apontar para CAs distintas.

O jeito oficial de sair disso é o `lookup` do Helm, que reusa o certificado que
já está no cluster. **O ArgoCD não tem `lookup`**: ele roda `helm template`,
sem acesso ao cluster. Então, com este chart e este ArgoCD, `autoGenerateCert`
não tem conserto.

### Por que ninguém percebeu

O webhook que injeta em pods (`mpod.kb.io`) vem com `failurePolicy: Ignore`.
É o padrão certo — um webhook quebrado não deve impedir pods de nascer — e é
também o que transformou a falha em silêncio: o pod subia, ficava `Healthy`,
o ArgoCD ficava verde, e não exportava trace nenhum. Só apareceu quando se foi
procurar o serviço no Tempo e ele não estava lá.

### As duas saídas, e a escolhida

**cert-manager.** Resolve de verdade: o `cainjector` escreve o `caBundle` a
partir do Secret, em tempo de execução, e as duas pontas nunca divergem. Custa
três Deployments, um conjunto de CRDs e mais um operador para manter vivo — em
um cluster de três nós que hoje roda a 63% de memória e precisa sobrar espaço
para outras VMs.

**Tirar o operador.** Escolhida. O que ele entregava de concreto era a fiação:
apontar o OTLP para o Alloy e nomear o serviço. Isso são quatro variáveis de
ambiente, e este chart passou a escrevê-las. O que sobra para o app é iniciar o
SDK da própria linguagem — dez linhas, versionadas junto com o código, que
falham na cara de quem mexeu.

O que se perde: instrumentação de app que não pode ser recompilado. Se isso
voltar a ser necessário, o caminho é cert-manager, e este ADR é o ponto de
partida.

#### Adendo, 2026-09-13: o cert-manager entrou

A decisão acima continua certa para o que ela decidia, e a premissa dela caiu
no mesmo dia em que outra coisa precisou do cert-manager.

O `spec.backup.barmanObjectStore` do CloudNativePG foi deprecado no operador
1.30 e **desaparece no 1.31**. O substituto é o plugin Barman Cloud, que exige
cert-manager para as CRDs e para o TLS entre o plugin e o operador. O
argumento que sustentava a recusa era *"nada mais precisa dele, então a troca
não se paga"* — e isso deixou de ser verdade.

O cert-manager está instalado desde então, em
[`homelab-gitops/platform/cert-manager/`](https://github.com/slipalison/homelab-gitops).
**Isto não reabre a injeção por webhook do OpenTelemetry:** o que este chart
faz continua sendo melhor, porque não depende de operador nenhum estar vivo no
momento em que o pod nasce. O adendo existe para que ninguém leia o ADR daqui
a seis meses e conclua que cert-manager foi proibido.

A lição que sobrevive é outra, e é a que importa: webhook com certificado
inválido e `failurePolicy: Ignore` falha **calado**. O cert-manager é
exatamente a ferramenta que resolve isso direito, em vez de cada operador
gerar o próprio certificado no `helm template`.

### O que mudou no chart

| 0.1.4 | 0.2.0 |
|---|---|
| `instrumentation.language: dotnet` | removido — `helm template` **falha** se ainda estiver no values |
| anotação lida pelo webhook | `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` no container |
| depende do operador estar vivo | não depende de nada além do Alloy |

A falha do `helm template` é deliberada. Um values que traz `language` foi
escrito para o mundo antigo; ignorá-lo em silêncio repetiria exatamente o modo
de falha que este ADR veio encerrar.

### O que o app precisa fazer

Iniciar o SDK. As variáveis já estão no ambiente; nenhum endereço é escrito no
código. Em Python, é o que está em
[`demo-python/app/observabilidade.py`](https://github.com/slipalison/demo-python/blob/main/app/observabilidade.py).
Em .NET:

```csharp
builder.Services.AddOpenTelemetry()
    .WithTracing(t => t.AddAspNetCoreInstrumentation().AddHttpClientInstrumentation().AddOtlpExporter())
    .WithMetrics(m => m.AddAspNetCoreInstrumentation().AddOtlpExporter());
```

`AddOtlpExporter()` sem argumento lê `OTEL_EXPORTER_OTLP_ENDPOINT` do ambiente
— que é o ponto de escrever a variável no chart em vez de no `appsettings`.

### Como se sabe que está no ar

`verificar-plataforma.sh` faz duas perguntas que teriam pego isto no dia:

1. todo webhook de admissão do cluster apresenta um certificado que fecha com
   o `caBundle` registrado nele;
2. o Tempo conhece o `service.name` de cada app que declara
   `instrumentation.enabled`.
