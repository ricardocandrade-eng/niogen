# NIOGEN no Portal (extensão do Chrome)

Painel lateral do NIOGEN sobre o portal PAP da Nio. Mostra as vendas **Prontas para o portal** e **escreve nos campos** da etapa aberta
do Novo Pedido. **Quem clica em tudo é a pessoa.** Prompt 28 · exceção de 06/11 21h19 da regra 5 do `CLAUDE.md`.

## Instalar (sem Chrome Web Store)
1. `chrome://extensions` → ligue **Modo do desenvolvedor**.
2. **Carregar sem compactação** → pasta `C:\Users\ricar\Documents\GitHub\niogen\extensao`.
3. A pasta precisa do `config.js` (cópia do `docs/config.js`; está no `.gitignore`). Sem ele o painel não conecta.
4. Abra `https://pap.niointernet.com.br/administrativo/…` logado no portal e clique no ícone **N** da extensão (painel lateral).
5. Atualizar = `git pull` + recarregar a extensão em `chrome://extensions` + F5 no portal.

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
- **Nunca clica em botão do portal** (`content.js › cliqueSeguro`: só opção de lista e caixa de marcar; botão, link e `[role=button]` são recusados).
- Não toca em login, token, `localStorage` do portal, rede do portal (`pap-api…`) nem no sufixo cifrado — só o DOM da página aberta por você.
- Dado de cliente só em memória do painel; sessão do Supabase (só os tokens) em `chrome.storage.local` por até **30 dias** desde o login (0.4.0 — antes era `storage.session`, que o Chrome apaga ao fechar); nenhum dado de cliente em storage, console ou log. **Sair** apaga a sessão na hora.
- Supabase: anon key + login do usuário (RLS). **Nunca** service role.
- `eventos_venda` guarda só o fato: `portal_extensao_preenchido` (etapa, nº de campos), `portal_extensao_destacado` e `pedido_aberto_portal`. Nunca o conteúdo.
- Avisos do portal ("já existe outro pedido", "Celular já utilizado anteriormente", "Endereço fora da área") aparecem no painel; a extensão não sugere seguir.

## Banco (migration `0051_portal_extensao.sql`)
`portal_prontas()` · `dados_portal(venda)` · `portal_gravar_pedido(venda, pedido)` — todas `SECURITY INVOKER` (vale o RLS de quem está logado).
