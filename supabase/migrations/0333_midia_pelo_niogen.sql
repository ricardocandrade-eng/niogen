-- NIOGEN | supabase/migrations/0333_midia_pelo_niogen.sql | 20/11/2026 — Claude Code / Opus 5.5
-- Prompt docs/Prompt_conversa_sem_chatwoot_171126_1620.md, item 2 ("Anexar foto e documento pelo NIOGEN") + Ricardo, 20/11 ~2h50:
-- "deixe o chat o mais parecido possível com o WhatsApp… Gravar áudio também". "Pode subir sem portão".
-- O que muda:
--   1. chatwoot_acoes aceita o tipo 'midia' (foto, documento ou áudio do time) — passa pela MESMA fila e as mesmas regras da
--      resposta escrita: Não contatar cancela, sai em nome de quem atende, a ação 'feita' grava o contato e o balão.
--   2. Bucket midia_conversas: + documentos (pdf, Word, Excel, texto); o time sobe arquivo só em bo/<conversa>/… (admin/BKO).
--   3. backoffice_midia(conversa, caminho, tipo, mime, nome, legenda): confere como o backoffice_responder — perfil, Chatwoot,
--      porta 'time_respondeu' (sem dono, o time assume: a Mari cala), Não contatar, janela de 24 h aberta (mídia não vai em template)
--      — e enfileira. Áudio gravado na tela vai como áudio do WhatsApp (ogg/opus ou mp4/aac — o que o navegador gravar).
--   4. backoffice_acoes_proximas devolve a mídia ao n8n (caminho, mime, nome, legenda); backoffice_acao_resultado grava o balão.
-- Regra 20: (1) sem situação nova · (2) a mídia é resposta do time: a mesma porta da resposta escrita (time_respondeu) ·
-- (3) consequência na fila chatwoot_acoes · (4) fonte: o arquivo no bucket · (5) a fila já é conferida (R3/R7 e conferência
-- "Nada automático fala por cima"). Desempenho: sem chamada nova na abertura.

begin;

alter table public.chatwoot_acoes drop constraint if exists chatwoot_acoes_tipo_check;
alter table public.chatwoot_acoes add constraint chatwoot_acoes_tipo_check
  check (tipo = any (array['atribuir', 'etiquetas', 'nota', 'mensagem', 'resolver', 'desatribuir', 'midia']));

update storage.buckets
   set allowed_mime_types = array['audio/ogg', 'audio/opus', 'audio/mpeg', 'audio/mp4', 'audio/m4a', 'audio/x-m4a', 'audio/aac', 'audio/amr',
                                  'audio/wav', 'image/jpeg', 'image/png', 'image/webp',
                                  'application/pdf', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                                  'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'text/plain']
 where id = 'midia_conversas';

drop policy if exists midia_conversas_bo_enviar on storage.objects;
create policy midia_conversas_bo_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'midia_conversas' and (select public.meu_perfil()) in ('admin', 'backoffice') and name like 'bo/%');

