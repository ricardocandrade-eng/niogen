-- NIOGEN | tests/parceiro_pap_validacao.sql | v2 10/11/2026 — Claude Code (docs/Prompt_pocket_parceiro_101126_2025.md)
-- Validação do Programa Parceiro PAP v2 (0115) no banco real, num bloco que se desfaz: tudo roda numa transação e
-- termina com RAISE EXCEPTION (o resultado volta na mensagem do erro; nada persiste). Rodar com:
--   npx.cmd supabase db query --remote --yes -f tests/parceiro_pap_validacao.sql
-- Esperado: "VALIDACAO PARCEIRO PAP v2: N OK, 0 FALHAS".
-- A v1 (06/11, diário + incentivo do quinzenal, regras aposentadas pela 0115) fica no histórico do git.
-- Cobre: só quinzenal · comissão padrão · calendário e vencimento na sexta · Pocket (endereço, planos, envio, status,
-- privacidade, resumo, extrato) · largada · garantia Bronze · apuração em R$ · venda indevida · cadastro público.

begin;

do $teste$
declare
  r      jsonb := '[]'::jsonb;
  nok    int;
  nfalha int;
  adm    uuid;
  uid_p  uuid := gen_random_uuid();
  pid    uuid;
  vid    uuid;
  x      jsonb;
  n      int;
  num    numeric;
  d      date;
  ok     boolean;
  cep_t  text;
  num_t  text;
  bai_t  text;
  pl_sup bigint;
