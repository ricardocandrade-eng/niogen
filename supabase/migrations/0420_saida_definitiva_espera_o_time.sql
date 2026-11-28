-- NIOGEN | supabase/migrations/0420_saida_definitiva_espera_o_time.sql | 26/11/2026 — Claude Code (Fable 5.2)
-- Casos L-132 (Lígia, Chatwoot #117) e L-220 (Cidinha, #200), 26/11 — Ricardo: "Recebi alerta que a Mari não respondeu a mais de
-- 3 min, mas acho que é alarme falso" → "Sim, corrige". As duas estavam em Saída definitiva (crédito negado), onde a Mari cala por
-- regra (0383) e o cliente ouve "já chamei o nosso time… alguém da equipe te responde por aqui".
--   L-132: escreveu 13h45, ouviu a fala fixa e 5 min depois a varredura de 10 min (_saidas_fechar) resolveu a conversa, porque a
--          fala fixa contava como "a última fala é nossa". Sem alarme (a fala fixa também contava como resposta). Só foi atendida
--          às 16h18, quando escreveu de novo. A 0383 queria a conversa aberta até as 24 h do prazo fora_fechar (X106 dizia "não
--          refecha", mas o cenário não passava pela varredura).
--   L-220: respondeu "Nao" ao pedido de indicação da Saída → fala fixa; depois "Sim" → alarme "Mari sem responder". Nada a fazer.
-- O que muda:
--  (1) _saida_so_negacao: "não", "não, obrigada", "não conheço ninguém"… Em Saída, vale como "ok/obrigado": silêncio, sem fala fixa,
--      a varredura fecha. Só nas Saídas (na venda viva um "não" pode ser resposta ao time). Não entra na _saida_so_confirmacao,
--      que a espera com data (0348) também usa.
--  (2) _saidas_fechar: não fecha enquanto o cliente espera o time — houve "já chamei o time" e nenhuma fala de pessoa depois.
--      Quem fecha é o time (ao responder ou resolver) ou o prazo fora_fechar (24 h sem ninguém falar, 0335).
--  (3) v_mari_sem_resposta: a fala fixa não conta como resposta; coluna nova vez_do_time (a Mari cala por regra e o cliente espera
--      uma pessoa). Em Saída, fala que é só confirmação ou negação não entra. O resto do alarme não muda.
--  (4) mari_alarme_proximos: no aviso do WhatsApp o nome vem com "é com o TIME (Saída: a Mari cala por regra)" — o template aprovado
--      pela Meta continua o mesmo ("Mari sem responder há…"); mari_ao_vivo só diz "parada" quando a Mari devia ter respondido;
--      o push do celular diz "🙋 Cliente esperando o time" em vez de "🔴 Mari parada".
-- Regra 20: (1) nenhuma situação nova — segue Saída definitiva; a espera aparece na Live pela v_fila_backoffice (sem_resposta), como
-- já aparecia nos 5 min; (2) ninguém parado em silêncio: alarme aos 3 min, lembrete aos 15, push, e fecha em 24 h; (3) nada grava
-- estado fora da porta (a mudança na entrada é no __nucleo; o fechamento segue pelo _porta_projetar); (4) fonte: a conversa;
-- (5) sem número novo — a conferência da conversa aberta fora do andamento (0335) é a de sempre. Cenário X144.
-- Desempenho: a view ganha 2 subconsultas por conversa com fala do cliente nas últimas 24 h (índices por conversa).
-- Medir em 7 dias: voltas com "já chamei o time" × minutos até a 1ª resposta de pessoa; alarmes "é com o TIME" × alarmes da Mari.
begin;

-- ── 1. "não" solto
create or replace function public._saida_so_negacao(p_texto text) returns boolean language sql immutable as $f$
  select length(public._ind_norm(p_texto)) <= 40
     and public._ind_norm(p_texto) ~ ('^(nao|n|nn|nops|nada|ninguem|nao conheco|nao conheco ninguem|nao tenho|nao tenho ninguem|'
        || 'no momento nao|agora nao|por enquanto nao|nao por enquanto|nao no momento|nao precisa)'
        || '( (obrigad[oa]|obg|obgd[oa]?|brigad[oa]|muito obrigad[oa]|valeu|vlw))?$')
$f$;
grant execute on function public._saida_so_negacao(text) to authenticated, service_role;

-- ── 2. a entrada (no __nucleo): em Saída, "não" solto fica em silêncio, sem "já chamei o time"
do $do$
declare
  d    text := pg_get_functiondef('public.mari_entrada__nucleo'::regproc);
  de   text := $a$public._saida_so_confirmacao(p_texto) or public._norm_resposta(p_texto) in ('confirmo', 'tudo certo')$a$;
  para text := $a$public._saida_so_confirmacao(p_texto) or public._norm_resposta(p_texto) in ('confirmo', 'tudo certo') or (v_s like 'saida%' and public._saida_so_negacao(p_texto))$a$;
begin
  if position('_saida_so_negacao' in d) > 0 then return; end if;   -- já aplicada
  if (length(d) - length(replace(d, de, ''))) / length(de) <> 1 then
    raise exception '0420: a linha da volta ao time (0383) não está uma vez só na mari_entrada__nucleo';
  end if;
  execute replace(d, de, para);
end $do$;

-- ── 3. a varredura de 10 min: quem espera o time não é fechado
CREATE OR REPLACE FUNCTION public._saidas_fechar(p_agora timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c     public.mari_conversas;
  ult   record;
  nosso timestamptz;
  n     int := 0;
begin
  for c in
    select m.* from public.mari_conversas m
      join public.v_lead_situacao ls on ls.conversa_id = m.id
     where m.canal = 'whatsapp' and m.chatwoot_conversation_id is not null
       and coalesce(m.chatwoot_status, 'open') = 'open'
       and ls.situacao in ('saida_pode_voltar', 'saida_definitiva', 'nao_contatar', 'cliente_nio')
       and coalesce(m.funil_destino, 'em_andamento') <> 'teste_duplicada'   -- duplicada: várias linhas da mesma conversa
       and coalesce(m.quadro_encerrada_motivo, '') <> 'suporte_nio'
       and m.chatwoot_agente is null and not coalesce(m.humano_atribuido, false) and not coalesce(m.time_atribuido, false)
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
       -- 0420 (L-132): o cliente ouviu "já chamei o time" e nenhuma pessoa falou depois → fica aberta para o time
       -- (fecha quando alguém responder ou resolver, ou pelo prazo fora_fechar de 24 h sem ninguém falar)
       and (coalesce(m.nao_contatar, false) or not exists (
              select 1 from public.chatwoot_acoes a
               where a.conversa_id = m.id and a.tipo = 'mensagem' and a.momento = 'cliente_voltou'
                 and a.payload ->> 'texto_chave' = 'volta_ao_time' and a.status = 'feita'
                 and a.criada_em > coalesce((select max(t.created_at) from public.mari_turnos t
                                              where t.conversa_id = m.id and t.papel = 'humano'), '-infinity'::timestamptz)))
     limit 30
     for update of m skip locked
  loop
    select t.papel, t.created_at into ult from public.mari_turnos t
     where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1;
    if ult.papel is null or ult.created_at > p_agora - interval '5 minutes' then continue; end if;
    -- 0250 (A6): Não contatar não reabre (situação 14: vez de ninguém) — fecha seja o que for que o cliente escreveu
    if ult.papel = 'lead' and not coalesce(c.nao_contatar, false) then
      select max(t.created_at) into nosso from public.mari_turnos t where t.conversa_id = c.id and t.papel in ('mari', 'humano');
      if nosso is null then continue; end if;
      -- 0420 (L-220): "não" solto também não é assunto
      if exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > nosso
                    and (t.midia is not null or not (public._saida_so_confirmacao(t.texto) or public._saida_so_negacao(t.texto)))) then continue; end if;
    end if;
    if array_length(public._porta_projetar(c.id, 'saida_fechar', null, null, true), 1) is null then continue; end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[Saída aberta sem ninguém com o que fazer (' || case when coalesce(c.nao_contatar, false) then 'Não contatar não reabre (0250)'
            when ult.papel = 'lead' then 'o cliente só confirmou ou se despediu'
            else 'a última fala é nossa' end || ') — resolvida no Chatwoot (0249); se ele escrever, reabre]', false);
    n := n + 1;
  end loop;
  return n;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_saidas_fechar', sqlerrm);
  return n;
end $function$;

-- ── 4. o alarme: a fala fixa não é resposta; vez_do_time diz quem deve
create or replace view public.v_mari_sem_resposta with (security_invoker = true) as
with cfg as (
  select coalesce((select (valor #>> '{}')::boolean from public.config_regras where chave = 'alarme_silencio_ligado'), true) as ligado,
         coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'alarme_silencio_limite_min'), 3) as limite_min,
         (select array_remove(regexp_split_to_array(regexp_replace(coalesce(texto, ''), '[^0-9,]', '', 'g'), ','), '')
            from public.config_mari_textos where chave = 'telefones_teste') as tels_teste
),
base0 as (
  select c.id, c.telefone, c.nome_contato, c.chatwoot_conversation_id, c.status, c.humano_atribuido, c.chatwoot_agente, c.nao_contatar,
         c.chatwoot_status, c.ultima_msg_lead_at, c.ultima_msg_mari_at,
         coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada') as em_saida,
         greatest((select max(t.created_at) from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano'),
                  (select max(a.criada_em) from public.chatwoot_acoes a
                    where a.conversa_id = c.id and a.tipo = 'mensagem' and a.payload ->> 'como' = 'humano'
                      and a.status = any (array['pendente', 'executando', 'feita']))) as ult_humano,
         (select t.texto from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' order by t.created_at desc limit 1) as ult_fala,
         -- 0420: a última vez que o cliente ouviu "já chamei o time" (a Mari cala por regra, 0383)
         (select max(a.criada_em) from public.chatwoot_acoes a
           where a.conversa_id = c.id and a.tipo = 'mensagem' and a.momento = 'cliente_voltou'
             and a.payload ->> 'texto_chave' = 'volta_ao_time' and a.status = any (array['pendente', 'executando', 'feita'])
             and a.criada_em > now() - interval '24 hours') as volta_em,
         public._mari_pos_handoff(c) as pos_handoff
    from public.mari_conversas c
   where coalesce(c.quadro_encerrada_motivo, '') <> 'suporte_nio'
     and c.ultima_msg_lead_at is not null
     and c.ultima_msg_lead_at > now() - interval '24 hours'
     and coalesce(c.canal, '') <> 'teste'
     and c.telefone not like '5500000000%'
),
base as (
  select b0.*, (b0.volta_em is not null and b0.volta_em > coalesce(b0.ult_humano, '-infinity'::timestamptz)) as vez_do_time
    from base0 b0
)
select b.id,
       b.chatwoot_conversation_id,
       split_part(btrim(coalesce(nullif(b.nome_contato, ''), 'Contato')), ' ', 1) as nome,
       public.mari_mascarar_fala(b.ult_fala) as ultima_fala,
       b.ultima_msg_lead_at as desde,
       floor(extract(epoch from (now() - b.ultima_msg_lead_at)) / 60)::int as minutos,
       b.pos_handoff,
       'dharma'::text as parceiro_id,
       b.vez_do_time
  from base b, cfg
 where cfg.ligado
   -- a fala fixa "já chamei o time" não é resposta: enquanto nenhuma pessoa falar, o cliente continua esperando
   and (b.ultima_msg_lead_at > coalesce(b.ultima_msg_mari_at, '-infinity'::timestamptz) or b.vez_do_time)
   and b.ultima_msg_lead_at > coalesce(b.ult_humano, '-infinity'::timestamptz)
   and b.ultima_msg_lead_at <= now() - make_interval(secs => cfg.limite_min * 60)
   and (
        (b.status = 'ativo' and not coalesce(b.humano_atribuido, false) and b.chatwoot_agente is null
         and not coalesce(b.nao_contatar, false) and coalesce(b.chatwoot_status, 'open') <> 'resolved')
        or b.pos_handoff
   )
   -- 0420 (L-220): em Saída, "ok", "sim", "não" soltos não esperam resposta de ninguém
   and not (b.em_saida and not b.vez_do_time and not exists (
              select 1 from public.mari_turnos t
               where t.conversa_id = b.id and t.papel = 'lead'
                 and t.created_at > coalesce((select max(t2.created_at) from public.mari_turnos t2
                                               where t2.conversa_id = b.id and t2.papel in ('mari', 'humano')), '-infinity'::timestamptz)
                 and (t.midia is not null or not (public._saida_so_confirmacao(t.texto) or public._saida_so_negacao(t.texto)))))
   and not (
        b.telefone = any (coalesce(cfg.tels_teste, '{}'))
        and exists (select 1 from public.mari_turnos t join public.mari_conversas c2 on c2.id = t.conversa_id
                     where c2.telefone = b.telefone and t.papel = 'sistema' and t.texto like '[memória da Mari zerada pelo comando #zerar%'
                       and t.created_at > now() - interval '2 minutes')
   );

-- ── 5. o aviso no WhatsApp do Ricardo diz de quem é a vez (o template da Meta é o mesmo)
CREATE OR REPLACE FUNCTION public.mari_alarme_proximos()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lembrete numeric := coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'alarme_silencio_lembrete_min'), 15);
  v_destino text := (select valor #>> '{}' from public.config_regras where chave = 'resumo_destino_whatsapp');
  v_saida jsonb := '[]'::jsonb;
  r record;
begin
  -- 1. episódio resolvido: a conversa saiu da lista (a Mari ou alguém do time respondeu, foi assumida, encerrada…)
  update public.mari_alarmes a set resolvido_em = now()
   where a.resolvido_em is null and not exists (select 1 from public.v_mari_sem_resposta s where s.id = a.conversa_id);
  -- 2. episódios novos
  insert into public.mari_alarmes (conversa_id, episodio_inicio)
  select s.id, s.desde from public.v_mari_sem_resposta s
   where not exists (select 1 from public.mari_alarmes a where a.conversa_id = s.id and a.resolvido_em is null);
  -- 3. o que mandar agora: 1º aviso e o lembrete (uma vez, quando o episódio chega a v_lembrete min)
  for r in
    select a.id, s.chatwoot_conversation_id, s.nome, s.ultima_fala, s.vez_do_time,
           floor(extract(epoch from (now() - a.episodio_inicio)) / 60)::int as minutos,
           case when a.avisado_em is null then 'aviso' else 'lembrete' end as tipo
      from public.mari_alarmes a join public.v_mari_sem_resposta s on s.id = a.conversa_id
     where a.resolvido_em is null
       and (a.avisado_em is null
            or (a.lembrado_em is null and a.episodio_inicio <= now() - make_interval(secs => v_lembrete * 60)))
     order by a.episodio_inicio
     limit 20
  loop
    if r.tipo = 'aviso' then update public.mari_alarmes set avisado_em = now() where id = r.id;
    else update public.mari_alarmes set lembrado_em = now() where id = r.id; end if;
    v_saida := v_saida || jsonb_build_object(
      'id', r.id, 'tipo', r.tipo, 'destino', v_destino, 'template', 'alerta_mari_silencio', 'idioma', 'pt_BR',
      'params', jsonb_build_array(r.minutos::text, coalesce(r.chatwoot_conversation_id, '—'),
                                  coalesce(nullif(r.nome, ''), 'Contato')
                                    -- 0420: a Mari cala por regra (0383) e o cliente ouviu "já chamei o time"
                                    || case when r.vez_do_time then ' — é com o TIME (Saída: a Mari cala por regra)' else '' end,
                                  coalesce(nullif(r.ultima_fala, ''), '(mídia ou botão)')));
  end loop;
  if v_destino is null or v_destino = '' then
    return '[]'::jsonb;   -- sem destino configurado não manda nada (os episódios ficam registrados)
  end if;
  return v_saida;
end $function$;

-- ── 6. "Mari parada" só quando a Mari devia ter respondido; o push diz que é com o time
do $do$
declare
  d  text := pg_get_functiondef('public.mari_ao_vivo'::regproc);
  de text := 'select count(*) into v_sem from public.v_mari_sem_resposta;';
begin
  if position('v_mari_sem_resposta where not vez_do_time' in d) = 0 then
    if (length(d) - length(replace(d, de, ''))) / length(de) <> 1 then raise exception '0420: mari_ao_vivo mudou — a contagem do alarme não está uma vez só'; end if;
    execute replace(d, de, 'select count(*) into v_sem from public.v_mari_sem_resposta where not vez_do_time;');
  end if;
  d  := pg_get_functiondef('public.push_pendentes'::regproc);
  de := $a$'🔴 Mari parada',$a$;
  if position('Cliente esperando o time' in d) = 0 then
    if (length(d) - length(replace(d, de, ''))) / length(de) <> 1 then raise exception '0420: push_pendentes mudou — o título "Mari parada" não está uma vez só'; end if;
    execute replace(d, de, $a$case when s.vez_do_time then '🙋 Cliente esperando o time' else '🔴 Mari parada' end,$a$);
  end if;
end $do$;

-- ── 7. conferência do que subiu
do $do$
begin
  if position('_saida_so_negacao' in pg_get_functiondef('public.mari_entrada__nucleo'::regproc)) = 0
     or position('volta_ao_time' in pg_get_functiondef('public._saidas_fechar'::regproc)) = 0
     or position('vez_do_time' in pg_get_functiondef('public.mari_alarme_proximos'::regproc)) = 0
     or position('where not vez_do_time' in pg_get_functiondef('public.mari_ao_vivo'::regproc)) = 0
     or position('Cliente esperando o time' in pg_get_functiondef('public.push_pendentes'::regproc)) = 0 then
    raise exception '0420: algum remendo não entrou';
  end if;
  if not (public._saida_so_negacao('Nao') and public._saida_so_negacao('Não, obrigada!') and public._saida_so_negacao('Não conheço ninguém')
          and not public._saida_so_negacao('Não recebi o chip') and not public._saida_so_negacao('Sim')) then
    raise exception '0420: _saida_so_negacao não reconhece o que devia';
  end if;
end $do$;

commit;
