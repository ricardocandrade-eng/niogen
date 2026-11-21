-- NIOGEN | supabase/migrations/0341_nova_venda_e_conferencia_pela_porta.sql | 21/11/2026 — Claude Code (Opus 5.5)
-- Fase 2, passo 4b (a) — Ricardo, 21/11: "Faz o 4b (a) e (b) enquanto a sombra roda". Os dois caminhos que a 0295 deixou de fora:
-- (1) Nova venda que já nasce em Saída (Já é cliente Nio · Fachada não atendida · Recusou · momento): a tela fazia INSERT direto com
--     status = 'saida'. Agora chama venda_nova_saida: a venda nasce em Qualificado e sai pela porta (lead_sair → porta 'saida:<motivo>'),
--     na mesma transação — o mesmo caminho, os mesmos efeitos e a mesma anotação de qualquer Saída. A trava nova recusa o INSERT
--     direto em Saída feito por pessoa logada.
-- (2) Conferência do parceiro reprovada (D17): a ficha gravava conferencia_status = 'reprovada' e status = 'saida' num PATCH só — e,
--     desde a 0295, esse PATCH é recusado pela trava da etapa (o Reprovar estava quebrado; em produção nenhuma venda foi reprovada
--     desde então — há 1 venda de parceiro, pendente). Agora venda_conferencia_reprovar grava a conferência e faz a Saída pela porta.
--     O motivo da conferência vira um motivo da lista única de Saída (tabela abaixo). PROPOSTA — conferir com o Ricardo.
-- Regra 20: (1) sem estado novo; (2) a etapa só muda pela porta (lead_sair), com anotação; (3) tela: Nova venda e ficha chamam as
--     RPCs, nada novo na tela; (4) sem fonte nova; (5) desempenho: uma chamada no lugar de outra. Cenário X66.
begin;

-- (1) Nova venda já em Saída
create or replace function public.venda_nova_saida(p_linha jsonb, p_motivo text, p_sub text default null, p_volta date default null,
                                                   p_obs text default null)
returns jsonb
language plpgsql
security invoker            -- o INSERT segue as regras de acesso de quem está logado (vendedor só a própria venda)
set search_path = public
as $$
declare
  cols text;
  v_id uuid;
  r    jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice', 'vendedor') then
    raise exception 'Sem permissão.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.config_lead where parceiro_id = 'dharma' and tipo = 'saida' and codigo = p_motivo) then
    raise exception 'Motivo de saída desconhecido: %', p_motivo;
  end if;
  -- só as colunas que a tela mandou (as outras ficam com o padrão da tabela); a etapa e a Saída são da porta
  select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into cols
    from pg_attribute a
   where a.attrelid = 'public.vendas'::regclass and a.attnum > 0 and not a.attisdropped
     and p_linha ? a.attname
     and a.attname not in ('id', 'status', 'motivo_saida', 'saida_motivo', 'saida_sub', 'interesse_futuro_em');
  if cols is null then raise exception 'Venda sem dados.'; end if;
  execute format('insert into public.vendas (status, %s) select ''0_qualificado'', %s from jsonb_populate_record(null::public.vendas, $1) returning id',
                 cols, cols)
    using p_linha into v_id;
  r := public.lead_sair(null, v_id, p_motivo, p_sub, p_volta, p_obs, null);
  return coalesce(r, '{}'::jsonb) || jsonb_build_object('venda_id', v_id);
end $$;
revoke all on function public.venda_nova_saida(jsonb, text, text, date, text) from public, anon;
grant execute on function public.venda_nova_saida(jsonb, text, text, date, text) to authenticated, service_role;

-- a trava: pessoa logada não cria venda já em Saída com INSERT direto (o PostgREST manda o INSERT como comando de topo)
create or replace function public._vendas_nasce_em_saida()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(auth.role(), '') = 'authenticated'
     and current_query() ~* 'insert\s+into\s+("?public"?\s*\.\s*)?"?vendas"?[\s(]' then
    raise exception 'Venda nova em Saída só pelo botão da Nova venda (passa pela porta, com o motivo).' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function public._vendas_nasce_em_saida() from public, anon, authenticated;
