-- NIOGEN | supabase/migrations/0229_fila_nao_reenvia.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (15/11 ~21h50, "Sim, faça o M8"): duplicata por reenvio da fila do Chatwoot (revisão dos fluxos, M8).
-- Causa (n8n backoffice_chatwoot): o nó "7 · Supabase resultado" seguia em silêncio quando o Supabase respondia 503 → a ação ficava
-- 'executando', em 10 min voltava para 'pendente' e a mensagem saía de novo. Em 14 dias: 5 mensagens repetidas, 2 chegaram 2× ao
-- cliente (Joao 11/11 14:26/14:36, Michele 13/11 15:11/15:21); nas outras 3 a 1ª tentativa não tinha saído (repetir estava certo).
-- Correção: (1) n8n — o nó 7 repete 4× (n8n/deploy_backoffice_chatwoot.py); (2) backoffice_acao_resultado ignora o 2º "feita";
-- (3) backoffice_acoes_proximas: antes de devolver à fila uma mensagem presa, procura o eco dela na conversa — chegou, fecha
-- como feita (o eco da resposta do time vem do Chatwoot; o da voz da Mari só nasce no "feita", então ali vale o item 1).
-- Recriadas a partir da versão no ar (conferidas iguais aos arquivos). Regra 20: nenhum estado novo.
begin;

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
  -- 0200: resolvida com o time e janela de 24 h fechada → volta para a Mari (varredura barata, a cada rodada de 1 min).
  begin perform public._conversas_volta_mari(); exception when others then
    insert into public.mari_erros (no_n8n, mensagem) values ('_conversas_volta_mari', sqlerrm); end;
  -- 0229 (revisão dos fluxos, M8): mensagem presa em 'executando' cujo ECO já chegou na conversa saiu de verdade (o n8n só não
  -- conseguiu avisar o banco): fecha como feita, sem reenviar. Casos Joao 11/11 e Michele 13/11 — a mesma resposta 2×, 10 min depois.
  update public.chatwoot_acoes q set status = 'feita', feita_em = coalesce(q.feita_em, now()),
         erro = 'confirmada pelo eco da conversa (o n8n não avisou o banco)'
   where q.status = 'executando' and q.pega_em < now() - interval '10 minutes' and q.tipo = 'mensagem'
     and nullif(btrim(q.payload ->> 'content'), '') is not null
     and exists (select 1 from public.mari_turnos t where t.conversa_id = q.conversa_id and t.papel in ('humano', 'mari')
                  and t.texto = q.payload ->> 'content' and t.created_at >= q.pega_em - interval '1 minute');
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
  -- 0229 (M8): o n8n agora repete este aviso quando o Supabase falha; o 2º "feita" não grava contato nem turno de novo.
  if a.status = 'feita' then return jsonb_build_object('ok', true, 'registrado', 'já estava feita'); end if;
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

commit;
