-- NIOGEN | supabase/migrations/0217_travas_contra_desligamento.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (15/11 ~14h): "o sistema não deveria ter essas travas para impedir que esses 'desligamentos' aconteçam por
-- falha do backoffice?" → "Sim, faça as duas".
-- Achado: conversa em andamento resolvida no Chatwoot (por gente ou por automação) ligava a trava "resolvida" da cadência e só
-- desligava se alguém reabrisse a conversa — a Mari parava para sempre, sem saída e sem dono (Rodrigo, Getulio, De souza, Luíz
-- Fábio, resolvidas em 12/11 15:46). E o 🔥 enviado a quem estava em Saída ("Esquentada por Ricardo … a Mari segue") não tirava
-- o lead da Saída: a conversa seguia resolvida com destino "recusou" e a Mari não seguia (Sergio Naves, Waldir, Tamires, 14/11 16:01).
--
-- Trava 1 · resolvida sem saída reabre sozinha: quando a conversa ATIVA, em andamento (sem destino de saída), sem dono humano, sem
--   "não contatar" e sem encerramento do quadro entra no estado "resolvida no Chatwoot", o gatilho desliga a trava na hora e põe na
--   fila do NIOGEN: reabrir no Chatwoot + nota privada ("resolvida sem destino de saída — o NIOGEN reabriu; a Mari segue. Para
--   encerrar, use Saída ▾"). Encerrar continua sendo só pelo NIOGEN, com destino (regra 20.3).
-- Trava 2 · 🔥 tira o lead da Saída: oportunidade "enviada" numa conversa com destino de saída (fora instalada) chama
--   (fora teste_duplicada) lead_reabrir (a mesma função do botão Reabrir: destino volta para em andamento, autor = quem mandou o 🔥, reabre no Chatwoot).
-- Acerto dos dados: as resolvidas sem saída de hoje reabrem; os 🔥 enviados depois da saída reabrem como se fosse pelo botão,
--   com o autor do 🔥.
-- Regra 20: (1) etapa/status/destino não mudam por fora; (2) é a saída automática do estado "resolvida sem saída";
-- (3) tudo por gatilho/função do banco, com motivo (momento 'sem_saida' / 'reabrir') e autor; (4) fonte: mari_conversas e
-- oportunidades_log; (5) sem estado nem número novo — a Live (0216) mostra o que sobrar.
-- Nada no mari_principal (o portão não se aplica).
begin;

create or replace function public._resolvida_sem_saida(c public.mari_conversas)
returns boolean language sql stable set search_path = public as $$
  select coalesce(c.chatwoot_resolvida, false)
     and c.status = 'ativo'
     and c.canal = 'whatsapp'
     and coalesce(c.chatwoot_conversation_id, '') <> ''
     and coalesce(c.telefone, '') not like '5500000000%'
     and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
     and not coalesce(c.nao_contatar, false)
     and coalesce(c.quadro_encerrada_motivo, '') = ''
     and c.chatwoot_agente is null
     and not coalesce(c.humano_atribuido, false)
     and not coalesce(c.time_atribuido, false)
     and (c.venda_id is null or not exists (select 1 from public.vendas v where v.id = c.venda_id and v.status = 'saida'))
$$;
revoke all on function public._resolvida_sem_saida(public.mari_conversas) from public, anon;

-- reabre (fila do NIOGEN) — usado pelo gatilho e pelo acerto
create or replace function public._reabrir_sem_saida(c public.mari_conversas)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'resolver'
              and a.status in ('pendente', 'executando') and a.payload ->> 'status' = 'open') then
    return;
  end if;
  perform public._bo_enfileirar(gen_random_uuid(), 1, 'sem_saida', c.venda_id, c, 'resolver', jsonb_build_object('status', 'open'),
                                now() + interval '1 minute');
  perform public._bo_enfileirar(gen_random_uuid(), 1, 'sem_saida', c.venda_id, c, 'nota',
    jsonb_build_object('content', '↩ Resolvida sem destino de saída — o NIOGEN reabriu e a Mari segue com o cliente. '
                                  || 'Para encerrar, use Saída ▾ no NIOGEN (escolha o destino).'),
    now() + interval '1 minute');
end;
$$;
revoke all on function public._reabrir_sem_saida(public.mari_conversas) from public, anon, authenticated;

create or replace function public._conversa_resolvida_sem_saida() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public._resolvida_sem_saida(new) and not public._resolvida_sem_saida(old) then
    new.chatwoot_resolvida := false;
    perform public._reabrir_sem_saida(new);
  end if;
  return new;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_conversa_resolvida_sem_saida', sqlerrm);
  return new;
end;
$$;
revoke all on function public._conversa_resolvida_sem_saida() from public, anon, authenticated;
drop trigger if exists mari_conversas_resolvida_sem_saida on public.mari_conversas;
create trigger mari_conversas_resolvida_sem_saida before update on public.mari_conversas
  for each row execute function public._conversa_resolvida_sem_saida();

-- Trava 2: 🔥 enviado a quem está em Saída → reabre (lead_reabrir, autor = quem mandou)
create or replace function public._oportunidade_tira_da_saida() returns trigger
language plpgsql security definer set search_path = public as $$
declare c public.mari_conversas;
begin
  select * into c from public.mari_conversas where id = new.conversa_id;
  if c.id is not null and coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada', 'teste_duplicada') then
    perform public.lead_reabrir(c.id, null);
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_oportunidade_tira_da_saida', coalesce(new.conversa_id::text, '') || ': ' || sqlerrm);
  return null;
end;
$$;
revoke all on function public._oportunidade_tira_da_saida() from public, anon, authenticated;
drop trigger if exists oportunidades_log_tira_da_saida on public.oportunidades_log;
create trigger oportunidades_log_tira_da_saida after insert on public.oportunidades_log
  for each row when (new.tipo = 'enviada') execute function public._oportunidade_tira_da_saida();

-- ───────── acerto dos dados ─────────
do $$
declare
  c public.mari_conversas;
  r record;
  n1 int := 0; n2 int := 0;
begin
  -- trava 1: as resolvidas sem saída de hoje
  for c in select * from public.mari_conversas mc where public._resolvida_sem_saida(mc) loop
    update public.mari_conversas set chatwoot_resolvida = false where id = c.id;
    perform public._reabrir_sem_saida(c);
    n1 := n1 + 1;
  end loop;
  -- trava 2: 🔥 enviado depois da saída (o último por conversa), reaberto em nome de quem mandou
  for r in select distinct on (l.conversa_id) l.conversa_id, l.criado_por
             from public.oportunidades_log l join public.mari_conversas mc on mc.id = l.conversa_id
            where l.tipo = 'enviada' and l.criado_por is not null
              and coalesce(mc.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada', 'teste_duplicada')
              and l.criado_em > coalesce(mc.funil_destino_em, '-infinity'::timestamptz)
              and not coalesce(mc.nao_contatar, false)
            order by l.conversa_id, l.criado_em desc loop
    perform set_config('request.jwt.claims', jsonb_build_object('sub', r.criado_por, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', r.criado_por::text, true);
    begin
      perform public.lead_reabrir(r.conversa_id, null);
      n2 := n2 + 1;
    exception when others then
      insert into public.mari_erros (no_n8n, mensagem) values ('0217_acerto_reabrir', r.conversa_id::text || ': ' || sqlerrm);
    end;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  raise notice '0217: % resolvidas sem saída reabertas · % tiradas da saída pelo 🔥', n1, n2;
end;
$$;

commit;
