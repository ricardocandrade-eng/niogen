-- NIOGEN | supabase/migrations/0091_jornada_dono.sql | 09/11/2026 — Claude Code
-- Prova do prompt Prompt_ajustes_operacao_ficha_conversa_091126_1535 (Pages): depois de "Assumir" numa conversa RESOLVIDA, a
-- v_jornada ainda dizia "sem dono" (olhava o resolvida antes do assumida) e a ficha seguia mostrando "Assumir".
-- Ordem nova do dono: não contatar → agente do Chatwoot → assumida no NIOGEN (humano_atribuido) → resolvida (sem dono) → time → Mari.
-- sem_dono (botão Assumir) também vale para resolvida sem atribuição. Só a view muda.

create or replace view public.v_jornada with (security_invoker = true) as
with cfg as (
  select coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15) as d_docs,
         (now() at time zone 'America/Sao_Paulo')::date as hoje
), conv as (
  select q.id, q.venda_id, q.nome, q.cidade, q.origem, q.plano_nome, q.coluna, q.itens_total, q.itens_validados,
         q.chatwoot_conversation_id, q.ultima_em, q.janela_24h_fecha_em, q.contatos_hoje, q.contatos_mes,
         c.chatwoot_agente, c.chatwoot_time, c.chatwoot_status, coalesce(c.humano_atribuido, false) as humano_atribuido,
         coalesce(c.nao_contatar, false) as nao_contatar, c.status as conv_status, c.handoff_motivo, c.handoff_em,
         l.ult_lead, l.ult_resp, l.ult_humano,
         s.minutos as sem_resp_min, s.desde as sem_resp_desde,
         al.tipo as alerta, al.em as alerta_em,
         bl.id as bloq_id, bl.motivo as bloq_motivo, bl.criada_em as bloq_em
    from public.v_mari_quadro q
    join public.mari_conversas c on c.id = q.id
    cross join lateral (
      select max(t.created_at) filter (where t.papel = 'lead') as ult_lead,
             max(t.created_at) filter (where t.papel in ('mari', 'humano')) as ult_resp,
             max(t.created_at) filter (where t.papel = 'humano') as ult_humano
        from public.mari_turnos t where t.conversa_id = q.id) l
    left join public.v_mari_sem_resposta s on s.id = q.id
    left join lateral (
      select case when t.texto ~* '(reclama|sem internet|internet (caiu|parou|lenta|ruim|n[aã]o funciona)|t[eé]cnico n[aã]o (veio|apareceu)|j[aá] sou cliente)' then 'reclamacao'
                  when t.texto ~* '(descont|abaixa\w* (o |esse )?(pre[cç]o|valor)|mais barat|faz (um |por )?menos)' then 'desconto'
                  else 'nao_pedi' end as tipo,
             t.created_at as em
        from public.mari_turnos t
       where t.conversa_id = q.id and t.papel = 'lead' and t.created_at > now() - interval '7 days'
         and t.created_at > coalesce(l.ult_humano, '-infinity'::timestamptz)
         and t.texto ~* '(reclama|sem internet|internet (caiu|parou|lenta|ruim|n[aã]o funciona)|t[eé]cnico n[aã]o (veio|apareceu)|j[aá] sou cliente|descont|abaixa\w* (o |esse )?(pre[cç]o|valor)|mais barat|faz (um |por )?menos|n[aã]o (pedi|solicitei|autorizei)|como (vc|voc[eê]s?) (conseguiu|pegou|achou) meu|n[aã]o me (mande|chame|ligue))'
       order by t.created_at desc limit 1) al on true
    left join lateral (
      select a.id, coalesce(a.payload ->> 'rotulo', a.momento) || coalesce(' — ' || a.erro, '') as motivo, a.criada_em
        from public.chatwoot_acoes a
       where a.conversa_id = q.id and a.status = 'bloqueada' and a.criada_em > now() - interval '7 days'
       order by a.criada_em limit 1) bl on true
   where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
), sinal as (
  -- O que a conversa pede ao time (a mesma regra com ou sem venda). null = nada.
  select cv.*,
    case
      when cv.nao_contatar or cv.coluna = 'encerrada' then null
      when cv.bloq_id is not null then 'Mensagem não saiu (' || cv.bloq_motivo || ') · mandar à mão'
      when cv.sem_resp_min is not null then 'Cliente sem resposta há ' || cv.sem_resp_min || ' min (a Mari não respondeu)'
      when cv.alerta = 'reclamacao' then 'Reclamação ou já cliente Nio · humano agora'
      when cv.alerta = 'desconto' then 'Pediu desconto · humano responde (só a tabela da Nio)'
      when cv.alerta = 'nao_pedi' then '"Não pedi contato" · humano responde e encerra'
      when cv.conv_status = 'handoff_realizado' and coalesce(cv.handoff_motivo, '') not in ('dados_completos', 'recusa_compra', 'sem_cobertura', 'fora_de_area', 'sem_contato')
           and coalesce(cv.ult_humano, '-infinity'::timestamptz) < coalesce(cv.handoff_em, '-infinity'::timestamptz)
        then 'Pediu um consultor · ninguém do time falou ainda'
      when (cv.conv_status = 'handoff_realizado' or cv.humano_atribuido or cv.chatwoot_agente is not null)
           and cv.ult_lead > coalesce(cv.ult_resp, '-infinity'::timestamptz) and cv.ult_lead > now() - interval '7 days'
        then case when cv.coluna = 'retomada' then 'Voltou a falar depois do time · responder' else 'Cliente escreveu · responder' end
    end as alerta_txt,
    case
      when cv.bloq_id is not null then cv.bloq_em
      when cv.sem_resp_min is not null then cv.sem_resp_desde
      when cv.alerta is not null then cv.alerta_em
      when cv.conv_status = 'handoff_realizado' and coalesce(cv.ult_humano, '-infinity'::timestamptz) < coalesce(cv.handoff_em, '-infinity'::timestamptz) then cv.handoff_em
      else cv.ult_lead
    end as alerta_desde,
    -- dono: resolvida = sem dono (a Mari volta se o cliente escrever)
    case when cv.nao_contatar then null
         when cv.chatwoot_agente is not null then 'pessoa'
         when cv.humano_atribuido then 'pessoa'
         when cv.chatwoot_status = 'resolved' then null
         when cv.chatwoot_time is not null then 'time'
         else 'mari' end as dono_tipo,
    case when cv.nao_contatar then null
         when cv.chatwoot_agente is not null then cv.chatwoot_agente
         when cv.humano_atribuido then 'time (assumida)'
         when cv.chatwoot_status = 'resolved' then null
         when cv.chatwoot_time is not null then 'time ' || cv.chatwoot_time
         else 'Mari' end as dono_nome
  from conv cv
), vend as (
  select v.*, public.jornada_etapa(v.status, v.nio_pedido) as etapa,
         p.nome_curto as plano_curto, u.nome as vendedor_nome,
         pe.id as pend_id, pe.revisar_em as pend_revisar, pe.aberta_em as pend_desde, pm.nome as pend_nome,
         case pe.quem_destrava when 'nio' then 'Nio' when 'rogerio' then 'Rogério' when 'cliente' then 'cliente' else 'nosso time' end as pend_quem,
         s.id as conv_id, s.chatwoot_conversation_id as cw_id, s.alerta_txt, s.alerta_desde, s.bloq_id, s.dono_tipo as conv_dono_tipo, s.dono_nome as conv_dono_nome,
         (s.id is not null and coalesce(s.chatwoot_conversation_id, '') <> '' and coalesce(s.dono_tipo, 'mari') = 'mari' and not s.nao_contatar) as sem_dono,
         coalesce(v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days', false) as viab_ok
    from public.vendas v
    left join public.config_planos p on p.id = v.plano_id
    left join public.usuarios u on u.id = v.vendedor_id
    left join public.venda_pendencias pe on pe.venda_id = v.id and pe.encerrada_em is null
    left join public.config_motivos_pendencia pm on pm.codigo = pe.motivo
    left join lateral (select x.* from sinal x where x.venda_id = v.id order by x.ultima_em desc nulls last limit 1) s on true
), vr as (
  select vd.*, cfg.d_docs,
    case
      when vd.status = 'saida' then jsonb_build_array('fora', coalesce(vd.motivo_saida, 'Saída')
             || coalesce(' · volta ' || to_char(vd.interesse_futuro_em, 'DD/MM'), ''), null, null)
      when vd.alerta_txt is not null then jsonb_build_array('agora', vd.alerta_txt,
             case when vd.bloq_id is not null then 'manual' when vd.sem_dono then 'assumir' else 'responder' end, vd.alerta_desde)
      when vd.pend_id is not null and vd.pend_revisar <= cfg.hoje then jsonb_build_array('agora',
             '⏰ Revisar hoje: ' || coalesce(vd.pend_nome, 'pendência') || ' · ' || vd.pend_quem, 'pendencia', vd.pend_desde)
      when vd.pend_id is not null then jsonb_build_array('espera',
             '⏸ Aguardando ' || vd.pend_quem || ' · ' || coalesce(vd.pend_nome, 'pendência') || ' · revisar ' || to_char(vd.pend_revisar, 'DD/MM'), 'pendencia', vd.pend_desde)
      when vd.nio_venda_valida = false then jsonb_build_array('agora', 'A Nio marcou a venda como inválida · avisar o Ricardo', 'abrir', vd.nio_osab_em)
      -- etapa 2 · Lead qualificado (sempre precisa de ação)
      when vd.etapa = 2 and vd.origem = 'parceiro_pap' and vd.conferencia_status = 'pendente' then jsonb_build_array(
             case when vd.conferencia_prazo_ate < now() then 'agora' else 'hoje' end, 'Conferir a venda do parceiro', 'conferencia', vd.criado_em)
      when vd.etapa = 2 and vd.origem = 'parceiro_pap' and vd.conferencia_status in ('devolvida', 'reprovada') then jsonb_build_array('espera',
             case vd.conferencia_status when 'devolvida' then 'Devolvida ao parceiro · esperando correção' else 'Reprovada na conferência' end, 'abrir', vd.criado_em)
      when vd.etapa = 2 and vd.credito_resultado = 'negado' then jsonb_build_array('agora', 'Crédito negado · pedir outro CPF (pendência) ou encerrar', 'abrir', vd.credito_em)
      when vd.etapa = 2 and not vd.viab_ok then jsonb_build_array('hoje',
             case when vd.nio_viab_resultado in ('sem_viabilidade', 'nao_encontrado', 'posse') then 'Portal: ' ||
                    case vd.nio_viab_resultado when 'sem_viabilidade' then 'sem viabilidade' when 'nao_encontrado' then 'endereço não encontrado' else 'endereço já tem Nio' end
                    || ' · conferir variações de CEP/rua/nº ou abrir pendência'
                  when vd.nio_viab_resultado = 'viavel' then 'Viabilidade vencida (> 7 dias) · consultar de novo no portal'
                  else 'Consultar a viabilidade no portal' end,
             case when vd.sem_dono then 'assumir' else 'viabilidade' end, vd.criado_em)
      when vd.etapa = 2 then jsonb_build_array('hoje', 'Viável · abrir o pedido no portal e gravar o nº',
             case when vd.sem_dono then 'assumir' else 'pedido' end, coalesce(vd.nio_viab_em, vd.criado_em))
      -- etapa 3 · Pedido · biometria
      when vd.etapa = 3 and vd.biometria_status = 'validada' then jsonb_build_array('agora',
             'Biometria validada · abrir a OS e agendar (prazo 4 h) · há ' || public._h_txt(vd.biometria_validada_em), 'os_agendar', vd.biometria_validada_em)
      when vd.etapa = 3 and vd.credito_resultado = 'negado' then jsonb_build_array('agora', 'Crédito negado · pedir outro CPF (pendência) ou encerrar', 'biometria', vd.credito_em)
      when vd.etapa = 3 and vd.biometria_status = 'com_risco' then jsonb_build_array('hoje', 'Biometria com risco · conferir no portal', 'biometria', vd.biometria_em)
      when vd.etapa = 3 and coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em) < now() - interval '72 hours' then jsonb_build_array('agora',
             'Link da biometria há ' || public._h_txt(coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em)) || ' · ligar para o cliente', 'biometria', coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em))
      when vd.etapa = 3 and coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em) < now() - interval '24 hours' then jsonb_build_array('hoje',
             'Link da biometria há ' || public._h_txt(coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em)) || ' · lembrar o cliente pela conversa', 'biometria', coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em))
      when vd.etapa = 3 then jsonb_build_array('espera', 'Esperando a biometria do cliente · link da Nio há ' || public._h_txt(coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em)),
             'biometria', coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em))
      -- etapa 4 · Venda · OS agendada
      when vd.etapa = 4 and vd.instalacao_agendada_para is null then jsonb_build_array('agora', 'Venda sem data de instalação · agendar', 'reagendar', vd.vendido_em)
      when vd.etapa = 4 and (vd.nio_pendencia_cod is not null or vd.nio_pendencia_desc is not null) then jsonb_build_array('hoje',
             left('Pendência Nio · ' || concat_ws(' · ', vd.nio_pendencia_cod, vd.nio_pendencia_desc), 90) || ' · reagendar', 'reagendar', coalesce(vd.nio_osab_em, vd.agendamento_registrado_em))
      when vd.etapa = 4 and (vd.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date < cfg.hoje then jsonb_build_array('hoje',
             'Instalação era ' || to_char(vd.instalacao_agendada_para at time zone 'America/Sao_Paulo', 'DD/MM') || ' e a Nio não deu baixa · conferir no portal', 'reagendar', vd.instalacao_agendada_para)
      when vd.etapa = 4 then jsonb_build_array('espera', 'Instalação ' || to_char(vd.instalacao_agendada_para at time zone 'America/Sao_Paulo', 'DD/MM')
             || case when coalesce(vd.instalacao_turno, '') = 'tarde' or extract(hour from vd.instalacao_agendada_para at time zone 'America/Sao_Paulo') >= 12 then ' à tarde' else ' de manhã' end
             || ' · com a Nio', 'reagendar', vd.agendamento_registrado_em)
      -- etapa 5 · Instalada
      when vd.etapa = 5 and vd.status = '3_instalado' and vd.docs_entregues_em is null and vd.instalado_em is not null then jsonb_build_array(
             case when vd.instalado_em + make_interval(days => cfg.d_docs) < now() then 'agora' else 'hoje' end,
             'Documentos à Nio · prazo ' || to_char((vd.instalado_em + make_interval(days => cfg.d_docs)) at time zone 'America/Sao_Paulo', 'DD/MM') || ' (' || cfg.d_docs || ' dias)', 'docs', vd.instalado_em)
      else jsonb_build_array('ok', 'Instalada · conta na meta', 'abrir', coalesce(vd.ativado_em, vd.instalado_em))
    end as r
  from vend vd cross join cfg
)
select 'venda'::text as tipo, vr.id::text as chave, vr.id as venda_id, vr.conv_id as conversa_id, vr.cw_id as chatwoot_conversation_id,
       vr.cliente_nome as nome, vr.cidade, coalesce(vr.plano_curto, '') as plano, vr.origem,
       vr.etapa, public.jornada_nome(vr.etapa) as etapa_nome,
       (vr.r ->> 0) in ('agora', 'hoje') as precisa_acao, vr.r ->> 0 as nivel, vr.r ->> 1 as o_que_fazer, vr.r ->> 2 as botao,
       nullif(vr.r ->> 3, '')::timestamptz as desde,
       coalesce(vr.conv_dono_tipo, case when vr.vendedor_id is not null then 'pessoa' end) as dono_tipo,
       coalesce(vr.conv_dono_nome, vr.vendedor_nome) as dono_nome,
       vr.pend_id is not null as pendencia, vr.bloq_id as acao_id, vr.status as status_venda, 'dharma'::text as parceiro_id
  from vr
