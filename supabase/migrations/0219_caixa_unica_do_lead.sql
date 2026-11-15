-- NIOGEN | supabase/migrations/0219_caixa_unica_do_lead.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (15/11 ~18h30): "Pode fechar as 7 caixas. E se possível faça um backfill para acertar tudo."
-- Base: docs/MAPA_estados_dos_leads_151126_1800.md (115 leads, 22 combinações de estado, 3 sem caixa).
--
-- A CAIXA é a resposta única para "onde este lead está e quem cuida". Uma só por lead, calculada num lugar só (v_jornada.caixa):
--   1 Mari conduzindo ............ em andamento, com a Mari, próximo toque marcado
--   2 Time precisa agir .......... Para fazer da Live (cliente escreveu, pediu consultor, OS, agendar, janela fechando…)
--   3 Com o time, esperando ...... dono pessoa/time, em espera combinada ou cliente só confirmou
--   4 Venda andando .............. venda viva esperando a Nio ou o cliente
--   5 Sem caixa .................. ninguém vai falar com o cliente → SOBE para Para fazer com a instrução (nunca em silêncio)
--   6 Saída ...................... destino de saída (no funil ou na venda)
--   7 Instalada .................. instalada / pós-venda
-- Quem lê: a Live (Para fazer = 2 e 5; Acompanhando = 3 e 4; caixa 1 vira uma linha de radar), v_lead_caixa (todos os leads,
-- inclusive os que não estão na v_jornada) e, por ela, _lead_em_silencio (retrato do Agente de Tráfego e item 16 da conferência).
--
-- Peça que faltava: o próximo toque. mari_conversas.cadencia_proximo_em só era gravado quando um toque saía; toque marcado mas
-- bloqueado (fora do horário, "o time falou hoje", aguardando) ficava vazio e o lead parecia em silêncio (Mauricio). Agora a
-- rodada da cadência (mari_cadencia_candidatos, a cada 5 min pelo n8n) grava o próximo toque de TODA conversa avaliada, na mesma
-- avaliação que já fazia — sem custo extra. A saída da função para o n8n não muda.
--
-- Backfill: carimbo do próximo toque agora; thay e Roberto Aureo (clientes Nio pedindo suporte, sem destino) → Saída "Já é cliente
-- Nio"; a conversa encerrada sem nome e sem resposta → Saída "Sem resposta". Pela lead_sair, em nome do Ricardo (admin).
-- Regra 20: (1) a caixa resume etapa/status/destino/vez/prazo; (2) caixa 5 vira dono cobrado na hora (Para fazer) e item da
-- conferência; (3) a caixa é leitura; estado só muda pelas funções de sempre (lead_sair, lead_reabrir…); (4) fonte única: v_jornada;
-- (5) item 16 da conferência passa a contar a caixa 5. Nada no mari_principal (o portão não se aplica).
begin;

create or replace function public._caixa_nome(p int)
returns text language sql immutable as $$
  select case p when 1 then 'Mari conduzindo' when 2 then 'Time precisa agir' when 3 then 'Com o time, esperando o cliente'
                when 4 then 'Venda andando (Nio/cliente)' when 5 then 'Sem caixa' when 6 then 'Saída' when 7 then 'Instalada' end
$$;
grant execute on function public._caixa_nome(int) to authenticated, service_role;

-- o próximo toque de cada conversa, a partir de uma avaliação já feita
create or replace function public._cadencia_carimbar(p_aval jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with a as (select (e ->> 'conversa_id')::uuid as id, (e ->> 'proximo_em')::timestamptz as prox
               from jsonb_array_elements(coalesce(p_aval, '[]'::jsonb)) e),
       x as (select c.id, a.prox from public.mari_conversas c left join a on a.id = c.id
              where c.canal in ('teste', 'whatsapp') and c.status in ('ativo', 'handoff_realizado'))
  update public.mari_conversas mc set cadencia_proximo_em = x.prox
    from x where mc.id = x.id and mc.cadencia_proximo_em is distinct from x.prox;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public._cadencia_carimbar(jsonb) from public, anon, authenticated;

-- a rodada da cadência (n8n, a cada 5 min): mesma saída de antes + o carimbo do próximo toque
create or replace function public.mari_cadencia_candidatos(p_agora timestamptz default now(), p_canal text default 'teste', p_limite int default 30)
returns setof jsonb language plpgsql set search_path = public as $$
declare v_aval jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) into v_aval from public.mari_cadencia_avaliar(p_agora, null) a;
  begin
    perform public._cadencia_carimbar(v_aval);
  exception when others then
    insert into public.mari_erros (no_n8n, mensagem) values ('_cadencia_carimbar', sqlerrm);
  end;
  return query
  select e from jsonb_array_elements(v_aval) e
   where (e ->> 'pode_enviar')::boolean and e ->> 'canal' = p_canal
   order by case e ->> 'proximo_passo' when 'RETORNO' then 0 when 'INSTALACAO' then 1 when 'VESPERA' then 1 when 'BIO1' then 1
                                       when 'F1' then 2 when 'F2' then 3 else 4 end,
            (e ->> 'proximo_em')::timestamptz
   limit least(greatest(coalesce(p_limite, 30), 1), 30);
