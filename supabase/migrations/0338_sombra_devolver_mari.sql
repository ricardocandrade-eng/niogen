-- NIOGEN | supabase/migrations/0338_sombra_devolver_mari.sql | 20/11/2026 — Claude Code (Opus 5.5)
-- Achado da sombra do projetor (19–20/11), dois padrões da devolução para a Mari (0322, janela de 24 h fechada):
-- (1) 11 "contrária" em 4 dias (Chatwoot 42, 172, 176…): a ordem do Devolver (devolver_mari e volta_mari) tira o time e o juiz a comparava com a situação
--     de antes ("com o time · esperando"). A situação só vira mari_atendendo depois que o dono sai — e quem tira é esta ordem.
--     Agora a transação do Devolver é julgada pela situação de destino (a da regra momento:devolver_mari → mari_atendendo).
-- (2) 8 "falta resolver" (172, 176, 179, 180 às 21h): o prazo de 1 h fechou a conversa com o time; ela voltou para a Mari
--     fechada e a situação pede aberta. Com o projetor mandando, ele reabriria conversa de cliente calado há mais de um dia.
--     Agora: Mari atendendo com o cliente calado há 24 h aceita a conversa fechada (ordem de fechar não é contrária, ficar
--     fechada não é falta). Reabre quando alguém escrever, como já é hoje.
-- Ricardo, 20/11: "Sim, monta a 0336" (o número 0336 já era de outra sessão).
-- Só o juiz da sombra muda (nenhuma ordem nova, nada na tela). Função recriada da versão no ar (pg_get_functiondef de 20/11
-- ~22h), com os trechos marcados "0338". Cenário X64.
-- Regra 20: (1) nenhum dado novo; (2) nenhum destino; (3) tela: nada; (4) desempenho: uma consulta a mais por julgamento.
begin;

CREATE OR REPLACE FUNCTION public._projetor_sombra_julgar()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c public.mari_conversas; s text; cs public.config_situacao; r public.projetor_sombra; e jsonb;
  st text; ag text; tm text; etq jsonb; v text; mot text; quero jsonb; antes jsonb; adds jsonb; rems jsonb; e2 record;
  tem_agendada_resolver boolean := false;
  quente boolean := false;   -- 0335
  parada boolean := false;   -- 0338