union all
select 'conversa', 'c:' || s.id::text, null::uuid, s.id, s.chatwoot_conversation_id,
       coalesce(nullif(initcap(split_part(btrim(coalesce(s.nome, '')), ' ', 1)), ''), 'Contato'), s.cidade, coalesce(s.plano_nome, ''), s.origem,
       1, public.jornada_nome(1),
       (s.alerta_txt is not null or s.coluna = 'completo'),
       case when s.alerta_txt is not null or s.coluna = 'completo' then 'agora' else 'espera' end,
       case when s.alerta_txt is not null then s.alerta_txt
            when s.coluna = 'completo' then 'Dados completos e a venda não nasceu · ver o erro na tela Mari'
            when s.dono_tipo in ('pessoa', 'time') then 'Com ' || s.dono_nome || ' · esperando o cliente'
            else 'Mari atendendo · ' || coalesce(s.itens_validados, 0) || '/' || coalesce(s.itens_total, 0) || ' dados' end,
       case when s.bloq_id is not null then 'manual' when s.dono_tipo = 'mari' or s.dono_tipo is null then 'assumir' else 'responder' end,
       case when s.alerta_txt is not null then s.alerta_desde when s.coluna = 'completo' then s.handoff_em else s.ultima_em end,
       s.dono_tipo, s.dono_nome, false, s.bloq_id, null::text, 'dharma'::text
  from sinal s
 where s.venda_id is null and s.coluna <> 'encerrada';

grant select on public.v_jornada to authenticated;
