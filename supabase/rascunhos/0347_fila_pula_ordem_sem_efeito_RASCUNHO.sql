-- NIOGEN | supabase/migrations/0347_fila_pula_ordem_sem_efeito.sql | 21/11/2026 — Claude Code (Opus 5.5)
-- Fase 2, passo 4, parte B1 (Ricardo, 21/11: "Enquanto isso, prepara a parte B1 do projetor"): a ordem que não muda nada no
-- PARADO 21/11 ~15h40: o portão completo deu C4, F1, F2 e X61 vermelhos com esta migration (verdes sem ela). Causa: _conversas_volta_mari,
-- _porta_handoff_devolver, indicacao_tick e mari_entrada__nucleo limpam o espelho (chatwoot_time/agente) ANTES de a ordem sair, então
-- "o espelho já está sem dono" não quer dizer que o Chatwoot está. Não aplicar sem resolver isso.
-- DEIXADA DE LADO 21/11 (Ricardo: "Ok"): a sobra real é só ~50 "tirar dono" na Saída em 3 dias, inofensivas. O conserto certo é
-- o projetor decidir pela situação, não pelo espelho (B2/B3). Fica aqui só como registro.
-- Chatwoot não sai. Na sombra do projetor (0307), 3 dias: ~95 de ~1.134 ordens eram "a_mais" — quase todas "tirar dono" de quem já
-- estava sem dono (Saída, destino, volta à Mari, devolver à Mari, fora do horário) e "etiquetas" que já estavam assim.
-- Onde: na hora de SAIR da fila (backoffice_acoes_proximas), não na hora de entrar — é quando o espelho está mais novo. A ordem pulada
-- fica na fila como 'cancelada' com o motivo em erro (o mesmo jeito do "não contatar" de hoje); 'cancelada' não segura o grupo.
-- Só pula com certeza (_fila_sem_efeito): (a) só etiquetas (add/remove) e desatribuir — resolver, atribuir, nota e mensagem saem sempre;
-- (b) nenhuma ordem anterior da conversa do mesmo assunto ainda pendente ou saindo nesta rodada (o espelho ainda não conta com ela);
-- (c) o espelho foi atualizado pelo Chatwoot DEPOIS da última ordem do mesmo assunto feita na conversa (o aviso do Chatwoot chega
--     segundos depois); (d) desatribuir: espelho E marcas do NIOGEN já sem dono (a ordem feita também limpa humano_atribuido /
--     time_atribuido — _cw_espelho_dono); (e) chave config_regras.fila_pula_sem_efeito = false desliga tudo, sem migration.
-- Regra 20: (1) não cria situação; (2) sem estado novo; (3) quem grava continua sendo a fila; (4) fonte única: o espelho do Chatwoot;
-- (5) conferência: as puladas ficam em chatwoot_acoes (status cancelada, erro "sem efeito: …") e a sombra continua julgando. Cenário X73.
-- Tela, guia do backoffice, n8n: sem impacto (a ordem pulada nunca chega ao n8n). Desempenho: 2 leituras curtas por ordem de etiqueta
-- ou desatribuir, só nessas.
begin;

do $$
begin
  if md5(pg_get_functiondef('public.backoffice_acoes_proximas(integer)'::regprocedure)) <> 'defd0b00860892d10216c4d5b3be60eb' then
    raise exception '0347: backoffice_acoes_proximas mudou no ar — refazer a partir da versão de agora';
  end if;
end $$;

