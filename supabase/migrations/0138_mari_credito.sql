-- NIOGEN | supabase/migrations/0138_mari_credito.sql | 12/11/2026 — Claude Code
-- Ricardo, 12/11 (regra 5 revista: "a consulta de crédito pode sair da Mari, pelo operador, sempre com o titular autorizando —
-- a Mari pede a autorização na conversa e grava quando e com qual frase o cliente autorizou") + "Sim, constrói".
-- Fluxo: e-mail confirmado → a Mari pergunta (botões "Sim, autorizo" · "Não") → "Sim" grava credito_autorizado_em + a frase →
-- o n8n mari_credito (a cada 2 min) consulta pelo operador (endereço padrão + celular do WhatsApp + e-mail do cliente; ~40 s)
-- → credito_resultado na conversa e em operador_consultas (CPF só mascarado). A Mari usa o resultado (só cartão → oferece o
-- cartão ou outro titular; negado → humano) e a nota do handoff leva o resultado. A VENDA não é gravada aqui: o crédito da
-- ficha continua sendo gravado pelo time (passa pela trava "Conferi: não é cliente nem endereço Nio").
-- TETOS: 1 consulta por conversa; 3 CPFs diferentes por telefone em 7 dias; telefones de teste fora; só com autorização.

alter table public.mari_conversas add column if not exists credito_autorizado_em timestamptz;
alter table public.mari_conversas add column if not exists credito_autorizacao_frase text;
alter table public.mari_conversas add column if not exists credito_recusado_em timestamptz;
alter table public.mari_conversas add column if not exists credito_resultado text;
alter table public.mari_conversas add column if not exists credito_formas jsonb;
alter table public.mari_conversas add column if not exists credito_em timestamptz;
alter table public.mari_conversas add column if not exists credito_consultas int not null default 0;
alter table public.mari_conversas drop constraint if exists mari_conversas_credito_resultado_check;
alter table public.mari_conversas add constraint mari_conversas_credito_resultado_check
  check (credito_resultado is null or credito_resultado in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente',
                                                            'negado', 'pedido_em_andamento', 'nao_decidiu'));

create or replace function public.mari_credito_pendentes(p_limite int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  with alvo as (
    select c.id from public.mari_conversas c
     where c.credito_autorizado_em is not null
       and c.credito_em is null and c.credito_consultas < 1
       and public._cpf_ok(c.dados->>'cpf')
       and coalesce(c.dados->>'email', '') ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
       and coalesce(c.nao_contatar, false) = false
       and coalesce(c.telefone, '') !~ '^55000000'
       and c.updated_at > now() - interval '12 hours'
       and (select count(distinct regexp_replace(o.dados->>'cpf', '\D', '', 'g')) from public.mari_conversas o
             where o.telefone = c.telefone and o.credito_consultas > 0 and o.credito_em > now() - interval '7 days'
               and regexp_replace(o.dados->>'cpf', '\D', '', 'g') <> regexp_replace(c.dados->>'cpf', '\D', '', 'g')) < 3
     order by c.credito_autorizado_em
     limit greatest(1, least(p_limite, 2))
     for update skip locked
  ), marcadas as (
    update public.mari_conversas c set credito_consultas = c.credito_consultas + 1, credito_em = now()
      from alvo where c.id = alvo.id
    returning c.id, c.dados, c.telefone
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'conversa_id', id,
           'cpf', regexp_replace(dados->>'cpf', '\D', '', 'g'),
           'celular', right(regexp_replace(coalesce(dados->>'telefone', telefone, ''), '\D', '', 'g'), 11),
           'email', lower(dados->>'email'))), '[]'::jsonb)
    into v from marcadas;
  return v;
end $$;
revoke all on function public.mari_credito_pendentes(int) from public, anon, authenticated;
grant execute on function public.mari_credito_pendentes(int) to service_role;

create or replace function public.mari_credito_gravar(p_conversa uuid, p_saida jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_op text := p_saida->>'resultado'; v text; c record;
begin
  if coalesce(p_saida->>'retry', '') = 'true' then
    update public.mari_conversas set credito_em = null, credito_consultas = greatest(credito_consultas - 1, 0)
     where id = p_conversa and credito_resultado is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  v := case when v_op in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'pedido_em_andamento')
            then v_op else 'nao_decidiu' end;
  update public.mari_conversas set credito_resultado = v, credito_em = now(),
         credito_formas = case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' end,
         nio_pedido_aberto = case when v = 'pedido_em_andamento' then 'sim' else nio_pedido_aberto end
   where id = p_conversa returning id, venda_id, credito_autorizado_em, credito_autorizacao_frase into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cpf_mascara, resultado, detalhe, ms)
  values ('credito', 'mari', p_conversa, c.venda_id, p_saida->>'cpf_mascara', coalesce(v_op, 'erro'),
          jsonb_strip_nulls(jsonb_build_object('formas', p_saida->'formas_liberadas', 'motivo', p_saida->>'motivo',
            'cache', p_saida->'cache', 'etapa_parada', p_saida->'etapa_parada',
            'autorizado_em', c.credito_autorizado_em, 'autorizacao_frase', c.credito_autorizacao_frase)),
          nullif(p_saida->>'ms', '')::int);
  return jsonb_build_object('ok', true, 'resultado', v);
end $$;
revoke all on function public.mari_credito_gravar(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.mari_credito_gravar(uuid, jsonb) to service_role;
