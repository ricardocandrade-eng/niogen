<!-- NIOGEN | CLAUDE.md | 03/11/2026 00:40 — Cowork, projeto "Nio Internet" -->

# CLAUDE.md — NIOGEN · Dharma Telecom × Nio Internet

> **Leia este arquivo primeiro. Ele é curto de propósito.**
> Ele não explica nada: diz **onde está cada coisa** e **quais são as regras**.
> Modelo: o `CLAUDE.md` do Grupo Humanidade (mesma governança, menos regras — o projeto é novo).
> Se o projeto claude.ai (Cowork) tiver cópia destes documentos, **a cópia de lá espelha esta — nunca o contrário.**

**NIOGEN — Renascer. Reconstruir. Crescer.** CRM + agente de IA (Mari) + Meta Ads da
**Dharma Telecom**, agente credenciado PAP da **Nio Internet**. Meta: 30 planos em nov/2026,
50 em dez, 70 em jan/2027. Empresa enxuta, IA no atendimento e na operação.

---

## ⚡ PROTOCOLO DE INÍCIO DE SESSÃO — obrigatório, antes de qualquer tarefa

1. **Ler a "Última atualização" do `ESTADO ATUAL — Diário de Bordo.md`.**
2. **Rodar `git log` desde essa data** no clone do `niogen` (quando existir) e conferir commits sem push.
3. **Se houver mudança fora do Diário: registrar ANTES de começar.** Uma linha por dia de trabalho.
4. **Perguntar ao Ricardo: "algo mudou fora do repo?"** (Nio, Rogério, Supabase, Meta, decisões faladas).

**Fim de sessão:** o que mudou vira linha no Diário **na própria sessão** (o Cowork escreve na caixa de
entrada — regra 7). Nada está "pronto" antes de virar linha lá. Mexeu em endereço, ID, rota ou repo → o `INFRA.md` é corrigido junto.

---

## Os 4 documentos que valem

Todos na raiz desta pasta. Se a informação não está em um destes, ela não é oficial.

| Documento | Responde | Muda |
|---|---|---|
| **ESTADO ATUAL — Diário de Bordo.md** | O que existe **hoje** e em que pé está | toda sessão |
| **INFRA.md** | **Onde** fica cada repo, URL, ID, planilha, credencial-referência | quando algo muda de lugar |
| **CLAUDE.md** (este) | As regras de trabalho | quase nunca |
| **docs/CONTRATO_DHARMA_regras.md** | As regras do **contrato com a Nio** que todo código obedece | quando a Nio mudar um anexo |

Documentos de apoio (não são governança, são fonte): `docs/ESTUDO_PLANO_NIO_30-50-70_021126_2130.md`
(o plano e as decisões), `docs/REFERENCIA_NIO_dicionario_dados_021126_2330.md` (os relatórios da Nio),
o mockup `claude.ai/artifact/SUJ1dg3yrDzd3UKtReDTBo` (as 12 telas).

## Documentos APOSENTADOS — não use, não atualize

- `_ref-vero/CLAUDE_clone-gas_ate-021126.md` e `_ref-vero/CONTEXTO_NIO_ate-021126.md` → eram o `CLAUDE.md` e o
  `CONTEXTO_NIO.md` do **clone em GAS + Sheets do DharmaPro Vero**. Aposentados em 03/11/2026 pela decisão de stack.
  O código GAS desta pasta (`*.js`, `*.html`, `.clasp.json`) é **referência**, não produto — ver regra 2.
- `_ref-vero/dharmapro-crm_CLAUDE.md` → cópia congelada do CRM Vero. Referência de padrões, nunca base.

---

## A arquitetura em cinco linhas (decisão de 02/11/2026)

