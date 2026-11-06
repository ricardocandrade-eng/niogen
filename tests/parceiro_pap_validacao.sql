-- NIOGEN | tests/parceiro_pap_validacao.sql | 06/11/2026 — Claude Code (prompt nº 22, etapa 1 do Programa Parceiro PAP)
-- Validação no banco real, num bloco que se desfaz: tudo roda numa transação e termina com RAISE EXCEPTION
-- (o resultado volta na mensagem do erro; nada persiste). Rodar com:
--   npx.cmd supabase db query --remote --yes -f tests/parceiro_pap_validacao.sql
-- Pré-requisito: migrations 0035–0043 aplicadas. Resultado esperado: "VALIDACAO PARCEIRO PAP: N OK, 0 FALHAS".
-- Para ensaiar ANTES de aplicar, concatene 0035…0043 antes deste arquivo (ver tests/saida/).

begin;

do $teste$
declare
  r        jsonb := '[]'::jsonb;
  nok      int := 0;
  nfalha   int := 0;
  adm      uuid;
  uid_par  uuid := gen_random_uuid();
  uid_out  uuid := gen_random_uuid();
  pl_cart  bigint;  pr_cart numeric;  pc_cart numeric;
  pl_outro bigint;  pr_outro numeric;
  mesh     bigint;
  pa uuid; pb uuid; pc uuid;
  va uuid; vb uuid; vc uuid; vd uuid; ve uuid; vf uuid; vg uuid;
  pontos_a numeric; pontos_b numeric;
  x jsonb; n int; num numeric; d date; t text; ok boolean; pag bigint;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  exp_diario date;

