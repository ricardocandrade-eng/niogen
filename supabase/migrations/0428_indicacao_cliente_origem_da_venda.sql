-- NIOGEN | supabase/migrations/0428_indicacao_cliente_origem_da_venda.sql | 26/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 26/11 ~23h40: "A origem deve ficar 'Indicação Cliente' no lugar de 'Evento / outro'".
-- A 0427 mudou a origem da CONVERSA do indicado para Indicação, mas a venda da L-397 já tinha nascido com origem 'outro'
-- (o handoff copia a origem da conversa na hora em que a venda nasce, e ali ela ainda era "desconhecida").
-- O que muda:
--   1. _ind_vincular: ao ligar o indicado a quem indicou, a venda dele que estava em 'outro' passa a 'indicacao'
--      (venda de anúncio, parceiro, rua etc. não é tocada: só a que não tinha canal).
--   2. O canal se chama "Indicação Cliente" (config_canais.nome; as telas acompanham no mesmo commit).
--   3. Uma vez agora: toda venda em 'outro' cujo lead tem indicação válida vira 'indicacao' (hoje, a da L-397).
-- Subida sem portão por ordem do Ricardo (26/11 ~23h20). Cenário X150 ganhou a conferência da origem da venda (não rodado).

begin;

do $$
declare d text := pg_get_functiondef('public._ind_vincular'::regproc);
  a text := $a$update public.mari_conversas set origem = 'indicacao' where id = cd.id and coalesce(origem, 'desconhecida') in ('direto', 'desconhecida');$a$;
begin
  if position('0428' in d) > 0 then return; end if;
  if position(a in d) = 0 or position(a in substr(d, position(a in d) + 1)) > 0 then
    raise exception '0428: _ind_vincular mudou — refazer o remendo a partir da versão no ar';
  end if;
  d := replace(d, a, a || E'
  -- 0428: a venda do indicado que nasceu sem canal passa a Indicação Cliente
'
                     || $b$  update public.vendas set origem = 'indicacao' where id = v.id and origem = 'outro';$b$);
  execute d;
end $$;

update public.config_canais set nome = 'Indicação Cliente' where canal = 'indicacao' and nome = 'Indicação';

update public.vendas vv set origem = 'indicacao'
 where vv.origem = 'outro'
   and exists (select 1 from public.indicacoes i
                where i.estado <> 'invalida' and (i.venda_id = vv.id
                   or i.conversa_id in (select m.id from public.mari_conversas m where m.venda_id = vv.id)));

do $$
begin
  if position('0428' in pg_get_functiondef('public._ind_vincular'::regproc)) = 0 then raise exception '0428: o remendo não entrou'; end if;
  if exists (select 1 from public.vendas vv join public.mari_conversas m on m.venda_id = vv.id
              join public.indicacoes i on i.conversa_id = m.id and i.estado <> 'invalida' where vv.origem = 'outro') then
    raise exception '0428: ainda há venda de indicado com origem outro';
  end if;
end $$;

commit;
