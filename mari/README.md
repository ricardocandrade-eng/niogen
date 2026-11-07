<!-- NIOGEN | mari/README.md | 04/11/2026 — Claude Code (prompt nº 8): de onde vem cada bloco do prompt da Mari, como versionar e a regra 12. -->

# Mari — conteúdo (separado do motor)

O motor (workflow n8n `mari_principal`) não carrega texto de negócio. O comportamento da Mari mora **aqui**,
num arquivo por versão, e é embutido no nó **"5a · Conteúdo Mari"** pelo script de deploy
(`n8n/deploy_mari.py`). Playbook da Renata §7 ("extrair o núcleo"): trocar o conteúdo nunca exige mexer no motor.

## Arquivos

| Arquivo | O que é |
|---|---|
| `prompt_mari_v1.md` | system prompt v1 (04/11, bateria 12/12). O modelo recebe só o trecho entre `<!-- PROMPT:INICIO -->` e `<!-- PROMPT:FIM -->`; linhas `# DECISÃO PENDENTE` são removidas no build |
| `prompt_mari_v2.md` | no ar de 04/11 10h15 a 05/11 ~00h50 (substituída pela v3). v1 + ajustes do teste do Ricardo no chat: confirmação do plano já leva condições e pedido de nome/CPF (guard-rail 21: toda mensagem termina com o próximo passo); forma de pagamento já dita → só o preço dessa forma (o motor manda `valor_mensal_na_forma` no estado); visita: anota o dia/período pedido, sem inventar regra de antecedência; concorrente: não comenta (guard-rail 22). Bateria: cenário 13 reproduz o teste. **+ revisão do Cowork (04/11 10h30, pedida como "v1.1"; somada na v2 por decisão do Ricardo):** vencimento no fechamento obrigatório (roteiro Passo 4, rev. 04/11); "Ótima escolha!" sempre antes da sugestão de upgrade, na mesma mensagem; telefone diferente do WhatsApp repetido e confirmado antes de seguir. Bateria: checagens globais de "25 dias" e da ordem confirmação → upgrade, cenário 14 (telefone). **Data de retorno** de quem cancelou há ≤ 30 dias: o modelo errava a conta (dava 15/11 ou 05/12 para o certo 25/11), então o motor passou a mandar no estado a `tabela_retorno_cancelamento` (N dias → DD/MM, calculada em Brasília) e o prompt só copia — autorizado pelo Ricardo em 04/11, porque data cedo demais = venda dentro da janela de estorno |
| `prompt_mari_v3.md` | no ar de 05/11 ~00h50 a ~10h55 (substituída pela v4) (aprovação do Ricardo: "Sim, vire"; teste real com o celular: balões chegando separados, eco ignorado). Guard-rail 23 afrouxado em 05/11 (o upsell começa pela confirmação sorteada). Proposta "Modo B caloroso" (`docs/MARI_tom_humano_proposta_041126_2230.md`, Drive, aprovada 04/11 22h27; emoji rev. 22h35): fluxo do Modo B intacto + jeito de falar do Modo A. Bloco 1 caloroso, resposta honesta ao "é robô?" e "nunca invente vida pessoal"; Bloco 2 novo "JEITO DE FALAR" (reagir antes de seguir, nunca a mesma frase 2×, espelhar o cliente, português de WhatsApp, emoji como gente usa — no máx. 2 na conversa se o cliente não usa, proibidos 🎯 📍 💰 ✅ 🚀 ✨ 💡 🔥 📌 👉 ⭐ e 1️⃣ —, balões com `\|\|`); lista "1) Nome, velocidade — R$X por mês (R$Y no cartão)"; condições em texto corrido (os 5 itens literais); falas do Bloco 3 viram "exemplo do jeito — não copie" (literais: valores, condições, elegibilidade, cancelamento ≤ 30 d, resumo, despedidas, "é robô?"); "achei caro" com o `preco_dia`; guard-rail 21 reescrito. Conciliações (no cabeçalho do arquivo): guard-rail 23 segue com "Ótima escolha!"; "nunca markdown"/"nunca invente" ficaram como item 14 do Bloco 2; condições mantêm o item dos 25 dias. **Motor (vale para qualquer versão, ativo só com a v3):** `5b` manda `preco_dia` no INTERNAL DATA (preço da forma ÷ 30, para cima no centavo, + "menos de R$N") e, na v3, o contador de emoji no estado; `7 · Extrair` corta em até 3 balões, corrige emoji fora da regra sozinho (conta em `emoji_ajustes`) e pede reescrita para expressão de robô ("Prezado", "Certamente"…); `11 · Saída` devolve `baloes` + `atrasos`; laço `12a → 12b → 12w → 12c` manda um balão por vez no Chatwoot (atraso ≈ 1 s/60 caracteres, 2–6 s). Bateria: `python tests/mari_cenarios.py --ensaio` (rota `mari-teste-v3`, telefones `5500000003xxx`, cenários 1–14 + tom 15–20 + anti-repetição 21) |
| `prompt_mari_v4.md` | no ar de 05/11 ~10h55 a ~17h10 (substituída pela v5) (prompt nº 15 — venda remota; bateria do ensaio 26/27, só o 21 de tom vermelho; virada com o OK prévio do Ricardo "as duas rodadas"). Adendo 10h05: a viabilidade oficial nunca nega venda. Não existe visita: Passo 4 item 6 = preferência manhã/tarde da **instalação** (`instalacao_preferencia`), resumo com "Instalação: preferência … (data o nosso time confirma)", despedida `dados_completos` = "o nosso time abre o seu pedido e te manda aqui mesmo, [prazo], o link da biometria", cartão por link do nosso time; **guard-rail 24** (o "novo 19" do prompt 15 — o 19 já existia): link, biometria e crédito são do nosso time; **Bloco 9** viabilidade oficial (`nio_viab_resultado`: viavel → "atende o seu endereço" · sem_viabilidade → não vende, `sem_cobertura` · posse → 2b, "não" → humano com nota · indisponivel → como na v3). Nível A em espera (login do portal = SSO Microsoft): o motor manda sempre `indisponivel`. **Motor (v4+):** `5b` manda `nio_viab_resultado` e `instalacao=` no estado; `7 · Extrair` grava `instalacao_preferencia`, leva `nio_viab_*` no handoff, pede reescrita se a Mari falar em visita/presencial ou mandar link; versões ≥ 3 ganham tudo da v3 (antes o motor testava `startsWith('mari_v3')`). Bateria: `python tests/mari_cenarios.py --ensaio` (1–26; 22–24 gravam a viabilidade na conversa de teste para simular o nível A) |
| `prompt_mari_v5.md` | no ar de 05/11 ~17h10 a ~22h10 (prompt 18; substituída pela v6). Parágrafos com linha em branco, lista espaçada, condições exatas pela marca `[CONDICOES]`, pagamento é da Nio (guard-rail 25), retomada da conversa resolvida, 💚 na saudação e na despedida (posto pelo sistema). |
| `prompt_mari_v6.md` | **NO AR desde 05/11 ~22h10** (prompt 19 — o link da biometria é disparado pela própria Nio, por WhatsApp e e-mail, na hora do pedido; ensaio 8/8 verde). Bloco 1, guard-rail 24 ("ele chega pela própria Nio, por WhatsApp e e-mail, assim que o pedido é aberto 😊"), retomada ("cadê o link?" → spam + pedido_humano), briefing e despedida `dados_completos` em três parágrafos (💚 do sistema no fim do 1º). Filtro do 7 · Extrair: "a Mari / o nosso time manda o link" → reescrever. |

