-- NIOGEN | supabase/migrations/0284_fila_vero_clique_mari.sql | 18/11/2026 — Claude Code / Opus 5.5
-- Ricardo, 18/11: "🔥 Clicou na oferta e não falou com a Mari: … enviar um template automático para o cliente pelo número da Mari
-- e adicionar na Live" → "de acordo, mas com o disparo imediato… Tem que pegar o cliente no pulo!" (exceção à regra "nunca o
-- número da Mari para disparar", só para quem tocou em "Quero ver a oferta"; 1 template, 1 vez) · "E na tela Fila Vero, precisa
-- ter uma sinalização … em cada lead … de que já foi tratado".
-- O que entra:
--   · template nio_fv_clique (MARKETING, WABA Nio — número da Mari), submetido por n8n/waba_templates_fila_vero.py;
--   · fila_vero_cliques_abrir() — quem clicou há ≥ 1 min (dá tempo de a pessoa mandar a mensagem pronta), nas últimas 24 h, sem
--     conversa com a Mari, no horário da Mari → o n8n fila_vero_clique (a cada 1 min) cria contato + conversa no Chatwoot
--     (como a indicação) e chama fila_vero_clique_resultado(), que cria o lead (origem fila_vero) e enfileira o template;
--   · resposta nessa conversa marca a linha como respondeu (gatilho mari_turnos_fila_vero_clique — a mensagem não traz o código);
--   · fila_vero_painel(): "na Mari" passa a ser quem RESPONDEU (antes: quem tinha conversa); 🔥 mostra quem clicou e não falou,
--     com o tratamento de cada um (Mari mandou às hh:mm · aguardando · fora do horário · não deu).
-- Os 4 que clicaram antes da 0284 (Marianne, Cleunice, Diego, Paula — ids na config "liberados") também recebem, fora da
-- janela de 24 h (Ricardo, 18/11: "Libera também para os 4 que clicaram antes").
-- Desligar: config_regras.fila_vero_clique → "ligado": false.
begin;

alter table public.fila_vero add column if not exists clique_msg_em timestamptz;
alter table public.fila_vero add column if not exists clique_msg_erro text;
alter table public.fila_vero add column if not exists clique_tentativas int not null default 0;
alter table public.fila_vero add column if not exists clique_tentativa_em timestamptz;

insert into public.config_regras (chave, valor, descricao) values
  ('fila_vero_clique', '{"ligado": true, "espera_s": 60, "janela_h": 24, "liberados": [1894, 1960, 3246, 1878]}',
   'Fila Vero: quem clicou em "Quero ver a oferta" e não escreveu recebe 1 template da Mari (nio_fv_clique) depois de espera_s segundos')
on conflict (chave) do nothing;

insert into public.config_templates_waba (nome, categoria, idioma, corpo, botoes, rodape, status, uso, atualizado_em) values
  ('nio_fv_clique', 'MARKETING', 'pt_BR',
   'Oi, {{1}}! Aqui é a Mari, da Nio 👋 Vi que você abriu a oferta da internet fibra com preço congelado até 2030. Quer que eu veja agora se ela chega no seu endereço?',
   '["Quero ver", "Agora não"]'::jsonb, null, 'PENDING',
   'FILA_VERO_CLIQUE (fila_vero_clique_resultado: 1 vez, para quem clicou na oferta e não escreveu)', now())
on conflict (nome) do nothing;

