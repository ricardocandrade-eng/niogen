-- NIOGEN | supabase/migrations/0211_trocar_titular_credito.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Correção da 0210: vendas.credito_resultado só aceita 'aprovado' | 'so_cartao' | 'pendente' | 'negado' (check da tabela);
-- venda_trocar_titular validava com os nomes do operador (aprovado_todas…) e a gravação falharia no check.
begin;
set local lock_timeout = '8s';
create or replace function public.venda_trocar_titular(p_venda uuid, p_nome text, p_cpf text, p_relacao text,
                                                       p_motivo text default null, p_credito text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v    public.vendas;
  doc  text := public._so_digitos(p_cpf);
  nome text := upper(btrim(regexp_replace(coalesce(p_nome, ''), '\s+', ' ', 'g')));
  rel  text := btrim(coalesce(p_relacao, ''));
  soltas int := 0;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice troca o titular.' using errcode = '42501';
  end if;
  if not public._cpf_ok(doc) then raise exception 'CPF do novo titular inválido (confira os dígitos).' using errcode = 'P0001'; end if;
  if length(nome) < 5 or nome !~ ' ' then raise exception 'Nome completo do novo titular (como saiu na Receita).' using errcode = 'P0001'; end if;
  if length(rel) < 2 then raise exception 'Diga o parentesco do titular com quem conversa (pai, mãe, filho, cônjuge…).' using errcode = 'P0001'; end if;
  if p_credito is not null and p_credito not in ('aprovado', 'so_cartao', 'pendente', 'negado') then
    raise exception 'Resultado de crédito inválido.' using errcode = 'P0001';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found then raise exception 'Venda não encontrada.' using errcode = 'P0001'; end if;
  if v.status = 'saida' then raise exception 'A venda está em Saída: reabra pela ficha.' using errcode = 'P0001'; end if;
  if public._so_digitos(v.cliente_cpf_cnpj) = doc then raise exception 'Esse já é o CPF do titular desta venda.' using errcode = 'P0001'; end if;

  update public.vendas set
    titular_anterior = jsonb_build_object('nome', v.cliente_nome, 'cpf_cnpj', v.cliente_cpf_cnpj, 'credito', v.credito_resultado,
                                          'credito_em', v.credito_em, 'ate', now()),
    contato_nome = coalesce(contato_nome, v.cliente_nome),
    contato_relacao = rel,
    cliente_nome = nome,
    cliente_cpf_cnpj = doc,
    credito_resultado = p_credito,
    credito_em = case when p_credito is null then null else now() end,
    titular_trocado_em = now(),
    titular_trocado_por = auth.uid()
  where id = v.id;

  -- As biometrias do CPF antigo deixam de valer para esta venda (o próximo GED360 casa as do titular novo pelo CPF).
  update public.nio_biometria set venda_id = null where venda_id = v.id and cpf_cnpj is distinct from doc;
  get diagnostics soltas = row_count;

  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (v.id, 'titular_trocado', jsonb_build_object('de', v.cliente_nome, 'para', nome, 'relacao', rel,
          'motivo', nullif(btrim(coalesce(p_motivo, '')), ''), 'credito', p_credito, 'biometrias_soltas', soltas), auth.uid());

  -- Casa já as biometrias do titular novo que o GED360 leu antes da troca (o mapa aplica na próxima leitura).
  update public.nio_biometria set venda_id = v.id, ultima_leitura = now()
   where venda_id is null and cpf_cnpj = doc and data_envio > now() - interval '15 days';

  return jsonb_build_object('ok', true, 'titular', nome, 'contato', coalesce(v.contato_nome, v.cliente_nome), 'relacao', rel);
end;
$$;
revoke all on function public.venda_trocar_titular(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.venda_trocar_titular(uuid, text, text, text, text, text) to authenticated;

commit;