end;
$$;

-- v_jornada (0216) + caixa, caixa_nome, proximo_toque_em; caixa 5 sobe para Para fazer
create or replace view public.v_jornada as  SELECT j.tipo,
    j.chave,
    j.venda_id,
    j.conversa_id,
    j.chatwoot_conversation_id,
    j.nome,
    j.cidade,
    j.plano,
    j.origem,
    j.etapa,
    j.etapa_nome,
    j.precisa_acao OR a.usa OR COALESCE(p.sobe, false) OR cx.n = 5 AS precisa_acao,
        CASE
            WHEN a.usa THEN a.nivel
            WHEN p.k IS NOT NULL THEN p.nivel
            WHEN cx.n = 5 THEN 'hoje'::text
            ELSE j.nivel
        END AS nivel,
        CASE
            WHEN a.usa THEN a.texto
            WHEN p.k IS NOT NULL THEN p.texto
            WHEN cx.n = 5 THEN 'Sem caixa: ninguém vai falar com o cliente · assuma, devolva à Mari com retorno ou dê Saída'::text
            ELSE j.o_que_fazer
        END AS o_que_fazer,
        CASE
            WHEN a.usa THEN a.botao
            ELSE j.botao
        END AS botao,
        CASE
            WHEN a.usa THEN a.em
            WHEN p.k IS NOT NULL THEN p.desde
            WHEN cx.n = 5 THEN COALESCE(mc.ultima_msg_lead_at, j.desde)
            ELSE j.desde
        END AS desde,
    j.dono_tipo,
    j.dono_nome,
    j.pendencia,
    j.acao_id,
    j.status_venda,
    j.parceiro_id,
    j.sem_dono_min,
    j.pedido_provisorio,
    j.cliente_confirmou,
    j.confirmou_em,
    an.portal_status,
    an.portal_desde AS portal_status_desde,
    an.bio_resultado AS biometria_ged,
    an.bio_desde AS biometria_ged_desde,
    COALESCE(p.k = 'parado'::text, false) AS cliente_parado,
    cx.n AS caixa,
    _caixa_nome(cx.n) AS caixa_nome,
    mc.cadencia_proximo_em AS proximo_toque_em
   FROM v_jornada_base j
     LEFT JOIN v_venda_andamento an ON an.venda_id = j.venda_id
     LEFT JOIN v_instalacao_confirmacao ic ON ic.venda_id = j.venda_id AND ic.resposta = 'remarcar'::text
     LEFT JOIN LATERAL ( SELECT x.texto,
            x.nivel,
            x.em,
            x.botao
           FROM ( VALUES (an.portal_alerta,an.portal_alerta_nivel,an.portal_desde,'abrir'::text), (an.bio_alerta,an.bio_alerta_nivel,an.bio_desde,'abrir'::text), (
                        CASE
                            WHEN ic.venda_id IS NOT NULL THEN 'Cliente pediu para remarcar a instalação · reagendar no portal e gravar'::text
                            ELSE NULL::text
                        END,'agora'::text,ic.resposta_em,'reagendar'::text)) x(texto, nivel, em, botao)
          WHERE x.texto IS NOT NULL
          ORDER BY (
                CASE x.nivel
                    WHEN 'agora'::text THEN 0
                    ELSE 1
                END), x.em
         LIMIT 1) al ON true
     CROSS JOIN LATERAL ( SELECT al.texto,
            al.nivel,
            al.em,
            al.botao,
            COALESCE(al.texto IS NOT NULL AND j.etapa > 0 AND (j.nivel <> 'agora'::text OR al.botao = 'reagendar'::text AND j.botao = 'responder'::text) AND
                CASE al.nivel
                    WHEN 'agora'::text THEN 0
                    ELSE 1
                END <=
                CASE j.nivel
                    WHEN 'hoje'::text THEN 1
                    ELSE 2
                END, false) AS usa) a
     CROSS JOIN ( SELECT COALESCE((r.valor ->> 'parado_min')::integer, 60) AS parado_min,
            COALESCE((r.valor ->> 'janela_fecha_h')::integer, 23) AS janela_fecha_h,
            COALESCE((r.valor ->> 'sobe_h')::integer, 3) AS sobe_h,
            COALESCE((r.valor ->> 'dias_max')::integer, 15) AS dias_max
           FROM ( SELECT ( SELECT config_regras.valor
                           FROM config_regras
                          WHERE config_regras.chave = 'live_cliente_parado'::text) AS valor) r) cp
     LEFT JOIN mari_conversas mc ON j.tipo = 'conversa'::text AND mc.id = j.conversa_id
     LEFT JOIN LATERAL ( SELECT q.k,
                CASE q.k
                    WHEN 'parado'::text THEN 'espera'::text
                    ELSE 'hoje'::text
                END AS nivel,
            q.k = ANY (ARRAY['resolvida'::text, 'janela'::text]) AS sobe,
                CASE q.k
                    WHEN 'resolvida'::text THEN 'Resolvida no Chatwoot e sem saída no NIOGEN · a Mari parou de cutucar · dar saída ou retomar'::text
                    WHEN 'janela'::text THEN (('Cliente parado há '::text || _oport_dur(now() - mc.ultima_msg_mari_at)) || ' · a janela de 24 h fecha às '::text)
                        || to_char((mc.ultima_msg_lead_at + '24:00:00'::interval) AT TIME ZONE 'America/Sao_Paulo'::text, 'HH24:MI'::text) || ' · cutucar agora (texto livre)'::text
                    ELSE ('Vez do cliente · parado há '::text || _oport_dur(now() - mc.ultima_msg_mari_at)) ||
                        CASE
                            WHEN (mc.ultima_msg_lead_at + '24:00:00'::interval) > now() THEN ' · janela de 24 h até '::text
                                || to_char((mc.ultima_msg_lead_at + '24:00:00'::interval) AT TIME ZONE 'America/Sao_Paulo'::text, 'DD/MM HH24:MI'::text)
                            ELSE ' · janela fechada (só template)'::text
                        END
                END AS texto,
            mc.ultima_msg_mari_at AS desde
           FROM ( SELECT
                        CASE
                            WHEN mc.id IS NULL OR j.precisa_acao OR a.usa OR j.pendencia OR COALESCE(j.dono_tipo, 'mari'::text) <> 'mari'::text
                              OR mc.status <> 'ativo'::text OR COALESCE(mc.nao_contatar, false) OR mc.ultima_msg_lead_at IS NULL
                              OR mc.ultima_msg_mari_at IS NULL OR mc.ultima_msg_mari_at < mc.ultima_msg_lead_at
                              OR mc.ultima_msg_lead_at < (now() - make_interval(days => cp.dias_max)) THEN NULL::text
                            WHEN COALESCE(mc.chatwoot_resolvida, false) AND COALESCE(mc.funil_destino, 'em_andamento'::text) <> 'em_andamento'::text THEN NULL::text
                            WHEN COALESCE(mc.chatwoot_resolvida, false) THEN 'resolvida'::text
                            WHEN mc.ultima_msg_mari_at > (now() - make_interval(mins => cp.parado_min)) THEN NULL::text
                            WHEN (mc.ultima_msg_lead_at + make_interval(hours => cp.janela_fecha_h)) > now()
                             AND (mc.ultima_msg_lead_at + make_interval(hours => cp.janela_fecha_h)) <= (now() + make_interval(hours => cp.sobe_h)) THEN 'janela'::text
                            ELSE 'parado'::text
                        END AS k) q
          WHERE q.k IS NOT NULL) p ON true
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN j.etapa = 0 OR COALESCE(mc.funil_destino, 'em_andamento'::text) <> ALL (ARRAY['em_andamento'::text, 'instalada'::text]) THEN 6
                    WHEN j.etapa = 5 OR mc.funil_destino = 'instalada'::text THEN 7
                    WHEN j.precisa_acao OR a.usa OR COALESCE(p.sobe, false) THEN 2
                    WHEN j.tipo = 'venda'::text THEN 4
                    WHEN (j.dono_tipo = ANY (ARRAY['pessoa'::text, 'time'::text])) OR j.pendencia OR COALESCE(j.cliente_confirmou, false) THEN 3
                    WHEN mc.cadencia_proximo_em IS NOT NULL THEN 1
                    ELSE 5
                END AS n) cx;