begin
  select id into adm from public.usuarios where perfil = 'admin' and ativo limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);

  select id, preco, preco_cartao into pl_cart, pr_cart, pc_cart from public.config_planos
   where portfolio = 'varejo' and cluster = 'regular' and ativo and preco_cartao is not null and preco_cartao <> preco order by id limit 1;
  select id, preco into pl_outro, pr_outro from public.config_planos
   where portfolio = 'varejo' and cluster = 'regular' and ativo and id <> pl_cart and preco is not null order by id limit 1;
  select id into mesh from public.config_adicionais where codigo = 'MESH';
  r := r || jsonb_build_object('t', '00 setup', 'ok', adm is not null and pl_cart is not null and pl_outro is not null and mesh is not null,
                               'info', jsonb_build_object('plano_cartao', pl_cart, 'preco', pr_cart, 'cartao', pc_cart, 'plano_outro', pl_outro, 'preco_outro', pr_outro));

  -- ── 1. parceiros: validação de CPF/WhatsApp ──
  begin
    insert into public.parceiros (nome, cpf, whatsapp) values ('CPF ruim', '11111111111', '32999990000');
    r := r || jsonb_build_object('t', '01 CPF inválido barrado', 'ok', false);
  exception when others then
    r := r || jsonb_build_object('t', '01 CPF inválido barrado', 'ok', sqlerrm like 'CPF inválido%', 'msg', sqlerrm);
  end;
  begin
    insert into public.parceiros (nome, cpf, whatsapp) values ('Zap ruim', '52998224725', '123');
    r := r || jsonb_build_object('t', '02 WhatsApp inválido barrado', 'ok', false);
  exception when others then
    r := r || jsonb_build_object('t', '02 WhatsApp inválido barrado', 'ok', sqlerrm like 'WhatsApp inválido%', 'msg', sqlerrm);
  end;

  insert into public.parceiros (nome, cpf, whatsapp, pix_chave) values ('Parceiro Teste A', '529.982.247-25', '(32) 99999-0001', '52998224725') returning id into pa;
  insert into public.parceiros (nome, cpf, whatsapp, pix_chave, forma_pagamento) values ('Parceiro Teste B', '111.444.777-35', '32999990002', '11144477735', 'quinzenal') returning id into pb;
  insert into public.parceiros (nome, cpf, whatsapp) values ('Parceiro Teste C (aguardando)', '390.533.447-05', '32999990003') returning id into pc;
  select count(*) into n from public.parceiros where id in (pa, pb) and cpf ~ '^[0-9]{11}$' and whatsapp like '55%';
  r := r || jsonb_build_object('t', '03 CPF e WhatsApp normalizados', 'ok', n = 2);

  begin
    insert into public.parceiros (nome, cpf, whatsapp) values ('Dup CPF', '52998224725', '32999990009');
    r := r || jsonb_build_object('t', '04 CPF único', 'ok', false);
  exception when unique_violation then
    r := r || jsonb_build_object('t', '04 CPF único', 'ok', true);
  end;

  -- aprova A e B (carimba aprovado_em); depois recua datas para simular parceiros antigos
  update public.parceiros set status = 'ativo' where id in (pa, pb);
  select count(*) into n from public.parceiros where id in (pa, pb) and aprovado_em is not null and aprovado_por = adm;
  r := r || jsonb_build_object('t', '05 aprovação carimba aprovado_em/por', 'ok', n = 2);
  update public.parceiros set aprovado_em = '2026-10-01 10:00-03', forma_pagamento_desde = '2026-10-01 10:00-03' where id in (pa, pb);

  begin
    update public.parceiros set status = 'suspenso' where id = pc;
    r := r || jsonb_build_object('t', '06 suspender exige motivo', 'ok', false);
  exception when others then
    r := r || jsonb_build_object('t', '06 suspender exige motivo', 'ok', sqlerrm like 'Suspender ou desligar%');
  end;

  -- ── 2. configuração (valores de teste, desfeitos no fim) ──
  update public.config_parceiros set
    incentivo_quinzenal_valor = 10, incentivo_quinzenal_multiplicador = 1.2,
    bonus_boas_vindas_valor = 50, bonus_boas_vindas_prazo_dias = 30;
  begin
    update public.config_parceiros set degraus = '[{"pontos":"x","premio":1}]'::jsonb;
    r := r || jsonb_build_object('t', '07 degraus inválidos barrados', 'ok', false);
  exception when check_violation then
    r := r || jsonb_build_object('t', '07 degraus inválidos barrados', 'ok', true);
  end;
  insert into public.parceiro_comissao (parceiro_id, plano_id, valor) values (null, pl_cart, 80), (null, pl_outro, 60);
  insert into public.parceiro_comissao (parceiro_id, plano_id, valor) values (pb, pl_outro, 100);
  r := r || jsonb_build_object('t', '08 comissão: padrão e override do parceiro',
        'ok', public.parceiro_comissao_valor(pa, pl_outro) = 60 and public.parceiro_comissao_valor(pb, pl_outro) = 100
              and public.parceiro_comissao_valor(pa, pl_cart) = 80);

  -- ── 3. venda de parceiro: origem, conferência e trava 0→1 ──
  begin
    insert into public.vendas (origem, cliente_nome, status) values ('parceiro_pap', 'Sem parceiro', '0_qualificado');
    r := r || jsonb_build_object('t', '09 parceiro_pap exige parceiro_id', 'ok', false);
  exception when others then
    r := r || jsonb_build_object('t', '09 parceiro_pap exige parceiro_id', 'ok', sqlstate = '23514' or sqlerrm like 'Parceiro sem aprovação%', 'msg', sqlerrm);
  end;
  begin
    insert into public.vendas (origem, parceiro_id, cliente_nome, status, cep, numero, cidade, uf, plano_id)
    values ('parceiro_pap', pc, 'Parceiro nao aprovado', '0_qualificado', '36010000', '999', 'Juiz de Fora', 'MG', pl_cart);
    r := r || jsonb_build_object('t', '10 parceiro não aprovado não envia venda', 'ok', false);
  exception when others then
    r := r || jsonb_build_object('t', '10 parceiro não aprovado não envia venda', 'ok', sqlerrm like 'Parceiro sem aprovação%', 'msg', sqlerrm);
  end;

  insert into public.vendas (origem, parceiro_id, cliente_nome, cliente_cpf_cnpj, cliente_whatsapp, segmento, status, cep, logradouro, numero, complemento, bairro, cidade, uf,
                             plano_id, forma_pagamento, dfv_dispensado, dfv_dispensa_motivo)
  values ('parceiro_pap', pa, 'Maria Souza Teste', '12345678909', '32988880001', 'PF', '0_qualificado', '36010000', 'Rua dos Testes', '100', 'ap 101', 'Centro', 'Juiz de Fora', 'MG',
          pl_cart, 'cartao', true, 'teste automatizado') returning id into va;
  select count(*) into n from public.vendas where id = va and conferencia_status = 'pendente' and conferencia_prazo_ate > now();
  r := r || jsonb_build_object('t', '11 venda nasce com conferência pendente e prazo', 'ok', n = 1,
        'prazo', (select conferencia_prazo_ate from public.vendas where id = va));

  begin
    update public.vendas set status = '1_vendido', nio_pedido = 'TESTE-PAP-A', biometria_status = 'validada' where id = va;
    r := r || jsonb_build_object('t', '12 TRAVA 0→1 com conferência pendente', 'ok', false);
  exception when others then
    r := r || jsonb_build_object('t', '12 TRAVA 0→1 com conferência pendente', 'ok', sqlerrm like '%conferência de qualidade precisa estar aprovada%', 'msg', sqlerrm);
  end;

  begin
    update public.vendas set conferencia_status = 'reprovada' where id = va;
    r := r || jsonb_build_object('t', '13 reprovar exige motivo', 'ok', false);
  exception when others then
    r := r || jsonb_build_object('t', '13 reprovar exige motivo', 'ok', sqlerrm like 'Reprovar ou devolver%');
  end;
  update public.vendas set conferencia_status = 'aprovada' where id = va;
  select count(*) into n from public.eventos_venda where venda_id = va and tipo = 'conferencia';
  r := r || jsonb_build_object('t', '14 aprovar carimba quem/quando e gera evento', 'ok',
        n = 2 and (select conferencia_por = adm and conferencia_em is not null from public.vendas where id = va));

  insert into public.venda_adicionais (venda_id, adicional_id, qtd) values (va, mesh, 1);
  update public.vendas set status = '1_vendido', nio_pedido = 'TESTE-PAP-A', biometria_status = 'validada' where id = va;
  r := r || jsonb_build_object('t', '15 TRAVA 0→1 passa com conferência aprovada', 'ok',
        (select status = '1_vendido' from public.vendas where id = va));

  -- outras origens intactas
  insert into public.vendas (origem, cliente_nome, status, cidade, uf) values ('rua', 'Venda de rua (origem intacta)', '0_qualificado', 'Juiz de Fora', 'MG') returning id into vd;
  insert into public.vendas (origem, cliente_nome, status, cidade, uf) values ('instagram', 'Origem instagram preservada', '0_qualificado', 'Juiz de Fora', 'MG') returning id into ve;
  begin
    update public.vendas set status = '1_vendido' where id = vd;
    r := r || jsonb_build_object('t', '16 rua: trava de sempre (pedido/biometria), sem conferência', 'ok', false);
  exception when others then
    r := r || jsonb_build_object('t', '16 rua: trava de sempre (pedido/biometria), sem conferência', 'ok',
          sqlerrm like 'Venda bloqueada: para passar de Qualificado é obrigatório o nº do pedido%', 'msg', sqlerrm);
  end;
  r := r || jsonb_build_object('t', '17 origens existentes aceitas (rua, instagram)', 'ok',
        (select count(*) from public.vendas where id in (vd, ve) and conferencia_status is null) = 2);

  -- ── 4. instalação confirmada → pontos e pagamentos (A: diário, cartão + Wi-Fi Total) ──
  update public.vendas set status = '2_aguardando_instalacao' where id = va;
  select count(*) into n from public.pontos_lancamentos where parceiro_id = pa;
  r := r || jsonb_build_object('t', '18 nada lançado antes da instalação', 'ok', n = 0);

  -- marcação MANUAL de instalado (sem Concluído/válida da Nio) NÃO paga
  update public.vendas set status = '3_instalado' where id = va;
  select count(*) into n from public.pontos_lancamentos where parceiro_id = pa;
  select count(*) into pag from public.parceiro_pagamentos where parceiro_id = pa;
  r := r || jsonb_build_object('t', '19 instalação manual não gera ponto nem pagamento (F5)', 'ok', n = 0 and pag = 0);

  -- o OSAB (aplicar_osab) grava situação/validade/data e leva 3 → 4
  update public.vendas set nio_situacao = 'Concluído', nio_venda_valida = true, instalado_em = '2026-10-14 15:00-03' where id = va;
  update public.vendas set status = '4_ativo_provisorio' where id = va;
  select coalesce(sum(pontos), 0) into pontos_a from public.pontos_lancamentos where parceiro_id = pa;
  r := r || jsonb_build_object('t', '20 pontos A = preço no cartão + Wi-Fi Total', 'ok', pontos_a = pc_cart + 30,
        'pontos', pontos_a, 'esperado', pc_cart + 30,
        'linhas', (select jsonb_agg(jsonb_build_object('tipo', tipo, 'base', valor_base, 'mult', multiplicador, 'pontos', pontos, 'comp', competencia)) from public.pontos_lancamentos where parceiro_id = pa));

  exp_diario := hoje + case extract(isodow from hoje)::int when 5 then 3 when 6 then 2 else 1 end;
  select vence_em into d from public.parceiro_pagamentos where parceiro_id = pa and tipo = 'comissao' and venda_id = va;
  select valor into num from public.parceiro_pagamentos where parceiro_id = pa and tipo = 'comissao' and venda_id = va;
  r := r || jsonb_build_object('t', '21 diário: comissão R$ 80, 1 dia útil após a confirmação', 'ok', num = 80 and d = exp_diario, 'vence_em', d, 'esperado', exp_diario);
  select count(*) into n from public.parceiro_pagamentos where parceiro_id = pa and tipo = 'bonus_boas_vindas' and valor = 50;
  select count(*) into pag from public.parceiro_pagamentos where parceiro_id = pa and tipo = 'incentivo_quinzenal';
  r := r || jsonb_build_object('t', '22 boas-vindas na 1ª venda instalada; diário sem incentivo', 'ok', n = 1 and pag = 0);

  x := public.parceiro_lancar_instalacao(va);
  select count(*) into n from public.pontos_lancamentos where parceiro_id = pa;
  select count(*) into pag from public.parceiro_pagamentos where parceiro_id = pa;
  r := r || jsonb_build_object('t', '23 lançamento idempotente (2ª chamada não duplica)', 'ok',
        (x ->> 'pontos_novos')::int = 0 and (x ->> 'pagamentos_novos')::int = 0 and n = 2 and pag = 2);

  begin
    update public.pontos_lancamentos set pontos = 1 where parceiro_id = pa;
    r := r || jsonb_build_object('t', '24 pontos só insert (update barrado)', 'ok', false);
  exception when others then
    r := r || jsonb_build_object('t', '24 pontos só insert (update barrado)', 'ok', sqlerrm like '%só aceita insert%');
  end;
  begin
    delete from public.pontos_lancamentos where parceiro_id = pa;
    r := r || jsonb_build_object('t', '25 pontos só insert (delete barrado)', 'ok', false);
  exception when others then
    r := r || jsonb_build_object('t', '25 pontos só insert (delete barrado)', 'ok', sqlerrm like '%só aceita insert%');
  end;

  -- ── 5. B: quinzenal, boleto, multiplicador 1,2 e incentivo ──
  insert into public.vendas (origem, parceiro_id, cliente_nome, cliente_cpf_cnpj, cliente_whatsapp, segmento, status, cep, logradouro, numero, bairro, cidade, uf,
                             plano_id, forma_pagamento, dfv_dispensado, dfv_dispensa_motivo, conferencia_status)
  values ('parceiro_pap', pb, 'Joao Pereira Teste', '39053344705', '32988880002', 'PF', '0_qualificado', '36010000', 'Rua dos Testes', '200', 'Centro', 'Juiz de Fora', 'MG',
          pl_outro, 'boleto', true, 'teste automatizado', 'aprovada') returning id into vb;
  insert into public.venda_adicionais (venda_id, adicional_id, qtd) values (vb, mesh, 1);
  update public.vendas set status = '1_vendido', nio_pedido = 'TESTE-PAP-B', biometria_status = 'validada' where id = vb;
  update public.vendas set status = '2_aguardando_instalacao' where id = vb;
  update public.vendas set nio_situacao = 'Concluído', nio_venda_valida = true, instalado_em = '2026-10-20 10:00-03' where id = vb;
  update public.vendas set status = '3_instalado' where id = vb;
  update public.vendas set status = '4_ativo_provisorio' where id = vb;
  select coalesce(sum(pontos), 0) into pontos_b from public.pontos_lancamentos where parceiro_id = pb;
  r := r || jsonb_build_object('t', '26 pontos B = (boleto + Wi-Fi Total) × 1,2', 'ok', pontos_b = round(pr_outro * 1.2, 2) + round(30 * 1.2, 2), 'pontos', pontos_b, 'esperado', round(pr_outro * 1.2, 2) + round(30 * 1.2, 2));
  select vence_em into d from public.parceiro_pagamentos where parceiro_id = pb and tipo = 'comissao';
  select count(*) into n from public.parceiro_pagamentos where parceiro_id = pb and tipo = 'incentivo_quinzenal' and valor = 10 and vence_em = d;
  -- base = hoje (06/11 → dia ≤ 15 → dia 20 do mês); a regra completa é conferida direto em parceiro_vence_em abaixo
  r := r || jsonb_build_object('t', '27 quinzenal: comissão R$ 100 + incentivo R$ 10, mesmo vencimento', 'ok',
        (select valor from public.parceiro_pagamentos where parceiro_id = pb and tipo = 'comissao') = 100 and n = 1 and d = public.parceiro_vence_em('quinzenal', hoje, array[20, 5]), 'vence_em', d);
  r := r || jsonb_build_object('t', '28 vencimento quinzenal: 1–15 → dia 20; 16–fim → dia 5 seguinte', 'ok',
        public.parceiro_vence_em('quinzenal', date '2026-10-15', array[20, 5]) = date '2026-10-20'
        and public.parceiro_vence_em('quinzenal', date '2026-10-16', array[20, 5]) = date '2026-11-05'
        and public.parceiro_vence_em('quinzenal', date '2026-12-31', array[20, 5]) = date '2027-01-05');
  r := r || jsonb_build_object('t', '29 dia útil: sexta → segunda; feriado 02/11 (Finados) pulado', 'ok',
        public.proximo_dia_util(date '2026-11-06') = date '2026-11-09'
        and public.proximo_dia_util(date '2026-10-30') = date '2026-11-03');

  -- ── 6. apuração: maior degrau, uma vez só ──
  update public.config_parceiros set degraus = jsonb_build_array(
    jsonb_build_object('pontos', floor(pontos_a) - 10, 'premio', 300),
    jsonb_build_object('pontos', floor(pontos_a) - 1,  'premio', 500),
    jsonb_build_object('pontos', floor(pontos_a) + 100000, 'premio', 9999));
  begin
    x := public.apurar_premios_parceiros(date_trunc('month', hoje)::date);
    r := r || jsonb_build_object('t', '30 apurar mês em andamento é recusado', 'ok', false);
  exception when others then
    r := r || jsonb_build_object('t', '30 apurar mês em andamento é recusado', 'ok', sqlerrm like '%ainda não terminou%');
  end;
  x := public.apurar_premios_parceiros(date '2026-10-01');
  select count(*), max(valor) into n, num from public.parceiro_pagamentos where parceiro_id = pa and tipo = 'premio_degrau';
  r := r || jsonb_build_object('t', '31 apuração: só o maior degrau atingido (R$ 500)', 'ok', n = 1 and num = 500, 'retorno', x);
  x := public.apurar_premios_parceiros(date '2026-10-01');
  select count(*) into n from public.parceiro_pagamentos where parceiro_id = pa and tipo = 'premio_degrau';
  r := r || jsonb_build_object('t', '32 apuração 2× não duplica', 'ok', n = 1 and (x ->> 'premios_novos')::int = 0);
  select vence_em into d from public.parceiro_pagamentos where parceiro_id = pa and tipo = 'premio_degrau';
  r := r || jsonb_build_object('t', '33 prêmio vence no dia 5 do mês seguinte', 'ok', d = date '2026-11-05', 'vence_em', d);

  -- instalação confirmada tarde (outubro já apurado) → pontos valem no mês da confirmação
  insert into public.vendas (origem, parceiro_id, cliente_nome, cliente_whatsapp, segmento, status, cep, numero, bairro, cidade, uf, plano_id, forma_pagamento, dfv_dispensado, dfv_dispensa_motivo, conferencia_status)
  values ('parceiro_pap', pa, 'Ana Tardia Teste', '32988880003', 'PF', '0_qualificado', '36010000', '300', 'Centro', 'Juiz de Fora', 'MG', pl_outro, 'boleto', true, 'teste automatizado', 'aprovada') returning id into vc;
  update public.vendas set status = '1_vendido', nio_pedido = 'TESTE-PAP-C', biometria_status = 'validada' where id = vc;
  update public.vendas set status = '2_aguardando_instalacao' where id = vc;
  update public.vendas set nio_situacao = 'Concluído', nio_venda_valida = true, instalado_em = '2026-10-28 10:00-03' where id = vc;
  update public.vendas set status = '4_ativo_provisorio' where id = vc;
  select competencia into d from public.pontos_lancamentos where venda_id = vc and tipo = 'plano';
  r := r || jsonb_build_object('t', '34 confirmação tardia cai no mês da confirmação', 'ok', d = date_trunc('month', hoje)::date, 'competencia', d);
  select count(*) into n from public.parceiro_pagamentos where venda_id = vc and tipo = 'bonus_boas_vindas';
  r := r || jsonb_build_object('t', '35 boas-vindas só na 1ª venda do parceiro', 'ok', n = 0);

  -- comissão sem valor configurado: sem pagamento + evento
  delete from public.parceiro_comissao where parceiro_id is null and plano_id = pl_outro;
  insert into public.vendas (origem, parceiro_id, cliente_nome, cliente_whatsapp, segmento, status, cep, numero, bairro, cidade, uf, plano_id, forma_pagamento, dfv_dispensado, dfv_dispensa_motivo, conferencia_status)
  values ('parceiro_pap', pa, 'Sem Comissao Teste', '32988880004', 'PF', '0_qualificado', '36010000', '400', 'Centro', 'Juiz de Fora', 'MG', pl_outro, 'boleto', true, 'teste automatizado', 'aprovada') returning id into vf;
  update public.vendas set status = '1_vendido', nio_pedido = 'TESTE-PAP-F', biometria_status = 'validada' where id = vf;
  update public.vendas set status = '2_aguardando_instalacao' where id = vf;
  update public.vendas set nio_situacao = 'Concluído', nio_venda_valida = true, instalado_em = '2026-11-03 10:00-03' where id = vf;
  update public.vendas set status = '4_ativo_provisorio' where id = vf;
  select count(*) into n from public.parceiro_pagamentos where venda_id = vf and tipo = 'comissao';
  select count(*) into pag from public.eventos_venda where venda_id = vf and tipo = 'parceiro_sem_comissao';
  r := r || jsonb_build_object('t', '36 sem comissão configurada: sem pagamento, com evento', 'ok', n = 0 and pag = 1);
  insert into public.parceiro_comissao (parceiro_id, plano_id, valor) values (null, pl_outro, 60);
  x := public.parceiro_lancar_instalacao(vf);
  select count(*) into n from public.parceiro_pagamentos where venda_id = vf and tipo = 'comissao';
  r := r || jsonb_build_object('t', '37 configurar e relançar gera o que faltou', 'ok', n = 1);

  -- ── 7. pagamento: barrado sem titular do Pix conferido ──
  select id into pag from public.parceiro_pagamentos where parceiro_id = pa and tipo = 'comissao' limit 1;
  begin
    update public.parceiro_pagamentos set status = 'pago' where id = pag;
    r := r || jsonb_build_object('t', '38 pagamento barrado sem titular do Pix conferido', 'ok', false);
  exception when others then
    r := r || jsonb_build_object('t', '38 pagamento barrado sem titular do Pix conferido', 'ok', sqlerrm like '%titular da chave Pix%');
  end;
  update public.parceiros set pix_titular_conferido_em = now(), pix_titular_conferido_por = adm where id = pa;
  update public.parceiro_pagamentos set status = 'pago', comprovante_path = 'teste/comprovante.png' where id = pag;
  select count(*) into n from public.parceiro_pagamentos where id = pag and status = 'pago' and pago_em is not null and pago_por = adm and pix_chave_snapshot = '52998224725';
  r := r || jsonb_build_object('t', '39 com titular conferido paga e guarda snapshot da chave', 'ok', n = 1);
  begin
    update public.parceiro_pagamentos set valor = 1 where id = pag;
    r := r || jsonb_build_object('t', '40 pagamento pago não se altera', 'ok', false);
  exception when others then
    r := r || jsonb_build_object('t', '40 pagamento pago não se altera', 'ok', sqlerrm like '%já feito não se altera%');
  end;
  update public.parceiros set pix_chave = 'outra-chave@teste.invalid' where id = pa;
  r := r || jsonb_build_object('t', '41 trocar a chave Pix zera a conferência do titular', 'ok',
        (select pix_titular_conferido_em is null from public.parceiros where id = pa));

  -- ── 8. tentativa de conferência (horário + devolução após 3 sem resposta) ──
  insert into public.vendas (origem, parceiro_id, cliente_nome, cliente_whatsapp, segmento, status, cep, numero, bairro, cidade, uf, plano_id, forma_pagamento)
  values ('parceiro_pap', pa, 'Conferencia Teste', '32988880005', 'PF', '0_qualificado', '36010000', '500', 'Centro', 'Juiz de Fora', 'MG', pl_outro, 'boleto') returning id into vg;
  insert into public.contatos_cliente (venda_id, canal, direcao, por, em, toque, tipo)
  values (vg, 'ligacao', 'saida', 'vendedor', now() - interval '2 days', 'CONF_SEM_RESPOSTA', 'ativo'),
         (vg, 'ligacao', 'saida', 'vendedor', now() - interval '1 day',  'CONF_SEM_RESPOSTA', 'ativo');
  -- a conferência foi "aberta" há 3 dias (a contagem de sem-resposta vale desde a última abertura)
  update public.eventos_venda set criado_em = now() - interval '3 days' where venda_id = vg and tipo = 'conferencia';
  begin
    x := public.parceiro_conferencia_tentativa(vg, 'ligacao', false, 'sem resposta (teste)');
    r := r || jsonb_build_object('t', '42 3ª tentativa sem resposta devolve ao parceiro (cliente_nao_atende)', 'ok',
          (x ->> 'devolvida')::boolean and (select conferencia_status = 'devolvida' and conferencia_motivo = 'cliente_nao_atende' from public.vendas where id = vg), 'retorno', x);
  exception when others then
    -- fora do horário do contrato (ou teto) a função recusa: também é o comportamento correto
    r := r || jsonb_build_object('t', '42 3ª tentativa sem resposta devolve ao parceiro (cliente_nao_atende)', 'ok',
          sqlerrm like 'Fora do horário de contato%', 'msg', sqlerrm, 'nota', 'recusada por horário: rodar de novo dentro do horário do contrato para exercitar a devolução');
  end;

  -- ── 9. funções da página do parceiro ──
  insert into auth.users (id, instance_id, aud, role, email) values (uid_par, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'parceiro.teste.a@example.invalid');
  insert into auth.users (id, instance_id, aud, role, email) values (uid_out, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'nao.parceiro@example.invalid');
  update public.parceiros set auth_user_id = uid_par where id = pa;

  perform set_config('request.jwt.claims', json_build_object('sub', uid_par, 'role', 'authenticated')::text, true);
  select count(*) into n from public.parceiro_minhas_vendas();
  r := r || jsonb_build_object('t', '43 parceiro vê só as próprias vendas', 'ok',
        n = (select count(*) from public.vendas where parceiro_id = pa) and n >= 4, 'n', n);
  select string_agg(a.attname, ',') into t
    from pg_proc p, unnest(p.proargnames) a(attname)
   where p.proname in ('parceiro_minhas_vendas', 'parceiro_meus_pontos', 'parceiro_meus_pagamentos') and p.pronamespace = 'public'::regnamespace
     and a.attname ~* '(cpf|whats|telefone|fone|email|logradouro|numero|cep|pedido|complemento|obs|cliente_nome)';
  r := r || jsonb_build_object('t', '44 funções do parceiro não têm coluna de CPF/telefone/endereço', 'ok', t is null, 'achou', t);
  select count(*) into n from public.parceiro_minhas_vendas() where primeiro_nome <> split_part(primeiro_nome, ' ', 1) or primeiro_nome = '';
  r := r || jsonb_build_object('t', '45 só primeiro nome do cliente', 'ok', n = 0 and exists (select 1 from public.parceiro_minhas_vendas() where primeiro_nome = 'Maria'));
  r := r || jsonb_build_object('t', '46 meus_pontos e meus_pagamentos respondem', 'ok',
        exists (select 1 from public.parceiro_meus_pontos()) and exists (select 1 from public.parceiro_meus_pagamentos()),
        'pontos', (select jsonb_agg(to_jsonb(p)) from public.parceiro_meus_pontos() p));
  r := r || jsonb_build_object('t', '47 checar endereço: igual → em_atendimento; outro → livre', 'ok',
        public.parceiro_checar_endereco('36010-000', '100', 'ap 101') = 'em_atendimento'
        and public.parceiro_checar_endereco('36010-000', '100', 'ap 202') = 'livre'
        and public.parceiro_checar_endereco('36010-000', '7777', null) = 'livre');

  -- RLS como o parceiro (authenticated, fora de usuarios): não lê tabelas internas
  set local role authenticated;
  select (select count(*) from public.parceiros) + (select count(*) from public.parceiro_pagamentos)
       + (select count(*) from public.pontos_lancamentos) + (select count(*) from public.config_parceiros) + (select count(*) from public.vendas) into n;
  reset role;
  r := r || jsonb_build_object('t', '48 RLS: parceiro logado não lê tabelas internas', 'ok', n = 0, 'linhas_vistas', n);

  -- quem não é parceiro: funções vazias e checar_endereco recusa
  perform set_config('request.jwt.claims', json_build_object('sub', uid_out, 'role', 'authenticated')::text, true);
  select count(*) into n from public.parceiro_minhas_vendas();
  begin
    perform public.parceiro_checar_endereco('36010000', '1', null);
    ok := false;
  exception when others then ok := sqlerrm like 'Acesso restrito%';
  end;
  r := r || jsonb_build_object('t', '49 não-parceiro: sem vendas e sem checar_endereco', 'ok', n = 0 and ok);

  -- anon não enxerga nada
  begin
    set local role anon;
    perform count(*) from public.parceiros;
    reset role;
    r := r || jsonb_build_object('t', '50 anon negado em parceiros', 'ok', false);
  exception when insufficient_privilege then
    r := r || jsonb_build_object('t', '50 anon negado em parceiros', 'ok', true);
  end;
  reset role;

  -- ── 10. views ──
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  select to_jsonb(i) into x from public.v_parceiro_indicadores i where parceiro_id = pa;
  r := r || jsonb_build_object('t', '51 v_parceiro_indicadores', 'ok', (x ->> 'enviadas')::int >= 4 and (x ->> 'instaladas')::int = 3, 'linha', x);
  select to_jsonb(m) into x from public.v_parceiro_pontos_mes m where parceiro_id = pa and competencia = date '2026-10-01';
  r := r || jsonb_build_object('t', '52 v_parceiro_pontos_mes: degrau atingido e próximo', 'ok',
        (x ->> 'degrau_premio')::numeric = 500 and (x ->> 'proximo_degrau_premio')::numeric = 9999 and (x ->> 'apurado')::boolean, 'linha', x);
  select count(*) into n from public.v_parceiro_a_pagar;
  r := r || jsonb_build_object('t', '53 v_parceiro_a_pagar responde', 'ok', true, 'linhas', n);
  select to_jsonb(m) into x from public.v_margem_canal m where origem = 'parceiro_pap';
  r := r || jsonb_build_object('t', '54 v_margem_canal: parceiro_pap com custo de parceiro', 'ok', (x ->> 'parceiros_pago')::numeric >= 0 and (x ->> 'parceiros_previsto')::numeric > 0, 'linha', x);

  -- ── resumo ──
  select count(*) filter (where (e ->> 'ok')::boolean), count(*) filter (where not (e ->> 'ok')::boolean) into nok, nfalha from jsonb_array_elements(r) e;
  raise exception 'VALIDACAO PARCEIRO PAP: % OK, % FALHAS % | teste 42: %', nok, nfalha,
    (select coalesce(jsonb_pretty(jsonb_agg(e)), '[]') from jsonb_array_elements(r) e where not (e ->> 'ok')::boolean),
    (select e::text from jsonb_array_elements(r) e where e ->> 't' like '42%');
end;
$teste$;

rollback;
