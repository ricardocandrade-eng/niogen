# NIOGEN no Portal (extensão do Chrome)

Painel lateral do NIOGEN sobre o portal PAP da Nio. Mostra as vendas **Prontas para o portal** e **escreve nos campos** da etapa aberta
do Novo Pedido. Desde a **0.6.0** (12/11) também **conduz as Etapas 1–5 até o Resumo e para sem salvar** — o clique que grava o pedido,
a biometria e o pagamento são da pessoa. Prompt 28 · regra 5 do `CLAUDE.md` (rev. 12/11/2026).

## Instalar (sem Chrome Web Store)
1. `chrome://extensions` → ligue **Modo do desenvolvedor**.
2. **Carregar sem compactação** → pasta `C:\Users\ricar\Documents\GitHub\niogen\extensao`.
3. A pasta precisa do `config.js` (cópia do `docs/config.js`; está no `.gitignore`). Sem ele o painel não conecta.
4. Abra `https://pap.niointernet.com.br/administrativo/…` logado no portal e clique no ícone **N** da extensão (painel lateral).
5. Atualizar = `git pull` + recarregar a extensão em `chrome://extensions` + F5 no portal.

## Conduzir até o Resumo (0.6.0, 12/11/2026) — `docs/Prompt_extensao_ate_resumo_121126_0100.md`
Regra 5 do `CLAUDE.md` (rev. 12/11): na sessão do humano logado no portal, a extensão percorre as Etapas 1–5 do Novo Pedido e **para no
Resumo sem salvar**. Só o humano clica no que grava o pedido ou manda algo ao cliente (botão final do Resumo, Abrir OS, biometria, link de
pagamento, agendamento). Uso autorizado pelo Rogério (Nio) — Ricardo, 12/11 00h52.

