-- NIOGEN | supabase/migrations/0131_mari_viabilidade_auto.sql | 12/11/2026 — Claude Code
-- Ricardo, 12/11 ~02h ("Sim, ataca" os achados graves da 1ª auditoria da Mari):
--   Achado 1 — venda coletada inteira e depois descartada por "sem cobertura na rua": nos últimos 7 dias NENHUMA conversa da Mari
--   teve a viabilidade oficial consultada (nio_viab_resultado nulo em 55 de 55 com CEP) — o motor sempre mandava "indisponivel".
--   O operador do portal já faz a viabilidade (Etapas 0–2, sem CPF; tela Cobertura desde 11/11). Aqui: a fila que o n8n
--   mari_viabilidade lê a cada 2 min, a gravação do resultado em mari_conversas (+ nio_viab_log) e a volta à fila quando o
--   endereço muda. A Mari já lê nio_viab_resultado (Bloco 9: viavel → "a Nio atende o seu endereço ✅"; o resto não muda a fala,
--   regra do Ricardo de 05/11) e o handoff já leva o resultado para a venda — o time recebe a venda com a viabilidade pronta.
--   Achado 3 — "mensagens fora de ordem" era defeito da própria auditoria: as falas iam ordenadas por "DD/MM HH:MI" (sem segundos),
--   e as do mesmo minuto chegavam embaralhadas ao Claude. Ordem agora pelo instante exato, com segundos.
--   sou_service_role(): a edge credito-consulta passa a aceitar o n8n (service role) só para viabilidade e status.

create or replace function public.sou_service_role() returns boolean language sql stable as $$
  select coalesce(auth.role() = 'service_role', false)
$$;
grant execute on function public.sou_service_role() to anon, authenticated, service_role;

-- Fila: endereço confirmado (CEP de 8 dígitos + número), nunca consultado, conversa viva nas últimas 12 h.
-- Marca nio_viab_em ao pegar (não repega); se o operador falhar, o n8n grava 'indisponivel'.
create or replace function public.mari_viab_pendentes(p_limite int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  with alvo as (
    select c.id from public.mari_conversas c
     where regexp_replace(coalesce(c.cep, ''), '\D', '', 'g') ~ '^\d{8}$'
       and nullif(btrim(coalesce(c.numero, '')), '') is not null
       and c.nio_viab_em is null
       and coalesce(c.nao_contatar, false) = false
       and coalesce(c.dentro_area, true)
       -- 12 h: sem enxurrada do passado (o operador tem teto de 60 viabilidades/h, dividido com a tela Cobertura)
       and c.updated_at > now() - interval '12 hours'
       and (c.venda_id is null or c.handoff_em > now() - interval '12 hours')
     order by c.updated_at desc
     limit greatest(1, least(p_limite, 5))
     for update skip locked
  ), marcadas as (
    update public.mari_conversas c set nio_viab_em = now()
      from alvo where c.id = alvo.id
    returning c.id, c.cep, c.numero, c.complemento, c.dados
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'conversa_id', id,
           'cep', regexp_replace(cep, '\D', '', 'g'),
           'numero', btrim(numero),
           -- só complemento de unidade (apto 403, bloco 2, casa B): "Casa", "nenhum" ou referência não vão ao portal
           'complemento', case when complemento ~* '(ap|apto|apartamento|bloco|bl|sala|loja|casa\s+[a-z0-9]\b|fundos|\d)' and complemento !~* '^\s*(casa|nenhum|nao|não|sem)\s*$'
                               then left(btrim(complemento), 60) else '' end)), '[]'::jsonb)
    into v from marcadas;
  return v;
end $$;
revoke all on function public.mari_viab_pendentes(int) from public, anon, authenticated;
grant execute on function public.mari_viab_pendentes(int) to service_role;