1. **Supabase Nio** é o **banco único**: Mari e NIOGEN leem e escrevem no mesmo lugar. Nada em Sheets como fonte da verdade.
2. **NIOGEN** é um front próprio em HTML sobre o Supabase (mesmo padrão Painel/Pocket do Parque, com o Supabase no lugar do Cofre). 10 telas: Painel · Placar · Vendas (lista ou quadro — o Funil virou a vista Quadro em 04/11) · Instalações · Mari · Adimplência · Conciliação · Meta Ads · Fila Vero · Configurações.
3. **Mari** = n8n + Chatwoot da Nio + Supabase Nio + Claude. Motor da Renata (guards, debounce, takeover, janela 24h), cabeça nova. Objetivo dela: **venda qualificada com biometria agendada**.
4. **n8n** importa os relatórios da Nio (OSAB, FPD, CHURN, extrato), roda a cadência e a régua de pagamento, avisa o vendedor.
5. **Fonte da verdade**: código → GitHub (`niogen`). Dado da operação → Supabase Nio. Verdade contábil → **a Nio** (NIOGEN é o auditor, não a folha). Segredos → `.env` da VPS / painel n8n / gerenciador de senhas. **O Drive nunca guarda código nem segredo.**

---

## As regras de trabalho

### 1. O contrato vem antes da venda
Toda tela, automação, prompt e anúncio obedece `docs/CONTRATO_DHARMA_regras.md`, priorizando o que protege a Dharma:
comissão só com instalação + biometria + área de atuação; estorno 100 % em cancelamento e reativação ≤ 30 d, cliente/endereço já na base Nio, cancelamento por não qualidade; parcial em downgrade ≤ 180 d (só a diferença); fraude = multa R$ 500 por ocorrência; multa de R$ 500 por recompra; **churn e inadimplência não estornam** (só pesam nos indicadores de qualidade);
agendar instalação em **4 h**; documentos em **15 dias**; contestação em **120 dias**; contato seg–sex 9–21, sáb 10–16, nunca dom/feriado,
**2/dia e 15/mês**; sem desconto, prazo ou benefício fora da tabela; marca Nio em anúncio só com aprovação prévia; dados de cliente são da Nio
(incidente → 24 h). Na dúvida entre vender e proteger a Dharma, **proteger e avisar o Ricardo**.

### 2. Desapego do Vero
Dharma Telecom ≠ Mobile Digital; Nio ≠ Vero. O DharmaPro, a Renata e o clone GAS são **referência de padrão**, nunca código herdado.
Nenhum ID, token, número, Supabase, Chatwoot ou planilha da Vero entra no NIOGEN. A única ponte operacional é a **Fila Vero** (regra 8).

### 3. Toda ideia nova é tela, tabela, fluxo ou relatório
- **tela** no NIOGEN · **tabela/evento** no Supabase Nio · **fluxo** no n8n (Mari, importação, cadência) · **relatório** da Nio importado.
Se não for nenhum dos quatro, não se constrói — vira doc de ideia e espera. **Nunca nasce "um sistema novo".**

### 4. O arquivo nasce no destino — o Ricardo não move arquivo à mão
- **Claude Code** escreve no clone (`C:\Users\ricar\Documents\GitHub\niogen`), faz commit, push e deploy.
- **Cowork** alcança a máquina só por pastas conectadas: conectar sempre `C:\Users\ricar\Meu Drive\Projetos Claude\dharmapro-nio` (→ `niogen` após o rename) e, quando precisar de referência, `dharmapro-crm`, `agente-ia-vero`, `Grupo Humanidade`.
- Relatórios da Nio ficam em `referencia-nio/` (exemplos) e, quando reais, **só no Supabase** — nunca copiados para outra pasta ou projeto.
- Convenção de nome: `nome_do_arquivo_DDMMAA_HHMM.ext`; todo arquivo gerado abre com o bloco de cabeçalho (projeto, data/hora, resumo).

