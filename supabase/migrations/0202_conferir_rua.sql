-- NIOGEN | supabase/migrations/0202_conferir_rua.sql | 14/11/2026 — Claude Code / Opus 5.5
-- Prompt: docs/Prompt_dfv_api_e_rua_do_portal_141126_1935.md (Drive), parte B. Caso real: Helton (CEP 36087-460, nº 99, JF) — o CEP tem
-- DUAS ruas; o portal resolveu "Rua Alvaro Coelho De Andrade Lemos, 99" e respondeu "sem viabilidade"; o cliente é da Rua Álvaro Cruz,
-- viável no DFV. Mesmo defeito no Sérggio (Beco Santo Antonio × Rua Desembargador Bráulio, BH) e no Matheus (Travessa × Rua Grão Mogol, JF).
-- O operador do portal passa a conferir a rua (portal/credito.py: mesma_rua) e para com "rua_divergente". Aqui:
--   1. mari_conversas.rua_conferir (motivo, portal, esperada, dfv) · rua_conferir_em (aberta) · rua_conferida_em/_por (quem conferiu).
--   2. _cobertura_rua_marcar(): ÚNICA função que abre a conferência (regra 20.3), com motivo e autor.
--   3. mari_viab_pendentes: manda ao operador a rua esperada (a que o cliente confirmou/escreveu; senão a do ViaCEP).
--   4. mari_viab_gravar: portal "rua_divergente", ou portal "sem viabilidade" com o DFV "exato" → abre a conferência. A DECISÃO da Mari não
--      ganha valor novo (rua_divergente = portal não decidiu → o DFV decide; o outro caso segue elegivel_200m): a Mari não nega nada e o
--      mari_principal não muda (portão da Mari). O portal decidiu de novo sem conflito → a conferência fecha sozinha.
--   5. _mari_viab_endereco_mudou: endereço novo fecha a conferência (a consulta recomeça).
--   6. cobertura_rua_conferida(conversa): o "Conferi" do time (admin/backoffice).
--   7. live_conferir (l): linha "Portal: outra rua" com as duas ruas, prazo de 4 h. conferencia_itens 14 (parada > 4 h) e 15 (DFV fora da API).
--   8. Acerto: as conversas que já estão no caso (portal sem viabilidade + DFV exato) abrem a conferência pela função do item 2.
--   9. lead_registrar_consulta: o "viável" registrado na ficha fecha a conferência da rua.
-- Teste real depois de aplicar (14/11 ~20h20, operador com a rua esperada): Helton → Rua Álvaro Cruz, 99 VIÁVEL até 1 GB; Sérggio →
-- Rua Desembargador Bráulio, 1009 VIÁVEL; Christian → Rua Quinze, 23 VIÁVEL; Matheus → Rua Grão Mogol, 49 pede o apartamento.
-- Corpos das funções = produção (pg_get_functiondef em 14/11), só com os trechos marcados 0202.

alter table public.mari_conversas
  add column if not exists rua_conferir      jsonb,
  add column if not exists rua_conferir_em   timestamptz,
  add column if not exists rua_conferida_em  timestamptz,
  add column if not exists rua_conferida_por uuid;
comment on column public.mari_conversas.rua_conferir_em is
  '0202: conferência da rua aberta (o portal consultou outra rua, ou disse sem viabilidade com a fachada viável no DFV). Null = nada a conferir.';

