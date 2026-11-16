-- NIOGEN | supabase/migrations/0233_unidade_a_confirmar.sql | 16/11/2026 — Claude Code / Opus 5.5
-- Pedido do Ricardo (16/11, caso Rua Rafael Merula 67, JF): o cliente disse "CS 1"/"Casa 1" e o portal só tem "Casa A" na lista
-- fechada de unidades — o operador parava com "unidade fora da lista" e a análise morria ali. Agora:
--   1. O operador (portal/credito.py, "consulta da fachada") segue com a 1ª unidade da lista SÓ para ler a viabilidade e devolve
--      'viavel' + unidade_a_confirmar. A Mari segue vendendo; o pedido (extensão) sempre usa a unidade do cliente.
--   2. mari_conversas.unidade_conferir (motivo, lista, informada, usada, autor) · unidade_conferir_em (aberta) · _conferida_em/_por.
--   3. _cobertura_unidade_marcar(): ÚNICA função que abre a conferência (regra 20.3), com motivo e autor. Motivos:
--      escolher (viável na fachada, o cliente escolhe) · nenhuma (o cliente disse "nenhuma dessas") · sem_cadastro (lista vazia).
--   4. Gatilho mari_conversas_unidade_nenhuma: dados.unidade_fora_lista = 'nenhuma' (a Mari registra) → motivo "nenhuma".
--   5. mari_viab_gravar: abre (escolher / sem_cadastro) ou fecha (o portal achou a unidade do cliente) a conferência.
--   6. _mari_viab_endereco_mudou: unidade nova → consulta nova, a conferência fecha.
--   7. cobertura_unidade_conferida(conversa): o "Conferi" do time (admin/backoffice).
--   8. live_conferir (n): linha "Unidade a confirmar", dono backoffice, prazo 4 h. conferencia_itens 20.
-- Regra 20: (1) etapa/status/destino não mudam; a vez segue da Mari, o prazo é o da conferência · (2) todo motivo tem prazo de 4 h
-- e dono (backoffice), na Live · (3) só _cobertura_unidade_marcar e o gatilho do "nenhuma" abrem; o "Conferi" e a consulta nova
-- fecham · (4) a lista vem do portal (fonte única) · (5) conferencia_itens 20.
-- Corpos das funções recriadas = produção (pg_get_functiondef em 16/11), só com os trechos marcados 0233.

alter table public.mari_conversas
  add column if not exists unidade_conferir      jsonb,
  add column if not exists unidade_conferir_em   timestamptz,
  add column if not exists unidade_conferida_em  timestamptz,
  add column if not exists unidade_conferida_por uuid;
comment on column public.mari_conversas.unidade_conferir_em is
  '0233: unidade a confirmar (a do cliente não bate com a lista fechada da Nio, ou não há unidade cadastrada). Null = nada a conferir.';

create or replace function public._cobertura_unidade_json(p_motivo text, p_lista jsonb, p_informada text, p_usada text, p_autor text)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object('motivo', p_motivo,
           'lista', case when jsonb_typeof(p_lista) = 'array' and jsonb_array_length(p_lista) > 0 then p_lista end,
           'lista_txt', (select left(string_agg(x, ', '), 200) from (select jsonb_array_elements_text(p_lista) as x
                          where jsonb_typeof(p_lista) = 'array' limit 12) z),
           'informada', nullif(btrim(coalesce(p_informada, '')), ''), 'usada', nullif(p_usada, ''), 'autor', p_autor, 'em', now()))
$$;
revoke all on function public._cobertura_unidade_json(text, jsonb, text, text, text) from public, anon, authenticated;

