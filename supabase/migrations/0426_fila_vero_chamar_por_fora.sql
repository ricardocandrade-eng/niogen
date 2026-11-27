-- NIOGEN | supabase/migrations/0426_fila_vero_chamar_por_fora.sql | 26/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 26/11: "Leads que chegam do Fila Vero e vão parar na Live 2.0, eu fico sem ação para tratá-los. Não tenho muito o que
-- fazer porque foi um template que disparamos e a janela de 24h está fechada. (...) devem ir pra Live, pra eu tomar ciência e
-- chamar os leads por um WhatsApp comum. (...) um botão para me perguntar se enviei a mensagem e depois que confirmar ou adiar o
-- envio, sair da Live." → "Regra 8: aprovado! Pode entrar na Live 1 hora depois. Pode manter os dois dias."
-- Quem é: lead da Fila Vero que clicou na oferta, recebeu o template da Mari (nio_fv_clique, 0284) e nunca escreveu. A janela de
-- 24 h nunca abriu: texto livre não sai. Hoje ele some sozinho em 2 dias (0285) sem ninguém do time ter o que fazer.
-- O que muda:
--  (1) live2_fila(): 1 h depois do template da Mari sem resposta, o lead vira tarefa "ligar" com a fonte fila_vero:chamar_fora.
--      Botões (vêm do banco): Abrir WhatsApp (wa.me do cliente com o texto pronto) · Enviei ✓ · Abrir o cliente; Adiar e Saída são
--      os fixos da Live 2.0 (backoffice_conversa_espera e lead_sair, pela porta, como em qualquer linha).
--  (2) fila_vero_fora_enviei(conversa): grava o toque (fila_vero.fora_enviado_em/fora_por, contatos_cliente FV_FORA, linha de
--      sistema na conversa) e dá baixa na fila até o fim do prazo (live2_baixas → o lead aparece no radar "em pausa"). Um só por lead.
--  (3) fila_vero_clique_encerrar(): a Saída "Sem resposta" automática conta 2 dias do ÚLTIMO fato — template da Mari, Enviei ou
--      a data do Adiar — e não leva quem está adiado. Sem Enviei e sem Adiar, nada muda: 2 dias depois do template, como na 0285.
--  (4) config_regras.fila_vero_fora: liga/desliga, minutos de espera, dias, o número de apoio e o texto pronto (sem deploy).
-- Regra 8 (exceção aprovada pelo Ricardo em 26/11): 3º contato, por WhatsApp comum, só para quem clicou e não respondeu.
-- Regra 20: (1) etapa/situação/vez não mudam (segue "com a Mari"); o prazo é a Saída automática; (2) saída automática em 2 dias,
-- e o Adiar tem data; (3) nenhum estado novo: Enviei grava um FATO do contato, Adiar e Saída passam pela porta que já existe;
-- (4) fonte única do toque: fila_vero.fora_enviado_em; (5) conferência: não precisa de item novo — não há estado nem número novo,
-- e o prazo é garantido por fila_vero_clique_encerrar (n8n fila_vero_clique, a cada 1 min). Regra 15: texto, número e prazos em config.
-- Regras de ouro 2 e 10: nenhum evento novo na porta. live2_fila e _live2_acoes são remendadas da versão no ar (pg_get_functiondef).
-- Cenário X149.
begin;

alter table public.fila_vero add column if not exists fora_enviado_em timestamptz;
alter table public.fila_vero add column if not exists fora_por uuid;
comment on column public.fila_vero.fora_enviado_em is
  '0426: quando o time confirmou (Live 2.0 › Enviei) que chamou o cliente por fora, pelo WhatsApp de apoio. Um só por lead.';

insert into public.config_regras (chave, valor, descricao) values
  ('fila_vero_fora',
   jsonb_build_object('ligado', true, 'espera_min', 60, 'dias', 2, 'numero', '5532920035815',
     'texto', 'Oi, {nome}! Tudo bem? Aqui é da equipe da Nio 👋 Vi que você abriu a nossa oferta de internet fibra. Quer que eu veja se ela já chega no seu endereço? É só me passar o seu CEP 😊'),
   'Fila Vero (0426): quem clicou na oferta e não respondeu à Mari entra na Live 2.0 depois de espera_min para o time chamar pelo WhatsApp de apoio (numero); dias = prazo da Saída automática depois do Enviei; texto = mensagem pronta ({nome} = 1º nome)')
on conflict (chave) do nothing;

