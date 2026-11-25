-- id: X122
-- titulo: 0391 (Live 2.0, passo 2): a faixa Reforço aponta conversas da Mari em que vale um gerente entrar (objeção, a Mari escorregou) — só com a Mari atendendo e a janela aberta; Soprar sai pela porta como fala da Mari, não muda a situação e tira a linha; Agora não tira por 24 h; conversa com dono ou com a janela fechada não aparece; tudo fica no reforco_log
-- tipo: atual
select sim.como('servico');
-- 1) objeção de preço numa conversa da Mari, com o cliente falando agora
select sim.lead_novo('Fabi X122') as f \gset
update public.mari_conversas set plano_escolhido = 'V-REG-FIBRA', dados = coalesce(dados, '{}'::jsonb) || '{"objecao":"preco"}'::jsonb where id = :'f';
select sim.cliente_escreve(:'f', 'Achei caro, na outra operadora eu pago 89');
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as k \gset
select coalesce((select x::text from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'f'), '{}') as rf \gset
select sim.confere('objeção numa conversa da Mari aparece no Reforço', (:'rf')::jsonb ->> 'sinal' = 'objecao', (:'k')::jsonb ->> 'reforco');
select sim.confere('com o motivo e a última fala do cliente', (:'rf')::jsonb ->> 'porque' like 'Objeção: preço%' and (:'rf')::jsonb ->> 'fala' like 'Achei caro%', left(:'rf', 300));
select sim.confere('o Reforço não é tarefa: a conversa não entra na fila por causa dele',
  not exists (select 1 from jsonb_array_elements((:'k')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'f' and x ->> 'fonte' = 'reforco'), 'entrou');

-- 2) a linha apareceu → grupo de comparação (uma vez por dia)
select public.reforco_mostrados(jsonb_build_array(jsonb_build_object('conversa_id', :'f', 'sinal', 'objecao')));
select public.reforco_mostrados(jsonb_build_array(jsonb_build_object('conversa_id', :'f', 'sinal', 'objecao')));
select sim.confere('"só mostrado" fica registrado uma vez só',
  (select count(*) from public.reforco_log where conversa_id = :'f' and modo = 'so_mostrado') = 1,
  (select count(*)::text from public.reforco_log where conversa_id = :'f'));

-- 3) Soprar: sai pela porta, como fala da Mari; a situação não muda; a linha sai do Reforço
select public._porta_situacao(:'f', null::uuid) as s0 \gset
select public.reforco_soprar(:'f', 'objecao', 'Entendo! Aqui o preço fica fixo até 2030 e a instalação sai sem custo. Quer que eu veja a data mais próxima?')::text as rs \gset
select sim.confere('o sopro foi aceito', ((:'rs')::jsonb ->> 'ok')::boolean, :'rs');
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('Soprar não muda a situação (a Mari segue)', public._porta_situacao(:'f', null::uuid) = :'s0', :'s0' || ' → ' || public._porta_situacao(:'f', null::uuid));
select sim.confere('o reforço ficou registrado como soprar',
  exists (select 1 from public.reforco_log where conversa_id = :'f' and modo = 'soprar' and sinal = 'objecao' and por = auth.uid()), 'sem linha');
select sim.confere('depois do reforço a linha sai da faixa (descanso)',
  not exists (select 1 from jsonb_array_elements(public.live2_fila() -> 'reforco') x where x ->> 'conversa_id' = :'f'), 'continua');

-- 4) a Mari escorregou: o cliente repete a mesma pergunta
select sim.como('servico');
select sim.lead_novo('Gil X122') as g \gset
select sim.cliente_escreve(:'g', 'Qual o valor do plano de 600 mega?');
select sim.cliente_escreve(:'g', 'Qual o valor do plano de 600 mega?');
select sim.fila_rodar();
select sim.como('backoffice');
select coalesce((select x::text from jsonb_array_elements(public.live2_fila() -> 'reforco') x where x ->> 'conversa_id' = :'g'), '{}') as rg \gset
select sim.confere('cliente repetiu a pergunta → "a Mari escorregou"', (:'rg')::jsonb ->> 'sinal' = 'escorregou', left(:'rg', 300));

-- 5) Agora não, com motivo: some por 24 h e fica registrado
select public.reforco_registrar(:'g', 'escorregou', 'agora_nao', 'nao_era');
select sim.confere('Agora não tira a linha',
  not exists (select 1 from jsonb_array_elements(public.live2_fila() -> 'reforco') x where x ->> 'conversa_id' = :'g'), 'continua');
select sim.confere('com o motivo gravado', exists (select 1 from public.reforco_log where conversa_id = :'g' and modo = 'agora_nao' and motivo = 'nao_era'), 'sem motivo');

-- 6) conversa com dono não é Reforço (quem fala é o dono)
select sim.como('servico');
select sim.lead_novo('Hugo X122') as h \gset
update public.mari_conversas set dados = coalesce(dados, '{}'::jsonb) || '{"objecao":"pensar"}'::jsonb where id = :'h';
select sim.como('backoffice');
select public.backoffice_conversa(:'h', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('servico');
select sim.cliente_escreve(:'h', 'Vou pensar e te falo', false);
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('conversa com o time não aparece no Reforço',
  not exists (select 1 from jsonb_array_elements(public.live2_fila() -> 'reforco') x where x ->> 'conversa_id' = :'h'), 'apareceu');
select sim.confere('e soprar nela é recusado pela porta', sim.recusa(format($$select public.reforco_soprar(%L, 'objecao', 'oi')$$, :'h')) is not null, 'aceitou');

-- 7) janela de 24 h fechada: não aparece (texto livre não sai)
select sim.como('servico');
select sim.lead_novo('Iara X122') as i \gset
update public.mari_conversas set dados = coalesce(dados, '{}'::jsonb) || '{"objecao":"preco"}'::jsonb where id = :'i';
select sim.cliente_escreve(:'i', 'Tá caro');
select sim.passa(:'i', '25 hours');
select sim.como('backoffice');
select sim.confere('janela fechada não aparece no Reforço',
  not exists (select 1 from jsonb_array_elements(public.live2_fila() -> 'reforco') x where x ->> 'conversa_id' = :'i'), 'apareceu');

-- 8) o desfecho por sinal e modo, e quem pode
select sim.confere('o resultado junta por sinal e modo',
  exists (select 1 from jsonb_array_elements(public.reforco_resultado(30)) x where x ->> 'sinal' = 'objecao' and x ->> 'modo' = 'soprar' and (x ->> 'n')::int >= 1),
  public.reforco_resultado(30)::text);
select sim.como('servico');
select sim.confere('fora do backoffice/admin: sem registrar e sem resultado',
  sim.recusa(format($$select public.reforco_registrar(%L, 'objecao', 'agora_nao')$$, :'g')) is not null and public.reforco_resultado(30) is null, 'aceitou');
