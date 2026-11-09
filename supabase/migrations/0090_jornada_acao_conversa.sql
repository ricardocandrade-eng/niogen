-- NIOGEN | supabase/migrations/0090_jornada_acao_conversa.sql | 09/11/2026 — Claude Code
-- Prompt docs/Prompt_ajustes_operacao_ficha_conversa_091126_1535.md · pontos 2 e 4.
--   1. v_jornada (security_invoker): UMA linha por pessoa — venda (etapas 2–5 / saída) ou conversa sem venda (etapa 1) — com
--      etapa, precisa_acao, nivel (agora · hoje · espera · ok · fora), o_que_fazer, botao, dono. É a fonte da Minha vez, do
--      número do menu, do "Precisam de ação" do Funil, do Painel e da tela Mari ("a Minha vez mostrava 0 e a Mari 4" acabou).
--      Entra em "precisa de ação":
--        conversa: mensagem que não saiu (mandar à mão) · Mari sem responder ≥ N min (v_mari_sem_resposta) · reclamação/cliente Nio,
--        desconto ou "não pedi contato" depois da última fala do time · pediu um consultor e o time ainda não falou · cliente
--        escreveu depois do handoff e ninguém respondeu (inclui a retomada) · dados completos sem venda;
--        venda: Lead qualificado sempre · Pedido·biometria com link > 24 h, risco, crédito negado ou biometria validada (agora) ·
--        Venda com a data passada sem baixa ou pendência da Nio · Instalada com documentos pendentes (15 d).
--        Pendência aberta tira a venda da regra até a data de revisão (a conversa do cliente esperando continua contando).
--      Fatura em D+5 ainda não entra: não há fatura no banco (a Adimplência não tem dado) — fica para quando o extrato chegar.
--   2. backoffice_responder(conversa, texto, nota, template): a caixa de resposta do NIOGEN. Nota privada = só o time vê.
--      Mensagem = outbox chatwoot_acoes com como=humano (o executor manda com a credencial "Chatwoot Nio": balão de pessoa; o motor
--      registra como fala humana e a Mari não responde). Sem dono → assume antes. Freios: horário do contrato, 2/dia e 15/mês
--      (resposta a quem falou por último NÃO conta: contatos_cliente.tipo = 'receptivo'), janela de 24 h fechada → só template.
--   3. backoffice_conversa(conversa, acao, valor): status (aberta/resolvida), atribuição (eu · time · Mari) e etiquetas — tudo pela
--      outbox (o front não tem token).
--   4. Executor: como=humano vai com o token do usuário; resultado grava o contato como receptivo/ativo e não duplica o turno.
--   5. "Na hora": pg_net + gatilho no 1º item de cada clique chama o webhook do n8n (URL no Vault 'n8n_backoffice_webhook';
--      sem a URL, segue o ciclo de 1 min).
--   6. Respostas rápidas (config_mari_textos rr_*: "Rótulo::texto").

-- ───────────────────────── helpers ─────────────────────────
create or replace function public._h_txt(p timestamptz)
returns text language sql stable set search_path = public as $$
  select case when p is null then ''
              when now() - p < interval '1 hour' then greatest(floor(extract(epoch from now() - p) / 60), 0)::int || ' min'
              when now() - p < interval '48 hours' then floor(extract(epoch from now() - p) / 3600)::int || ' h'
              else floor(extract(epoch from now() - p) / 86400)::int || ' dias' end
$$;

