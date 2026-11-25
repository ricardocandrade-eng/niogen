-- NIOGEN | supabase/migrations/0401_venda_em_risco.sql | 25/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 25/11/2026 (caso L-377): "estava com pressa na instalação e ameaçou desistir. A Mari deveria imediatamente ter falado
-- que acionaria um atendente para tentar encaixar a instalação dele pra hoje e entrado como prioridade 1 na fila da Live. É
-- oportunidade de venda e é isso que precisamos medir! Se eu não tivesse visto em Conversas perderíamos a venda".
-- O caso: plano escolhido, cartão, botões de data → "Teria para hoje?" → a Mari: "pra hoje não vai rolar" → "Então pode deixar obg"
-- → a Mari repetiu "E qual período você prefere nesse dia?" duas vezes. A conversa estava com a Mari: a fila nem a enxergava.
-- O conserto tem duas metades:
--   (Mari, n8n — 7 · Extrair, P54) com o plano escolhido, pressa na instalação ou ameaça de desistir → handoff urgencia_alta na
--       hora, com a fala "vou acionar agora um atendente do nosso time pra tentar encaixar a sua instalação". Grava dados.risco_venda.
--   (esta migration) a fila da Live 2.0 e a medição:
--     live2_fila()      — lead em que a Mari acionou o time por urgência (evento mari_passou:urgencia_alta na porta) e em que
--                         ninguém do time falou depois: urgência 5, SEMPRE em 1º (antes dos pontos), "Venda em risco · …",
--                         nunca escondido por Adiar/Já cobrei. Sai dessa regra quando uma pessoa responde. Vale por 48 h
--                         (live2_pesos.risco_horas); o peso é live2_pesos.urgencia.venda_em_risco (10).
--     live2_resgates(d) — a medição (regra 18: "toda oportunidade criada registra se foi usada e no que deu"): cada vez que a
--                         Mari acionou o time por urgência, em quantos minutos uma pessoa respondeu e no que deu (pedido,
--                         instalada, saída). Só leitura, sobre a porta, os turnos e a venda — nenhuma tabela nova.
--     config_mari_textos — as duas falas, trocáveis sem deploy.
-- Regra 20: (1) nenhum estado novo: a situação continua "Com o time — responder agora", com vez e prazo; (2) ninguém parado: a
-- linha fica em 1º até alguém responder, e a volta para a Mari em 24 h úteis (C4) segue valendo; (3) nada grava; (4) fonte única:
-- a porta (porta_sombra) e a conversa; (5) número novo = live2_resgates, que é a própria conferência do que foi feito.
-- Regra de ouro 6: a fala sai no lugar da resposta da Mari, nunca por cima de uma pessoa. Cenário X131.
-- Medir em 7 dias: resgates acionados × respondidos em até 5 min × viraram pedido (aba 7 dias da Live 2.0).

begin;

insert into public.config_mari_textos (chave, texto) values
  ('risco_pressa_fala', E'Entendi{nome}! Vou acionar agora um atendente do nosso time pra tentar encaixar a sua instalação pra hoje.\n\n{prazo} 😊'),
  ('risco_desiste_fala', E'Calma{nome}, não quero que você fique sem a sua internet por causa da data 😊\n\nVou acionar agora um atendente do nosso time pra ver com você o melhor dia e horário da instalação. {prazo}.')
on conflict (chave) do nothing;