create or replace function public.backoffice_midia(p_conversa uuid, p_caminho text, p_tipo text, p_mime text, p_nome text default null,
                                                    p_legenda text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c        public.mari_conversas;
  g        uuid := gen_random_uuid();
  o        int := 0;
  aid      bigint;
  v_porta  jsonb;
  ult_lead timestamptz;
  ult_out  timestamptz;
  resposta boolean;
  leg      text := btrim(coalesce(p_legenda, ''));
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice manda mídia pelo NIOGEN.' using errcode = '42501';
  end if;
  if p_tipo not in ('imagem', 'arquivo', 'audio') then raise exception 'Tipo de mídia inválido.'; end if;
  if coalesce(p_caminho, '') !~ '^bo/[A-Za-z0-9._/-]{3,200}$' then raise exception 'Arquivo inválido.'; end if;
  if not exists (select 1 from storage.objects where bucket_id = 'midia_conversas' and name = p_caminho) then
    raise exception 'O arquivo não chegou ao NIOGEN: tente de novo.';
  end if;
  if length(leg) > 1000 then raise exception 'Legenda longa demais (máx. 1.000 caracteres).'; end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' then raise exception 'Esta conversa não está no Chatwoot.'; end if;
  if c.telefone like '5500000000%' then raise exception 'Telefone de teste: nada vai ao Chatwoot.'; end if;
  -- a mesma porta da resposta escrita: sem dono, o time assume (a Mari cala); Não contatar recusa
  v_porta := public.porta('time_respondeu', c.id, null::uuid, jsonb_build_object('grupo', g, 'ordem', o));
  o := coalesce((v_porta ->> 'acoes')::int, o);
  if coalesce(c.nao_contatar, false) then raise exception 'O cliente pediu para não ser contatado.'; end if;
  select max(t.created_at) filter (where t.papel = 'lead'), max(t.created_at) filter (where t.papel in ('mari', 'humano'))
    into ult_lead, ult_out from public.mari_turnos t where t.conversa_id = c.id;
  if ult_lead is null or now() >= ult_lead + interval '23 hours' then
    raise exception 'A janela de 24 h fechou: mídia não vai em template. Mande um template primeiro e espere o cliente responder.' using errcode = 'P0001';
  end if;
  resposta := ult_lead > coalesce(ult_out, '-infinity'::timestamptz);
  o := o + 1;
  aid := public._bo_enfileirar(g, o, 'responder', c.venda_id, c, 'midia',
    jsonb_build_object('content', leg, 'caminho', p_caminho, 'mime', left(coalesce(p_mime, ''), 120), 'nome', left(coalesce(p_nome, ''), 160),
                       'tipo_midia', p_tipo, 'como', 'humano', 'conta', case when resposta then 'nao' else 'sim' end,
                       'rotulo', case p_tipo when 'imagem' then 'foto do time' when 'audio' then 'áudio do time' else 'documento do time' end));
  return jsonb_build_object('ok', true, 'acao_id', aid, 'resumo',
    case p_tipo when 'imagem' then '✓ foto enviada' when 'audio' then '✓ áudio enviado' else '✓ documento enviado' end);
end $$;
revoke all on function public.backoffice_midia(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.backoffice_midia(uuid, text, text, text, text, text) to authenticated;

-- 4a. backoffice_acoes_proximas (= produção + o tipo midia)
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
$function$
;

-- 4b. backoffice_acao_resultado (= produção + o tipo midia)
CREATE OR REPLACE FUNCTION public.backoffice_acao_resultado(p_id bigint, p_ok boolean, p_erro text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
  -- 0333: a mídia do time saiu → contato + o balão com a mídia na conversa do NIOGEN (o Chatwoot não avisa a Mari de anexo sem
  -- texto; a legenda, se houver, chega pelo Chatwoot como fala do time — aqui o turno vai sem texto, só a mídia).
  if a.tipo = 'midia' then
    select * into c from public.mari_conversas where id = a.conversa_id;
    insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
    values (a.venda_id, a.conversa_id, c.telefone, 'whatsapp', 'saida', 'vendedor', now(), 'BO_MIDIA',
            case when a.payload ->> 'conta' = 'nao' then 'receptivo' else 'ativo' end,
            'NIOGEN · ' || coalesce(a.payload ->> 'tipo_midia', 'mídia') || ' do time');
    insert into public.mari_turnos (conversa_id, papel, texto, tags, midia, created_at)
    values (a.conversa_id, 'humano', '',
            jsonb_build_object('backoffice', 'midia', 'acao_id', a.id, 'por', a.criada_por),
            jsonb_build_array(jsonb_build_object('tipo', coalesce(a.payload ->> 'tipo_midia', 'arquivo'), 'caminho', a.payload ->> 'caminho',
              'mime', a.payload ->> 'mime', 'nome', a.payload ->> 'nome', 'do_time', true)), now());
    return jsonb_build_object('ok', true, 'registrado', 'feita');
  end if;
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
      -- 0299: o sopro é resposta do time na voz da Mari — conta como receptivo e o turno guarda quem soprou
      insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
      values (a.venda_id, a.conversa_id, c.telefone, 'whatsapp', 'saida', 'vendedor', now(), 'BO_' || upper(a.momento),
              case when a.momento = 'sopro' then 'receptivo' else 'ativo' end,
              'NIOGEN · ' || coalesce(a.payload ->> 'rotulo', a.momento) || coalesce(' · template ' || (a.payload ->> 'template'), ''));
      insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
      values (a.conversa_id, 'mari', coalesce(a.payload ->> 'content', ''),
              jsonb_build_object('backoffice', a.momento, 'acao_id', a.id)
              || case when a.momento = 'sopro' then jsonb_build_object('por', a.criada_por) else '{}'::jsonb end, now());
    end if;
  end if;
  return jsonb_build_object('ok', true, 'registrado', 'feita');
end;
$function$
;

commit;