drop trigger if exists vendas_a_nasce_em_saida on public.vendas;
create trigger vendas_a_nasce_em_saida
  before insert on public.vendas
  for each row when (new.status = 'saida')
  execute function public._vendas_nasce_em_saida();

-- (2) Conferência reprovada (D17)
create or replace function public.venda_conferencia_reprovar(p_venda uuid, p_motivo text, p_obs text default null,
                                                             p_cancelou_portal boolean default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v     public.vendas;
  nomes jsonb := '{"cliente_nao_confirmou": "Cliente não confirmou a compra", "cliente_nao_atende": "Cliente não atende",
                   "dados_divergentes": "Dados divergentes", "sem_cobertura": "Sem cobertura", "fora_da_area": "Fora da área de atuação",
                   "ja_cliente_nio": "Já é cliente Nio", "ja_tem_pedido_nio": "Já tem pedido na Nio",
                   "cancelou_30d": "Cancelou a Nio há menos de 30 dias", "suspeita_fraude": "Suspeita de fraude", "outro": "Outro motivo"}'::jsonb;
  -- motivo da conferência → motivo da Saída (lista única, config_lead) e porquê. PROPOSTA 21/11 — conferir com o Ricardo.
  saida jsonb := '{"cliente_nao_confirmou": ["recusou", "outro"], "cliente_nao_atende": ["sem_resposta", null],
                   "dados_divergentes": ["recusou", "outro"], "sem_cobertura": ["fachada_nao_atendida", null],
                   "fora_da_area": ["cidade_nao_atendida", null], "ja_cliente_nio": ["ja_cliente_nio", null],
                   "ja_tem_pedido_nio": ["ja_cliente_nio", null], "cancelou_30d": ["recusou", "momento"],
                   "suspeita_fraude": ["venda_indevida_fraude", null], "outro": ["recusou", "outro"]}'::jsonb;
  obs   text := nullif(btrim(coalesce(p_obs, '')), '');
  r     jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só o backoffice ou o admin reprova a conferência.' using errcode = '42501';
  end if;
  if not (saida ? coalesce(p_motivo, '')) then
    raise exception 'Reprovar a conferência exige um motivo da lista.' using errcode = 'P0001';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found then raise exception 'Venda não encontrada.'; end if;
  if v.origem is distinct from 'parceiro_pap' then raise exception 'Só venda de parceiro passa pela conferência.'; end if;
  if v.conferencia_status is distinct from 'pendente' then
    raise exception 'A conferência desta venda não está pendente (hoje: %).', coalesce(v.conferencia_status, 'sem conferência');
  end if;

  update public.vendas
     set conferencia_status = 'reprovada', conferencia_motivo = p_motivo,
         conferencia_obs = case when obs is null then conferencia_obs else concat_ws(E'\n', conferencia_obs, obs) end
   where id = v.id;

  if v.status = 'saida' then   -- já estava em Saída: só a conferência muda
    return jsonb_build_object('ok', true, 'resumo', '✓ conferência reprovada (a venda já estava em Saída)');
  end if;
  r := public.lead_sair(null, v.id, saida -> p_motivo ->> 0, saida -> p_motivo ->> 1,
         case when saida -> p_motivo ->> 1 = 'momento' then (now() at time zone 'America/Sao_Paulo')::date + 31 end,
         'Reprovada na conferência: ' || (nomes ->> p_motivo), p_cancelou_portal);
  return r;
end $$;
revoke all on function public.venda_conferencia_reprovar(uuid, text, text, boolean) from public, anon;
grant execute on function public.venda_conferencia_reprovar(uuid, text, text, boolean) to authenticated, service_role;

commit;
