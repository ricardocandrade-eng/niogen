<!--
  NIOGEN | n8n/RPC_dfv_consultar_031126_2130.md
  Gerado em 03/11/2026 21:30 (America/Sao_Paulo) — Claude Code
  Resumo: contrato do RPC dfv_consultar (migration 0011) para o workflow da Mari no n8n. O workflow ainda não existe.
  Fica em n8n/ (e não em docs/) porque docs/ é a pasta publicada no GitHub Pages.
-->

# RPC `dfv_consultar` — viabilidade pela base DFV (para a Mari)

A Mari **não recebe a base**: o n8n pergunta ao Supabase Nio por CEP + número (+ complemento) e usa a resposta.
A base (`nio_hp`) é da Nio, só tem endereços **viáveis** e é trocada inteira a cada carga (`aplicar_dfv`).

## Chamada

```
POST https://zlrfwbkblytnokuexjti.supabase.co/rest/v1/rpc/dfv_consultar
apikey: <service role do Supabase Nio — credencial do n8n, nunca no workflow exportado>
Authorization: Bearer <service role>
Content-Type: application/json

{ "p_cep": "36000-000", "p_numero": "100", "p_complemento": "APTO 101" }
```

- `p_cep`: aceita com ou sem traço (a função tira tudo que não é dígito).
- `p_numero`: como o cliente disse. `"12C"` casa exatamente; se não houver, casa pelos dígitos (`"12"` → 12, 12A…). Vazio, `"s/n"` ou `"SN"` → `precisa_numero`.
- `p_complemento`: opcional. Compara só letras e dígitos (`"Apto 101"` = `"APTO101"`); se não bater, tenta só os dígitos (`"101"`).
- Também aceita `GET /rest/v1/rpc/dfv_consultar?p_cep=…&p_numero=…` (a função é `stable`).

## Resposta

Sempre um array com **uma** linha:

```json
[{
  "resultado": "viavel",
  "hp_livre": 1, "hc_tot": 0, "hp_tot": 1,
  "tipo_edificacao": "HORIZONTAL",
  "faixa_credito": "Maior que 70%",
  "classificacao": "ALTO", "classe_social": "A/B",
  "bairro": "CENTRO", "celula": "000 (XXX) SECUNDÁRIA", "cod_survey": "L0000000",
  "particao": "2026-11-03",
  "opcoes": null
}]
```

| `resultado` | Quando | O que a Mari faz |
|---|---|---|
| `viavel` | 1 fachada, HP livre ≥ 1 | segue a qualificação ("o endereço aparece na nossa base; o consultor confirma na visita") |
| `viavel_predio` | várias linhas no CEP + número (prédio, casas A/B) e o complemento não escolheu uma | pergunta o apto/bloco; `opcoes` = `[{complemento, numero, hp_livre, hc_tot, hp_tot}]`; chamar de novo com `p_complemento` |
| `endereco_ocupado` | casa (HP_TOT = 1) com HC ≥ 1 | **já tem Nio**: não vender (estorno 100 % + multa) → humano / saída "Já é cliente Nio" |
| `sem_porta_livre` | na base, HP livre = 0 (sem ser casa ocupada) | não vender agora; humano decide |
| `nao_encontrado` | CEP + número fora da base | sem viabilidade hoje → saída "Sem cobertura", interesse futuro 90 d. Antes, confirmar CEP e número com o cliente |
| `precisa_numero` | número vazio / s/n | pedir o número da fachada. `bairro` vem preenchido se o CEP está na base |

Regras que valem para a resposta (contrato e `CLAUDE.md`):
- **Nunca** dizer ao cliente "cobertura confirmada": a palavra final é do APP NiO PAP / do consultor na visita.
- `faixa_credito`, `classificacao` e `classe_social` **não se falam com o cliente**: servem para priorizar e para o risco de FPD.
- `particao` = data da base. Se tiver mais de 7 dias, avisar o Ricardo (a base parou de chegar).

## Na venda (NIOGEN)

O trigger `vendas_antes_cobertura` chama a mesma função quando uma venda em `0_qualificado` ganha ou muda CEP + número (+ complemento)
e preenche `dfv_viabilidade`, `dfv_hp_livre`, `dfv_hcs`, `dfv_faixa_credito`, `dfv_classificacao`, `dfv_resultado`, `dfv_particao`,
`dfv_origem = 'auto'`. Ou seja: se a Mari gravar a venda com CEP e número, o DFV já sai preenchido — não precisa mandar os campos `dfv_*`.
Uma consulta **manual** mais nova que a base não é sobrescrita.

## Mapa resultado → `vendas.dfv_viabilidade`

`viavel` → `viavel` · `viavel_predio` → `viavel_predio` · `endereco_ocupado` → `sem_viabilidade` (+ evento "DFV: endereço já tem Nio") ·
`sem_porta_livre` → `sem_viabilidade` · `nao_encontrado` → `nao_encontrado` · `precisa_numero` → não mexe.
