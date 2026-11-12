-- NIOGEN | 0151_destino_elegivel_200m.sql | 12/11/2026 — Claude Code (pedido do Ricardo: "Sim, revisa")
-- Resumo: 4 conversas de BH tinham o operador dizendo "elegível 200 m" (fachada viável a 5–135 m) e o portal "sem viabilidade".
-- A regra dura do destino (0147) seguia o portal, marcava "sem cobertura" e o gatilho resolvia a conversa no Chatwoot,
-- embora a Mari tivesse seguido para planos/coleta. Agora:
--   1. _funil_calcular: o portal "sem_viabilidade" só vira saída "sem_cobertura" se o operador NÃO decidiu viavel/elegivel_200m
--      (cobertura_decisao = 'sem_cobertura' continua valendo sempre).
--   2. _funil_antes: conversa que estava em "sem_cobertura" pela regra dura e deixou de cumpri-la volta para em_andamento
--      (ou para a saída de evento que existir, ex.: Saída da conversa "perdida" marcada pelo backoffice).
--   3. Correção: recalcula as conversas afetadas e reabre no Chatwoot as que voltaram para em_andamento.
-- Corpo das duas funções = cópia da 0147 com só esses dois trechos trocados.

create or replace function public._funil_calcular(c public.mari_conversas)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  v        public.vendas;
  tel      text := regexp_replace(coalesce(c.telefone, ''), '\D', '', 'g');
  teste    boolean;
  viavel   boolean; viav_pend boolean; cliente boolean;
  pedido   boolean; bio boolean; agendada boolean; instalada boolean; qualif boolean; viu boolean;
  respondeu boolean := false;
  etapa    text;
  duro     text; duro_det text;
  evento   text; evento_det text;
  quadro   text := public._funil_destino_quadro(c.quadro_encerrada_motivo);
  hand     text := public._funil_destino_handoff(c.handoff_motivo);
