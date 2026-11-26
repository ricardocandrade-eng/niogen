-- NIOGEN | supabase/migrations/0410_osab_importar_de_volta.sql | 25/11/2026 — Claude Code / Opus 5.5
-- Resumo: recria public.osab_importar(text, jsonb) — a porta da OSAB AUTOMÁTICA (0168), apagada em 18/11 pela limpeza de funções
-- sem uso (0286: "nenhum robô chama"). Agora chama: a rotina diária do Dashboard (n8n dashboard_diario, 0407). Corpo idêntico ao
-- da 0168 (troca o retrato da OSAB pelo arquivo e chama aplicar_osab — a mesma regra da importação manual; recusa arquivo vazio).
-- Achado na 1ª rodada real (25/11 ~21h10): "Could not find the function public.osab_importar(p_arquivo, p_linhas)". Lição (regra 21):
-- conferir a função na produção antes de ligar um fluxo a ela, não só a migration que a criou.
-- Regra 20: (3) estado muda pela função do banco (aplicar_osab); (4) pedido/OS/instalação → a Nio pela OSAB; (5) conferência item 38 (0407).
begin;

create or replace function public.osab_importar(p_arquivo text, p_linhas jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_imp uuid;
  n     int;
begin
  if not public._os_pode_gravar() then
    raise exception 'Sem permissão para importar o OSAB.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_linhas) is distinct from 'array' then raise exception 'p_linhas precisa ser uma lista.' using errcode = 'P0001'; end if;
  select count(distinct nullif(btrim(x ->> 'pedido'), '')) into n from jsonb_array_elements(p_linhas) x;
  if coalesce(n, 0) = 0 then
    raise exception 'OSAB sem nenhum pedido: nada foi importado.' using errcode = 'P0001';
  end if;
  insert into public.importacoes (tipo, arquivo_nome, dt_ref, linhas, aplicadas, ignoradas, resumo)
  values ('osab', left(coalesce(nullif(btrim(p_arquivo), ''), 'OSAB automático'), 200),
          (select max(left(x ->> 'dt_ref', 10)::date) from jsonb_array_elements(p_linhas) x where nullif(x ->> 'dt_ref', '') is not null),
          jsonb_array_length(p_linhas), 0, jsonb_array_length(p_linhas) - n,
          jsonb_build_object('automatico', true, 'pedidos', n))
  returning id into v_imp;
  delete from public.nio_osab o using jsonb_array_elements(p_linhas) x where o.pedido = nullif(btrim(x ->> 'pedido'), '');
  insert into public.nio_osab
  select (jsonb_populate_record(null::public.nio_osab,
            x || jsonb_build_object('importacao_id', v_imp, 'fonte', coalesce(nullif(x ->> 'fonte', ''), 'painel')))).*
    from (select distinct on (nullif(btrim(e ->> 'pedido'), '')) e as x
            from jsonb_array_elements(p_linhas) e
           where nullif(btrim(e ->> 'pedido'), '') is not null
           order by nullif(btrim(e ->> 'pedido'), ''), e ->> 'atualizado_nio_em' desc nulls last) s;
  return public.aplicar_osab(v_imp) || jsonb_build_object('importacao_id', v_imp);
end;
$$;
revoke all on function public.osab_importar(text, jsonb) from public, anon, authenticated;
grant execute on function public.osab_importar(text, jsonb) to service_role;

-- Repositório público: o texto da conferência (0407) citava a matrícula do login de gestão. Troca por "login de gestão".
do $$
declare d text := pg_get_functiondef('public.conferencia_itens'::regproc);
begin
  if d !~ 'sessão do TT[0-9]+ pode ter expirado' then return; end if;
  execute regexp_replace(d, 'sessão do TT[0-9]+ pode ter expirado', 'sessão do login de gestão pode ter expirado');
end $$;

commit;