### 5. Segurança, sem exceção
Nenhum segredo em arquivo versionado, HTML ou chat. Token da WABA Nio (system user `Nio_API`), service role do Supabase Nio, token do Meta Ads Nio,
chave Claude: `.env` da VPS, credencial do n8n, gerenciador de senhas. Chave exposta = rotacionar na hora. O app Meta "Renata Digital" serve as duas
WABAs: **webhook da Nio sempre por override da WABA `1419511943295487`, nunca no nível do app**. Base de clientes da Nio não vai para chip comum/Evolution. **Portal PAP (05/11, prompt 16):** a Nio não tem API e autorizou o login BO (TT837725) para a viabilidade; o login automático por navegador (Playwright) é permitido **só numa VPS no Brasil**, com as chamadas feitas **dentro da página** do portal pela função do próprio front — nunca reproduzir o sufixo cifrado do front nem contornar o bloqueio de IP. Usuário e senha só no `.env` da VPS do portal; o token não sai do navegador do serviço (nunca em arquivo, repo, Drive, `config_links`, chat ou log). Só nível A (viabilidade); nível C (pedido, crédito, biometria, OS) recusado no código. **Exceção (Ricardo, 10/11 11h02):** no **Histórico de Pedidos** a extensão pode clicar **só nos filtros** (campos, opções, datas, "Filtrar", paginação) **para ler** a tabela e mandar tipo/status ao NIOGEN — lista branca no código; nunca Detalhar, Carregar, Salvar, Atualizar Pedido, Novo Pedido, Funil ou Tramitações. **GED360 / BrPronto (Ricardo, 10/11 12h39):** o robô do n8n pode usar um login próprio — **TT837722** desde 10/11 15h (o GED360 não aceita sessões simultâneas; o TT837725 é da Joysse) — para **ler** o Relatório Detalhado (CSV) e trazer o status da biometria — senha só na credencial do n8n/`.env`; nenhuma outra tela; sem contornar bloqueio de IP. **Exceção (Ricardo, 03/11):** usuário e as 2 senhas do painel DFV Nio (filtro do relatório, não uma conta) ficam no Supabase Nio, em `config_links.acesso`, visíveis só para usuário logado no NIOGEN — gravadas pelo CLI, **nunca** em arquivo versionado, HTML, Drive ou INFRA.

### 6. Deploy
Front: Claude Code publica no clone → push → hospedagem (Cloudflare Pages ou GitHub Pages — decidir, INFRA). **Sempre bumpar o `CACHE` do `sw.js`** se houver.
Supabase: migrations versionadas em `supabase/migrations/`, nunca alteração à mão no painel sem migration correspondente.
n8n: workflow exportado em `n8n/` após cada mudança; backup antes de PUT. **A prova de que pegou é abrir a tela ou chamar a rota — não o "deploy ok".**

### 7. O Cowork não grava o Diário — escreve na caixa de entrada
Igual à Humanidade: o Cowork acrescenta a entrada no fim de `Diário — caixa de entrada do Cowork.md`; o Claude Code (ou o `guarda.py`, quando
instalado para esta pasta) junta no Diário. Os outros três documentos o Cowork pode editar.

### 8. Fila Vero — risco aceito, com regras
Decisão do Ricardo em 02/11/2026: seguir, apesar do risco (LGPD/finalidade e não concorrência). Regras fixas: só template aprovado, cobertura Nio
checada pelo CEP antes de abordar, **1 contato/dia e 2 no total por cliente**, nenhum dado da fila fora do NIOGEN, todo toque registrado, quem responde
entra na Mari com origem "Fila Vero".

### 9. Toda tarefa do Claude Code vem em prompt pronto, no chat
O que mudou e por quê · arquivos nomeados · mensagem de commit · migration/export quando houver · `git push` · e o que o Code **não** deve fazer.
Especificação de layout vai como arquivo ou artefato (`claude.ai/code/artifact/<id>`), nunca como prosa.

### 10. Medição diz QUE mudou; ela nunca diz POR QUÊ
Achado como fato, causa como pergunta. Antes de apresentar uma queda como falha, conferir o óbvio (feriado, vendedor fora, relatório atrasado).

### 11. Entregável com prazo vira cartão; reunião fica no calendário
Decisão pendente: quadro Trello próprio "NIOGEN" ou lista dentro do quadro "Grupo Humanidade" (ver Diário). Até decidir, o entregável fica no Diário com data.

