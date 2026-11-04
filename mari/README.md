<!-- NIOGEN | mari/README.md | 04/11/2026 — Claude Code (prompt nº 8): de onde vem cada bloco do prompt da Mari, como versionar e a regra 12. -->

# Mari — conteúdo (separado do motor)

O motor (workflow n8n `mari_principal`) não carrega texto de negócio. O comportamento da Mari mora **aqui**,
num arquivo por versão, e é embutido no nó **"5a · Conteúdo Mari"** pelo script de deploy
(`n8n/deploy_mari.py`). Playbook da Renata §7 ("extrair o núcleo"): trocar o conteúdo nunca exige mexer no motor.

## Arquivos

| Arquivo | O que é |
|---|---|
| `prompt_mari_v1.md` | system prompt v1. O modelo recebe só o trecho entre `<!-- PROMPT:INICIO -->` e `<!-- PROMPT:FIM -->`; linhas `# DECISÃO PENDENTE` são removidas no build |

Placeholders preenchidos pelo nó **"5b · Motor"** a cada turno:

| Placeholder | De onde vem |
|---|---|
| `{{DATA_HORA_ATUAL}}` | relógio do n8n em America/Sao_Paulo |
| `{{HORARIO_COMERCIAL}}` | seg–sex 9–21, sáb 10–16 (contrato); domingo nunca. Feriado: ainda não tratado (lista a criar) |
| `{{ESTADO_ATUAL}}` | `mari_conversas` (etapa, endereço do ViaCEP, cidade/cluster/dentro_area, elegibilidade, segmento, dados coletados, CPF por dígito verificador, nome_confiavel, `dfv_resultado`) |
| `{{INTERNAL_DATA}}` | `config_planos` ativos do cluster da cidade e do segmento (nome, velocidade, Wi-Fi, 5G, inclusos, `preco`, `preco_cartao`, taxa, isenção) — **preço, cidade e plano nunca são escritos à mão no prompt** |

## De onde vem cada bloco (fonte: `docs/MARI_roteiro_atendimento_031126_1430.md`, no Drive)

| Bloco do prompt | Roteiro | Observação |
|---|---|---|
| 1 Identidade e missão | Bloco 1 | o nome da revendedora **não aparece** no prompt (o modelo não tem como escrevê-lo); o filtro de saída do nó 7 bloqueia por garantia |
| 2 Tom | Bloco 2 | |
| 3 Fluxo (passos 1–5, 2b, 3b) | Bloco 3 | preços de exemplo do roteiro trocados por referências ao `[INTERNAL DATA]`; lista de cidades BTU trocada por `tabela_cidade` do estado |
| 4 Preço | Bloco 4 + base §3/§3b | |
| 5 Guard-rails 1–20 | Bloco 5 (1–18) + base §11 (19, 20) | |
| 6 Tags + `[HANDOFF]` | Bloco 6 | tags novas de motor: `[ENDERECO]`, `[SEGMENTO]`, `[UPSELL_OFERECIDO]`; `[DADOS_COLETADOS]` leva `campo=valor` (o motor grava os valores em `mari_conversas.dados`) |
| 6b Despedidas | Bloco 6b | prazo "em até 2 horas" / "no próximo horário de atendimento" |
| 7 Desvios | Bloco 7 + base §10 | |
| 8 Base DFV | seção "DFV — regra para a Mari" | |
| Mídia | Bloco 8 | não está no prompt: resposta fixa do motor (nó "2c · Mídia") |

## Decisões pendentes (padrão em uso, marcado `# DECISÃO PENDENTE` no prompt)

- (a) LGPD = uma linha na 1ª vez que pede CPF.
- (b) a Mari nunca fala em ligação.
- (c) consultor = "nosso consultor"; prazo "em até 2 horas" dentro do horário (seg–sex 9–21, sáb 10–16), senão "no próximo horário de atendimento".

## Versionar

1. Mudança de comportamento → **arquivo novo** `prompt_mari_v2.md` (nunca editar a versão que está no ar sem subir o número).
2. Apontar o deploy para a versão nova (`PROMPT_FILE` em `n8n/deploy_mari.py`), rodar a bateria `tests/mari_cenarios.py` até verde, deploy cirúrgico do nó "5a".
3. Registrar no Diário: versão, o que mudou e por quê.

## Regra 12 (CLAUDE.md)

Mudou o roteiro, a tabela de planos, a área de atuação ou o contrato → **na mesma sessão** muda: o Supabase (config), este prompt
(se o texto de comportamento mudou), o `INFRA.md` e o Diário. Preço e cidade só mudam no banco — o prompt não tem nenhum.