-- ───────────────────────── 1. v_jornada ─────────────────────────
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
    case when cv.chatwoot_status = 'resolved' or cv.nao_contatar then null
         when cv.chatwoot_agente is not null then 'pessoa'
         when cv.humano_atribuido then 'pessoa'
         when cv.chatwoot_time is not null then 'time'
         else 'mari' end as dono_tipo,
    case when cv.chatwoot_status = 'resolved' or cv.nao_contatar then null
         when cv.chatwoot_agente is not null then cv.chatwoot_agente
         when cv.humano_atribuido then 'time'
         when cv.chatwoot_time is not null then 'time ' || cv.chatwoot_time
         else 'Mari' end as dono_nome
  from conv cv
), vend as (
  select v.*, public.jornada_etapa(v.status, v.nio_pedido) as etapa,
         p.nome_curto as plano_curto, u.nome as vendedor_nome,
         pe.id as pend_id, pe.revisar_em as pend_revisar, pe.aberta_em as pend_desde, pm.nome as pend_nome,
         case pe.quem_destrava when 'nio' then 'Nio' when 'rogerio' then 'Rogério' when 'cliente' then 'cliente' else 'nosso time' end as pend_quem,
         s.id as conv_id, s.chatwoot_conversation_id as cw_id, s.alerta_txt, s.alerta_desde, s.bloq_id, s.dono_tipo as conv_dono_tipo, s.dono_nome as conv_dono_nome,
         (s.id is not null and coalesce(s.chatwoot_conversation_id, '') <> '' and s.dono_tipo = 'mari') as sem_dono,
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

comment on view public.v_jornada is
  '0090: a jornada de 5 etapas e a regra única de "precisa de ação" (Minha vez, menu, Funil, Painel, Mari). Uma linha por pessoa.';
grant select on public.v_jornada to authenticated;

-- ───────────────────────── 2. contatos: resposta a quem falou por último não conta ─────────────────────────
create or replace function public.mari_toques(p_tel text, p_agora timestamptz default now(), out hoje int, out mes int)
returns record language sql stable set search_path = public as $$
  select
    count(*) filter (where (c.em at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date)::int,
    count(*) filter (where date_trunc('month', c.em at time zone 'America/Sao_Paulo') = date_trunc('month', p_agora at time zone 'America/Sao_Paulo'))::int
  from public.contatos_cliente c
  where c.direcao = 'saida' and c.telefone = public.tel_norm(p_tel) and coalesce(c.tipo, 'ativo') <> 'receptivo'   -- 0090
$$;
create or replace view public.v_contatos_limite as
 select v.id as venda_id,
    count(c.id) filter (where (c.em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date)::integer as hoje,
    count(c.id) filter (where date_trunc('month', (c.em at time zone 'America/Sao_Paulo')) = date_trunc('month', (now() at time zone 'America/Sao_Paulo')))::integer as mes
   from public.vendas v
     left join public.contatos_cliente c on c.direcao = 'saida' and coalesce(c.tipo, 'ativo') <> 'receptivo'
          and (c.venda_id = v.id or c.telefone is not null and c.telefone = public.tel_norm(v.cliente_whatsapp))
  group by v.id;

-- ───────────────────────── 3. caixa de resposta ─────────────────────────
create or replace function public.backoffice_responder(p_conversa uuid, p_texto text, p_nota boolean default false, p_template text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c        public.mari_conversas;
  g        uuid := gen_random_uuid();
  o        int := 0;
  quem     text;
  agente   int;
  v_time   int := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;
  txt      text := btrim(coalesce(p_texto, ''));
  aid      bigint;
  assumiu  boolean := false;
  ult_lead timestamptz;
  ult_out  timestamptz;
  resposta boolean;
  v_tq     record;
  v_fila_d int; v_fila_m int;
  v_prox   timestamptz;
  v_tpl    public.config_templates_waba;
  v_pay    jsonb;
  v_nome   text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice responde pelo NIOGEN.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' then raise exception 'Esta conversa não está no Chatwoot.'; end if;
  if c.telefone like '5500000000%' then raise exception 'Telefone de teste: nada vai ao Chatwoot.'; end if;
  if p_template is null and txt = '' then raise exception 'Escreva a mensagem.'; end if;
  if length(txt) > 4000 then raise exception 'Mensagem longa demais (máx. 4.000 caracteres).'; end if;
  select nome, chatwoot_agente_id into quem, agente from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');

  -- Nota privada: só o time vê; não é contato com o cliente.
  if coalesce(p_nota, false) then
    if txt = '' then raise exception 'Escreva a nota.'; end if;
    aid := public._bo_enfileirar(g, 1, 'nota', c.venda_id, c, 'nota', jsonb_build_object('content', txt, 'como', 'humano'));
    return jsonb_build_object('ok', true, 'acao_id', aid, 'nota', true, 'resumo', '✓ nota privada salva no Chatwoot (só o time vê)');
  end if;

  if coalesce(c.nao_contatar, false) then raise exception 'O cliente pediu para não ser contatado.'; end if;
  -- Freio 1: horário do contrato (seg–sex 9–21, sáb 10–16, nunca domingo ou feriado).
  v_prox := public.mari_proximo_horario(now(), c.cidade);
  if v_prox is null or v_prox > now() + interval '1 minute' then
    raise exception 'Fora do horário do contrato (seg–sex 9–21, sáb 10–16, nunca domingo ou feriado).%',
      coalesce(' Próximo horário: ' || to_char(v_prox at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || '.', '') using errcode = 'P0001';
  end if;
  -- Freio 2: 2/dia e 15/mês. Responder a quem falou por último não conta (é receptivo); continuar a mesma resposta também não.
  select max(t.created_at) filter (where t.papel = 'lead'), max(t.created_at) filter (where t.papel in ('mari', 'humano'))
    into ult_lead, ult_out from public.mari_turnos t where t.conversa_id = c.id;
  resposta := ult_lead is not null and ult_lead > now() - interval '24 hours'
              and (ult_lead > coalesce(ult_out, '-infinity'::timestamptz)
                   or exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'mensagem'
                               and a.payload ->> 'conta' = 'nao' and a.criada_em > ult_lead and a.criada_em > now() - interval '30 minutes'));
  if not resposta then
    select * into v_tq from public.mari_toques(c.telefone, now());
    select count(*) filter (where (a.executar_apos at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date),
           count(*) filter (where date_trunc('month', a.executar_apos at time zone 'America/Sao_Paulo') = date_trunc('month', now() at time zone 'America/Sao_Paulo'))
      into v_fila_d, v_fila_m
      from public.chatwoot_acoes a join public.mari_conversas c2 on c2.id = a.conversa_id
     where a.tipo = 'mensagem' and a.status in ('pendente', 'executando') and coalesce(a.payload ->> 'conta', 'sim') <> 'nao'
       and public.tel_norm(c2.telefone) = public.tel_norm(c.telefone);
    if coalesce(v_tq.hoje, 0) + v_fila_d >= 2 then
      raise exception 'Teto do contrato: já são 2 contatos hoje com este cliente. Responder quando ele escrever não conta.' using errcode = 'P0001';
    end if;
    if coalesce(v_tq.mes, 0) + v_fila_m >= 15 then
      raise exception 'Teto do contrato: já são 15 contatos neste mês com este cliente.' using errcode = 'P0001';
    end if;
  end if;
  -- Freio 3: janela de 24 h (23 h de folga, igual à cadência). Fechada → só template aprovado (de 1 parâmetro: o nome).
  if p_template is not null then
    select * into v_tpl from public.config_templates_waba where nome = p_template and status = 'APPROVED' and nome like 'nio\_%';
    if v_tpl.nome is null then raise exception 'Template não aprovado: %', p_template; end if;
    if (select count(*) from regexp_matches(coalesce(v_tpl.corpo, ''), '\{\{[0-9]+\}\}', 'g')) > 1 then
      raise exception 'Este template precisa de mais dados; mande pelo Chatwoot.';
    end if;
    v_nome := public.mari_cadencia_nome(c);
    v_pay := jsonb_build_object('content', public.mari_render_template(v_tpl.nome, jsonb_build_array(v_nome)), 'content_type', 'text',
      'message_type', 'outgoing', 'private', false, 'template', v_tpl.nome,
      'template_params', jsonb_build_object('name', v_tpl.nome, 'category', v_tpl.categoria, 'language', v_tpl.idioma,
        'processed_params', jsonb_build_object('body', jsonb_build_object('1', v_nome))));
  else
    if ult_lead is null or now() >= ult_lead + interval '23 hours' then
      raise exception 'A janela de 24 h fechou: só template aprovado. Escolha um em "Respostas rápidas › Templates".' using errcode = 'P0001';
    end if;
    v_pay := jsonb_build_object('content', txt, 'message_type', 'outgoing', 'private', false);
  end if;
  v_pay := v_pay || jsonb_build_object('como', 'humano', 'conta', case when resposta then 'nao' else 'sim' end, 'rotulo', 'resposta do time');

  -- Sem dono → assume antes (a Mari cala, a cadência para).
  if c.chatwoot_agente is null and not coalesce(c.humano_atribuido, false) then
    perform public.mari_cadencia_parar(c.id, p_humano => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[assumida no NIOGEN por ' || quem || ' ao responder — cadência parada]', false);
    o := o + 1;
    perform public._bo_enfileirar(g, o, 'assumir', c.venda_id, c, 'atribuir',
      case when agente is not null then jsonb_build_object('assignee_id', agente) else jsonb_build_object('team_id', v_time) end);
    assumiu := true;
  end if;
  o := o + 1;
  aid := public._bo_enfileirar(g, o, 'responder', c.venda_id, c, 'mensagem', v_pay);
  return jsonb_build_object('ok', true, 'acao_id', aid, 'resposta', resposta, 'assumiu', assumiu,
    'resumo', '✓ mensagem enviada' || case when assumiu then ' · conversa assumida (a Mari calou)' else '' end
      || case when resposta then ' · resposta (não conta no limite)' else ' · conta no limite do contrato' end);
end;
$$;
grant execute on function public.backoffice_responder(uuid, text, boolean, text) to authenticated;

create or replace function public.backoffice_conversa(p_conversa uuid, p_acao text, p_valor text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c      public.mari_conversas;
  g      uuid := gen_random_uuid();
  v_time int := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;
  lab    text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa;
  if not found or coalesce(c.chatwoot_conversation_id, '') = '' then raise exception 'Conversa sem Chatwoot.'; end if;
  if c.telefone like '5500000000%' then raise exception 'Telefone de teste: nada vai ao Chatwoot.'; end if;
  if p_acao = 'atribuir' then
    if p_valor = 'eu' then return public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', c.id)); end if;
    if p_valor = 'mari' then return public.backoffice_momento(null, 'devolver_mari', jsonb_build_object('conversa_id', c.id)); end if;
    if p_valor = 'time' then
      perform public.mari_cadencia_parar(c.id, p_time => true);
      perform public._bo_enfileirar(g, 1, 'atribuir', c.venda_id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(g, 2, 'atribuir', c.venda_id, c, 'atribuir', jsonb_build_object('team_id', v_time));
      return jsonb_build_object('ok', true, 'resumo', '✓ conversa no time backoffice (a Mari calou)');
    end if;
    raise exception 'Atribuição inválida.';
  elsif p_acao = 'status' then
    if p_valor not in ('open', 'resolved') then raise exception 'Status inválido.'; end if;
    perform public._bo_enfileirar(g, 1, 'status', c.venda_id, c, 'resolver', jsonb_build_object('status', p_valor));
    return jsonb_build_object('ok', true, 'resumo', case when p_valor = 'resolved' then '✓ conversa resolvida (sem dono; a Mari volta se o cliente escrever)' else '✓ conversa reaberta' end);
  elsif p_acao in ('etiqueta_add', 'etiqueta_remove') then
    lab := lower(btrim(coalesce(p_valor, '')));
    if lab !~ '^[a-z0-9_-]{2,40}$' then raise exception 'Etiqueta inválida.'; end if;
    perform public._bo_enfileirar(g, 1, 'etiqueta', c.venda_id, c, 'etiquetas',
      case when p_acao = 'etiqueta_add' then jsonb_build_object('add', jsonb_build_array(lab))
           else jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array(lab)) end);
    return jsonb_build_object('ok', true, 'resumo', case when p_acao = 'etiqueta_add' then '✓ etiqueta ' || lab || ' posta' else '✓ etiqueta ' || lab || ' tirada' end);
  end if;
  raise exception 'Ação desconhecida: %', p_acao;
end;
$$;
grant execute on function public.backoffice_conversa(uuid, text, text) to authenticated;

-- ───────────────────────── 4. executor ─────────────────────────
CREATE OR REPLACE FUNCTION public.backoffice_acoes_proximas(p_limite integer DEFAULT 20)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  a      public.chatwoot_acoes;
  c      public.mari_conversas;
  conta  text := public._bo_cfg('chatwoot_conta', '195428') #>> '{}';
  usr    jsonb := public._bo_cfg('backoffice_cred_usuario', '[]'::jsonb);
  base   text;
  n      int := 0;
begin
  if not coalesce((public._bo_cfg('backoffice_chatwoot_ligado', 'true') #>> '{}')::boolean, true) then return; end if;
  -- 'executando' preso há mais de 10 min (execução caiu no meio) volta para a fila.
  update public.chatwoot_acoes set status = case when tentativas < 3 then 'pendente' else 'erro' end,
         erro = coalesce(erro, 'execução interrompida')
   where status = 'executando' and pega_em < now() - interval '10 minutes';
  for a in
    select x.* from public.chatwoot_acoes x
     where x.status = 'pendente' and x.executar_apos <= now()
       -- 0083: o clique inteiro sai na mesma rodada (o n8n executa etiquetas primeiro e o resto na ordem do id). Só espera
       -- quando uma ação anterior do grupo ainda vai sair mais tarde (mensagem fora do horário) ou está numa rodada anterior.
       and not exists (select 1 from public.chatwoot_acoes y
                        where y.grupo = x.grupo and y.ordem < x.ordem
                          and (y.status = 'executando' or (y.status = 'pendente' and y.executar_apos > now())))
     order by x.executar_apos, x.grupo, x.ordem
     limit greatest(1, least(coalesce(p_limite, 20), 50))
     for update skip locked
  loop
    select * into c from public.mari_conversas where id = a.conversa_id;
    if a.tipo = 'mensagem' and coalesce(c.nao_contatar, false) then
      update public.chatwoot_acoes set status = 'cancelada', erro = 'cliente pediu para não ser contatado', feita_em = now() where id = a.id;
      continue;
    end if;
    update public.chatwoot_acoes set status = 'executando', tentativas = tentativas + 1, pega_em = now() where id = a.id;
    base := 'https://app.chatwoot.com/api/v1/accounts/' || conta || '/conversations/' || a.chatwoot_conversation_id;
    n := n + 1;
    return next jsonb_build_object(
      'id', a.id, 'tipo', a.tipo, 'momento', a.momento,
      'usuario', (usr ? a.tipo) or coalesce(a.payload ->> 'como', '') = 'humano',   -- 0090: resposta do time sai como pessoa
      'url_base', base,
      'url', base || case a.tipo when 'atribuir' then '/assignments' when 'desatribuir' then '/assignments'
                                 when 'etiquetas' then '/labels' when 'resolver' then '/toggle_status' else '/messages' end,
      'corpo', case a.tipo
                 when 'nota' then jsonb_build_object('content', a.payload ->> 'content', 'message_type', 'outgoing', 'private', true)
                 when 'mensagem' then (a.payload - 'texto_chave' - 'rotulo' - 'template' - 'motivo' - 'como' - 'conta')
                 when 'etiquetas' then '{}'::jsonb
                 else a.payload end,
      'add', coalesce(a.payload -> 'add', '[]'::jsonb), 'remove', coalesce(a.payload -> 'remove', '[]'::jsonb));
  end loop;
  return;
end;
$function$;


create or replace function public.backoffice_acao_resultado(p_id bigint, p_ok boolean, p_erro text default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  a public.chatwoot_acoes;
  c public.mari_conversas;
begin
  select * into a from public.chatwoot_acoes where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'ação inexistente'); end if;
  if not coalesce(p_ok, false) then
    update public.chatwoot_acoes
       set status = case when tentativas >= 3 then 'erro' else 'pendente' end,
           executar_apos = case when tentativas >= 3 then executar_apos else now() + interval '2 minutes' end,
           erro = left(coalesce(p_erro, 'sem detalhe'), 500)
     where id = p_id;
    if a.tentativas >= 3 then
      insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
      values (a.conversa_id, 'backoffice_chatwoot', 'ação ' || a.tipo || ' (' || a.momento || ') falhou 3×: ' || left(coalesce(p_erro, ''), 300),
              jsonb_build_object('acao_id', a.id));
    end if;
    return jsonb_build_object('ok', true, 'registrado', 'erro');
  end if;
  update public.chatwoot_acoes set status = 'feita', erro = null, feita_em = now() where id = p_id;
  if a.tipo = 'mensagem' then
    select * into c from public.mari_conversas where id = a.conversa_id;
    if a.payload ->> 'como' = 'humano' then
      -- 0090: resposta do time pela caixa do NIOGEN. Receptivo (respondeu a quem falou por último) não conta no teto.
      -- O turno 'humano' quem grava é o motor da Mari (o Chatwoot avisa a fala do usuário) — não duplica aqui.
      insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
      values (a.venda_id, a.conversa_id, c.telefone, 'whatsapp', 'saida', 'vendedor', now(), 'BO_RESPOSTA',
              case when a.payload ->> 'conta' = 'nao' then 'receptivo' else 'ativo' end,
              'NIOGEN · resposta do time' || coalesce(' · template ' || (a.payload ->> 'template'), ''));
    else
      insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
      values (a.venda_id, a.conversa_id, c.telefone, 'whatsapp', 'saida', 'vendedor', now(), 'BO_' || upper(a.momento), 'ativo',
              'NIOGEN · ' || coalesce(a.payload ->> 'rotulo', a.momento) || coalesce(' · template ' || (a.payload ->> 'template'), ''));
      insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
      values (a.conversa_id, 'mari', coalesce(a.payload ->> 'content', ''), jsonb_build_object('backoffice', a.momento, 'acao_id', a.id), now());
    end if;
  end if;
  return jsonb_build_object('ok', true, 'registrado', 'feita');
end;
$$;

-- ───────────────────────── 5. na hora: acordar o n8n no 1º item de cada clique ─────────────────────────
create extension if not exists pg_net;
create or replace function public._bo_acordar_n8n()
returns trigger language plpgsql security definer set search_path = public as $$
declare u text;
begin
  if new.status <> 'pendente' or new.executar_apos > now() + interval '5 seconds' then return null; end if;
  select decrypted_secret into u from vault.decrypted_secrets where name = 'n8n_backoffice_webhook' limit 1;
  if coalesce(u, '') = '' then return null; end if;   -- sem URL: o ciclo de 1 min do n8n pega
  perform net.http_post(url := u, body := jsonb_build_object('grupo', new.grupo), timeout_milliseconds := 5000);
  return null;
exception when others then
  return null;   -- acordar o n8n nunca derruba o clique
end;
$$;
drop trigger if exists chatwoot_acoes_acordar on public.chatwoot_acoes;
create trigger chatwoot_acoes_acordar after insert on public.chatwoot_acoes
  for each row when (new.ordem = 1) execute function public._bo_acordar_n8n();

-- ───────────────────────── 6. respostas rápidas ("Rótulo::texto") ─────────────────────────
insert into public.config_mari_textos (chave, texto) values
  ('rr_01_apresentacao', 'Apresentação do consultor::Oi! Aqui é do time da Nio. Vou seguir com você por aqui 😊'),
  ('rr_02_biometria', 'Link da biometria::A Nio te mandou o link da biometria por WhatsApp e por e-mail. É rapidinho: os 5 primeiros números do CPF e uma selfie (sem óculos, num lugar bem iluminado). Me avisa quando terminar?'),
  ('rr_03_pendencia', 'Retorno da pendência::Temos um retorno sobre o seu pedido: '),
  ('rr_04_credito', 'Crédito negado::Não conseguimos a aprovação no seu CPF neste momento. Você teria outro CPF (de um familiar ou amigo) para tentarmos?'),
  ('rr_05_desconto', 'Pedido de desconto::Os preços são os da tabela da Nio, iguais para todo mundo. Posso te mostrar o plano que fica mais em conta pra você?'),
  ('rr_06_instalacao', 'Instalação confirmada::Sua instalação está confirmada. O técnico da Nio vai no período combinado; é importante ter alguém maior de idade em casa.')
on conflict (chave) do nothing;