### 12. Mudou uma regra de conteúdo, muda tudo no mesmo passo
Tabela de planos, área de atuação, régua da Mari, templates, regras do contrato: a mudança atualiza **na mesma sessão** o Supabase (config), o prompt/base
da Mari, o `INFRA.md` e o Diário. Conflito entre duas fontes não vira lista — pergunta ao Ricardo e corrige todos os lugares.

### 13. Mudou o sistema, muda o guia do backoffice no mesmo passo
Toda mudança que altera o que o backoffice vê ou faz — Mari (falas, guard, handoff, retomada), nota/etiquetas/times/automações
do Chatwoot, telas e avisos do NIOGEN ligados à venda, portal PAP, biometria, pagamento, cadência, contrato — atualiza **na mesma
sessão** `docs/BACKOFFICE_chatwoot_com_a_mari_051126_1045.md` (pasta `dharmapro-nio` no Drive — não é o `docs/` do site; com linha `rev.` no cabeçalho). Vale para o Cowork e para o Claude Code:
**todo prompt do Code (regra 9) traz o item "atualizar o guia do backoffice"** ou diz explicitamente "guia do backoffice: sem impacto".
Nada está "pronto" com o guia desatualizado.

---

## Regras de conteúdo da Mari (valem para prompt, base e templates)

- Fala só da tabela vigente. Nunca desconto, prazo, benefício ou promessa de data de instalação.
- Informa limitações do produto. Pede LGPD curta. Valida CEP (cobertura + área), CPF, telefone confirmado.
- Cliente Nio reclamando, luto, urgência, pedido de desconto → **humano agora**.
- **Venda remota (05/11):** não existe visita nem biometria em campo. Pedido pelo portal PAP (BO), link da biometria **disparado pela Nio** (e-mail + WhatsApp) na hora do pedido — nós não mandamos link, instalação agendada pelo nosso time. A Mari coleta preferência de período, nunca promete data. Viabilidade oficial pelo portal (n8n, nível A) antes dos planos; DFV é fallback.
- Cadência de lead: 24h · D3 · ligação do vendedor · D7 · D15. Régua de pagamento: **D−2 · D0 · D+5**, só fatura em aberto. Depois do D+5, vendedor liga (15 dias perde o M-10).
- Sempre dentro de 2 contatos/dia e 15/mês; nunca domingo ou feriado.
- Template com marca Nio → aprovação da Nio antes da Meta.

## Regras da Mari no código — o portão (08/11/2026, Onda 1.2)

- **Nada sobe no `mari_principal` sem a bateria fixa `portao` verde.** `python n8n/deploy_mari.py codigo|estrutura` (produção)
  recusa se não houver, nas últimas 6 h, uma rodada de `python tests/mari_portao.py` 100 % verde, completa, com o **mesmo hash**
  do código que vai subir e o modelo da produção (tabela `mari_portao_rodadas`). Caminho: `codigo --ensaio` → `tests/mari_portao.py` → `codigo`.
- **Falha nova achada em teste real → antes de corrigir, escrever o cenário** em `tests/mari_portao.py` (P16, P17…) que a reproduz
  e vê-lo vermelho; depois corrigir até ficar verde. Toda falha já vista vira cenário fixo.
- A bateria roda **só no ensaio** (`mari_principal_v3`, chave "Claude API Nio — Testes"), nunca na produção. Custo ~US$ 1,40 por rodada.
- Bateria achou vermelho → **listar e parar**; corrigir a Mari é outro passo, com o OK do Ricardo.
- `--sem-portao "motivo"` publica mesmo assim e grava o motivo — **só o Ricardo decide** usar.

---

## Onde o trabalho realmente acontece

`chats do Cowork` · `Claude Code em Documents\GitHub\niogen` · `painel do Supabase` · `n8n` · `Chatwoot da Nio` · `Business Manager (Meta)` · `e-mail do Rogério` · `APP NiO PAP`

Só a pasta tem governança. Quando algo nasce fora dela — e a maioria nasce — **só o Diário captura.**