- **Onde:** painel da venda, quadro **Conduzir até o Resumo** (só admin/backoffice; vendedor não vê). Habilita com CEP, número (ou "sem
  número"), CPF, celular, e-mail, plano e forma de pagamento — e, se a venda tiver aviso de possível duplicado, a conferência de recompra
  marcada (etapa 3). O checkbox "o titular autorizou a análise de crédito" do prompt **não foi posto**: a regra 5 revista no mesmo dia
  (12/11 ~10h) tirou a pergunta de autorização ("nem o WhatsApp oficial da Nio pede") — a linha da LGPD não muda.
- **Modos** (lembrado em `chrome.storage.local`): **Passo a passo** (padrão: antes de cada BOTÃO do portal o painel mostra "Vou clicar em
  ‹botão› na Etapa N" + Seguir/Parar; opções de lista e caixas de marcar não perguntam) e **Direto**. **■ Parar** sempre visível.
- **O que faz:** E1 UF/PDV (espera até 12 s) + matrícula `TT837725` → Avançar · E2 CEP, número ou "Sem número" → Buscar → endereço da lista
  pelo número exato (52 ≠ 520) ou o único → complemento pela lista fechada (nunca troca de unidade) → referência → Avançar → modal
  "disponível" → registra **Viável** no NIOGEN → Continuar · E3 CPF → Buscar (1× "Tentar novamente" no erro da Receita) → aviso se o nome
  diverge (não para) → Avançar → duplicidade · E4 celular e e-mail (2×), aceite de comunicação por WhatsApp (o portal exige) → Avançar →
  popup do crédito · **o "Continuar" desse popup manda a biometria ao cliente: a extensão PAUSA ("clique você") e retoma quando a Etapa 5
  abrir**, aí registra o crédito no NIOGEN · E5 forma da venda (boleto/cartão; **DACC para**), oferta casada por nome + velocidade + R$/mês
  da `config_planos` (nenhuma ou várias → pausa "escolha você" + Seguir), "Com fidelidade", adicionais da venda (pausa: marque você),
  Avançar · **E6 Resumo: nenhum clique** — o painel mostra o texto do Resumo, a venda ao lado e o nome do botão final.
- **Para sempre que:** popup inesperado (texto vai ao painel), "Pedido encontrado"/"já existe outro pedido" (recompra), celular ou e-mail
  recusado, crédito negado/pendente/só cartão com venda em boleto, DACC, tela pedindo cartão, oferta que não casa (pausa), 40 s sem o portal
  responder (60 s nas consultas lentas: endereço, viabilidade, Receita, duplicidade, crédito), o humano mexeu na página fora de uma pausa
  (`mousedown`/`keydown` reais), Parar.
- **Travas** (`travas.js`, funções puras; `node extensao/testar_travas.mjs` tem que dar VERDE):
  - clique: lista branca por etapa (E1 Avançar · E2 Buscar, Avançar, opção de endereço/complemento, caixa "Sem número" · E3 Buscar, Avançar
    · E4 Avançar, caixa do aceite · E5 Avançar, Selecionar/Escolher, radios), popup só "Continuar" do modal "disponível" (E2) e "Tentar
    novamente" (E3), nunca em popup que fala de biometria/link/envio/pagamento; lista negra sempre (salvar interesse, abrir os, enviar,
    finalizar, confirmar, concluir pedido, checkout, carregar, reenviar, seguir fora da área, consultar outro cpf, fechar/gerar pedido, agendar);
    E6+ nada.
  - rede: regras de **sessão** do `declarativeNetRequest` com `tabIds` = só a aba do portal, ligadas pelo painel ao começar e removidas ao
    parar/chegar ao Resumo (e pelo `background.js` se a aba fechar). Barram `aberturaos`, `checkout`, `carrinho/…enviar`, `biometria`,
    `/pagamento/`, `reenviolink`, `dadosBancarios`, `SAVE_LEAD`, `prevenda`, `portabilidade` e, da Etapa 3 em diante, `interesse`. Liberadas:
    `portabilidadenovafibra/consulta…` (a Etapa 5 quebra sem elas) e **só a leitura (GET) de `aberturaos/carrinho/<id>`**, caso o Resumo
    precise dela para aparecer. Regra disparada → `onRuleMatchedDebug` (extensão sem compactação, permissão `declarativeNetRequestFeedback`)
    para a condução e mostra o caminho.
- **Registro:** `eventos_venda` tipo `portal_extensao_conduzido` (`etapa_parada`, `motivo` resumo/popup/recompra/credito/oferta/dacc/timeout/
  humano/parou/trava, `modo`, `duracao_s`, popup e texto redigidos — sem CPF, telefone ou e-mail). Viável e crédito vão pelo
  `backoffice_momento`, como os botões de sempre.
- **Testar a trava** (no quadro): pede ao content.js, pelo caminho da condução, para clicar em "Seguir fora da área", "Salvar interesse",
  "Finalizar pedido" e "Abrir OS" — todos recusados (log no console da aba).
- **Ainda não conferido no portal real** (aceite 2 do prompt, com o Ricardo na tela): o DOM da Etapa 5 (como a oferta se seleciona) e da
  Etapa 6 (o nome do botão final e se o Resumo lê o carrinho). Na primeira condução, anotar aqui o texto de cada popup e do botão final.

## Painel da venda (0.5.0, 10/11/2026) — jornada fixa, sem rolagem
1. Entre com o e-mail e a senha **do NIOGEN** (não é o login do portal) e escolha a venda em **Prontas para o portal**.
2. **Jornada das 7 etapas sempre à vista**, no alto do painel: a etapa aberta no portal **acende sozinha** (●); as já feitas ficam com ✓ e
   **continuam acesas até "Concluir"** (se o portal voltar uma etapa, ela vira "aberta" e segue com ✓). "N faltam" em vermelho = dado que o
   NIOGEN não tem. Ao lado da 2 e da 3 aparece o resultado registrado (Viável, Aprovado…).
3. **Etapa em foco** (a única parte que rola, por dentro): linhas da etapa, avisos do portal, **Preencher esta etapa** (1–4) ou
   **Destacar no portal** (5), resultados e o registro no NIOGEN (viabilidade na 2, crédito na 3). Clique numa etapa da jornada para ver
   outra; **↺ seguir o portal** volta ao automático. Quem clica em Buscar / Continuar / Avançar no portal é **você**.
4. **📋 Todos os dados** (rodapé): camada com os dados de todas as etapas, cada linha com **Copiar** (no formato que o portal aceita) e
   **Copiar tudo** (texto simples `Rótulo: valor`, agrupado por etapa). Fecha com × ou Esc. Nunca traz banco, agência, conta, cartão nem senha.
5. **Pedido (OS) e agendamento não são gravados aqui** (decisão do Ricardo, 10/11 22h45): na etapa 7, **Abrir a ficha** leva à ficha da venda
   no NIOGEN (`NIOGEN_URL` do `config.js`; padrão `https://niogen.dharmatelecom.com.br`).
6. **Concluir** (rodapé) fecha a venda e apaga as luzes guardadas. Fechar e reabrir o painel, ou sair e voltar em **← Vendas**, não perde as luzes
   (ficam em `chrome.storage.session`: só números de etapa e resultados, nunca dado de cliente).
- Permissão nova: `clipboardWrite` (para copiar). Atualizar: `git pull` + recarregar a extensão em `chrome://extensions` + F5 no portal.

| Etapa | A extensão faz |
|---|---|
| 1 Identificação PDV | UF · PDV `1069521 - DHARMA TELECOM LTDA` · matrícula **sempre `TT837725` (Joysse)** — decisão do Ricardo, 06/11 (escolhe a opção da lista) |
| 2 Viabilidade | CEP · número (ou "Sem número") · referência · complemento. **Para antes de Buscar** |
| 3 Cadastro | CPF/CNPJ. **Para antes de Buscar**. Nascimento e nome da mãe: não coletamos |
| 4 Contato | celular (2×) · e-mail (2×). Aceite de WhatsApp: nunca marca |
| 5 Pagamento/Ofertas | **só destaca** plano, "Com fidelidade", adicionais, forma de pagamento. Crédito, banco, agência e conta: nunca |
| 6 Resumo · 7 Abrir OS | nada; mostra o checklist do fechamento obrigatório e o período preferido |

## Novidades da 0.2.0 (08/11/2026)
- **Rolagem:** depois de **Preencher esta etapa**, o painel desce sozinho até a etapa seguinte quando a etapa fechou (tudo escrito,
  ou o que falta é dado que o NIOGEN não tem). Se algum campo ainda pede você (não apareceu, lista ambígua, portal recusou), fica na
  mesma etapa mostrando o resultado. O recado "Pronto — confira…" fica num aviso fixo no rodapé.
- **Conversas da Mari** (orelha ao lado de *Prontas para o portal*, só admin/backoffice): conversas em andamento (ativas ou com o time,
  Chatwoot não resolvido, sem pedido aberto) para **consultar o portal antes de a venda ser qualificada**. A extensão usa o que a Mari já
  coletou (CEP, número, referência, CPF, contato, plano). Sem venda não há "Gravar no NIOGEN"; se a conversa já virou venda, botão **Abrir a venda**.
- **Orelha "💬 Conversa (Chatwoot)"** (ao lado de "Preencher no portal", na venda ou na conversa aberta; atalho **💬 Ler conversa** na lista): a negociação da Mari/time/cliente (`mari_turnos`), só leitura, com **Abrir no Chatwoot**.
- **Atualizar** (0.2.1, no topo do painel): recarrega do NIOGEN o que está aberto — dados da venda/conversa e a negociação — sem perder a
  etapa, os resultados do preenchimento nem o nº do pedido digitado; na tela inicial, recarrega as duas listas.
- Banco: nenhuma migration — leitura direta de `mari_conversas`, `mari_turnos` e `config_planos` pelo RLS (admin/backoffice).
  Na conversa sem venda nada é gravado (nem `eventos_venda`).

## Novidades da 0.4.0 (10/11/2026)
- **Status do portal → NIOGEN:** abra **Histórico de Pedidos** no portal e, no painel, **Atualizar status no NIOGEN**. A extensão roda
  Venda × 7 status (Aguardando tratamento · Contato Agendado · Gross · Não Venda · Pedido Gerado · Sem contato com o cliente · Venda),
  Pré-Venda e Interesse, nos **últimos 30 dias** (o máximo que o portal aceita), lê todas as páginas e manda o lote em **uma** chamada
  `portal_status_registrar` (migration `0105`). ~75 s; não mexa no portal enquanto lê. Mostra "N pedidos · X mudanças · Y sem venda · Z alertas".
- **Lista branca de cliques** (`content.js › cliqueFiltro`, exceção do Ricardo 10/11 11h02): botão Filtros, campos e opções do filtro,
  datas, Filtrar e próxima página. Detalhar, Carregar pedido, Salvar, Atualizar Pedido, Novo Pedido, Funil e Tramitações: recusados
  (e registrados no console). Botão **Testar a trava de cliques** no painel prova isso.
- **Login dura 30 dias** (pedido do Ricardo, 10/11): não precisa entrar de novo ao fechar o Chrome.

## Regras do código (não negociáveis)
- **Preencher esta etapa** nunca clica em botão do portal (`content.js › cliqueSeguro`: só opção de lista e caixa de marcar). A **condução**
  (0.6.0) clica só pela lista branca de `travas.js` (`conduzirClique`) e nunca no Resumo nem depois.
- Não toca em login, token, `localStorage` do portal, rede do portal (`pap-api…`) nem no sufixo cifrado — só o DOM da página aberta por você.
- Dado de cliente só em memória do painel; sessão do Supabase (só os tokens) em `chrome.storage.local` por até **30 dias** desde o login (0.4.0 — antes era `storage.session`, que o Chrome apaga ao fechar); nenhum dado de cliente em storage, console ou log. **Sair** apaga a sessão na hora.
- Supabase: anon key + login do usuário (RLS). **Nunca** service role.
- `eventos_venda` guarda só o fato: `portal_extensao_preenchido` (etapa, nº de campos), `portal_extensao_destacado` e `pedido_aberto_portal`. Nunca o conteúdo.
- Avisos do portal ("já existe outro pedido", "Celular já utilizado anteriormente", "Endereço fora da área") aparecem no painel; a extensão não sugere seguir.

## Banco (migration `0051_portal_extensao.sql`)
`portal_prontas()` · `dados_portal(venda)` · `portal_gravar_pedido(venda, pedido)` — todas `SECURITY INVOKER` (vale o RLS de quem está logado).
