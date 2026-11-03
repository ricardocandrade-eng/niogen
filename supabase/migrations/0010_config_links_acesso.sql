-- NIOGEN | supabase/migrations/0010_config_links_acesso.sql | 03/11/2026
-- Acesso ao DFV Nio dentro do NIOGEN (decisão do Ricardo, 03/11): usuário e as 2 senhas do painel ficam no banco,
-- visíveis só para usuário logado (RLS de config_links: meu_perfil() is not null). São um filtro do relatório da Nio,
-- não uma conta. O VALOR nunca entra em arquivo versionado: é gravado pelo CLI, fora do repo (o niogen é público).
-- Exceção registrada na regra 5 do CLAUDE.md.

alter table public.config_links
  add column if not exists acesso jsonb;   -- {usuario, senha1, senha2, passos}

comment on column public.config_links.acesso is
  'Credenciais de filtro de painel da Nio (ex.: DFV). Preenchido fora do repo pelo CLI; leitura só para usuário logado.';
