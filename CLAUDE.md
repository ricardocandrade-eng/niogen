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

### 5. Segurança e robôs nos sistemas da Nio (rev. 13/11/2026)
**Segredos.** Nenhum segredo em arquivo versionado, HTML, Drive, cartão do Trello, chat ou log. Token da WABA Nio (system user `Nio_API`), service role do Supabase Nio,
token do Meta Ads Nio, chave Claude e logins da Nio (portal PAP, GED360): `.env` da VPS, credencial do n8n, gerenciador de senhas. Chave exposta = rotacionar na hora.
Única exceção: usuário e as 2 senhas do painel DFV (filtro do relatório, não uma conta) ficam em `config_links.acesso` no Supabase Nio, gravados pelo CLI e visíveis só
para usuário logado no NIOGEN (Ricardo, 03/11) — nunca em arquivo versionado, HTML, Drive ou INFRA.

**Meta e WhatsApp.** O app Meta "Renata Digital" serve as duas WABAs: **webhook da Nio sempre por override da WABA `1419511943295487`, nunca no nível do app**.
Base de clientes da Nio não vai para chip comum/Evolution.

**Robôs nos sistemas da Nio** (operador `niogen-portal`, operador DFV, robô do GED360, extensão "NIOGEN no Portal"). A Nio não tem API; vale para todos:
- **Pela página, como gente:** navegador real e chamadas feitas **dentro da página** pela função do próprio front. Nunca reproduzir o sufixo cifrado do front, nunca
  contornar bloqueio de IP nem controle antifraude da Nio (ex.: trocar de celular para driblar o limite de repetição do mesmo número).
- **Onde roda:** navegador automático no portal PAP só com IP do Brasil (VPS `niogen-portal-br` ou o PC do Ricardo).
- **Login:** um por robô sempre que a Nio der (GED360 = TT837722; portal PAP = TT837725, dividido com a Joysse até sair um próprio — não rodar o operador com ela no
  meio de um pedido). Senha só no `.env`/credencial do n8n; o token não sai do navegador do serviço (nunca em arquivo, repo, Drive, `config_links`, chat ou log).
- **Travas no código, com teste:** lista branca do que se clica e bloqueio de rede do que não pode (`portal/credito.py` + `portal/testar_travas.py`). Etapa nova
  ganha trava e teste antes de rodar.
- **Quem dispara:** a consulta de crédito sai **sozinha pela Mari** (pelo operador `niogen-portal`) assim que ela tem o CPF e o e-mail confirmado, **sem perguntar** ao cliente (Ricardo, 12/11/2026 ~10h: "nem o WhatsApp oficial da Nio pede autorização; isso pode travar o cliente") — a linha da LGPD não muda; negado → a Mari oferece o CPF de um parente/familiar como titular (1 nova consulta). Admin/backoffice também consultam pela tela. O clique que grava o pedido continua só do humano admin/backoffice. Aceite de comunicação por WhatsApp sempre marcado (o portal exige).

**Novo Pedido: o robô vai até o fim, o humano dá o clique que grava (Ricardo, 12/11/2026 00h47).** O robô — operador ou extensão — pode percorrer **todas as etapas**
(viabilidade, cadastro, contato, crédito, oferta e forma de pagamento **da venda registrada**) e chegar ao Resumo com tudo preenchido, como na Consulta de cobertura,
e **para sem salvar o pedido**. **Só o humano clica** no que grava o pedido ou manda algo ao cliente: confirmar/enviar o Resumo (checkout), Abrir OS, envio da
biometria, link de pagamento, agendamento. Se o portal mandar algo ao cliente antes do Resumo (um "Continuar" que dispara a biometria, por exemplo), o robô para ali.
Nunca, em etapa nenhuma: **Salvar interesse**, oferta ou forma de pagamento diferente da venda, dados de cartão ou de conta (DACC) — esses o humano digita.
O pedido que vale é o feito pela extensão na sessão do humano logado, que confere e clica; o operador na VPS (sem humano na tela) serve de consulta e larga o rascunho.
Uso do robô autorizado pelo Rogério (Nio) — Ricardo, 12/11/2026 00h52. Pedido errado, sem consentimento ou recompra (estorno, multa de R$ 500 na matrícula): risco assumido pelo Ricardo em 11/11/2026.