-- ───────────── Enviei: o time confirma que chamou por fora ─────────────
create or replace function public.fila_vero_fora_enviei(p_conversa uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cfg    jsonb := coalesce(public._fv_cfg('fila_vero_fora'), '{}'::jsonb);
  v_dias int := greatest(coalesce((cfg ->> 'dias')::int, 2), 1);
  v_num  text := coalesce(cfg ->> 'numero', '');
  v      public.fila_vero%rowtype;
  v_ate  timestamptz;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só o backoffice registra o contato por fora.' using errcode = '42501';
  end if;
  select * into v from public.fila_vero where conversa_id = p_conversa order by id desc limit 1 for update;
  if v.id is null or v.clique_msg_em is null then
    raise exception 'Este lead não veio do clique da Fila Vero.' using errcode = 'P0001';
  end if;
  if v.respondeu_em is not null
     or exists (select 1 from public.mari_turnos t where t.conversa_id = p_conversa and t.papel = 'lead') then
    raise exception 'O cliente já respondeu à Mari: fale com ele pela conversa.' using errcode = 'P0001';
  end if;
  if v.fora_enviado_em is not null then
    raise exception 'O contato por fora deste lead já foi registrado em %.', to_char(v.fora_enviado_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
      using errcode = 'P0001';
  end if;
  if exists (select 1 from public.mari_conversas c where c.id = p_conversa
              and (coalesce(c.funil_destino, 'em_andamento') <> 'em_andamento' or coalesce(c.nao_contatar, false))) then
    raise exception 'Este lead já saiu ou está como Não contatar.' using errcode = 'P0001';
  end if;

  v_ate := now() + make_interval(days => v_dias);
  update public.fila_vero set fora_enviado_em = now(), fora_por = auth.uid() where id = v.id;
  insert into public.contatos_cliente (canal, direcao, por, em, resumo, telefone, conversa_id, toque, tipo)
  values ('whatsapp', 'saida', 'vendedor', now(),
          left('Fila Vero: chamado por fora, pelo WhatsApp de apoio' || case when v_num <> '' then ' (final ' || right(v_num, 4) || ')' else '' end, 300),
          v.telefone, p_conversa, 'FV_FORA', 'ativo');
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (p_conversa, 'sistema',
          format('[Fila Vero: contato por fora registrado na Live — o time chamou o cliente pelo WhatsApp de apoio%s; sem resposta em %s dias, Saída "Sem resposta" automática]',
                 case when v_num <> '' then ' (final ' || right(v_num, 4) || ')' else '' end, v_dias), false);
  insert into public.live2_baixas (k, conversa_id, venda_id, como, nota, por, ate)
  values ('c:' || p_conversa::text, p_conversa, null, 'cobrei', 'Fila Vero: chamado por fora', auth.uid(), v_ate);
  return jsonb_build_object('ok', true, 'ate', v_ate,
    'resumo', format('✓ Contato por fora registrado · sem resposta até %s, vai para a Saída sozinho',
                     to_char(v_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI')));
end $$;
revoke all on function public.fila_vero_fora_enviei(uuid) from public, anon;
grant execute on function public.fila_vero_fora_enviei(uuid) to authenticated, service_role;

-- ───────────── a Saída automática conta do último fato e respeita o Adiar ─────────────
create or replace function public.fila_vero_clique_encerrar()
returns int language plpgsql security definer set search_path = public as $$
declare r record; antes text; res jsonb; n int := 0;
        v_dias int := coalesce((public._fv_cfg('fila_vero_clique') ->> 'sem_resposta_dias')::int, 2);
        v_fora int := greatest(coalesce((public._fv_cfg('fila_vero_fora') ->> 'dias')::int, 2), 1);
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  for r in select fv.id, fv.status, c.id as cid, (fv.fora_enviado_em is not null) as fora
             from public.fila_vero fv join public.mari_conversas c on c.id = fv.conversa_id
            where fv.clique_msg_em is not null and fv.respondeu_em is null
              and (c.espera_ate is null or c.espera_ate <= now())          -- 0426: adiado na Live espera a data
              and greatest(fv.clique_msg_em + make_interval(days => v_dias),
                           fv.fora_enviado_em + make_interval(days => v_fora),
                           c.espera_ate + make_interval(days => v_fora)) < now()
              and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
              and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead')
            limit 20
  loop
    begin
      antes := public._porta_situacao(r.cid, null::uuid);
      res := public.porta('saida:sem_resposta', r.cid, null::uuid,
               jsonb_build_object('obs', case when r.fora then format('Fila Vero: não respondeu ao contato por fora em %s dias', v_fora)
                                              else format('Fila Vero: não respondeu à Mari em %s dias depois do clique', v_dias) end));
      perform public._porta_anotar('saida:sem_resposta', 'fila_vero_clique_encerrar', r.cid, null::uuid, antes, res);
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (r.cid, 'sistema',
              case when r.fora then format('[Fila Vero: sem resposta ao contato por fora em %s dias — Saída "Sem resposta" automática; se escrever, reabre]', v_fora)
                   else format('[Fila Vero: sem resposta à mensagem do clique em %s dias — Saída "Sem resposta" automática; se escrever, reabre]', v_dias) end, false);
      if r.status in ('apto', 'enviado', 'erro') then
        perform public.fila_vero_mudar(r.id, 'encerrado',
                  case when r.fora then format('contato por fora sem resposta (%s dias)', v_fora)
                       else format('clique sem resposta à Mari (%s dias)', v_dias) end, 'fila_vero_clique');
      end if;
      n := n + 1;
    exception when others then
      insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (r.cid, 'fila_vero_clique_encerrar', 'Saída sem resposta: ' || sqlerrm);
    end;
  end loop;
  return n;
end $$;
revoke all on function public.fila_vero_clique_encerrar() from public, anon, authenticated;

-- ───────────── os botões do cartão (remendo da _live2_acoes no ar) ─────────────
do $mig$
declare
  d   text := pg_get_functiondef('public._live2_acoes(text,text,text,uuid,uuid,text,text,text,jsonb)'::regprocedure);
  ins text := $ins$
  -- 0426: Fila Vero — clicou na oferta e não respondeu à Mari: o time chama por fora (WhatsApp de apoio)
  if p_fonte = 'fila_vero' then
    if tel <> '' then
      a := a || jsonb_build_object('a', 'wa', 'rotulo', 'Abrir WhatsApp', 'principal', true,
                                   'tel', case when length(tel) <= 11 then '55' || tel else tel end,
                                   'texto', coalesce(p_extra ->> 'texto', ''));
    end if;
    a := a || jsonb_build_object('a', 'rpc', 'fn', 'fila_vero_fora_enviei', 'rotulo', 'Enviei ✓',
                                 'confirma', 'Confirma que você já mandou a mensagem para este cliente pelo WhatsApp de apoio? Ele sai da Live; sem resposta, vai para a Saída sozinho.',
                                 'args', jsonb_build_object('p_conversa', conv))
           || jsonb_build_object('a', 'abrir', 'rotulo', 'Abrir o cliente', 'leve', true);
    return a;
  end if;
$ins$;
begin
  if position('fila_vero_fora_enviei' in d) > 0 then
    raise notice '0426: _live2_acoes já tem o cartão da Fila Vero';
  else
    if regexp_count(d, E'\\r?\\n  if p_fonte = ''andamento'' then\\r?\\n') <> 1 then
      raise exception '0426: não achei o ponto de encaixe em _live2_acoes';
    end if;
    d := regexp_replace(d, E'(\\r?\\n)(  if p_fonte = ''andamento'' then\\r?\\n)', E'\\1' || ins || E'\\1\\2');
    execute d;
  end if;
end $mig$;

-- ───────────── a tarefa na fila única (remendo da live2_fila no ar) ─────────────
do $mig$
declare
  d    text := pg_get_functiondef('public.live2_fila()'::regprocedure);
  decl text := $ins$
  v_fv    jsonb := coalesce((select valor from public.config_regras where chave = 'fila_vero_fora'), '{}'::jsonb);$ins$;
  ins  text := $ins$
    union all
    -- (6) 0426: Fila Vero — clicou na oferta, recebeu o template da Mari e não escreveu: a janela de 24 h nunca abriu → chamar por fora
    select 'c:' || c.id::text, c.id, null::uuid, 'ligar', 'fila_vero', 'chamar_fora', fv.id::text, null::text,
           format('Clicou na oferta da Fila Vero e não respondeu à Mari · a janela de 24 h não abriu: chame pelo WhatsApp de apoio%s e marque Enviei',
                  case when coalesce(v_fv ->> 'numero', '') <> '' then ' (final ' || right(v_fv ->> 'numero', 4) || ')' else '' end),
           fv.clique_msg_em + make_interval(mins => coalesce((v_fv ->> 'espera_min')::int, 60)),
           greatest(fv.clique_msg_em, fv.fora_enviado_em, c.espera_ate) + make_interval(days => greatest(coalesce((v_fv ->> 'dias')::int, 2), 1)), 2,
           jsonb_build_object('texto', replace(coalesce(v_fv ->> 'texto', ''), '{nome}',
                                               coalesce(nullif(initcap(lower(split_part(btrim(coalesce(fv.nome, '')), ' ', 1))), ''), 'tudo bem'))), 0
      from public.fila_vero fv
      join public.mari_conversas c on c.id = fv.conversa_id
     where coalesce((v_fv ->> 'ligado')::boolean, false)
       and fv.clique_msg_em is not null and fv.respondeu_em is null
       and fv.clique_msg_em <= now() - make_interval(mins => coalesce((v_fv ->> 'espera_min')::int, 60))
       and c.venda_id is null
       and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
       and not coalesce(c.nao_contatar, false)
       and (c.espera_ate is null or c.espera_ate <= now())
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead')$ins$;
begin
  if position('chamar_fora' in d) > 0 then
    raise notice '0426: live2_fila já tem a tarefa da Fila Vero';
  else
    if regexp_count(d, E'\\n  v_res   jsonb;\\r?\\nbegin\\r?\\n') <> 1
       or regexp_count(d, E'\\n      from public\\.v_andamento_pendencias p\\r?\\n  \\),') <> 1 then
      raise exception '0426: não achei os pontos de encaixe em live2_fila';
    end if;
    d := regexp_replace(d, E'(\\n  v_res   jsonb;)(\\r?\\nbegin\\r?\\n)', E'\\1' || decl || E'\\2');
    d := regexp_replace(d, E'(\\n      from public\\.v_andamento_pendencias p)(\\r?\\n  \\),)', E'\\1' || ins || E'\\2');
    execute d;
  end if;
end $mig$;

commit;