-- todos os leads com a sua caixa (os que não estão na v_jornada — conversa encerrada — caem por destino)
create or replace view public.v_lead_caixa with (security_invoker = true) as
with j as materialized (select tipo, venda_id, conversa_id, caixa, proximo_toque_em from public.v_jornada)
select l.lead_id, l.conversa_id, l.venda_id, l.parceiro_id, l.nome, l.criado_em, l.etapa, l.status, l.destino, l.vez, l.prazo_em,
       coalesce(jv.caixa, jc.caixa,
                case when l.destino = 'instalada' or l.venda_status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then 7
                     when l.destino <> 'em_andamento' or l.venda_status = 'saida' then 6
                     else 5 end) as caixa,
       public._caixa_nome(coalesce(jv.caixa, jc.caixa,
                case when l.destino = 'instalada' or l.venda_status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then 7
                     when l.destino <> 'em_andamento' or l.venda_status = 'saida' then 6
                     else 5 end)) as caixa_nome,
       (jv.caixa is null and jc.caixa is null) as fora_da_live,
       coalesce(jv.proximo_toque_em, jc.proximo_toque_em) as proximo_toque_em
  from public.v_leads l
  left join j jv on l.venda_id is not null and jv.tipo = 'venda' and jv.venda_id = l.venda_id
  left join j jc on l.venda_id is null and jc.tipo = 'conversa' and jc.conversa_id = l.conversa_id;
