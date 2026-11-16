-- NIOGEN | supabase/migrations/0237_time_fala_reabre_chatwoot.sql | 16/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (16/11, conversa 128 — "Porque essa conversa foi marcada como Resolvida? Mari estava atendendo" → "Sim, corrige").
-- Achado: a conversa saiu por sem cobertura (14:50, portal sem viabilidade) e foi resolvida no Chatwoot. Às 16:04 o Ricardo
-- respondeu pelo NIOGEN: backoffice_responder assumiu (atribuir) e mandou a mensagem, mas NADA reabria a conversa — o Chatwoot
-- só reabre sozinho quando o CLIENTE escreve. Resultado: o time atendendo e a conversa "Resolvida" no Chatwoot.
-- O quê: gatilho no FIM da transação (constraint trigger deferido) em chatwoot_acoes. Quando o time assume (atribuir, momento
-- 'assumir') ou manda mensagem ao cliente (mensagem como 'humano', não privada) numa conversa que está 'resolved' no Chatwoot,
-- põe na fila um 'resolver' → 'open' (momento 'reabrir_time'). Vale para backoffice_responder, backoffice_momento('assumir') e
-- qualquer caminho futuro que fale pelo time — sem reescrever essas funções.
-- Não reabre se, na mesma transação ou na fila, já há um 'resolver' pendente/executando para a conversa (Saída, Aguardar,
-- Silenciar decidem o status) nem se a conversa está adiada (snoozed: silenciada/aguardando seguem como estão).
-- O destino do funil NÃO muda: lead em Saída continua em Saída (reabrir o lead é o botão Reabrir, com as travas da 0227).
-- Regra 20: (1) nenhum estado novo; (2) a conversa com dono humano sai do "resolvida em silêncio"; (3) muda por gatilho do banco,
-- com momento e autor (criada_por) na fila e turno de sistema; (4) fonte: chatwoot_acoes/mari_conversas; (5) sem número novo —
-- a conferência 0228 já olha conversa com dono.
-- Nada no mari_principal (o portão não se aplica).
begin;

create or replace function public._time_fala_reabre() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  c public.mari_conversas;
begin
  if not ((new.tipo = 'atribuir' and new.momento = 'assumir')
          or (new.tipo = 'mensagem' and coalesce(new.payload ->> 'como', '') = 'humano'
              and coalesce(new.payload ->> 'private', 'false') <> 'true')) then
    return null;
  end if;
  if new.status not in ('pendente', 'executando', 'feita') then return null; end if;
  select * into c from public.mari_conversas where id = new.conversa_id;
  if c.id is null or c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = ''
     or coalesce(c.telefone, '') like '5500000000%' then
    return null;
  end if;
  if coalesce(c.chatwoot_status, 'open') <> 'resolved' then return null; end if;
  -- alguém já decide o status (Saída, Aguardar, Silenciar, outro reabrir): não atropela
  if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'resolver'
               and a.status in ('pendente', 'executando')) then
    return null;
  end if;
  perform public._bo_enfileirar(gen_random_uuid(), 1, 'reabrir_time', c.venda_id, c, 'resolver', jsonb_build_object('status', 'open'));
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[conversa reaberta no Chatwoot — o time ' ||
          case when new.tipo = 'atribuir' then 'assumiu' else 'falou com o cliente' end ||
          coalesce(' (' || (select u.nome from public.usuarios u where u.id = new.criada_por) || ')', '') || ']', false);
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_time_fala_reabre', coalesce(new.conversa_id::text, '?') || ': ' || sqlerrm);
  return null;
end;
$$;
revoke all on function public._time_fala_reabre() from public, anon, authenticated;

drop trigger if exists chatwoot_acoes_time_fala_reabre on public.chatwoot_acoes;
create constraint trigger chatwoot_acoes_time_fala_reabre after insert on public.chatwoot_acoes
  deferrable initially deferred
  for each row when (new.tipo in ('atribuir', 'mensagem'))
  execute function public._time_fala_reabre();

commit;