begin
  if not exists (select 1 from public.projetor_sombra p where p.tx = new.tx and p.conversa_id is not distinct from new.conversa_id
                  and p.veredito = 'pendente') then
    return null;   -- outra linha desta transação já julgou esta conversa
  end if;
  begin
    select * into c from public.mari_conversas where id = new.conversa_id;
    s := case when c.id is null then '(sem conversa)' else public._porta_situacao(c.id, null::uuid) end;
    -- 0338: a devolução para a Mari (janela de 24 h fechada) é julgada pela situação de destino. A situação só vira
    -- mari_atendendo quando o dono sai de fato, e quem tira o dono é justamente esta ordem.
    if s in ('time_agora', 'time_esperando') and exists (select 1 from public.projetor_sombra p where p.tx = new.tx
         and p.conversa_id is not distinct from new.conversa_id and p.momento in ('devolver_mari', 'volta_mari')) then
      s := 'mari_atendendo';
    end if;
    select * into cs from public.config_situacao where codigo = s;
    -- 0338: Mari atendendo com o cliente calado há 24 h (a janela fechou; a cadência ou a Retomada segue) → a conversa pode
    -- ficar fechada no Chatwoot: ela reabre quando alguém escrever.
    parada := c.id is not null and s = 'mari_atendendo'
              and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead'
                               and t.created_at > now() - interval '24 hours');
    -- 0335: fora do andamento com o time falando nas últimas 24 h → aberta e com dono pode
    quente := c.id is not null and s in ('instalada', 'saida_pode_voltar', 'saida_definitiva', 'cliente_nio')
              and (exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano'
                            and t.created_at > now() - interval '24 hours')
                   or exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'mensagem'
                               and coalesce(a.payload ->> 'como', '') = 'humano' and a.status in ('pendente', 'executando', 'feita')
                               and a.criada_em > now() - interval '24 hours'));   -- a mensagem do time ainda na fila
    e := case when c.id is null then '{"add":[],"remove":[]}'::jsonb else public._projetor_etiquetas(c, s) end;
    -- o Chatwoot no fim da transação: o espelho de agora + as ordens desta transação que ainda não saíram
    st := coalesce(c.chatwoot_status, 'open'); ag := c.chatwoot_agente; tm := c.chatwoot_time;
    etq := to_jsonb(coalesce(c.chatwoot_etiquetas, '{}'::text[]));

    for r in select * from public.projetor_sombra p where p.tx = new.tx and p.conversa_id is not distinct from new.conversa_id
               and p.veredito = 'pendente' order by p.id loop
      antes := coalesce(r.cw_antes, '{}'::jsonb); v := 'igual'; mot := null;
      if exists (select 1 from public.projetor_sombra p where p.tx = r.tx and p.conversa_id is not distinct from r.conversa_id
                   and p.id < r.id and p.acao_id is not null and p.tipo = r.tipo and p.payload = r.payload) then
        v := 'repetida'; mot := 'a mesma ordem já entrou nesta transação';
      elsif r.executar_apos > r.em + interval '1 minute' then
        v := 'agendada'; mot := 'sai às ' || to_char(r.executar_apos at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ': julgar na hora';
      elsif r.tipo = 'resolver' then
        if cs.cw_status is not null and not ((r.payload ->> 'status') = any (cs.cw_status)) and not (quente and r.payload ->> 'status' = 'open')
           and not (parada and r.payload ->> 'status' = 'resolved') then
          v := 'contraria'; mot := 'situação ' || s || ' pede ' || array_to_string(cs.cw_status, '/') || ', a ordem põe ' || (r.payload ->> 'status');
        elsif antes ->> 'status' = r.payload ->> 'status' then
          v := 'a_mais'; mot := 'o Chatwoot já estava ' || (r.payload ->> 'status');
        end if;
      elsif r.tipo = 'atribuir' then
        if cs.dono = 'nenhum' and not quente then v := 'contraria'; mot := 'situação ' || s || ' é sem dono, a ordem põe dono'; end if;
      elsif r.tipo = 'desatribuir' then
        if r.payload ? 'team_id' and cs.dono = 'time' and (r.payload ->> 'team_id') is null then
          v := 'contraria'; mot := 'situação ' || s || ' é com o time, a ordem tira o time';
        elsif (r.payload ? 'assignee_id' and antes ->> 'agente' is null) or (r.payload ? 'team_id' and antes ->> 'time' is null) then
          v := 'a_mais'; mot := 'já estava sem ' || case when r.payload ? 'team_id' then 'time' else 'pessoa' end;
        end if;
      elsif r.tipo = 'etiquetas' then
        adds := coalesce(r.payload -> 'add', '[]'::jsonb); rems := coalesce(r.payload -> 'remove', '[]'::jsonb);
        if exists (select 1 from jsonb_array_elements_text(adds) x where (e -> 'remove') ? x)
           or exists (select 1 from jsonb_array_elements_text(rems) x where (e -> 'add') ? x) then
          v := 'contraria'; mot := 'situação ' || s || ' pede etiquetas ' || e::text;
        elsif not exists (select 1 from jsonb_array_elements_text(adds) x where not (coalesce(antes -> 'etiquetas', '[]'::jsonb) ? x))
          and not exists (select 1 from jsonb_array_elements_text(rems) x where coalesce(antes -> 'etiquetas', '[]'::jsonb) ? x) then
          v := 'a_mais'; mot := 'as etiquetas já estavam assim';
        end if;
      end if;
      update public.projetor_sombra set veredito = v, motivo = mot, situacao = s where id = r.id;
    end loop;

    -- o Chatwoot depois das ordens que ainda não saíram (desta e de transações anteriores; a que saiu já está no espelho)
    for e2 in select a.tipo, a.payload, a.executar_apos from public.chatwoot_acoes a
               where a.conversa_id = c.id and a.status in ('pendente', 'executando') order by a.id loop
      if e2.executar_apos > now() + interval '1 minute' then
        if e2.tipo = 'resolver' then tem_agendada_resolver := true; end if;
        continue;
      end if;
      if e2.tipo = 'resolver' then st := coalesce(e2.payload ->> 'status', st);
      elsif e2.tipo = 'atribuir' then
        if e2.payload ? 'assignee_id' then ag := coalesce(e2.payload ->> 'assignee_id', ag); end if;
        if e2.payload ? 'team_id' then tm := coalesce(e2.payload ->> 'team_id', tm); end if;
      elsif e2.tipo = 'desatribuir' then
        if e2.payload ? 'assignee_id' then ag := null; end if;
        if e2.payload ? 'team_id' then tm := null; end if;
      elsif e2.tipo = 'etiquetas' then
        etq := (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from (
                  select x from jsonb_array_elements_text(etq) x where not (coalesce(e2.payload -> 'remove', '[]'::jsonb) ? x)
                  union select x from jsonb_array_elements_text(coalesce(e2.payload -> 'add', '[]'::jsonb)) x) z);
      end if;
    end loop;

    -- o que a situação pede e nenhuma ordem pediu (o projetor mandaria) — só conversa de WhatsApp com Chatwoot, como no projetor
    if c.id is not null and coalesce(c.canal, '') = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> ''
       and coalesce(c.telefone, '') not like '5500000000%' then
      if cs.cw_status is not null and not (st = any (cs.cw_status)) and not tem_agendada_resolver and not quente
         and not (parada and st = 'resolved') then
        quero := jsonb_build_object('status', cs.cw_status[1]);
        insert into public.projetor_sombra (tx, conversa_id, momento, tipo, payload, situacao, veredito, motivo, mandaria)
        values (new.tx, c.id, 'projetor', 'resolver', null, s, 'falta', 'situação ' || s || ' pede ' || array_to_string(cs.cw_status, '/')
                || ', o Chatwoot fica ' || st, quero);
      end if;
      if cs.dono = 'nenhum' and (ag is not null or tm is not null) and not quente then
        insert into public.projetor_sombra (tx, conversa_id, momento, tipo, payload, situacao, veredito, motivo, mandaria)
        values (new.tx, c.id, 'projetor', 'desatribuir', null, s, 'falta', 'situação ' || s || ' é sem dono, o Chatwoot fica com '
                || concat_ws(' e ', case when ag is not null then 'pessoa' end, case when tm is not null then 'time' end),
                jsonb_build_object('assignee_id', null, 'team_id', null));
      end if;
      quero := jsonb_build_object(
        'add', (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements_text(e -> 'add') x where not (etq ? x)),
        'remove', (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements_text(e -> 'remove') x where etq ? x));
      if jsonb_array_length(quero -> 'add') > 0 or jsonb_array_length(quero -> 'remove') > 0 then
        insert into public.projetor_sombra (tx, conversa_id, momento, tipo, payload, situacao, veredito, motivo, mandaria)
        values (new.tx, c.id, 'projetor', 'etiquetas', null, s, 'falta', 'situação ' || s || ' pede outras etiquetas', quero);
      end if;
    end if;
  exception when others then
    update public.projetor_sombra set veredito = 'erro', motivo = left(sqlerrm, 300)
     where tx = new.tx and conversa_id is not distinct from new.conversa_id and veredito = 'pendente';
  end;
  return null;
exception when others then
  return null;   -- nunca derruba a transação de verdade
end $function$;

commit;