create or replace function public._fila_sem_efeito(a public.chatwoot_acoes, c public.mari_conversas)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  etq text[]; fam text[];
begin
  if c.id is null or a.tipo not in ('etiquetas', 'desatribuir') or c.chatwoot_sync_em is null then return null; end if;
  if not coalesce((public._bo_cfg('fila_pula_sem_efeito', 'true'::jsonb) #>> '{}')::boolean, true) then return null; end if;
  fam := case when a.tipo = 'etiquetas' then array['etiquetas'] else array['atribuir', 'desatribuir'] end;
  if exists (select 1 from public.chatwoot_acoes y where y.conversa_id = a.conversa_id and y.id <> a.id and y.tipo = any (fam)
               and (y.status in ('pendente', 'executando') and y.id < a.id
                    or y.status = 'feita' and y.feita_em >= c.chatwoot_sync_em)) then
    return null;
  end if;
  if a.tipo = 'etiquetas' then
    if a.payload ? 'labels' or c.chatwoot_etiquetas is null then return null; end if;
    etq := c.chatwoot_etiquetas;
    if exists (select 1 from jsonb_array_elements_text(coalesce(a.payload -> 'add', '[]'::jsonb)) x where not (x = any (etq)))
       or exists (select 1 from jsonb_array_elements_text(coalesce(a.payload -> 'remove', '[]'::jsonb)) x where x = any (etq)) then
      return null;
    end if;
    return 'sem efeito: as etiquetas já estavam assim no Chatwoot';
  end if;
  if not (a.payload ? 'assignee_id' or a.payload ? 'team_id') then return null; end if;
  if a.payload ? 'assignee_id' and (a.payload ->> 'assignee_id' is not null or c.chatwoot_agente is not null
                                    or coalesce(c.humano_atribuido, false)) then return null; end if;
  if a.payload ? 'team_id' and (a.payload ->> 'team_id' is not null or c.chatwoot_time is not null
                                or coalesce(c.time_atribuido, false)) then return null; end if;
  return 'sem efeito: a conversa já estava sem ' || concat_ws(' e ', case when a.payload ? 'assignee_id' then 'pessoa' end,
                                                                     case when a.payload ? 'team_id' then 'time' end);
exception when others then
  return null;   -- na dúvida, a ordem sai
end $$;
revoke all on function public._fila_sem_efeito(public.chatwoot_acoes, public.mari_conversas) from public, anon, authenticated;

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
  mot    text;
begin
  if not coalesce((public._bo_cfg('backoffice_chatwoot_ligado', 'true') #>> '{}')::boolean, true) then return; end if;
  -- 0200: resolvida com o time e janela de 24 h fechada → volta para a Mari (varredura barata, a cada rodada de 1 min).
  begin perform public._conversas_volta_mari(); exception when others then
    insert into public.mari_erros (no_n8n, mensagem) values ('_conversas_volta_mari', sqlerrm); end;
  -- 0325 (caso Kell): viabilidade sem cobertura depois dos planos — avisa o cliente que ficou sem aviso.
  begin perform public._cobertura_avisa_veredito(); exception when others then
    insert into public.mari_erros (no_n8n, mensagem) values ('_cobertura_avisa_veredito', sqlerrm); end;
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
    if a.tipo in ('mensagem', 'midia') and coalesce(c.nao_contatar, false) then   -- 0333: a mídia também
      update public.chatwoot_acoes set status = 'cancelada', erro = 'cliente pediu para não ser contatado', feita_em = now() where id = a.id;
      continue;
    end if;
    -- 0347 (fase 2, passo 4 B1): ordem que não muda nada (etiqueta que já está, dono que já não há) não vai ao Chatwoot.
    mot := public._fila_sem_efeito(a, c);
    if mot is not null then
      update public.chatwoot_acoes set status = 'cancelada', erro = mot, feita_em = now() where id = a.id;
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
                 -- 0333: foto, documento ou áudio do time — o n8n baixa do bucket (caminho) e manda como anexo (multipart)
                 when 'midia' then jsonb_build_object('content', coalesce(a.payload ->> 'content', ''), 'caminho', a.payload ->> 'caminho',
                                                      'mime', a.payload ->> 'mime', 'nome', a.payload ->> 'nome')
                 when 'etiquetas' then '{}'::jsonb
                 else a.payload end,
      'add', coalesce(a.payload -> 'add', '[]'::jsonb), 'remove', coalesce(a.payload -> 'remove', '[]'::jsonb));
  end loop;
  return;
end;
$function$;

commit;