## Produção × ensaio

- **Produção** = workflow `mari_principal` (modo chatwoot no 31 2888-1265). Prompt definido em `ALVOS['producao']` do `n8n/deploy_mari.py`.
- **Ensaio** = workflow `mari_principal_v3` (hoje com a **v4**): mesmo motor, prompt novo, só a rota `/webhook/mari-teste-v3` (sem o webhook do Chatwoot — não recebe nem manda nada para número real). Todo comando do deploy aceita `--ensaio`.
- **Ensaio barato (07/11)** — config por alvo no `ALVOS` (regra 15):

  | | produção | ensaio |
  |---|---|---|
  | credencial do Claude (nós 6/6r) | `Claude API Nio` | `Claude API Nio — Testes` (workspace "Testes Mari", limite US$ 30/mês) |
  | modelo | `claude-sonnet-5` | `claude-haiku-5-5` · `--modelo sonnet` para validar o tom |
  | corte de histórico | sem corte | sem corte · `--historico N` mantém as últimas N mensagens |
  | `uso` por fala na rota de teste | não | sim (input / cache write / cache read / output + corte medido) |

  - A credencial de testes nasce com `python n8n/deploy_mari.py credenciais --ensaio`, lendo a variável de usuário `ANTHROPIC_API_KEY_TESTES` (nunca impressa). Sem a variável, ou sem o ID em `mari_ids.json`, o ensaio para — nunca cai na credencial da produção. Trocar a credencial/modelo no n8n: `estrutura --ensaio` (`codigo --ensaio` troca só o código).
  - Os trechos `// @ensaio-inicio … // @ensaio-fim` dos `.js` saem inteiros do código da produção, e `__MODELO__`/`__HIST_MAX__` são preenchidos pelo deploy. Prova de que a produção não mudou: `python n8n/deploy_mari.py codigo --dry-run` → "nada a fazer".
  - Bateria: `python tests/mari_v7_bateria.py <cenários> [--max N]` — sem cenário não roda; no fim, tokens por tipo, % de cache, custo por conversa e a economia estimada do corte; a limpeza roda sempre (`finally`).
  - ⚠️ 07/11: o Haiku 5.5 **não emite as tags** do prompt (busca da rua, planos) — os cenários que dependem delas (c, k) falham no Haiku e passam no Sonnet. Haiku só serve para o que não depende de tag.
- **Virar a produção para a v3** (só depois do OK do Ricardo): em `ALVOS['producao']` trocar `prompt_mari_v2.md`/`mari_v2` por `prompt_mari_v3.md`/`mari_v3` → `npx supabase db push --remote` (aplica a `0021`, eco por balão) → `python n8n/deploy_mari.py estrutura` (backup antes) → teste real com o celular do Ricardo (balões chegando separados, sem eco virando fala de consultor) → Diário.

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
2. Pôr a versão nova no ensaio (`ALVOS['ensaio']` em `n8n/deploy_mari.py`; `python n8n/deploy_mari.py estrutura --ensaio`), rodar `python tests/mari_cenarios.py --ensaio` até verde, mostrar conversas ao Ricardo; com o OK, apontar `ALVOS['producao']` para ela e publicar (seção acima).
3. Registrar no Diário: versão, o que mudou e por quê.

## Regra 12 (CLAUDE.md)

Mudou o roteiro, a tabela de planos, a área de atuação ou o contrato → **na mesma sessão** muda: o Supabase (config), este prompt
(se o texto de comportamento mudou), o `INFRA.md` e o Diário. Preço e cidade só mudam no banco — o prompt não tem nenhum.