create or replace function public._cobertura_unidade_marcar(p_conversa uuid, p_motivo text, p_lista jsonb, p_informada text, p_usada text, p_autor text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_motivo not in ('escolher', 'nenhuma', 'sem_cadastro') then raise exception 'motivo desconhecido: %', p_motivo; end if;
  update public.mari_conversas c
     set unidade_conferir = public._cobertura_unidade_json(p_motivo, coalesce(p_lista, c.unidade_conferir -> 'lista'), p_informada, p_usada, p_autor),
         unidade_conferir_em = case when c.unidade_conferir_em is not null and c.unidade_conferir ->> 'motivo' = p_motivo
                                    then c.unidade_conferir_em else now() end,   -- a mesma pendência não reinicia o prazo
         unidade_conferida_em = null, unidade_conferida_por = null
   where c.id = p_conversa;
end $$;
revoke all on function public._cobertura_unidade_marcar(uuid, text, jsonb, text, text, text) from public, anon, authenticated;

-- 4. "nenhuma dessas": a Mari grava dados.unidade_fora_lista = 'nenhuma' (n07) → a conferência vira "pedir o cadastro"
create or replace function public._unidade_nenhuma_antes()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.dados ->> 'unidade_fora_lista' = 'nenhuma' and old.dados ->> 'unidade_fora_lista' is distinct from 'nenhuma' then
    new.unidade_conferir := public._cobertura_unidade_json('nenhuma', coalesce(old.unidade_conferir -> 'lista', old.cobertura_detalhe -> 'unidades'),
                                                           coalesce(old.unidade_conferir ->> 'informada', old.complemento), null, 'mari_cliente');
    new.unidade_conferir_em := now(); new.unidade_conferida_em := null; new.unidade_conferida_por := null;
  end if;
  return new;
end $$;
drop trigger if exists mari_conversas_unidade_nenhuma on public.mari_conversas;
create trigger mari_conversas_unidade_nenhuma before update of dados on public.mari_conversas
  for each row execute function public._unidade_nenhuma_antes();

create or replace function public.cobertura_unidade_conferida(p_conversa uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  update public.mari_conversas
     set unidade_conferida_em = now(), unidade_conferida_por = auth.uid(), unidade_conferir_em = null,
         unidade_conferir = coalesce(unidade_conferir, '{}'::jsonb) || jsonb_build_object('conferida_em', now(), 'conferida_por', auth.uid())
   where id = p_conversa and unidade_conferir_em is not null;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'resumo', case when n = 1 then 'Unidade conferida' else 'Nada a conferir nesta conversa' end);
end $$;
revoke all on function public.cobertura_unidade_conferida(uuid) from public, anon;
grant execute on function public.cobertura_unidade_conferida(uuid) to authenticated;

-- 5. mari_viab_gravar
CREATE OR REPLACE FUNCTION public.mari_viab_gravar(p_conversa uuid, p_saida jsonb, p_dfv jsonb DEFAULT NULL::jsonb, p_erro text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_res text; v_op text := p_saida->>'resultado'; v_dfv text; v_dec text; c record; v_conf text;
        v_uac jsonb := p_saida -> 'unidade_a_confirmar';   -- 0233: viável na fachada com a unidade emprestada
begin
  if coalesce(p_saida->>'retry', '') = 'true' and p_dfv is null then
    update public.mari_conversas set nio_viab_em = null, viab_consultas = greatest(viab_consultas - 1, 0)
     where id = p_conversa and nio_viab_resultado is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  if coalesce(p_saida->>'retry', '') = 'true' then v_op := null; end if;   -- portal não decidiu; o DFV pode decidir
  v_res := case v_op when 'viavel' then 'viavel' when 'sem_viabilidade' then 'sem_viabilidade'
                     when 'complemento_fora_lista' then 'nao_encontrado' else 'indisponivel' end;
  v_dfv := public._dfv_veredito(p_dfv);
  v_dec := public.cobertura_decidir(v_op, v_dfv);   -- rua_divergente = portal não decidiu: o DFV decide (a Mari segue o fluxo normal)
  -- 0202: portal em outra rua, ou portal "sem viabilidade" com a própria fachada viável no DFV → o time confere a rua
  v_conf := case when v_op = 'rua_divergente' then 'rua_divergente'
                 when v_op = 'sem_viabilidade' and p_dfv ->> 'match' = 'exato' and coalesce(p_dfv ->> 'fonte', '') <> 'base_congelada'
                 then 'portal_nao_dfv_exato' end;
  update public.mari_conversas set nio_viab_resultado = v_res,
         nio_viab_velocidade = case when v_res = 'viavel' then nullif(p_saida->>'velocidade', '') end,
         nio_viab_em = now(), cobertura_decisao = v_dec, cobertura_em = now(),
         cobertura_detalhe = jsonb_strip_nulls(jsonb_build_object(
           'portal', v_op, 'dfv', v_dfv, 'velocidade', p_saida->>'velocidade',
           'portal_texto', p_saida->'endereco'->>'viabilidade', 'portal_motivo', p_saida->>'motivo',
           'unidades', case when v_op = 'complemento_fora_lista' or v_uac is not null then p_saida->'opcoes'->'lista' end,
           'unidade_a_confirmar', case when v_uac is not null then true end,
           'dfv_fachadas_cep', p_dfv->'total_fachadas_no_cep', 'dfv_fonte', coalesce(p_dfv->>'fonte', case when p_dfv is not null then 'ao_vivo' end),
           'dfv_match', p_dfv->>'match', 'portal_endereco', p_saida->'endereco'->>'resolvido', 'conferir_rua', v_conf))
   where id = p_conversa
  returning id, cep, numero, complemento, venda_id into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  if v_conf is not null then
    perform public._cobertura_rua_marcar(p_conversa, v_conf, p_saida->'endereco'->>'resolvido', p_saida->'endereco'->>'esperado',
                                         p_dfv->'fachada'->>'logradouro', 'mari_viab_gravar');
  elsif v_op is not null then   -- o portal decidiu de novo sem conflito: a conferência pendente fecha sozinha
    update public.mari_conversas set rua_conferir_em = null where id = p_conversa and rua_conferir_em is not null;
  end if;
  -- 0233: unidade a confirmar. Viável com a unidade emprestada → o cliente escolhe (a Mari mostra a lista); o portal sem
  -- NENHUMA unidade cadastrada → o time pede o cadastro à Nio. A unidade do cliente bateu → a conferência fecha sozinha.
  if v_op = 'viavel' and v_uac is not null then
    perform public._cobertura_unidade_marcar(p_conversa, 'escolher', p_saida->'opcoes'->'lista', v_uac->>'informada', v_uac->>'usada', 'mari_viab_gravar');
  elsif v_op = 'complemento_fora_lista' and p_saida->'opcoes'->>'situacao' = 'nenhuma' then
    perform public._cobertura_unidade_marcar(p_conversa, 'sem_cadastro', '[]'::jsonb, c.complemento, null, 'mari_viab_gravar');
  elsif v_op = 'viavel' then
    update public.mari_conversas set unidade_conferir_em = null where id = p_conversa and unidade_conferir_em is not null;
  end if;
  insert into public.nio_viab_log (origem, conversa_id, cep, numero, complemento, saida, resultado, erro)
  values ('mari', p_conversa, c.cep, c.numero, c.complemento, p_saida - 'cpf_mascara', v_res,
          coalesce(p_erro, case when v_res = 'indisponivel' then left(coalesce(p_saida->>'motivo', v_op, 'portal não decidiu'), 300) end));
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cep, numero, complemento, resultado, decisao, detalhe, ms)
  values ('viabilidade', 'mari', p_conversa, c.venda_id, c.cep, c.numero, c.complemento, coalesce(v_op, 'nao_decidiu'), v_dec,
          jsonb_build_object('portal', p_saida - 'cpf_mascara' - 'pedido_portal', 'dfv_veredito', v_dfv), nullif(p_saida->>'ms', '')::int);
  if p_dfv is not null then
    insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cep, numero, complemento, resultado, decisao, detalhe)
    values ('dfv', 'mari', p_conversa, c.venda_id, c.cep, c.numero, c.complemento, v_dfv, v_dec, p_dfv - 'opcoes' - 'unidades');
  end if;
  return jsonb_build_object('ok', true, 'resultado', v_res, 'operador', v_op, 'dfv', v_dfv, 'decisao', v_dec, 'conferir_rua', v_conf);
end $function$;

-- 6. _mari_viab_endereco_mudou
CREATE OR REPLACE FUNCTION public._mari_viab_endereco_mudou()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if (new.cep is distinct from old.cep or new.numero is distinct from old.numero or new.complemento is distinct from old.complemento)
     and old.nio_viab_em is not null then
    new.nio_viab_em := null; new.nio_viab_resultado := null; new.nio_viab_velocidade := null;
    new.cobertura_decisao := null; new.cobertura_detalhe := null; new.cobertura_em := null;
    new.rua_conferir_em := null;   -- 0202: endereço novo → consulta nova; a conferência da rua velha fecha
    new.unidade_conferir_em := null;   -- 0233: unidade nova → consulta nova; a conferência da unidade fecha
  end if;
  return new;
