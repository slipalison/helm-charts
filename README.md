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
| Anotacao de instrumentacao OpenTelemetry | Traces sem tocar no codigo |

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

```bash
git tag v0.1.0 && git push --tags
```

O workflow empacota, valida e envia para `oci://ghcr.io/slipalison/charts`.
