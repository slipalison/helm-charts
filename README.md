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
