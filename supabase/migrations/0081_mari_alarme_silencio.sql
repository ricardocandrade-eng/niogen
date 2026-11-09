-- NIOGEN | supabase/migrations/0081_mari_alarme_silencio.sql | 09/11/2026 — Claude Code (docs/Prompt_mari_alarme_silencio_091126_0650.md · Onda 1.2, Parte 2)
-- Por quê: o portão evita publicar Mari quebrada; o alarme pega o que escapar. A conversa #5 (07/11) ficou calada até o Ricardo ver por
--          acaso. Canal decidido em 09/11: template de WhatsApp do número da Mari para o celular do Ricardo (o mesmo destino do resumo, 0080).
-- O quê (só aditivo; módulo Mari, desligável por config):
--   1. config_regras: alarme_silencio_ligado true · alarme_silencio_limite_min 3 · alarme_silencio_lembrete_min 15
--      (destino = resumo_destino_whatsapp — nenhum número no repo).
--   2. config_templates_waba: alerta_mari_silencio (UTILITY pedido, pt_BR, sem marca, 4 variáveis sem quebra de linha).
--   3. v_mari_sem_resposta (security_invoker, admin/backoffice): a última fala é do CLIENTE há ≥ limite, sem resposta da Mari nem de
--      humano, e a conversa DEVERIA ser da Mari (ativa, sem humano atribuído, sem agente no Chatwoot, não resolvida, sem "não contatar") ou
--      está na janela pós-handoff (0061). Conversas de teste (canal teste / 5500000000…) fora; os telefones_teste só saem por 2 min
--      depois de um #zerar. Só falas das últimas 24 h. A última fala sai mascarada (dígitos longos, e-mail), até 60 caracteres.
--   4. mari_alarmes: um episódio por conversa (aberto até a Mari ou um humano responder) com avisado_em / lembrado_em / resolvido_em / erro.
--   5. mari_alarme_proximos() (service_role): fecha os episódios resolvidos, abre os novos, devolve o que mandar agora (1º aviso e o
--      lembrete aos 15 min) e marca na mesma transação. mari_alarme_erro(id, erro) grava falha de envio (o laço do n8n não trava).

insert into public.config_regras (chave, valor, descricao) values
  ('alarme_silencio_ligado', 'true', 'Alarme de silêncio da Mari (WhatsApp do Ricardo): false desliga sem mexer no n8n'),
  ('alarme_silencio_limite_min', '3', 'Alarme de silêncio: minutos desde a última fala do cliente sem resposta da Mari nem do time'),
  ('alarme_silencio_lembrete_min', '15', 'Alarme de silêncio: um lembrete quando o mesmo episódio chega a estes minutos (uma vez só)')
on conflict (chave) do nothing;

insert into public.config_templates_waba (nome, categoria, idioma, corpo, uso)
values ('alerta_mari_silencio', 'UTILITY', 'pt_BR',
        '⚠️ Mari sem responder há {{1}} min · Chatwoot #{{2}} · {{3}} · última fala: "{{4}}"',
        'Alarme de silêncio da Mari para o Ricardo (n8n mari_alarme_silencio). Interno: nunca para cliente.')
on conflict do nothing;

-- Texto curto e sem dado pessoal: some com sequências de 6+ dígitos (CPF, telefone, CEP), e-mail e quebras de linha.
create or replace function public.mari_mascarar_fala(p text, p_max int default 60)
returns text language sql immutable set search_path = '' as $$
  select case when length(t) > p_max then left(t, p_max - 1) || '…' else t end
    from (select btrim(regexp_replace(
                   regexp_replace(
                     regexp_replace(coalesce(p, ''), '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}', '[e-mail]', 'g'),
                   '\d[\d .()/-]{4,}\d', '•••', 'g'),
                 '\s+', ' ', 'g')) as t) x
$$;

-- a view é security_invoker (a tela lê como o usuário): o teste da janela pós-handoff (só leitura) precisa abrir para logados.
grant execute on function public._mari_pos_handoff(public.mari_conversas) to authenticated;

