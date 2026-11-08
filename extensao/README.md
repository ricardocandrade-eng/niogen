# NIOGEN no Portal (extensão do Chrome)

Painel lateral do NIOGEN sobre o portal PAP da Nio. Mostra as vendas **Prontas para o portal** e **escreve nos campos** da etapa aberta
do Novo Pedido. **Quem clica em tudo é a pessoa.** Prompt 28 · exceção de 06/11 21h19 da regra 5 do `CLAUDE.md`.

## Instalar (sem Chrome Web Store)
1. `chrome://extensions` → ligue **Modo do desenvolvedor**.
2. **Carregar sem compactação** → pasta `C:\Users\ricar\Documents\GitHub\niogen\extensao`.
3. A pasta precisa do `config.js` (cópia do `docs/config.js`; está no `.gitignore`). Sem ele o painel não conecta.
4. Abra `https://pap.niointernet.com.br/administrativo/…` logado no portal e clique no ícone **N** da extensão (painel lateral).
5. Atualizar = `git pull` + recarregar a extensão em `chrome://extensions` + F5 no portal.

## Como usar
1. Entre com o e-mail e a senha **do NIOGEN** (não é o login do portal).
2. Escolha a venda em **Prontas para o portal** (faltas em vermelho).
3. No portal, abra **Novo Pedido**. O painel acompanha a etapa aberta (ou troque no seletor).
4. **Preencher esta etapa** escreve os campos. Confira, e clique **você** em Buscar / Continuar / Avançar.
5. Ao terminar o pedido, digite o **Número do pedido** no painel e **Gravar no NIOGEN**.

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
- **Orelha Conversa** (na venda ou na conversa aberta): a negociação da Mari/time/cliente (`mari_turnos`), só leitura, com **Abrir no Chatwoot**.
- Banco: nenhuma migration — leitura direta de `mari_conversas`, `mari_turnos` e `config_planos` pelo RLS (admin/backoffice).
  Na conversa sem venda nada é gravado (nem `eventos_venda`).

## Regras do código (não negociáveis)
- **Nunca clica em botão do portal** (`content.js › cliqueSeguro`: só opção de lista e caixa de marcar; botão, link e `[role=button]` são recusados).
- Não toca em login, token, `localStorage` do portal, rede do portal (`pap-api…`) nem no sufixo cifrado — só o DOM da página aberta por você.
- Dado de cliente só em memória do painel; sessão do Supabase em `chrome.storage.session`; nada em `storage.local`, console ou log.
- Supabase: anon key + login do usuário (RLS). **Nunca** service role.
- `eventos_venda` guarda só o fato: `portal_extensao_preenchido` (etapa, nº de campos), `portal_extensao_destacado` e `pedido_aberto_portal`. Nunca o conteúdo.
- Avisos do portal ("já existe outro pedido", "Celular já utilizado anteriormente", "Endereço fora da área") aparecem no painel; a extensão não sugere seguir.

## Banco (migration `0051_portal_extensao.sql`)
`portal_prontas()` · `dados_portal(venda)` · `portal_gravar_pedido(venda, pedido)` — todas `SECURITY INVOKER` (vale o RLS de quem está logado).