end $function$;

-- 8. live_conferir (n) e conferencia_itens 20
CREATE OR REPLACE FUNCTION public.live_conferir()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_horas numeric := coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'envelhecimento_dono_horas'), 24);
  v_docs  int := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15);
  r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return '[]'::jsonb; end if;
  with nomes as (
    select c.id, c.venda_id,
           coalesce(nullif(btrim(c.dados ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Contato') as nome,
           c.chatwoot_agente, c.funil_alerta, c.funil_alerta_em, coalesce(c.nao_contatar, false) as nao_contatar
      from public.mari_conversas c
     where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
  ),
  itens as (
    -- (a) ação do Chatwoot que falhou 3 vezes e não foi refeita depois
    select 'acao_falhou' as tipo, a.id::text as chave, a.conversa_id, a.venda_id, n.nome, a.criada_em as desde, 1 as ordem,
           format('O Chatwoot não obedeceu: %s%s', case a.tipo when 'resolver' then 'resolver / reabrir' when 'etiquetas' then 'etiqueta'
                    when 'atribuir' then 'atribuir' when 'desatribuir' then 'tirar a atribuição' when 'nota' then 'nota privada'
                    when 'mensagem' then 'mensagem ao cliente' else a.tipo end,
                  coalesce(' — ' || left(a.erro, 120), '')) as texto
      from public.chatwoot_acoes a
      left join nomes n on n.id = a.conversa_id
     where a.status = 'erro' and a.criada_em > now() - interval '7 days'
       and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                         and b.status = 'feita' and b.criada_em > a.criada_em)
    union all
    -- (b) conversa mexida direto no Chatwoot
    select 'fora_niogen', n.id::text, n.id, n.venda_id, n.nome, n.funil_alerta_em, 2,
           case n.funil_alerta
             when 'resolvida_fora_niogen' then 'Resolvida direto no Chatwoot, sem destino — registre a Saída (ou reabra)'
             when 'mensagem_fora_niogen' then case when n.nao_contatar   -- 0183
               then 'O time respondeu direto no Chatwoot a quem pediu para NÃO ser contatado — não escrever de novo; abrir a conversa no NIOGEN e conferir'
               else 'Respondida direto no Chatwoot — responda pelo NIOGEN para a venda andar' end
             when 'atribuida_fora_niogen' then 'Atribuída direto no Chatwoot a ' || coalesce(n.chatwoot_agente, 'alguém') || ' — a Mari calou; assuma pelo NIOGEN ou devolva para a Mari'
             else 'Adiada direto no Chatwoot — some da fila sem data de volta; use ⏸ Aguardar no NIOGEN' end
      from nomes n where n.funil_alerta is not null
    union all
    -- (c) conversa em andamento com dono e sem nenhuma fala há mais de N horas
    select case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then 'handoff_parado' else 'dono_parado' end,
           c.id::text, c.id, c.venda_id, n.nome, u.ult, 3,
           format(case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido
                       then 'Passada pela Mari%s e ninguém pegou há %s — assumir, devolver para a Mari ou registrar a Saída'
                       else 'Com %s e parada há %s — retomar, devolver para a Mari ou registrar a Saída' end,
                  case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then ''
                       else coalesce(c.chatwoot_agente, 'o time') end,
                  case when now() - u.ult >= interval '48 hours' then floor(extract(epoch from now() - u.ult) / 86400)::int || ' dias'
                       else floor(extract(epoch from now() - u.ult) / 3600)::int || ' h' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
      left join public.vendas v on v.id = c.venda_id
      cross join lateral (select max(t.created_at) as ult from public.mari_turnos t
                           where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano')) u
     where coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
       and (c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null or c.status = 'handoff_realizado')   -- 0155
       and not coalesce(c.nao_contatar, false)
       and c.quadro_encerrada_motivo is null
       and (c.espera_ate is null or c.espera_ate <= now())
       and coalesce(c.chatwoot_status, 'open') <> 'snoozed'
       and (v.id is null or v.status in ('0_qualificado', '1_vendido'))
       and not exists (select 1 from public.venda_pendencias vp where vp.venda_id = c.venda_id and vp.encerrada_em is null)
       and u.ult is not null and u.ult < now() - make_interval(mins => (v_horas * 60)::int)
    union all
    -- (d) documentos à Nio: 15 dias depois da instalação
    select 'docs_prazo', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), v.instalado_em, 4,
           case when v.instalado_em + make_interval(days => v_docs) < now()
                  then format('Documentos à Nio ATRASADOS — o prazo era %s', to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'))
                else format('Documentos à Nio até %s (%s dias depois da instalação)',
                            to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'), v_docs) end
      from public.vendas v
     where v.status in ('3_instalado', '4_ativo_provisorio') and v.instalado_em is not null and v.docs_entregues_em is null
       and v.instalado_em > now() - interval '90 days'
    union all
    -- (e) 0155: cliente já instalado escreveu e ninguém do time respondeu — pós-venda
    select 'pos_venda', c.id::text, c.id, c.venda_id, n.nome, u.ult_lead, 2,
           'Cliente já instalado escreveu — é pós-venda: responda você (a Mari não responde cliente instalado)'
      from public.mari_conversas c
      join nomes n on n.id = c.id
      cross join lateral (select max(t.created_at) filter (where t.papel = 'lead') as ult_lead,
                                 max(t.created_at) filter (where t.papel = 'humano') as ult_hum
                            from public.mari_turnos t where t.conversa_id = c.id) u
     where c.funil_destino = 'instalada' and u.ult_lead is not null and u.ult_lead > now() - interval '14 days'
       and u.ult_lead > coalesce(u.ult_hum, '-infinity') and u.ult_lead > coalesce(c.dispensada_em, '-infinity')
    union all
    -- (f) 0157: saiu com pedido ou OS aberta na Nio e ninguém confirmou o cancelamento no portal
    select 'cancelar_nio', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), ev.em, 2,
           'Saiu com pedido aberto na Nio' || coalesce(' (nº ' || coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) || ')', '')
             || ' — cancele no portal e confirme aqui. Pedido vivo trava o CPF e o endereço (recompra = multa de R$ 500)'
      from public.vendas v
      cross join lateral (select max(e.criado_em) as em from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'status') ev
     where v.status = 'saida' and v.instalado_em is null
       and (nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null)
       and coalesce(v.motivo_saida, '') not ilike 'Nio:%'
       and v.criado_em > now() - interval '90 days'
       and not exists (select 1 from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'cancelado_no_portal')
    union all
    -- (g) 0157 (D1): qualificado em andamento, sem fala do cliente há mais de N dias
    select case when l.tem_pedido_nio then 'silencio_com_pedido' else 'silencio_qualificado' end,
           l.lead_id, l.conversa_id, l.venda_id, l.nome, l.ultima_msg_lead_at, 3,
           case when l.tem_pedido_nio
                then format('Sem resposta do cliente há %s dias e com pedido aberto na Nio — insistir (ligar) ou cancelar na Nio e registrar a Saída',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int)
                else format('Qualificado e sem resposta do cliente há %s dias — retomar ou registrar a Saída · Sem resposta',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int) end
      from public.v_leads l
     where l.destino = 'em_andamento' and l.etapa in ('qualificado', 'instalacao') and l.status <> 'aguardando_instalacao'
       and not l.em_espera and l.venda_id is not null
       and l.ultima_msg_lead_at is not null
       and l.ultima_msg_lead_at < now() - make_interval(days => coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'saida_silencio_dias'), 15))    union all
    -- (h) 0157: saída com data de volta que chegou (recusou · momento, fachada em revisão) — vale também para conversa sem venda
    select 'volta_hoje', l.lead_id, l.conversa_id, l.venda_id, l.nome, l.volta_em::timestamptz, 3,
           format('Combinou voltar em %s (%s%s) — retomar o contato ou reabrir', to_char(l.volta_em, 'DD/MM'), l.saida_nome, coalesce(' · ' || l.saida_sub, ''))
      from public.v_leads l
     where l.destino = 'saida' and l.volta_em is not null
       and l.volta_em <= (now() at time zone 'America/Sao_Paulo')::date and l.volta_em > (now() at time zone 'America/Sao_Paulo')::date - 30
       and l.saida_motivo <> 'nao_contatar'
    union all
    -- (i) 0168: exceção da OS na Nio (Operador de OS e OSAB), com o valor em jogo e a ação
    select 'os_excecao', a.pedido, null::uuid, a.venda_id,
           coalesce(nullif(btrim(v.cliente_nome), ''), 'OS ' || a.pedido), coalesce(a.excecao_desde, a.mudou_em), 1,
           format('OS %s na Nio: %s%s%s — %s', a.pedido, coalesce(a.status_ordem, 'sem status'),
                  coalesce(' · ' || nullif(btrim(a.motivo_cancelamento), ''), ''),
                  case when coalesce(v.comissao_prevista, 0) > 0
                       then ' · R$ ' || replace(to_char(v.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end,
                  coalesce(a.acao, 'conferir na Consulta OS'))
      from public.os_andamento a
      left join public.vendas v on v.id = a.venda_id
     where a.excecao
    union all
    -- (i2) 0196: biometria da Nio fora do ar (suspeita automática pelo GED360 ou marcada pelo time)
    select 'biometria_fora', q.id::text, null::uuid, null::uuid, 'Biometria da Nio', q.inicio, 1,
           format('%s desde %s%s · %s venda(s) esperando a biometria — peça à Nio a dispensa e marque "Nio dispensou" em cada ficha; quando voltar, marque "Voltou" (Operações › Biometria)',
                  case when q.confirmada_em is null then 'Biometria da Nio parece fora do ar (GED360 sem biometria nova há ' || q.horas_sem_envio || ' h no horário comercial · confirme no grupo)'
                       else 'Biometria da Nio FORA DO AR' end,
                  to_char(q.inicio at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                  case when q.origem = 'manual' then ' (marcada por ' || coalesce((select u.nome from public.usuarios u where u.id = q.aberta_por), 'time') || ')' else '' end,
                  (select count(*) from public.vendas v where v.status in ('1_vendido', '2_aguardando_instalacao') and v.biometria_status in ('pendente', 'com_risco')))
      from public.biometria_quedas q
     where q.fim is null
    union all
    -- (j) 0175: a conta de hoje não fechou (conferência diária, etapa 6) — uma linha por falha
    select 'conta_nao_fecha', x ->> 'codigo', null::uuid, null::uuid, 'Conferência do dia', c.rodada_em, 1,
           format('A conta não fecha — %s: %s%s', x ->> 'nome', x ->> 'texto', coalesce(' → ' || nullif(x ->> 'fazer', ''), ''))
      from public.conferencias_diarias c
      cross join lateral jsonb_array_elements(c.itens) x
     where c.dia = (now() at time zone 'America/Sao_Paulo')::date and x ->> 'nivel' = 'falha'
    union all
    -- (k) 0182: risco de recompra — venda em andamento com CPF ou endereço repetido (só aviso; decisão do Ricardo, 13/11)
    select 'risco_recompra', rr.venda_id::text, null::uuid, rr.venda_id, coalesce(nullif(btrim(rr.cliente_nome), ''), 'Cliente'), rr.criado_em, 2,
           format('Risco de recompra — %s%s — conferir no portal ANTES de gravar o pedido e marcar "Conferi" na ficha (cliente ou endereço já na base = estorno de 100 %%; recompra = multa de R$ 500)',
                  rr.motivo, case when coalesce(rr.comissao_prevista, 0) > 0
                                  then ' · R$ ' || replace(to_char(rr.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end)
      from public.v_venda_risco_recompra rr
    union all
    -- (l) 0202: o portal consultou outra rua (ou disse "sem viabilidade" com a fachada viável no DFV) — o time confere a rua
    select 'conferir_rua', c.id::text, c.id, c.venda_id, n.nome, c.rua_conferir_em,
           case when c.rua_conferir_em < now() - interval '4 hours' then 1 else 2 end,
           format('%s — cliente: %s, nº %s · portal: %s%s. Refaça na Cobertura escolhendo a rua do cliente e marque "Conferi"%s',
                  case c.rua_conferir ->> 'motivo' when 'rua_divergente' then 'O portal consultou OUTRA RUA'
                       else 'O portal disse sem viabilidade, mas a fachada está viável no DFV' end,
                  coalesce(nullif(c.rua_conferir ->> 'esperada', ''), c.endereco_cep ->> 'logradouro', '?'), coalesce(c.numero, '?'),
                  coalesce(nullif(split_part(c.rua_conferir ->> 'portal', ',', 1), ''), '?'),
                  coalesce(' · DFV: ' || nullif(c.rua_conferir ->> 'dfv', ''), ''),
                  case when c.rua_conferir_em < now() - interval '4 hours' then ' · PRAZO DE 4 h VENCIDO' else ' (prazo: 4 h)' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.rua_conferir_em is not null
    union all
    -- (n) 0233: unidade a confirmar — o portal tem lista fechada de unidades e a do cliente não bate (ou ele disse "nenhuma
    -- dessas", ou o endereço não tem nenhuma cadastrada). Dono: backoffice. Prazo: 4 h.
    select 'conferir_unidade', c.id::text, c.id, c.venda_id, n.nome, c.unidade_conferir_em,
           case when c.unidade_conferir_em < now() - interval '4 hours' or c.unidade_conferir ->> 'motivo' <> 'escolher' then 1 else 2 end,
           format('%s · %s, nº %s%s',
                  case c.unidade_conferir ->> 'motivo'
                       when 'escolher' then format('Unidade a confirmar — viável no endereço; o cliente disse "%s" e o portal tem: %s. A Mari está perguntando qual é; se ele não escolher, confirme com ele. No pedido, escolha a unidade DELE (nunca outra)',
                                                   coalesce(nullif(c.unidade_conferir ->> 'informada', ''), 'nada'), coalesce(nullif(c.unidade_conferir ->> 'lista_txt', ''), '?'))
                       when 'nenhuma' then format('Unidade fora do cadastro da Nio — o cliente disse que a unidade dele não é nenhuma de: %s. Peça à Nio o cadastro da unidade (formulário) e marque "Conferi"',
                                                  coalesce(nullif(c.unidade_conferir ->> 'lista_txt', ''), '?'))
                       else format('Endereço sem unidade cadastrada na Nio (complemento "%s") — peça à Nio o cadastro da unidade (formulário) e marque "Conferi"',
                                   coalesce(nullif(c.unidade_conferir ->> 'informada', ''), c.complemento, '?')) end,
                  coalesce(c.endereco_cep ->> 'logradouro', 'CEP ' || c.cep, '?'), coalesce(c.numero, '?'),
                  case when c.unidade_conferir_em < now() - interval '4 hours' then ' · PRAZO DE 4 h VENCIDO' else ' (prazo: 4 h)' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.unidade_conferir_em is not null
    union all
    -- (m) 0210: o robô do GED360 está barrado (2+ leituras seguidas com erro) — sem ele ninguém fica sabendo da biometria
    select 'ged360_barrado', 'ged360', null::uuid, null::uuid, 'Robô do GED360', g.desde, 1,
           case when g.erro ilike '%simult%'
                then format('O robô do GED360 não lê desde %s: alguém entrou no GED360 com o login do robô ("logins simultâneos"). Saia do GED360 e use "⟳ Consultar no GED360" na ficha — sem o robô, biometria aprovada não avisa ninguém',
                            to_char(g.desde at time zone 'America/Sao_Paulo', 'HH24:MI'))
                else format('O robô do GED360 não lê desde %s (%s leituras com erro: %s) — biometria aprovada não avisa ninguém até voltar',
                            to_char(g.desde at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), g.n, left(g.erro, 120)) end
      from (select (select min(l.lida_em) from public.ged360_leituras l
                     where not l.ok and l.lida_em > coalesce((select max(k.lida_em) from public.ged360_leituras k where k.ok), '-infinity')) as desde,
                   (select count(*) from public.ged360_leituras l
                     where not l.ok and l.lida_em > coalesce((select max(k.lida_em) from public.ged360_leituras k where k.ok), '-infinity')) as n,
                   (select l.erro from public.ged360_leituras l order by l.lida_em desc limit 1) as erro,
                   (select l.ok from public.ged360_leituras l order by l.lida_em desc limit 1) as ultima_ok) g
     where g.ultima_ok = false and g.n >= 2
  )
  select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'chave', chave, 'conversa_id', conversa_id, 'venda_id', venda_id,
                                               'nome', nome, 'desde', desde, 'texto', texto) order by ordem, desde), '[]'::jsonb)
    into r from itens;
  return r;
end;
$function$;

CREATE OR REPLACE FUNCTION public.conferencia_itens(p_parceiro text DEFAULT 'dharma'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  it     jsonb := '[]'::jsonb;
  n      int;
  n2     int;
  ex     text;
  v_tot  int;
  v_soma int;
begin
  if not public._os_pode_gravar() then   -- admin, backoffice, chave de serviço ou CLI
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;

  -- 1. A soma dos destinos é o total de leads
  select count(*) into v_tot from public.v_leads;
  select coalesce(sum(c), 0) into v_soma from (select count(*) c from public.v_leads where destino is not null group by destino) x;
  it := it || jsonb_build_object('codigo', 'soma_destinos', 'nome', 'Soma dos destinos = total de leads',
    'nivel', case when v_tot = v_soma then 'ok' else 'falha' end, 'n', v_tot - v_soma,
    'texto', format('%s leads; os destinos somam %s', v_tot, v_soma),
    'fazer', case when v_tot = v_soma then null else 'Há lead sem destino: avisar o Claude Code (é defeito da v_leads).' end);

  -- 2. Lead em andamento sem vez / sem status · saída sem motivo
  select count(*), string_agg(nome, ', ' order by ultima_em desc) filter (where rn <= 5) into n, ex
    from (select nome, ultima_em, row_number() over (order by ultima_em desc) rn from public.v_leads
           where destino = 'em_andamento' and (vez is null or status is null)) x;
  it := it || jsonb_build_object('codigo', 'lead_sem_vez', 'nome', 'Todo lead em andamento tem status e vez',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todos com status e de quem é a vez' else format('%s lead(s) sem status ou sem vez: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Abrir cada um na Leads e registrar o que falta; se o sistema não deixar, avisar o Claude Code.' end);

  select count(*), string_agg(nome, ', ' order by ultima_em desc) filter (where rn <= 5) into n, ex
    from (select nome, ultima_em, row_number() over (order by ultima_em desc) rn from public.v_leads
           where destino = 'saida' and saida_motivo is null) x;
  it := it || jsonb_build_object('codigo', 'saida_sem_motivo', 'nome', 'Toda saída tem motivo',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as saídas com motivo da lista única' else format('%s saída(s) sem motivo: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Abrir a ficha e registrar o motivo da Saída.' end);

  -- 3. Prazo vencido (ninguém parado em silêncio): fecha, mas é para olhar hoje
  select count(*) into n from public.v_leads where destino = 'em_andamento' and atrasado and not em_espera;
  it := it || jsonb_build_object('codigo', 'atrasados', 'nome', 'Leads com o prazo da vez vencido',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead com prazo vencido' else format('%s lead(s) com o prazo vencido', n) end,
    'fazer', case when n = 0 then null else 'Leads › aba Precisam de ação.' end);

  -- 4. NIOGEN × Nio — venda sem pedido
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') filter (where rn <= 5) into n, ex
    from (select cliente_nome, row_number() over (order by criado_em desc) rn from public.vendas
           where status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio')
             and coalesce(nullif(btrim(nio_os), ''), nullif(btrim(nio_pedido), '')) is null) x;
  it := it || jsonb_build_object('codigo', 'venda_sem_pedido', 'nome', 'Toda venda tem o nº do pedido da Nio',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as vendas com pedido' else format('%s venda(s) sem nº de pedido: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Gravar o nº do pedido do portal na ficha.' end);

  -- 5. NIOGEN × Nio — OS aberta que o Operador de OS nunca leu (há mais de 6 h)
  select count(*), string_agg(ped, ', ') filter (where rn <= 5) into n, ex
    from (select coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) as ped,
                 row_number() over (order by v.criado_em desc) rn
            from public.vendas v
           where v.status in ('1_vendido', '2_aguardando_instalacao')
             and coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) ~ '^\d{8}$'
             and coalesce(v.nio_os_em, v.nio_pedido_em, v.vendido_em, v.criado_em) < now() - interval '6 hours'
             and not exists (select 1 from public.os_andamento a where a.parceiro_id = p_parceiro
                              and a.pedido = coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')))) x;
  it := it || jsonb_build_object('codigo', 'os_sem_leitura', 'nome', 'Toda OS aberta foi lida na Nio',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as OS abertas com leitura do Operador de OS' else format('%s OS sem nenhuma leitura: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Operações › ⟳ Varrer OS abertas. Se não ler, conferir o CPF e o nº da OS da venda.' end);

  -- 6. NIOGEN × Nio — a Nio enxerga pedido que o NIOGEN não tem
  select count(*) into n from public.portal_pedidos p
   where p.parceiro_id = p_parceiro and p.venda_id is null and upper(coalesce(p.tipo, '')) = 'VENDA'
     and p.ultima_leitura > now() - interval '30 days';
  select coalesce((i.resumo ->> 'sem_venda')::int, 0) into n2 from public.importacoes i
   where i.tipo = 'osab' and i.aplicado_em is not null order by i.aplicado_em desc limit 1;
  it := it || jsonb_build_object('codigo', 'pedido_sem_venda', 'nome', 'Pedido na Nio sem venda no NIOGEN',
    'nivel', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then 'ok' else 'atencao' end, 'n', coalesce(n, 0) + coalesce(n2, 0),
    'texto', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then 'nenhum pedido da Nio sem venda nossa'
                  else format('%s no Histórico do portal e %s no último OSAB', coalesce(n, 0), coalesce(n2, 0)) end,
    'fazer', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then null else 'Live › Conferir › casar o pedido com a venda (ou registrar a venda que falta).' end);

  -- 7. NIOGEN × Nio — texto novo da Nio sem tradução e exceção de OS parada há mais de 1 dia
  select count(*), string_agg(texto, ' · ') into n, ex from public.config_os_estados where parceiro_id = p_parceiro and estado is null;
  it := it || jsonb_build_object('codigo', 'os_texto_novo', 'nome', 'Textos da Nio traduzidos',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'todos os textos da OS conhecidos' else format('%s texto(s) sem tradução: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Ricardo para traduzir (config_os_estados). Enquanto isso a venda não muda sozinha.' end);

  select count(*) into n from public.os_andamento where parceiro_id = p_parceiro and excecao and excecao_desde < now() - interval '1 day';
  it := it || jsonb_build_object('codigo', 'os_excecao_parada', 'nome', 'Exceção de OS tratada no mesmo dia',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma exceção de OS aberta há mais de 1 dia' else format('%s exceção(ões) de OS aberta(s) há mais de 1 dia', n) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › linhas "OS … na Nio".' end);

  -- 8. NIOGEN × Chatwoot — conversa mexida fora e ação que o Chatwoot não obedeceu
  select count(*) into n from public.mari_conversas c
   where c.canal = 'whatsapp' and c.funil_alerta is not null and coalesce(c.telefone, '') not like '5500000000%';
  select count(*) into n2 from public.chatwoot_acoes a
   where a.status = 'erro' and a.criada_em > now() - interval '7 days'
     and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                       and b.status = 'feita' and b.criada_em > a.criada_em);
  it := it || jsonb_build_object('codigo', 'chatwoot', 'nome', 'NIOGEN e Chatwoot dizem a mesma coisa',
    'nivel', case when n + n2 = 0 then 'ok' else 'atencao' end, 'n', n + n2,
    'texto', case when n + n2 = 0 then 'nenhuma conversa mexida fora e nenhuma ação em erro'
                  else format('%s conversa(s) mexida(s) direto no Chatwoot · %s ação(ões) que o Chatwoot não obedeceu', n, n2) end,
    'fazer', case when n + n2 = 0 then null else 'Live › Conferir.' end);

  -- 9. Dinheiro — toda instalada tem a comissão prevista lançada
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') filter (where rn <= 5) into n, ex
    from (select v.cliente_nome, row_number() over (order by v.instalado_em desc) rn from public.vendas v
           where v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and v.instalado_em is not null
             and coalesce(v.comissao_prevista, 0) > 0
             and not exists (select 1 from public.comissao_lancamentos l where l.venda_id = v.id and l.tipo = 'prevista')) x;
  it := it || jsonb_build_object('codigo', 'instalada_sem_previsto', 'nome', 'Toda instalada tem a comissão prevista lançada',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as instaladas com o previsto na razão da comissão' else format('%s instalada(s) sem o previsto: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: a razão da comissão não lançou o previsto.' end);

  -- 10. Dinheiro — previsto × extrato (só quando houver Extrato importado e conciliado: etapa 5c)
  select count(*) into n from public.comissao_lancamentos where parceiro_id = p_parceiro and origem = 'extrato';
  it := it || jsonb_build_object('codigo', 'previsto_extrato', 'nome', 'Comissão prevista × Extrato da Nio',
    'nivel', case when n = 0 then 'sem_dado' else 'ok' end, 'n', n,
    'texto', case when n = 0 then 'o Extrato da Nio ainda não foi conciliado (etapa 5c do plano)' else format('%s lançamento(s) do extrato', n) end,
    'fazer', null);

  -- 11. 0182 — risco de recompra: venda em andamento com CPF ou endereço repetido e ainda sem o "Conferi" (só aviso)
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') into n, ex from public.v_venda_risco_recompra;
  it := it || jsonb_build_object('codigo', 'risco_recompra', 'nome', 'Venda em andamento sem risco de recompra',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma venda em andamento com CPF ou endereço repetido' else format('%s venda(s) com CPF ou endereço repetido: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Conferir no portal antes de gravar o pedido e marcar "Conferi" na ficha. Recompra = multa de R$ 500.' end);

  -- 12. 0183 — o vermelho do pulso tem dono: incidente "Mari parada" sem nenhum cliente esperando (últimas 24 h; sem crédito não conta)
  select count(*), string_agg(to_char(inicio_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), ', ' order by inicio_em) into n, ex
    from public.pulso_incidentes
   where parceiro_id = p_parceiro and elo = 'mari' and nivel = 'parado' and clientes_esperando_max = 0
     and inicio_em > now() - interval '24 hours' and coalesce(motivo, '') not ilike 'sem crédito%';
  it := it || jsonb_build_object('codigo', 'pulso_mari_sem_espera', 'nome', 'Alarme da Mari só com cliente esperando',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum alarme vermelho da Mari sem cliente esperando nas últimas 24 h'
                  else format('%s alarme(s) vermelho(s) da Mari sem cliente esperando: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o pulso acusou a Mari sem ninguém esperando (ver pulso_incidentes e Mari › Erros).' end);

  -- 13. 0186 — o caminho de volta para a Meta: evento na fila com erro, ou venda de anuncio cuja OS nao virou Purchase enviado
  select count(*), string_agg(distinct evento, ', ') into n, ex from public.meta_eventos
   where parceiro_id = p_parceiro and status = 'erro';
  -- só conta o que já passou de 1 h: a fila normal esvazia de 5 em 5 min
  select count(*) into n2 from public.v_venda_meta vm
   where vm.tem_os and vm.meta_status = 'sem_evento'
      or (vm.tem_os and vm.meta_status = 'pendente'
          and exists (select 1 from public.meta_eventos e where e.venda_id = vm.venda_id and e.evento = 'Purchase'
                        and e.criado_em < now() - interval '1 hour'));
  it := it || jsonb_build_object('codigo', 'meta_capi', 'nome', 'A Meta recebeu o que o NIOGEN gravou',
    'nivel', case when n > 0 then 'falha' when n2 > 0 then 'atencao' else 'ok' end, 'n', n + n2,
    'texto', case when n > 0 then format('%s evento(s) com erro de envio (%s)', n, left(coalesce(ex, ''), 60))
                  when n2 > 0 then format('%s venda(s) de anuncio esperando o Purchase na fila', n2)
                  else 'nenhum erro de envio e nenhuma venda de anuncio parada na fila' end,
    'fazer', case when n > 0 then 'Avisar o Claude Code: ver meta_eventos (resposta e fbtrace_id) e o workflow meta_capi_envio. Nao reenviar a mao.'
                  when n2 > 0 then 'Se passar de 1 h, o workflow meta_capi_envio pode estar parado: avisar o Claude Code.'
                  else null end);


  -- 14. 0202 — conferir a rua: o portal consultou outra rua e ninguém conferiu em 4 h
  select count(*), string_agg(coalesce(nullif(btrim(dados ->> 'nome'), ''), nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas where rua_conferir_em is not null and rua_conferir_em < now() - interval '4 hours';
  it := it || jsonb_build_object('codigo', 'conferir_rua', 'nome', 'Rua conferida em até 4 h quando o portal consulta outra rua',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma conferência de rua parada há mais de 4 h' else format('%s conversa(s) com a rua por conferir há mais de 4 h: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › "Portal: outra rua": refazer na Cobertura escolhendo a rua do cliente e marcar "Conferi".' end);

  -- 15. 0202 — a DFV ao vivo sai pela API do Power BI (o operador da VPS é só reserva)
  select count(*), count(*) filter (where coalesce(detalhe ->> 'fonte', '') <> 'api') into n, n2
    from public.operador_consultas where tipo = 'dfv'
     and criado_em > greatest(now() - interval '24 hours', timestamptz '2026-11-14 20:10-03');   -- API no ar desde 14/11 20h10
  it := it || jsonb_build_object('codigo', 'dfv_pela_api', 'nome', 'DFV consultada pela API do Power BI',
    'nivel', case when n = 0 or n2 * 100 <= n * 5 then 'ok' else 'atencao' end, 'n', n2,
    'texto', case when n = 0 then 'nenhuma consulta DFV nas últimas 24 h' else format('%s de %s consulta(s) DFV nas últimas 24 h fora da API', n2, n) end,
    'fazer', case when n = 0 or n2 * 100 <= n * 5 then null else 'A Nio pode ter republicado o relatório (chave/modelId mudaram): avisar o Claude Code — config_regras.dfv_api.' end);

  -- 16. 0218 — ninguém parado em silêncio: vez da Mari, conversa ativa, sem próximo toque e sem prazo
  select count(*), string_agg(coalesce(nullif(btrim(l.nome), ''), 'sem nome'), ', ' order by l.ultima_em desc) into n, ex
    from public._lead_em_silencio() s join public.v_leads l on l.conversa_id = s.conversa_id;
  it := it || jsonb_build_object('codigo', 'lead_em_silencio', 'nome', 'Ninguém parado em silêncio (vez da Mari sem próximo toque)',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'todo lead com a vez da Mari tem o próximo toque marcado ou um prazo'
                  else format('%s lead(s) com a vez da Mari, sem próximo toque e sem prazo: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Abrir na Live e dar saída, esquentar (🔥) ou assumir. Se a cadência deveria ter marcado o próximo toque, avisar o Claude Code.' end);

  -- 17. 0228 (revisão dos fluxos) — Saída com dono: lead em Saída cuja conversa segue aberta com pessoa ou time no Chatwoot
  -- há mais de 1 h (a Saída devolve para a Mari na hora; "já é cliente Nio" e "não contatar" ficam de fora).
  select count(*), string_agg(coalesce(nullif(btrim(c.dados ->> 'nome'), ''), c.nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas c left join public.vendas v on v.id = c.venda_id
   where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
     and (v.status = 'saida' or (c.venda_id is null and c.saida_em is not null and coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada', 'teste_duplicada')))
     and coalesce(c.funil_destino, '') not in ('ja_cliente_nio', 'ja_cliente') and not coalesce(c.nao_contatar, false)
     and c.chatwoot_status in ('open', 'pending') and (c.chatwoot_agente is not null or c.chatwoot_time is not null)
     and coalesce(c.saida_em, c.funil_destino_em, c.created_at) < now() - interval '1 hour';
  it := it || jsonb_build_object('codigo', 'saida_com_dono', 'nome', 'Lead em Saída sem dono no Chatwoot',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead em Saída com a conversa aberta e com dono' else format('%s lead(s) em Saída ainda com pessoa ou time no Chatwoot: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Abrir a ficha: se o cliente ainda quer seguir, Reabrir; senão "Devolver para a Mari". Se voltar a acontecer, avisar o Claude Code.' end);

  -- 18. 0228 — mensagem automática com a conversa assumida por uma pessoa (pela fila do NIOGEN, na voz da Mari, ou a Mari
  -- respondendo o cliente), nas últimas 24 h. "Assumida" = a última ação de pessoa feita pelo NIOGEN foi atribuir.
  select count(*), string_agg(distinct nome, ', ') into n, ex from (
    select c.nome_contato as nome from public.chatwoot_acoes a join public.mari_conversas c on c.id = a.conversa_id
     where a.tipo = 'mensagem' and a.status = 'feita' and a.criada_em > greatest(now() - interval '24 hours', timestamptz '2026-11-15 20:00-03')
       and coalesce(a.payload ->> 'como', '') <> 'humano' and coalesce(c.telefone, '') not like '5500000000%'
       and (select b.tipo from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.status = 'feita' and b.payload ? 'assignee_id'
              and b.tipo in ('atribuir', 'desatribuir') and b.criada_em < a.criada_em order by b.criada_em desc limit 1) = 'atribuir'
    union all
    select c.nome_contato from public.mari_turnos t join public.mari_conversas c on c.id = t.conversa_id
     where t.papel = 'mari' and t.created_at > greatest(now() - interval '24 hours', timestamptz '2026-11-15 20:00-03')   -- correções no ar desde 15/11 ~20h and coalesce(c.telefone, '') not like '5500000000%'
       and (select p.papel from public.mari_turnos p where p.conversa_id = t.conversa_id and p.papel <> 'sistema' and p.created_at < t.created_at
              order by p.created_at desc limit 1) = 'lead'
       and (select b.tipo from public.chatwoot_acoes b where b.conversa_id = t.conversa_id and b.status = 'feita' and b.payload ? 'assignee_id'
              and b.tipo in ('atribuir', 'desatribuir') and b.criada_em < t.created_at order by b.criada_em desc limit 1) = 'atribuir') x;
  it := it || jsonb_build_object('codigo', 'msg_auto_assumida', 'nome', 'Nada automático fala por cima de quem assumiu',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma mensagem automática com a conversa assumida nas últimas 24 h' else format('%s mensagem(ns) automática(s) com a conversa assumida: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code (guard da Mari ou botão sem o "em nome da pessoa"). Ver a conversa e, se precisar, corrigir com o cliente.' end);

  -- 19. 0228 — o banco diz "pessoa/time atribuído" e o Chatwoot diz sem dono (a 0227 espelha; isto acha o que escapar)
  select count(*), string_agg(coalesce(c.nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas c
   where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%' and c.chatwoot_sync_em < now() - interval '10 minutes'
     and ((c.humano_atribuido and c.chatwoot_agente is null) or (c.time_atribuido and c.chatwoot_time is null and c.chatwoot_agente is null))
     and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'atribuir' and a.status in ('pendente', 'executando'));
  it := it || jsonb_build_object('codigo', 'dono_banco_chatwoot', 'nome', 'Dono no NIOGEN = dono no Chatwoot',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todo dono no banco também está no Chatwoot' else format('%s conversa(s) com dono no banco e sem dono no Chatwoot: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o espelho do Chatwoot (0227) deixou passar. Enquanto isso a cadência dessas conversas fica parada.' end);

  -- 20. 0233 — unidade a confirmar: a unidade do cliente não está na lista da Nio e ninguém resolveu em 4 h
  select count(*), string_agg(coalesce(nullif(btrim(dados ->> 'nome'), ''), nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas where unidade_conferir_em is not null and unidade_conferir_em < now() - interval '4 hours';
  it := it || jsonb_build_object('codigo', 'conferir_unidade', 'nome', 'Unidade confirmada em até 4 h quando não bate com a lista da Nio',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma unidade por confirmar há mais de 4 h' else format('%s conversa(s) com a unidade por confirmar há mais de 4 h: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › "Unidade a confirmar": confirmar a unidade com o cliente ou pedir o cadastro à Nio e marcar "Conferi".' end);

  return it;
end;
$function$;