**Leitura de acompanhamento.** No **Histórico de Pedidos** a extensão clica só nos filtros (campos, opções, datas, "Filtrar", paginação) para ler tipo/status —
nunca Detalhar, Carregar, Salvar, Atualizar Pedido, Funil ou Tramitações. No **GED360/BrPronto** o robô do n8n só lê o Relatório Detalhado (CSV) da biometria.
No **painel DFV** o operador só consulta.
Na **Consulta OS** (login TT837725) o operador `niogen-portal` lê o andamento da OS de venda registrada no NIOGEN: preenche só o filtro
(CPF/CNPJ, Número OS, período) e clica só em "Filtros" e "Filtrar". Nunca: Enviar/Reenviar link de pagamento, Agendar instalação, reagendar,
cancelar OS, "Atualizar o status da OS" nem "Detalhar" (a pesquisa já traz tudo). Rede: passa só a leitura `consultastatusos`; o resto que
grava fica bloqueado. E-mail e telefone do cliente que vêm na resposta não são guardados. Não roda com a Joysse no meio de um pedido.
No **Dashboard › Performance em Foco** (painel Power BI, login TT836757 — autorizado pelo Ricardo em 13/11/2026: "Pode, só o painel") o operador
só abre o Dashboard, troca de aba e de filtro do painel e exporta as tabelas "Exportação - OSAB" e "Faturas Em Aberto". Nunca: Cadastro Usuários,
Gestão de Fila, Histórico, Áreas ou qualquer menu fora do Dashboard. (Levantamento de 13/11/2026: `docs/LEVANTAMENTO_consulta_os_131126_0955.md`.)

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

<!-- 10/11/2026 (Claude Code, prompt Prompt_mari_ao_vivo_oportunidades_101126_1400): regras 14–18 copiadas da pasta dharmapro-nio (rev. 10/11 14:00) — a pasta é a fonte; as regras 1–13 deste espelho podem estar defasadas (ver a pasta). -->
### 14. Anúncio de imagem: cada posicionamento com a sua arte (06/11/2026)
Todo anúncio de imagem nasce com **1x1 (1080×1080) e 9x16 (1080×1920)** e personalização por posicionamento:
9x16 em **todas** as posições verticais (`instagram story/reels/profile_reels/reels_overlay`, `facebook story/facebook_reels/facebook_reels_overlay`,
`messenger story`, `whatsapp status`) e **regra de fallback 1x1** para o resto. Advantage+ criativo e corte/ampliação automáticos sempre desligados.
O script recusa criativo fora disso (`validar_criativo`, prompt 25). **Nada vai ao ar sem a prévia de Stories conferida** (9x16 servida) e,
24 h depois, um print real de Stories. Edição sugerida pela IA da Meta (textos/títulos gerados) não se publica sem revisão.

### 15. Construir como se houvesse mais de um parceiro (07/11/2026)
Não se constrói multi-parceiro agora, mas nada fecha essa porta (ideia para 2027: `docs/IDEIA_NIOGEN_outros_PAPs_071126_0010.md`).
- **Toda tabela de operação nova nasce com `parceiro_id`** (hoje um único valor: Dharma). Tabela antiga ganha a coluna quando for mexida.
- **Nada fixo no código:** comissões, cidades, prazos do contrato, IDs Meta/WABA, links e logins do portal ficam em config no Supabase.
- **Núcleo × módulos da Dharma:** regras do contrato e importadores dos relatórios da Nio são núcleo; **Mari** e **Fila Vero** são módulos desligáveis — o NIOGEN funciona sem eles.
- **Cada importador de relatório da Nio é peça isolada**, testada contra `referencia-nio/`.
Todo prompt do Claude Code (regra 9) respeita estes quatro pontos ou diz por que não.