begin
  if c.venda_id is not null then select * into v from public.vendas where id = c.venda_id; end if;
  teste := coalesce(c.canal, '') = 'teste' or tel like '5500000000%'
        or tel = any (coalesce((select array_remove(regexp_split_to_array(regexp_replace(coalesce(texto, ''), '[^0-9,]', '', 'g'), ','), '')
                                  from public.config_mari_textos where chave = 'telefones_teste'), '{}'::text[]));
  viavel    := coalesce(c.cobertura_decisao in ('viavel', 'elegivel_200m') or c.nio_viab_resultado = 'viavel' or v.nio_viab_resultado = 'viavel', false);
  viav_pend := coalesce(c.cobertura_decisao = 'unidade_fora_lista', false);       -- decisão 1: viável com pendência (não qualifica sozinha)
  pedido    := coalesce(v.nio_pedido is not null or v.nio_os is not null
            or v.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'), false);
  cliente   := coalesce(c.elegibilidade = 'ja_cliente' or c.handoff_motivo = 'ja_cliente_nio' or c.quadro_encerrada_motivo = 'suporte_nio'
            or ((c.credito_resultado = 'pedido_em_andamento' or c.nio_pedido_aberto = 'sim') and not pedido), false);  -- decisões 2 e 3
  bio       := v.biometria_status = 'validada';
  agendada  := v.instalacao_agendada_para is not null or v.status in ('2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme');
  instalada := v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme');
  viu       := c.plano_escolhido is not null or c.etapa in ('planos', 'coleta', 'resumo') or c.handoff_motivo = 'dados_completos' or v.id is not null;
  qualif    := coalesce(c.handoff_motivo = 'dados_completos' or v.id is not null, false) and viavel and not cliente
            and coalesce(c.credito_resultado, '') not like 'negado%' and coalesce(v.motivo_saida, '') !~* 'cr[eé]dito';
  if c.id is not null and c.ultima_msg_lead_at is not null and coalesce(c.funil_etapa, 'nova') = 'nova' then
    select count(*) >= 2 into respondeu from (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' limit 2) x;
  end if;

  etapa := case
    when coalesce(instalada, false) then 'instalada'
    when coalesce(agendada, false)  then 'agendada'
    when coalesce(bio, false)       then 'biometria'
    when coalesce(pedido, false)    then 'pedido'
    when coalesce(qualif, false)    then 'qualificada'
    when coalesce(viu, false)       then 'viu_planos'
    when coalesce(viavel or viav_pend, false) then 'viavel'
    when c.dentro_area is true      then 'area_ok'
    when c.cep is not null          then 'cep'
    when respondeu or coalesce(c.funil_etapa, 'nova') <> 'nova' then 'respondeu'
    else 'nova' end;

  -- saída dura (na ordem de prioridade)
  if teste then duro := 'teste_duplicada'; duro_det := 'telefone ou canal de teste';
  elsif coalesce(instalada, false) then duro := 'instalada'; duro_det := 'instalada';
  elsif cliente then duro := 'ja_cliente_nio';
    duro_det := case when c.quadro_encerrada_motivo = 'suporte_nio' then 'suporte Nio'
                     when c.elegibilidade = 'ja_cliente' or c.handoff_motivo = 'ja_cliente_nio' then 'elegibilidade: já cliente'
                     else 'pedido Nio em andamento (não é nosso)' end;
  elsif c.dentro_area is false or c.elegibilidade = 'fora_area' then duro := 'fora_area'; duro_det := 'CEP fora da área';
  elsif c.cobertura_decisao = 'sem_cobertura'
        or (c.nio_viab_resultado = 'sem_viabilidade' and coalesce(c.cobertura_decisao, '') not in ('viavel', 'elegivel_200m')) then
    duro := 'sem_cobertura'; duro_det := 'viabilidade: sem cobertura';   -- 0151: operador elegível (fachada a ≤ 200 m) vence o portal
  elsif coalesce(c.nao_contatar, false) then duro := 'recusou'; duro_det := 'não contatar';
  end if;

  -- saída de evento: cada fonte em separado (o gatilho só aplica a fonte que acabou de mudar) + a primeira pela prioridade
  return jsonb_build_object('etapa', etapa, 'duro', duro, 'duro_det', duro_det,
    'venda',   case when v.status = 'saida' then public.funil_destino_de_motivo(v.motivo_saida) end,
    'venda_det', 'venda: ' || coalesce(v.motivo_saida, 'sem motivo'),
    'quadro',  quadro, 'quadro_det', 'Saída da conversa: ' || c.quadro_encerrada_motivo,
    'hand',    hand,   'hand_det', 'Mari: ' || c.handoff_motivo,
    'cad',     case when c.cadencia_passo = 'encerrada' then 'sem_resposta' end, 'cad_det', 'cadência esgotada',
    'evento',  coalesce(case when v.status = 'saida' then public.funil_destino_de_motivo(v.motivo_saida) end, quadro, hand,
                        case when c.cadencia_passo = 'encerrada' then 'sem_resposta' end),
    'evento_det', case when v.status = 'saida' then 'venda: ' || coalesce(v.motivo_saida, 'sem motivo')
                       when quadro is not null then 'Saída da conversa: ' || c.quadro_encerrada_motivo
                       when hand is not null then 'Mari: ' || c.handoff_motivo
                       when c.cadencia_passo = 'encerrada' then 'cadência esgotada' end);
end;
$$;

create or replace function public._funil_antes()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  d        jsonb;
  ev       text;
  novo     text; det text;
  ant      text := coalesce(new.funil_destino, 'em_andamento');
  saida_ev boolean;
begin
  d := public._funil_calcular(new);
  -- etapa: só sobe
  if new.funil_etapa is null or public._funil_ordem('etapa', d ->> 'etapa') > public._funil_ordem('etapa', new.funil_etapa) then
    new.funil_etapa := d ->> 'etapa';
  end if;

  -- qual fonte de evento acabou de mudar (só ela vale: um sinal velho não derruba uma conversa que o cliente reabriu)
  ev := case
    when new.funil_evento = 'venda' and d ->> 'venda' is not null then 'venda'
    when tg_op = 'UPDATE' and new.quadro_encerrada_motivo is distinct from old.quadro_encerrada_motivo and d ->> 'quadro' is not null then 'quadro'
    when tg_op = 'UPDATE' and new.handoff_motivo is distinct from old.handoff_motivo and d ->> 'hand' is not null then 'hand'
    when tg_op = 'UPDATE' and new.cadencia_passo is distinct from old.cadencia_passo and d ->> 'cad' is not null then 'cad' end;
  saida_ev := ant not in ('em_andamento', 'teste_duplicada', 'instalada');

  if d ->> 'duro' is not null and (ev is null
      or public._funil_ordem('destino', d ->> 'duro') <= public._funil_ordem('destino', d ->> ev)) then
    novo := d ->> 'duro'; det := d ->> 'duro_det';
  elsif ev is not null then
    novo := d ->> ev; det := d ->> (ev || '_det');
  elsif new.funil_evento = 'reabrir' then
    novo := 'em_andamento'; det := 'venda reativada';
  elsif tg_op = 'UPDATE' and ant = 'sem_cobertura' and old.funil_detalhe = 'viabilidade: sem cobertura' then
    novo := coalesce(d ->> 'evento', 'em_andamento');                                  -- 0151: o sem cobertura era a regra dura
    det  := coalesce(d ->> 'evento_det', 'cobertura revista: operador elegível (≤ 200 m)');  -- e ela não vale mais
  elsif tg_op = 'UPDATE' and old.funil_destino is not null and ant in ('teste_duplicada', 'instalada') then
    novo := 'em_andamento'; det := 'saída dura não vale mais';
  elsif saida_ev and new.ultima_msg_lead_at is not null and new.funil_destino_em is not null
        and new.ultima_msg_lead_at > new.funil_destino_em then
    novo := 'em_andamento'; det := 'cliente voltou a escrever';          -- reabre na mesma etapa
  elsif tg_op = 'UPDATE' and old.funil_destino is not null then
    novo := old.funil_destino; det := old.funil_detalhe;                 -- saída de evento fica
  else
    novo := coalesce(d ->> 'evento', 'em_andamento'); det := d ->> 'evento_det';   -- 1º cálculo (backfill / conversa nova)
  end if;

  if novo is distinct from new.funil_destino then
    new.funil_destino := novo;
    new.funil_detalhe := det;
    new.funil_destino_em := now();
    if novo <> 'em_andamento' then new.funil_alerta := null; new.funil_alerta_em := null; end if;   -- destino registrado: alerta some
  end if;
  new.funil_evento := null;
  return new;
exception when others then
  -- o funil nunca derruba a gravação da conversa: registra e segue sem recalcular
  insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (new.id, 'funil_antes', sqlerrm);
  new.funil_evento := null;
  return new;
end;
$$;

-- ───────────────────────── correção das conversas afetadas ─────────────────────────
create temp table _r151 on commit drop as
  select id from public.mari_conversas
   where funil_destino = 'sem_cobertura' and funil_detalhe = 'viabilidade: sem cobertura'
     and cobertura_decisao in ('viavel', 'elegivel_200m') and coalesce(nio_viab_resultado, '') = 'sem_viabilidade';

update public.mari_conversas c set funil_evento = 'revisao_0151' from _r151 r where c.id = r.id;

-- voltou para em_andamento e está resolvida no Chatwoot → reabre para o backoffice ver (mesmo caminho da 0101)
do $$
declare c public.mari_conversas;
begin
  for c in select m.* from public.mari_conversas m join _r151 r on r.id = m.id
            where m.funil_destino = 'em_andamento' and coalesce(m.chatwoot_status, 'open') = 'resolved'
              and coalesce(m.chatwoot_conversation_id, '') <> '' and coalesce(m.canal, '') = 'whatsapp'
  loop
    perform public._bo_enfileirar(gen_random_uuid(), 2, 'destino', c.venda_id, c, 'resolver', jsonb_build_object('status', 'open'));
  end loop;
end $$;