create or replace view public.v_mari_sem_resposta with (security_invoker = true) as
with cfg as (
  select coalesce((select (valor #>> '{}')::boolean from public.config_regras where chave = 'alarme_silencio_ligado'), true) as ligado,
         coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'alarme_silencio_limite_min'), 3) as limite_min,
         (select array_remove(regexp_split_to_array(regexp_replace(coalesce(texto, ''), '[^0-9,]', '', 'g'), ','), '')
            from public.config_mari_textos where chave = 'telefones_teste') as tels_teste
),
base as (
  select c.*,
         (select max(t.created_at) from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano') as ult_humano,
         (select t.texto from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' order by t.created_at desc limit 1) as ult_fala,
         public._mari_pos_handoff(c) as pos_handoff
    from public.mari_conversas c
   where c.ultima_msg_lead_at is not null
     and c.ultima_msg_lead_at > now() - interval '24 hours'
     and coalesce(c.canal, '') <> 'teste'
     and c.telefone not like '5500000000%'
)
select b.id,
       b.chatwoot_conversation_id,
       split_part(btrim(coalesce(nullif(b.nome_contato, ''), 'Contato')), ' ', 1) as nome,
       public.mari_mascarar_fala(b.ult_fala) as ultima_fala,
       b.ultima_msg_lead_at as desde,
       floor(extract(epoch from (now() - b.ultima_msg_lead_at)) / 60)::int as minutos,
       b.pos_handoff,
       'dharma'::text as parceiro_id
  from base b, cfg
 where cfg.ligado
   and b.ultima_msg_lead_at > coalesce(b.ultima_msg_mari_at, '-infinity'::timestamptz)
   and b.ultima_msg_lead_at > coalesce(b.ult_humano, '-infinity'::timestamptz)
   and b.ultima_msg_lead_at <= now() - make_interval(secs => cfg.limite_min * 60)
   and (
        (b.status = 'ativo' and not coalesce(b.humano_atribuido, false) and b.chatwoot_agente is null
         and not coalesce(b.nao_contatar, false) and coalesce(b.chatwoot_status, 'open') <> 'resolved')
        or b.pos_handoff
   )
   and not (
        b.telefone = any (coalesce(cfg.tels_teste, '{}'))
        and exists (select 1 from public.mari_turnos t join public.mari_conversas c2 on c2.id = t.conversa_id
                     where c2.telefone = b.telefone and t.papel = 'sistema' and t.texto like '[memória da Mari zerada pelo comando #zerar%'
                       and t.created_at > now() - interval '2 minutes')
   );
grant select on public.v_mari_sem_resposta to authenticated;

create table if not exists public.mari_alarmes (
  id              bigint generated always as identity primary key,
  conversa_id     uuid not null references public.mari_conversas(id) on delete cascade,
  episodio_inicio timestamptz not null,
  avisado_em      timestamptz,
  lembrado_em     timestamptz,
  resolvido_em    timestamptz,
  erro            text,
  erro_em         timestamptz,
  parceiro_id     text not null default 'dharma',
  criado_em       timestamptz not null default now()
);
create unique index if not exists mari_alarmes_um_aberto on public.mari_alarmes (conversa_id) where resolvido_em is null;
alter table public.mari_alarmes enable row level security;
drop policy if exists mari_alarmes_ler on public.mari_alarmes;
create policy mari_alarmes_ler on public.mari_alarmes for select to authenticated using (public.meu_perfil() in ('admin', 'backoffice'));
revoke all on public.mari_alarmes from anon;
grant select on public.mari_alarmes to authenticated;

create or replace function public.mari_alarme_proximos()
returns jsonb language plpgsql security definer set search_path = public as $$
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
    select a.id, s.chatwoot_conversation_id, s.nome, s.ultima_fala,
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
      'params', jsonb_build_array(r.minutos::text, coalesce(r.chatwoot_conversation_id, '—'), coalesce(nullif(r.nome, ''), 'Contato'),
                                  coalesce(nullif(r.ultima_fala, ''), '(mídia ou botão)')));
  end loop;
  if v_destino is null or v_destino = '' then
    return '[]'::jsonb;   -- sem destino configurado não manda nada (os episódios ficam registrados)
  end if;
  return v_saida;
end $$;
revoke all on function public.mari_alarme_proximos() from public, anon, authenticated;
grant execute on function public.mari_alarme_proximos() to service_role;

create or replace function public.mari_alarme_erro(p_id bigint, p_erro text)
returns void language sql security definer set search_path = public as $$
  update public.mari_alarmes set erro = left(p_erro, 500), erro_em = now() where id = p_id and nullif(btrim(p_erro), '') is not null;   -- envio ok = nada a gravar
$$;
revoke all on function public.mari_alarme_erro(bigint, text) from public, anon, authenticated;
grant execute on function public.mari_alarme_erro(bigint, text) to service_role;
