-- NIOGEN | supabase/migrations/0068_mari_portao_verba_nov.sql | 08/11/2026 — Claude Code (Onda 1.2, prompt
-- docs/Prompt_portao_mari_alarme_081126_0100.md — Partes 1 e 3; a Parte 2, alarme de silêncio, está em espera)
--
-- 1) mari_portao_rodadas — registro de cada rodada da bateria fixa "portao" (tests/mari_portao.py) e de cada publicação
--    no mari_principal feita com --sem-portao. O deploy_mari.py só publica na produção se existir uma rodada 'bateria'
--    100 % verde, com o mesmo hash do código que vai subir, nas últimas 6 h. Módulo Mari (desligável); regra 15: parceiro_id.
--    Escrita só pelo CLI (postgres / service role); usuário logado no NIOGEN pode ler.
-- 2) verba_mes de novembro: R$ 2.000 → R$ 5.000 (Ricardo, 08/11 00h58: C2 segue a R$ 200/dia; CJ_JF sem gasto mínimo).

create table if not exists public.mari_portao_rodadas (
  id           bigint generated always as identity primary key,
  quando       timestamptz not null default now(),
  tipo         text not null default 'bateria' check (tipo in ('bateria', 'sem_portao')),
  hash_codigo  text not null,
  modelo       text,
  verdes       int not null default 0,
  vermelhos    int not null default 0,
  total        int not null default 0,
  custo_usd    numeric(10,4),
  completa     boolean not null default false,   -- false = parou antes do fim (teto de custo, erro, Ctrl+C)
  motivo       text,                              -- só no tipo 'sem_portao' (obrigatório) ou na rodada interrompida
  detalhe      jsonb not null default '{}'::jsonb, -- resultado por cenário e por P#, sem telefone/CPF/texto de conversa
  parceiro_id  text not null default 'dharma',
  constraint mari_portao_sem_portao_motivo check (tipo <> 'sem_portao' or coalesce(btrim(motivo), '') <> '')
);
comment on table public.mari_portao_rodadas is
  'Portão da Mari (0068): rodadas da bateria fixa "portao" no ensaio e publicações --sem-portao. Deploy na produção exige rodada verde do mesmo hash em 6 h.';
create index if not exists mari_portao_rodadas_hash_idx on public.mari_portao_rodadas (hash_codigo, quando desc);

alter table public.mari_portao_rodadas enable row level security;
drop policy if exists mari_portao_rodadas_ler on public.mari_portao_rodadas;
create policy mari_portao_rodadas_ler on public.mari_portao_rodadas for select to authenticated using (true);
revoke all on public.mari_portao_rodadas from anon, authenticated;
grant select on public.mari_portao_rodadas to authenticated;

update public.config_meta_ads_regras
   set valor = 5000,
       descricao = 'Verba de Meta Ads do mês (R$) exibida na tela Meta Ads › Desempenho. Nov/26: R$ 5.000 (C2 a R$ 200/dia; Ricardo, 08/11)'
 where chave = 'verba_mes';
