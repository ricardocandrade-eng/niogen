-- NIOGEN | supabase/migrations/0334_mensagens_chatwoot_tiques_e_citar.sql | 20/11/2026 — Claude Code / Opus 5.5
-- Prompt docs/Prompt_conversa_sem_chatwoot_171126_1620.md, item 4 ("Responder citando o balão do cliente") + Ricardo, 20/11 ~3h:
-- "deixe o chat o mais parecido possível com o WhatsApp" · "E os dois vv de mensagem entregue?". "Pode subir sem portão".
-- O que muda:
--   1. mari_msg_cw: cada mensagem da conversa no Chatwoot (id do Chatwoot, wamid do WhatsApp, direção, status enviada / entregue /
--      lida / falhou, começo do texto). Alimentada pelo mesmo evento que já sincroniza a conversa (nó 2t do mari_principal): o
--      2 · Entrada passa a mandar a mensagem junto (p_msg) — message_created e message_updated (este traz entregue/lida).
--      Só o que o Chatwoot manda; nada de conteúdo além dos 300 primeiros caracteres (para casar com o balão da tela).
--   2. mari_chatwoot_sync(…, p_msg): versão com a mensagem — chama a de sempre e grava/atualiza mari_msg_cw (o status só avança:
--      enviada → entregue → lida; falhou fica). A de 5 argumentos continua igual (quem chama sem a mensagem não muda).
--   3. backoffice_responder_citando(conversa, texto, cw_msg_id): a resposta do time citando um balão — é o backoffice_responder de
--      sempre (mesma porta, mesmas regras) com a marca bo.cita; o gatilho chatwoot_acoes_citar põe content_attributes.in_reply_to na
--      mensagem, e o Chatwoot manda ao WhatsApp como resposta citada.
-- Regra 15: parceiro_id na tabela nova. Regra 20: sem estado de lead; fonte = o Chatwoot; a tela só lê; sem conferência nova (o
-- status da mensagem não é número de negócio). Desempenho: 1 leitura a mais na rodada paralela da conversa.
-- Se o webhook do Chatwoot não tiver "message_updated" ligado, os tiques ficam em ✓ (enviada): ligar em Configurações › Integrações
-- › Webhooks do Chatwoot (evento "Mensagem atualizada").

begin;

create table if not exists public.mari_msg_cw (
  cw_msg_id                bigint primary key,
  conversa_id              uuid references public.mari_conversas(id) on delete set null,
  chatwoot_conversation_id text not null,
  wamid                    text,
  direcao                  text check (direcao in ('in', 'out')),
  status                   text,
  texto                    text,
  criado_em                timestamptz,
  atualizado_em            timestamptz not null default now(),
  parceiro_id              text not null default 'dharma'
);
create index if not exists mari_msg_cw_conversa on public.mari_msg_cw (conversa_id, criado_em desc);
alter table public.mari_msg_cw enable row level security;
drop policy if exists mari_msg_cw_ler on public.mari_msg_cw;
create policy mari_msg_cw_ler on public.mari_msg_cw for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
grant select on public.mari_msg_cw to authenticated;

