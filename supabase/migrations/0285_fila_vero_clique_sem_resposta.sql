-- NIOGEN | supabase/migrations/0285_fila_vero_clique_sem_resposta.sql | 18/11/2026 — Claude Code / Opus 5.5
-- Ricardo, 18/11: "Saída automática em 2 dias. E eu acho que esses podem ficar recolhidos, como fica os 'Acompanhando'".
-- Quem recebeu a mensagem da Mari pelo clique (0284) e não respondeu em 2 dias vai para a Saída "Sem resposta" pela porta única
-- (sem mensagem nenhuma; se escrever depois, a porta reabre como qualquer Saída) e a linha da fila vira "encerrado".
-- A cadência da Mari pula a origem fila_vero sem mensagem do lead, por isso o fim precisava ser daqui.
-- Roda dentro de fila_vero_cliques_abrir() (n8n fila_vero_clique, a cada 1 min). Prazo: config_regras.fila_vero_clique.sem_resposta_dias.
begin;

update public.config_regras set valor = valor || '{"sem_resposta_dias": 2}'::jsonb, atualizado_em = now()
 where chave = 'fila_vero_clique';

create or replace function public.fila_vero_clique_encerrar()
returns int language plpgsql security definer set search_path = public as $$
declare r record; antes text; res jsonb; n int := 0;
        v_dias int := coalesce((public._fv_cfg('fila_vero_clique') ->> 'sem_resposta_dias')::int, 2);
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  for r in select fv.id, fv.status, c.id as cid
             from public.fila_vero fv join public.mari_conversas c on c.id = fv.conversa_id
            where fv.clique_msg_em is not null and fv.respondeu_em is null
              and fv.clique_msg_em < now() - make_interval(days => v_dias)
              and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
              and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead')
            limit 20
  loop
    begin
      antes := public._porta_situacao(r.cid, null::uuid);
      res := public.porta('saida:sem_resposta', r.cid, null::uuid,
               jsonb_build_object('obs', format('Fila Vero: não respondeu à Mari em %s dias depois do clique', v_dias)));
      perform public._porta_anotar('saida:sem_resposta', 'fila_vero_clique_encerrar', r.cid, null::uuid, antes, res);
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (r.cid, 'sistema', format('[Fila Vero: sem resposta à mensagem do clique em %s dias — Saída "Sem resposta" automática; se escrever, reabre]', v_dias), false);
      if r.status in ('apto', 'enviado', 'erro') then
        perform public.fila_vero_mudar(r.id, 'encerrado', format('clique sem resposta à Mari (%s dias)', v_dias), 'fila_vero_clique');
      end if;
      n := n + 1;
    exception when others then
      insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (r.cid, 'fila_vero_clique_encerrar', 'Saída sem resposta: ' || sqlerrm);
    end;
  end loop;
  return n;
end $$;

create or replace function public.fila_vero_cliques_abrir()
returns setof jsonb language plpgsql security definer set search_path = public as $$
declare cfg jsonb := coalesce(public._fv_cfg('fila_vero_clique'), '{}'::jsonb); r record;
        conta text := public._bo_cfg('chatwoot_conta', '195428') #>> '{}';
        inbox int := coalesce((public._ind_cfg() ->> 'inbox_id')::int, 153431);
begin
  if not public._os_pode_gravar() then raise exception 'Só serviço.' using errcode = '42501'; end if;
  perform public.fila_vero_clique_encerrar();   -- 0285: quem não respondeu à Mari em 2 dias sai (Sem resposta)
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

revoke all on function public.fila_vero_clique_encerrar() from public, anon, authenticated;
revoke all on function public.fila_vero_cliques_abrir() from public, anon, authenticated;
grant execute on function public.fila_vero_cliques_abrir() to service_role;

commit;