create or replace function public._cobertura_rua_marcar(p_conversa uuid, p_motivo text, p_portal text, p_esperada text, p_dfv text, p_autor text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_motivo not in ('rua_divergente', 'portal_nao_dfv_exato') then raise exception 'motivo desconhecido: %', p_motivo; end if;
  update public.mari_conversas c
     set rua_conferir = jsonb_strip_nulls(jsonb_build_object('motivo', p_motivo, 'portal', nullif(p_portal, ''),
                          'esperada', coalesce(nullif(p_esperada, ''), nullif(c.dados ->> 'rua_confirmada', ''), c.endereco_cep ->> 'logradouro'),
                          'dfv', nullif(p_dfv, ''), 'autor', p_autor, 'em', now())),
         rua_conferir_em = now(), rua_conferida_em = null, rua_conferida_por = null
   where c.id = p_conversa;
end $$;
revoke all on function public._cobertura_rua_marcar(uuid, text, text, text, text, text) from public, anon, authenticated;

create or replace function public.cobertura_rua_conferida(p_conversa uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  update public.mari_conversas
     set rua_conferida_em = now(), rua_conferida_por = auth.uid(), rua_conferir_em = null,
         rua_conferir = coalesce(rua_conferir, '{}'::jsonb) || jsonb_build_object('conferida_em', now(), 'conferida_por', auth.uid())
   where id = p_conversa and rua_conferir_em is not null;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'resumo', case when n = 1 then 'Rua conferida' else 'Nada a conferir nesta conversa' end);
end $$;
revoke all on function public.cobertura_rua_conferida(uuid) from public, anon;
grant execute on function public.cobertura_rua_conferida(uuid) to authenticated;

create or replace function public._mari_viab_endereco_mudou()
 returns trigger language plpgsql as $function$
begin
  if (new.cep is distinct from old.cep or new.numero is distinct from old.numero or new.complemento is distinct from old.complemento)
     and old.nio_viab_em is not null then
    new.nio_viab_em := null; new.nio_viab_resultado := null; new.nio_viab_velocidade := null;
    new.cobertura_decisao := null; new.cobertura_detalhe := null; new.cobertura_em := null;
    new.rua_conferir_em := null;   -- 0202: endereço novo → consulta nova; a conferência da rua velha fecha
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.mari_viab_pendentes(p_limite integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin
  -- Teto por telefone: mais de 3 conversas consultadas em 7 dias → não consulta (marca para não voltar à fila).
  -- 0137: conta ENDEREÇOS diferentes (CEP+nº), não conversas — quem volta ao mesmo endereço não pesa (teste do Ricardo, 12/11 09h).
  update public.mari_conversas c set nio_viab_em = now(), cobertura_decisao = 'indefinida',
         cobertura_detalhe = jsonb_build_object('teto', 'telefone: 3 endereços diferentes consultados em 7 dias'), cobertura_em = now()
   where c.nio_viab_em is null and c.updated_at > now() - interval '12 hours'
     and (select count(distinct (regexp_replace(coalesce(o.cep, ''), '\D', '', 'g'), btrim(coalesce(o.numero, ''))))
            from public.mari_conversas o
           where o.telefone = c.telefone and o.viab_consultas > 0 and o.cobertura_em > now() - interval '7 days'
             and (regexp_replace(coalesce(o.cep, ''), '\D', '', 'g'), btrim(coalesce(o.numero, '')))
                 is distinct from (regexp_replace(coalesce(c.cep, ''), '\D', '', 'g'), btrim(coalesce(c.numero, '')))) >= 3;
  with alvo as (
    select c.id from public.mari_conversas c
     where regexp_replace(coalesce(c.cep, ''), '\D', '', 'g') ~ '^\d{8}$'
       and nullif(btrim(coalesce(c.numero, '')), '') is not null
       and c.nio_viab_em is null
       and c.viab_consultas < 3                       -- teto por conversa: 3 endereços
       and coalesce(c.telefone, '') !~ '^55000000'    -- telefones de teste (bateria) nunca vão ao operador
       and coalesce(c.nao_contatar, false) = false
       and coalesce(c.dentro_area, true)
       and c.updated_at > now() - interval '12 hours'
       and (c.venda_id is null or c.handoff_em > now() - interval '12 hours')
     order by c.updated_at desc
     limit greatest(1, least(p_limite, 5))
     for update skip locked
  ), marcadas as (
    update public.mari_conversas c set nio_viab_em = now(), viab_consultas = c.viab_consultas + 1
      from alvo where c.id = alvo.id
    returning c.id, c.cep, c.numero, c.complemento, c.cidade, c.uf,
              coalesce(nullif(btrim(c.dados ->> 'rua_confirmada'), ''), nullif(btrim(c.dados ->> 'rua_informada'), ''),
                       nullif(btrim(c.endereco_cep ->> 'logradouro'), '')) as rua
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'conversa_id', id,
           'cep', regexp_replace(cep, '\D', '', 'g'),
           'numero', btrim(numero),
           'complemento', case when complemento ~* '(ap|apto|apartamento|bloco|bl|sala|loja|casa\s+[a-z0-9]\b|fundos|\d)' and complemento !~* '^\s*(casa|nenhum|nao|não|sem)\s*$'
                               then left(btrim(complemento), 60) else '' end,
           'uf', coalesce(uf, 'MG'), 'municipio', upper(coalesce(cidade, '')),
           'logradouro_esperado', coalesce(left(rua, 120), ''))), '[]'::jsonb)   -- 0202: o operador confere a rua do portal
    into v from marcadas;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.mari_viab_gravar(p_conversa uuid, p_saida jsonb, p_dfv jsonb DEFAULT NULL::jsonb, p_erro text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_res text; v_op text := p_saida->>'resultado'; v_dfv text; v_dec text; c record; v_conf text;
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
           'unidades', case when v_op = 'complemento_fora_lista' then p_saida->'opcoes'->'lista' end,
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

  return it;
end;
$function$;

-- 8. Acerto: conversas que já estão no caso (portal sem viabilidade + DFV exato na última consulta DFV da Mari)
do $$
declare r record; n int := 0;
begin
  for r in
    select c.id, (select l.saida -> 'endereco' ->> 'resolvido' from public.nio_viab_log l where l.conversa_id = c.id order by l.id desc limit 1) as portal,
           o.detalhe -> 'fachada' ->> 'logradouro' as dfv
      from public.mari_conversas c
      join lateral (select detalhe from public.operador_consultas o where o.conversa_id = c.id and o.tipo = 'dfv' order by o.id desc limit 1) o on true
     where c.nio_viab_resultado = 'sem_viabilidade' and c.cobertura_decisao = 'elegivel_200m'
       and o.detalhe ->> 'match' = 'exato' and c.rua_conferir_em is null
  loop
    perform public._cobertura_rua_marcar(r.id, 'portal_nao_dfv_exato', r.portal, null, r.dfv, 'acerto 0202');
    n := n + 1;
  end loop;
  raise notice '0202: % conversa(s) com a rua por conferir', n;
end $$;

-- 9. 0202: o "viável" registrado na ficha (lead_registrar_consulta) fecha a conferência da rua. Corpo = produção (14/11) + 1 linha.
CREATE OR REPLACE FUNCTION public.lead_registrar_consulta(p_conversa uuid, p_tipo text, p_resultado text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c    public.mari_conversas;
  rot  text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null then raise exception 'Este lead já tem venda: registre na venda.'; end if;

  if p_tipo = 'viabilidade' then
    if p_resultado <> 'viavel' then
      raise exception 'Por aqui só se grava "viável". Sem viabilidade: use Saída › Fachada não atendida.';
    end if;
    update public.mari_conversas
       set nio_viab_resultado = 'viavel', nio_viab_em = now(),
           cobertura_decisao = 'viavel', cobertura_em = now(),
           cobertura_detalhe = coalesce(cobertura_detalhe, '{}'::jsonb) || jsonb_build_object('portal', 'viavel', 'registrado_na_ficha', true),
           rua_conferir_em = null   -- 0202: viável registrado na ficha = rua conferida
     where id = c.id;
    insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, cep, numero, complemento, resultado, decisao, detalhe)
    values ('viabilidade', 'tela', auth.uid(), c.id, c.cep, c.numero, c.complemento, 'viavel', 'viavel', jsonb_build_object('registrado_na_ficha', true));
    rot := 'viabilidade: viável';

  elsif p_tipo = 'credito' then
    if p_resultado not in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'pedido_em_andamento') then
      raise exception 'Resultado de crédito desconhecido: %', p_resultado;
    end if;
    update public.mari_conversas
       set credito_resultado = p_resultado, credito_em = now(),
           nio_pedido_aberto = case when p_resultado = 'pedido_em_andamento' then 'sim' else nio_pedido_aberto end
     where id = c.id;
    insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, resultado, detalhe)
    values ('credito', 'tela', auth.uid(), c.id, p_resultado, jsonb_build_object('registrado_na_ficha', true));
    rot := 'crédito: ' || case p_resultado when 'aprovado_todas' then 'aprovado' when 'aprovado_parcial' then 'aprovado (parcial)'
                                           when 'aprovado_cartao' then 'aprovado só no cartão' when 'pendente' then 'pendente'
                                           when 'negado' then 'negado' else 'já tem pedido em andamento' end;
  else
    raise exception 'Tipo desconhecido: %', p_tipo;
  end if;

  return jsonb_build_object('ok', true, 'resumo', '✓ registrado no lead — ' || rot);
end;
$function$;