-- ---------------------------------------------------------------- quem abrir agora (n8n fila_vero_clique, a cada 1 min)
create or replace function public.fila_vero_cliques_abrir()
returns setof jsonb language plpgsql security definer set search_path = public as $$
declare cfg jsonb := coalesce(public._fv_cfg('fila_vero_clique'), '{}'::jsonb); r record;
        conta text := public._bo_cfg('chatwoot_conta', '195428') #>> '{}';
        inbox int := coalesce((public._ind_cfg() ->> 'inbox_id')::int, 153431);
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  if not coalesce((cfg ->> 'ligado')::boolean, false)
     or not exists (select 1 from public.config_templates_waba where nome = 'nio_fv_clique' and status = 'APPROVED') then
    return;
  end if;
  for r in select fv.* from public.fila_vero fv
            where fv.clicou_em is not null and fv.respondeu_em is null and fv.conversa_id is null and fv.clique_msg_em is null
              and fv.clicou_em <= now() - make_interval(secs => coalesce((cfg ->> 'espera_s')::int, 60))
              and (fv.clicou_em >= now() - make_interval(hours => coalesce((cfg ->> 'janela_h')::int, 24))
                   or coalesce(cfg -> 'liberados', '[]'::jsonb) @> to_jsonb(fv.id))   -- os 4 que clicaram antes (Ricardo, 18/11)
              and fv.status not in ('opt_out', 'ja_cliente_nio', 'sem_cobertura')
              and fv.clique_tentativas < 3
              and (fv.clique_tentativa_em is null or fv.clique_tentativa_em < now() - interval '10 minutes')
              and fv.telefone ~ '^55\d{10,11}$'
              and not exists (select 1 from public.mari_conversas c
                               where c.status in ('ativo', 'handoff_realizado')
                                 and public._tel_chave(c.telefone) = public._tel_chave(fv.telefone))
            order by fv.clicou_em limit 10 for update skip locked
  loop
    if not public.mari_no_horario(now(), r.cidade) then continue; end if;
    update public.fila_vero set clique_tentativas = clique_tentativas + 1, clique_tentativa_em = now() where id = r.id;
    return next jsonb_build_object('id', r.id,
      'nome', coalesce(nullif(initcap(lower(btrim(r.nome))), ''), 'Cliente Nio'),
      'telefone', '+' || r.telefone, 'inbox_id', inbox,
      'base', 'https://app.chatwoot.com/api/v1/accounts/' || conta);
  end loop;
  return;
end $$;