update public.config_regras
   set valor = jsonb_set(valor || jsonb_build_object('risco_horas', coalesce((valor ->> 'risco_horas')::int, 48)),
                         '{urgencia,venda_em_risco}', coalesce(valor #> '{urgencia,venda_em_risco}', '10'::jsonb), true)
 where chave = 'live2_pesos';

CREATE OR REPLACE FUNCTION public.live2_fila()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_p     jsonb := coalesce((select valor from public.config_regras where chave = 'live2_pesos'), '{}'::jsonb);
  v_pad   numeric := coalesce((v_p ->> 'vale_padrao')::numeric, 380);
  v_hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
  v_cob_h int := coalesce((v_p ->> 'cobrar_de_novo_h')::int, 24);
  v_urg_h int := coalesce((v_p ->> 'cobrar_urgente_h')::int, 3);
  v_des_d int := coalesce((v_p ->> 'desistir_dias')::int, 7);
  v_rx    text := public._recusa_regex();
  v_risco numeric := coalesce((v_p #>> '{urgencia,venda_em_risco}')::numeric, 10);
  v_risco_h int := coalesce((v_p ->> 'risco_horas')::int, 48);
  v_res   jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    return null;
  end if;

  with j as materialized (
    select distinct on (k) x.*
      from (select coalesce(vj.venda_id::text, 'c:' || vj.conversa_id::text) as k, vj.* from public.v_jornada vj) x
     where x.k is not null
     order by x.k, x.precisa_acao desc
  ),
  est as materialized (
    select coalesce(e.venda_id::text, 'c:' || e.conversa_id::text) as k, e.conversa_id, e.venda_id, e.situacao, e.vez, e.prazo_em, e.em,
           s.nome as sit_nome, s.o_que_fazer as sit_fazer
      from public.lead_estado e
      left join public.config_situacao s on s.codigo = e.situacao
  ),
  conf as materialized (
    select x.tipo, x.chave, x.conversa_id, x.venda_id, x.nome, x.desde, x.texto, public._live2_tipo_conferir(x.tipo) as t6
      from jsonb_to_recordset(coalesce(public.live_conferir(), '[]'::jsonb))
           as x(tipo text, chave text, conversa_id uuid, venda_id uuid, nome text, desde timestamptz, texto text)
  ),
  cand as (
    -- (1) alarmes da jornada (o "Para fazer" de hoje)
    select j.k, j.conversa_id, j.venda_id,
           case when j.caixa = 5 or j.o_que_fazer like 'Resolvida no Chatwoot%' then 'decidir'
                when j.botao = 'abrir' and j.venda_id is not null and j.o_que_fazer like 'Crédito aprovado%' then 'venda'
                else public._live2_tipo_botao(j.botao) end as tipo,
           'jornada'::text as fonte, j.botao as sub, null::text as chave, j.nome, j.o_que_fazer as oque, j.desde, null::timestamptz as prazo_em,
           case when j.caixa <> 5 and public._live2_tipo_botao(j.botao) = 'responder' then 4 when j.nivel = 'agora' then 3 when j.nivel = 'hoje' then 2 else 1 end as urg,
           null::jsonb as extra, 1 as pri
      from j where j.precisa_acao
    union all
    -- (2) a vez é do time na situação gravada
    select e.k, e.conversa_id, e.venda_id, public._live2_tipo_situacao(e.situacao), 'situacao', e.situacao, null, null,
           coalesce(case when e.situacao = 'time_agora' and e.venda_id is null and e.conversa_id is not null
                         then public._cutucada_texto(e.conversa_id) end, e.sit_fazer, e.sit_nome),
           coalesce(e.prazo_em, e.em), e.prazo_em,
           case when e.situacao = 'time_agora' then 4
                when e.situacao in ('qualificado_os', 'instalacao_agendar') and e.prazo_em is not null and e.prazo_em <= now() then 3 else 2 end,
           null::jsonb, 2
      from est e where e.vez = 'time' and e.k is not null
    union all
    -- (3) prazo gravado vencido há mais de 1 h, com a vez de outro: ninguém parado em silêncio
    select e.k, e.conversa_id, e.venda_id, 'decidir', 'prazo', e.situacao, null, null,
           case when e.situacao = 'em_espera' then 'A data combinada da espera passou · retomar, marcar nova data ou dar Saída'
                when e.situacao = 'qualificado_biometria' then 'O cliente ainda não fez a biometria (prazo vencido)'
                else 'O cliente não respondeu no prazo' end,
           e.prazo_em, e.prazo_em, 2, null::jsonb, 4
      from est e
     where coalesce(e.vez, '') <> 'time' and e.k is not null and e.prazo_em < now() - interval '1 hour'
       and e.situacao in ('time_esperando', 'qualificado_biometria', 'em_espera')
       and not exists (select 1 from j where j.k = e.k and j.precisa_acao and j.botao in ('biometria', 'cartao'))
    union all
    -- (4) avisos do Conferir que são tarefa sobre um cliente
    select coalesce(c.venda_id::text, 'c:' || c.conversa_id::text), c.conversa_id, c.venda_id, c.t6, 'conferir', c.tipo, c.chave, c.nome, c.texto,
           c.desde, null::timestamptz,
           case when c.tipo = 'retorno_agora' or c.texto ~* '(VENCIDO|ATRASAD|cancelou|sem técnico)' then 3 else 2 end,
           null::jsonb, 3
      from conf c where c.t6 <> 'sistema' and (c.conversa_id is not null or c.venda_id is not null)
    union all
    -- (5) andamento na Nio sem venda (pedido do portal a casar, biometria sem dono)
    select 'p:' || p.tipo || ':' || p.chave, null::uuid, null::uuid, 'nio', 'andamento', p.tipo, p.chave,
           case when p.tipo = 'casar_pedido' then coalesce(p.nome, 'Cliente') else 'Protocolo ' || p.chave end,
           case when p.tipo = 'casar_pedido' then format('Pedido %s do portal (%s) sem venda no NIOGEN — escolha a venda certa', p.chave, p.rotulo)
                else coalesce(p.alerta, format('Biometria %s (GED360: %s) sem venda aberta no NIOGEN — confira de quem é', p.chave, p.rotulo)) end,
           p.desde, null::timestamptz, case when p.alerta is not null then 3 else 2 end,
           case when p.tipo = 'casar_pedido' then p.sugestoes else null end, 5
      from public.v_andamento_pendencias p
  ),
  -- o lead de cada chave: nome, cidade, plano, etapa e de quem é
  info as (
    select q.k,
           coalesce(jj.conversa_id, q.conversa_id, mcv.id) as conversa_id,
           coalesce(jj.venda_id, q.venda_id) as venda_id,
           coalesce(jj.nome, q.nome, 'Cliente') as nome,
           coalesce(jj.cidade, mc.cidade, vv.cidade) as cidade,
           coalesce(jj.plano, pl.nome_curto, pl.nome) as plano,
           jj.etapa, jj.etapa_nome, jj.caixa, jj.dono_nome,
           mc.telefone, mc.funil_etapa,
           ee.situacao, ee.sit_nome, ee.vez,
           coalesce(nullif(vv.comissao_prevista, 0), pl.comissao + coalesce(bo.valor, 0)) as vale
      from (select k, max(conversa_id::text)::uuid as conversa_id, max(venda_id::text)::uuid as venda_id, max(nome) as nome from cand group by k) q
      left join j jj on jj.k = q.k
      left join public.vendas vv on vv.id = coalesce(jj.venda_id, q.venda_id)
      left join lateral (select m.id from public.mari_conversas m where m.venda_id = vv.id order by m.updated_at desc limit 1) mcv
             on coalesce(jj.conversa_id, q.conversa_id) is null and vv.id is not null
      left join public.mari_conversas mc on mc.id = coalesce(jj.conversa_id, q.conversa_id, mcv.id)
      left join public.config_planos pl on (vv.plano_id is not null and pl.id = vv.plano_id) or (vv.plano_id is null and pl.codigo = mc.plano_escolhido)
      left join lateral (select b.valor from public.config_bonus b where b.tipo = 'transicao' and b.cluster = pl.cluster
                           and b.valido_de <= v_hoje and (b.valido_ate is null or b.valido_ate >= v_hoje) limit 1) bo on true
      left join lateral (select e.situacao, e.sit_nome, e.vez from est e where e.k = q.k limit 1) ee on true
  ),
  pes0 as (
    select c.*, i.nome as lead_nome, i.cidade, i.plano, i.etapa, i.etapa_nome, i.caixa, i.dono_nome, i.telefone, i.funil_etapa,
           i.situacao, i.sit_nome, i.vez, i.vale, i.conversa_id as conv, i.venda_id as vend,
           case when i.etapa in (3) then coalesce((v_p #>> '{etapa,pedido}')::numeric, 6)
                when i.etapa = 4 then coalesce((v_p #>> '{etapa,instalacao}')::numeric, 6)
                when i.etapa = 2 or (coalesce(i.etapa, 1) = 1 and i.funil_etapa in ('qualificada', 'biometria', 'agendada')) then coalesce((v_p #>> '{etapa,qualificado}')::numeric, 5)
                when i.etapa = 5 then coalesce((v_p #>> '{etapa,instalada}')::numeric, 2)
                when coalesce(i.etapa, 1) = 1 and i.funil_etapa in ('viu_planos', 'viavel') then coalesce((v_p #>> '{etapa,viu_planos}')::numeric, 2)
                when i.etapa = 0 then coalesce((v_p #>> '{etapa,saida}')::numeric, 1)
                else coalesce((v_p #>> '{etapa,conversa}')::numeric, 1) end as pe
      from cand c join info i on i.k = c.k
  ),
  -- 0394: quem falou por último em cada lead candidato e a baixa em vigor (Já cobrei / Adiar)
  ctx as materialized (
    select q.k,
           (select max(t.created_at) from public.mari_turnos t where t.conversa_id = q.conv and t.papel = 'humano') as ult_time,
           (select max(t.created_at) from public.mari_turnos t where t.conversa_id = q.conv and t.papel = 'lead') as ult_lead,
           (select btrim(regexp_replace(coalesce(t.texto, ''), '\s+', ' ', 'g')) from public.mari_turnos t
             where t.conversa_id = q.conv and t.papel = 'lead' order by t.created_at desc limit 1) as ult_lead_txt,
           q.etapa_k,
           (select max(s.em) from public.porta_sombra s where s.conversa_id = q.conv and s.evento = 'mari_passou:urgencia_alta'
               and s.em > now() - make_interval(hours => v_risco_h)) as risco_em,
           (select m.dados ->> 'risco_venda' from public.mari_conversas m where m.id = q.conv) as risco_tipo,
           b.em as baixa_em, b.ate as baixa_ate, b.como as baixa_como
      from (select p.k, p.conv, max(coalesce(p.etapa, 1)) as etapa_k from pes0 p group by p.k, p.conv) q
      left join lateral (select x.em, x.ate, x.como from public.live2_baixas x where x.k = q.k and x.ate > now() order by x.em desc limit 1) b on true
  ),
  -- cobrança = a tarefa é do CLIENTE (biometria, cartão, responder no prazo): o que cabe ao time é cobrar
  pes1a as (
    select p.*, x.ult_time, x.ult_lead, x.baixa_em, x.baixa_ate, x.baixa_como, x.ult_lead_txt, x.risco_tipo,
           -- 0401: a Mari acionou o time por urgência (pressa na instalação, ameaça de desistir) e NINGUÉM do time falou depois
           coalesce(x.risco_em is not null and (x.ult_time is null or x.ult_time < x.risco_em), false) as risco,
           -- 0398: a última fala do cliente foi uma recusa curta, o time já respondeu depois dela e a venda ainda não tem OS
           coalesce(x.ult_time > x.ult_lead and x.etapa_k <= 3 and length(x.ult_lead_txt) between 1 and 80 and x.ult_lead_txt ~* v_rx, false) as recusa,
           (p.tipo <> 'responder' and (
              (p.fonte = 'jornada' and p.sub in ('biometria', 'cartao')
                 and p.oque ~* '(esperando a biometria|biometria pendente h|biometria da nio voltou|cart[aã]o sem cadastro|cart[aã]o n[aã]o (foi )?cadastrado)')
              or (p.fonte = 'prazo' and p.sub in ('time_esperando', 'qualificado_biometria'))
              or (p.fonte = 'conferir' and p.sub = 'janela_fechada'))) as cobranca
      from pes0 p join ctx x on x.k = p.k
  ),
  -- cob_desde = desde quando se cobra este lead; sinal_em = último sinal do cliente (ou o começo da cobrança, o que for mais novo)
  pes1 as (
    select q.*, min(q.desde) filter (where q.cobranca) over (partition by q.k) as cob_desde,
           greatest(q.ult_lead, min(q.desde) filter (where q.cobranca) over (partition by q.k)) as sinal_em
      from pes1a q
  ),
  pes2 as (
    select p.k, p.conversa_id, p.venda_id,
           case when p.cobranca and p.sinal_em < now() - make_interval(days => v_des_d) then 'decidir' when p.cobranca then 'ligar' else p.tipo end as tipo,
           p.fonte, p.sub, p.chave, p.nome,
           case when p.cobranca and p.sinal_em < now() - make_interval(days => v_des_d)
                  then format('Sem resposta do cliente há %s dias · combinar uma data ou dar Saída · %s', floor(extract(epoch from now() - p.sinal_em) / 86400)::int, p.oque)
                when p.cobranca and p.fonte in ('jornada', 'prazo') then 'Cobrar o cliente · ' || p.oque
                else p.oque end as oque,
           p.desde, p.prazo_em,
           case when p.risco then 5
                when p.cobranca and p.fonte = 'jornada' and p.sub = 'cartao' then p.urg
                when p.cobranca and p.ult_time > p.cob_desde then 1
                when p.cobranca then 2
                else p.urg end as urg,
           p.extra, p.pri, p.lead_nome, p.cidade, p.plano, p.etapa, p.etapa_nome, p.caixa, p.dono_nome, p.telefone, p.funil_etapa,
           p.situacao, p.sit_nome, p.vez, p.vale, p.conv, p.vend, p.pe, p.cobranca, p.ult_time, p.ult_lead, p.recusa, p.ult_lead_txt, p.risco, p.risco_tipo
      from pes1 p
           -- baixa dada na tela vale até a hora marcada, ou até o cliente escrever de novo; nunca esconde "cliente esperando resposta"
     where (p.risco or not (p.tipo <> 'responder' and p.baixa_ate is not null and (p.ult_lead is null or p.ult_lead <= p.baixa_em)))
           -- agir dá baixa: o time falou por último e há pouco → a bola está com o cliente
       and not (p.cobranca and not p.recusa and not p.risco and p.ult_time is not null and p.ult_time > coalesce(p.ult_lead, '-infinity'::timestamptz)
                and p.ult_time > now() - make_interval(hours => case when p.sub = 'cartao' and p.urg >= 3 then v_urg_h else v_cob_h end)
                and (p.fonte <> 'conferir' or p.ult_time > p.desde))
  ),
  pes as (
    select p.*,
           case p.urg when 5 then v_risco
                      when 4 then coalesce((v_p #>> '{urgencia,cliente_esperando}')::numeric, 4)
                      when 3 then coalesce((v_p #>> '{urgencia,agora}')::numeric, 3)
                      when 2 then coalesce((v_p #>> '{urgencia,hoje}')::numeric, 2)
                      else coalesce((v_p #>> '{urgencia,sem_prazo}')::numeric, 1) end as pu
      from pes2 p
  ),
  ord as (
    select q.*, row_number() over (partition by q.k order by (q.bloq and not q.tem_resp) desc, q.urg desc, q.pri) as rn
      from (select p.*, (p.fonte = 'conferir' and p.sub = 'conferir_unidade') as bloq,
                   bool_or(p.tipo = 'responder') over (partition by p.k) as tem_resp,
                   max(p.urg) over (partition by p.k) as urg_max, max(p.pu) over (partition by p.k) as pu_max
              from pes p) q
  ),
  linhas as (
    select o.k, o.conv as conversa_id, o.vend as venda_id,
           case when o.risco then 'responder'
                when o.recusa then 'decidir'
                when o.fonte = 'conferir' and o.sub = 'conferir_unidade'
                 and exists (select 1 from pes x where x.k = o.k and x.fonte = 'conferir' and x.sub = 'janela_fechada') then 'ligar' else o.tipo end as tipo,
           o.fonte, o.sub, o.lead_nome as nome, o.cidade, o.plano, o.etapa, o.etapa_nome,
           o.situacao, o.sit_nome, o.vez, o.caixa, o.dono_nome,
           case when o.risco then 'Venda em risco · ' || case o.risco_tipo
                       when 'pressa' then 'o cliente quer a instalação para já: assumir AGORA e tentar encaixar na agenda da Nio'
                       when 'desiste' then 'o cliente falou em desistir na hora de marcar a instalação: assumir AGORA e combinar outro dia'
                       else 'a Mari acionou o time por urgência: assumir AGORA' end
                when o.recusa then format('O cliente recusou: «%s» (%s) · registrar a Saída, ou retomar se fizer sentido', o.ult_lead_txt,
                                          to_char(o.ult_lead at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')) else o.oque end as oque,
           o.desde, case when o.recusa then 1 else o.urg_max end as urg, o.pe,
           case when o.recusa then coalesce((v_p #>> '{urgencia,sem_prazo}')::numeric, 1) else o.pu_max end as pu,
           coalesce(o.vale, v_pad) as vale, (o.vale is null) as vale_estimado,
           round(coalesce(o.vale, v_pad) * o.pe * case when o.recusa then coalesce((v_p #>> '{urgencia,sem_prazo}')::numeric, 1) else o.pu_max end) as pontos,
           coalesce(o.prazo_em, (select min(x.prazo_em) from pes x where x.k = o.k)) as prazo_em,
           (select coalesce(jsonb_agg(distinct x.oque), '[]'::jsonb) from pes x where x.k = o.k and (x.oque is distinct from o.oque or o.recusa or o.risco) and x.oque is not null
               and not (x.fonte = 'situacao' and exists (select 1 from pes y where y.k = o.k and y.fonte = 'jornada'))) as motivos,
           (select coalesce(jsonb_agg(distinct x.fonte || coalesce(':' || x.sub, '')), '[]'::jsonb) from pes x where x.k = o.k) as fontes,
           -- os botões: os da linha escolhida primeiro, depois os dos outros avisos do mesmo lead (sem repetir "abrir")
           o.cobranca, o.recusa, o.risco,
           case when o.recusa then jsonb_build_array(jsonb_build_object('a', 'saida', 'rotulo', 'Registrar a Saída', 'principal', true)) else '[]'::jsonb end ||
           case when o.cobranca then
                  jsonb_build_array(jsonb_build_object('a', 'abrir', 'rotulo', 'Falar com o cliente', 'principal', true))
                  || case when coalesce(o.telefone, '') <> '' and not exists (select 1 from pes x where x.k = o.k and x.fonte = 'conferir' and x.sub = 'janela_fechada')
                          then jsonb_build_array(jsonb_build_object('a', 'tel', 'rotulo', 'Ligar', 'tel', case when length(o.telefone) <= 11 then '55' || o.telefone else o.telefone end))
                          else '[]'::jsonb end
                  || jsonb_build_array(jsonb_build_object('a', 'rpc', 'fn', 'live2_baixa', 'rotulo', 'Já cobrei ✓', 'leve', true,
                                                          'args', jsonb_build_object('p_k', o.k, 'p_como', 'cobrei')))
                else '[]'::jsonb end ||
           (select coalesce(jsonb_agg(b.b order by b.o1, b.o2), '[]'::jsonb)
              from (select distinct on (coalesce(b0 ->> 'fn', b0 ->> 'a') || coalesce(b0 -> 'args' ->> 'p_acao', '') || coalesce(b0 -> 'args' ->> 'p_resultado', '') || coalesce(b0 -> 'args' ->> 'p_como', '') || coalesce(b0 -> 'args' ->> 'p_venda', ''))
                           b0 as b, case when x.k is not null and x.fonte = o.fonte and x.sub is not distinct from o.sub then 0 else 1 end as o1, t.ord as o2
                      from pes x
                      cross join lateral jsonb_array_elements(public._live2_acoes(x.fonte, x.sub, x.chave, o.conv, o.vend, x.tipo, x.sub, o.telefone, x.extra)) with ordinality t(b0, ord)
                     where x.k = o.k and not (x.cobranca and x.fonte in ('jornada', 'prazo'))
                     order by coalesce(b0 ->> 'fn', b0 ->> 'a') || coalesce(b0 -> 'args' ->> 'p_acao', '') || coalesce(b0 -> 'args' ->> 'p_resultado', '') || coalesce(b0 -> 'args' ->> 'p_como', '') || coalesce(b0 -> 'args' ->> 'p_venda', ''),
                              case when x.fonte = o.fonte and x.sub is not distinct from o.sub then 0 else 1 end, t.ord) b) as acoes
      from ord o where o.rn = 1
  ),
  fila as (
    select l.*, uf.texto as ultima_fala, uf.created_at as ultima_fala_em,
           -- Adiar = Em espera com data (backoffice_conversa_espera), que só vale para conversa sem venda; venda adia pela Pendência da ficha
           (l.conversa_id is not null and l.venda_id is null and coalesce(l.caixa, 0) between 1 and 5 and coalesce(l.situacao, '') not in ('em_espera')) as pode_adiar,
           ((l.conversa_id is not null or l.venda_id is not null) and coalesce(l.caixa, 0) between 1 and 5) as pode_sair,
           ((l.cobranca or l.tipo = 'decidir') and (l.conversa_id is not null or l.venda_id is not null)
            and not (l.conversa_id is not null and l.venda_id is null and coalesce(l.caixa, 0) between 1 and 5 and coalesce(l.situacao, '') not in ('em_espera'))) as pode_pausar
      from linhas l
      left join lateral (select left(regexp_replace(coalesce(t.texto, ''), '\s+', ' ', 'g'), 220) as texto, t.created_at
                           from public.mari_turnos t where t.conversa_id = l.conversa_id and t.papel = 'lead'
                          order by t.created_at desc limit 1) uf on l.conversa_id is not null
  ),
  vivos as (select j.* from j where j.caixa between 1 and 5),
  pausa as (
    select distinct on (p.k) p.k, p.lead_nome as nome, p.cidade, p.plano, p.etapa_nome, p.oque, p.ult_time as desde,
           case when p.baixa_ate is not null and (p.ult_lead is null or p.ult_lead <= p.baixa_em) then p.baixa_ate
                else p.ult_time + make_interval(hours => case when p.sub = 'cartao' and p.urg >= 3 then v_urg_h else v_cob_h end) end as volta_em,
           case when p.baixa_ate is not null and (p.ult_lead is null or p.ult_lead <= p.baixa_em)
                then case p.baixa_como when 'cobrei' then 'você cobrou' else 'adiada por você' end
                else 'você falou por último' end as motivo
      from pes1 p where not exists (select 1 from fila f where f.k = p.k)
     order by p.k, p.pri
  ),
  fora as (select v.* from vivos v where not exists (select 1 from fila f where f.k = v.k) and not exists (select 1 from pausa p where p.k = v.k))
  select jsonb_build_object(
    'carimbo', now(),
    'pesos', v_p,
    'fila', coalesce((select jsonb_agg(jsonb_build_object(
               'k', f.k, 'conversa_id', f.conversa_id, 'venda_id', f.venda_id, 'tipo', f.tipo, 'fonte', f.fonte, 'sub', f.sub,
               'nome', f.nome, 'cidade', f.cidade, 'plano', f.plano, 'etapa', f.etapa, 'etapa_nome', f.etapa_nome,
               'situacao', f.situacao, 'situacao_nome', f.sit_nome, 'vez', coalesce(f.vez, 'time'), 'dono', f.dono_nome,
               'oque', f.oque, 'motivos', f.motivos, 'fontes', f.fontes, 'desde', f.desde, 'prazo_em', f.prazo_em,
               'urg', f.urg, 'pe', f.pe, 'pu', f.pu, 'vale', f.vale, 'vale_estimado', f.vale_estimado, 'pontos', f.pontos,
               'ultima_fala', f.ultima_fala, 'ultima_fala_em', f.ultima_fala_em,
               'acoes', f.acoes, 'pode_adiar', f.pode_adiar, 'pode_sair', f.pode_sair, 'pode_pausar', f.pode_pausar, 'cobranca', f.cobranca, 'recusa', f.recusa, 'risco', f.risco)
               order by f.risco desc, f.pontos desc, f.desde nulls last, f.k) from fila f), '[]'::jsonb),
    'conta', jsonb_build_object(
      'vivos', (select count(*) from vivos),
      'na_fila', (select count(*) from vivos v where exists (select 1 from fila f where f.k = v.k)),
      'em_pausa', (select count(*) from vivos v where exists (select 1 from pausa p where p.k = v.k)),
      'com_mari', (select count(*) from fora where caixa = 1),
      'esperando_cliente', (select count(*) from fora where caixa = 3),
      'esperando_nio', (select count(*) from fora where caixa = 4),
      'sem_lugar', (select count(*) from fora where caixa not in (1, 3, 4)),
      'tarefas', (select count(*) from fila),
      'em_risco', (select count(*) from fila where risco),
      'tarefas_de_encerrados', (select count(*) from fila f where not exists (select 1 from vivos v where v.k = f.k)),
      'em_jogo', (select coalesce(sum(f.vale), 0) from fila f where exists (select 1 from vivos v where v.k = f.k))),
    'radar', jsonb_build_object(
      'em_pausa', coalesce((select jsonb_agg(jsonb_build_object('k', p.k, 'nome', p.nome, 'cidade', p.cidade, 'plano', p.plano, 'etapa_nome', p.etapa_nome,
                    'oque', p.oque, 'desde', p.desde, 'volta_em', p.volta_em, 'motivo', p.motivo) order by p.volta_em) from pausa p), '[]'::jsonb),
      'com_mari', coalesce((select jsonb_agg(x order by x ->> 'desde' desc) from (select jsonb_build_object('k', k, 'nome', nome, 'cidade', cidade, 'plano', plano,
                    'etapa_nome', etapa_nome, 'oque', o_que_fazer, 'desde', desde, 'proximo_toque_em', proximo_toque_em) x from fora where caixa = 1 order by desde desc nulls last limit 60) y), '[]'::jsonb),
      'esperando_cliente', coalesce((select jsonb_agg(jsonb_build_object('k', k, 'nome', nome, 'cidade', cidade, 'plano', plano,
                    'etapa_nome', etapa_nome, 'oque', o_que_fazer, 'desde', desde, 'dono', dono_nome) order by desde) from fora where caixa = 3), '[]'::jsonb),
      'esperando_nio', coalesce((select jsonb_agg(jsonb_build_object('k', k, 'nome', nome, 'cidade', cidade, 'plano', plano,
                    'etapa_nome', etapa_nome, 'oque', o_que_fazer, 'desde', desde) order by desde) from fora where caixa = 4), '[]'::jsonb),
      'sem_lugar', coalesce((select jsonb_agg(jsonb_build_object('k', k, 'nome', nome, 'etapa_nome', etapa_nome, 'oque', o_que_fazer, 'desde', desde)) from fora where caixa not in (1, 3, 4)), '[]'::jsonb)),
    'sistema', coalesce((select jsonb_agg(jsonb_build_object('tipo', c.tipo, 'chave', c.chave, 'nome', c.nome, 'texto', c.texto, 'desde', c.desde,
                    'k', coalesce(c.venda_id::text, 'c:' || c.conversa_id::text),
                    'acoes', public._live2_acoes('conferir', c.tipo, c.chave, c.conversa_id, c.venda_id, 'sistema', null, null, null)) order by c.desde)
                  from conf c where c.t6 = 'sistema' or (c.conversa_id is null and c.venda_id is null)), '[]'::jsonb),
    'reforco', coalesce(public._live2_reforco(), '[]'::jsonb),
    'feitos', (select count(*) from public.porta_sombra s where s.por = auth.uid()
                and s.em >= (date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo')),
    'cobertura', jsonb_build_object(
      'rodada_em', (select c.rodada_em from public.live2_cobertura c where c.parceiro_id = 'dharma'),
      'esperando', (select c.esperando from public.live2_cobertura c where c.parceiro_id = 'dharma'),
      'furos', coalesce((select jsonb_agg(jsonb_build_object('conversa_id', f.conversa_id, 'nome', f.nome, 'desde', f.desde) order by f.desde)
                           from public.live2_furos f where f.fechado_em is null), '[]'::jsonb)))
    into v_res;
  return v_res;
end $function$;


-- a medição dos resgates: o que a Mari passou por urgência, em quanto tempo uma pessoa respondeu e no que deu
create or replace function public.live2_resgates(p_dias int default 30) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    return null;
  end if;
  with ev as (
    select s.conversa_id, min(s.em) as em
      from public.porta_sombra s
     where s.evento = 'mari_passou:urgencia_alta' and s.em >= now() - make_interval(days => greatest(1, least(coalesce(p_dias, 30), 365)))
     group by s.conversa_id, (s.em at time zone 'America/Sao_Paulo')::date
  ),
  r as (
    select e.conversa_id, e.em, m.lead_numero, coalesce(m.dados ->> 'risco_venda', 'urgencia') as tipo,
           (select min(t.created_at) from public.mari_turnos t where t.conversa_id = e.conversa_id and t.papel = 'humano' and t.created_at > e.em) as respondeu_em,
           v.status as venda_status, (coalesce(btrim(v.nio_pedido), '') <> '' or coalesce(btrim(v.nio_os), '') <> '') as com_pedido,
           coalesce(m.funil_destino, 'em_andamento') as destino
      from ev e
      join public.mari_conversas m on m.id = e.conversa_id
      left join public.vendas v on v.id = m.venda_id
     where coalesce(m.funil_destino, '') not like 'teste%'
  ),
  x as (
    select r.*, round(extract(epoch from r.respondeu_em - r.em) / 60.0)::int as minutos,
           case when r.venda_status = '3_instalado' then 'instalada'
                when r.venda_status = 'saida' or r.destino not in ('em_andamento', 'instalada') then 'saida'
                when r.com_pedido or r.venda_status = '1_vendido' then 'pedido'
                else 'em_andamento' end as deu
      from r
  )
  select jsonb_build_object(
    'dias', p_dias,
    'total', (select count(*) from x),
    'ate_5min', (select count(*) from x where minutos <= 5),
    'ate_30min', (select count(*) from x where minutos <= 30),
    'sem_resposta', (select count(*) from x where respondeu_em is null),
    'mediana_min', (select percentile_cont(0.5) within group (order by minutos) from x where minutos is not null),
    'pedido', (select count(*) from x where deu in ('pedido', 'instalada')),
    'instalada', (select count(*) from x where deu = 'instalada'),
    'saida', (select count(*) from x where deu = 'saida'),
    'em_andamento', (select count(*) from x where deu = 'em_andamento'),
    'lista', coalesce((select jsonb_agg(jsonb_build_object('conversa_id', x.conversa_id, 'lead', x.lead_numero, 'em', x.em, 'tipo', x.tipo,
                         'minutos', x.minutos, 'deu', x.deu) order by x.em desc) from x), '[]'::jsonb))
    into v;
  return v;
end $$;
revoke all on function public.live2_resgates(int) from public, anon;
grant execute on function public.live2_resgates(int) to authenticated;

commit;
