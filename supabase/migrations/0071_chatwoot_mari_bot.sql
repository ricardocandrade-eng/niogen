-- NIOGEN | supabase/migrations/0071_chatwoot_mari_bot.sql | 09/11/2026 — Claude Code (docs/Prompt_mari_agent_bot_chatwoot_081126_2310.md)
-- Pendência 33: a Mari fala no Chatwoot como Agent Bot "Mari" (conta 195428), não mais com o token do perfil do Ricardo.
-- Agent Bot não ocupa assento; a fala aparece com nome e foto dela e sender.type = agent_bot.
-- Regra 15: o id do bot é config do parceiro (Dharma), não fica fixo em nó. O token do bot NÃO vem para cá:
-- mora só na credencial n8n "Chatwoot Nio — Mari bot" (e o Chatwoot o mostra ao admin em Configurações › Bots).
-- O bot NÃO está ligado à caixa 153431 (o envio funciona sem ligação; ligar faria a conversa nova nascer Pendente).

insert into public.config_links (chave, nome, url, observacao)
values ('chatwoot_mari_bot',
        'Chatwoot Nio · Agent Bot "Mari" (id 11823)',
        'https://app.chatwoot.com/app/accounts/195428/settings/agent-bots',
        'Agent Bot id 11823 na conta 195428. Token só na credencial n8n "Chatwoot Nio — Mari bot" (mari_principal e '
        'mari_cadencia). Não ligado à caixa 153431. O bot não edita contato (401) — o nó 9k · Chatwoot nome usa o '
        'token do Ricardo ("Chatwoot Nio"). Criado em 09/11/2026.')
on conflict (chave) do update
  set nome = excluded.nome, url = excluded.url, observacao = excluded.observacao, atualizado_em = now();