begin
  select id into adm from public.usuarios where perfil = 'admin' and ativo limit 1;
  select h.cep, h.numero, h.bairro into cep_t, num_t, bai_t from public.nio_hp h
   where h.cep like '360%' and h.hp_livre >= 1 and h.hp_tot = 1 and h.numero ~ '^[0-9]+$'
     and not exists (select 1 from public.vendas v where regexp_replace(coalesce(v.cep, ''), '\D', '', 'g') = h.cep)
   limit 1;
  select id into pl_sup from public.config_planos where codigo = 'V-REG-SUP' and ativo;
  r := r || jsonb_build_object('t', '00 setup', 'ok', adm is not null and cep_t is not null and pl_sup is not null);

  -- ── 1. só quinzenal ──
  begin
    insert into public.parceiros (nome, cpf, whatsapp, forma_pagamento) values ('X Y', '52998224725', '32999990009', 'diario');
    ok := false;
  exception when check_violation then ok := true;
  end;
  r := r || jsonb_build_object('t', '01 forma diário recusada', 'ok', ok);
  r := r || jsonb_build_object('t', '02 incentivo do quinzenal zerado', 'ok',
        (select incentivo_quinzenal_valor is null and incentivo_quinzenal_multiplicador is null from public.config_parceiros));

  -- ── 2. comissão padrão e degraus ──
  select jsonb_object_agg(p.codigo, c.valor) into x from public.parceiro_comissao c join public.config_planos p on p.id = c.plano_id where c.parceiro_id is null;
  r := r || jsonb_build_object('t', '03 comissão padrão 10/11', 'ok',
        (x ->> 'V-REG-FIBRA')::numeric = 150 and (x ->> 'V-REG-ESS')::numeric = 190 and (x ->> 'V-REG-SUP')::numeric = 220 and (x ->> 'V-REG-ULT')::numeric = 240
        and (x ->> 'V-O50-FIBRA')::numeric = 110 and (x ->> 'V-O50-ULT')::numeric = 180 and (x ->> 'E-REG-SUP')::numeric = 195);
  r := r || jsonb_build_object('t', '04 degraus em R$', 'ok',
        (select jsonb_agg(jsonb_build_array((e ->> 'pontos')::int, (e ->> 'premio')::int)) from public.config_parceiros c, jsonb_array_elements(c.degraus) e)
        = '[[800,300],[1300,600],[2000,1000],[2600,1500]]'::jsonb);

  -- ── 3. calendário ──
  r := r || jsonb_build_object('t', '05 sexta seguinte à quinta (Natal → segunda)', 'ok',
        public.parceiro_sexta_de('2026-11-26') = '2026-11-27' and public.parceiro_sexta_de('2026-12-24') = '2026-12-28');
  begin
    insert into public.parceiro_calendario (ciclo, instalacoes_de, instalacoes_ate, nio_paga_em, parceiro_recebe_em)
    values ('TESTE', '2026-11-10', '2026-11-20', '2026-12-03', '2026-12-04');
    ok := false;
  exception when others then ok := sqlerrm like '%cruza%';
  end;
  r := r || jsonb_build_object('t', '06 ciclo sobreposto recusado', 'ok', ok);

  -- ── 4. parceiro de teste com login do Pocket ──
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (uid_p, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'parceiro-teste-' || uid_p || '@parceiros.niogen.app',
          '{"tipo":"parceiro"}', '{}', now(), now());
  r := r || jsonb_build_object('t', '07 login do parceiro não vira usuário do NIOGEN', 'ok', not exists (select 1 from public.usuarios where id = uid_p));
  insert into public.parceiros (nome, cpf, whatsapp, pix_chave, cidade, auth_user_id) values ('Carlos Teste da Silva', '52998224725', '32999990001', 'pix-teste', 'Juiz de Fora', uid_p)
  returning id into pid;
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  update public.parceiros set status = 'ativo', pix_titular_conferido_em = now(), largada_valor = 300, largada_paga_em = current_date where id = pid;

  -- ── 5. Pocket como parceiro ──
  perform set_config('request.jwt.claims', json_build_object('sub', uid_p, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    n := (select count(*) from public.vendas);
    ok := n = 0;
  exception when insufficient_privilege then ok := true;
  end;
  r := r || jsonb_build_object('t', '08 parceiro não lê vendas direto', 'ok', ok);
  x := public.parceiro_consultar_endereco(cep_t, num_t, null, 'Juiz de Fora', 'MG', bai_t);
  r := r || jsonb_build_object('t', '09 endereço livre com cobertura', 'ok', (x ->> 'pode_seguir')::boolean and x ->> 'cobertura' = 'tem', 'x', x);
  select count(*) into n from public.parceiro_planos('Juiz de Fora', 'MG', bai_t) where plano_id = pl_sup and comissao = 220;
  r := r || jsonb_build_object('t', '10 planos da cidade com a comissão do parceiro', 'ok', n = 1);
  x := public.parceiro_enviar_venda(jsonb_build_object('cliente_nome', 'Maria Cliente Teste', 'cliente_doc', '11144477735',
        'cliente_whatsapp', '32988887777', 'cep', cep_t, 'numero', num_t, 'bairro', bai_t, 'cidade', 'Juiz de Fora', 'uf', 'MG',
        'plano_id', pl_sup, 'segmento', 'PF', 'forma_pagamento', 'boleto'));
  vid := (x ->> 'venda_id')::uuid;
  r := r || jsonb_build_object('t', '11 venda enviada', 'ok', vid is not null and (x ->> 'comissao')::numeric = 220);
  begin
    perform public.parceiro_enviar_venda(jsonb_build_object('cliente_nome', 'Outra Pessoa', 'cliente_doc', '39053344705',
        'cliente_whatsapp', '32977776666', 'cep', cep_t, 'numero', num_t, 'bairro', bai_t, 'cidade', 'Juiz de Fora', 'uf', 'MG',
        'plano_id', pl_sup, 'segmento', 'PF', 'forma_pagamento', 'boleto'));
    ok := false;
  exception when others then ok := sqlerrm like '%já está atendendo%';
  end;
  r := r || jsonb_build_object('t', '12 mesmo endereço não entra duas vezes', 'ok', ok);
  select to_jsonb(v) into x from public.parceiro_minhas_vendas() v where v.venda_id = vid;
  r := r || jsonb_build_object('t', '13 status "Enviada", só primeiro nome, sem CPF/telefone', 'ok',
        x ->> 'status_texto' = 'Enviada' and x ->> 'primeiro_nome' = 'Maria'
        and not (x ?| array['cliente_cpf_cnpj', 'cliente_whatsapp', 'logradouro', 'numero', 'cep']), 'x', x);
  reset role;
  r := r || jsonb_build_object('t', '14 venda nasce parceiro_pap, conferência pendente', 'ok',
        exists (select 1 from public.vendas v where v.id = vid and v.origem = 'parceiro_pap' and v.parceiro_id = pid and v.conferencia_status = 'pendente'));

  -- ── 6. instalação confirmada (simulada) → lançamento na sexta do ciclo + largada ──
  set local session_replication_role = replica;
  update public.vendas set conferencia_status = 'aprovada', status = '3_instalado', nio_situacao = 'Concluído', nio_venda_valida = true,
         instalado_em = '2026-11-05 14:00-03', biometria_status = 'validada' where id = vid;
  set local session_replication_role = origin;
  x := public.parceiro_lancar_instalacao(vid);
  select vence_em, valor into d, num from public.parceiro_pagamentos where venda_id = vid and tipo = 'comissao';
  r := r || jsonb_build_object('t', '15 comissão R$ 220 na sexta 27/11 (ciclo 1QNOV26)', 'ok', num = 220 and d = '2026-11-27', 'x', x);
  r := r || jsonb_build_object('t', '16 largada: abatimento de R$ 100 na mesma sexta', 'ok',
        exists (select 1 from public.parceiro_pagamentos where venda_id = vid and tipo = 'largada_abatimento' and valor = -100 and vence_em = '2026-11-27'));
  perform public.parceiro_lancar_instalacao(vid);
  r := r || jsonb_build_object('t', '17 lançamento idempotente', 'ok', (select count(*) from public.parceiro_pagamentos where venda_id = vid and tipo in ('comissao', 'largada_abatimento')) = 2);
  update public.parceiro_pagamentos set vence_em = null where venda_id = vid and tipo = 'comissao';
  perform public.parceiro_recalcular_vencimentos();
  r := r || jsonb_build_object('t', '18 recálculo do vencimento pelo calendário', 'ok',
        (select vence_em from public.parceiro_pagamentos where venda_id = vid and tipo = 'comissao') = '2026-11-27');

  -- ── 7. garantia Bronze e apuração ──
  insert into public.pontos_lancamentos (parceiro_id, competencia, tipo, valor_base, multiplicador, pontos, obs) values
    (pid, '2026-10-01', 'ajuste', 900, 1, 900, 'teste'), (pid, '2026-11-01', 'ajuste', 400, 1, 400, 'teste');
  perform set_config('request.jwt.claims', json_build_object('sub', uid_p, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select to_jsonb(m) into x from public.parceiro_meus_pontos() m where m.competencia = '2026-11-01';
  r := r || jsonb_build_object('t', '19 garantia: 570 pts em nov depois de 900 em out → R$ 300', 'ok',
        (x ->> 'garantia_vale')::boolean and (x ->> 'ajuda_prevista')::numeric = 300 and x ->> 'garantia_ate' = '2027-01-01', 'x', x);
  x := public.parceiro_resumo();
  r := r || jsonb_build_object('t', '20 resumo: próxima sexta 27/11 com R$ 220 líquido e saldo da largada 200', 'ok',
        x #>> '{proximo,recebe_em}' = '2026-11-27' and (x #>> '{proximo,valor}')::numeric = 220 and (x #>> '{largada,saldo}')::numeric = 200, 'proximo', x -> 'proximo');
  select count(*) into n from public.parceiro_meus_pagamentos() where tipo = 'largada' and valor = 300;
  r := r || jsonb_build_object('t', '21 extrato mostra a largada paga', 'ok', n = 1);
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  x := public.apurar_premios_parceiros('2026-10-01');
  reset role;
  select valor, vence_em into num, d from public.parceiro_pagamentos where parceiro_id = pid and tipo = 'premio_degrau' and competencia = '2026-10-01';
  r := r || jsonb_build_object('t', '22 apuração de out: Bronze R$ 300 na 1ª sexta depois do dia 5', 'ok', num = 300 and d = '2026-11-13');

  -- ── 8. venda indevida ──
  set local role authenticated;
  x := public.parceiro_marcar_indevida(vid, true, 'teste de validação');
  reset role;
  r := r || jsonb_build_object('t', '23 indevida cancela comissão e abatimento', 'ok',
        not exists (select 1 from public.parceiro_pagamentos where venda_id = vid and status <> 'cancelado'));
  r := r || jsonb_build_object('t', '24 mês com indevida sem ajuda de custo', 'ok', public.parceiro_mes_com_indevida(pid, '2026-11-01'));
  set local role authenticated;
  x := public.parceiro_marcar_indevida(vid, false, null);
  reset role;
  r := r || jsonb_build_object('t', '25 desmarcar devolve o que foi cancelado', 'ok',
        (select count(*) from public.parceiro_pagamentos where venda_id = vid and status = 'previsto' and tipo in ('comissao', 'largada_abatimento')) = 2);

  -- ── 9. cadastro público (anon) ──
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.headers', '{"x-forwarded-for":"10.0.0.1"}', true);
  set local role anon;
  x := public.parceiro_cadastrar('João Novo Parceiro', '39053344705', '(32) 98111-2233', 'joao@pix', 'Juiz de Fora', null);
  begin
    perform public.parceiro_cadastrar('Sem Sobrenome', '123', '32', 'x', 'JF', null);
    ok := false;
  exception when others then ok := true;
  end;
  begin
    perform count(*) from public.parceiros;
    reset role;
    r := r || jsonb_build_object('t', '27 anon negado em parceiros', 'ok', false);
  exception when insufficient_privilege then
    reset role;
    r := r || jsonb_build_object('t', '27 anon negado em parceiros', 'ok', true);
  end;
  reset role;
  r := r || jsonb_build_object('t', '26 cadastro público nasce aguardando; inválido recusado', 'ok',
        ok and x ->> 'ok' = 'true' and exists (select 1 from public.parceiros where cpf = '39053344705' and status = 'aguardando' and cadastro_origem = 'pocket'));

  -- ── resumo ──
  select count(*) filter (where (e ->> 'ok')::boolean), count(*) filter (where not (e ->> 'ok')::boolean) into nok, nfalha from jsonb_array_elements(r) e;
  raise exception 'VALIDACAO PARCEIRO PAP v2: % OK, % FALHAS %', nok, nfalha,
    (select coalesce(jsonb_pretty(jsonb_agg(e)), '[]') from jsonb_array_elements(r) e where not (e ->> 'ok')::boolean);
end;
$teste$;

rollback;