grant select on public.v_lead_caixa to authenticated, service_role;

-- "lead em silêncio" (retrato do Agente de Tráfego e item 16 da conferência) = caixa 5, a mesma regra da Live
create or replace function public._lead_em_silencio(p_de date default null)
returns table (conversa_id uuid)
language sql stable security definer set search_path = public as $$
  select x.conversa_id from public.v_lead_caixa x
   where x.caixa = 5 and x.conversa_id is not null
     and (p_de is null or (x.criado_em at time zone 'America/Sao_Paulo')::date >= p_de)
$$;

-- ───────── backfill ─────────
do $$
declare
  v_aval jsonb; n int; r record; k int := 0;
begin
  select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) into v_aval from public.mari_cadencia_avaliar(now(), null) a;
  n := public._cadencia_carimbar(v_aval);
  raise notice '0219: próximo toque carimbado em % conversas', n;
  perform set_config('request.jwt.claims', '{"sub": "3d1ffdae-f7b7-448b-87bd-5ee7ad9da9f5", "role": "authenticated"}', true);
  perform set_config('request.jwt.claim.sub', '3d1ffdae-f7b7-448b-87bd-5ee7ad9da9f5', true);
  for r in select * from (values
             ('a6354482-54bf-427f-8680-2484cf19a2b7'::uuid, 'ja_cliente_nio', 'cliente Nio pedindo suporte (App Nio); sem destino desde 09/11 — backfill 0219'),
             ('d5939e04-d52c-4391-8df9-80554b8c2fc0'::uuid, 'ja_cliente_nio', 'cliente Nio pedindo suporte (App Nio); sem destino desde 10/11 — backfill 0219'),
             ('84e57f1b-2e07-4ec6-b0f2-8be62004b3e9'::uuid, 'sem_resposta',   'encerrada sem nunca responder; destino em andamento — backfill 0219')) t(id, motivo, obs) loop
    begin
      perform public.lead_sair(r.id, null, r.motivo, null, null, r.obs, null);
      k := k + 1;
    exception when others then
      insert into public.mari_erros (no_n8n, mensagem) values ('0219_backfill_saida', r.id::text || ': ' || sqlerrm);
    end;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  raise notice '0219: % saídas gravadas', k;
end;
$$;

commit;