### 16. Painéis e integrações da Meta: fazer, não perguntar — e avisar logo em seguida (Ricardo, 07/11/2026)
Claude Code e Cowork têm **autonomia total** no trabalho do projeto Nio, **sem perguntar antes**: app NIOGEN (developers.facebook.com: webhooks,
campos assinados, casos de uso, permissões), WABA Nio, BM Dharma, CA Nio — inclusive **ativar, pausar e mudar verba de campanha**, apagar,
remover ou desinscrever, e mexer no app Renata Digital quando a tarefa da Nio exigir (ampliado no mesmo dia: "Pode incluir tudo!").
**Obrigação em troca:** sinalizar ao Ricardo **logo depois** o que foi feito (mensagem no chat), e registrar no Diário (+ INFRA se mudou endereço/ID).
Limites que não dependem desta regra (regras de segurança do próprio Claude): ele não digita senha nem token em campo de site (o Ricardo cola),
não executa pagamento nem transferência, e, no navegador, ainda pode confirmar na hora um clique irreversível. Tarefas da **Vero** fora do
projeto Nio seguem o `CLAUDE.md` da raiz.


### 17. Venda e resultado primeiro (Ricardo, 08/11/2026 13h09)
"Vender é mais importante do que seguir todas essas regras. Precisamos pensar em venda, resultado!"
- A meta (30 · 50 · 70 planos) manda. Toda proposta começa por **quanto ela aproxima da venda** e **quão rápido**.
- **Cautela interna não segura venda:** esperar aprendizado da Meta, medição "limpa", volume mínimo de conversas, uma mudança por vez, documentação antes de agir — nada disso adia o que vende mais. Faz agora, mede depois, corrige rápido.
- **Velocidade no contato:** lead que chegou é atendido e retomado o mais rápido que o contrato permite. Na dúvida entre esperar e agir, **agir**.
- **O que trava de verdade é pouco:** o contrato com a Nio (sem desconto fora da tabela, biometria, não vender a quem já é cliente — porque quebrar vira estorno/multa e anula a venda) e segurança (regra 5). O resto das regras deste arquivo é **forma de trabalhar**: se atrasar uma venda, a venda vence e o Ricardo é avisado.
- Governança (Diário, INFRA, guia, Trello) se faz **junto ou logo depois**, nunca **antes** do que vende.

### 18. Tudo é resultado: o NIOGEN caça venda, receita e caixa o tempo todo (Ricardo, 10/11/2026 13h55)
"O Niogen deve ser um sistema que busca oportunidade de venda, de receita e de controle financeiro a todo momento. Tudo dele deve ser voltado em RESULTADO!"
- Toda tela responde primeiro **quanto isso vira de venda ou receita e o que fazer agora para pegar** — números em planos e R$, não em atividade.
- **O sistema procura a oportunidade sozinho** (lead esquentável, janela de 24 h fechando, objeção parada, fatura em aberto antes do D+5, M-10 em risco,
  estorno evitável, comissão não conciliada, verba Meta sem retorno) e a manda para o **Live** (antiga Minha vez) com o motivo, o valor em jogo e a ação de 1 clique.
  Oportunidade não entra no contador de obrigação: tem selo próprio (🔥).
- Cartão = **quem · onde está · quanto vale · o que fazer**. Informação que não muda uma decisão vai para a gaveta.
- Sucesso de uma entrega = planos vendidos, receita confirmada, estorno ou inadimplência evitados. "Deploy ok" ou tela bonita não contam.
- Todo prompt do Code (regra 9) diz **que resultado persegue e como medir em 7 dias**; toda oportunidade criada registra se foi usada e no que deu.
- Limites que continuam: contrato (regra 1) e segurança (regra 5).

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
