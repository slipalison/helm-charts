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
Secret `<app>-db`, **do próprio namespace**.

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

### O que o chart NAO deixa voce fazer

Por desenho, e cada um ja custou caro a alguem:

- **`image.tag: latest`** — o `values.schema.json` recusa. Sem tag fixa nao
  existe rollback.
- **rodar como root** — `runAsNonRoot` e fixo, e o namespace e `restricted`.
- **sair para qualquer lugar** — o egresso externo precisa estar em
  `.Values.egress`, e as faixas de casa e da tailnet ficam de fora sempre.
- **ser chamado por outro app** — so o gateway entra.

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

Depois de publicar, o `homelab-gitops` precisa apontar para a versao nova em
dois lugares: `targetRevision` no `apps/applicationset.yaml` e `chart_version`
no `validar-apps.yml`.

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