-- ---------------------------------------------------------------- conversa aberta no Chatwoot → lead da Mari + template
create or replace function public.fila_vero_clique_resultado(p_id bigint, p_ok boolean, p_chatwoot_conversation_id text default null, p_erro text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare fv public.fila_vero; c public.mari_conversas; v_cw text := nullif(btrim(coalesce(p_chatwoot_conversation_id, '')), '');
        v_id bigint; v_nome1 text;
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  select * into fv from public.fila_vero where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'linha inexistente'); end if;
  if fv.clique_msg_em is not null or fv.respondeu_em is not null then return jsonb_build_object('ok', true, 'registrado', 'já tratada'); end if;
  if not coalesce(p_ok, false) or v_cw is null then
    update public.fila_vero set clique_msg_erro = left(coalesce(p_erro, 'sem detalhe'), 300) where id = p_id;
    if fv.clique_tentativas >= 3 then
      insert into public.mari_erros (no_n8n, mensagem, payload)
      values ('fila_vero_clique', 'não abri a conversa de quem clicou na oferta (3×): ' || left(coalesce(p_erro, ''), 300),
              jsonb_build_object('fila_vero_id', p_id));
    end if;
    return jsonb_build_object('ok', true, 'registrado', 'erro');
  end if;
  v_nome1 := coalesce(nullif(initcap(lower(split_part(btrim(coalesce(fv.nome, '')), ' ', 1))), ''), 'tudo bem');
  select * into c from public.mari_conversas m
   where m.canal = 'whatsapp' and m.status in ('ativo', 'handoff_realizado')
     and (m.chatwoot_conversation_id = v_cw or public._tel_chave(m.telefone) = public._tel_chave(fv.telefone))
   order by (m.chatwoot_conversation_id = v_cw) desc limit 1;
  if c.id is null then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id, cadencia_passo, cadencia_passo_em)
    values (fv.telefone, initcap(lower(btrim(fv.nome))), 'whatsapp', 'fila_vero', v_cw, 'P1', now())
    returning * into c;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[Fila Vero: cliente antigo da equipe tocou em "Quero ver a oferta" ' ||
            coalesce(fv.lugar, '') || ' e não escreveu — a Mari mandou o template nio_fv_clique ("Quer que eu veja agora se ela chega no seu endereço?"). ' ||
            'Endereço da base: ' || coalesce(fv.lugar, 'sem endereço') || '. Não citar de onde veio o contato além de "você já foi cliente de internet com a nossa equipe".]', false);
    v_id := public._ind_template(c, null, 'fila_vero_clique', 'nio_fv_clique', jsonb_build_array(v_nome1));
    insert into public.contatos_cliente (conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
    values (c.id, c.telefone, 'whatsapp', 'saida', 'mari', now(), 'P1', 'ativo', 'Fila Vero · clicou na oferta (template nio_fv_clique)');
  end if;
  update public.fila_vero set conversa_id = c.id, clique_msg_em = now(), clique_msg_erro = null where id = p_id;
  return jsonb_build_object('ok', true, 'registrado', 'mari_mandou', 'conversa_id', c.id, 'acao_id', v_id);
end $$;

-- ---------------------------------------------------------------- resposta na conversa aberta pelo clique → respondeu
create or replace function public._fila_vero_resposta_clique()
returns trigger language plpgsql security definer set search_path = public as $$
declare v public.fila_vero%rowtype;
begin
  begin   -- nunca derruba a gravação do turno da Mari
    select * into v from public.fila_vero where conversa_id = new.conversa_id and respondeu_em is null limit 1;
    if v.id is null then return null; end if;
    update public.fila_vero set respondeu_em = now() where id = v.id;
    if v.status in ('apto', 'enviado', 'erro', 'encerrado') then
      perform set_config('niogen.fila_vero_porta', 'on', true);
      perform set_config('niogen.fila_vero_motivo', 'respondeu a Mari (template do clique)', true);
      perform set_config('niogen.fila_vero_autor', 'mari_turnos', true);
      update public.fila_vero set status = 'respondeu' where id = v.id;
      perform set_config('niogen.fila_vero_porta', 'off', true);
    end if;
  exception when others then
    raise warning 'fila_vero_resposta_clique: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists mari_turnos_fila_vero_clique on public.mari_turnos;
create trigger mari_turnos_fila_vero_clique after insert on public.mari_turnos
  for each row when (new.papel = 'lead')
  execute function public._fila_vero_resposta_clique();

-- ---------------------------------------------------------------- painel: "na Mari" = respondeu; 🔥 com o tratamento
CREATE OR REPLACE FUNCTION public.fila_vero_painel()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with f as (select fv.*, c.funil_etapa, c.venda_id as cvenda from public.fila_vero fv left join public.mari_conversas c on c.id = fv.conversa_id),
  v as (select f.template1, f.faixa, vd.status, vd.comissao_prevista from f join public.vendas vd on vd.id = coalesce(f.venda_id, f.cvenda)),
  tp as (select template1 t, count(*) enviados, count(entregue_em) entregues, count(lido_em) lidos, count(clicou_em) cliques,
                count(respondeu_em) na_mari, count(*) filter (where status = 'opt_out') opt_out,
                count(*) filter (where funil_etapa in ('qualificada', 'pedido', 'biometria', 'agendada', 'instalada')) qualificados
           from f where template1 is not null group by 1),
  fx as (select faixa, count(*) filter (where status = 'apto') aptos, count(*) filter (where toques > 0) enviados, count(entregue_em) entregues,
                count(clicou_em) cliques, count(respondeu_em) na_mari, count(*) filter (where status = 'opt_out' and toques > 0) opt_out
           from f where faixa is not null group by 1)
  select jsonb_build_object(
    'ativo', coalesce((public._fv_cfg('fila_vero_ativo') #>> '{}')::boolean, false),
    'dentro_horario', public.fila_vero_dentro_horario(),
    'ritmo', coalesce((public._fv_cfg('fila_vero_ritmo_dia') #>> '{}')::int, 100),
    'hoje', public._fv_enviados_hoje(),
    'rampa', public._fv_cfg('fila_vero_rampa'),
    'ab', public._fv_cfg('fila_vero_ab'),
    'qualidade', public._fv_cfg('fila_vero_qualidade'),
    'prioridade_b', public._fv_cfg('fila_vero_prioridade_b'),
    'hist', public._fv_cfg('fila_vero_ativo_hist'),
    'clique_auto', jsonb_build_object('ligado', coalesce((public._fv_cfg('fila_vero_clique') ->> 'ligado')::boolean, false),
                                      'template', (select status from public.config_templates_waba where nome = 'nio_fv_clique')),
    'base', (select count(*) from f),
    'por_status', (select jsonb_object_agg(status, n) from (select status, count(*) n from f group by 1) s),
    'enviados', (select count(*) from f where toques > 0),
    'segundo_toque', (select count(*) from f where toques >= 2),
    'entregues', (select count(entregue_em) from f),
    'lidos', (select count(lido_em) from f),
    'cliques', (select count(clicou_em) from f),
    'na_mari', (select count(respondeu_em) from f),
    'mari_chamou', (select count(clique_msg_em) from f),
    'qualificados', (select count(*) from f where funil_etapa in ('qualificada', 'pedido', 'biometria', 'agendada', 'instalada')),
    'pedidos', (select count(*) from f where funil_etapa in ('pedido', 'biometria', 'agendada', 'instalada')),
    'instaladas', (select count(*) from v where status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')),
    'comissao', (select coalesce(sum(comissao_prevista), 0) from v where status <> 'saida'),
    'opt_out', (select count(*) from f where status = 'opt_out' and toques > 0),
    'por_template', (select coalesce(jsonb_object_agg(t, to_jsonb(tp) - 't'), '{}'::jsonb) from tp),
    'por_faixa', (select coalesce(jsonb_object_agg(faixa, to_jsonb(fx) - 'faixa'), '{}'::jsonb) from fx),
    'falhas', (select coalesce(jsonb_object_agg(coalesce(erro_codigo, '?'), n), '{}'::jsonb) from (select erro_codigo, count(*) n from f where erro_codigo is not null group by 1) e),
    'clicou_sem_mari', (select coalesce(jsonb_agg(x order by x ->> 'clicou_em' desc), '[]'::jsonb) from (
        select jsonb_build_object('id', id, 'nome', initcap(lower(split_part(btrim(coalesce(nome, '')), ' ', 1))), 'telefone', telefone,
                                  'template', template1, 'clicou_em', clicou_em, 'lugar', lugar, 'conversa_id', conversa_id,
                                  'mari_em', clique_msg_em, 'erro', clique_msg_erro, 'tentativas', clique_tentativas,
                                  'liberado', coalesce(public._fv_cfg('fila_vero_clique') -> 'liberados', '[]'::jsonb) @> to_jsonb(id)) x
          from f where clicou_em is not null and respondeu_em is null and clicou_em > now() - interval '7 days'
           and status not in ('opt_out', 'ja_cliente_nio') order by clicou_em desc limit 30) c),
    'na_mari_lista', (select coalesce(jsonb_agg(x order by x ->> 'em' desc), '[]'::jsonb) from (
        select jsonb_build_object('conversa_id', f.conversa_id, 'nome', coalesce(nullif(split_part(btrim(c.nome_contato), ' ', 1), ''), initcap(lower(split_part(btrim(coalesce(f.nome, '')), ' ', 1)))),
                                  'template', f.template1, 'em', f.respondeu_em, 'etapa', c.funil_etapa, 'destino', c.funil_destino,
                                  'chatwoot', c.chatwoot_conversation_id, 'lugar', f.lugar, 'pelo_clique', f.clique_msg_em is not null,
                                  'vez', c.status) x
          from f join public.mari_conversas c on c.id = f.conversa_id where f.respondeu_em is not null
         order by f.respondeu_em desc limit 50) m),
    'em', now())
  where public.meu_perfil() in ('admin', 'backoffice') or session_user <> 'authenticator';
$function$;

revoke all on function public.fila_vero_cliques_abrir(), public.fila_vero_clique_resultado(bigint, boolean, text, text),
  public._fila_vero_resposta_clique() from public, anon, authenticated;
grant execute on function public.fila_vero_cliques_abrir(), public.fila_vero_clique_resultado(bigint, boolean, text, text) to service_role;

commit;
