-- NIOGEN | supabase/migrations/0276_divergencias_superadas.sql | 18/11/2026 — Claude Code / Opus 5.5
-- Reta final, itens 3 (C7) e 4 (nio:biometria:pendente) — seção 17 do diagnóstico, Ricardo 18/11 "De acordo com todos".
-- O que a produção mostrou (18/11 ~08h, só leitura): as 17 linhas de v_porta_divergencias são TODAS de antes do conserto.
--   · C7 — 16 × time_respondeu "Mari atendendo" → ficou "Mari atendendo" (17/11 19h23–20h52 UTC). A 0266 (17/11 ~21h05 UTC) fez a
--     situação 3 derivável pelo dono; desde então todo time_respondeu de "Mari atendendo" foi para "Com o time", de acordo com a tabela.
--   · biometria — 1 × nio:biometria:pendente "qualificado_credito" → "qualificado_biometria" (17/11 23h30 UTC). A regra veio na 0272
--     (nio:biometria:* @ andamento → {=, qualificado_biometria}); depois dela, 0 divergências.
-- Esta migration: a divergência consertada fica marcada (porta_sombra.superada = qual migration explicou) e sai da lista; o diário não
-- perde nada. porta_divergencias_rever() refaz a marca para o que a tabela de hoje já prevê — rodar depois de toda mudança na tabela.
-- Regra 20: (1) nenhuma situação nova; (2) nada parado — só a lista fica limpa; (3) nenhum estado de lead muda; (4) fonte única: o
-- diário da porta; (5) conferência: cenário X19 no portão (Responder e resposta no Chatwoot dão a vez ao time; superada não aparece).
begin;

alter table public.porta_sombra add column if not exists superada text;

-- o que a tabela de hoje já prevê (a regra faltava e foi escrita depois): marca com a regra que explica
create or replace function public.porta_divergencias_rever()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.porta_sombra s
     set superada = 'a tabela de hoje prevê (' || coalesce(x.regra, '?') || ')'
    from (select d.id, p.regra
            from public.porta_sombra d
            cross join lateral public.porta_prever(d.antes, d.evento) p
           where d.concorda is distinct from true and d.superada is null
             and d.antes is not null and d.depois is not null
             and p.aceito and public._porta_bate(d.antes, d.depois, p.para)) x
   where s.id = x.id;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.porta_divergencias_rever() from public, anon, authenticated;

-- C7: o sistema estava errado e foi consertado (0266). Marca só o que veio antes da 0266 — a primeira anotação da situação 3
-- ("Com o time — esperando o cliente", que só existe desde a 0266) marca a hora em que ela entrou.
update public.porta_sombra s
   set superada = '0266: C7 — responder sem assumir passou a dar a vez ao time'
 where s.evento = 'time_respondeu' and s.antes = 'mari_atendendo' and s.depois = 'mari_atendendo'
   and s.concorda is distinct from true and s.superada is null
   and s.em < (select min(em) from public.porta_sombra where 'time_esperando' in (antes, depois));

select public.porta_divergencias_rever();

create or replace view public.v_porta_divergencias with (security_invoker = true) as
select s.id, s.em, s.evento, s.origem, s.conversa_id, s.venda_id, coalesce(c.nome_contato, '') as nome,
       s.antes, s.depois, s.aceito, s.para, s.frase, s.regra, s.sistema_ok, s.sistema_resumo,
       case when s.aceito is null then 'sem regra: caminho que ninguém desenhou'
            when s.aceito then 'a tabela previa ' || array_to_string(s.para, ' ou ') || ', o sistema levou a ' || coalesce(s.depois, '?')
            else 'a tabela recusaria ("' || s.frase || '"), o sistema levou a ' || coalesce(s.depois, '?') end as divergencia
  from public.porta_sombra s
  left join public.mari_conversas c on c.id = s.conversa_id
 where s.concorda is distinct from true
   and s.superada is null
   and coalesce(c.telefone, '') not like '5500000000%' and coalesce(c.canal, 'whatsapp') <> 'teste';
grant select on public.v_porta_divergencias to authenticated;

commit;
