-- NIOGEN | supabase/migrations/0065_conteudos.sql | 08/11/2026 — Claude Code (docs/Prompt_pendencias_venda_081126_0005.md, Parte 2)
-- Por quê: o Guia do Backoffice vira uma tela do NIOGEN (guia.html), sempre igual ao arquivo do Drive
-- (docs/BACKOFFICE_chatwoot_com_a_mari_051126_1045.md, fonte única). O repo niogen é PÚBLICO: o texto do guia não vai para o
-- repo nem para o GitHub Pages — fica aqui, legível só para quem está logado.
-- O quê: tabela conteudos (uma linha por texto publicado; hoje só 'guia_backoffice'). Leitura: authenticated. Escrita: só
-- service_role (o script niogen/scripts/publicar_guia.py grava pelo CLI do Supabase, sem chave em arquivo).

create table if not exists public.conteudos (
  chave         text primary key,
  titulo        text not null,
  markdown      text not null,
  rev           text,                       -- texto da última linha "rev." do cabeçalho do arquivo
  hash          text not null,              -- sha256 do markdown publicado (o script só publica se mudou)
  publicado_em  timestamptz not null default now(),
  publicado_por text,                       -- quem rodou o script (usuário do Windows / "Claude Code")
  parceiro_id   text not null default 'dharma'
);
comment on table public.conteudos is 'Textos publicados no NIOGEN (0065). guia_backoffice = Guia do Backoffice, fonte única no Drive; publicar com scripts/publicar_guia.py.';

alter table public.conteudos enable row level security;
drop policy if exists conteudos_ler on public.conteudos;
create policy conteudos_ler on public.conteudos for select to authenticated using (true);
revoke all on public.conteudos from anon, authenticated;
grant select on public.conteudos to authenticated;