create or replace function public.mari_chatwoot_sync(p_chatwoot_conversation_id text, p_status text, p_agente text, p_time text,
                                                     p_etiquetas text[], p_msg jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n   integer := public.mari_chatwoot_sync(p_chatwoot_conversation_id, p_status, p_agente, p_time, p_etiquetas);
  id  bigint := nullif(p_msg ->> 'id', '')::bigint;
  st  text := lower(coalesce(p_msg ->> 'status', ''));
  ord int;
  cid uuid;
begin
  if id is null or coalesce(btrim(p_chatwoot_conversation_id), '') = '' then return n; end if;
  st := case st when 'sent' then 'enviada' when 'delivered' then 'entregue' when 'read' then 'lida' when 'failed' then 'falhou' else null end;
  ord := case st when 'enviada' then 1 when 'entregue' then 2 when 'lida' then 3 when 'falhou' then 4 else 0 end;
  select c.id into cid from public.mari_conversas c
   where c.chatwoot_conversation_id = btrim(p_chatwoot_conversation_id) and c.canal = 'whatsapp' order by c.created_at desc limit 1;
  insert into public.mari_msg_cw (cw_msg_id, conversa_id, chatwoot_conversation_id, wamid, direcao, status, texto, criado_em, atualizado_em)
  values (id, cid, btrim(p_chatwoot_conversation_id), nullif(p_msg ->> 'wamid', ''),
          case p_msg ->> 'dir' when 'in' then 'in' when 'out' then 'out' end, st, left(p_msg ->> 'texto', 300),
          coalesce(case when p_msg ->> 'em' ~ '^\d+(\.\d+)?$' then to_timestamp((p_msg ->> 'em')::double precision)
                        when nullif(p_msg ->> 'em', '') is not null then (p_msg ->> 'em')::timestamptz end, now()), now())
  on conflict (cw_msg_id) do update
     set wamid = coalesce(excluded.wamid, mari_msg_cw.wamid),
         direcao = coalesce(mari_msg_cw.direcao, excluded.direcao),
         texto = coalesce(nullif(excluded.texto, ''), mari_msg_cw.texto),
         conversa_id = coalesce(mari_msg_cw.conversa_id, excluded.conversa_id),
         status = case when excluded.status is null then mari_msg_cw.status
                       when mari_msg_cw.status = 'falhou' then mari_msg_cw.status
                       when (case excluded.status when 'enviada' then 1 when 'entregue' then 2 when 'lida' then 3 when 'falhou' then 4 else 0 end)
                            >= (case mari_msg_cw.status when 'enviada' then 1 when 'entregue' then 2 when 'lida' then 3 when 'falhou' then 4 else 0 end)
                       then excluded.status else mari_msg_cw.status end,
         atualizado_em = now();
  return n;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem, payload) values ('0334 · mari_msg_cw', sqlerrm, p_msg);
  return n;
end $$;
revoke all on function public.mari_chatwoot_sync(text, text, text, text, text[], jsonb) from public, anon, authenticated;
grant execute on function public.mari_chatwoot_sync(text, text, text, text, text[], jsonb) to service_role;

create or replace function public._chatwoot_acoes_citar()
returns trigger language plpgsql set search_path = public as $$
declare v text := coalesce(current_setting('bo.cita', true), '');
begin
  if v ~ '^\d{1,15}$' and new.tipo = 'mensagem' and coalesce(new.payload ->> 'como', '') = 'humano' then
    new.payload := new.payload || jsonb_build_object('content_attributes', jsonb_build_object('in_reply_to', v::bigint));
  end if;
  return new;
end $$;
drop trigger if exists chatwoot_acoes_citar on public.chatwoot_acoes;
create trigger chatwoot_acoes_citar before insert on public.chatwoot_acoes for each row execute function public._chatwoot_acoes_citar();

create or replace function public.backoffice_responder_citando(p_conversa uuid, p_texto text, p_cw_msg_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if not exists (select 1 from public.mari_msg_cw m join public.mari_conversas c on c.id = p_conversa
                  where m.cw_msg_id = p_cw_msg_id and m.chatwoot_conversation_id = c.chatwoot_conversation_id) then
    raise exception 'A mensagem citada não é desta conversa.';
  end if;
  perform set_config('bo.cita', p_cw_msg_id::text, true);
  r := public.backoffice_responder(p_conversa, p_texto, false, null);
  perform set_config('bo.cita', '', true);
  return r || jsonb_build_object('citou', p_cw_msg_id);
end $$;
revoke all on function public.backoffice_responder_citando(uuid, text, bigint) from public, anon;
grant execute on function public.backoffice_responder_citando(uuid, text, bigint) to authenticated;

commit;