-- Grava o resultado do operador: viavel | sem_viabilidade → iguais; complemento_fora_lista → nao_encontrado; o resto → indisponivel.
create or replace function public.mari_viab_gravar(p_conversa uuid, p_saida jsonb, p_ms int default null, p_erro text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_res text; v_op text := p_saida->>'resultado'; c record;
begin
  -- Operador ocupado (fila cheia, teto da hora, fora do ar): volta para a fila, sem log, tenta na próxima rodada.
  if coalesce(p_saida->>'retry', '') = 'true' then
    update public.mari_conversas set nio_viab_em = null where id = p_conversa and nio_viab_resultado is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  v_res := case v_op when 'viavel' then 'viavel' when 'sem_viabilidade' then 'sem_viabilidade'
                     when 'complemento_fora_lista' then 'nao_encontrado' else 'indisponivel' end;
  update public.mari_conversas set nio_viab_resultado = v_res,
         nio_viab_velocidade = case when v_res = 'viavel' then nullif(p_saida->>'velocidade', '') end,
         nio_viab_em = now()
   where id = p_conversa
  returning id, cep, numero, complemento into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  insert into public.nio_viab_log (origem, conversa_id, cep, numero, complemento, saida, resultado, duracao_ms, erro)
  values ('mari', p_conversa, c.cep, c.numero, c.complemento,
          p_saida - 'cpf_mascara', v_res, p_ms, coalesce(p_erro, case when v_res = 'indisponivel' then left(coalesce(p_saida->>'motivo', v_op), 300) end));
  return jsonb_build_object('ok', true, 'resultado', v_res, 'operador', v_op);
end $$;
revoke all on function public.mari_viab_gravar(uuid, jsonb, int, text) from public, anon, authenticated;
grant execute on function public.mari_viab_gravar(uuid, jsonb, int, text) to service_role;

-- Endereço mudou (CEP, número ou complemento) → viabilidade volta à fila.
create or replace function public._mari_viab_endereco_mudou() returns trigger language plpgsql as $$
begin
  if (new.cep is distinct from old.cep or new.numero is distinct from old.numero or new.complemento is distinct from old.complemento)
     and old.nio_viab_em is not null then
    new.nio_viab_em := null; new.nio_viab_resultado := null; new.nio_viab_velocidade := null;
  end if;
  return new;
end $$;
drop trigger if exists mari_viab_endereco_mudou on public.mari_conversas;
create trigger mari_viab_endereco_mudou before update of cep, numero, complemento on public.mari_conversas
  for each row execute function public._mari_viab_endereco_mudou();

-- Auditoria: falas na ordem exata (com segundos).
create or replace function public._auditoria_mari_dados(p_de timestamptz, p_ate timestamptz, p_conversa uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  with cs as (
    select c.* from public.mari_conversas c
     where (p_conversa is not null and c.id = p_conversa)
        or (p_conversa is null and exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.created_at between p_de and p_ate))
     order by c.updated_at desc nulls last
     limit case when p_conversa is null then 60 else 1 end
  ), conv as (
    select jsonb_build_object(
      'conversa_id', c.id, 'nome', split_part(coalesce(c.nome_contato, ''), ' ', 1),
      'cidade', c.cidade, 'cluster', c.cluster, 'origem', c.origem, 'etapa', c.etapa, 'status', c.status,
      'dentro_area', c.dentro_area, 'viabilidade_nio', c.nio_viab_resultado, 'plano_escolhido', c.plano_escolhido,
      'forma_pagamento', c.forma_pagamento, 'handoff_motivo', c.handoff_motivo, 'handoff_em', c.handoff_em,
      'virou_venda', c.venda_id is not null, 'com_humano', (c.humano_atribuido is not null or c.time_atribuido is not null),
      'nao_contatar', c.nao_contatar, 'cadencia_passo', c.cadencia_passo, 'cadencia_proximo_em', c.cadencia_proximo_em,
      'falas', (select coalesce(jsonb_agg(x.f order by x.ts, x.id), '[]'::jsonb) from (
          select t.created_at ts, t.id, jsonb_build_object(
            'em', to_char(t.created_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI:SS'),
            'quem', t.papel,
            'texto', left(public._auditoria_mascarar(t.texto), 600),
            'tags', nullif(case when jsonb_typeof(t.tags) = 'object' then t.tags - 'dados_coletados' - 'endereco' - 'acao_id' else null end, '{}'::jsonb),
            'latencia_s', case when t.latencia_ms is not null then round(t.latencia_ms / 1000.0, 1) end) f
          from public.mari_turnos t
         where t.conversa_id = c.id
           and t.created_at <= p_ate
           and t.created_at >= case when p_conversa is null then p_de - interval '24 hours' else p_de end
         order by t.created_at desc, t.id desc limit case when p_conversa is null then 40 else 120 end) x)
    ) j
    from cs c
  )
  select jsonb_build_object(
    'conversas', (select coalesce(jsonb_agg(j), '[]'::jsonb) from conv),
    'erros', (select coalesce(jsonb_agg(jsonb_build_object(
                'em', to_char(e.created_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI:SS'), 'no', e.no_n8n,
                'conversa_id', e.conversa_id, 'mensagem', left(public._auditoria_mascarar(e.mensagem), 240),
                'texto_bloqueado', left(public._auditoria_mascarar(e.payload->>'texto_bloqueado'), 300)) order by e.created_at), '[]'::jsonb)
              from public.mari_erros e
             where e.created_at between p_de and p_ate and (p_conversa is null or e.conversa_id = p_conversa)),
    'numeros', (select jsonb_build_object(
                  'conversas', count(distinct t.conversa_id),
                  'falas_lead', count(*) filter (where t.papel = 'lead'),
                  'falas_mari', count(*) filter (where t.papel = 'mari'),
                  'falas_time', count(*) filter (where t.papel = 'humano'),
                  'toques_cadencia', count(*) filter (where t.papel = 'mari' and t.tags ? 'cadencia'),
                  'handoffs', count(*) filter (where t.papel = 'mari' and t.tags ? 'handoff'),
                  'latencia_media_s', round(avg(t.latencia_ms) filter (where t.papel = 'mari') / 1000.0, 1),
                  'latencia_max_s', round(max(t.latencia_ms) filter (where t.papel = 'mari') / 1000.0, 1),
                  'tokens_in_mari', sum(t.tokens_in), 'tokens_out_mari', sum(t.tokens_out))
                from public.mari_turnos t
               where t.created_at between p_de and p_ate and (p_conversa is null or t.conversa_id = p_conversa))
  ) into v;
  return v;
end $$;
revoke all on function public._auditoria_mari_dados(timestamptz, timestamptz, uuid) from public, anon, authenticated;
